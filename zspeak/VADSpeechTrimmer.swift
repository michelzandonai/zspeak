import Foundation
import FluidAudio
import OSLog

/// Parâmetros tunáveis do trim por VAD (Silero via FluidAudio), persistidos em
/// UserDefaults para permitir tuning e A/B sem rebuild:
///
///   defaults write com.zspeak.app vadTrimEnabled -bool false
///   defaults write com.zspeak.app vadThreshold -float 0.6
///   defaults write com.zspeak.app vadHangoverSeconds -float 0.5
///
/// O A/B contra o trim RMS roda no benchmark gated `VADTrimBenchmarkTests`.
enum VADTrimSettings {
    static let enabledKey = "vadTrimEnabled"
    static let thresholdKey = "vadThreshold"
    static let hangoverKey = "vadHangoverSeconds"
    static let paddingKey = "vadSpeechPaddingSeconds"

    /// Probabilidade de fala para ENTRAR em um segmento (canônico do Silero).
    /// O default do FluidAudio (0.85) é agressivo demais para mics de ganho
    /// baixo — 0.5 mantém recall alto; a rejeição de ruído fica com o modelo.
    static let defaultThreshold: Float = 0.5
    /// Hangover: silêncio mínimo para encerrar/fundir segmentos. Valores curtos
    /// demais fragmentam pausas naturais de ditado.
    static let defaultHangover: TimeInterval = 0.4
    /// Padding devolvido nas bordas de cada segmento — protege consoantes
    /// iniciais/finais fracas que o VAD corta rente.
    static let defaultPadding: TimeInterval = 0.15

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }

    /// Clamps mantêm os invariantes do `VadSegmentationConfig` do FluidAudio
    /// (preconditions/asserts) mesmo com valores absurdos escritos via defaults.
    static func threshold(_ defaults: UserDefaults = .standard) -> Float {
        guard defaults.object(forKey: thresholdKey) != nil else { return defaultThreshold }
        let raw = Float(defaults.double(forKey: thresholdKey))
        guard raw.isFinite, raw > 0, raw < 1 else { return defaultThreshold }
        return min(max(raw, 0.2), 0.95)
    }

    static func hangover(_ defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: hangoverKey) != nil else { return defaultHangover }
        let raw = defaults.double(forKey: hangoverKey)
        guard raw.isFinite, raw >= 0 else { return defaultHangover }
        return min(raw, 5.0)
    }

    static func padding(_ defaults: UserDefaults = .standard) -> TimeInterval {
        guard defaults.object(forKey: paddingKey) != nil else { return defaultPadding }
        let raw = defaults.double(forKey: paddingKey)
        guard raw.isFinite, raw >= 0 else { return defaultPadding }
        return min(raw, 0.5)
    }
}

/// Trim de fala pré-ASR usando Silero VAD (CoreML via FluidAudio).
///
/// Substitui o gate RMS (`SpeechSampleTrimmer`) no fluxo do microfone quando o
/// modelo está disponível: o Silero distingue fala de respiração/teclado/ruído
/// por conteúdo espectral, não por energia — mic com ganho alto não "vaza"
/// ruído pro ASR e o pre-roll é aparado no fonema, não no volume.
///
/// Design conservador (não perder fala > rejeitar ruído):
/// - Apara apenas as BORDAS (início do 1º segmento → fim do último). Pausas
///   internas são preservadas — removê-las corromperia prosódia e pontuação.
/// - Qualquer falha (modelo indisponível, erro de inferência, zero segmentos)
///   devolve `nil` e o chamador cai para o trim RMS. Fala baixinha que o
///   Silero não reconhece continua protegida pelo caminho antigo.
actor VADSpeechTrimmer {

    private static let logger = Logger(subsystem: "com.zspeak.app", category: "VADSpeechTrimmer")

    /// Base onde o FluidAudio materializa `Models/silero-vad-coreml` — mesma
    /// raiz dos modelos ASR (`zspeak/Models/`), fora do diretório compartilhado
    /// `FluidAudio/` para não conflitar com outros apps (Spokenly).
    private static let modelsBaseDirectory: URL = {
        SafePath.firstURL(for: .applicationSupportDirectory)
            .appendingPathComponent("zspeak", isDirectory: true)
    }()

    private var vad: VadManager?
    private var loadTask: Task<VadManager?, Never>?

    /// Dispara o download/carregamento do modelo em background (idempotente).
    /// Chamado no startup depois do ASR ficar pronto — fora do caminho crítico
    /// da gravação. Falha não é fatal: o pipeline segue no trim RMS.
    func prepare() {
        guard vad == nil, loadTask == nil else { return }
        loadTask = Task {
            do {
                let manager = try await VadManager(
                    config: .default,
                    modelDirectory: Self.modelsBaseDirectory
                )
                Self.logger.info("Silero VAD pronto")
                return manager
            } catch {
                Self.logger.error("Silero VAD indisponível (fallback RMS): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    /// Apara silêncio/ruído das bordas via VAD. `nil` = indisponível ou nenhum
    /// segmento de fala confiável — o chamador deve usar o fallback RMS.
    func trimForASR(
        _ samples: [Float],
        userDefaults: UserDefaults = .standard
    ) async -> SpeechTrimResult? {
        guard VADTrimSettings.isEnabled(userDefaults), !samples.isEmpty else { return nil }

        if vad == nil {
            prepare()
            vad = await loadTask?.value
        }
        guard let vad else { return nil }

        let config = Self.segmentationConfig(
            threshold: VADTrimSettings.threshold(userDefaults),
            hangover: VADTrimSettings.hangover(userDefaults),
            padding: VADTrimSettings.padding(userDefaults)
        )

        let segments: [VadSegment]
        do {
            // Custo do VAD é adicionado ao caminho do stop — medir sempre.
            segments = try await PerfSignposter.measure(.vadTrim, metadata: [
                "samples_in": "\(samples.count)",
            ]) {
                try await vad.segmentSpeech(samples, config: config)
            }
        } catch {
            Self.logger.error("segmentSpeech falhou (fallback RMS): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let result = Self.edgeTrimResult(samples: samples, segments: segments)
        if let result {
            Self.logger.debug("VAD trim: \(result.removedSampleCount) samples removidos de \(samples.count)")
        }
        return result
    }

    // MARK: - Lógica pura (testável sem modelo)

    /// Constrói o `VadSegmentationConfig` respeitando os asserts do FluidAudio:
    /// - threshold de ENTRADA é derivado como `negativeThreshold + offset`
    ///   (única forma de tunar por chamada sem recriar o VadManager);
    /// - `silenceThresholdForSplit >= negativeThreshold` (assert upstream);
    /// - `speechPadding <= minSpeechDuration` (assert upstream).
    static func segmentationConfig(
        threshold: Float,
        hangover: TimeInterval,
        padding: TimeInterval
    ) -> VadSegmentationConfig {
        let offset: Float = 0.15
        let negative = max(threshold - offset, 0.01)
        return VadSegmentationConfig(
            minSpeechDuration: max(0.15, padding),
            minSilenceDuration: max(0, hangover),
            speechPadding: max(0, padding),
            silenceThresholdForSplit: max(0.3, negative),
            negativeThreshold: negative,
            negativeThresholdOffset: offset
        )
    }

    /// Converte segmentos de fala em um `SpeechTrimResult` de bordas: mantém
    /// tudo entre o início do primeiro segmento e o fim do último (pausas
    /// internas preservadas). `nil` quando não há segmento utilizável.
    static func edgeTrimResult(
        samples: [Float],
        segments: [VadSegment],
        sampleRate: Int = 16_000
    ) -> SpeechTrimResult? {
        guard !samples.isEmpty, !segments.isEmpty, sampleRate > 0 else { return nil }

        let firstStart = segments.map(\.startTime).min() ?? 0
        let lastEnd = segments.map(\.endTime).max() ?? 0

        let start = max(0, Int(firstStart * Double(sampleRate)))
        let end = min(samples.count, Int((lastEnd * Double(sampleRate)).rounded(.up)))
        guard start < end else { return nil }

        if start == 0 && end == samples.count {
            return SpeechTrimResult(
                samples: samples,
                originalSampleCount: samples.count,
                startSampleIndex: 0,
                endSampleIndex: samples.count
            )
        }

        return SpeechTrimResult(
            samples: Array(samples[start..<end]),
            originalSampleCount: samples.count,
            startSampleIndex: start,
            endSampleIndex: end
        )
    }
}

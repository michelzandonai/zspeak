import FluidAudio
import Foundation
import Testing
@testable import zspeak

// MARK: - Lógica pura (sem modelo)

@Suite("VADSpeechTrimmer - lógica pura")
struct VADSpeechTrimmerLogicTests {

    private let sampleRate = 16_000

    // MARK: edgeTrimResult

    @Test("Sem segmentos devolve nil (chamador cai para RMS)")
    func edgeTrimSemSegmentos() {
        let samples = [Float](repeating: 0.1, count: 32_000)
        #expect(VADSpeechTrimmer.edgeTrimResult(samples: samples, segments: []) == nil)
        #expect(VADSpeechTrimmer.edgeTrimResult(samples: [], segments: [
            VadSegment(startTime: 0, endTime: 1),
        ]) == nil)
    }

    @Test("Segmento único apara as duas bordas")
    func edgeTrimSegmentoUnico() throws {
        let samples = (0..<32_000).map { Float($0) / 100_000 }
        let segments = [VadSegment(startTime: 0.5, endTime: 1.0)]

        let result = try #require(VADSpeechTrimmer.edgeTrimResult(samples: samples, segments: segments))

        #expect(result.startSampleIndex == 8_000)
        #expect(result.endSampleIndex == 16_000)
        #expect(result.samples.count == 8_000)
        #expect(result.samples.first == samples[8_000])
        #expect(result.originalSampleCount == 32_000)
        #expect(result.removedSampleCount == 24_000)
    }

    @Test("Múltiplos segmentos: pausa interna é preservada (apara só as bordas)")
    func edgeTrimPreservaPausaInterna() throws {
        let samples = [Float](repeating: 0.1, count: 32_000)
        let segments = [
            VadSegment(startTime: 0.25, endTime: 0.5),
            VadSegment(startTime: 1.5, endTime: 1.75),
        ]

        let result = try #require(VADSpeechTrimmer.edgeTrimResult(samples: samples, segments: segments))

        // Do início do 1º ao fim do último — a pausa 0.5s-1.5s fica dentro.
        #expect(result.startSampleIndex == 4_000)
        #expect(result.endSampleIndex == 28_000)
        #expect(result.samples.count == 24_000)
    }

    @Test("Segmento além do fim do áudio é clampado")
    func edgeTrimClampaForaDoAudio() throws {
        let samples = [Float](repeating: 0.1, count: 32_000)
        let segments = [VadSegment(startTime: 1.0, endTime: 3.0)]

        let result = try #require(VADSpeechTrimmer.edgeTrimResult(samples: samples, segments: segments))

        #expect(result.startSampleIndex == 16_000)
        #expect(result.endSampleIndex == 32_000)
    }

    @Test("Segmento inteiramente após o fim do áudio devolve nil")
    func edgeTrimSegmentoInvalido() {
        let samples = [Float](repeating: 0.1, count: 32_000)
        let segments = [VadSegment(startTime: 2.5, endTime: 3.0)]

        #expect(VADSpeechTrimmer.edgeTrimResult(samples: samples, segments: segments) == nil)
    }

    @Test("Cobertura total devolve o buffer inteiro sem cópia parcial")
    func edgeTrimCoberturaTotal() throws {
        let samples = [Float](repeating: 0.1, count: 32_000)
        let segments = [VadSegment(startTime: 0, endTime: 2.0)]

        let result = try #require(VADSpeechTrimmer.edgeTrimResult(samples: samples, segments: segments))

        #expect(result.startSampleIndex == 0)
        #expect(result.endSampleIndex == 32_000)
        #expect(result.samples.count == 32_000)
        #expect(result.removedSampleCount == 0)
    }

    // MARK: segmentationConfig

    @Test("Threshold de entrada é derivado como negativeThreshold + offset")
    func configThresholdDerivado() throws {
        let config = VADSpeechTrimmer.segmentationConfig(threshold: 0.5, hangover: 0.4, padding: 0.15)

        let negative = try #require(config.negativeThreshold)
        #expect(abs(negative - 0.35) < 0.0001)
        #expect(abs(config.negativeThresholdOffset - 0.15) < 0.0001)
        // O FluidAudio reconstrói o threshold de entrada como negative + offset
        #expect(abs((negative + config.negativeThresholdOffset) - 0.5) < 0.0001)
    }

    @Test("Invariantes do FluidAudio: split >= negative e padding <= minSpeech")
    func configInvariantesUpstream() throws {
        // Threshold alto força negative acima do split default (0.3)
        let alto = VADSpeechTrimmer.segmentationConfig(threshold: 0.9, hangover: 0.4, padding: 0.15)
        let negativeAlto = try #require(alto.negativeThreshold)
        #expect(alto.silenceThresholdForSplit >= negativeAlto)

        // Padding acima do minSpeech default (0.15) força minSpeech a acompanhar
        let paddingAlto = VADSpeechTrimmer.segmentationConfig(threshold: 0.5, hangover: 0.4, padding: 0.5)
        #expect(paddingAlto.speechPadding <= paddingAlto.minSpeechDuration)

        // Threshold baixo não pode gerar negative <= 0
        let baixo = VADSpeechTrimmer.segmentationConfig(threshold: 0.1, hangover: 0.4, padding: 0.15)
        let negativeBaixo = try #require(baixo.negativeThreshold)
        #expect(negativeBaixo >= 0.01)
    }

    @Test("Hangover vira minSilenceDuration")
    func configHangover() {
        let config = VADSpeechTrimmer.segmentationConfig(threshold: 0.5, hangover: 0.8, padding: 0.15)
        #expect(abs(config.minSilenceDuration - 0.8) < 0.0001)
    }

    // MARK: VADTrimSettings

    /// Defaults isolados por teste — nunca toca UserDefaults.standard.
    private func makeDefaults() -> UserDefaults {
        let suite = "zspeak-vad-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("Sem chaves gravadas usa os defaults documentados")
    func settingsDefaults() {
        let defaults = makeDefaults()
        #expect(VADTrimSettings.isEnabled(defaults) == true)
        #expect(VADTrimSettings.threshold(defaults) == VADTrimSettings.defaultThreshold)
        #expect(VADTrimSettings.hangover(defaults) == VADTrimSettings.defaultHangover)
        #expect(VADTrimSettings.padding(defaults) == VADTrimSettings.defaultPadding)
    }

    @Test("vadTrimEnabled false desliga o caminho VAD")
    func settingsDisable() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: VADTrimSettings.enabledKey)
        #expect(VADTrimSettings.isEnabled(defaults) == false)
    }

    @Test("Valores absurdos são clampados ou devolvem o default")
    func settingsClamps() {
        let defaults = makeDefaults()

        // Fora de (0,1): inválido → default
        defaults.set(7.5, forKey: VADTrimSettings.thresholdKey)
        #expect(VADTrimSettings.threshold(defaults) == VADTrimSettings.defaultThreshold)
        // Dentro de (0,1) mas extremo: clamp
        defaults.set(0.05, forKey: VADTrimSettings.thresholdKey)
        #expect(VADTrimSettings.threshold(defaults) == 0.2)
        defaults.set(0.99, forKey: VADTrimSettings.thresholdKey)
        #expect(VADTrimSettings.threshold(defaults) == 0.95)

        defaults.set(-3.0, forKey: VADTrimSettings.hangoverKey)
        #expect(VADTrimSettings.hangover(defaults) == VADTrimSettings.defaultHangover)
        defaults.set(60.0, forKey: VADTrimSettings.hangoverKey)
        #expect(VADTrimSettings.hangover(defaults) == 5.0)

        defaults.set(2.0, forKey: VADTrimSettings.paddingKey)
        #expect(VADTrimSettings.padding(defaults) == 0.5)
    }

    @Test("trimForASR devolve nil imediatamente quando desabilitado")
    func trimDesabilitadoDevolveNil() async {
        let defaults = makeDefaults()
        defaults.set(false, forKey: VADTrimSettings.enabledKey)

        let trimmer = VADSpeechTrimmer()
        let samples = [Float](repeating: 0.1, count: 32_000)
        // Não pode nem tentar carregar modelo — retorno imediato.
        let result = await trimmer.trimForASR(samples, userDefaults: defaults)
        #expect(result == nil)
    }
}

// MARK: - Integração com o modelo Silero real

/// Baixa o modelo Silero VAD (~alguns MB) do HuggingFace na primeira execução.
/// Skip com `ZSPEAK_SKIP_SLOW=1` (mesmo gate dos testes de integração do ASR).
@Suite("VADSpeechTrimmer - integração Silero", .serialized)
struct VADSpeechTrimmerIntegrationTests {

    private static var shouldSkip: Bool {
        ProcessInfo.processInfo.environment["ZSPEAK_SKIP_SLOW"] == "1"
    }

    private static let fixturesDir: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }()

    /// Instância compartilhada — o load do modelo é caro e os testes são serializados.
    private static let sharedTrimmer = VADSpeechTrimmer()

    private func fixtureSamples(_ name: String) throws -> [Float] {
        let url = Self.fixturesDir.appendingPathComponent(name)
        return try BenchmarkStore.decodeWAV(Data(contentsOf: url))
    }

    @Test("Fala real com silêncio adicionado nas bordas é aparada", .timeLimit(.minutes(10)))
    func aparaSilencioDasBordas() async throws {
        guard !Self.shouldSkip else { return }

        let speech = try fixtureSamples("pt-short.wav")
        let silence = [Float](repeating: 0, count: 16_000)
        let padded = silence + speech + silence

        let result = await Self.sharedTrimmer.trimForASR(padded)
        let trimmed = try #require(result, "VAD deveria encontrar fala em pt-short.wav")

        // Removeu ao menos 0,5 s de cada segundo de silêncio adicionado
        // (padding de 0,15 s + granularidade de chunk de 256 ms dão a folga).
        #expect(trimmed.startSampleIndex >= 8_000, "início=\(trimmed.startSampleIndex)")
        #expect(trimmed.endSampleIndex <= padded.count - 8_000, "fim=\(trimmed.endSampleIndex) de \(padded.count)")
        // Não comeu mais que 0,5 s do arquivo original (a fala precisa sobrar)
        #expect(trimmed.startSampleIndex <= 16_000 + 8_000)
        #expect(trimmed.samples.count >= 16_000, "sobrou pouca fala: \(trimmed.samples.count) samples")
    }

    @Test("Silêncio puro devolve nil (fallback RMS decide)", .timeLimit(.minutes(10)))
    func silencioPuroDevolveNil() async throws {
        guard !Self.shouldSkip else { return }

        let silence = try fixtureSamples("silence.wav")
        let result = await Self.sharedTrimmer.trimForASR(silence)
        #expect(result == nil)
    }
}

import Foundation
import FluidAudio
import os

/// Segmento de fala com identificação do interlocutor
/// Abstração local desacoplada de `TimedSpeakerSegment` do FluidAudio
struct SpeakerSegment: Identifiable, Sendable, Equatable {
    let id = UUID()
    let speakerId: String        // Ex.: "Speaker 0", "Speaker 1"
    let startTimeSeconds: Double
    let endTimeSeconds: Double

    var durationSeconds: Double { endTimeSeconds - startTimeSeconds }

    static func == (lhs: SpeakerSegment, rhs: SpeakerSegment) -> Bool {
        lhs.speakerId == rhs.speakerId
            && lhs.startTimeSeconds == rhs.startTimeSeconds
            && lhs.endTimeSeconds == rhs.endTimeSeconds
    }
}

/// Wrapper para `OfflineDiarizerManager` do FluidAudio
/// - Baixa modelos sob demanda (~600 MB: pyannote segmentation + WeSpeaker + FBank + PLDA)
/// - Armazena em ~/Library/Application Support/zspeak/Models/diarizer/
/// - Idle timer descarrega o modelo após 120s sem uso (similar ao LLMCorrectionManager)
actor DiarizationManager {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.zspeak",
        category: "DiarizationManager"
    )

    enum ModelState: Sendable, Equatable {
        case notReady
        case preparing(progress: Double)
        case ready
        case error(String)
    }

    enum DiarizerError: LocalizedError {
        case modelNotReady
        case preparationFailed(String)
        case processingFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotReady:
                return "Modelo de diarização não está pronto."
            case .preparationFailed(let reason):
                return "Falha ao preparar modelos de diarização: \(reason)"
            case .processingFailed(let reason):
                return "Falha ao identificar interlocutores: \(reason)"
            }
        }
    }

    /// Diretório exclusivo do zspeak para modelos de diarização
    static let modelsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("zspeak", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("diarizer", isDirectory: true)
    }()

    /// Tamanho total esperado dos modelos pyannote 3.1 + WeSpeaker + FBank + PLDA (~600 MB)
    /// Usado para calcular % de progresso baseado no tamanho em disco durante o download.
    static let expectedTotalBytes: Int64 = 600_000_000

    /// Tempo ocioso antes de descarregar o manager (segundos)
    private static let idleTimeout: TimeInterval = 120

    private(set) var modelState: ModelState = .notReady
    /// OfflineDiarizerManager é `final class` com `nonisolated(unsafe)` internamente —
    /// documentado como thread-safe após `prepareModels()`. Mantemos aqui como
    /// nonisolated(unsafe) para poder passar para métodos async nonisolated sem
    /// violar Sendable (o actor controla quem pode chamar, a lib garante thread safety).
    nonisolated(unsafe) private var manager: OfflineDiarizerManager?
    private var idleTimer: Task<Void, Never>?
    /// Última hint de numSpeakers usada para construir o manager (nil = auto)
    private var currentNumSpeakers: Int?

    /// Config tunada do zspeak: threshold mais alto que o default 0.6 do pyannote/community
    /// para reduzir over-segmentation (uma pessoa fragmentada em vários speakers).
    /// minGapDurationSeconds maior funde segmentos consecutivos do mesmo speaker.
    /// Se `numSpeakers` for fornecido, é forçado e elimina ambiguidade.
    static func makeConfig(numSpeakers: Int? = nil) -> OfflineDiarizerConfig {
        let community = OfflineDiarizerConfig.Clustering.community
        return OfflineDiarizerConfig(
            clustering: OfflineDiarizerConfig.Clustering(
                threshold: 0.7,  // 0.6 default → 0.7 menos sensível, junta mais
                warmStartFa: community.warmStartFa,
                warmStartFb: community.warmStartFb,
                minSpeakers: nil,
                maxSpeakers: nil,
                numSpeakers: numSpeakers
            ),
            postProcessing: OfflineDiarizerConfig.PostProcessing(
                minGapDurationSeconds: 0.5,  // 0.1 default → 0.5 funde gaps curtos do mesmo speaker
                exclusiveSegments: true
            )
        )
    }

    /// Verifica se os modelos já estão baixados em disco (sem carregar na memória)
    nonisolated func areModelsDownloaded() -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: Self.modelsDirectory, includingPropertiesForKeys: nil) else {
            return false
        }
        // Heurística simples: pasta existe e contém pelo menos um arquivo .mlmodelc ou .mlpackage
        return contents.contains { url in
            let ext = url.pathExtension.lowercased()
            return ext == "mlmodelc" || ext == "mlpackage"
        }
    }

    /// Tamanho total dos modelos de diarização em disco (bytes)
    nonisolated func modelsSizeOnDisk() -> Int64? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: Self.modelsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Baixa e carrega os modelos de diarização
    /// Primeira execução: ~600 MB de download + compilação CoreML (pode demorar 1-3 minutos)
    /// O `modelState` é atualizado para `.preparing(progress:)` em tempo real durante o download
    /// (polling do tamanho em disco vs `expectedTotalBytes`).
    func prepare() async throws {
        if manager != nil, case .ready = modelState {
            refreshIdleTimer()
            return
        }

        // Cria diretório se não existir
        try? FileManager.default.createDirectory(
            at: Self.modelsDirectory,
            withIntermediateDirectories: true
        )

        modelState = .preparing(progress: 0)
        Self.logger.info("Preparando modelos de diarização em \(Self.modelsDirectory.path, privacy: .public)")

        // Inicia task de polling do tamanho em disco para atualizar progresso
        let progressTask = startProgressPolling()

        let localManager = OfflineDiarizerManager(config: Self.makeConfig(numSpeakers: currentNumSpeakers))
        do {
            try await localManager.prepareModels(directory: Self.modelsDirectory)
            progressTask.cancel()
            self.manager = localManager
            self.modelState = .ready
            refreshIdleTimer()
            Self.logger.info("Modelos de diarização carregados")
        } catch {
            progressTask.cancel()
            let description = error.localizedDescription
            self.modelState = .error(description)
            Self.logger.error("Falha ao preparar diarizer: \(description, privacy: .public)")
            throw DiarizerError.preparationFailed(description)
        }
    }

    /// Inicia uma task que polla o tamanho do diretório a cada 500ms e atualiza modelState
    /// com o progresso baseado em `expectedTotalBytes`. Para automaticamente quando cancelada.
    private func startProgressPolling() -> Task<Void, Never> {
        Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let currentBytes = self.currentBytesOnDisk()
                let progress = Self.computeProgress(currentBytes: currentBytes)
                await self.updateProgress(progress)
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }
        }
    }

    private func updateProgress(_ progress: Double) {
        // Só atualiza se ainda está em preparing (não sobrescreve .ready/.error vindos do prepare())
        if case .preparing = modelState {
            modelState = .preparing(progress: progress)
        }
    }

    /// Soma o tamanho de todos os arquivos no diretório de modelos.
    /// Versão nonisolated para uso em Task externa (mesma lógica de modelsSizeOnDisk).
    nonisolated private func currentBytesOnDisk() -> Int64 {
        return Self.directoryByteCount(Self.modelsDirectory)
    }

    /// Função pura para calcular tamanho total recursivamente
    nonisolated static func directoryByteCount(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Função pura — calcula progresso 0.0-0.95 baseado em bytes baixados vs total esperado.
    /// Cap em 0.95 para deixar margem para a fase de compilação CoreML que vem depois.
    nonisolated static func computeProgress(currentBytes: Int64, expected: Int64 = expectedTotalBytes) -> Double {
        guard expected > 0 else { return 0 }
        let ratio = Double(currentBytes) / Double(expected)
        return min(0.95, max(0.0, ratio))
    }

    /// Diariza áudio PCM 16 kHz mono float32
    /// - Parameter numSpeakers: se conhecido, força exatamente N speakers (elimina over-segmentation).
    ///   Se nil, deixa o clustering decidir automaticamente.
    /// Retorna lista de segmentos ordenados por tempo de início.
    func diarize(samples: [Float], numSpeakers: Int? = nil) async throws -> [SpeakerSegment] {
        // Se a hint mudou, recria o manager com nova config (modelos em disco são reusados)
        if numSpeakers != currentNumSpeakers || manager == nil {
            currentNumSpeakers = numSpeakers
            let newManager = OfflineDiarizerManager(config: Self.makeConfig(numSpeakers: numSpeakers))
            do {
                try await newManager.prepareModels(directory: Self.modelsDirectory)
            } catch {
                self.modelState = .error(error.localizedDescription)
                throw DiarizerError.preparationFailed(error.localizedDescription)
            }
            self.manager = newManager
            self.modelState = .ready
            Self.logger.info("Diarizer recriado com numSpeakers=\(numSpeakers.map(String.init) ?? "auto", privacy: .public)")
        }

        refreshIdleTimer()
        return try await performDiarization(samples: samples)
    }

    /// Executa a diarização fora do isolamento do actor — o OfflineDiarizerManager
    /// é thread-safe após `prepareModels()`, então é seguro chamar de contexto nonisolated.
    nonisolated private func performDiarization(samples: [Float]) async throws -> [SpeakerSegment] {
        guard let manager else {
            throw DiarizerError.modelNotReady
        }

        let result: DiarizationResult
        do {
            result = try await manager.process(audio: samples)
        } catch {
            throw DiarizerError.processingFailed(error.localizedDescription)
        }

        return Self.mapSegments(result.segments)
    }

    /// Remove modelos de diarização do disco
    func deleteModels() async throws {
        // Descarrega manager antes de apagar
        self.manager = nil
        self.modelState = .notReady
        idleTimer?.cancel()
        idleTimer = nil

        let fm = FileManager.default
        if fm.fileExists(atPath: Self.modelsDirectory.path) {
            try fm.removeItem(at: Self.modelsDirectory)
        }
    }

    /// Mapeia segmentos do FluidAudio para o tipo local, filtrando segmentos vazios
    /// e ordenando por `startTimeSeconds`. Função pura — testável sem carregar modelo.
    static func mapSegments(_ segments: [TimedSpeakerSegment]) -> [SpeakerSegment] {
        segments
            .filter { $0.endTimeSeconds > $0.startTimeSeconds }
            .sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            .map {
                SpeakerSegment(
                    speakerId: $0.speakerId,
                    startTimeSeconds: Double($0.startTimeSeconds),
                    endTimeSeconds: Double($0.endTimeSeconds)
                )
            }
    }

    /// Extrai um slice de samples a partir de um range em segundos. Função pura — testável.
    static func slice(
        samples: [Float],
        from startSeconds: Double,
        to endSeconds: Double,
        sampleRate: Int = 16000
    ) -> [Float] {
        let totalSamples = samples.count
        let startIdx = max(0, min(totalSamples, Int(startSeconds * Double(sampleRate))))
        let endIdx = max(startIdx, min(totalSamples, Int(endSeconds * Double(sampleRate))))
        guard endIdx > startIdx else { return [] }
        return Array(samples[startIdx..<endIdx])
    }

    // MARK: - Idle timer

    private func refreshIdleTimer() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.idleTimeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    private func unload() {
        guard manager != nil else { return }
        Self.logger.info("Descarregando diarizer após idle timeout")
        manager = nil
        modelState = .notReady
    }
}

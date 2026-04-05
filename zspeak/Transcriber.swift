import Foundation
import FluidAudio

/// Wrapper para transcrição de áudio usando Parakeet TDT 0.6B V3 via FluidAudio
/// Modelo roda 100% local no Apple Neural Engine via CoreML
actor Transcriber {

    private var asrManager: AsrManager?
    private var ctcModels: CtcModels?
    private(set) var isReady = false

    /// Diretório exclusivo do zspeak para modelos — evita conflito com outros apps (Spokenly)
    private static let modelsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("zspeak", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }()

    /// Carrega o modelo Parakeet TDT v3
    /// Primeiro uso: download automático do HuggingFace (~496 MB)
    func initialize() async throws {
        let models = try await AsrModels.downloadAndLoad(to: Self.modelsDirectory, version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asrManager = manager
        self.isReady = true
    }

    /// Transcreve amostras de áudio (16kHz mono float32)
    /// Retorna o texto transcrito
    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager = asrManager else {
            throw TranscriberError.notInitialized
        }

        let result = try await manager.transcribe(samples, source: .microphone)
        return result.text
    }

    /// Configura vocabulário customizado com context biasing nativo
    /// Baixa modelo CTC auxiliar (~110MB) na primeira chamada
    func configureVocabulary(_ context: CustomVocabularyContext) async throws {
        guard let manager = asrManager else {
            throw TranscriberError.notInitialized
        }

        // Baixa/carrega modelo CTC se necessário (diretório exclusivo do zspeak)
        if ctcModels == nil {
            ctcModels = try await CtcModels.downloadAndLoad(to: Self.modelsDirectory, variant: .ctc110m)
        }

        try await manager.configureVocabularyBoosting(
            vocabulary: context,
            ctcModels: ctcModels!
        )
    }

    /// Desativa vocabulário customizado
    func disableVocabulary() async {
        await asrManager?.disableVocabularyBoosting()
    }

    enum TranscriberError: LocalizedError {
        case notInitialized

        var errorDescription: String? {
            switch self {
            case .notInitialized:
                return "Modelo de transcrição não foi inicializado"
            }
        }
    }
}

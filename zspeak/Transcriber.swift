import Foundation
import FluidAudio

/// Wrapper para transcrição de áudio usando Parakeet TDT 0.6B V3 via FluidAudio
/// Modelo roda 100% local no Apple Neural Engine via CoreML
actor Transcriber {

    private var asrManager: AsrManager?
    private(set) var isReady = false

    /// Carrega o modelo Parakeet TDT v3
    /// Primeiro uso: download automático do HuggingFace (~496 MB)
    func initialize() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
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

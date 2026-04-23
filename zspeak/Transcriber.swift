import Foundation
import FluidAudio

/// Wrapper para transcrição de áudio usando Parakeet TDT 0.6B V3 via FluidAudio.
/// Modelo roda 100% local no Apple Neural Engine via CoreML.
actor Transcriber {

    private var asrManager: AsrManager?
    private var ctcModels: CtcModels?
    private var configuredVocabularySignature: String?
    private(set) var isReady = false

    /// Diretório exclusivo do zspeak para modelos — evita conflito com outros apps (Spokenly)
    private static let modelsDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("zspeak", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }()

    /// Diretório exclusivo do modelo CTC usado no rescoring do vocabulário.
    private static let ctcModelsDirectory: URL = {
        modelsDirectory.appendingPathComponent("parakeet-ctc-110m-coreml", isDirectory: true)
    }()

    /// Carrega o modelo Parakeet TDT v3.
    /// Primeiro uso: download automático do HuggingFace (~496 MB).
    func initialize() async throws {
        let models = try await AsrModels.downloadAndLoad(to: Self.modelsDirectory, version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asrManager = manager
        self.configuredVocabularySignature = nil
        self.isReady = true
    }

    /// Configura o context biasing nativo do FluidAudio para batch ASR.
    ///
    /// O `VocabularyStore.applyReplacements(to:)` continua existindo como fallback
    /// leve no texto final, mas a principal correção de termos técnicos deve
    /// acontecer aqui, ainda durante o rescoring do decoder.
    func configureVocabulary(_ vocabulary: CustomVocabularyContext?) async throws {
        guard let manager = asrManager else {
            throw TranscriberError.notInitialized
        }

        let signature = vocabularySignature(for: vocabulary)
        guard signature != configuredVocabularySignature else { return }

        guard let vocabulary, !vocabulary.terms.isEmpty else {
            await manager.disableVocabularyBoosting()
            configuredVocabularySignature = nil
            return
        }

        let ctc = try await loadCtcModelsIfNeeded()
        try await manager.configureVocabularyBoosting(
            vocabulary: vocabulary,
            ctcModels: ctc
        )
        configuredVocabularySignature = signature
    }

    /// Transcreve amostras de áudio (16kHz mono float32).
    /// Retorna o texto transcrito. Quando configurado, o vocabulário customizado
    /// é aplicado nativamente no rescoring do decoder; o pipeline ainda mantém
    /// um fallback em Swift no texto final para aliases exatos.
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

    private func loadCtcModelsIfNeeded() async throws -> CtcModels {
        if let ctcModels {
            return ctcModels
        }

        let models = try await CtcModels.downloadAndLoad(
            to: Self.ctcModelsDirectory,
            variant: .ctc110m
        )
        self.ctcModels = models
        return models
    }

    private func vocabularySignature(for vocabulary: CustomVocabularyContext?) -> String? {
        guard let vocabulary, !vocabulary.terms.isEmpty else { return nil }

        let terms = vocabulary.terms.map { term in
            let aliases = term.aliases?.joined(separator: ",") ?? ""
            let weight = term.weight.map { String($0) } ?? ""
            return "\(term.text)|\(weight)|\(aliases)"
        }
        return terms.joined(separator: ";")
    }
}

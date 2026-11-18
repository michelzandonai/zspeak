import Foundation
import FluidAudio
import os

/// Reconhecimento local com Parakeet Ultra via FluidAudio e Core ML.
actor Transcriber {
    static let modelName = "Parakeet Ultra"
    private static let logger = Logger(subsystem: "com.zspeak", category: "Transcriber")

    private struct PreparedVocabulary {
        let signature: Data
        let session: VocabularyBoostingSession
    }

    private var asrManager: AsrManager?
    private var asrModels: AsrModels?
    private var ctcModels: CtcModels?
    private var ctcLoadTask: Task<CtcModels, Error>?
    private var vocabularySessions: [VocabularyEntryContext: PreparedVocabulary] = [:]
    private var vocabularyRevision = 0
    var isReady: Bool { asrManager != nil }

    /// Cache exclusivo do zspeak. Cada modelo tem seu próprio subdiretório.
    private static let modelsDirectory: URL = {
        SafePath.firstURL(for: .applicationSupportDirectory)
            .appendingPathComponent("zspeak", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }()

    private static let ctcModelsDirectory = modelsDirectory
        .appendingPathComponent(Repo.parakeetCtc110m.folderName, isDirectory: true)

    func initialize() async throws {
        guard asrManager == nil else { return }

        let models = try await AsrModels.downloadAndLoad(
            to: Self.modelsDirectory.appendingPathComponent(Repo.parakeetUltra.folderName, isDirectory: true),
            version: .ultra
        )
        asrManager = AsrManager(config: .default, models: models)
        asrModels = models
        Self.logger.info("Modelo ASR pronto: \(Self.modelName, privacy: .public)")
    }

    /// Prepara o vocabulário fora da gravação e preserva o contexto por destino.
    /// O perfil de desenvolvimento inclui as entradas globais.
    func configureVocabulary(
        global: CustomVocabularyContext?, development: CustomVocabularyContext?
    ) async throws {
        guard asrManager != nil else { throw TranscriberError.notInitialized }

        vocabularyRevision += 1
        let revision = vocabularyRevision
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var pending: [(scope: VocabularyEntryContext, context: CustomVocabularyContext, signature: Data)] = []
        var ready: [VocabularyEntryContext: PreparedVocabulary] = [:]

        let scopes: [(VocabularyEntryContext, CustomVocabularyContext?)] = [
            (.global, global), (.dev, development)
        ]
        for (scope, context) in scopes {
            guard let context, !context.terms.isEmpty else { continue }
            // Os parâmetros ficam no perfil central. A assinatura inclui os termos
            // na ordem original, com pesos, aliases e tokens.
            let signature = try encoder.encode(context.terms)
            if let cached = vocabularySessions[scope], cached.signature == signature {
                ready[scope] = cached
            } else {
                pending.append((scope, context, signature))
            }
        }

        // Mudanças removem o contexto obsoleto antes de qualquer suspensão.
        // Se o CTC falhar, a transcrição continua com os aliases no pós-processamento.
        vocabularySessions = ready
        guard !pending.isEmpty else { return }
        let ctc = try await loadCtcModelsIfNeeded()
        for item in pending {
            guard revision == vocabularyRevision else { return }
            if let identical = ready.values.first(where: { $0.signature == item.signature }) {
                ready[item.scope] = identical
                continue
            }
            let session = try await VocabularyBoostingSession(
                vocabulary: item.context,
                ctcModels: ctc,
                config: VocabularyBiasingProfile.rescorerConfig,
                thresholds: VocabularyBiasingProfile.thresholds
            )
            ready[item.scope] = PreparedVocabulary(signature: item.signature, session: session)
        }
        guard revision == vocabularyRevision else { return }
        vocabularySessions = ready
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await transcribe(samples, vocabularyScope: .global)
    }

    func transcribe(_ samples: [Float], vocabularyScope: VocabularyEntryContext) async throws -> String {
        guard let manager = asrManager else { throw TranscriberError.notInitialized }

        let vocabulary = vocabularySessions[vocabularyScope]?.session
        let result = try await Self.decode(samples, using: manager)
        let timings = result.tokenTimings ?? []
        guard let vocabulary,
              vocabulary.hasCTCRescoringCandidates(text: result.text, tokenTimings: timings)
        else { return result.text }

        let rescored = await vocabulary.rescore(text: result.text, tokenTimings: timings, audioSamples: samples)
        return rescored?.text ?? result.text
    }

    func startLiveTranscription(
        onUpdate: @escaping @Sendable (LiveTranscriptionUpdate) -> Void
    ) async throws -> any LiveTranscriptionSession {
        guard let models = asrModels else { throw TranscriberError.notInitialized }

        let manager = AsrManager(config: .default, models: models)
        // Cada prévia reprocessa uma janela. O CTC roda uma vez no resultado final.
        return CumulativeLiveTranscriptionSession(
            transcribePreview: { samples in
                try await Self.decode(samples, using: manager).text
            },
            onUpdate: onUpdate
        )
    }

    enum TranscriberError: LocalizedError {
        case notInitialized

        var errorDescription: String? {
            "Modelo de transcrição não foi inicializado"
        }
    }

    private static func decode(_ samples: [Float], using manager: AsrManager) async throws -> ASRResult {
        var decoder = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(samples, decoderState: &decoder)
    }

    private func loadCtcModelsIfNeeded() async throws -> CtcModels {
        if let ctcModels { return ctcModels }
        if let ctcLoadTask { return try await ctcLoadTask.value }

        let task = Task {
            try await CtcModels.downloadAndLoad(to: Self.ctcModelsDirectory, variant: .ctc110m)
        }
        ctcLoadTask = task
        defer { ctcLoadTask = nil }

        let models = try await task.value
        ctcModels = models
        return models
    }
}

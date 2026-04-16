import Foundation
import Hub
import MLXLLM
import MLXLMCommon
import os

/// Gerencia o LLM local (MLX) para correção pós-transcrição
/// Download, carregamento e inferência do modelo Gemma 3 4B quantizado
actor LLMCorrectionManager {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.zspeak",
        category: "LLMCorrectionManager"
    )

    enum ModelState: Sendable, Equatable {
        case notDownloaded
        case downloading(progress: Double)
        case downloaded
        case loading
        case ready
        case error(String)

        static func == (lhs: ModelState, rhs: ModelState) -> Bool {
            switch (lhs, rhs) {
            case (.notDownloaded, .notDownloaded),
                 (.downloaded, .downloaded),
                 (.loading, .loading),
                 (.ready, .ready):
                return true
            case let (.downloading(a), .downloading(b)):
                return a == b
            case let (.error(a), .error(b)):
                return a == b
            default:
                return false
            }
        }
    }

    enum LLMError: LocalizedError {
        case modelNotReady
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelNotReady:
                return "Modelo LLM não est�� pronto"
            case .generationFailed(let reason):
                return "Falha na geração: \(reason)"
            }
        }
    }

    private(set) var modelState: ModelState = .notDownloaded
    private var modelContainer: ModelContainer?
    private var idleTimer: Task<Void, Never>?
    private var keepAlive: Bool = false

    /// Quando true, cancela o idle timer e impede que o modelo seja descarregado.
    /// Usado enquanto o Modo Prompt está ativo — evita cold starts repetidos.
    func setKeepAlive(_ alive: Bool) {
        keepAlive = alive
        if alive {
            idleTimer?.cancel()
            idleTimer = nil
        } else if case .ready = modelState {
            startIdleTimer()
        }
    }

    /// Qwen 2.5 3B Instruct quantizado 4-bit (~1.7 GB) — melhor instruction following
    static let modelID = "mlx-community/Qwen2.5-3B-Instruct-4bit"

    /// Tempo de inatividade antes de descarregar o modelo da memória (segundos)
    private static let idleTimeout: TimeInterval = 120

    private static let modelConfiguration = ModelConfiguration(
        id: modelID,
        defaultPrompt: ""
    )

    /// Diretório onde o defaultHubApi armazena modelos baixados
    /// ~/Library/Caches/models/{org}/{model}
    private static var modelCacheDirectory: URL {
        let cacheBase = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelID, isDirectory: true)
    }

    // MARK: - Inicialização

    init() {
        // Verifica existência do modelo no init (nonisolated, inline)
        let dir = Self.modelCacheDirectory
        if FileManager.default.fileExists(atPath: dir.path) {
            modelState = .downloaded
        }
    }

    // MARK: - Download

    /// Baixa o modelo do HuggingFace com progresso
    func downloadModel() async throws {
        guard case .notDownloaded = modelState else {
            if case .downloaded = modelState { return }
            if case .ready = modelState { return }
            return
        }

        Self.logger.info("Iniciando download do modelo \(Self.modelID)")
        modelState = .downloading(progress: 0)

        do {
            // loadContainer faz download + carregamento.
            // `[weak self]` evita reter o manager (um actor) pelo closure do loader
            // enquanto o download acontece em background. Se o app der deinit no
            // meio (troca de modelo, encerramento), o progresso simplesmente para
            // de atualizar em vez de segurar o actor vivo.
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: Self.modelConfiguration
            ) { [weak self] progress in
                let fraction = progress.fractionCompleted
                Task { [weak self] in
                    await self?.updateDownloadProgress(fraction)
                }
            }

            modelContainer = container
            modelState = .ready
            startIdleTimer()
            Self.logger.info("Modelo baixado e carregado com sucesso")
        } catch {
            modelState = .error(error.localizedDescription)
            Self.logger.error("Erro no download do modelo: \(error.localizedDescription)")
            throw error
        }
    }

    private func updateDownloadProgress(_ fraction: Double) {
        modelState = .downloading(progress: fraction)
    }

    // MARK: - Carregamento / Descarregamento

    /// Carrega o modelo na memória (se já foi baixado)
    func loadModel() async throws {
        if case .ready = modelState { return }

        Self.logger.info("Carregando modelo na memória")
        modelState = .loading

        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: Self.modelConfiguration
            ) { _ in }

            modelContainer = container
            modelState = .ready
            startIdleTimer()
            Self.logger.info("Modelo carregado com sucesso")
        } catch {
            modelState = .error(error.localizedDescription)
            Self.logger.error("Erro ao carregar modelo: \(error.localizedDescription)")
            throw error
        }
    }

    /// Descarrega o modelo da memória para liberar RAM
    func unloadModel() {
        modelContainer = nil
        idleTimer?.cancel()
        idleTimer = nil
        if case .ready = modelState {
            modelState = .downloaded
        }
        Self.logger.info("Modelo descarregado da memória")
    }

    // MARK: - Inferência

    /// Corrige o texto transcrito usando o LLM local
    /// - Parameters:
    ///   - text: Texto transcrito pelo ASR
    ///   - systemPrompt: Prompt de sistema com instruções de correção
    ///   - maxTokens: Limite de tokens na resposta (padrão: 384)
    ///   - onPartial: Callback chamado a cada chunk com o texto parcial acumulado (para streaming na UI)
    /// - Returns: Texto corrigido pelo LLM
    func correct(
        text: String,
        systemPrompt: String,
        maxTokens: Int = 384,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        // Lazy load do disco se já baixado — NUNCA faz download aqui
        if modelContainer == nil {
            guard case .downloaded = modelState else {
                throw LLMError.modelNotReady
            }
            try await loadModel()
        }

        guard case .ready = modelState, let container = modelContainer else {
            throw LLMError.modelNotReady
        }

        resetIdleTimer()

        Self.logger.info("Iniciando correção de texto (\(text.count) chars)")

        let userInput = UserInput(
            chat: [
                .system(systemPrompt),
                .user(text),
            ]
        )

        let input = try await container.prepare(input: userInput)

        var parameters = GenerateParameters()
        parameters.maxTokens = maxTokens

        // Gera resposta token a token via AsyncStream
        var result = ""
        let stream = try await container.generate(
            input: input,
            parameters: parameters
        )

        for await generation in stream {
            switch generation {
            case .chunk(let chunk):
                result += chunk
                // Notifica callback com texto parcial (ignora tags <think> para preview)
                if let onPartial {
                    var preview = result
                    if let thinkStart = preview.range(of: "<think>") {
                        if let thinkEnd = preview.range(of: "</think>") {
                            preview.removeSubrange(thinkStart.lowerBound...thinkEnd.upperBound)
                        } else {
                            preview.removeSubrange(thinkStart.lowerBound..<preview.endIndex)
                        }
                    }
                    onPartial(preview.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            case .info:
                break
            default:
                break
            }
        }

        // Remove tags <think>...</think> se presentes (Qwen3 thinking mode)
        var cleaned = result
        if let thinkStart = cleaned.range(of: "<think>"),
           let thinkEnd = cleaned.range(of: "</think>") {
            cleaned.removeSubrange(thinkStart.lowerBound...thinkEnd.upperBound)
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        Self.logger.info("Correção concluída: \(trimmed.count) chars")
        return trimmed
    }

    // MARK: - Gerenciamento do Modelo

    /// Verifica se o modelo já foi baixado localmente
    func checkModelExists() -> Bool {
        let dir = Self.modelCacheDirectory
        let exists = FileManager.default.fileExists(atPath: dir.path)
        if exists {
            Self.logger.debug("Modelo encontrado em cache: \(dir.path)")
        }
        return exists
    }

    /// Remove o modelo do disco
    func deleteModel() throws {
        unloadModel()

        let dir = Self.modelCacheDirectory
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
            Self.logger.info("Modelo removido do disco")
        }

        modelState = .notDownloaded
    }

    /// Calcula o tamanho do modelo no disco (bytes)
    func modelSizeOnDisk() -> Int64? {
        let dir = Self.modelCacheDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }

        let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]
        )
        var totalSize: Int64 = 0

        while let fileURL = enumerator?.nextObject() as? URL {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }

        return totalSize > 0 ? totalSize : nil
    }

    // MARK: - Idle Timer

    /// Inicia timer para descarregar modelo após inatividade
    private func startIdleTimer() {
        idleTimer?.cancel()
        guard !keepAlive else { return }
        idleTimer = Task {
            try? await Task.sleep(for: .seconds(Self.idleTimeout))
            guard !Task.isCancelled else { return }
            unloadModel()
        }
    }

    /// Reinicia o timer de inatividade
    private func resetIdleTimer() {
        startIdleTimer()
    }
}

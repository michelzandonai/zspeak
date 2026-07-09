import Foundation

// Protocolos de dependência injetável — permitem que `RecordingController`,
// `LLMCoordinator` e `FileTranscriptionCoordinator` sejam exercitados com
// fakes em testes sem tocar hardware de áudio / modelo MLX / clipboard.
//
// Os tipos existentes (`AudioCapture`, `Transcriber`, `TextInserter`,
// `LLMCorrectionManager`) conformam via extension em seus próprios arquivos
// ou na parte inferior deste arquivo (extensões simples quando não carregam
// armazenamento próprio). Nada da implementação atual muda — só formaliza
// o contrato que já estava sendo consumido.

/// Captura de áudio do microfone.
/// Abstrai `AudioCapture` para testes que precisam simular start/stop
/// sem abrir o HAL.
protocol AudioCapturing: Actor {
    /// Leitura não-isolated do nível atual (UI faz pull em 30 Hz).
    nonisolated func currentAudioLevel() -> Float
    /// Clipping recente na captação (aviso "mic muito alto" na UI).
    nonisolated func isInputClipping() -> Bool

    /// Inicia a captura no device indicado (ou no default do sistema se nil).
    /// `onFirstSample` é invocado uma única vez quando a gravação começa a
    /// persistir samples — usado para transicionar `.preparing → .recording`.
    /// Em modo quente, é disparado síncrono (pre-roll já presente).
    func start(
        deviceUID: String?,
        onFirstSample: (@Sendable () -> Void)?,
        onSamples: (@Sendable ([Float]) -> Void)?
    ) async throws

    /// Para a captura, drena buffers em voo e devolve os samples acumulados
    /// (16 kHz mono float32). Preserva o hot window quando ativo.
    func stop() async -> [Float]

    /// Mantém o engine em hot window para o próximo start. O HAL/microfone
    /// fica aberto, mas o buffer principal só recebe áudio após `start`.
    func warmUp(deviceUID: String?) async throws

    /// Fecha o hot window: desliga o engine, apaga o indicador do mic e
    /// limpa o pre-roll. No-op se não estava hot ou se há gravação ativa.
    func coolDown() async
}

/// Transcrição de áudio para texto via Parakeet TDT.
protocol Transcribing: Actor {
    func initialize() async throws
    func transcribe(_ samples: [Float]) async throws -> String
    func startLiveTranscription(
        onUpdate: @escaping @Sendable (LiveTranscriptionUpdate) -> Void
    ) async throws -> any LiveTranscriptionSession
}

/// Inserção de texto no app em foco (Cmd+V simulado) e operações de clipboard.
@MainActor
protocol TextInserting {
    @discardableResult
    func insert(_ text: String) async -> Bool
    func copyToClipboard(_ text: String)
    @discardableResult
    func replaceLastPaste(_ newText: String) async -> Bool
}

/// Correção pós-transcrição via LLM local (MLX).
protocol LLMCorrecting: Actor {
    var modelState: LLMCorrectionManager.ModelState { get async }
    var selectedModel: LLMModelOption { get async }
    func setKeepAlive(_ alive: Bool) async
    func selectModel(id: String) async -> LLMCorrectionManager.ModelState
    func downloadModel() async throws
    func downloadProgressSnapshot() async -> LLMDownloadProgressSnapshot?
    func cancelDownloadAndCleanup() async throws
    func loadModel() async throws
    func deleteModel() async throws
    func deleteModel(id: String) async throws
    func modelSizeOnDisk() async -> Int64?
    func cachedModelsOnDisk() async -> [LLMCorrectionManager.CachedModelInfo]
    func correct(
        text: String,
        systemPrompt: String,
        maxTokens: Int,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String
    func translate(
        text: String,
        targetLanguage: String,
        maxTokens: Int,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String
    func translateTerm(
        term: String,
        context: String?,
        targetLanguage: String,
        maxTokens: Int,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String
}

// MARK: - Conformâncias dos tipos concretos

extension AudioCapture: AudioCapturing {}
extension Transcriber: Transcribing {}
extension TextInserter: TextInserting {}
extension LLMCorrectionManager: LLMCorrecting {}

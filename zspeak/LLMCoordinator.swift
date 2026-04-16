import Foundation
import AppKit
import os.log

private let logger = Logger(subsystem: "com.zspeak", category: "LLMCoordinator")

/// Coordena o pipeline de correção pós-transcrição via LLM local.
///
/// Responsabilidades:
/// - Download / load / delete do modelo (via `LLMCorrecting`)
/// - Keep-alive (evita unload durante Modo Prompt)
/// - Aplicação de prompts (arbitrário, clipboard, última transcrição)
/// - Integração com `TextInserter` para substituir o texto já colado
/// - Persistência da correção no histórico (via hook)
///
/// Mantém estado observável:
/// - `isApplyingPrompt` — spinner no overlay
/// - `lastLLMResult` / `lastLLMPromptName` — preview streaming
/// - `lastTranscription` / `lastTranscriptionRecordID` — input do LLM
/// - `errorMessage` — feedback de erro para o overlay
///
/// NÃO conhece o pipeline de gravação nem o de arquivo — quem alimenta
/// `lastTranscription` é o `AppState` (que sincroniza a partir do
/// `RecordingController` e do `FileTranscriptionCoordinator`).
@MainActor
@Observable
final class LLMCoordinator {

    // MARK: - Estado público observável

    /// True enquanto uma correção está sendo aplicada.
    var isApplyingPrompt: Bool = false

    /// Texto parcial recebido do LLM (streaming) ou final.
    var lastLLMResult: String?

    /// Nome do prompt usado na última/atual correção.
    var lastLLMPromptName: String?

    /// Último texto que foi transcrito ou colado — serve de input para o LLM.
    var lastTranscription: String = ""

    /// UUID do record de transcrição linkado ao input — usado como `sourceRecordID`
    /// no novo record criado pela correção.
    var lastTranscriptionRecordID: UUID?

    /// Erro persistido para a UI mostrar. Notifica o façade via callback para
    /// manter uma única fonte de verdade compartilhada com `RecordingController`.
    var errorMessage: String? {
        didSet { onErrorMessageChange?(errorMessage) }
    }

    /// Callback do façade para sincronizar `AppState.errorMessage`.
    var onErrorMessageChange: (@MainActor (String?) -> Void)?

    /// Setado externamente pelo `AppState`.
    var accessibilityGranted: Bool = false

    /// Toggle global — persiste em UserDefaults.
    var llmCorrectionEnabled: Bool = UserDefaults.standard.bool(forKey: "llmCorrectionEnabled") {
        didSet { UserDefaults.standard.set(llmCorrectionEnabled, forKey: "llmCorrectionEnabled") }
    }

    // MARK: - Dependências injetadas

    private let llmManager: any LLMCorrecting
    private let textInserter: any TextInserting

    /// Fornecido pelo `AppState`: acesso ao prompt atualmente ativo no store.
    var activePromptProvider: (@MainActor () -> CorrectionPrompt?)?

    /// Fornecido pelo `AppState`: persiste o record do LLM no histórico,
    /// ligando-o ao record original via `sourceRecordID`.
    var persistLLMResult: (@MainActor (_ text: String, _ modelName: String, _ targetAppName: String?, _ sourceRecordID: UUID?) -> Void)?

    // MARK: - Tasks

    /// Task que aplica o prompt LLM na última transcrição. Cancelada quando o
    /// usuário dispara uma nova aplicação.
    private var llmCorrectionTask: Task<Void, Never>?

    // MARK: - Init

    init(llmManager: any LLMCorrecting, textInserter: any TextInserting) {
        self.llmManager = llmManager
        self.textInserter = textInserter
    }

    // MARK: - Aplicação de prompts

    /// Aplica o prompt ativo (configurado em `CorrectionPromptStore`) na última transcrição.
    func applyPrompt() {
        guard let prompt = activePromptProvider?() else {
            errorMessage = "Nenhum prompt ativo."
            return
        }
        applyPromptToLast(prompt)
    }

    /// Usa o texto atual do clipboard como input do LLM e aplica o prompt ativo.
    func applyPromptFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string) else {
            errorMessage = "Clipboard vazio."
            return
        }
        applyPromptToTextInput(raw)
    }

    /// Aplica o prompt ativo num texto arbitrário fornecido pelo usuário.
    func applyPromptToTextInput(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            errorMessage = "Texto vazio."
            return
        }
        guard let prompt = activePromptProvider?() else {
            errorMessage = "Nenhum prompt ativo."
            return
        }
        // Define como input do LLM — texto colado não tem record de gravação associado
        lastTranscription = text
        lastTranscriptionRecordID = nil
        lastLLMResult = nil
        lastLLMPromptName = nil
        applyPromptToLast(prompt)
    }

    /// Aplica um prompt específico na última transcrição, substituindo o texto colado.
    ///
    /// Se já existe uma correção LLM em andamento, ela é cancelada antes de
    /// iniciar a nova — evita que dois streams compitam pelo `lastLLMResult`
    /// e pelo clipboard.
    func applyPromptToLast(_ prompt: CorrectionPrompt) {
        guard !lastTranscription.isEmpty else {
            errorMessage = "Nenhuma transcrição para processar."
            return
        }

        llmCorrectionTask?.cancel()

        // Re-salva o app em foco atual (pode ter mudado desde a transcrição)
        TextInserter.saveFocusedApp()

        isApplyingPrompt = true
        errorMessage = nil
        lastLLMResult = ""
        lastLLMPromptName = prompt.name
        let originalID = lastTranscriptionRecordID
        let originalText = lastTranscription

        llmCorrectionTask = Task {
            do {
                let corrected = try await llmManager.correct(
                    text: originalText,
                    systemPrompt: prompt.systemPrompt,
                    maxTokens: 384,
                    onPartial: { [weak self] partial in
                        Task { @MainActor in
                            guard let self else { return }
                            guard !Task.isCancelled else { return }
                            self.lastLLMResult = partial
                        }
                    }
                )

                if Task.isCancelled { return }

                let trimmed = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if accessibilityGranted {
                        _ = textInserter.replaceLastPaste(trimmed)
                    } else {
                        textInserter.copyToClipboard(trimmed)
                    }

                    persistLLMResult?(
                        trimmed,
                        "LLM: \(prompt.name)",
                        TextInserter.previousApp?.localizedName,
                        originalID
                    )

                    lastLLMResult = trimmed
                    lastLLMPromptName = prompt.name
                    logger.info("Prompt '\(prompt.name)' aplicado: \(trimmed.count) chars")
                } else {
                    errorMessage = "LLM retornou vazio."
                }
            } catch is CancellationError {
                logger.debug("applyPromptToLast cancelado")
            } catch {
                if !Task.isCancelled {
                    errorMessage = "Erro ao aplicar prompt: \(error.localizedDescription)"
                    logger.error("applyPromptToLast falhou: \(error.localizedDescription)")
                }
            }
            if !Task.isCancelled {
                isApplyingPrompt = false
            }
            llmCorrectionTask = nil
        }
    }

    // MARK: - Gerenciamento do modelo

    func downloadModel() async -> LLMCorrectionManager.ModelState {
        do {
            try await llmManager.downloadModel()
        } catch {
            logger.error("Erro no download do modelo LLM: \(error.localizedDescription)")
        }
        return await llmManager.modelState
    }

    func modelState() async -> LLMCorrectionManager.ModelState {
        await llmManager.modelState
    }

    func loadModel() async -> LLMCorrectionManager.ModelState {
        do {
            try await llmManager.loadModel()
        } catch {
            logger.error("Erro ao carregar modelo LLM: \(error.localizedDescription)")
        }
        return await llmManager.modelState
    }

    /// Pré-carrega em background + ativa keep-alive. Chamado quando Modo Prompt liga.
    func preloadAndKeepAlive() {
        let manager = llmManager
        Task.detached(priority: .userInitiated) {
            await manager.setKeepAlive(true)
            let state = await manager.modelState
            if case .downloaded = state {
                try? await manager.loadModel()
            }
        }
    }

    /// Libera keep-alive. Chamado quando Modo Prompt desliga.
    func releaseKeepAlive() {
        let manager = llmManager
        Task.detached(priority: .utility) {
            await manager.setKeepAlive(false)
        }
    }

    func removeModel() async {
        do {
            try await llmManager.deleteModel()
        } catch {
            logger.error("Erro ao remover modelo LLM: \(error.localizedDescription)")
        }
    }

    func modelSizeOnDisk() async -> Int64? {
        await llmManager.modelSizeOnDisk()
    }
}

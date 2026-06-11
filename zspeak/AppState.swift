import SwiftUI
import AppKit

/// Façade do estado global do app.
///
/// `AppState` não contém mais lógica de negócio: ele instancia os controllers
/// especializados (`RecordingController`, `LLMCoordinator`, `FileTranscriptionCoordinator`)
/// e expõe as mesmas propriedades/métodos que as Views sempre consumiram,
/// delegando internamente. Isso preserva a API pública — `appState.state`,
/// `appState.applyPromptToLast(...)`, etc. continuam funcionando sem mudança
/// nos call sites.
///
/// Responsabilidades que permanecem aqui (escopo pequeno, sem valor em extrair):
/// - Wiring entre controllers (sincronização `lastTranscription` / accessibility)
/// - Configuração dos stores (`TranscriptionStore`, `VocabularyStore`, etc.)
///   — setados externamente por `App.swift`
@MainActor
@Observable
final class AppState {

    // MARK: - Tipos reexportados

    typealias RecordingState = RecordingController.RecordingState

    // MARK: - Controllers

    let recordingController: RecordingController
    let llmCoordinator: LLMCoordinator
    let fileCoordinator: FileTranscriptionCoordinator
    let selectionTranslationCoordinator: SelectionTranslationCoordinator

    // MARK: - Stores externos (setados por App.swift)

    var store: TranscriptionStore? {
        didSet { wireStoreHooks() }
    }
    var benchmarkStore: BenchmarkStore?
    var vocabularyStore: VocabularyStore? {
        didSet { wireVocabularyHook() }
    }
    var correctionPromptStore: CorrectionPromptStore? {
        didSet { wireActivePromptProvider() }
    }
    var promptModeManager: PromptModeManager? {
        didSet { wirePromptModeHook() }
    }
    var diarizationManager: DiarizationManager? {
        didSet { fileCoordinator.diarizationManager = diarizationManager }
    }

    // MARK: - Acessibilidade (sincroniza nos controllers)

    var accessibilityGranted: Bool = false {
        didSet {
            recordingController.accessibilityGranted = accessibilityGranted
            llmCoordinator.accessibilityGranted = accessibilityGranted
            if accessibilityGranted {
                selectionTranslationCoordinator.refreshAmbientLookupEventTap()
            }
        }
    }

    // MARK: - Propriedades espelhadas (API pública preservada)

    var state: RecordingState {
        get { recordingController.state }
        set { recordingController.state = newValue }
    }
    var isRecordingOrPreparing: Bool { recordingController.isRecordingOrPreparing }
    var isModelReady: Bool {
        get { recordingController.isModelReady }
        set { recordingController.isModelReady = newValue }
    }

    var lastTranscription: String {
        get { recordingController.lastTranscription }
        set {
            recordingController.lastTranscription = newValue
            llmCoordinator.lastTranscription = newValue
        }
    }

    var lastTranscriptionRecordID: UUID? {
        get { recordingController.lastTranscriptionRecordID }
        set {
            recordingController.lastTranscriptionRecordID = newValue
            llmCoordinator.lastTranscriptionRecordID = newValue
        }
    }

    /// Fonte única de verdade para mensagens de erro exibidas na UI.
    /// Controllers setam seu próprio `errorMessage` e o didSet deles notifica
    /// o façade (via callback instalado no init) — quem chegou por último ganha.
    /// Setter externo (testes/UI) propaga para ambos controllers, mantendo-os
    /// alinhados.
    var errorMessage: String? {
        didSet {
            guard oldValue != errorMessage else { return }
            // Sincroniza os controllers sem re-disparar didSet → evitar loop:
            // o callback `onErrorMessageChange` só é invocado quando o valor
            // muda lá, e aqui `oldValue != newValue` já foi checado.
            if recordingController.errorMessage != errorMessage {
                recordingController.errorMessage = errorMessage
            }
            if llmCoordinator.errorMessage != errorMessage {
                llmCoordinator.errorMessage = errorMessage
            }
        }
    }

    // LLM — delegam direto
    var isApplyingPrompt: Bool {
        get { llmCoordinator.isApplyingPrompt }
        set { llmCoordinator.isApplyingPrompt = newValue }
    }
    var lastLLMResult: String? {
        get { llmCoordinator.lastLLMResult }
        set { llmCoordinator.lastLLMResult = newValue }
    }
    var lastLLMPromptName: String? {
        get { llmCoordinator.lastLLMPromptName }
        set { llmCoordinator.lastLLMPromptName = newValue }
    }
    var llmCorrectionEnabled: Bool {
        get { llmCoordinator.llmCorrectionEnabled }
        set { llmCoordinator.llmCorrectionEnabled = newValue }
    }

    // Tradução da seleção — delega para o coordenador dedicado
    var isSelectionTranslationVisible: Bool { selectionTranslationCoordinator.isVisible }
    var isTranslatingSelection: Bool { selectionTranslationCoordinator.isTranslating }
    var selectionTranslationSourceText: String { selectionTranslationCoordinator.sourceText }
    var selectionTranslationResult: String? { selectionTranslationCoordinator.translatedText }
    var selectionTranslationAnchor: NSRect? { selectionTranslationCoordinator.anchorRect }
    var selectionTranslationError: String? { selectionTranslationCoordinator.errorMessage }
    var selectionLookupTerm: String? { selectionTranslationCoordinator.selectedLookupTerm }
    var selectionLookupTranslation: String? { selectionTranslationCoordinator.lookupTranslation }
    var isLookingUpSelectionTerm: Bool { selectionTranslationCoordinator.isLookingUpTerm }
    var selectionLookupError: String? { selectionTranslationCoordinator.lookupErrorMessage }
    var selectionTranslationPresentation: SelectionTranslationPresentation { selectionTranslationCoordinator.presentation }
    var isSelectionLookupModeEnabled: Bool { selectionTranslationCoordinator.isAmbientLookupEnabled }

    // MARK: - Dependências compartilhadas

    let microphoneManager: MicrophoneManager

    // Instâncias concretas usadas para compor os controllers; expostas como
    // `private` porque os controllers já atendem o resto do app.
    private let audioCapture: AudioCapture
    private let transcriber: Transcriber
    private let textInserter: TextInserter
    private let llmManager: LLMCorrectionManager
    private let selectedTextReader: SelectedTextReader

    // MARK: - Init

    init(skipBundlePermissionCheck: Bool = false) {
        let micManager = MicrophoneManager(skipBundlePermissionCheck: skipBundlePermissionCheck)
        let audio = AudioCapture()
        let asr = Transcriber()
        let inserter = TextInserter()
        let llm = LLMCorrectionManager()
        let selectionReader = SelectedTextReader()

        self.microphoneManager = micManager
        self.audioCapture = audio
        self.transcriber = asr
        self.textInserter = inserter
        self.llmManager = llm
        self.selectedTextReader = selectionReader

        self.recordingController = RecordingController(
            audioCapture: audio,
            transcriber: asr,
            textInserter: inserter,
            microphoneManager: micManager
        )
        self.llmCoordinator = LLMCoordinator(
            llmManager: llm,
            textInserter: inserter
        )
        self.fileCoordinator = FileTranscriptionCoordinator(
            transcribe: { [asr] samples in
                try await asr.transcribe(samples)
            },
            textInserter: inserter
        )
        self.selectionTranslationCoordinator = SelectionTranslationCoordinator(
            llmManager: llm,
            selectionReader: selectionReader
        )

        // Propagação bidirecional de erro: controller → façade.
        // Setter do façade propaga na direção inversa, com guarda para evitar loop.
        self.recordingController.onErrorMessageChange = { [weak self] newValue in
            guard let self, self.errorMessage != newValue else { return }
            self.errorMessage = newValue
        }
        self.llmCoordinator.onErrorMessageChange = { [weak self] newValue in
            guard let self, self.errorMessage != newValue else { return }
            self.errorMessage = newValue
        }
        self.selectionTranslationCoordinator.onErrorMessageChange = { [weak self] newValue in
            guard let self, self.errorMessage != newValue else { return }
            self.errorMessage = newValue
        }

        // Hook inicial de persistência no RecordingController (pipeline de gravação).
        // `store` começa nil — quando o `App.swift` setar, `wireStoreHooks()` é chamado
        // pelo didSet e os closures finais são instalados. O hook temporário abaixo
        // espelha `lastTranscription` entre controllers mesmo antes do store chegar.
        recordingController.persistTranscription = { [weak self] text, modelName, duration, app, samples in
            self?.persistRecordingRecord(text: text, modelName: modelName, duration: duration, targetAppName: app, samples: samples)
        }
        fileCoordinator.persistTranscription = { [weak self] text, modelName, duration, app, samples in
            self?.persistRecordingRecord(text: text, modelName: modelName, duration: duration, targetAppName: app, samples: samples)
        }
        fileCoordinator.updateSpeakerNamesInStore = { [weak self] id, names in
            self?.store?.updateSpeakerNames(recordID: id, names: names)
        }
        llmCoordinator.persistLLMResult = { [weak self] text, modelName, app, sourceID in
            _ = self?.store?.addRecord(
                text: text,
                modelName: modelName,
                duration: 0,
                targetAppName: app,
                samples: nil,
                sourceRecordID: sourceID
            )
        }
    }

    // MARK: - Hooks com stores externos

    private func wireStoreHooks() {
        // Os closures já capturam `[weak self]` — só precisa revalidar
        // se o store muda após init (ex: testes).
    }

    private func wireVocabularyHook() {
        let replacer: @MainActor (String) -> String = { [weak self] text in
            self?.vocabularyStore?.applyReplacements(to: text) ?? text
        }
        recordingController.applyVocabularyReplacements = replacer
        fileCoordinator.applyVocabularyReplacements = replacer
    }

    private func wireActivePromptProvider() {
        llmCoordinator.activePromptProvider = { [weak self] in
            self?.correctionPromptStore?.activePrompt
        }
    }

    private func wirePromptModeHook() {
        recordingController.shouldDeferInsertionAfterTranscription = { [weak self] in
            self?.promptModeManager?.isEnabled == true
        }
    }

    /// Persiste um record no histórico e sincroniza `lastTranscription`
    /// entre os controllers (para que o LLM possa consumir o texto recém-gravado).
    private func persistRecordingRecord(
        text: String,
        modelName: String,
        duration: Double,
        targetAppName: String?,
        samples: [Float]?
    ) -> UUID? {
        let newID = store?.addRecord(
            text: text,
            modelName: modelName,
            duration: duration,
            targetAppName: targetAppName,
            samples: samples
        )
        // Sincroniza input do LLM
        llmCoordinator.lastTranscription = text
        llmCoordinator.lastTranscriptionRecordID = newID
        return newID
    }

    // MARK: - Inicialização do modelo ASR

    /// Carrega modelo ASR — chamado no startup do app.
    func initialize() async {
        await recordingController.initialize()
        guard isModelReady else { return }

        // Reaplica o vocabulário persistido em background logo após o modelo
        // principal ficar pronto. Se o rescoring nativo falhar, o fallback em
        // Swift continua ativo no pipeline.
        do {
            try await applyVocabulary()
        } catch {
            // Não bloqueia o app na inicialização por falha do vocabulário.
        }
    }

    /// Pré-aquece o `AudioCapture` com o device prioritário atual.
    func warmUpAudioCapture() async {
        await recordingController.warmUpAudioCapture()
    }

    func coolDownAudioCapture() async {
        await recordingController.coolDownAudioCapture()
    }

    // MARK: - Audio level (UI)

    nonisolated func currentAudioLevel() async -> Float {
        await recordingController.currentAudioLevel()
    }

    // MARK: - Transcrição bruta (benchmark / arquivo)

    /// Expõe transcrição para uso externo (benchmark).
    func transcribe(_ samples: [Float]) async throws -> String {
        try await recordingController.transcribe(samples)
    }

    /// Transcreve um arquivo de áudio (qualquer formato suportado).
    func transcribeFile(
        url: URL,
        mode: AudioFileTranscriber.Mode,
        numSpeakers: Int? = nil,
        onProgress: @escaping @MainActor (FileTranscriptionPhase) -> Void
    ) async throws -> FileTranscriptionResult {
        let outcome = try await fileCoordinator.transcribeFile(
            url: url,
            mode: mode,
            numSpeakers: numSpeakers,
            onProgress: onProgress
        )
        // Sincroniza estado do façade com o que o LLM vai consumir
        lastTranscription = outcome.result.text
        lastTranscriptionRecordID = outcome.recordID
        return outcome.result
    }

    func updateSpeakerNames(recordID: UUID, names: [String: String]) {
        fileCoordinator.updateSpeakerNames(recordID: recordID, names: names)
    }

    // MARK: - Toggle de gravação (delegam)

    func toggleRecording() { recordingController.toggleRecording() }
    func startRecordingIfIdle() { recordingController.startRecordingIfIdle() }
    func stopRecordingIfActive() { recordingController.stopRecordingIfActive() }
    func cancelRecording() { recordingController.cancelRecording() }

    // MARK: - LLM (delegam)

    func applyPrompt() { llmCoordinator.applyPrompt() }
    func applyPromptFromClipboard() { llmCoordinator.applyPromptFromClipboard() }
    func applyPromptToTextInput(_ raw: String) { llmCoordinator.applyPromptToTextInput(raw) }
    func applyPromptToLast(_ prompt: CorrectionPrompt) { llmCoordinator.applyPromptToLast(prompt) }

    func translateSelection() { selectionTranslationCoordinator.translateSelection() }
    func toggleSelectionLookupMode() {
        selectionTranslationCoordinator.toggleAmbientLookupEnabled()
    }
    func setSelectionLookupModeEnabled(_ enabled: Bool) {
        selectionTranslationCoordinator.setAmbientLookupEnabled(enabled)
    }

    @discardableResult
    func dismissSelectionTranslation() -> Bool { selectionTranslationCoordinator.dismiss() }

    func selectedLLMModel() async -> LLMModelOption { await llmCoordinator.selectedModel() }
    func selectLLMModel(id: String) async -> LLMCorrectionManager.ModelState { await llmCoordinator.selectModel(id: id) }
    func downloadLLMModel() async -> LLMCorrectionManager.ModelState { await llmCoordinator.downloadModel() }
    func llmDownloadProgressSnapshot() async -> LLMDownloadProgressSnapshot? {
        await llmCoordinator.downloadProgressSnapshot()
    }
    func cancelLLMModelDownload() async { await llmCoordinator.cancelDownloadAndCleanup() }
    func llmModelState() async -> LLMCorrectionManager.ModelState { await llmCoordinator.modelState() }
    func loadLLMModel() async -> LLMCorrectionManager.ModelState { await llmCoordinator.loadModel() }
    func preloadLLMAndKeepAlive() { llmCoordinator.preloadAndKeepAlive() }
    func releaseLLMKeepAlive() { llmCoordinator.releaseKeepAlive() }
    func removeLLMModel() async { await llmCoordinator.removeModel() }
    func removeLLMModel(id: String) async { await llmCoordinator.removeModel(id: id) }
    func llmModelSizeOnDisk() async -> Int64? { await llmCoordinator.modelSizeOnDisk() }
    func cachedLLMModelsOnDisk() async -> [LLMCorrectionManager.CachedModelInfo] {
        await llmCoordinator.cachedModelsOnDisk()
    }

    // MARK: - Vocabulário

    /// Aplica o vocabulário persistido tanto no rescoring nativo do decoder
    /// quanto no fallback em Swift usado pelo pipeline pós-transcrição.
    func applyVocabulary() async throws {
        wireVocabularyHook()

        guard isModelReady else { return }

        let context = vocabularyStore?.buildVocabularyContext()
        try await transcriber.configureVocabulary(context)
    }
}

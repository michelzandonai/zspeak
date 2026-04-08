import SwiftUI

/// Gerencia o overlay flutuante — precisa ser classe para evitar problemas com struct App
@MainActor
final class OverlayController {
    private let panel = OverlayPanel()
    private let appState: AppState
    private let promptModeManager: PromptModeManager
    private let model = OverlayModel()
    private var isShowing = false

    init(appState: AppState, promptModeManager: PromptModeManager) {
        self.appState = appState
        self.promptModeManager = promptModeManager

        // Closure direta: WaveformView lê audioLevel do AudioCapture sem intermediários
        model.getAudioLevel = { [weak appState] in
            await appState?.currentAudioLevel() ?? 0
        }

        // Aplica prompt selecionado na última transcrição
        model.onApplyPrompt = { [weak appState] prompt in
            appState?.applyPromptToLast(prompt)
        }

        // Usa texto do clipboard como input e aplica o prompt ativo (TASK-012)
        model.onPasteAndApply = { [weak appState] in
            appState?.applyPromptFromClipboard()
        }

        // TextField detectou paste — aplica prompt no texto colado (TASK-013)
        model.onTextInputApply = { [weak appState] text in
            appState?.applyPromptToTextInput(text)
        }

        panel.setupContent(model: model)
        startObserving()
        update()
    }

    private func startObserving() {
        withObservationTracking {
            _ = appState.state
            _ = appState.isApplyingPrompt
            _ = appState.lastLLMResult
            _ = appState.lastLLMPromptName
            _ = appState.lastTranscription
            _ = promptModeManager.isEnabled
            _ = appState.correctionPromptStore?.prompts
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
            }
        }
    }

    private var wasPromptModeEnabled: Bool = false
    private var wasApplyingPrompt: Bool = false

    private func update() {
        // Sincroniza modelo in-place — SwiftUI reage via @Observable sem recriar views
        model.state = appState.state
        model.isModelReady = appState.isModelReady
        model.isApplyingPrompt = appState.isApplyingPrompt
        model.promptModeEnabled = promptModeManager.isEnabled
        model.lastLLMResult = appState.lastLLMResult
        model.lastLLMPromptName = appState.lastLLMPromptName
        model.lastTranscription = appState.lastTranscription

        // Detecta transição do Modo Prompt para preload/release do LLM
        if promptModeManager.isEnabled && !wasPromptModeEnabled {
            appState.preloadLLMAndKeepAlive()
        } else if !promptModeManager.isEnabled && wasPromptModeEnabled {
            appState.releaseLLMKeepAlive()
        }
        wasPromptModeEnabled = promptModeManager.isEnabled

        // Borda 'começou a aplicar prompt' → expande LLMResultView automaticamente
        // (TASK-011). Usuário pode colapsar manualmente depois e o estado persiste.
        if appState.isApplyingPrompt && !wasApplyingPrompt {
            model.isResultExpanded = true
        }
        wasApplyingPrompt = appState.isApplyingPrompt

        if let store = appState.correctionPromptStore {
            model.prompts = store.prompts
        }

        if let app = TextInserter.previousApp {
            model.focusedAppName = app.localizedName ?? ""
            model.focusedAppIcon = app.icon
        }
        model.microphoneName = appState.microphoneManager.activeMicrophoneName

        // Nota: o tamanho do panel é auto-ajustado via KVO em OverlayPanel
        // (NSHostingController.preferredContentSize → adjustToPreferredSize)

        // Show/hide: visível durante gravação/processamento OU se modo prompt ativo
        let shouldShow = appState.state == .recording
            || appState.state == .processing
            || promptModeManager.isEnabled

        if shouldShow && !isShowing {
            panel.show()
            isShowing = true
        } else if !shouldShow && isShowing {
            panel.hide()
            isShowing = false
        }

        // Re-registrar observação (withObservationTracking é one-shot)
        startObserving()
    }
}

/// Ponto de entrada do zspeak — app de transcrição por voz local
@main
struct ZSpeakApp: App {

    @State private var appState = AppState()
    @State private var store = TranscriptionStore()
    @State private var benchmarkStore = BenchmarkStore()
    @State private var vocabularyStore = VocabularyStore()
    @State private var correctionPromptStore = CorrectionPromptStore()
    @State private var promptModeManager = PromptModeManager()
    private let diarizationManager = DiarizationManager()
    private let activationKeyManager = ActivationKeyManager()
    private let accessibilityManager = AccessibilityManager()
    private let hotkeyManager: HotkeyManager
    /// Retém referência estática para evitar desalocação por ARC
    nonisolated(unsafe) private static var overlayController: OverlayController?

    var body: some Scene {
        // App vive exclusivamente no menu bar (sem janela principal)
        MenuBarExtra {
            MenuBarView(appState: appState, activationKeyManager: activationKeyManager, accessibilityManager: accessibilityManager, store: store, benchmarkStore: benchmarkStore, vocabularyStore: vocabularyStore, correctionPromptStore: correctionPromptStore, promptModeManager: promptModeManager)
        } label: {
            Image(systemName: menuBarIcon)
                .symbolRenderingMode(.palette)
        }

        // Janela de configurações
        Settings {
            let mgr = appState.microphoneManager
            SettingsView(appState: appState, microphoneManager: mgr, activationKeyManager: activationKeyManager, accessibilityManager: accessibilityManager, store: store, benchmarkStore: benchmarkStore, vocabularyStore: vocabularyStore, correctionPromptStore: correctionPromptStore)
        }
    }

    /// Ícone do menu bar baseado no estado atual
    private var menuBarIcon: String {
        switch appState.state {
        case .idle:
            return "mic"
        case .recording:
            return "mic.fill"
        case .processing:
            return "waveform"
        }
    }

    init() {
        let keyManager = activationKeyManager
        self.hotkeyManager = HotkeyManager(activationKeyManager: keyManager)
        let state = appState
        let promptMode = promptModeManager

        // Conecta stores ao AppState
        state.store = store
        state.benchmarkStore = benchmarkStore
        state.vocabularyStore = vocabularyStore
        state.correctionPromptStore = correctionPromptStore
        state.promptModeManager = promptMode
        state.diarizationManager = diarizationManager
        benchmarkStore.importFromHistory(historyStore: store)

        // Sincroniza estado inicial de Accessibility com AppState
        state.accessibilityGranted = accessibilityManager.isGranted

        // Configura callbacks para manter AppState sincronizado com permissão de Accessibility
        let hotkey = hotkeyManager
        accessibilityManager.onPermissionGranted = { [hotkey] in
            state.accessibilityGranted = true
            hotkey.recreateEventTap()
        }
        accessibilityManager.onPermissionRevoked = {
            state.accessibilityGranted = false
        }

        // Solicita permissão de Accessibility no startup (abre prompt do sistema)
        if !accessibilityManager.isGranted {
            accessibilityManager.requestPermission()
        }

        // Injeta PromptModeManager no HotkeyManager para o atalho de toggle e ESC
        hotkeyManager.promptModeManager = promptMode

        // Configura hotkey global com 4 callbacks para suportar toggle/hold/doubleTap
        hotkeyManager.setup(
            onToggle: { state.toggleRecording() },
            onStartRecording: { state.startRecordingIfIdle() },
            onStopRecording: { state.stopRecordingIfActive() },
            onCancelRecording: { state.cancelRecording() }
        )

        // Carrega modelos no startup
        Task {
            await state.initialize()
        }

        // Cria overlay controller e retém referência estática para evitar desalocação por ARC
        Self.overlayController = OverlayController(appState: state, promptModeManager: promptMode)
    }
}

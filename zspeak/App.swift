import SwiftUI

/// Gerencia o overlay flutuante — precisa ser classe para evitar problemas com struct App
@MainActor
final class OverlayController {
    private let panel = OverlayPanel()
    private let appState: AppState
    private let model = OverlayModel()
    private var isShowing = false
    private var dismissTimer: Timer?

    init(appState: AppState) {
        self.appState = appState
        // Closure direta: WaveformView lê audioLevel do AudioCapture sem intermediários
        model.getAudioLevel = { [weak appState] in
            await appState?.currentAudioLevel() ?? 0
        }

        // Callbacks para ações do overlay
        model.onApplyPrompt = { [weak appState] in
            appState?.applyPrompt()
        }
        model.onSwitchAndApplyPrompt = { [weak appState] prompt in
            appState?.correctionPromptStore?.setActive(prompt)
            appState?.applyPromptWithSpecific(prompt)
        }
        model.onDismissPromptReady = { [weak appState] in
            appState?.dismissPromptReady()
        }

        panel.setupContent(model: model)
        startObserving()
    }

    private func startObserving() {
        withObservationTracking {
            _ = appState.state
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
            }
        }
    }

    private func update() {
        // Atualiza modelo in-place — SwiftUI reage via @Observable sem recriar views
        model.state = appState.state
        model.isModelReady = appState.isModelReady

        // Atualiza ícone/nome do app em foco
        if let app = TextInserter.previousApp {
            model.focusedAppName = app.localizedName ?? ""
            model.focusedAppIcon = app.icon
        }

        // Nome do microfone ativo (do MicrophoneManager ou default)
        model.microphoneName = appState.microphoneManager.activeMicrophoneName

        // Sincronizar prompts LLM
        if let store = appState.correctionPromptStore {
            model.prompts = store.prompts
            model.activePromptName = store.activePrompt?.name ?? ""
        }

        switch appState.state {
        case .recording, .processing, .applyingPrompt:
            dismissTimer?.invalidate()
            dismissTimer = nil
            if !isShowing {
                panel.show()
                isShowing = true
            }
        case .promptReady:
            if !isShowing {
                panel.show()
                isShowing = true
            }
            // Timer de auto-dismiss 4s
            dismissTimer?.invalidate()
            dismissTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.appState.dismissPromptReady()
                }
            }
        case .idle:
            dismissTimer?.invalidate()
            dismissTimer = nil
            if isShowing {
                panel.hide()
                isShowing = false
            }
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
    private let activationKeyManager = ActivationKeyManager()
    private let accessibilityManager = AccessibilityManager()
    private let hotkeyManager: HotkeyManager
    /// Retém referência estática para evitar desalocação por ARC
    nonisolated(unsafe) private static var overlayController: OverlayController?

    var body: some Scene {
        // App vive exclusivamente no menu bar (sem janela principal)
        MenuBarExtra {
            MenuBarView(appState: appState, activationKeyManager: activationKeyManager, accessibilityManager: accessibilityManager, store: store, benchmarkStore: benchmarkStore, vocabularyStore: vocabularyStore, correctionPromptStore: correctionPromptStore)
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
        case .promptReady:
            return "sparkles"
        case .applyingPrompt:
            return "waveform"
        }
    }

    init() {
        let keyManager = activationKeyManager
        self.hotkeyManager = HotkeyManager(activationKeyManager: keyManager)
        let state = appState

        // Conecta stores ao AppState
        state.store = store
        state.benchmarkStore = benchmarkStore
        state.vocabularyStore = vocabularyStore
        state.correctionPromptStore = correctionPromptStore
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

        // Configura hotkey global com 4 callbacks para suportar toggle/hold/doubleTap
        hotkeyManager.setup(
            onToggle: { state.toggleRecording() },
            onStartRecording: { state.startRecordingIfIdle() },
            onStopRecording: { state.stopRecordingIfActive() },
            onCancelRecording: { state.cancelRecording() }
        )

        // Hotkey de aplicar prompt LLM
        hotkeyManager.onApplyPrompt = {
            TextInserter.saveFocusedApp()
            state.applyPrompt()
        }

        // Carrega modelos no startup
        Task {
            await state.initialize()
        }

        // Cria overlay controller e retém referência estática para evitar desalocação por ARC
        Self.overlayController = OverlayController(appState: state)
    }
}

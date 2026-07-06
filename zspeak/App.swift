import SwiftUI
import AppKit

/// Gerencia o overlay flutuante — precisa ser classe para evitar problemas com struct App
@MainActor
final class OverlayController {
    private let panel = OverlayPanel()
    private let appState: AppState
    private let promptModeManager: PromptModeManager
    private let activationKeyManager: ActivationKeyManager?
    private let model = OverlayModel()
    private var isShowing = false
    private var lastAutoAppliedPromptKey: String?

    init(
        appState: AppState,
        promptModeManager: PromptModeManager,
        activationKeyManager: ActivationKeyManager? = nil
    ) {
        self.appState = appState
        self.promptModeManager = promptModeManager
        self.activationKeyManager = activationKeyManager

        // Closure direta: WaveformView lê audioLevel do AudioCapture sem intermediários
        model.getAudioLevel = { [weak appState] in
            await appState?.currentAudioLevel() ?? 0
        }

        // Aplica prompt selecionado na última transcrição
        model.onApplyPrompt = { [weak appState] prompt in
            appState?.applyPromptToLast(prompt)
        }

        model.onPromptSelected = { [weak self] prompt in
            self?.applyPromptFromSelection(prompt)
        }

        // Usa texto do clipboard como input e aplica o prompt ativo (TASK-012)
        model.onPasteAndApply = { [weak appState] in
            appState?.applyPromptFromClipboard()
        }

        // TextField detectou paste — aplica prompt no texto colado (TASK-013)
        model.onTextInputApply = { [weak appState] text in
            appState?.applyPromptToTextInput(text)
        }

        model.onDismissTranslation = { [weak appState] in
            appState?.dismissSelectionTranslation()
        }

        panel.setupContent(model: model)
        update()
    }

    private func startObserving() {
        withObservationTracking {
            _ = appState.state
            _ = appState.recordingStartedAt
            _ = appState.isApplyingPrompt
            _ = appState.lastLLMResult
            _ = appState.lastLLMPromptName
            _ = appState.lastTranscription
            _ = appState.liveTranscriptionPreview
            _ = appState.lastTranscriptionRecordID
            _ = appState.errorMessage
            _ = appState.isSelectionTranslationVisible
            _ = appState.isTranslatingSelection
            _ = appState.selectionTranslationSourceText
            _ = appState.selectionTranslationResult
            _ = appState.selectionTranslationAnchor
            _ = appState.selectionTranslationError
            _ = appState.selectionTranslationPresentation
            _ = appState.selectionLookupTerm
            _ = appState.selectionLookupTranslation
            _ = appState.isLookingUpSelectionTerm
            _ = appState.selectionLookupError
            _ = appState.isSelectionLookupModeEnabled
            _ = promptModeManager.isEnabled
            _ = appState.correctionPromptStore?.prompts
            _ = activationKeyManager?.escapeToCancel
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
        model.recordingStartedAt = appState.recordingStartedAt
        model.isModelReady = appState.isModelReady
        model.isApplyingPrompt = appState.isApplyingPrompt
        model.promptModeEnabled = promptModeManager.isEnabled
        model.lastLLMResult = appState.lastLLMResult
        model.lastLLMPromptName = appState.lastLLMPromptName
        model.lastTranscription = appState.lastTranscription
        model.liveTranscriptionPreview = appState.liveTranscriptionPreview
        model.errorMessage = appState.errorMessage
        model.translationVisible = appState.isSelectionTranslationVisible
        model.isTranslatingSelection = appState.isTranslatingSelection
        model.selectionTranslationSourceText = appState.selectionTranslationSourceText
        model.selectionTranslationResult = appState.selectionTranslationResult
        model.selectionTranslationError = appState.selectionTranslationError
        model.selectionTranslationPresentation = appState.selectionTranslationPresentation
        model.selectionLookupTerm = appState.selectionLookupTerm
        model.selectionLookupTranslation = appState.selectionLookupTranslation
        model.isLookingUpSelectionTerm = appState.isLookingUpSelectionTerm
        model.selectionLookupError = appState.selectionLookupError

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
            let selectedStillExists: Bool
            if let selectedPromptID = model.selectedPromptID {
                selectedStillExists = store.prompts.contains(where: { $0.id == selectedPromptID })
            } else {
                selectedStillExists = false
            }
            if !selectedStillExists {
                model.selectedPromptID = store.activePrompt?.id ?? store.prompts.first?.id
            }
        }

        if let app = TextInserter.previousApp {
            model.focusedAppName = app.localizedName ?? ""
            model.focusedAppIcon = app.icon
        }
        model.microphoneName = appState.microphoneManager.activeMicrophoneName
        model.microphoneManager = appState.microphoneManager
        model.escHintEnabled = activationKeyManager?.escapeToCancel ?? true

        // Nota: o tamanho do panel é auto-ajustado via KVO em OverlayPanel
        // (NSHostingController.preferredContentSize → adjustToPreferredSize)

        // Show/hide: visível durante preparação/gravação/processamento OU se modo prompt ativo.
        // Inclui `.preparing` para feedback imediato no press da hotkey (overlay
        // aparece com spinner antes do engine capturar o 1º sample).
        let shouldShow = appState.state == .preparing
            || appState.state == .recording
            || appState.state == .processing
            || promptModeManager.isEnabled
            || appState.isSelectionTranslationVisible

        if shouldShow && !isShowing {
            panel.show(near: appState.isSelectionTranslationVisible ? appState.selectionTranslationAnchor : nil)
            isShowing = true
        } else if shouldShow && isShowing, appState.isSelectionTranslationVisible,
                  let anchor = appState.selectionTranslationAnchor {
            panel.moveNear(anchor)
        } else if shouldShow && isShowing, !appState.isSelectionTranslationVisible {
            panel.clearTransientAnchor()
        } else if !shouldShow && isShowing {
            panel.hide()
            isShowing = false
        }

        autoApplyPromptIfNeeded()

        // Re-registrar observação (withObservationTracking é one-shot)
        startObserving()
    }

    private func autoApplyPromptIfNeeded() {
        guard promptModeManager.isEnabled else { return }
        guard appState.state == .idle else { return }
        guard !appState.isApplyingPrompt else { return }
        guard !appState.lastTranscription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let prompt = model.selectedPrompt else { return }

        let key = autoApplyKey(prompt: prompt)
        guard key != lastAutoAppliedPromptKey else { return }
        lastAutoAppliedPromptKey = key
        appState.applyPromptToLast(prompt)
    }

    private func applyPromptFromSelection(_ prompt: CorrectionPrompt) {
        guard promptModeManager.isEnabled else { return }
        guard appState.state == .idle else { return }
        guard !appState.isApplyingPrompt else { return }
        guard !appState.lastTranscription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        lastAutoAppliedPromptKey = autoApplyKey(prompt: prompt)
        appState.applyPromptToLast(prompt)
    }

    private func autoApplyKey(prompt: CorrectionPrompt) -> String {
        let source = appState.lastTranscriptionRecordID?.uuidString ?? appState.lastTranscription
        return "\(prompt.id.uuidString)|\(source)"
    }
}

/// Ponto de entrada do zspeak — app de transcrição por voz local
@main
struct ZSpeakApp: App {

    @NSApplicationDelegateAdaptor(ZSpeakAppDelegate.self) private var appDelegate
    @State private var appState: AppState
    @State private var store: TranscriptionStore
    @State private var benchmarkStore: BenchmarkStore
    @State private var vocabularyStore: VocabularyStore
    @State private var correctionPromptStore: CorrectionPromptStore
    @State private var promptModeManager: PromptModeManager
    private let diarizationManager: DiarizationManager
    private let activationKeyManager: ActivationKeyManager
    private let accessibilityManager: AccessibilityManager
    private let hotkeyManager: HotkeyManager
    /// Retém referência estática para evitar desalocação por ARC
    nonisolated(unsafe) private static var overlayController: OverlayController?
    nonisolated(unsafe) private static var settingsWindowController: SettingsWindowController?
    nonisolated(unsafe) private static var audioFileWindowController: AudioFileWindowController?
    nonisolated(unsafe) private static var statusItemController: StatusItemController?

    var body: some Scene {
        // Mantém um Scene de Settings apenas para o menu do app. As janelas reais
        // são controladas por NSWindowController em AppLifecycle.swift para evitar
        // que o macOS abra "Transcrever arquivo" automaticamente no launch.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Configurações...") {
                    Self.settingsWindowController?.show(initialPage: .overview)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }

    init() {
        _appState = State(initialValue: AppState())
        _store = State(initialValue: TranscriptionStore())
        _benchmarkStore = State(initialValue: BenchmarkStore())
        _vocabularyStore = State(initialValue: VocabularyStore())
        _correctionPromptStore = State(initialValue: CorrectionPromptStore())
        _promptModeManager = State(initialValue: PromptModeManager())
        self.diarizationManager = DiarizationManager()
        self.activationKeyManager = ActivationKeyManager()
        self.accessibilityManager = AccessibilityManager()

        let keyManager = activationKeyManager
        self.hotkeyManager = HotkeyManager(activationKeyManager: keyManager)
        let state = appState
        let promptMode = promptModeManager
        let transcriptions = store
        let benchmarks = benchmarkStore
        let vocabulary = vocabularyStore
        let correctionPrompts = correctionPromptStore
        let activation = activationKeyManager
        let accessibility = accessibilityManager

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
            onCancelRecording: {
                if !state.dismissSelectionTranslation() {
                    state.cancelRecording()
                }
            },
            onTranslateSelection: { state.translateSelection() },
            onToggleSelectionLookupMode: { state.toggleSelectionLookupMode() }
        )

        // Carrega modelos no startup
        Task {
            await state.initialize()
        }

        // Cria overlay controller e retém referência estática para evitar desalocação por ARC
        Self.overlayController = OverlayController(
            appState: state,
            promptModeManager: promptMode,
            activationKeyManager: activation
        )

        // Cria o status item somente depois do AppKit finalizar o launch.
        // Isso evita crash/intermitência ao tocar em NSApplication ou NSStatusBar no init do SwiftUI App.
        ZSpeakAppDelegate.onDidFinishLaunching = {
            let settingsController = SettingsWindowController(
                appState: state,
                activationKeyManager: activation,
                accessibilityManager: accessibility,
                store: transcriptions,
                benchmarkStore: benchmarks,
                vocabularyStore: vocabulary,
                correctionPromptStore: correctionPrompts,
                promptModeManager: promptMode
            )
            let audioFileController = AudioFileWindowController(appState: state, store: transcriptions)
            let statusController = StatusItemController(
                appState: state,
                store: transcriptions,
                promptModeManager: promptMode,
                accessibilityManager: accessibility,
                settingsWindowController: settingsController,
                audioFileWindowController: audioFileController
            )

            Self.settingsWindowController = settingsController
            Self.audioFileWindowController = audioFileController
            Self.statusItemController = statusController
            StartupWindowPresenter(showSettings: { page in
                settingsController.show(initialPage: page)
            })
            .showInitialWindow()
        }
    }
}

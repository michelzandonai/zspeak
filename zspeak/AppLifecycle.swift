import AppKit
import SwiftUI

@MainActor
struct AppAppearanceInstaller {
    private let applyAppearance: (NSAppearance?) -> Void

    init(applyAppearance: @escaping (NSAppearance?) -> Void) {
        self.applyAppearance = applyAppearance
    }

    static var live: AppAppearanceInstaller {
        AppAppearanceInstaller { appearance in
            NSApplication.shared.appearance = appearance
        }
    }

    func applyDarkAquaAppearance() {
        applyAppearance(NSAppearance(named: .darkAqua))
    }
}

@MainActor
struct AppDockIconInstaller {
    private let setActivationPolicy: (NSApplication.ActivationPolicy) -> Bool

    init(setActivationPolicy: @escaping (NSApplication.ActivationPolicy) -> Bool) {
        self.setActivationPolicy = setActivationPolicy
    }

    static var live: AppDockIconInstaller {
        AppDockIconInstaller { policy in
            NSApplication.shared.setActivationPolicy(policy)
        }
    }

    func showDockIcon() {
        _ = setActivationPolicy(.regular)
    }
}

@MainActor
final class ZSpeakAppDelegate: NSObject, NSApplicationDelegate {
    static var onDidFinishLaunching: (() -> Void)?

    private let appearanceInstaller: AppAppearanceInstaller
    private let dockIconInstaller: AppDockIconInstaller

    override convenience init() {
        self.init(appearanceInstaller: .live, dockIconInstaller: .live)
    }

    init(
        appearanceInstaller: AppAppearanceInstaller,
        dockIconInstaller: AppDockIconInstaller = .live
    ) {
        self.appearanceInstaller = appearanceInstaller
        self.dockIconInstaller = dockIconInstaller
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appearanceInstaller.applyDarkAquaAppearance()
        dockIconInstaller.showDockIcon()
        Self.onDidFinishLaunching?()
    }
}

@MainActor
struct StartupWindowPresenter {
    private let showSettings: (SettingsPage) -> Void

    init(showSettings: @escaping (SettingsPage) -> Void) {
        self.showSettings = showSettings
    }

    func showInitialWindow() {
        showSettings(.overview)
    }
}

@MainActor
struct SettingsWindowPresenter {
    private let setInitialPage: (String) -> Void
    private let showDockIcon: () -> Void
    private let activateApplication: () -> Void
    private let showWindow: () -> Void

    init(
        setInitialPage: @escaping (String) -> Void,
        showDockIcon: @escaping () -> Void = {},
        activateApplication: @escaping () -> Void,
        showWindow: @escaping () -> Void
    ) {
        self.setInitialPage = setInitialPage
        self.showDockIcon = showDockIcon
        self.activateApplication = activateApplication
        self.showWindow = showWindow
    }

    func show(_ page: SettingsPage) {
        setInitialPage(page.rawValue)
        showDockIcon()
        activateApplication()
        showWindow()
    }
}

@MainActor
final class SettingsWindowController {
    private let appState: AppState
    private let activationKeyManager: ActivationKeyManager
    private let accessibilityManager: AccessibilityManager
    private let store: TranscriptionStore
    private let benchmarkStore: BenchmarkStore
    private let vocabularyStore: VocabularyStore
    private let correctionPromptStore: CorrectionPromptStore
    private let promptModeManager: PromptModeManager
    private var window: NSWindow?
    private lazy var presenter = SettingsWindowPresenter(
        setInitialPage: { page in
            UserDefaults.standard.set(page, forKey: "settings.initialPage")
        },
        showDockIcon: {
            NSApp.setActivationPolicy(.regular)
        },
        activateApplication: {
            NSApp.activate(ignoringOtherApps: true)
        },
        showWindow: { [weak self] in
            self?.showWindow()
        }
    )

    init(
        appState: AppState,
        activationKeyManager: ActivationKeyManager,
        accessibilityManager: AccessibilityManager,
        store: TranscriptionStore,
        benchmarkStore: BenchmarkStore,
        vocabularyStore: VocabularyStore,
        correctionPromptStore: CorrectionPromptStore,
        promptModeManager: PromptModeManager
    ) {
        self.appState = appState
        self.activationKeyManager = activationKeyManager
        self.accessibilityManager = accessibilityManager
        self.store = store
        self.benchmarkStore = benchmarkStore
        self.vocabularyStore = vocabularyStore
        self.correctionPromptStore = correctionPromptStore
        self.promptModeManager = promptModeManager
    }

    func show(initialPage: SettingsPage = .overview) {
        presenter.show(initialPage)
    }

    private func showWindow() {
        if window == nil {
            let content = SettingsView()
                .preferredColorScheme(.dark)
                .environment(appState)
                .environment(appState.microphoneManager)
                .environment(activationKeyManager)
                .environment(accessibilityManager)
                .environment(store)
                .environment(benchmarkStore)
                .environment(vocabularyStore)
                .environment(correctionPromptStore)
                .environment(promptModeManager)

            let hostingController = NSHostingController(rootView: content)
            let settingsWindow = NSWindow(contentViewController: hostingController)
            settingsWindow.title = "Configurações"
            settingsWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            settingsWindow.setContentSize(NSSize(width: 920, height: 640))
            settingsWindow.center()
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.standardWindowButton(.miniaturizeButton)?.isHidden = true
            settingsWindow.standardWindowButton(.zoomButton)?.isHidden = true
            window = settingsWindow
        }

        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class AudioFileWindowController {
    private let appState: AppState
    private let store: TranscriptionStore
    private var window: NSWindow?

    init(appState: AppState, store: TranscriptionStore) {
        self.appState = appState
        self.store = store
    }

    func show() {
        if window == nil {
            let content = AudioFileWindowContent()
                .preferredColorScheme(.dark)
                .environment(appState)
                .environment(store)

            let hostingController = NSHostingController(rootView: content)
            let audioFileWindow = NSWindow(contentViewController: hostingController)
            audioFileWindow.title = "Transcrever arquivo"
            audioFileWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            audioFileWindow.setContentSize(NSSize(width: 720, height: 580))
            audioFileWindow.center()
            audioFileWindow.isReleasedWhenClosed = false
            window = audioFileWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let appState: AppState
    private let store: TranscriptionStore
    private let promptModeManager: PromptModeManager
    private let accessibilityManager: AccessibilityManager
    private let settingsWindowController: SettingsWindowController
    private let audioFileWindowController: AudioFileWindowController
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    /// Mini-overlay do modo tray — mostra o conteúdo completo da transcrição
    /// logo abaixo da barra de menu (o item só comporta a cauda truncada).
    private let infoPanel = TrayInfoOverlayPanel()

    init(
        appState: AppState,
        store: TranscriptionStore,
        promptModeManager: PromptModeManager,
        accessibilityManager: AccessibilityManager,
        settingsWindowController: SettingsWindowController,
        audioFileWindowController: AudioFileWindowController
    ) {
        self.appState = appState
        self.store = store
        self.promptModeManager = promptModeManager
        self.accessibilityManager = accessibilityManager
        self.settingsWindowController = settingsWindowController
        self.audioFileWindowController = audioFileWindowController
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        menu.delegate = self
        // Sem isto, o AppKit re-habilita itens com action+target e ignora o
        // `isEnabled = false` de "Iniciar Gravação"/"Transcrever arquivo..."
        // enquanto o modelo ainda carrega.
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateButton()
        startObserving()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func startObserving() {
        withObservationTracking {
            _ = appState.state
            _ = appState.isModelReady
            _ = appState.microphoneManager.permissionState
            // Modo compacto: o texto ao vivo aparece no próprio item do tray.
            _ = appState.liveTranscriptionPreview
            // Modo Prompt esconde o mini-overlay (overlay grande em cena).
            _ = promptModeManager.isEnabled
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateButton()
                self?.startObserving()
            }
        }
    }

    private func updateButton() {
        let trayModeEnabled = TrayLivePreview.isEnabled()
        let infoOverlayVisible = TrayInfoOverlay.isVisible(
            state: appState.state,
            trayModeEnabled: trayModeEnabled,
            promptModeActive: promptModeManager.isEnabled
        )

        // Com o mini-overlay em cena o texto já aparece logo abaixo da barra —
        // o item do tray fica no selo compacto (ZS + indicador de estado) em
        // vez de expandir e duplicar o conteúdo.
        let itemPresentation = infoOverlayVisible
            ? TrayLivePreview.compactBadge(state: appState.state)
            : TrayLivePreview.presentation(
                state: appState.state,
                previewText: appState.liveTranscriptionPreview,
                enabled: trayModeEnabled,
                maxWidth: TrayLivePreview.maxWidth()
            )
        TrayLivePreview.apply(itemPresentation, to: statusItem)
        statusItem.button?.toolTip = statusText

        // Mini-overlay sob a barra de menu com o conteúdo COMPLETO.
        if infoOverlayVisible {
            infoPanel.present(
                TrayLivePreview.presentation(
                    state: appState.state,
                    previewText: appState.liveTranscriptionPreview,
                    enabled: trayModeEnabled,
                    maxWidth: TrayLivePreview.maxWidth()
                ),
                anchoredTo: statusItem.button
            )
        } else {
            infoPanel.dismiss()
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        addItem(title: statusText, symbolName: statusIconName, enabled: false)
        menu.addItem(.separator())

        if promptModeManager.isEnabled {
            addItem(title: "Modo Prompt LLM: ATIVO", symbolName: "sparkles", enabled: false)
        }

        if appState.isSelectionLookupModeEnabled {
            addItem(title: "Modo Tradução: ATIVO", symbolName: "text.magnifyingglass", enabled: false)
        }

        addItem(
            title: promptModeManager.isEnabled ? "Desligar Modo Prompt" : "Ligar Modo Prompt",
            symbolName: "sparkles",
            action: #selector(togglePromptMode)
        )
        addItem(
            title: appState.isSelectionLookupModeEnabled ? "Desligar Modo Tradução" : "Ligar Modo Tradução",
            symbolName: "text.magnifyingglass",
            action: #selector(toggleSelectionLookupMode)
        )

        if appState.microphoneManager.permissionState != .authorized {
            addItem(title: microphonePermissionTitle, symbolName: "mic.slash", enabled: false)

            if appState.microphoneManager.permissionState != .notDetermined {
                addItem(
                    title: "Configurar Microfone...",
                    symbolName: "gearshape",
                    action: #selector(openPermissionsSettings)
                )
            }
        }

        if !accessibilityManager.isGranted {
            addItem(title: "Acessibilidade ausente: sem colagem automática", symbolName: "exclamationmark.triangle", enabled: false)
            addItem(
                title: "Configurar Acessibilidade...",
                symbolName: "gearshape",
                action: #selector(openPermissionsSettings)
            )
        }

        menu.addItem(.separator())

        addItem(
            title: appState.isRecordingOrPreparing ? "Parar Gravação" : "Iniciar Gravação",
            symbolName: appState.isRecordingOrPreparing ? "stop.fill" : "mic.fill",
            action: #selector(toggleRecording),
            enabled: appState.state != .processing && appState.isModelReady,
            keyEquivalent: "r"
        )

        menu.addItem(.separator())

        if let lastRecord = store.records.first {
            addItem(title: "Última transcrição:", enabled: false)
            addCopyItem(text: lastRecord.text)
            menu.addItem(.separator())
        } else if !appState.lastTranscription.isEmpty {
            addItem(title: "Última transcrição:", enabled: false)
            addCopyItem(text: appState.lastTranscription)
            menu.addItem(.separator())
        }

        if let error = appState.errorMessage {
            addItem(title: error, symbolName: "exclamationmark.triangle", enabled: false)
            menu.addItem(.separator())
        }

        addItem(
            title: "Transcrever arquivo...",
            symbolName: "waveform.badge.plus",
            action: #selector(openAudioFileWindow),
            enabled: appState.isModelReady,
            keyEquivalent: "T"
        )

        addItem(
            title: "Configurações...",
            symbolName: "gearshape",
            action: #selector(openSettings),
            keyEquivalent: ","
        )

        addItem(
            title: "Sair",
            symbolName: "power",
            action: #selector(quit),
            keyEquivalent: "q"
        )
    }

    private func addItem(
        title: String,
        symbolName: String? = nil,
        action: Selector? = nil,
        enabled: Bool = true,
        keyEquivalent: String = ""
    ) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = action == nil ? nil : self
        item.isEnabled = enabled
        if let symbolName {
            item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        }
        menu.addItem(item)
    }

    private func addCopyItem(text: String) {
        let truncatedText = text.prefix(100) + (text.count > 100 ? "..." : "")
        let item = NSMenuItem(title: String(truncatedText), action: #selector(copyTranscription(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = text
        menu.addItem(item)
    }

    @objc private func togglePromptMode() {
        promptModeManager.toggle()
        rebuildMenu()
    }

    @objc private func toggleSelectionLookupMode() {
        appState.toggleSelectionLookupMode()
        rebuildMenu()
    }

    @objc private func toggleRecording() {
        appState.toggleRecording()
        updateButton()
        rebuildMenu()
    }

    @objc private func copyTranscription(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openAudioFileWindow() {
        audioFileWindowController.show()
    }

    @objc private func openSettings() {
        settingsWindowController.show(initialPage: .overview)
    }

    @objc private func openPermissionsSettings() {
        settingsWindowController.show(initialPage: .permissions)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private var statusIconName: String {
        switch appState.state {
        case .idle:
            return appState.isModelReady ? "checkmark.circle.fill" : "hourglass"
        case .preparing:
            return "mic.badge.plus"
        case .recording:
            return "mic.fill"
        case .processing:
            return "waveform"
        }
    }

    private var statusText: String {
        if appState.microphoneManager.permissionState != .authorized { return microphonePermissionTitle }
        if !appState.isModelReady { return "Carregando modelo..." }
        switch appState.state {
        case .idle: return "Pronto"
        case .preparing: return "Preparando..."
        case .recording: return "Gravando..."
        case .processing: return "Transcrevendo..."
        }
    }

    private var microphonePermissionTitle: String {
        switch appState.microphoneManager.permissionState {
        case .unavailable:
            return "Build sem acesso ao microfone"
        case .notDetermined:
            return "Permissão de microfone pendente"
        case .denied, .restricted:
            return "Microfone necessário"
        case .authorized:
            return "Pronto"
        }
    }
}

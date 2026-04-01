import SwiftUI

/// Gerencia o overlay flutuante — precisa ser classe para evitar problemas com struct App
@MainActor
final class OverlayController {
    private let panel = OverlayPanel()
    private let appState: AppState
    private let model = OverlayModel()
    private var isShowing = false

    init(appState: AppState) {
        self.appState = appState
        panel.setupContent(model: model)
        startObserving()
    }

    private func startObserving() {
        withObservationTracking {
            _ = appState.state
            _ = appState.audioLevel
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
            }
        }
    }

    private func update() {
        // Atualiza modelo in-place — SwiftUI reage via @Observable sem recriar views
        model.state = appState.state
        model.audioLevel = appState.audioLevel
        model.isModelReady = appState.isModelReady

        switch appState.state {
        case .recording, .processing:
            if !isShowing {
                panel.show()
                isShowing = true
            }
        case .idle:
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
    private let hotkeyManager = HotkeyManager()
    /// Retém referência estática para evitar desalocação por ARC
    nonisolated(unsafe) private static var overlayController: OverlayController?

    var body: some Scene {
        // App vive exclusivamente no menu bar (sem janela principal)
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(systemName: menuBarIcon)
                .symbolRenderingMode(.palette)
        }

        // Janela de configurações
        Settings {
            SettingsView(appState: appState)
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
        let state = appState

        // Solicita permissão de Accessibility no startup (abre prompt do sistema)
        TextInserter.requestAccessibilityPermission()

        // Configura hotkey global
        hotkeyManager.setup {
            state.toggleRecording()
        }

        // Carrega modelos no startup
        Task {
            await state.initialize()
        }

        // Cria overlay controller e retém referência estática para evitar desalocação por ARC
        Self.overlayController = OverlayController(appState: state)
    }
}

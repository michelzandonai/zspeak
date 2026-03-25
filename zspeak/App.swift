import SwiftUI

/// Ponto de entrada do zspeak — app de transcrição por voz local
@main
struct ZSpeakApp: App {

    @State private var appState = AppState()
    private let hotkeyManager = HotkeyManager()

    var body: some Scene {
        // App vive exclusivamente no menu bar (sem janela principal)
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            // Ícone muda conforme o estado
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
        // Configura hotkey global
        let state = appState
        hotkeyManager.setup {
            state.toggleRecording()
        }

        // Carrega modelos no startup
        Task {
            await state.initialize()
        }
    }
}

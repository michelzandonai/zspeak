import SwiftUI

/// Menu do ícone no menu bar.
///
/// Dependências injetadas via `@Environment` (mesmas classes @Observable
/// também consumidas por `SettingsView`). Para abrir a janela de Settings usa
/// `openSettings` (macOS 14+); a aba inicial é comunicada via
/// `@AppStorage("settings.initialPage")` — SettingsView observa esse storage e
/// sincroniza `selectedPage`. Para a janela de arquivo usa `openWindow(id:)`.
struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(AccessibilityManager.self) private var accessibilityManager
    @Environment(TranscriptionStore.self) private var store
    @Environment(PromptModeManager.self) private var promptModeManager

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @AppStorage("settings.initialPage") private var initialSettingsPage: String = SettingsPage.overview.rawValue

    var body: some View {
        // Indicador do Modo Prompt LLM
        if promptModeManager.isEnabled {
            Label("Modo Prompt LLM: ATIVO", systemImage: "sparkles")
                .foregroundStyle(.yellow)
        }

        Button(promptModeManager.isEnabled ? "Desligar Modo Prompt" : "Ligar Modo Prompt") {
            promptModeManager.toggle()
        }

        Divider()

        // Status atual
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
        }
        .padding(.horizontal)

        if appState.microphoneManager.permissionState != .authorized {
            Label(microphonePermissionTitle, systemImage: "mic.slash")
                .foregroundStyle(.orange)
                .font(.caption)

            if appState.microphoneManager.permissionState == .notDetermined {
                Text("A permissão será solicitada na primeira gravação.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if appState.microphoneManager.permissionState == .unavailable {
                Text("Esse build precisa ser executado como app bundle para usar o microfone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Button("Configurar Microfone...") {
                    openSettingsOn(.permissions)
                }
            }
        }

        if !accessibilityManager.isGranted {
            Label("Acessibilidade ausente: sem colagem automática", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
            Button("Configurar Acessibilidade...") {
                openSettingsOn(.permissions)
            }
        }

        Divider()

        // Toggle de gravação
        Button(appState.isRecordingOrPreparing ? "Parar Gravação" : "Iniciar Gravação") {
            appState.toggleRecording()
        }
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(appState.state == .processing || !appState.isModelReady)

        Divider()

        // Última transcrição (do store ou fallback para appState)
        if let lastRecord = store.records.first {
            Text("Última transcrição:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(lastRecord.text.prefix(100) + (lastRecord.text.count > 100 ? "..." : "")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lastRecord.text, forType: .string)
            }

            Divider()
        } else if !appState.lastTranscription.isEmpty {
            Text("Última transcrição:")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(appState.lastTranscription.prefix(100) + (appState.lastTranscription.count > 100 ? "..." : "")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(appState.lastTranscription, forType: .string)
            }

            Divider()
        }

        // Erro
        if let error = appState.errorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .font(.caption)
            Divider()
        }

        // Transcrever arquivo de áudio — abre janela flutuante dedicada
        Button("Transcrever arquivo...") {
            openWindow(id: AudioFileWindowID.value)
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(!appState.isModelReady)

        // Configurações e sair
        Button("Configurações...") {
            openSettingsOn(.overview)
        }
        .keyboardShortcut(",", modifiers: [.command])

        Button("Sair") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    /// Seta a aba inicial desejada e abre Settings. Como `SettingsView` observa
    /// o `@AppStorage`, a aba correta é selecionada mesmo se a janela já estava
    /// aberta.
    private func openSettingsOn(_ page: SettingsPage) {
        initialSettingsPage = page.rawValue
        openSettings()
    }

    private var statusColor: Color {
        switch appState.state {
        case .idle:
            if appState.microphoneManager.permissionState != .authorized { return .orange }
            return appState.isModelReady ? .green : .gray
        case .preparing: return .orange
        case .recording: return .red
        case .processing: return .yellow
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

import SwiftUI

/// Menu do ícone no menu bar
struct MenuBarView: View {
    let appState: AppState
    let activationKeyManager: ActivationKeyManager
    let accessibilityManager: AccessibilityManager

    var body: some View {
        // Status atual
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
        }
        .padding(.horizontal)

        // Aviso de acessibilidade
        if !accessibilityManager.isGranted {
            Label("Acessibilidade necessária", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)
            Button("Configurar Acessibilidade...") {
                accessibilityManager.openSystemSettings()
            }
        }

        Divider()

        // Toggle de gravação
        Button(appState.state == .recording ? "Parar Gravação" : "Iniciar Gravação") {
            appState.toggleRecording()
        }
        .keyboardShortcut("r", modifiers: [.command])
        .disabled(appState.state == .processing || !appState.isModelReady || !accessibilityManager.isGranted)

        Divider()

        // Última transcrição
        if !appState.lastTranscription.isEmpty {
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

        // Configurações e sair
        Button("Configurações...") {
            SettingsWindowController.shared.show(appState: appState, microphoneManager: appState.microphoneManager, activationKeyManager: activationKeyManager, accessibilityManager: accessibilityManager)
        }
        .keyboardShortcut(",", modifiers: [.command])

        Button("Sair") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    private var statusColor: Color {
        switch appState.state {
        case .idle:
            if !accessibilityManager.isGranted { return .orange }
            return appState.isModelReady ? .green : .gray
        case .recording: return .red
        case .processing: return .yellow
        }
    }

    private var statusText: String {
        if !accessibilityManager.isGranted { return "Acessibilidade necessária" }
        if !appState.isModelReady { return "Carregando modelo..." }
        switch appState.state {
        case .idle: return "Pronto"
        case .recording: return "Gravando..."
        case .processing: return "Transcrevendo..."
        }
    }
}

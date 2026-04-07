import SwiftUI

/// Menu do ícone no menu bar
struct MenuBarView: View {
    let appState: AppState
    let activationKeyManager: ActivationKeyManager
    let accessibilityManager: AccessibilityManager
    let store: TranscriptionStore
    let benchmarkStore: BenchmarkStore
    let vocabularyStore: VocabularyStore
    let correctionPromptStore: CorrectionPromptStore
    let promptModeManager: PromptModeManager

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
                    appState.microphoneManager.openSystemSettings()
                }
            }
        }

        if !accessibilityManager.isGranted {
            Label("Acessibilidade ausente: sem colagem automática", systemImage: "exclamationmark.triangle")
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

        // Transcrever arquivo de áudio
        Button("Transcrever arquivo...") {
            SettingsWindowController.shared.show(
                appState: appState,
                microphoneManager: appState.microphoneManager,
                activationKeyManager: activationKeyManager,
                accessibilityManager: accessibilityManager,
                store: store,
                benchmarkStore: benchmarkStore,
                vocabularyStore: vocabularyStore,
                correctionPromptStore: correctionPromptStore,
                initialPage: .audioFile
            )
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(!appState.isModelReady)

        // Configurações e sair
        Button("Configurações...") {
            SettingsWindowController.shared.show(appState: appState, microphoneManager: appState.microphoneManager, activationKeyManager: activationKeyManager, accessibilityManager: accessibilityManager, store: store, benchmarkStore: benchmarkStore, vocabularyStore: vocabularyStore, correctionPromptStore: correctionPromptStore)
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
            if appState.microphoneManager.permissionState != .authorized { return .orange }
            return appState.isModelReady ? .green : .gray
        case .recording: return .red
        case .processing: return .yellow
        }
    }

    private var statusText: String {
        if appState.microphoneManager.permissionState != .authorized { return microphonePermissionTitle }
        if !appState.isModelReady { return "Carregando modelo..." }
        switch appState.state {
        case .idle: return "Pronto"
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

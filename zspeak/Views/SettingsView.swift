import SwiftUI
import AppKit
import KeyboardShortcuts
import LaunchAtLogin

/// Controlador da janela de configurações (abre via NSWindow programaticamente)
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(appState: AppState, microphoneManager: MicrophoneManager) {
        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(appState: appState, microphoneManager: microphoneManager)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "zspeak — Configurações"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}

/// Tela de configurações do zspeak
struct SettingsView: View {
    let appState: AppState
    @Bindable var microphoneManager: MicrophoneManager

    var body: some View {
        Form {
            // Seção: Atalho de teclado
            Section("Atalho de Teclado") {
                KeyboardShortcuts.Recorder("Atalho de gravação:", name: .toggleRecording)
                Text("Pressione o atalho para iniciar/parar a gravação")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Seção: Geral
            Section("Geral") {
                LaunchAtLogin.Toggle("Iniciar com o sistema")
            }

            // Seção: Microfone
            Section("Microfone") {
                Toggle(isOn: $microphoneManager.useSystemDefault) {
                    Label("Usar padrão do sistema", systemImage: "mic")
                }

                if !microphoneManager.useSystemDefault {
                    List {
                        ForEach(Array(microphoneManager.microphones.enumerated()), id: \.element.id) { index, mic in
                            HStack(spacing: 8) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.secondary)

                                Text("\(index + 1).")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()

                                if mic.isConnected {
                                    Text(mic.name)
                                } else {
                                    Label(mic.name, systemImage: "mic.slash")
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if mic.id == microphoneManager.activeMicrophoneID {
                                    Circle()
                                        .fill(.green)
                                        .frame(width: 8, height: 8)
                                }
                            }
                        }
                        .onMove { source, destination in
                            microphoneManager.reorder(fromOffsets: source, toOffset: destination)
                        }
                    }
                    .frame(minHeight: 60)

                    Text("Microfones são tentados na ordem de prioridade. Arraste para reordenar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Seção: Permissões
            Section("Permissões") {
                HStack {
                    Image(systemName: TextInserter.hasAccessibilityPermission
                          ? "checkmark.circle.fill"
                          : "exclamationmark.triangle.fill")
                        .foregroundStyle(TextInserter.hasAccessibilityPermission ? .green : .orange)

                    Text("Acessibilidade")

                    Spacer()

                    if !TextInserter.hasAccessibilityPermission {
                        Button("Ativar") {
                            TextInserter.requestAccessibilityPermission()
                        }
                    }
                }

                Text("Necessário para inserir texto no app ativo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Seção: Sobre
            Section("Sobre") {
                LabeledContent("Modelo", value: "Parakeet TDT 0.6B V3")
                LabeledContent("Motor", value: "FluidAudio (CoreML/ANE)")
                LabeledContent("Processamento", value: "100% local")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 500)
    }
}

import SwiftUI
import AppKit
import KeyboardShortcuts
import LaunchAtLogin

/// Controlador da janela de configurações (abre via NSWindow programaticamente)
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(appState: AppState) {
        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(appState: appState)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 350),
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
        .frame(width: 400, height: 350)
    }
}

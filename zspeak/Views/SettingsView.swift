import SwiftUI
import KeyboardShortcuts
import LaunchAtLogin

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

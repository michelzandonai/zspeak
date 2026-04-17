import SwiftUI
import AppKit

/// Página "Sobre" — logo, versão, informações de processamento e links.
struct AboutPage: View {

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.accentColor)
                            .padding(.top, 8)

                        Text("zspeak")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("versão \(appVersion) (\(buildNumber))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    Spacer()
                }
            }

            Section("Tecnologia") {
                LabeledContent("Modelo ASR", value: "Parakeet TDT 0.6B V3")
                LabeledContent("Motor", value: "FluidAudio (CoreML / ANE)")
                LabeledContent("Processamento", value: "100% local")
            }

            Section("Plataforma") {
                LabeledContent("Sistema", value: "macOS 14+ (Apple Silicon)")
                LabeledContent("Privacidade", value: "Nenhum dado sai do dispositivo")
            }

            Section("Links") {
                Button {
                    if let url = URL(string: "https://github.com/michelzandonai/zspeak") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Abrir repositório no GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }

                // TODO: implementar em onda futura
                Button {
                    // placeholder não-funcional
                } label: {
                    Label("Verificar atualizações", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sobre")
    }
}

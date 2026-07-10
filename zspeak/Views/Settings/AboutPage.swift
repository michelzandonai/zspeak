import SwiftUI
import AppKit

/// Página "Sobre" — identidade do app centrada no topo e informações em
/// sections agrupadas, no padrão dos Ajustes do Sistema.
struct AboutPage: View {

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// True quando o processo atual tem um ícone próprio declarado no bundle.
    private var bundleHasIcon: Bool {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil
            || Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") != nil
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    // Ícone real do bundle; squircle como fallback quando o
                    // processo não roda de um .app com ícone (ex.: testes).
                    if bundleHasIcon {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 72, height: 72)
                    } else {
                        ZSSettingsIcon(systemImage: "waveform.badge.mic", color: .blue, size: 64)
                    }

                    VStack(spacing: 2) {
                        Text("zspeak")
                            .font(.title.weight(.bold))
                        Text("Transcrição local para devs")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Text("Versão \(appVersion) (\(buildNumber))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ZSStatusChip(text: "100% local", tone: .success, systemImage: "lock.fill")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Tecnologia") {
                LabeledContent("Modelo ASR", value: "Parakeet TDT 0.6B V3")
                LabeledContent("Motor", value: "FluidAudio (CoreML / ANE)")
                LabeledContent("Processamento", value: "No dispositivo")
            }

            Section("Plataforma") {
                LabeledContent("Sistema", value: "macOS 14+")
                LabeledContent("Arquitetura", value: "Apple Silicon")
            }

            Section("Privacidade") {
                LabeledContent("Rede", value: "Sem envio de áudio")
                LabeledContent("Chaves", value: "Sem API keys")
                LabeledContent("Modelo", value: "Baixado no Mac")
            }

            Section {
                HStack {
                    Label("Repositório", systemImage: "chevron.left.forwardslash.chevron.right")
                    Spacer()
                    Button("Abrir no GitHub") {
                        if let url = URL(string: "https://github.com/michelzandonai/zspeak") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
            } header: {
                Text("Links")
            }
        }
        .formStyle(.grouped)
        .zsAppSurface()
        .navigationTitle("Sobre")
    }
}

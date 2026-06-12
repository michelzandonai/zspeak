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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZSPageHeader(
                    title: "zspeak",
                    subtitle: "Transcrição local para devs · versão \(appVersion) (\(buildNumber))",
                    systemImage: "waveform.badge.mic",
                    tone: .accent
                ) {
                    ZSStatusChip(text: "100% local", tone: .success, systemImage: "lock.fill")
                }

                LazyVGrid(columns: aboutColumns, alignment: .leading, spacing: 16) {
                    ZSSectionCard {
                        sectionTitle("Tecnologia", systemImage: "cpu")
                        LabeledContent("Modelo ASR", value: "Parakeet TDT 0.6B V3")
                        LabeledContent("Motor", value: "FluidAudio (CoreML / ANE)")
                        LabeledContent("Processamento", value: "No dispositivo")
                    }

                    ZSSectionCard {
                        sectionTitle("Plataforma", systemImage: "macbook")
                        LabeledContent("Sistema", value: "macOS 14+")
                        LabeledContent("Arquitetura", value: "Apple Silicon")
                        LabeledContent("IDE", value: "Xcode 15+")
                    }

                    ZSSectionCard {
                        sectionTitle("Privacidade", systemImage: "lock.shield")
                        LabeledContent("Rede", value: "Sem envio de áudio")
                        LabeledContent("Chaves", value: "Sem API keys")
                        LabeledContent("Modelo", value: "Baixado no Mac")
                    }

                    ZSSectionCard {
                        sectionTitle("Links", systemImage: "link")
                        Button {
                            if let url = URL(string: "https://github.com/michelzandonai/zspeak") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Abrir repositório no GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        }

                        Button {
                            // TODO: implementar em onda futura
                        } label: {
                            Label("Verificar atualizações", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(true)
                    }
                }
            }
            .padding(ZSDesign.pagePadding)
        }
        .background(ZSDesign.pageBackground)
        .navigationTitle("Sobre")
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    private var aboutColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 280), spacing: 16, alignment: .top),
        ]
    }
}

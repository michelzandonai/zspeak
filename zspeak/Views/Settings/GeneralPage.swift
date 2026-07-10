import SwiftUI
import AppKit
import LaunchAtLogin

/// Modo de inserção de texto após transcrição.
enum PasteMode: String, CaseIterable, Identifiable {
    case instant    // cola automático no app ativo (requer Accessibility)
    case clipboard  // só copia para o clipboard, usuário decide onde colar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .instant: return "Colar automaticamente"
        case .clipboard: return "Apenas copiar para o clipboard"
        }
    }
}

/// Página Geral — toggles amplos que afetam o app inteiro.
struct GeneralPage: View {
    @AppStorage("pasteMode") private var pasteModeRaw: String = PasteMode.instant.rawValue
    @AppStorage("playRecordingSounds") private var playRecordingSounds: Bool = false
    @AppStorage("showOverlayLatency") private var showOverlayLatency: Bool = false
    // Mesma chave/default de TrayLivePreview.isEnabled (ausente = ligado).
    @AppStorage(TrayLivePreview.enabledDefaultsKey) private var trayModeEnabled: Bool = true

    private var pasteMode: Binding<PasteMode> {
        Binding(
            get: { PasteMode(rawValue: pasteModeRaw) ?? .instant },
            set: { pasteModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                LaunchAtLogin.Toggle {
                    ZSRowLabel("Iniciar com o sistema", systemImage: "power", color: .green)
                }
            } footer: {
                Text("Abre o zspeak automaticamente quando você faz login no macOS.")
            }

            Section {
                Picker(selection: pasteMode) {
                    ForEach(PasteMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                } label: {
                    ZSRowLabel("Após a transcrição", systemImage: "doc.on.clipboard.fill", color: .blue)
                }
            } header: {
                Text("Inserção de texto")
            } footer: {
                Text("\"Colar automaticamente\" simula ⌘+V no app ativo (precisa de Acessibilidade). \"Apenas copiar\" deixa o texto no clipboard para você colar quando quiser.")
            }

            Section {
                Toggle(isOn: $trayModeEnabled) {
                    ZSRowLabel(
                        "Modo tray",
                        systemImage: "menubar.dock.rectangle",
                        color: .indigo,
                        subtitle: "Transcrição ao vivo abaixo da barra de menu"
                    )
                }
            } header: {
                Text("Durante a gravação")
            } footer: {
                Text("Ligado: o texto aparece num painel discreto sob a barra de menu, com indicador de estado no item do tray. Desligado: volta o overlay flutuante com a animação de voz.")
            }

            Section {
                Toggle(isOn: $playRecordingSounds) {
                    ZSRowLabel("Som ao gravar", systemImage: "speaker.wave.2.fill", color: .pink, subtitle: "Bip no início e no fim da gravação")
                }
            } footer: {
                Text("Usa o bip padrão do sistema como feedback sonoro — útil quando o overlay está fora da visão.")
            }

            Section {
                Toggle(isOn: $showOverlayLatency) {
                    ZSRowLabel("Mostrar latência no overlay", systemImage: "gauge.with.needle", color: .orange, subtitle: "Tempo entre hotkey e primeiro sample")
                }
            } footer: {
                Text("Útil para debug de performance da captura.")
            }
        }
        .formStyle(.grouped)
        .zsAppSurface()
        .navigationTitle("Geral")
        .navigationSubtitle("Inicialização, inserção de texto e feedback")
    }
}

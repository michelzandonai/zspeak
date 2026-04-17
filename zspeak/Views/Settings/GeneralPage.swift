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

    private var pasteMode: Binding<PasteMode> {
        Binding(
            get: { PasteMode(rawValue: pasteModeRaw) ?? .instant },
            set: { pasteModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section {
                LaunchAtLogin.Toggle("Iniciar com o sistema")
            } footer: {
                Text("Abre o zspeak automaticamente quando você faz login no macOS.")
            }

            Section {
                Picker("Após a transcrição", selection: pasteMode) {
                    ForEach(PasteMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Inserção de texto")
            } footer: {
                Text("\"Colar automaticamente\" simula ⌘+V no app ativo (precisa de Acessibilidade). \"Apenas copiar\" deixa o texto no clipboard para você colar quando quiser.")
            }

            Section {
                Toggle("Tocar som no início e no fim da gravação", isOn: $playRecordingSounds)
            } footer: {
                Text("Usa o bip padrão do sistema como feedback sonoro — útil quando o overlay está fora da visão.")
            }

            Section {
                Toggle("Mostrar latência no overlay", isOn: $showOverlayLatency)
            } footer: {
                Text("Exibe o tempo entre apertar a hotkey e o primeiro sample capturado. Útil para debug.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Geral")
    }
}

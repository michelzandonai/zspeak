import SwiftUI
import KeyboardShortcuts

/// Página de Atalhos de Teclado.
///
/// Mostra um preview visual do atalho atual no topo, deixa o usuário trocar a
/// tecla de ativação e o modo (toggle/hold/doubleTap), e expõe o atalho global
/// do Modo Prompt LLM. A ajuda sobre os modos aparece AO LADO do picker — não
/// em footer de outra seção — para que fique claro o que cada modo faz.
struct KeyboardPage: View {
    @Environment(ActivationKeyManager.self) private var activationKeyManager

    var body: some View {
        @Bindable var keyManager = activationKeyManager

        Form {
            Section {
                shortcutPreview
            }

            Section {
                Picker("Tecla", selection: $keyManager.selectedKey) {
                    ForEach(ActivationKey.allCases) { key in
                        Text(key.rawValue).tag(key)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Picker("Modo", selection: $keyManager.activationMode) {
                        ForEach(ActivationMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(modeDescription(for: keyManager.activationMode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Tecla de ativação")
            }

            Section {
                KeyboardShortcuts.Recorder("Modo Prompt LLM:", name: .togglePromptMode)
            } header: {
                Text("Correção LLM")
            } footer: {
                Text("Atalho global para ligar/desligar o Modo Prompt. Quando ativo, o overlay fica visível com chips de prompts clicáveis. ESC também desliga.")
            }

            Section {
                Toggle("Escape cancela gravação", isOn: $keyManager.escapeToCancel)
            } footer: {
                Text("Permite interromper uma gravação em andamento sem transcrever, pressionando ESC.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Atalhos de Teclado")
    }

    // MARK: - Preview do atalho atual

    private var shortcutPreview: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .font(.title2)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text("Atalho atual")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    shortcutBadge(text: activationKeyManager.selectedKey.rawValue)
                    Text("para")
                        .foregroundStyle(.secondary)
                    shortcutBadge(text: activationKeyManager.activationMode.rawValue)
                }
                .font(.body)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func shortcutBadge(text: String) -> some View {
        Text(text)
            .font(.body.monospaced())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }

    private func modeDescription(for mode: ActivationMode) -> String {
        switch mode {
        case .toggle:
            return "Toggle: toque a tecla para começar, toque de novo para parar."
        case .hold:
            return "Hold: mantenha a tecla pressionada enquanto grava; solte para parar."
        case .doubleTap:
            return "Double Tap: toque duas vezes rapidamente para iniciar; toque duas vezes para parar."
        }
    }
}

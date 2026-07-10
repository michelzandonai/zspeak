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
                Picker(selection: $keyManager.selectedKey) {
                    ForEach(ActivationKey.allCases) { key in
                        Text(key.rawValue).tag(key)
                    }
                } label: {
                    ZSRowLabel("Tecla", systemImage: "command", color: .gray)
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
                recorderRow("Modo Prompt", systemImage: "sparkles", color: .purple, name: .togglePromptMode)
                recorderRow("Modo Tradução", systemImage: "character.bubble.fill", color: .indigo, name: .toggleSelectionLookupMode)
                recorderRow("Traduzir seleção", systemImage: "globe", color: .blue, name: .translateSelection)
            } header: {
                Text("LLM")
            } footer: {
                Text("O Modo Prompt mantém o overlay aberto para correções. O Modo Tradução mostra uma bolha curta ao selecionar palavras. Traduzir seleção lê o texto selecionado no app ativo e mostra a tradução no overlay.")
            }

            Section {
                Toggle(isOn: $keyManager.escapeToCancel) {
                    ZSRowLabel("Escape cancela gravação", systemImage: "escape", color: .red, subtitle: "Interrompe sem transcrever")
                }
            } footer: {
                Text("Permite interromper uma gravação em andamento sem transcrever, pressionando ESC.")
            }
        }
        .formStyle(.grouped)
        .zsAppSurface()
        .navigationTitle("Atalhos de Teclado")
        .navigationSubtitle("Tecla principal e atalhos globais dos modos LLM")
    }

    /// Row de recorder com ícone squircle: label nosso à esquerda, recorder
    /// nativo do KeyboardShortcuts à direita.
    private func recorderRow(
        _ title: String,
        systemImage: String,
        color: Color,
        name: KeyboardShortcuts.Name
    ) -> some View {
        HStack {
            ZSRowLabel(title, systemImage: systemImage, color: color)
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }

    // MARK: - Preview do atalho atual

    private var shortcutPreview: some View {
        HStack(spacing: 12) {
            ZSSettingsIcon(systemImage: "keyboard.fill", color: .gray, size: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text("Atalho atual")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    keycap(activationKeyManager.selectedKey.rawValue)
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(activationKeyManager.activationMode.rawValue)
                        .foregroundStyle(.secondary)
                }
                .font(.body)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    /// Tecla desenhada como keycap físico: fundo elevado com "degrau" inferior.
    private func keycap(_ text: String) -> some View {
        Text(text)
            .font(.system(.body, design: .rounded).weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ZSDesign.raisedBackground)
                    .shadow(color: .black.opacity(0.35), radius: 0, y: 1.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
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

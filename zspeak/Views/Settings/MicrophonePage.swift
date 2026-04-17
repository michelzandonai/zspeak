import SwiftUI

/// Página de Microfone.
///
/// Lista dispositivos disponíveis e permite reordenar via `List.onMove` (drag).
/// Badges indicam o microfone **Ativo** (em uso agora) e o **Preferido** (o que
/// será tentado primeiro na próxima gravação). O toggle "Usar padrão do sistema"
/// esconde/mostra a lista com transição animada.
struct MicrophonePage: View {
    @Environment(MicrophoneManager.self) private var microphoneManager

    var body: some View {
        @Bindable var mic = microphoneManager

        Form {
            Section {
                Toggle("Usar padrão do sistema", isOn: $mic.useSystemDefault)
            } footer: {
                Text("Quando ligado, zspeak usa sempre o microfone padrão do sistema. Desligue para definir uma ordem de prioridade.")
            }

            if !microphoneManager.useSystemDefault {
                Section {
                    List {
                        ForEach(microphoneManager.microphones) { mic in
                            micRow(for: mic)
                        }
                        .onMove { offsets, destination in
                            microphoneManager.reorder(fromOffsets: offsets, toOffset: destination)
                        }
                    }
                    .frame(minHeight: rowHeight * CGFloat(max(microphoneManager.microphones.count, 1)))
                } header: {
                    Text("Ordem de prioridade")
                } footer: {
                    Text("Arraste para reordenar. zspeak tenta cada microfone conectado na ordem acima.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Microfone")
        .animation(.default, value: microphoneManager.useSystemDefault)
    }

    // MARK: - Linha

    private let rowHeight: CGFloat = 32

    @ViewBuilder
    private func micRow(for mic: MicrophoneInfo) -> some View {
        let isActive = microphoneManager.activeMicrophoneID == mic.id
        let isPreferred = preferredMicrophoneID == mic.id && !isActive

        HStack(spacing: 8) {
            Image(systemName: iconName(for: mic, isActive: isActive))
                .foregroundStyle(iconColor(for: mic, isActive: isActive))
                .frame(width: 16)

            Text(mic.name)
                .foregroundStyle(mic.isConnected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if isActive {
                badge(text: "Ativo", color: .red)
            } else if isPreferred {
                badge(text: "Preferido", color: .green)
            } else if !mic.isConnected {
                badge(text: "Desconectado", color: .secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func iconName(for mic: MicrophoneInfo, isActive: Bool) -> String {
        if isActive { return "mic.fill" }
        if !mic.isConnected { return "mic.slash" }
        return "mic"
    }

    private func iconColor(for mic: MicrophoneInfo, isActive: Bool) -> Color {
        if isActive { return .red }
        if !mic.isConnected { return .secondary }
        return .primary
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    /// ID do microfone que será usado na próxima gravação: ativo (durante gravação)
    /// ou o primeiro conectado da lista ordenada.
    private var preferredMicrophoneID: String? {
        if let activeID = microphoneManager.activeMicrophoneID {
            return activeID
        }
        return microphoneManager.microphones.first(where: \.isConnected)?.id
    }
}

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
                ZSFormHero(
                    title: "Microfone",
                    subtitle: "Escolha o padrão do sistema ou priorize dispositivos específicos.",
                    systemImage: "mic.fill",
                    tone: .danger
                )
            }

            Section {
                Toggle("Usar padrão do sistema", isOn: $mic.useSystemDefault)
            } footer: {
                Text("Quando ligado, zspeak usa sempre o microfone padrão do sistema. Desligue para definir uma ordem de prioridade.")
            }

            if !microphoneManager.useSystemDefault {
                Section {
                    if microphoneManager.microphones.isEmpty {
                        emptyMicrophoneState
                            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
                    } else {
                        List {
                            ForEach(microphoneManager.microphones) { mic in
                                micRow(for: mic)
                            }
                            .onMove { offsets, destination in
                                microphoneManager.reorder(fromOffsets: offsets, toOffset: destination)
                            }
                        }
                        .frame(minHeight: listHeight)
                    }
                } header: {
                    Text("Ordem de prioridade")
                } footer: {
                    Text("Arraste para reordenar. zspeak tenta cada microfone conectado na ordem acima.")
                }
            }
        }
        .formStyle(.grouped)
        .zsFormPage()
        .navigationTitle("Microfone")
        .animation(.default, value: microphoneManager.useSystemDefault)
    }

    // MARK: - Linha

    private let rowHeight: CGFloat = 32

    private var listHeight: CGFloat {
        if microphoneManager.microphones.isEmpty {
            return 112
        }
        return rowHeight * CGFloat(max(microphoneManager.microphones.count, 1))
    }

    private var emptyMicrophoneState: some View {
        HStack(spacing: 12) {
            Image(systemName: "mic.badge.plus")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text("Nenhum microfone listado")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Conecte um dispositivo ou ligue o padrão do sistema.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
    }

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

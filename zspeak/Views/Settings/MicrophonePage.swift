import SwiftUI

/// Página de Microfone.
///
/// Lista dispositivos disponíveis e permite reordenar via `List.onMove` (drag).
/// Badges indicam o microfone **Ativo** (em uso agora), o **Preferido** (o que
/// será tentado primeiro na próxima gravação) e os **Bloqueados** (nunca são
/// usados — nem quando são o padrão do sistema). O toggle "Usar padrão do
/// sistema" alterna entre seguir o macOS e a ordem de prioridade própria.
struct MicrophonePage: View {
    @Environment(MicrophoneManager.self) private var microphoneManager

    var body: some View {
        @Bindable var mic = microphoneManager

        Form {
            Section {
                Toggle(isOn: $mic.useSystemDefault) {
                    ZSRowLabel("Usar padrão do sistema", systemImage: "mic.fill", color: .red, subtitle: "Segue o microfone escolhido no macOS")
                }
            } footer: {
                Text("Quando ligado, zspeak usa sempre o microfone padrão do sistema. Desligue para definir uma ordem de prioridade.")
            }

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
                Text(microphoneManager.useSystemDefault ? "Dispositivos" : "Ordem de prioridade")
            } footer: {
                Text(
                    microphoneManager.useSystemDefault
                        ? "Clique no símbolo de proibido para bloquear um microfone: ele nunca será usado — se virar o padrão do sistema, o zspeak grava com o primeiro permitido da lista."
                        : "Arraste para reordenar — zspeak tenta cada microfone conectado na ordem acima. Clique no símbolo de proibido para bloquear um microfone: ele nunca será usado, nem como fallback."
                )
            }
        }
        .formStyle(.grouped)
        .zsAppSurface()
        .navigationTitle("Microfone")
        .navigationSubtitle("Padrão do sistema, prioridade e bloqueio")
        .animation(.default, value: microphoneManager.useSystemDefault)
    }

    // MARK: - Linha

    private let rowHeight: CGFloat = 38

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
        let isBlocked = microphoneManager.isBlocked(mic.id)
        let isActive = microphoneManager.activeMicrophoneID == mic.id
        let isPreferred = preferredMicrophoneID == mic.id && !isActive && !isBlocked

        HStack(spacing: 10) {
            ZSSettingsIcon(
                systemImage: iconName(for: mic, isActive: isActive, isBlocked: isBlocked),
                color: iconColor(for: mic, isActive: isActive, isBlocked: isBlocked),
                size: 24
            )

            Text(mic.name)
                .foregroundStyle(mic.isConnected && !isBlocked ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            if isBlocked {
                ZSStatusChip(text: "Bloqueado", tone: .danger, systemImage: "nosign")
            } else if isActive {
                ZSStatusChip(text: "Ativo", tone: .danger, systemImage: "waveform")
            } else if isPreferred {
                ZSStatusChip(text: "Preferido", tone: .success)
            } else if !mic.isConnected {
                ZSStatusChip(text: "Desconectado", tone: .neutral)
            }

            Button {
                microphoneManager.setBlocked(mic.id, blocked: !isBlocked)
            } label: {
                Image(systemName: "nosign")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isBlocked ? Color.red : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .help(isBlocked ? "Desbloquear — volta a poder ser usado" : "Bloquear — nunca usar este microfone")
        }
        .padding(.vertical, 2)
    }

    private func iconName(for mic: MicrophoneInfo, isActive: Bool, isBlocked: Bool) -> String {
        if isBlocked { return "mic.slash.fill" }
        if isActive { return "mic.fill" }
        if !mic.isConnected { return "mic.slash.fill" }
        return "mic.fill"
    }

    private func iconColor(for mic: MicrophoneInfo, isActive: Bool, isBlocked: Bool) -> Color {
        if isBlocked { return .red }
        if isActive { return .red }
        if !mic.isConnected { return Color(nsColor: .tertiaryLabelColor) }
        return .gray
    }

    /// ID do microfone que será usado na próxima gravação: ativo (durante gravação)
    /// ou o primeiro candidato resolvido (respeita bloqueados e o modo padrão
    /// do sistema).
    private var preferredMicrophoneID: String? {
        if let activeID = microphoneManager.activeMicrophoneID {
            return activeID
        }
        guard !microphoneManager.useSystemDefault else { return nil }
        return microphoneManager.connectedMicrophones().first?.id
    }
}

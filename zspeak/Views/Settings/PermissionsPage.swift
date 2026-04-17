import SwiftUI

/// Página de Permissões.
///
/// Header agregado no topo informa se está tudo concedido ou se algo precisa
/// de atenção. Cada permissão aparece numa section com status visual e CTA
/// consistente; os passos "Como ativar" só aparecem quando a permissão está
/// pendente, para não poluir a UI quando tudo já está ok.
struct PermissionsPage: View {
    @Environment(MicrophoneManager.self) private var microphoneManager
    @Environment(AccessibilityManager.self) private var accessibilityManager

    var body: some View {
        Form {
            Section { summaryHeader }

            // Microfone
            Section {
                permissionRow(
                    title: "Microfone",
                    granted: microphoneManager.isPermissionGranted,
                    iconName: microphoneStatusIcon,
                    iconColor: microphoneStatusColor,
                    action: microphoneAction
                )
            } footer: {
                Text(microphonePermissionFooter)
            }

            if !microphoneManager.isPermissionGranted && microphoneManager.permissionState != .unavailable {
                Section("Como ativar o microfone") {
                    Label("Clique em \"Solicitar Permissão\" ou inicie uma gravação", systemImage: "1.circle")
                    Label("Se o macOS negar, abra Ajustes do Sistema", systemImage: "2.circle")
                    Label("Ative zspeak em Privacidade → Microfone", systemImage: "3.circle")
                }
            }

            // Acessibilidade
            Section {
                permissionRow(
                    title: "Acessibilidade",
                    granted: accessibilityManager.isGranted,
                    iconName: accessibilityManager.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                    iconColor: accessibilityManager.isGranted ? .green : .orange,
                    action: accessibilityAction
                )
            } footer: {
                Text("Necessário para colar no app ativo e para a hotkey global. Sem isso, a transcrição continua funcionando com cópia para o clipboard.")
            }

            if !accessibilityManager.isGranted {
                Section("Como ativar a acessibilidade") {
                    Label("Clique em \"Abrir Ajustes do Sistema\"", systemImage: "1.circle")
                    Label("Encontre \"zspeak\" na lista", systemImage: "2.circle")
                    Label("Ative o toggle", systemImage: "3.circle")
                }

                Section("Resolução de problemas") {
                    Text("Se zspeak não aparece na lista: clique \"+\" e navegue até /Applications/zspeak.app")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Se o toggle está ativo mas aqui mostra inativo: remova da lista, adicione novamente e reinicie o app.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // Build sem Info.plist — mostrar apenas no caso técnico
            if microphoneManager.permissionState == .unavailable {
                Section("Build") {
                    Text("O build atual não expõe permissão de microfone. Isso acontece quando o app é rodado fora de um bundle .app com Info.plist embutido.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissões")
    }

    // MARK: - Header agregado

    private var summaryHeader: some View {
        let pending = pendingCount
        let allGranted = pending == 0

        return HStack(spacing: 10) {
            Image(systemName: allGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(allGranted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(allGranted ? "Tudo concedido" : "Atenção necessária")
                    .font(.headline)
                Text(allGranted
                     ? "zspeak tem todas as permissões para funcionar completamente."
                     : "\(pending) permissão\(pending == 1 ? "" : "es") faltando para o app funcionar completamente."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var pendingCount: Int {
        var count = 0
        if !microphoneManager.isPermissionGranted { count += 1 }
        if !accessibilityManager.isGranted { count += 1 }
        return count
    }

    // MARK: - Linha de permissão

    @ViewBuilder
    private func permissionRow(
        title: String,
        granted: Bool,
        iconName: String,
        iconColor: Color,
        action: PermissionAction?
    ) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
            }

            Spacer()

            if granted {
                statusChip(text: "Concedido", color: .green)
            } else {
                statusChip(text: "Pendente", color: .orange)
                if let action {
                    Button(action.label, action: action.run)
                        .controlSize(.small)
                }
            }
        }
    }

    private func statusChip(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - Ações

    private struct PermissionAction {
        let label: String
        let run: () -> Void
    }

    private var microphoneAction: PermissionAction? {
        switch microphoneManager.permissionState {
        case .authorized, .unavailable:
            return nil
        case .notDetermined:
            return PermissionAction(label: "Conceder") {
                Task {
                    _ = await microphoneManager.requestPermissionIfNeeded()
                }
            }
        case .denied, .restricted:
            return PermissionAction(label: "Abrir Ajustes") {
                microphoneManager.openSystemSettings()
            }
        }
    }

    private var accessibilityAction: PermissionAction? {
        guard !accessibilityManager.isGranted else { return nil }
        return PermissionAction(label: "Abrir Ajustes") {
            accessibilityManager.openSystemSettings()
        }
    }

    // MARK: - Strings específicas de microfone

    private var microphoneStatusIcon: String {
        switch microphoneManager.permissionState {
        case .authorized: return "checkmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        case .denied, .restricted, .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    private var microphoneStatusColor: Color {
        switch microphoneManager.permissionState {
        case .authorized: return .green
        case .notDetermined: return .yellow
        case .denied, .restricted, .unavailable: return .orange
        }
    }

    private var microphonePermissionFooter: String {
        switch microphoneManager.permissionState {
        case .authorized:
            return "Obrigatório para capturar sua voz e iniciar a transcrição."
        case .notDetermined:
            return "A primeira gravação vai solicitar acesso ao microfone."
        case .denied, .restricted:
            return "Sem acesso ao microfone a gravação não inicia."
        case .unavailable:
            return "Build atual não expõe permissão de microfone — rode via bundle .app em /Applications."
        }
    }
}

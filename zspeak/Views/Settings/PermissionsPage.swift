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

    @State private var isRunningSetup = false
    private let refreshOnAppear: Bool

    init(refreshOnAppear: Bool = true) {
        self.refreshOnAppear = refreshOnAppear
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZSPageHeader(
                    title: pendingCount == 0 ? "Tudo concedido" : "Atenção necessária",
                    subtitle: pendingCount == 0
                        ? "zspeak tem todas as permissões para gravar e inserir texto."
                        : "\(pendingCount) permissão\(pendingCount == 1 ? "" : "es") faltando para o fluxo completo.",
                    systemImage: pendingCount == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    tone: pendingCount == 0 ? .success : .warning
                ) {
                    ZSStatusChip(
                        text: pendingCount == 0 ? "Completo" : "\(pendingCount) pendente\(pendingCount == 1 ? "" : "s")",
                        tone: pendingCount == 0 ? .success : .warning
                    )
                }

                if pendingCount > 0 {
                    ZSSectionCard {
                        sectionTitle("Configuração guiada", systemImage: "checklist.checked")
                        Text("O zspeak abre os prompts e os Ajustes certos. O macOS ainda exige que você confirme Microfone e Acessibilidade manualmente.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await runGuidedSetup() }
                        } label: {
                            Label(isRunningSetup ? "Configurando..." : "Configurar permissões", systemImage: "checklist.checked")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunningSetup)
                    }
                }

                ZSSectionCard {
                    sectionTitle("Microfone", systemImage: "mic.fill")
                    permissionRow(
                        title: "Microfone",
                        granted: microphoneManager.isPermissionGranted,
                        iconName: microphoneStatusIcon,
                        iconColor: microphoneStatusColor,
                        action: microphoneAction
                    )
                    Text(microphonePermissionFooter)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !microphoneManager.isPermissionGranted && microphoneManager.permissionState != .unavailable {
                    stepsCard(
                        title: "Como ativar o microfone",
                        steps: [
                            "Clique em \"Conceder\" ou inicie uma gravação",
                            "Se o macOS negar, abra Ajustes do Sistema",
                            "Ative zspeak em Privacidade → Microfone",
                        ]
                    )
                }

                ZSSectionCard {
                    sectionTitle("Acessibilidade", systemImage: "accessibility")
                    permissionRow(
                        title: "Acessibilidade",
                        granted: accessibilityManager.isGranted,
                        iconName: accessibilityManager.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        iconColor: accessibilityManager.isGranted ? .green : .orange,
                        action: accessibilityAction
                    )
                    Text("Necessário para colar no app ativo e para a hotkey global. Sem isso, a transcrição continua funcionando com cópia para o clipboard.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !accessibilityManager.isGranted {
                    stepsCard(
                        title: "Como ativar a acessibilidade",
                        steps: [
                            "Clique em \"Configurar permissões\" ou \"Conceder\"",
                            "Encontre \"zspeak\" na lista",
                            "Ative o toggle",
                        ]
                    )

                    ZSSectionCard {
                        sectionTitle("Resolução de problemas", systemImage: "wrench.and.screwdriver")
                        Text("Se zspeak não aparece na lista: clique \"+\" e navegue até /Applications/zspeak.app")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Se o toggle está ativo mas aqui mostra inativo: remova da lista, adicione novamente e reinicie o app.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if microphoneManager.permissionState == .unavailable {
                    ZSSectionCard {
                        sectionTitle("Build", systemImage: "hammer")
                        Text("O build atual não expõe permissão de microfone. Isso acontece quando o app é rodado fora de um bundle .app com Info.plist embutido.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(ZSDesign.pagePadding)
        }
        .background(ZSDesign.pageBackground)
        .navigationTitle("Permissões")
        .onAppear {
            guard refreshOnAppear else { return }
            microphoneManager.refreshPermissionState()
            accessibilityManager.refreshPermissionState()
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.primary)
    }

    private func stepsCard(title: String, steps: [String]) -> some View {
        ZSSectionCard {
            sectionTitle(title, systemImage: "list.number")
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Label(step, systemImage: "\(index + 1).circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
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

    private func runGuidedSetup() async {
        guard !isRunningSetup else { return }
        isRunningSetup = true
        defer { isRunningSetup = false }

        microphoneManager.refreshPermissionState()
        accessibilityManager.refreshPermissionState()

        switch microphoneManager.permissionState {
        case .notDetermined:
            _ = await microphoneManager.requestPermissionIfNeeded()
        case .denied, .restricted:
            microphoneManager.openSystemSettings()
        case .authorized, .unavailable:
            break
        }

        if !accessibilityManager.isGranted {
            accessibilityManager.startGuidedPermissionFlow()
        }

        try? await Task.sleep(for: .milliseconds(500))
        microphoneManager.refreshPermissionState()
        accessibilityManager.refreshPermissionState()
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
        return PermissionAction(label: "Conceder") {
            accessibilityManager.startGuidedPermissionFlow()
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

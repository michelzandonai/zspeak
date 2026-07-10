import SwiftUI

/// Página de Permissões.
///
/// Banner agregado no topo informa se está tudo concedido ou se algo precisa
/// de atenção. Cada permissão é uma section do form com status, CTA e footer
/// explicativo; os passos "Como ativar" só aparecem quando a permissão está
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
        Form {
            Section {
                ZSStatusBanner(
                    title: pendingCount == 0 ? "Tudo concedido" : "Atenção necessária",
                    subtitle: pendingCount == 0
                        ? "zspeak tem todas as permissões para gravar e inserir texto."
                        : "\(pendingCount) permissão\(pendingCount == 1 ? "" : "es") faltando para o fluxo completo.",
                    systemImage: pendingCount == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    tone: pendingCount == 0 ? .success : .warning,
                    chipText: pendingCount == 0 ? "Completo" : "\(pendingCount) pendente\(pendingCount == 1 ? "" : "s")"
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            if pendingCount > 0 {
                Section {
                    HStack {
                        Text("O zspeak abre os prompts e os Ajustes certos; o macOS ainda exige confirmação manual.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            Task { await runGuidedSetup() }
                        } label: {
                            Label(isRunningSetup ? "Configurando..." : "Configurar", systemImage: "checklist.checked")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunningSetup)
                    }
                } header: {
                    Text("Configuração guiada")
                }
            }

            Section {
                permissionRow(
                    title: "Microfone",
                    icon: "mic.fill",
                    tint: .red,
                    granted: microphoneManager.isPermissionGranted,
                    action: microphoneAction
                )

                if !microphoneManager.isPermissionGranted && microphoneManager.permissionState != .unavailable {
                    steps([
                        "Clique em \"Conceder\" ou inicie uma gravação",
                        "Se o macOS negar, abra Ajustes do Sistema",
                        "Ative zspeak em Privacidade → Microfone",
                    ])
                }
            } header: {
                Text("Microfone")
            } footer: {
                Text(microphonePermissionFooter)
            }

            Section {
                permissionRow(
                    title: "Acessibilidade",
                    icon: "accessibility",
                    tint: .blue,
                    granted: accessibilityManager.isGranted,
                    action: accessibilityAction
                )

                if !accessibilityManager.isGranted {
                    steps([
                        "Clique em \"Configurar\" ou \"Conceder\"",
                        "Encontre \"zspeak\" na lista",
                        "Ative o toggle",
                    ])
                }
            } header: {
                Text("Acessibilidade")
            } footer: {
                Text("Necessário para colar no app ativo e para a hotkey global. Sem isso, a transcrição continua funcionando com cópia para o clipboard.")
            }

            if !accessibilityManager.isGranted {
                Section {
                    Label {
                        Text("Se zspeak não aparece na lista: clique \"+\" e navegue até /Applications/zspeak.app")
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)

                    Label {
                        Text("Se o toggle está ativo mas aqui mostra inativo: remova da lista, adicione novamente e reinicie o app.")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Resolução de problemas")
                }
            }

            if microphoneManager.permissionState == .unavailable {
                Section {
                    Label {
                        Text("O build atual não expõe permissão de microfone. Isso acontece quando o app é rodado fora de um bundle .app com Info.plist embutido.")
                    } icon: {
                        Image(systemName: "hammer")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Build")
                }
            }
        }
        .formStyle(.grouped)
        .zsAppSurface()
        .navigationTitle("Permissões")
        .onAppear {
            guard refreshOnAppear else { return }
            microphoneManager.refreshPermissionState()
            accessibilityManager.refreshPermissionState()
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
        icon: String,
        tint: Color,
        granted: Bool,
        action: PermissionAction?
    ) -> some View {
        HStack(spacing: 10) {
            ZSSettingsIcon(systemImage: icon, color: tint, size: 24)
            Text(title)

            Spacer()

            if granted {
                ZSStatusChip(text: "Concedido", tone: .success, systemImage: "checkmark")
            } else {
                ZSStatusChip(text: "Pendente", tone: .warning)
                if let action {
                    Button(action.label, action: action.run)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func steps(_ items: [String]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { index, step in
            Label(step, systemImage: "\(index + 1).circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
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

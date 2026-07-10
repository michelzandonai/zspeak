import SwiftUI

/// Página de Overview — "dashboard" do estado do app.
///
/// Banner de status agregado no topo (verde = tudo ok, laranja = algo pedindo
/// atenção), grid de métricas rápidas e rows de estado no padrão dos Ajustes
/// do Sistema, com CTAs contextuais para navegar direto na aba certa.
struct OverviewPage: View {
    @Environment(AppState.self) private var appState
    @Environment(MicrophoneManager.self) private var microphoneManager
    @Environment(AccessibilityManager.self) private var accessibilityManager
    @Environment(ActivationKeyManager.self) private var activationKeyManager
    @Environment(TranscriptionStore.self) private var store

    @AppStorage("settings.initialPage") private var initialPage: String = "overview"

    @State private var llmState: LLMCorrectionManager.ModelState = .notDownloaded
    @State private var selectedLLMModel = LLMModelOption.defaultModel

    var body: some View {
        Form {
            Section {
                ZSStatusBanner(
                    title: attentionIssues.isEmpty ? "Tudo funcionando" : "Atenção necessária",
                    subtitle: attentionIssues.isEmpty
                        ? "zspeak está pronto para transcrever localmente no Mac."
                        : "Resolva os itens pendentes para liberar gravação, colagem e correções.",
                    systemImage: attentionIssues.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    tone: attentionIssues.isEmpty ? .success : .warning,
                    chipText: attentionIssues.isEmpty
                        ? "Pronto"
                        : "\(attentionIssues.count) pendente\(attentionIssues.count == 1 ? "" : "s")"
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ZSMetricTile(title: "Transcrição", value: asrStatus.text, systemImage: "waveform", tone: asrTone)
                    ZSMetricTile(title: "LLM", value: llmStatusText, systemImage: "sparkles", tone: llmTone)
                    ZSMetricTile(title: "Permissões", value: pendingPermissions.isEmpty ? "OK" : "\(pendingPermissions.count) pendente\(pendingPermissions.count == 1 ? "" : "s")", systemImage: "lock.shield.fill", tone: pendingPermissions.isEmpty ? .success : .warning)
                    ZSMetricTile(title: "Atalho", value: activationKeyManager.selectedKey.rawValue, systemImage: "keyboard.fill", tone: .neutral)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("Estado operacional") {
                statusRow(
                    icon: "waveform",
                    tint: .blue,
                    title: "Modelo de transcrição",
                    status: asrStatus.text,
                    statusColor: asrStatus.color
                )

                HStack {
                    statusRow(
                        icon: "sparkles",
                        tint: .purple,
                        title: "Correção LLM",
                        status: "\(selectedLLMModel.shortName) · \(llmStatusText)",
                        statusColor: llmStatusColor
                    )
                    if case .notDownloaded = llmState {
                        Button("Configurar") {
                            initialPage = "correction"
                        }
                        .controlSize(.small)
                    }
                }

                HStack {
                    let pending = pendingPermissions
                    statusRow(
                        icon: "lock.shield.fill",
                        tint: .green,
                        title: "Permissões",
                        status: pending.isEmpty ? "Todas concedidas" : "\(pending.count) pendente\(pending.count == 1 ? "" : "s")",
                        statusColor: pending.isEmpty ? .green : .orange
                    )
                    if !pending.isEmpty {
                        Button("Abrir Permissões") {
                            initialPage = "permissions"
                        }
                        .controlSize(.small)
                    }
                }

                HStack {
                    statusRow(
                        icon: "keyboard.fill",
                        tint: .gray,
                        title: "Atalho",
                        status: "\(activationKeyManager.selectedKey.rawValue) · \(activationKeyManager.activationMode.rawValue)",
                        statusColor: nil
                    )
                    Button("Editar") {
                        initialPage = "keyboard"
                    }
                    .controlSize(.small)
                }
            }

            if let last = lastTranscriptionSnippet {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(last.text)
                            .lineLimit(4)
                            .textSelection(.enabled)
                            .foregroundStyle(.primary)
                        Text(last.relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Última transcrição")
                }
            }
        }
        .formStyle(.grouped)
        .zsAppSurface()
        .navigationTitle("Visão Geral")
        .task(id: llmStateTaskID) {
            selectedLLMModel = await appState.selectedLLMModel()
            llmState = await appState.llmModelState()
        }
    }

    // MARK: - Row de estado

    /// Row no padrão dos Ajustes do Sistema: squircle colorido, título e
    /// status à direita. `statusColor` nil usa o cinza secundário.
    @ViewBuilder
    private func statusRow(
        icon: String,
        tint: Color,
        title: String,
        status: String,
        statusColor: Color?
    ) -> some View {
        HStack(spacing: 10) {
            ZSSettingsIcon(systemImage: icon, color: tint, size: 24)
            Text(title)
            Spacer()
            Text(status)
                .font(.callout)
                .foregroundStyle(statusColor ?? Color.secondary)
        }
        .padding(.vertical, 1)
    }

    // MARK: - Dados derivados

    private var asrStatus: (text: String, color: Color) {
        if appState.isModelReady { return ("Pronto", .green) }
        return ("Carregando...", .orange)
    }

    private var llmStatusText: String {
        switch llmState {
        case .notDownloaded: return "Não baixado"
        case .downloading(let progress): return "Baixando (\(Int(progress * 100))%)"
        case .downloaded: return "Baixado"
        case .loading: return "Carregando..."
        case .ready: return "Pronto"
        case .error: return "Erro"
        }
    }

    private var llmStatusColor: Color? {
        switch llmState {
        case .notDownloaded: return nil
        case .downloading, .loading: return .orange
        case .downloaded, .ready: return .green
        case .error: return .red
        }
    }

    private var asrTone: ZSTone {
        appState.isModelReady ? .success : .warning
    }

    private var llmTone: ZSTone {
        switch llmState {
        case .notDownloaded: return .neutral
        case .downloading, .loading: return .warning
        case .downloaded, .ready: return .success
        case .error: return .danger
        }
    }

    /// Força re-execução do .task quando o estado observado muda.
    private var llmStateTaskID: Int {
        appState.isModelReady ? 1 : 0
    }

    private var pendingPermissions: [String] {
        var list: [String] = []
        if !microphoneManager.isPermissionGranted { list.append("Microfone") }
        if !accessibilityManager.isGranted { list.append("Acessibilidade") }
        return list
    }

    private var attentionIssues: [String] {
        var issues: [String] = []
        if !appState.isModelReady { issues.append("Modelo ASR carregando") }
        issues.append(contentsOf: pendingPermissions.map { "\($0) pendente" })
        return issues
    }

    private var lastTranscriptionSnippet: (text: String, relative: String)? {
        if let record = store.records.first {
            return (record.text, relativeDate(record.timestamp))
        }
        let fallback = appState.lastTranscription
        guard !fallback.isEmpty else { return nil }
        return (fallback, "agora")
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: "pt_BR")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

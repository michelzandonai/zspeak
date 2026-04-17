import SwiftUI

/// Página de Overview — "dashboard" do estado do app.
///
/// Mostra um header grande com status agregado (verde = tudo ok, laranja = algo
/// pedindo atenção) e cards com as informações mais relevantes: ASR, LLM,
/// permissões, atalho, última transcrição. Inclui CTAs contextuais para
/// navegar direto na aba certa quando algo está faltando.
struct OverviewPage: View {
    @Environment(AppState.self) private var appState
    @Environment(MicrophoneManager.self) private var microphoneManager
    @Environment(AccessibilityManager.self) private var accessibilityManager
    @Environment(ActivationKeyManager.self) private var activationKeyManager
    @Environment(TranscriptionStore.self) private var store

    @AppStorage("settings.initialPage") private var initialPage: String = "overview"

    @State private var llmState: LLMCorrectionManager.ModelState = .notDownloaded

    var body: some View {
        Form {
            Section { summaryHeader }

            Section("Status") {
                asrStatusRow
                llmStatusRow
                permissionsStatusRow
                shortcutRow
            }

            if let last = lastTranscriptionSnippet {
                Section("Última transcrição") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(last.text)
                            .lineLimit(3)
                            .foregroundStyle(.primary)
                        Text(last.relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Visão Geral")
        .task(id: llmStateTaskID) {
            llmState = await appState.llmModelState()
        }
    }

    // MARK: - Header agregado

    private var summaryHeader: some View {
        let issues = attentionIssues
        let allGood = issues.isEmpty

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: allGood ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(allGood ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(allGood ? "Tudo funcionando" : "Atenção necessária")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(allGood
                         ? "zspeak está pronto para transcrever."
                         : "Verifique os itens abaixo para liberar todas as funcionalidades."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Linhas de status

    private var asrStatusRow: some View {
        statusRow(
            icon: "waveform",
            title: "Modelo de transcrição",
            status: asrStatus.text,
            color: asrStatus.color
        )
    }

    private var llmStatusRow: some View {
        HStack {
            statusRow(
                icon: "sparkles",
                title: "Correção LLM",
                status: llmStatusText,
                color: llmStatusColor
            )
            if case .notDownloaded = llmState {
                Spacer()
                Button("Configurar") {
                    initialPage = "correction"
                }
                .controlSize(.small)
            }
        }
    }

    private var permissionsStatusRow: some View {
        HStack {
            let pending = pendingPermissions
            statusRow(
                icon: "lock.shield",
                title: "Permissões",
                status: pending.isEmpty ? "Todas concedidas" : "\(pending.count) pendente\(pending.count == 1 ? "" : "s")",
                color: pending.isEmpty ? .green : .orange
            )
            if !pending.isEmpty {
                Spacer()
                Button("Abrir Permissões") {
                    initialPage = "permissions"
                }
                .controlSize(.small)
            }
        }
    }

    private var shortcutRow: some View {
        HStack {
            statusRow(
                icon: "keyboard",
                title: "Atalho",
                status: "\(activationKeyManager.selectedKey.rawValue) · \(activationKeyManager.activationMode.rawValue)",
                color: .secondary
            )
            Spacer()
            Button("Editar") {
                initialPage = "keyboard"
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func statusRow(icon: String, title: String, status: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color == .secondary ? .secondary : color)
                .frame(width: 18)
            Text(title)
            Spacer()
            Text(status)
                .foregroundStyle(color == .secondary ? .secondary : color)
                .font(.callout)
        }
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

    private var llmStatusColor: Color {
        switch llmState {
        case .notDownloaded: return .secondary
        case .downloading, .loading: return .orange
        case .downloaded, .ready: return .green
        case .error: return .red
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

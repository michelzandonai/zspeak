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
    @State private var selectedLLMModel = LLMModelOption.defaultModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZSPageHeader(
                    title: attentionIssues.isEmpty ? "Tudo funcionando" : "Atenção necessária",
                    subtitle: attentionIssues.isEmpty
                        ? "zspeak está pronto para transcrever localmente no Mac."
                        : "Resolva os itens pendentes para liberar gravação, colagem e correções.",
                    systemImage: attentionIssues.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
                    tone: attentionIssues.isEmpty ? .success : .warning
                ) {
                    ZSStatusChip(
                        text: attentionIssues.isEmpty ? "Pronto" : "\(attentionIssues.count) pendente\(attentionIssues.count == 1 ? "" : "s")",
                        tone: attentionIssues.isEmpty ? .success : .warning
                    )
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ZSMetricTile(title: "Transcrição", value: asrStatus.text, systemImage: "waveform", tone: asrTone)
                    ZSMetricTile(title: "LLM", value: llmStatusText, systemImage: "sparkles", tone: llmTone)
                    ZSMetricTile(title: "Permissões", value: pendingPermissions.isEmpty ? "OK" : "\(pendingPermissions.count)", systemImage: "lock.shield", tone: pendingPermissions.isEmpty ? .success : .warning)
                    ZSMetricTile(title: "Atalho", value: activationKeyManager.selectedKey.rawValue, systemImage: "keyboard", tone: .neutral)
                }

                ZSSectionCard {
                    sectionTitle("Estado operacional", systemImage: "list.bullet.rectangle")
                    asrStatusRow
                    Divider()
                    llmStatusRow
                    Divider()
                    permissionsStatusRow
                    Divider()
                    shortcutRow
                }

                if let last = lastTranscriptionSnippet {
                    ZSSectionCard {
                        sectionTitle("Última transcrição", systemImage: "text.bubble")
                        Text(last.text)
                            .lineLimit(4)
                            .textSelection(.enabled)
                            .foregroundStyle(.primary)
                        Text(last.relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(ZSDesign.pagePadding)
        }
        .background(ZSDesign.pageBackground)
        .navigationTitle("Visão Geral")
        .task(id: llmStateTaskID) {
            selectedLLMModel = await appState.selectedLLMModel()
            llmState = await appState.llmModelState()
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(.primary)
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
                status: "\(selectedLLMModel.shortName) · \(llmStatusText)",
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

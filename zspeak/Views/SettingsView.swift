import SwiftUI

// MARK: - Sidebar navigation

/// Enum das páginas de Settings. `rawValue` é estável (usado em
/// `@AppStorage("settings.initialPage")`), separado do título legível via
/// `title`.
enum SettingsPage: String, CaseIterable, Identifiable {
    case overview = "overview"
    case history = "history"
    case benchmark = "benchmark"
    case vocabulary = "vocabulary"
    case correction = "correction"
    case keyboard = "keyboard"
    case microphone = "microphone"
    case general = "general"
    case permissions = "permissions"
    case about = "about"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Visão Geral"
        case .history: "Histórico"
        case .benchmark: "Benchmark"
        case .vocabulary: "Vocabulário"
        case .correction: "Correção LLM"
        case .keyboard: "Atalhos de Teclado"
        case .microphone: "Microfone"
        case .general: "Geral"
        case .permissions: "Permissões"
        case .about: "Sobre"
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .history: "clock.arrow.circlepath"
        case .benchmark: "gauge.with.needle"
        case .vocabulary: "text.book.closed.fill"
        case .correction: "sparkles"
        case .keyboard: "keyboard.fill"
        case .microphone: "mic.fill"
        case .general: "gearshape.fill"
        case .permissions: "lock.shield.fill"
        case .about: "info"
        }
    }

    /// Cor do squircle do ícone na sidebar — mesma linguagem dos Ajustes do
    /// Sistema, onde cada área tem uma cor de identidade fixa.
    var tint: Color {
        switch self {
        case .overview: ZSDesign.accent
        case .history: ZSDesign.infoAccent
        case .benchmark: ZSDesign.warningAccent
        case .vocabulary: ZSDesign.successAccent
        case .correction: Color(red: 0.73, green: 0.56, blue: 1.0)
        case .keyboard: ZSDesign.neutralAccent
        case .microphone: ZSDesign.dangerAccent
        case .general: ZSDesign.neutralAccent
        case .permissions: ZSDesign.successAccent
        case .about: ZSDesign.infoAccent
        }
    }

    /// Seção da sidebar onde a página aparece.
    enum Section: String, CaseIterable {
        case content = "Conteúdo"
        case configuration = "Configurações"
        case system = "Sistema"
    }

    var section: Section {
        switch self {
        case .overview, .history, .benchmark: .content
        case .vocabulary, .correction, .keyboard, .microphone, .general: .configuration
        case .permissions, .about: .system
        }
    }
}

/// Sidebar própria do zspeak. Evita que o material translúcido padrão do
/// `List.sidebar` dilua a identidade azul-grafite em janelas claras.
struct SettingsSidebar: View {
    @Binding var selection: SettingsPage

    var body: some View {
        ZStack {
            ZSDesign.sidebarBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    brand

                    ForEach(SettingsPage.Section.allCases, id: \.self) { section in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(section.rawValue.uppercased())
                                .font(.caption2.weight(.semibold))
                                .tracking(0.8)
                                .foregroundStyle(ZSDesign.textTertiary)
                                .padding(.horizontal, 10)

                            ForEach(pages(in: section)) { page in
                                navigationButton(for: page)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
        }
        .preferredColorScheme(.dark)
    }

    private var brand: some View {
        HStack(spacing: 11) {
            ZSSettingsIcon(
                systemImage: "waveform.badge.mic",
                color: ZSDesign.accent,
                size: 34
            )

            VStack(alignment: .leading, spacing: 1) {
                Text("zspeak")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(ZSDesign.textPrimary)
                Text("Transcrição local")
                    .font(.caption)
                    .foregroundStyle(ZSDesign.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("zspeak, transcrição local")
    }

    private func navigationButton(for page: SettingsPage) -> some View {
        let isSelected = selection == page

        return Button {
            selection = page
        } label: {
            HStack(spacing: 10) {
                ZSSettingsIcon(systemImage: page.icon, color: page.tint, size: 22)
                Text(page.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? ZSDesign.textPrimary : ZSDesign.textSecondary)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: ZSDesign.compactRadius, style: .continuous)
                    .fill(isSelected ? ZSDesign.accent.opacity(0.15) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ZSDesign.compactRadius, style: .continuous)
                    .strokeBorder(isSelected ? ZSDesign.accent.opacity(0.42) : Color.clear, lineWidth: 0.7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func pages(in section: SettingsPage.Section) -> [SettingsPage] {
        SettingsPage.allCases.filter { $0.section == section }
    }
}

// MARK: - Settings View

/// Tela principal de Settings. Não possui init customizado: todas as
/// dependências vêm via `@Environment` injetado em `App.swift`. A página
/// inicial é controlada por `@AppStorage("settings.initialPage")`, permitindo
/// que o MenuBar abra a janela já na aba certa.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(MicrophoneManager.self) private var microphoneManager
    @Environment(ActivationKeyManager.self) private var activationKeyManager
    @Environment(AccessibilityManager.self) private var accessibilityManager
    @Environment(TranscriptionStore.self) private var store
    @Environment(BenchmarkStore.self) private var benchmarkStore
    @Environment(VocabularyStore.self) private var vocabularyStore
    @Environment(CorrectionPromptStore.self) private var correctionPromptStore

    @AppStorage("settings.initialPage") private var initialPageRaw: String = SettingsPage.overview.rawValue

    @State private var selectedPage: SettingsPage = .overview

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $selectedPage)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detailView(for: selectedPage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ZSDesign.pageBackground.ignoresSafeArea())
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 480, idealHeight: 560)
        .zsAppSurface()
        .onAppear {
            // Sincroniza a aba inicial com o AppStorage que o MenuBar manipula
            if let page = SettingsPage(rawValue: initialPageRaw) {
                selectedPage = page
            }
        }
        .onChange(of: initialPageRaw) { _, newValue in
            if let page = SettingsPage(rawValue: newValue) {
                selectedPage = page
            }
        }
        .onChange(of: selectedPage) { _, page in
            initialPageRaw = page.rawValue
        }
    }

    @ViewBuilder
    private func detailView(for page: SettingsPage) -> some View {
        switch page {
        case .overview:
            OverviewPage()
        case .history:
            HistoryView(store: store)
        case .benchmark:
            BenchmarkView(appState: appState, store: benchmarkStore, historyStore: store)
        case .vocabulary:
            VocabularyView(appState: appState, store: vocabularyStore)
        case .correction:
            CorrectionPromptsView(appState: appState, store: correctionPromptStore)
        case .keyboard:
            KeyboardPage()
        case .microphone:
            MicrophonePage()
        case .general:
            GeneralPage()
        case .permissions:
            PermissionsPage()
        case .about:
            AboutPage()
        }
    }
}

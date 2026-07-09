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
        case .overview: .blue
        case .history: .indigo
        case .benchmark: .orange
        case .vocabulary: .teal
        case .correction: .purple
        case .keyboard: .gray
        case .microphone: .red
        case .general: .gray
        case .permissions: .green
        case .about: .gray
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
            List(selection: $selectedPage) {
                ForEach(SettingsPage.Section.allCases, id: \.self) { section in
                    Section(section.rawValue) {
                        ForEach(pages(in: section)) { page in
                            Label {
                                Text(page.title)
                            } icon: {
                                ZSSettingsIcon(systemImage: page.icon, color: page.tint, size: 21)
                            }
                            .tag(page)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detailView(for: selectedPage)
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 480, idealHeight: 560)
        .tint(.accentColor)
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
    }

    private func pages(in section: SettingsPage.Section) -> [SettingsPage] {
        SettingsPage.allCases.filter { $0.section == section }
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

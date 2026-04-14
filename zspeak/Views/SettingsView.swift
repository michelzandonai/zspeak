import SwiftUI
import AppKit
import LaunchAtLogin
import KeyboardShortcuts

// MARK: - Window Controller

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private var currentHostingView: NSHostingView<SettingsView>?

    func show(
        appState: AppState,
        microphoneManager: MicrophoneManager,
        activationKeyManager: ActivationKeyManager,
        accessibilityManager: AccessibilityManager,
        store: TranscriptionStore,
        benchmarkStore: BenchmarkStore,
        vocabularyStore: VocabularyStore,
        correctionPromptStore: CorrectionPromptStore,
        initialPage: SettingsPage? = nil
    ) {
        if let window = window, window.isVisible {
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            // Se foi pedida uma página específica, reconstrói a view com initialPage
            if let initialPage {
                let updatedView = SettingsView(
                    appState: appState,
                    microphoneManager: microphoneManager,
                    activationKeyManager: activationKeyManager,
                    accessibilityManager: accessibilityManager,
                    store: store,
                    benchmarkStore: benchmarkStore,
                    vocabularyStore: vocabularyStore,
                    correctionPromptStore: correctionPromptStore,
                    initialPage: initialPage
                )
                let hostingView = NSHostingView(rootView: updatedView)
                window.contentView = hostingView
                self.currentHostingView = hostingView
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                window.level = .normal
            }
            return
        }

        let settingsView = SettingsView(
            appState: appState,
            microphoneManager: microphoneManager,
            activationKeyManager: activationKeyManager,
            accessibilityManager: accessibilityManager,
            store: store,
            benchmarkStore: benchmarkStore,
            vocabularyStore: vocabularyStore,
            correctionPromptStore: correctionPromptStore,
            initialPage: initialPage
        )
        let hostingView = NSHostingView(rootView: settingsView)
        self.currentHostingView = hostingView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 620, height: 420)
        window.title = "zspeak — Configurações"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            window.level = .normal
        }

        self.window = window
    }
}

// MARK: - Sidebar navigation

enum SettingsPage: String, CaseIterable, Identifiable {
    case history = "Histórico"
    case audioFile = "Transcrever Arquivo"
    case benchmark = "Benchmark"
    case vocabulary = "Vocabulário"
    case correction = "Correção LLM"
    case keyboard = "Atalhos de Teclado"
    case microphone = "Microfone"
    case general = "Geral"
    case permissions = "Permissões"
    case about = "Sobre"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .audioFile: "waveform.badge.plus"
        case .benchmark: "gauge.with.needle"
        case .vocabulary: "text.book.closed"
        case .correction: "sparkles"
        case .keyboard: "keyboard"
        case .microphone: "mic.fill"
        case .general: "gearshape"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    let appState: AppState
    @Bindable var microphoneManager: MicrophoneManager
    @Bindable var activationKeyManager: ActivationKeyManager
    var accessibilityManager: AccessibilityManager
    let store: TranscriptionStore
    @Bindable var benchmarkStore: BenchmarkStore
    @Bindable var vocabularyStore: VocabularyStore
    @Bindable var correctionPromptStore: CorrectionPromptStore

    @State private var selectedPage: SettingsPage

    init(
        appState: AppState,
        microphoneManager: MicrophoneManager,
        activationKeyManager: ActivationKeyManager,
        accessibilityManager: AccessibilityManager,
        store: TranscriptionStore,
        benchmarkStore: BenchmarkStore,
        vocabularyStore: VocabularyStore,
        correctionPromptStore: CorrectionPromptStore,
        initialPage: SettingsPage? = nil
    ) {
        self.appState = appState
        self.microphoneManager = microphoneManager
        self.activationKeyManager = activationKeyManager
        self.accessibilityManager = accessibilityManager
        self.store = store
        self.benchmarkStore = benchmarkStore
        self.vocabularyStore = vocabularyStore
        self.correctionPromptStore = correctionPromptStore
        self._selectedPage = State(initialValue: initialPage ?? .general)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: $selectedPage) { page in
                Label(page.rawValue, systemImage: page.icon)
                    .tag(page)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            detailView(for: selectedPage)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 420, idealHeight: 500)
    }

    @ViewBuilder
    private func detailView(for page: SettingsPage) -> some View {
        switch page {
        case .history:
            HistoryView(store: store)
        case .audioFile:
            AudioFileView(appState: appState, store: store)
        case .benchmark:
            BenchmarkView(appState: appState, store: benchmarkStore, historyStore: store)
        case .vocabulary:
            VocabularyView(appState: appState, store: vocabularyStore)
        case .correction:
            CorrectionPromptsView(appState: appState, store: correctionPromptStore)
        case .keyboard:
            keyboardPage
        case .microphone:
            microphonePage
        case .general:
            generalPage
        case .permissions:
            permissionsPage
        case .about:
            aboutPage
        }
    }

    // MARK: - Atalhos de Teclado

    private var keyboardPage: some View {
        Form {
            Section("Tecla de ativação") {
                Picker("Tecla", selection: $activationKeyManager.selectedKey) {
                    ForEach(ActivationKey.allCases) { key in
                        Text(key.rawValue).tag(key)
                    }
                }

                Picker("Modo", selection: $activationKeyManager.activationMode) {
                    ForEach(ActivationMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                KeyboardShortcuts.Recorder("Modo Prompt LLM:", name: .togglePromptMode)
            } header: {
                Text("Correção LLM")
            } footer: {
                Text("Atalho global para ligar/desligar o Modo Prompt. Quando ativo, o overlay fica visível com chips de prompts clicáveis. ESC também desliga.")
            }

            Section {
                Toggle("Escape cancela gravação", isOn: $activationKeyManager.escapeToCancel)
            } footer: {
                Text("Toggle: toque para iniciar/parar · Hold: grave enquanto pressiona · Double Tap: toque duas vezes")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Atalhos de Teclado")
    }

    // MARK: - Microfone

    /// ID do microfone que será usado na próxima gravação
    private var preferredMicrophoneID: String? {
        // Durante gravação, mostra o mic realmente ativo
        if let activeID = microphoneManager.activeMicrophoneID {
            return activeID
        }
        // Fora de gravação, mostra o primeiro conectado na ordem de prioridade
        return microphoneManager.microphones.first(where: \.isConnected)?.id
    }

    private var microphonePage: some View {
        Form {
            Section {
                Toggle("Usar padrão do sistema", isOn: $microphoneManager.useSystemDefault)
            }

            if !microphoneManager.useSystemDefault {
                Section {
                    // Em Form/.grouped no macOS, .onMove n\u00e3o oferece drag-to-reorder
                    // nativo confi\u00e1vel. Usamos bot\u00f5es de seta como alternativa acess\u00edvel.
                    ForEach(Array(microphoneManager.microphones.enumerated()), id: \.element.id) { index, mic in
                        HStack {
                            let isPreferred = mic.id == preferredMicrophoneID
                            Image(systemName: isPreferred ? "mic.circle.fill" : (mic.isConnected ? "mic" : "mic.slash"))
                                .foregroundStyle(isPreferred ? .green : (mic.isConnected ? .primary : .secondary))
                            Text(mic.name)
                                .foregroundStyle(mic.isConnected ? .primary : .secondary)
                            Spacer()
                            Button {
                                microphoneManager.reorder(
                                    fromOffsets: IndexSet(integer: index),
                                    toOffset: index - 1
                                )
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                            .help("Mover para cima")

                            Button {
                                microphoneManager.reorder(
                                    fromOffsets: IndexSet(integer: index),
                                    toOffset: index + 2
                                )
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == microphoneManager.microphones.count - 1)
                            .help("Mover para baixo")
                        }
                    }
                } header: {
                    Text("Ordem de prioridade")
                } footer: {
                    Text("Microfones são tentados na ordem acima. Use as setas para reordenar.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Microfone")
    }

    // MARK: - Geral

    private var generalPage: some View {
        Form {
            Section {
                LaunchAtLogin.Toggle("Iniciar com o sistema")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Geral")
    }

    // MARK: - Permissões

    private var permissionsPage: some View {
        Form {
            Section {
                HStack {
                    Label {
                        Text("Microfone")
                    } icon: {
                        Image(systemName: microphoneStatusIcon)
                            .foregroundStyle(microphoneStatusColor)
                    }

                    Spacer()

                    if microphoneManager.isPermissionGranted {
                        Text("Ativo")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.1), in: Capsule())
                    } else if microphoneManager.permissionState == .notDetermined {
                        Button("Solicitar Permissão") {
                            Task {
                                _ = await microphoneManager.requestPermissionIfNeeded()
                            }
                        }
                    } else if microphoneManager.permissionState != .unavailable {
                        Button("Abrir Ajustes do Sistema") {
                            microphoneManager.openSystemSettings()
                        }
                    }
                }
            } footer: {
                Text(microphonePermissionFooter)
            }

            Section {
                HStack {
                    Label {
                        Text("Acessibilidade")
                    } icon: {
                        Image(systemName: accessibilityManager.isGranted
                              ? "checkmark.circle.fill"
                              : "exclamationmark.triangle.fill")
                            .foregroundStyle(accessibilityManager.isGranted ? .green : .orange)
                    }

                    Spacer()

                    if accessibilityManager.isGranted {
                        Text("Ativo")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.1), in: Capsule())
                    } else {
                        Button("Abrir Ajustes do Sistema") {
                            accessibilityManager.openSystemSettings()
                        }
                    }
                }
            } footer: {
                Text("Necessário para colar no app ativo e para a hotkey global. Sem isso, a transcrição continua funcionando com cópia para o clipboard.")
            }

            if microphoneManager.permissionState == .unavailable {
                Section("Bundle") {
                    Text("O produto atual está sendo gerado como executável SwiftPM, sem `Info.plist` embutido. Nesse modo, o macOS não expõe a permissão de microfone de forma confiável.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if !microphoneManager.isPermissionGranted && microphoneManager.permissionState != .unavailable {
                Section("Como ativar o microfone") {
                    Label("Clique em \"Solicitar Permissão\" ou inicie uma gravação", systemImage: "1.circle")
                    Label("Se o macOS negar, abra Ajustes do Sistema", systemImage: "2.circle")
                    Label("Ative zspeak em Privacidade → Microfone", systemImage: "3.circle")
                }
            }

            if !accessibilityManager.isGranted {
                Section("Como ativar") {
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
        }
        .formStyle(.grouped)
        .navigationTitle("Permissões")
    }

    // MARK: - Sobre

    private var aboutPage: some View {
        Form {
            Section {
                LabeledContent("Modelo", value: "Parakeet TDT 0.6B V3")
                LabeledContent("Motor", value: "FluidAudio (CoreML/ANE)")
                LabeledContent("Processamento", value: "100% local")
            }

            Section {
                LabeledContent("Plataforma", value: "macOS 14+ (Apple Silicon)")
                LabeledContent("Privacidade", value: "Nenhum dado sai do dispositivo")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sobre")
    }

    private var microphoneStatusIcon: String {
        switch microphoneManager.permissionState {
        case .authorized:
            return "checkmark.circle.fill"
        case .notDetermined:
            return "questionmark.circle.fill"
        case .denied, .restricted, .unavailable:
            return "exclamationmark.triangle.fill"
        }
    }

    private var microphoneStatusColor: Color {
        switch microphoneManager.permissionState {
        case .authorized:
            return .green
        case .notDetermined:
            return .yellow
        case .denied, .restricted, .unavailable:
            return .orange
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
            return "O bundle atual não expõe `NSMicrophoneUsageDescription`, então o macOS não consegue liberar o microfone."
        }
    }
}

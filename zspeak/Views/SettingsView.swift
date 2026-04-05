import SwiftUI
import AppKit
import LaunchAtLogin

// MARK: - Window Controller

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(appState: AppState, microphoneManager: MicrophoneManager, activationKeyManager: ActivationKeyManager, accessibilityManager: AccessibilityManager, store: TranscriptionStore, benchmarkStore: BenchmarkStore, vocabularyStore: VocabularyStore) {
        if let window = window, window.isVisible {
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
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
            vocabularyStore: vocabularyStore
        )
        let hostingView = NSHostingView(rootView: settingsView)

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

private enum SettingsPage: String, CaseIterable, Identifiable {
    case history = "Histórico"
    case benchmark = "Benchmark"
    case vocabulary = "Vocabulário"
    case keyboard = "Atalhos de Teclado"
    case microphone = "Microfone"
    case general = "Geral"
    case permissions = "Permissões"
    case about = "Sobre"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .benchmark: "gauge.with.needle"
        case .vocabulary: "text.book.closed"
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

    @State private var selectedPage: SettingsPage = .history

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
        case .benchmark:
            BenchmarkView(appState: appState, store: benchmarkStore, historyStore: store)
        case .vocabulary:
            VocabularyView(appState: appState, store: vocabularyStore)
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
                Toggle("Escape cancela gravação", isOn: $activationKeyManager.escapeToCancel)
            } footer: {
                Text("Toggle: toque para iniciar/parar · Hold: grave enquanto pressiona · Double Tap: toque duas vezes")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Atalhos de Teclado")
    }

    // MARK: - Microfone

    private var microphonePage: some View {
        Form {
            Section {
                Toggle("Usar padrão do sistema", isOn: $microphoneManager.useSystemDefault)
            }

            if !microphoneManager.useSystemDefault {
                Section {
                    ForEach(Array(microphoneManager.microphones.enumerated()), id: \.element.id) { index, mic in
                        HStack {
                            if mic.isConnected {
                                Label(mic.name, systemImage: "mic")
                            } else {
                                Label(mic.name, systemImage: "mic.slash")
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if mic.id == microphoneManager.activeMicrophoneID {
                                Text("Ativo")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(.green.opacity(0.1), in: Capsule())
                            }
                        }
                    }
                    .onMove { source, destination in
                        microphoneManager.reorder(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    Text("Ordem de prioridade")
                } footer: {
                    Text("Microfones são tentados na ordem acima. Arraste para reordenar.")
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

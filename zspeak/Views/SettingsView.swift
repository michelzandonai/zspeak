import SwiftUI
import AppKit
import LaunchAtLogin

// MARK: - Window Controller

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(appState: AppState, microphoneManager: MicrophoneManager, activationKeyManager: ActivationKeyManager, accessibilityManager: AccessibilityManager) {
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
            accessibilityManager: accessibilityManager
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
    case keyboard = "Atalhos de Teclado"
    case microphone = "Microfone"
    case general = "Geral"
    case permissions = "Permissões"
    case about = "Sobre"

    var id: String { rawValue }

    var icon: String {
        switch self {
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

    @State private var selectedPage: SettingsPage = .keyboard

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
                Text("Necessário para inserir texto transcrito no app ativo via atalho de teclado.")
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
}

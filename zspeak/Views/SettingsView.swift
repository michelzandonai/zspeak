import SwiftUI
import AppKit
import LaunchAtLogin

/// Controlador da janela de configurações (abre via NSWindow programaticamente)
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(appState: AppState, microphoneManager: MicrophoneManager, activationKeyManager: ActivationKeyManager, accessibilityManager: AccessibilityManager) {
        if let window = window, window.isVisible {
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            // Voltar nível normal após aparecer (para não ficar always-on-top)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                window.level = .normal
            }
            return
        }

        let settingsView = SettingsView(appState: appState, microphoneManager: microphoneManager, activationKeyManager: activationKeyManager, accessibilityManager: accessibilityManager)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "zspeak — Configurações"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Voltar nível normal após aparecer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            window.level = .normal
        }

        self.window = window
    }
}

/// Tela de configurações do zspeak
struct SettingsView: View {
    let appState: AppState
    @Bindable var microphoneManager: MicrophoneManager
    @Bindable var activationKeyManager: ActivationKeyManager
    var accessibilityManager: AccessibilityManager

    var body: some View {
        Form {
            // Seção: Keyboard Controls
            Section("Keyboard Controls") {
                HStack {
                    Text("Activation Keys")
                    Spacer()
                    Picker("", selection: $activationKeyManager.selectedKey) {
                        ForEach(ActivationKey.allCases) { key in
                            Text(key.rawValue).tag(key)
                        }
                    }
                    .frame(width: 180)
                }

                HStack {
                    Spacer()
                    Picker("", selection: $activationKeyManager.activationMode) {
                        ForEach(ActivationMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                }

                Text("Configure shortcut keys and how they activate: Toggle (tap to start/stop), Hold (record while pressed), Double Tap (tap twice quickly).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(isOn: $activationKeyManager.escapeToCancel) {
                    Label("Use Escape to cancel recording", systemImage: "escape")
                }
            }

            // Seção: Geral
            Section("Geral") {
                LaunchAtLogin.Toggle("Iniciar com o sistema")
            }

            // Seção: Microfone
            Section("Microfone") {
                Toggle(isOn: $microphoneManager.useSystemDefault) {
                    Label("Usar padrão do sistema", systemImage: "mic")
                }

                if !microphoneManager.useSystemDefault {
                    List {
                        ForEach(Array(microphoneManager.microphones.enumerated()), id: \.element.id) { index, mic in
                            HStack(spacing: 8) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.secondary)

                                Text("\(index + 1).")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()

                                if mic.isConnected {
                                    Text(mic.name)
                                } else {
                                    Label(mic.name, systemImage: "mic.slash")
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if mic.id == microphoneManager.activeMicrophoneID {
                                    Circle()
                                        .fill(.green)
                                        .frame(width: 8, height: 8)
                                }
                            }
                        }
                        .onMove { source, destination in
                            microphoneManager.reorder(fromOffsets: source, toOffset: destination)
                        }
                    }
                    .frame(minHeight: 60)

                    Text("Microfones são tentados na ordem de prioridade. Arraste para reordenar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Seção: Permissões
            Section("Permissões") {
                HStack {
                    Image(systemName: accessibilityManager.isGranted
                          ? "checkmark.circle.fill"
                          : "exclamationmark.triangle.fill")
                        .foregroundStyle(accessibilityManager.isGranted ? .green : .orange)

                    Text("Acessibilidade")

                    Spacer()

                    if accessibilityManager.isGranted {
                        Text("Ativo")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else {
                        Button("Abrir Configurações") {
                            accessibilityManager.openSystemSettings()
                        }
                        Button("Solicitar Permissão") {
                            accessibilityManager.requestPermission()
                        }
                    }
                }

                if !accessibilityManager.isGranted {
                    Text("Permissão necessária para inserir texto no app ativo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Como ativar:")
                            .font(.caption)
                            .bold()
                        Text("1. Clique em 'Abrir Configurações' acima")
                            .font(.caption)
                        Text("2. Encontre 'zspeak' na lista")
                            .font(.caption)
                        Text("3. Ative o toggle")
                            .font(.caption)
                        Text("Se zspeak não aparece: clique '+', navegue até /Applications/zspeak.app")
                            .font(.caption)
                            .italic()
                    }
                    .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Resolução de problemas:")
                            .font(.caption)
                            .bold()
                        Text("Se o toggle está ativo mas aqui mostra negado: remova zspeak da lista, adicione novamente e reinicie o app.")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Text("Necessário para inserir texto no app ativo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Seção: Sobre
            Section("Sobre") {
                LabeledContent("Modelo", value: "Parakeet TDT 0.6B V3")
                LabeledContent("Motor", value: "FluidAudio (CoreML/ANE)")
                LabeledContent("Processamento", value: "100% local")
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 500)
    }
}

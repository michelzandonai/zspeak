import Cocoa

/// Gerencia permissão de Acessibilidade com polling e notificação de mudança de estado
@Observable
@MainActor
final class AccessibilityManager {

    /// Estado atual da permissão de Acessibilidade
    private(set) var isGranted: Bool = false

    /// Callback disparado quando a permissão transiciona de false → true
    var onPermissionGranted: (() -> Void)?

    /// Callback disparado quando a permissão transiciona de true → false
    var onPermissionRevoked: (() -> Void)?

    /// Timer usado para revalidar o estado da permissão ao longo da execução
    private var timer: Timer?

    init() {
        isGranted = AXIsProcessTrusted()
        print("[zspeak] Accessibility: estado inicial = \(isGranted)")
        startPolling()
    }

    // MARK: - Polling

    /// Inicia polling adaptativo: 1s enquanto aguarda permissão, 30s após concedida
    private func startPolling() {
        let interval: TimeInterval = isGranted ? 30.0 : 1.0
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkPermission()
            }
        }
    }

    /// Recria timer com novo intervalo (chamado nas transições de estado)
    private func restartPolling() {
        timer?.invalidate()
        startPolling()
    }

    private func checkPermission() {
        let granted = AXIsProcessTrusted()
        let wasGranted = isGranted
        isGranted = granted

        // Transição false → true: permissão concedida
        if granted && !wasGranted {
            print("[zspeak] Accessibility: permissão concedida")
            onPermissionGranted?()
            restartPolling() // Reduz para 30s
        }

        // Transição true → false: permissão revogada
        if !granted && wasGranted {
            print("[zspeak] Accessibility: permissão revogada")
            onPermissionRevoked?()
            restartPolling() // Aumenta para 1s
        }
    }

    // MARK: - Ações

    /// Solicita permissão de Acessibilidade (mostra prompt do sistema)
    func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Abre System Settings na seção de Acessibilidade
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

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

    /// Referência ao timer guardada fora do MainActor para invalidar no deinit
    nonisolated(unsafe) private var timer: Timer?

    init() {
        isGranted = AXIsProcessTrusted()
        print("[zspeak] Accessibility: estado inicial = \(isGranted)")
        startPolling()
    }

    deinit {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Polling

    /// Verifica permissão a cada 1 segundo
    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkPermission()
            }
        }
    }

    private func checkPermission() {
        let granted = AXIsProcessTrusted()
        let wasGranted = isGranted
        isGranted = granted

        // Transição false → true: permissão concedida
        if granted && !wasGranted {
            print("[zspeak] Accessibility: permissão concedida")
            onPermissionGranted?()
        }

        // Transição true → false: permissão revogada
        if !granted && wasGranted {
            print("[zspeak] Accessibility: permissão revogada")
            onPermissionRevoked?()
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

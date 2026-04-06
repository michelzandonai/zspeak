import AppKit
import SwiftUI

/// Painel flutuante que mostra feedback visual durante gravação
/// Aparece no topo central da tela, não rouba foco do app ativo
final class OverlayPanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Configurações do painel
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        // Não aparece no Dock, Mission Control, etc
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        // Não rouba foco
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        // Posiciona no topo central da tela
        positionAtBottomCenter()
    }

    /// Permite que SwiftUI receba eventos de mouse no painel
    override var canBecomeKey: Bool { true }

    /// Posiciona o painel na parte inferior central da tela principal
    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.minY + 80
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Mostra o painel com animação
    func show() {
        alphaValue = 0
        orderFrontRegardless()
        positionAtBottomCenter()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            self.animator().alphaValue = 1
        }
    }

    /// Esconde o painel com animação
    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            self.animator().alphaValue = 0
        }) { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
            }
        }
    }

    /// Configura o conteúdo SwiftUI UMA VEZ com o modelo observável
    /// Atualizações subsequentes são feitas via OverlayModel (sem recriar a view)
    func setupContent(model: OverlayModel) {
        contentView = NSHostingView(rootView: OverlayView(model: model))
    }
}

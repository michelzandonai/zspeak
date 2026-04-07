import AppKit
import SwiftUI

/// Painel flutuante que mostra feedback visual durante gravação
/// Aparece no topo central da tela, não rouba foco do app ativo
final class OverlayPanel: NSPanel {

    private static let xKey = "overlayPanelX"
    private static let yKey = "overlayPanelY"
    private static let collapsedWidth: CGFloat = 320
    private static let expandedWidth: CGFloat = 440
    private var hostingView: NSHostingView<OverlayView>?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.collapsedWidth, height: 80),
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

        // Permite arrastar pelo fundo
        isMovableByWindowBackground = true

        // Restaura posição salva ou usa default
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.xKey) != nil, defaults.object(forKey: Self.yKey) != nil {
            let x = CGFloat(defaults.double(forKey: Self.xKey))
            let y = CGFloat(defaults.double(forKey: Self.yKey))
            setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            positionAtBottomCenter()
        }

        // Persiste posição quando o usuário arrasta
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleDidMove(_ note: Notification) {
        let defaults = UserDefaults.standard
        defaults.set(Double(frame.origin.x), forKey: Self.xKey)
        defaults.set(Double(frame.origin.y), forKey: Self.yKey)
    }

    /// Posiciona o painel na parte inferior central da tela principal
    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.minY + 80
        setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Ajusta o tamanho do painel com base no conteúdo SwiftUI (intrinsic size)
    /// Chamado após qualquer mudança de estado que afete o layout
    func setExpanded(_ expanded: Bool) {
        let targetWidth = expanded ? Self.expandedWidth : Self.collapsedWidth
        // Força o hostingView a recalcular o fittingSize com a nova largura
        hostingView?.frame.size.width = targetWidth
        let targetHeight = hostingView?.fittingSize.height ?? 80
        guard frame.width != targetWidth || frame.height != targetHeight else { return }
        var newFrame = frame
        // Mantém a base do painel ancorada (cresce para cima)
        newFrame.origin.y -= (targetHeight - newFrame.height)
        newFrame.size.width = targetWidth
        newFrame.size.height = targetHeight
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().setFrame(newFrame, display: true)
        }
    }

    /// Mostra o painel com animação
    func show() {
        alphaValue = 0
        orderFrontRegardless()
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
        let hosting = NSHostingView(rootView: OverlayView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.postsFrameChangedNotifications = true
        contentView = hosting
        hostingView = hosting

        // Quando o SwiftUI mudar de tamanho (ex: modo prompt alternado, estado muda),
        // o NSHostingView posta frameDidChangeNotification e ajustamos o panel
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleContentSizeChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: hosting
        )
    }

    @objc private func handleContentSizeChange(_ note: Notification) {
        guard let hosting = hostingView else { return }
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        guard frame.size != size else { return }
        var newFrame = frame
        let heightDelta = size.height - newFrame.size.height
        newFrame.origin.y -= heightDelta
        newFrame.size = size
        setFrame(newFrame, display: true)
    }
}

import AppKit
import SwiftUI

/// Painel flutuante que mostra feedback visual durante gravação
/// Aparece no topo central da tela, não rouba foco do app ativo
final class OverlayPanel: NSPanel {

    private static let xKey = "overlayPanelX"
    private static let yKey = "overlayPanelY"

    private var hostingController: NSHostingController<OverlayView>?
    private var sizeObservation: NSKeyValueObservation?
    private var ignoresPositionPersistence = false
    private var currentAnchorRect: NSRect?
    private enum Orientation { case above, below }
    private var lockedOrientation: Orientation?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
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
            clampToVisibleScreen()
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
        // sizeObservation é NSKeyValueObservation — auto-invalida quando deallocado
    }

    /// Permite que o painel vire key window quando o usuário clica no TextField interno (TASK-013).
    /// Combinado com .nonactivatingPanel, isso permite input de teclado sem ativar o app zspeak —
    /// o foco vai pro TextField mas o app destino mantém o seu próprio "key" do ponto de vista do usuário.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc private func handleDidMove(_ note: Notification) {
        guard !ignoresPositionPersistence else { return }
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

    /// Configura o conteúdo SwiftUI UMA VEZ com o modelo observável.
    ///
    /// Usa NSHostingController com `.preferredContentSize`: a cada mudança no intrinsic
    /// size do SwiftUI (ex: troca de estado, modo prompt, resultado LLM), o controller
    /// atualiza `preferredContentSize`. Observamos essa propriedade via KVO e ajustamos
    /// o frame do panel automaticamente. Isso elimina o bug de medir `fittingSize` antes
    /// do SwiftUI renderizar (que acontecia com NSHostingView + frameDidChangeNotification).
    func setupContent(model: OverlayModel) {
        let controller = NSHostingController(rootView: OverlayView(model: model))
        controller.sizingOptions = [.preferredContentSize]
        hostingController = controller
        contentView = controller.view

        // Aplica tamanho inicial (sem animação — painel ainda escondido)
        adjustToPreferredSize(animated: false)

        // Observa mudanças subsequentes do tamanho preferido do SwiftUI
        sizeObservation = controller.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.adjustToPreferredSize(animated: true)
            }
        }
    }

    /// Ajusta o frame do painel para match exato com `preferredContentSize` do SwiftUI.
    /// Mantém a base do painel ancorada (cresce para cima em vez de para baixo).
    private func adjustToPreferredSize(animated: Bool) {
        guard let controller = hostingController else { return }
        let size = controller.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }
        // Evita chamadas redundantes
        guard abs(frame.width - size.width) > 0.5 || abs(frame.height - size.height) > 0.5 else {
            return
        }

        var newFrame = frame
        let heightDelta = size.height - newFrame.size.height
        newFrame.origin.y -= heightDelta
        newFrame.size = size
        if let currentAnchorRect {
            newFrame.origin = frameOriginNear(anchorRect: currentAnchorRect, size: size, useLock: true)
        }

        if animated && alphaValue > 0 && isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().setFrame(newFrame, display: true)
                if currentAnchorRect == nil {
                    clampToVisibleScreen()
                }
            }
        } else {
            setFrame(newFrame, display: true)
            if currentAnchorRect == nil {
                clampToVisibleScreen()
            }
        }
    }

    /// Garante que o painel nunca fique salvo fora da área visível do monitor.
    /// Isso cobre mudanças de monitor/resolução e restores antigos com `y`
    /// negativo que deixam o overlay invisível.
    private func clampToVisibleScreen() {
        guard let screen = nearestScreen() ?? NSScreen.main else { return }

        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        var origin = frame.origin

        let maxX = visible.maxX - frame.width
        let maxY = visible.maxY - frame.height

        origin.x = min(max(origin.x, visible.minX), maxX)
        origin.y = min(max(origin.y, visible.minY), maxY)

        guard abs(origin.x - frame.origin.x) > 0.5 || abs(origin.y - frame.origin.y) > 0.5 else { return }

        setFrameOrigin(origin)
        if !ignoresPositionPersistence {
            let defaults = UserDefaults.standard
            defaults.set(Double(origin.x), forKey: Self.xKey)
            defaults.set(Double(origin.y), forKey: Self.yKey)
        }
    }

    private func nearestScreen() -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)

        if let containing = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) }) {
            return containing
        }

        return NSScreen.screens.min { lhs, rhs in
            distanceSquared(from: center, to: centerPoint(of: lhs.visibleFrame)) < distanceSquared(from: center, to: centerPoint(of: rhs.visibleFrame))
        }
    }

    private func centerPoint(of rect: NSRect) -> NSPoint {
        NSPoint(x: rect.midX, y: rect.midY)
    }

    private func distanceSquared(from lhs: NSPoint, to rhs: NSPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    /// Mostra o painel com animação.
    ///
    /// Ordena front com alpha = 0, depois dispara async o ajuste de tamanho +
    /// fade-in. O async dispatch dá ao SwiftUI uma iteração do runloop para
    /// renderizar pendências do modelo (ex: `state = .recording` recém-setado),
    /// garantindo que `preferredContentSize` reflita o estado correto antes
    /// do painel ficar visível.
    func show(near anchorRect: NSRect? = nil) {
        currentAnchorRect = anchorRect
        ignoresPositionPersistence = anchorRect != nil
        if let anchorRect {
            lockedOrientation = nil // Reset lock to let positionNear decide initial orientation
            positionNear(anchorRect: anchorRect)
        }

        alphaValue = 0
        orderFrontRegardless()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.adjustToPreferredSize(animated: false)
            if let anchorRect = self.currentAnchorRect {
                self.positionNear(anchorRect: anchorRect)
            } else {
                self.clampToVisibleScreen()
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                self.animator().alphaValue = 1
            }
        }
    }

    func moveNear(_ anchorRect: NSRect) {
        currentAnchorRect = anchorRect
        ignoresPositionPersistence = true
        positionNear(anchorRect: anchorRect)
    }

    func clearTransientAnchor() {
        guard currentAnchorRect != nil || ignoresPositionPersistence else { return }
        currentAnchorRect = nil
        ignoresPositionPersistence = false
        clampToVisibleScreen()
    }

    private func positionNear(anchorRect: NSRect) {
        setFrameOrigin(frameOriginNear(anchorRect: anchorRect, size: frame.size, useLock: false))
    }

    private func frameOriginNear(anchorRect: NSRect, size: NSSize, useLock: Bool) -> NSPoint {
        guard let screen = screen(containing: anchorRect) ?? NSScreen.main else { return frame.origin }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let gap: CGFloat = 10

        let originAbove = NSPoint(
            x: anchorRect.midX - size.width / 2,
            y: anchorRect.maxY + gap
        )
        let originBelow = NSPoint(
            x: anchorRect.midX - size.width / 2,
            y: anchorRect.minY - size.height - gap
        )

        var origin: NSPoint
        if useLock, let lock = lockedOrientation {
            origin = lock == .above ? originAbove : originBelow
        } else {
            // Decide initial orientation: prefer top, but use bottom if top is off-screen
            if originAbove.y + size.height > visible.maxY {
                origin = originBelow
                lockedOrientation = .below
            } else {
                origin = originAbove
                lockedOrientation = .above
            }
        }

        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return origin
    }

    private func screen(containing rect: NSRect) -> NSScreen? {
        let point = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.visibleFrame.contains(point) }
    }

    /// Esconde o painel com animação
    func hide() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            self.animator().alphaValue = 0
        }) { [weak self] in
            MainActor.assumeIsolated {
                self?.currentAnchorRect = nil
                self?.lockedOrientation = nil
                self?.ignoresPositionPersistence = false
                self?.orderOut(nil)
            }
        }
    }
}

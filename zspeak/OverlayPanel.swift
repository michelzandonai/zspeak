import AppKit
import SwiftUI

/// Painel flutuante que mostra feedback visual durante gravação
/// Aparece no topo central da tela, não rouba foco do app ativo
final class OverlayPanel: NSPanel {

    private static let xKey = "overlayPanelX"
    /// Legado: origem inferior-esquerda. Mantido só para migração — a altura
    /// do painel varia por estado, então restaurar a base movia o overlay a
    /// cada relaunch (o init usa 80pt e o conteúdo cresce ancorado no topo).
    private static let legacyYKey = "overlayPanelY"
    /// Âncora persistida: topo do painel (`frame.maxY`). O topo é o que fica
    /// fixo em todos os resizes programáticos (`adjustToPreferredSize`), então
    /// é a única coordenada estável entre estados e relaunches.
    private static let topYKey = "overlayPanelTopY"

    private var hostingController: NSHostingController<OverlayView>?
    private var sizeObservation: NSKeyValueObservation?
    private var ignoresPositionPersistence = false
    private var currentAnchorRect: NSRect?
    private enum Orientation { case above, below }
    private var lockedOrientation: Orientation?

    /// Canto superior esquerdo vigente do overlay — FONTE ÚNICA da posição.
    /// Todo posicionamento programático (resize, show, hide) deriva o frame
    /// daqui em vez de ler `frame` (que pode estar no meio de uma animação);
    /// o usuário atualiza a âncora ao arrastar o painel (didMove). Isso impede
    /// que offsets transitórios (rise-in do show, drift do hide) ou relayouts
    /// durante o fade "vazem" para a posição e façam o overlay migrar um pouco
    /// a cada gravação.
    private var anchorTopLeft: NSPoint = .zero
    /// > 0 enquanto uma animação transitória (rise-in/drift) está em voo —
    /// didMove desses moves não pode adotar o deslocamento na âncora. Contador
    /// (e não Bool) para sobreviver a show/hide sobrepostos.
    private var transientAnimationCount = 0

    /// Seam testável do "Reduce Motion" do sistema: no xctest headless o
    /// NSWorkspace reporta true e os caminhos animados de show/hide nunca
    /// executariam — os testes de regressão forçam false para exercitá-los.
    var prefersReducedMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

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

        // Restaura a âncora salva ou usa o default (inferior central).
        let defaults = UserDefaults.standard
        let hasTopY = defaults.object(forKey: Self.topYKey) != nil
        let hasLegacyY = defaults.object(forKey: Self.legacyYKey) != nil
        if defaults.object(forKey: Self.xKey) != nil, hasTopY || hasLegacyY {
            let x = CGFloat(defaults.double(forKey: Self.xKey))
            let topY: CGFloat
            if hasTopY {
                topY = CGFloat(defaults.double(forKey: Self.topYKey))
            } else {
                // Migração do formato antigo (origem inferior-esquerda).
                topY = CGFloat(defaults.double(forKey: Self.legacyYKey)) + frame.height
            }
            anchorTopLeft = NSPoint(x: x, y: topY)
            clampAnchorToVisibleScreen(for: frame.size)
            setFrameOrigin(derivedOrigin(for: frame.size))
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
        // Só drags do usuário (e o próprio clamp) atualizam a âncora. Moves
        // transitórios (rise-in/drift) são bloqueados pelo contador; resizes
        // programáticos preservam o topo, então adotá-los aqui é inócuo.
        guard !ignoresPositionPersistence, transientAnimationCount == 0 else { return }
        anchorTopLeft = NSPoint(x: frame.origin.x, y: frame.maxY)
        persistAnchor()
    }

    /// Origem (inferior-esquerda) derivada da âncora para um painel de `size`.
    private func derivedOrigin(for size: NSSize) -> NSPoint {
        NSPoint(x: anchorTopLeft.x, y: anchorTopLeft.y - size.height)
    }

    /// Salva a âncora superior esquerda em UserDefaults.
    private func persistAnchor() {
        guard !ignoresPositionPersistence else { return }
        let defaults = UserDefaults.standard
        defaults.set(Double(anchorTopLeft.x), forKey: Self.xKey)
        defaults.set(Double(anchorTopLeft.y), forKey: Self.topYKey)
        defaults.removeObject(forKey: Self.legacyYKey)
    }

    /// Posiciona o painel na parte inferior central da tela principal
    private func positionAtBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        anchorTopLeft = NSPoint(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.minY + 80 + frame.height
        )
        setFrameOrigin(derivedOrigin(for: frame.size))
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
    /// O frame alvo deriva SEMPRE da âncora (topo fixo, cresce/encolhe para
    /// baixo) — nunca do `frame` corrente, que pode estar no meio de uma
    /// animação e propagaria o deslocamento transitório para a posição final.
    private func adjustToPreferredSize(animated: Bool) {
        guard let controller = hostingController else { return }
        let size = controller.preferredContentSize
        guard size.width > 0, size.height > 0 else { return }

        let newFrame: NSRect
        if let currentAnchorRect {
            newFrame = NSRect(
                origin: frameOriginNear(anchorRect: currentAnchorRect, size: size, useLock: true),
                size: size
            )
        } else {
            if clampAnchorToVisibleScreen(for: size) {
                persistAnchor()
            }
            newFrame = NSRect(origin: derivedOrigin(for: size), size: size)
        }

        // Evita chamadas redundantes
        guard abs(frame.width - newFrame.width) > 0.5
            || abs(frame.height - newFrame.height) > 0.5
            || abs(frame.origin.x - newFrame.origin.x) > 0.5
            || abs(frame.origin.y - newFrame.origin.y) > 0.5 else {
            return
        }

        if animated && alphaValue > 0 && isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: true)
        }
    }

    /// Clampa a ÂNCORA à área visível do monitor mais próximo para um painel
    /// de `size`. Cobre mudanças de monitor/resolução e restores antigos fora
    /// da tela. Retorna true se a âncora precisou mudar.
    @discardableResult
    private func clampAnchorToVisibleScreen(for size: NSSize) -> Bool {
        let derivedFrame = NSRect(origin: derivedOrigin(for: size), size: size)
        guard let screen = nearestScreen(to: derivedFrame) ?? NSScreen.main else { return false }

        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        var anchor = anchorTopLeft

        anchor.x = min(max(anchor.x, visible.minX), max(visible.minX, visible.maxX - size.width))
        anchor.y = min(max(anchor.y, visible.minY + size.height), visible.maxY)

        guard abs(anchor.x - anchorTopLeft.x) > 0.5 || abs(anchor.y - anchorTopLeft.y) > 0.5 else {
            return false
        }
        anchorTopLeft = anchor
        return true
    }

    /// Garante que o painel esteja na posição derivada da âncora (clampada).
    private func clampToVisibleScreen() {
        if clampAnchorToVisibleScreen(for: frame.size) {
            persistAnchor()
        }
        let target = derivedOrigin(for: frame.size)
        guard abs(target.x - frame.origin.x) > 0.5 || abs(target.y - frame.origin.y) > 0.5 else { return }
        setFrameOrigin(target)
    }

    private func nearestScreen(to rect: NSRect) -> NSScreen? {
        let center = NSPoint(x: rect.midX, y: rect.midY)

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

            // Entrada "rise-in": nasce 10pt abaixo e sobe com fade até a
            // posição final. Com Reduce Motion, só o fade.
            let reduceMotion = self.prefersReducedMotion()
            guard !reduceMotion else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.1
                    self.animator().alphaValue = 1
                }
                return
            }

            // O deslocamento é transitório — o contador impede que didMove o
            // adote na âncora (didMove dispara também em moves programáticos).
            let target = self.frame.origin
            self.transientAnimationCount += 1
            self.setFrameOrigin(NSPoint(x: target.x, y: target.y - 10))
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().alphaValue = 1
                self.animator().setFrameOrigin(target)
            }) { [weak self] in
                MainActor.assumeIsolated {
                    self?.transientAnimationCount -= 1
                }
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
        // Adota a posição em que o modo ancorado deixou o painel — o overlay
        // permanece onde a tradução o posicionou (comportamento histórico).
        anchorTopLeft = NSPoint(x: frame.origin.x, y: frame.maxY)
        clampToVisibleScreen()
        persistAnchor()
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

    /// Esconde o painel com fade + leve drift para baixo (espelho da entrada).
    func hide() {
        let reduceMotion = prefersReducedMotion()
        // Drift transitório + relayouts durante o fade não podem tocar a âncora.
        transientAnimationCount += 1

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0.1 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.animator().alphaValue = 0
            if !reduceMotion {
                self.animator().setFrameOrigin(
                    NSPoint(x: self.frame.origin.x, y: self.frame.origin.y - 8)
                )
            }
        }) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentAnchorRect = nil
                self.lockedOrientation = nil
                self.orderOut(nil)
                self.ignoresPositionPersistence = false
                // Reposiciona a partir da âncora: o conteúdo pode ter mudado
                // de altura durante o fade (relayout para idle), então
                // restaurar a origem capturada antes do fade deslocaria o
                // topo — era a causa do overlay "descer" a cada gravação.
                self.setFrameOrigin(self.derivedOrigin(for: self.frame.size))
                self.transientAnimationCount -= 1
            }
        }
    }
}

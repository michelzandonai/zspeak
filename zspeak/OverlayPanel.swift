import AppKit
import SwiftUI

/// Painel flutuante que mostra feedback visual durante gravação
/// Aparece no topo central da tela, não rouba foco do app ativo
final class OverlayPanel: NSPanel {

    private static let xKey = "overlayPanelX"
    private static let yKey = "overlayPanelY"

    private var hostingController: NSHostingController<OverlayView>?
    private var sizeObservation: NSKeyValueObservation?

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

        if animated && alphaValue > 0 && isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: true)
        }
    }

    /// Mostra o painel com animação.
    ///
    /// Ordena front com alpha = 0, depois dispara async o ajuste de tamanho +
    /// fade-in. O async dispatch dá ao SwiftUI uma iteração do runloop para
    /// renderizar pendências do modelo (ex: `state = .recording` recém-setado),
    /// garantindo que `preferredContentSize` reflita o estado correto antes
    /// do painel ficar visível.
    func show() {
        alphaValue = 0
        orderFrontRegardless()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.adjustToPreferredSize(animated: false)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                self.animator().alphaValue = 1
            }
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
}

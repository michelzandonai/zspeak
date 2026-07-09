import AppKit
import SwiftUI

/// Mini-overlay de informação do "modo tray": faixa discreta logo abaixo da
/// barra de menu (borda direita alinhada ao item do tray) que mostra o
/// conteúdo COMPLETO da transcrição ao vivo em fonte pequena, quebrando em
/// linhas — o item do tray só comporta a cauda. Neste modo o overlay grande
/// (com a animação de voz) fica suprimido durante o ciclo de ditado.
///
/// Fluidez: a JANELA tem tamanho fixo e nunca anima frame — todo movimento
/// (entrada/saída do pill, crescimento, datilografia, dot pulsando) é SwiftUI
/// puro dentro dela, dirigido por Core Animation.
enum TrayInfoOverlay {
    /// Tunável sem rebuild:
    /// `defaults write com.zspeak.app trayInfoOverlayWidth -float 520`
    static let widthDefaultsKey = "trayInfoOverlayWidth"
    static let defaultWidth: CGFloat = 460
    /// Piso para valores customizados — abaixo disso o texto vira coluna.
    static let minimumWidth: CGFloat = 220

    /// Respiro entre a barra de menu e o pill.
    static let topGap: CGFloat = 6
    /// Margem lateral mínima até as bordas da tela.
    static let edgeMargin: CGFloat = 8
    /// Altura máxima do pill (≈9 linhas + padding) — o teto de caracteres
    /// abaixo garante que o texto exibido caiba.
    static let pillMaxHeight: CGFloat = 150
    /// Folga transparente da janela ao redor do pill — espaço para a sombra
    /// e para o overshoot do spring de entrada, sem clipping.
    static let windowPadding: CGFloat = 16
    /// Teto de caracteres exibidos (~8 linhas na largura default) — acima
    /// disso mantém a CAUDA (palavras mais novas), com reticência à frente.
    static let maxDisplayCharacters = 560

    static func width(defaults: UserDefaults = .standard) -> CGFloat {
        let raw = defaults.double(forKey: widthDefaultsKey)
        guard raw > 0 else { return defaultWidth }
        return max(minimumWidth, CGFloat(raw))
    }

    /// Visível durante o ciclo de ditado do modo tray. Some quando o Modo
    /// Prompt está ativo — nesse caso o overlay grande está em cena com a UI
    /// completa e o mini-overlay duplicaria a informação.
    static func isVisible(
        state: AppState.RecordingState,
        trayModeEnabled: Bool,
        promptModeActive: Bool
    ) -> Bool {
        trayModeEnabled && !promptModeActive && state != .idle
    }

    /// No modo tray o overlay grande não participa do ciclo de ditado — o
    /// feedback vem do item do tray + mini-overlay. Modo Prompt e tradução
    /// continuam usando o overlay grande (a gate do OverlayController fica só
    /// na cláusula de ditado).
    static func suppressesMainOverlay(
        state: AppState.RecordingState,
        trayModeEnabled: Bool
    ) -> Bool {
        trayModeEnabled && state != .idle
    }

    /// Mantém a cauda quando o texto excede o teto, cortando na fronteira de
    /// palavra e sinalizando o corte com reticência.
    static func displayTailText(
        _ text: String,
        maxCharacters: Int = maxDisplayCharacters
    ) -> String {
        guard text.count > maxCharacters else { return text }
        let tail = text.suffix(maxCharacters)
        let wordAligned = tail
            .drop(while: { !$0.isWhitespace })
            .drop(while: \.isWhitespace)
        return "…" + (wordAligned.isEmpty ? tail : wordAligned)
    }

    /// Origem da ÁREA DO PILL: logo abaixo da barra de menu, borda direita
    /// alinhada ao item do tray (sem âncora, ao canto direito da tela), sempre
    /// dentro da área visível. `screenVisibleFrame` já exclui a barra de menu.
    /// A janela real é essa área expandida por `windowPadding`.
    static func origin(
        panelSize: NSSize,
        statusItemFrame: NSRect?,
        screenVisibleFrame: NSRect
    ) -> NSPoint {
        let rightEdge = statusItemFrame?.maxX ?? (screenVisibleFrame.maxX - edgeMargin)
        var x = rightEdge - panelSize.width
        x = max(x, screenVisibleFrame.minX + edgeMargin)
        x = min(x, screenVisibleFrame.maxX - edgeMargin - panelSize.width)
        let y = screenVisibleFrame.maxY - topGap - panelSize.height
        return NSPoint(x: x, y: y)
    }
}

/// Estado observável do mini-overlay — a rootView é criada UMA vez e o
/// SwiftUI reage às mudanças (com transições), em vez de trocar a árvore
/// inteira a cada palavra transcrita.
@MainActor
@Observable
final class TrayInfoOverlayModel {
    var presentation = TrayPreviewPresentation(
        length: 0,
        text: "",
        symbolName: nil,
        isRecordingDot: false,
        isLivePreview: true,
        isPlaceholderText: false
    )
    /// Dirige a transição de entrada/saída do pill (o painel fica em cena
    /// durante a animação de saída antes do orderOut).
    var isShown = false
    /// false nos harnesses estáticos (ImageRenderer não roda o Task de
    /// datilografia — renderiza o texto completo de uma vez).
    var typingEnabled = true
    /// Seam de Reduce Motion (nil = usa o ambiente do sistema) — os testes
    /// forçam um valor para exercitar/congelar os caminhos animados.
    var reduceMotionOverride: Bool?
}

/// Conteúdo SwiftUI do mini-overlay: pill de material ancorado no canto
/// superior direito da janela fixa, com datilografia da transcrição (mesmo
/// motor ProgressiveTextReveal do overlay grande), dot de gravação pulsando e
/// waveform animada no processing.
struct TrayInfoOverlayView: View {
    let model: TrayInfoOverlayModel

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool {
        model.reduceMotionOverride ?? systemReduceMotion
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
            if model.isShown {
                pill
                    .transition(
                        reduceMotion
                            ? .opacity.animation(.easeOut(duration: 0.12))
                            : .asymmetric(
                                insertion: .opacity
                                    .combined(with: .scale(scale: 0.92, anchor: .topTrailing))
                                    .combined(with: .offset(y: -5)),
                                removal: .opacity
                                    .combined(with: .scale(scale: 0.97, anchor: .topTrailing))
                            )
                    )
            }
        }
        .padding(TrayInfoOverlay.windowPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var pill: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            statusIcon
                .frame(width: 11, alignment: .center)
            textContent
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 9, x: 0, y: 3)
        // Crossfade suave entre placeholder ("Ouvindo…") e texto real, e no
        // crescimento do pill a cada quebra de linha.
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: model.presentation.isPlaceholderText
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        if model.presentation.isRecordingDot {
            TrayPulsingDot(reduceMotion: reduceMotion)
        } else if model.presentation.symbolName != nil {
            // Processing: waveform com barras animadas (variable color).
            Image(systemName: "waveform")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .symbolEffect(
                    .variableColor.iterative,
                    options: .repeating,
                    isActive: !reduceMotion
                )
        }
    }

    @ViewBuilder
    private var textContent: some View {
        if model.presentation.isPlaceholderText {
            Text(model.presentation.text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        } else {
            TrayProgressiveText(
                text: TrayInfoOverlay.displayTailText(model.presentation.text),
                animate: model.typingEnabled && !reduceMotion
            )
            .transition(.opacity)
        }
    }
}

/// Dot de gravação com pulso respirado — para o pill parecer "vivo" enquanto
/// escuta. Congela em opacidade cheia com Reduce Motion.
private struct TrayPulsingDot: View {
    let reduceMotion: Bool
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color(nsColor: .systemRed))
            .frame(width: 7.5, height: 7.5)
            .opacity(pulsing && !reduceMotion ? 0.4 : 1)
            .animation(
                reduceMotion
                    ? nil
                    : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}

/// Datilografia do texto ao vivo no pill — mesmo padrão do
/// ProgressiveTranscriptText do overlay grande (revealStep: correções
/// interiores trocam no lugar, só a cauda nova é datilografada), com fonte
/// pequena e sem animação por passo (a cadência de ~30-50 chars/s já dá a
/// sensação de digitação).
private struct TrayProgressiveText: View {
    let text: String
    let animate: Bool

    @State private var displayedText: String = ""
    @State private var targetText: String = ""
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        Text(displayedText)
            .font(.system(size: 11))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { updateRevealTarget(text) }
            .onChange(of: text) { _, newValue in
                updateRevealTarget(newValue)
            }
            .onChange(of: animate) {
                updateRevealTarget(text)
            }
            .onDisappear {
                revealTask?.cancel()
                revealTask = nil
            }
    }

    @MainActor
    private func updateRevealTarget(_ target: String) {
        targetText = target

        guard animate else {
            revealTask?.cancel()
            revealTask = nil
            displayedText = target
            return
        }

        guard revealTask == nil else { return }
        revealTask = Task { @MainActor in
            await revealCurrentTarget()
        }
    }

    @MainActor
    private func revealCurrentTarget() async {
        defer {
            let shouldContinue = !Task.isCancelled && displayedText != targetText && animate
            revealTask = nil
            if shouldContinue {
                updateRevealTarget(targetText)
            }
        }

        revealLoop: while displayedText != targetText, !Task.isCancelled {
            let nextTarget = targetText
            let step = ProgressiveTextReveal.revealStep(
                current: displayedText,
                target: nextTarget
            )

            // Correções interiores trocam no lugar — sem apagar/redigitar.
            if displayedText != step.base {
                withAnimation(.easeOut(duration: 0.12)) {
                    displayedText = step.base
                }
            }

            while displayedText != nextTarget, !Task.isCancelled {
                if targetText != nextTarget {
                    continue revealLoop
                }

                let remaining = max(0, nextTarget.count - displayedText.count)
                let batchSize = ProgressiveTextReveal.batchSize(
                    remainingCharacterCount: remaining
                )
                displayedText = ProgressiveTextReveal.nextText(
                    current: displayedText,
                    target: nextTarget,
                    maxCharacters: batchSize
                )

                let delay = ProgressiveTextReveal.frameDelayMilliseconds(
                    remainingCharacterCount: max(0, nextTarget.count - displayedText.count)
                )
                if delay > 0 {
                    try? await Task.sleep(for: .milliseconds(Int64(delay)))
                } else {
                    await Task.yield()
                }
            }
        }
    }
}

/// Painel do mini-overlay: não rouba foco, não intercepta cliques e vive no
/// nível da barra de status. Frame FIXO por ciclo de apresentação (calculado
/// uma vez no primeiro present) — a janela nunca anima nem redimensiona; todo
/// movimento acontece no SwiftUI interno. Sombra desenhada pelo SwiftUI
/// (hasShadow da janela ficaria com artefatos ao redor da área transparente).
@MainActor
final class TrayInfoOverlayPanel: NSPanel {

    private let model = TrayInfoOverlayModel()
    private var isPresented = false
    /// Invalida o orderOut agendado se um novo present chegar durante a
    /// animação de saída.
    private var dismissGeneration = 0

    /// Seam testável do "Reduce Motion" do sistema (mesmo padrão do
    /// OverlayPanel) — xctest headless reporta true e congelaria os caminhos
    /// animados que os harnesses precisam exercitar.
    var prefersReducedMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    init() {
        super.init(
            contentRect: NSRect(
                x: 0, y: 0,
                width: TrayInfoOverlay.defaultWidth + TrayInfoOverlay.windowPadding * 2,
                height: TrayInfoOverlay.pillMaxHeight + TrayInfoOverlay.windowPadding * 2
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Puramente informativo — cliques atravessam para o que estiver atrás.
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let hostingController = NSHostingController(
            rootView: TrayInfoOverlayView(model: model)
        )
        // SEM constraints de tamanho do SwiftUI na janela: o default
        // (.standardBounds) impõe o tamanho "ideal" do conteúdo e o autolayout
        // redimensionava o painel por baixo do setFrame manual (painel inflava
        // milhares de pt e o pill "descia" a cada fala). Frame 100% manual.
        hostingController.sizingOptions = []
        contentView = hostingController.view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Atualiza o conteúdo e garante o painel visível. O frame é calculado só
    /// no PRIMEIRO present do ciclo (janela fixa; tela e posição não mudam no
    /// meio do ditado) — atualizações seguintes só alimentam o modelo.
    func present(_ presentation: TrayPreviewPresentation, anchoredTo button: NSStatusBarButton?) {
        model.reduceMotionOverride = prefersReducedMotion()
        model.presentation = presentation

        guard !isPresented else { return }
        guard let screen = button?.window?.screen ?? NSScreen.main else { return }
        isPresented = true
        dismissGeneration += 1

        let pillArea = NSRect(
            origin: TrayInfoOverlay.origin(
                panelSize: NSSize(width: TrayInfoOverlay.width(), height: TrayInfoOverlay.pillMaxHeight),
                statusItemFrame: button?.window?.frame,
                screenVisibleFrame: screen.visibleFrame
            ),
            size: NSSize(width: TrayInfoOverlay.width(), height: TrayInfoOverlay.pillMaxHeight)
        )
        setFrame(
            pillArea.insetBy(
                dx: -TrayInfoOverlay.windowPadding,
                dy: -TrayInfoOverlay.windowPadding
            ),
            display: true
        )
        alphaValue = 1
        orderFrontRegardless()

        // A entrada anima como transição SwiftUI — o hop de runloop garante
        // que a primeira renderização aconteça com isShown=false para a
        // transição de inserção rodar.
        let reduce = prefersReducedMotion()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented else { return }
            withAnimation(
                reduce
                    ? .easeOut(duration: 0.12)
                    : .spring(response: 0.38, dampingFraction: 0.78)
            ) {
                self.model.isShown = true
            }
        }
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        dismissGeneration += 1
        let generation = dismissGeneration

        withAnimation(
            prefersReducedMotion()
                ? .easeOut(duration: 0.1)
                : .easeIn(duration: 0.16)
        ) {
            model.isShown = false
        }

        // orderOut depois da transição de saída do pill.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(240))
            guard let self, !self.isPresented, generation == self.dismissGeneration else { return }
            self.orderOut(nil)
        }
    }

    /// Acesso do harness visual/testes ao modelo (datilografia, seams).
    var overlayModel: TrayInfoOverlayModel { model }
}

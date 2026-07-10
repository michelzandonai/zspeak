import AppKit
import SwiftUI

/// Mini-overlay de informação do "modo tray": faixa discreta logo abaixo da
/// barra de menu (borda direita alinhada ao item do tray) que mostra o
/// a cauda recente da transcrição ao vivo em até quatro linhas — o item do
/// tray fica reduzido ao selo de estado. Neste modo o overlay grande
/// (com a animação de voz) fica suprimido durante o ciclo de ditado.
///
/// Fluidez: a JANELA tem tamanho fixo e nunca anima frame — todo movimento
/// (entrada/saída do pill, crescimento, datilografia, dot pulsando) é SwiftUI
/// puro dentro dela, dirigido por Core Animation.
enum TrayInfoOverlay {
    /// Tunável sem rebuild:
    /// `defaults write com.zspeak.app trayInfoOverlayWidth -float 520`
    static let widthDefaultsKey = "trayInfoOverlayWidth"
    static let defaultWidth: CGFloat = ZSTrayTheme.panelWidth
    /// Piso para valores customizados — abaixo disso o texto vira coluna.
    static let minimumWidth: CGFloat = ZSTrayTheme.minimumPanelWidth

    /// Respiro entre a barra de menu e o pill.
    static let topGap: CGFloat = 6
    /// Margem lateral mínima até as bordas da tela.
    static let edgeMargin: CGFloat = 8
    /// Altura máxima da faixa; o frame do painel permanece fixo por ciclo.
    static let pillMaxHeight: CGFloat = ZSTrayTheme.panelMaxHeight
    /// Folga transparente da janela ao redor do pill — espaço para a sombra
    /// e para o overshoot do spring de entrada, sem clipping.
    static let windowPadding: CGFloat = 16
    /// Teto de caracteres exibidos (~4 linhas na largura default) — acima
    /// disso mantém a CAUDA (palavras mais novas), com reticência à frente.
    static let maxDisplayCharacters = 260

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

    static func statusLabel(for state: AppState.RecordingState) -> String {
        switch state {
        case .idle: return "PRONTO"
        case .preparing: return "PREPARANDO"
        case .recording: return "AO VIVO"
        case .processing: return "TRANSCREVENDO"
        }
    }

    static func supportingHint(for state: AppState.RecordingState) -> String {
        switch state {
        case .preparing, .recording: return "Esc para cancelar"
        case .processing: return "Finalizando…"
        case .idle: return ""
        }
    }

    static func formattedElapsedTime(_ elapsed: TimeInterval) -> String {
        let totalSeconds = max(0, Int(elapsed.rounded(.down)))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
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
        state: .idle,
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
    /// Instante do primeiro sample; mesma fonte de verdade do overlay grande.
    var recordingStartedAt: Date?
    /// Congela o timer em previews/snapshots.
    var elapsedTimeOverride: TimeInterval?
    /// Fonte do nível real do microfone para a fita de áudio.
    var getAudioLevel: (() -> Float)?
    /// Perfil visual determinístico para harnesses.
    var waveformLevelsOverride: [Float]?

    var presentationState: AppState.RecordingState { presentation.state }
}

/// Conteúdo SwiftUI do mini-overlay: faixa de material ancorada no canto
/// superior direito, com estado, waveform real, timer e transcrição ao vivo.
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
                traySurface
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

    private var traySurface: some View {
        VStack(alignment: .leading, spacing: ZSTrayTheme.sectionSpacing) {
            statusRail

            HStack(alignment: .firstTextBaseline, spacing: 14) {
                textContent
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(TrayInfoOverlay.supportingHint(for: model.presentationState))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(ZSTrayTheme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, ZSTrayTheme.horizontalPadding)
        .padding(.vertical, ZSTrayTheme.verticalPadding)
        .frame(width: TrayInfoOverlay.width(), alignment: .leading)
        .frame(minHeight: ZSTrayTheme.minimumPanelHeight, alignment: .center)
        .background {
            ZStack {
                surfaceShape.fill(.regularMaterial)
                surfaceShape.fill(ZSTrayTheme.surface)
            }
        }
        .overlay(
            surfaceShape
                .strokeBorder(ZSTrayTheme.surfaceStroke, lineWidth: 0.7)
        )
        .shadow(color: .black.opacity(0.34), radius: 14, x: 0, y: 5)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        // Crossfade suave entre placeholder ("Ouvindo…") e texto real, e no
        // crescimento do pill a cada quebra de linha.
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: model.presentation.isPlaceholderText
        )
    }

    private var surfaceShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ZSTrayTheme.cornerRadius, style: .continuous)
    }

    private var statusRail: some View {
        HStack(spacing: ZSTrayTheme.inlineSpacing) {
            HStack(spacing: 7) {
                statusGlyph
                Text(TrayInfoOverlay.statusLabel(for: model.presentationState))
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.8)
            }
            .foregroundStyle(statusAccent)
            .fixedSize()

            divider

            ZSTraySignalWaveform(
                isActive: model.presentationState == .recording,
                getAudioLevel: model.getAudioLevel,
                levelsOverride: model.waveformLevelsOverride,
                reduceMotion: reduceMotion
            )
            .frame(maxWidth: .infinity)

            divider

            timerContent
                .frame(minWidth: 34, alignment: .trailing)
        }
        .frame(height: 26)
    }

    private var divider: some View {
        Rectangle()
            .fill(ZSTrayTheme.divider)
            .frame(width: 1, height: 22)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch model.presentationState {
        case .recording:
            TrayPulsingDot(reduceMotion: reduceMotion)
        case .preparing:
            ProgressView()
                .controlSize(.mini)
                .tint(statusAccent)
                .accessibilityHidden(true)
        case .processing:
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .semibold))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                .accessibilityHidden(true)
        case .idle:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var timerContent: some View {
        if model.presentationState == .recording {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let elapsed = model.elapsedTimeOverride
                    ?? model.recordingStartedAt.map { max(0, context.date.timeIntervalSince($0)) }
                    ?? 0
                Text(TrayInfoOverlay.formattedElapsedTime(elapsed))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusAccent)
                    .contentTransition(.numericText())
            }
        } else {
            Text(model.presentationState == .processing ? "•••" : "—")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(ZSTrayTheme.textTertiary)
        }
    }

    private var statusAccent: Color {
        switch model.presentationState {
        case .recording: return ZSTrayTheme.recordingAccent
        case .preparing: return ZSTrayTheme.preparingAccent
        case .processing: return ZSTrayTheme.processingAccent
        case .idle: return ZSTrayTheme.textSecondary
        }
    }

    private var accessibilityLabel: String {
        [
            TrayInfoOverlay.statusLabel(for: model.presentationState),
            model.presentation.text,
            TrayInfoOverlay.supportingHint(for: model.presentationState),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: ". ")
    }

    @ViewBuilder
    private var textContent: some View {
        if model.presentation.isPlaceholderText {
            Text(model.presentation.text)
                .font(.system(size: 15.5, weight: .medium))
                .foregroundStyle(ZSTrayTheme.textSecondary)
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
        ZStack(alignment: .topLeading) {
            // Reserva a altura do alvo antes da datilografia/onAppear. Sem
            // esta sonda invisível, o texto podia crescer para fora do painel
            // no primeiro frame de estados como `.processing`.
            transcriptText(text)
                .hidden()
                .accessibilityHidden(true)

            transcriptText(displayedText)
                .foregroundStyle(ZSTrayTheme.textPrimary)
        }
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

    private func transcriptText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 15.5, weight: .medium))
            .multilineTextAlignment(.leading)
            .lineSpacing(2)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
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
    func present(
        _ presentation: TrayPreviewPresentation,
        recordingStartedAt: Date? = nil,
        anchoredTo button: NSStatusBarButton?
    ) {
        model.reduceMotionOverride = prefersReducedMotion()
        model.presentation = presentation
        model.recordingStartedAt = recordingStartedAt

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

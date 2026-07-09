import SwiftUI
import AppKit

/// Tokens visuais do overlay — hierarquia de texto, superfícies e acentos por
/// estado. Centraliza os valores que antes viviam espalhados como
/// `.white.opacity(x)` em cada subview, garantindo consistência.
enum OverlayTheme {
    static let cornerRadius: CGFloat = 16
    static let innerRadius: CGFloat = 9

    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.74)
    static let textTertiary = Color.white.opacity(0.50)

    static let surface = Color.white.opacity(0.055)
    static let surfaceStroke = Color.white.opacity(0.11)
    static let raisedSurface = Color.white.opacity(0.09)
    static let raisedStroke = Color.white.opacity(0.22)

    /// Vermelho vivo do estado de gravação (dot pulsante + badge "ao vivo").
    static let recordingAccent = Color(red: 1.0, green: 0.30, blue: 0.32)
    /// Azul frio do estado de processamento.
    static let processingAccent = Color(red: 0.45, green: 0.68, blue: 1.0)

    /// Fundo "dark glass": base quase preta com leve tinta azulada no topo.
    static var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.095, green: 0.10, blue: 0.12).opacity(0.97),
                Color(red: 0.030, green: 0.033, blue: 0.045).opacity(0.96),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Borda com brilho concentrado na aresta superior — dá o relevo de vidro.
    static var edgeHighlight: LinearGradient {
        LinearGradient(
            colors: [Color.white.opacity(0.30), Color.white.opacity(0.07)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Modelo observável do overlay — atualizado in-place para evitar recriação de views
@Observable
@MainActor
final class OverlayModel {
    var state: AppState.RecordingState = .idle
    /// Instante do 1º sample da sessão atual — âncora do timer do chip.
    /// Vem do RecordingController; sobrevive a recriações do overlay.
    var recordingStartedAt: Date?
    var isModelReady: Bool = false
    var focusedAppName: String = ""
    var focusedAppIcon: NSImage?
    /// Referência ao MicrophoneManager para ler o nome do mic ativo de forma reativa.
    /// Setada externamente (App.swift). Quando presente, o overlay atualiza o nome
    /// automaticamente ao trocar de microfone durante a gravação, já que
    /// `MicrophoneManager` e `OverlayModel` são ambos `@Observable`.
    var microphoneManager: MicrophoneManager?
    /// Fallback não-reativo usado apenas em previews/testes quando não há manager.
    /// Em produção, `microphoneManager` é sempre setado e esta propriedade é ignorada.
    var microphoneName: String = ""

    /// Nome efetivo do mic: prioriza a fonte reativa do manager; cai para o fallback.
    var effectiveMicrophoneName: String {
        if let manager = microphoneManager {
            return manager.activeMicrophoneName
        }
        return microphoneName
    }
    /// Closure para ler audioLevel direto do AudioCapture. SÍNCRONA de
    /// propósito: o `AudioLevelMonitor` já é thread-safe e a amostragem roda a
    /// cada 45 ms — um hop async aqui faz a leitura disputar o executor global
    /// com o ASR do preview ao vivo e a waveform congela enquanto o usuário fala.
    var getAudioLevel: (@Sendable () -> Float)?
    /// Closure para ler o flag de clipping do mic (aviso "mic muito alto").
    var getMicClipping: (@Sendable () -> Bool)?
    /// Atualizado pelo loop de amostragem da WaveformView; lido pelo MetaRow.
    var micClippingActive: Bool = false
    /// Usado apenas por snapshots para congelar a fase da animacao.
    var waveformAnimationPhaseOverride: TimeInterval?
    /// Usado apenas por snapshots para renderizar a waveform em estado ativo.
    var waveformLevelOverride: Float?
    /// Mostra o hint "esc cancela" durante a gravação — espelha a preferência
    /// `escapeToCancel` do ActivationKeyManager (wired em App.swift).
    var escHintEnabled: Bool = true

    // Modo Prompt
    var promptModeEnabled: Bool = false
    var prompts: [CorrectionPrompt] = []
    var isApplyingPrompt: Bool = false
    var onApplyPrompt: ((CorrectionPrompt) -> Void)?
    /// Chamado ao selecionar outro prompt; no Modo Prompt a aplicação é automática.
    var onPromptSelected: ((CorrectionPrompt) -> Void)?
    /// Closure para aplicar o prompt ativo no texto atual do clipboard (TASK-012)
    var onPasteAndApply: (() -> Void)?
    /// Closure chamada quando o TextField detecta paste — passa o texto colado (TASK-013)
    var onTextInputApply: ((String) -> Void)?

    /// Texto da última transcrição — exibido no overlay no estado idle do modo prompt
    /// para o usuário ver o que foi capturado antes de decidir aplicar um prompt.
    var lastTranscription: String = ""
    /// Texto parcial exibido enquanto a gravação está ativa. Não é colado no app
    /// em foco; a inserção automática continua acontecendo só no texto final.
    var liveTranscriptionPreview: String = ""

    /// Último resultado gerado pela LLM (para exibir no overlay)
    var lastLLMResult: String?
    var lastLLMPromptName: String?
    var errorMessage: String?

    // Tradução de seleção
    var translationVisible: Bool = false
    var isTranslatingSelection: Bool = false
    var selectionTranslationSourceText: String = ""
    var selectionTranslationResult: String?
    var selectionTranslationError: String?
    var selectionTranslationPresentation: SelectionTranslationPresentation = .fullTranslation
    var selectionLookupTerm: String?
    var selectionLookupTranslation: String?
    var isLookingUpSelectionTerm: Bool = false
    var selectionLookupError: String?
    var onDismissTranslation: (() -> Void)?

    /// Toggle para expandir/colapsar a visualização do resultado LLM — persiste em UserDefaults
    var isResultExpanded: Bool {
        didSet { UserDefaults.standard.set(isResultExpanded, forKey: "overlayResultExpanded") }
    }

    /// ID do último prompt selecionado — persiste em UserDefaults
    var selectedPromptID: UUID? {
        didSet {
            if let id = selectedPromptID {
                UserDefaults.standard.set(id.uuidString, forKey: "overlayLastPromptID")
            }
        }
    }

    init() {
        self.isResultExpanded = UserDefaults.standard.bool(forKey: "overlayResultExpanded")
        if let raw = UserDefaults.standard.string(forKey: "overlayLastPromptID"),
           let id = UUID(uuidString: raw) {
            self.selectedPromptID = id
        }
    }

    /// Retorna o prompt atualmente selecionado (ou o primeiro se nenhum)
    var selectedPrompt: CorrectionPrompt? {
        if let id = selectedPromptID, let match = prompts.first(where: { $0.id == id }) {
            return match
        }
        return prompts.first
    }
}

/// Overlay visual estilo Spokenly — barra escura com waveform reativa
struct OverlayView: View {
    let model: OverlayModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: AppState.RecordingState { model.state }

    /// Descrição do estado atual para leitores de tela (VoiceOver).
    private var stateAccessibilityLabel: String {
        if model.translationVisible {
            return model.isTranslatingSelection ? "Traduzindo seleção" : "Tradução da seleção"
        }

        switch state {
        case .idle:
            return "Ocioso"
        case .preparing:
            return "Preparando microfone"
        case .recording:
            return "Gravando áudio"
        case .processing:
            return "Processando transcrição"
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            if model.translationVisible {
                if model.selectionTranslationPresentation == .compactLookup {
                    CompactSelectionLookupOverlayContent(model: model)
                } else {
                    SelectionTranslationOverlayContent(model: model)
                }
            } else {
            // Header: app em foco à esquerda + chip de estado à direita.
            OverlayHeader(model: model)

            // Waveform visível já no preparing (com movimento idle) — evita o
            // pulo de layout na transição preparing → recording e dá feedback
            // imediato no press da hotkey.
            if state == .preparing || state == .recording {
                WaveformView(model: model)
                    .frame(height: 44)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Forma de onda do áudio capturado")
                    .transition(.opacity.combined(with: .scale(scale: 0.88, anchor: .center)))

                RecordingMetaRow(model: model)
                    .transition(.opacity)
            }

            if state == .recording || state == .processing {
                TranscriptionPreviewBlock(
                    text: model.liveTranscriptionPreview,
                    state: state
                )
                .transition(.opacity)
            }

            if model.promptModeEnabled && state != .recording && state != .processing {
                if !model.lastTranscription.isEmpty || state != .idle {
                    TranscriptionPreviewBlock(text: model.lastTranscription, state: state)
                } else if state == .idle {
                    // TextField editável — usuário pode colar texto para o LLM (TASK-013)
                    TextInputBlock(model: model)
                }
            }

            // Seção inferior: seletor de prompt + ações rápidas (Modo Prompt)
            if model.promptModeEnabled {
                Divider()
                    .background(.white.opacity(0.16))

                PromptSelectorBar(model: model)

                if let error = model.errorMessage {
                    PromptErrorView(message: error)
                }

                // Resultado da última correção LLM (toggleável)
                if model.lastLLMResult != nil {
                    Divider()
                        .background(.white.opacity(0.16))

                    LLMResultView(model: model)
                }
            }
            }
        }
        // Estados trocam com fade/scale suave em vez de corte seco — o painel
        // já anima o frame (KVO em preferredContentSize); o conteúdo acompanha.
        // Aplicado antes do .frame(width:) para a largura não participar.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: state)
        .padding(.horizontal, model.selectionTranslationPresentation == .compactLookup ? 11 : 16)
        .padding(.vertical, model.selectionTranslationPresentation == .compactLookup ? 9 : 13)
        .frame(width: overlayWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius, style: .continuous)
                .fill(OverlayTheme.backgroundGradient)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OverlayTheme.cornerRadius, style: .continuous)
                .strokeBorder(OverlayTheme.edgeHighlight, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.40), radius: 22, y: 10)
        // VoiceOver: anuncia o estado corrente do overlay como valor do container.
        // O label de cada bloco interno (preparing/recording/processing) também
        // é exposto, mas esse valor global ajuda a orientar quem entra no overlay.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Overlay do zspeak")
        .accessibilityValue(stateAccessibilityLabel)
    }

    private var overlayWidth: CGFloat {
        if model.translationVisible && model.selectionTranslationPresentation == .compactLookup {
            return 230
        }
        if model.translationVisible { return 500 }
        // Preparing já usa a largura de gravação: o overlay nasce no tamanho
        // final e não "salta" quando o primeiro sample chega.
        if state == .preparing || state == .recording || state == .processing { return 520 }
        return model.promptModeEnabled ? 520 : 320
    }
}

/// Linha superior do overlay: destino da transcrição (app em foco) à esquerda
/// e o chip de estado (idle/preparando/gravando/processando) à direita.
private struct OverlayHeader: View {
    let model: OverlayModel

    var body: some View {
        HStack(spacing: 8) {
            if let icon = model.focusedAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .accessibilityHidden(true)
            }

            Text(model.focusedAppName)
                .font(.callout.weight(.medium))
                .foregroundStyle(OverlayTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel("App em foco: \(model.focusedAppName)")

            Spacer(minLength: 12)

            OverlayStatusChip(model: model)
        }
    }
}

/// Chip de estado no canto superior direito. Substitui o branding estático
/// "zspeak" por informação útil: dot pulsante + timer na gravação, spinner
/// nos estados de espera. No idle mantém a marca discreta.
private struct OverlayStatusChip: View {
    let model: OverlayModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch model.state {
        case .idle:
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                    .font(.caption2)
                Text("zspeak")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(OverlayTheme.textTertiary)
            .accessibilityHidden(true)

        case .preparing:
            chip(tint: Color.white.opacity(0.65), fill: OverlayTheme.surface, stroke: OverlayTheme.surfaceStroke) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white.opacity(0.7))
                    .accessibilityHidden(true)
                Text("Preparando")
                    .font(.caption.weight(.medium))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Preparando microfone")

        case .recording:
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                // Âncora vem do modelo (1º sample da sessão) — o timer não
                // zera se o overlay for fechado/reaberto durante a gravação.
                let elapsed = model.waveformAnimationPhaseOverride
                    ?? model.recordingStartedAt.map { max(0, context.date.timeIntervalSince($0)) }
                    ?? 0
                chip(
                    tint: OverlayTheme.recordingAccent,
                    fill: OverlayTheme.recordingAccent.opacity(0.16),
                    stroke: OverlayTheme.recordingAccent.opacity(0.34)
                ) {
                    PulsingDot(
                        color: OverlayTheme.recordingAccent,
                        phase: model.waveformAnimationPhaseOverride,
                        frozen: reduceMotion
                    )
                    Text(Self.formattedElapsedTime(elapsed))
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .contentTransition(.numericText())
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Gravando áudio")

        case .processing:
            chip(
                tint: OverlayTheme.processingAccent,
                fill: OverlayTheme.processingAccent.opacity(0.14),
                stroke: OverlayTheme.processingAccent.opacity(0.30)
            ) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(OverlayTheme.processingAccent)
                    .accessibilityHidden(true)
                Text("Transcrevendo")
                    .font(.caption.weight(.medium))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Processando transcrição")
        }
    }

    private func chip<Content: View>(
        tint: Color,
        fill: Color,
        stroke: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 6) {
            content()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(fill, in: Capsule())
        .overlay(Capsule().strokeBorder(stroke, lineWidth: 0.5))
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    static func formattedElapsedTime(_ elapsed: TimeInterval) -> String {
        let totalSeconds = max(0, Int(elapsed.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}

/// Dot vermelho pulsante do estado de gravação. Congela em snapshots (phase
/// override) e quando "Reduce Motion" está ativo.
private struct PulsingDot: View {
    let color: Color
    let phase: TimeInterval?
    let frozen: Bool

    var body: some View {
        if frozen || phase != nil {
            dot(opacity: 1.0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                dot(opacity: 0.55 + 0.45 * (sin(t * 3.6) + 1) / 2)
            }
        }
    }

    private func dot(opacity: Double) -> some View {
        Circle()
            .fill(color.opacity(opacity))
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(opacity * 0.6), radius: 3)
            .accessibilityHidden(true)
    }
}

/// Linha de metadados abaixo da waveform: mic ativo (ou "preparando") à
/// esquerda e o hint de cancelamento via Esc à direita.
private struct RecordingMetaRow: View {
    let model: OverlayModel

    var body: some View {
        HStack(spacing: 10) {
            if model.state == .preparing {
                HStack(spacing: 5) {
                    Image(systemName: "mic")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text("Preparando microfone...")
                        .font(.caption2)
                }
                .foregroundStyle(OverlayTheme.textTertiary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Preparando microfone")
            } else if model.micClippingActive {
                // Clipping na captação: distorção não tem conserto depois —
                // avisa na hora para o usuário afastar/reduzir o mic.
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text("Mic muito alto — reduza o ganho")
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(OverlayTheme.recordingAccent)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Microfone muito alto, reduza o ganho de entrada")
            } else {
                // Nome do mic ativo — reativo via MicrophoneManager. Trunca no
                // meio se o nome do device for muito longo. Dynamic Type limitado
                // a xLarge para não quebrar o layout lateral do overlay.
                let micName = model.effectiveMicrophoneName
                if !micName.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "mic.fill")
                            .font(.caption2)
                            .accessibilityHidden(true)
                        Text(micName)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(OverlayTheme.textTertiary)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Microfone ativo: \(micName)")
                }
            }

            Spacer(minLength: 8)

            if model.escHintEnabled && model.state == .recording {
                HStack(spacing: 4) {
                    Text("esc")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(OverlayTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(OverlayTheme.surfaceStroke, lineWidth: 0.5)
                        )
                    Text("cancela")
                        .font(.caption2)
                }
                .foregroundStyle(OverlayTheme.textTertiary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Tecla Escape cancela a gravação")
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }
}

private struct CompactSelectionLookupOverlayContent: View {
    let model: OverlayModel

    private var term: String {
        model.selectionLookupTerm ?? model.selectionTranslationSourceText
    }

    private var valueText: String {
        if let error = model.selectionLookupError, !error.isEmpty {
            return error
        }

        let text = model.selectionLookupTranslation?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "..." : text
    }

    var body: some View {
        HStack(spacing: 8) {
            if model.isLookingUpSelectionTerm {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white.opacity(0.72))
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(term)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(valueText)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(model.selectionLookupError == nil ? .white.opacity(0.96) : .red.opacity(0.95))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tradução rápida")
        .accessibilityValue("\(term): \(valueText)")
    }
}

private struct SelectionTranslationOverlayContent: View {
    let model: OverlayModel

    private var resultText: String {
        if let error = model.selectionTranslationError, !error.isEmpty {
            return error
        }

        let text = model.selectionTranslationResult?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty && model.isTranslatingSelection {
            return "Traduzindo..."
        }
        return text
    }

    private var hasResult: Bool {
        !(model.selectionTranslationResult ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .accessibilityHidden(true)

                Text("Tradução")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.94))

                Spacer()

                if model.isTranslatingSelection {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.75))
                        .accessibilityLabel("Traduzindo seleção")
                }

                if hasResult {
                    Button {
                        if let text = model.selectionTranslationResult {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .buttonStyle(.plain)
                    .help("Copiar tradução")
                    .accessibilityLabel("Copiar tradução")
                }

                Button {
                    model.onDismissTranslation?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .buttonStyle(.plain)
                .help("Fechar")
                .accessibilityLabel("Fechar tradução")
            }

            if !model.selectionTranslationSourceText.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(model.selectionTranslationSourceText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 58)
                .accessibilityLabel("Texto original")
                .accessibilityValue(model.selectionTranslationSourceText)
            }

            ScrollView {
                Text(resultText)
                    .font(.body)
                    .foregroundStyle(model.selectionTranslationError == nil ? .white.opacity(0.96) : .red.opacity(0.95))
                    .italic(resultText == "Traduzindo...")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityLabel(model.selectionTranslationError == nil ? "Tradução" : "Erro de tradução")
                    .accessibilityValue(resultText)
            }
            .frame(maxHeight: 180)
        }
    }
}

/// Transcrição capturada pelo ASR, mantida visível no Modo Prompt mesmo enquanto
/// uma nova gravação/processamento acontece. O texto continua selecionável para
/// permitir inspeção rápida antes/depois da LLM.
private struct TranscriptionPreviewBlock: View {
    let text: String
    let state: AppState.RecordingState

    private var isWaitingForText: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var waitingMessage: String {
        switch state {
        case .preparing:
            return "Preparando microfone..."
        case .recording:
            return "Falando... a transcrição aparece aqui em instantes."
        case .processing:
            return "Processando transcrição..."
        case .idle:
            return "Nenhuma transcrição capturada ainda."
        }
    }

    private var title: String {
        switch state {
        case .recording, .processing:
            return "Transcrição ao vivo"
        case .preparing, .idle:
            return "Transcrição capturada"
        }
    }

    private var shouldAnimateText: Bool {
        state == .recording || state == .processing
    }

    /// Rótulo curto em mini-caps — menos peso visual que o Label antigo com ícone.
    private var badgeText: String {
        switch state {
        case .recording:
            return "AO VIVO"
        case .processing:
            return "TRANSCRIÇÃO"
        case .preparing, .idle:
            return "ÚLTIMA TRANSCRIÇÃO"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                if state == .recording {
                    Circle()
                        .fill(OverlayTheme.recordingAccent)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
                Text(badgeText)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(
                        state == .recording
                            ? OverlayTheme.recordingAccent.opacity(0.92)
                            : OverlayTheme.textTertiary
                    )
                    .accessibilityLabel(title)
            }

            ScrollView {
                if isWaitingForText {
                    Text(waitingMessage)
                        .font(.body)
                        .foregroundStyle(OverlayTheme.textTertiary)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .accessibilityLabel(title)
                        .accessibilityValue(waitingMessage)
                } else {
                    ProgressiveTranscriptText(
                        text: text,
                        animate: shouldAnimateText
                    )
                    .accessibilityLabel(title)
                        .accessibilityValue(text)
                }
            }
            .defaultScrollAnchor(.bottom)
            .frame(minHeight: shouldAnimateText ? 52 : nil, maxHeight: 96)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: OverlayTheme.innerRadius, style: .continuous)
                .fill(OverlayTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OverlayTheme.innerRadius, style: .continuous)
                .strokeBorder(OverlayTheme.surfaceStroke, lineWidth: 0.5)
        )
    }
}

/// Texto ao vivo com revelação progressiva "sem regressão visual": correções
/// que o ASR faz em trechos já exibidos são aplicadas no lugar (troca
/// instantânea, sem varredura de deleção/redigitação) e apenas o texto
/// genuinamente novo é datilografado no fim. Evita o efeito de o texto
/// "sumir e voltar" a cada preview.
private struct ProgressiveTranscriptText: View {
    let text: String
    let animate: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedText: String = ""
    @State private var targetText: String = ""
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        Text(displayedText)
            .font(.body)
            .foregroundStyle(.white.opacity(0.95))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .onAppear {
                updateRevealTarget(text)
            }
            .onChange(of: text) { _, newValue in
                updateRevealTarget(newValue)
            }
            .onChange(of: animate) {
                updateRevealTarget(text)
            }
            .onChange(of: reduceMotion) {
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

        guard animate, !reduceMotion else {
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
            let shouldContinue = !Task.isCancelled && displayedText != targetText && animate && !reduceMotion
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

            // Correções interiores trocam no lugar — o texto já visto nunca
            // é apagado e redigitado na frente do usuário.
            if displayedText != step.base {
                withAnimation(.easeOut(duration: 0.12)) {
                    displayedText = step.base
                }
            }

            // A cauda genuinamente nova é datilografada progressivamente.
            while displayedText != nextTarget, !Task.isCancelled {
                if targetText != nextTarget {
                    continue revealLoop
                }

                let remaining = max(0, nextTarget.count - displayedText.count)
                let batchSize = ProgressiveTextReveal.batchSize(
                    remainingCharacterCount: remaining
                )
                // Sem withAnimation por passo: a cadencia (~30-50/s) ja da a
                // sensacao de digitacao; transacoes animadas por passo
                // disputavam o MainActor com a waveform de 60fps.
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

/// Barra inferior do overlay no Modo Prompt: menu de prompts + ações rápidas.
struct PromptSelectorBar: View {
    let model: OverlayModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isApplyingPrompt {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.8))
                    .accessibilityHidden(true)
                Text("Aplicando \(model.selectedPrompt?.name ?? "")...")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .accessibilityLabel("Aplicando prompt \(model.selectedPrompt?.name ?? "selecionado")")
                Spacer()
            } else {
                // Dropdown de prompts — Menu com label custom (chevron no lugar certo).
                // Dynamic Type limitado a xLarge para manter o dropdown dentro da
                // largura do overlay em tamanhos de acessibilidade.
                Menu {
                    ForEach(model.prompts) { prompt in
                        Button {
                            model.selectedPromptID = prompt.id
                            model.onPromptSelected?(prompt)
                        } label: {
                            if prompt.id == model.selectedPromptID {
                                Label(prompt.name, systemImage: "checkmark")
                            } else {
                                Text(prompt.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(OverlayTheme.textSecondary)
                            .accessibilityHidden(true)
                        Text(model.selectedPrompt?.name ?? "Selecionar prompt")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(OverlayTheme.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(OverlayTheme.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(OverlayTheme.raisedSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(OverlayTheme.raisedStroke, lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .dynamicTypeSize(...DynamicTypeSize.xLarge)
                .accessibilityLabel("Prompt selecionado: \(model.selectedPrompt?.name ?? "nenhum")")
                .accessibilityHint("Abre a lista de prompts disponíveis")

                // Botão "colar do clipboard" — usa texto do clipboard como input do LLM (TASK-012)
                Button {
                    model.onPasteAndApply?()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OverlayTheme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(OverlayTheme.raisedSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(OverlayTheme.raisedStroke, lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Aplicar prompt no texto do clipboard")
                .accessibilityLabel("Colar e aplicar prompt no clipboard")
                .accessibilityHint("Usa o texto atual do clipboard como entrada do prompt")

                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Erro compacto dentro do overlay do Modo Prompt.
struct PromptErrorView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red.opacity(0.9))
                .accessibilityHidden(true)

            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.red.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.red.opacity(0.28), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Erro no modo prompt")
        .accessibilityValue(message)
    }
}

/// Visualização do último resultado da LLM — pode ser expandida ou colapsada
struct LLMResultView: View {
    let model: OverlayModel

    /// Respeita "Reduce Motion" do sistema — quando ativo, o toggle expand/collapse
    /// acontece sem animação (instantâneo) para evitar movimento desnecessário.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header com toggle expand/collapse + nome do prompt + botão copiar
            HStack(spacing: 6) {
                if model.isApplyingPrompt {
                    // Spinner enquanto LLM gera (TASK-011) — feedback visual de streaming ao vivo
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.7))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: model.isResultExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                }

                Text("Resultado")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))

                if let name = model.lastLLMPromptName {
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .accessibilityHidden(true)
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }

                Spacer()

                if model.isResultExpanded {
                    Button {
                        if let text = model.lastLLMResult {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .help("Copiar resultado")
                    .accessibilityLabel("Copiar resultado")
                    .accessibilityHint("Copia o texto gerado pelo prompt para o clipboard")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                // Reduce Motion: troca sem animação. Caso contrário, easeInOut curto.
                if reduceMotion {
                    model.isResultExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        model.isResultExpanded.toggle()
                    }
                }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(model.isResultExpanded ? "Colapsar resultado" : "Expandir resultado")
            .accessibilityHint(model.isResultExpanded ? "Esconde o texto gerado pelo prompt" : "Mostra o texto gerado pelo prompt")

            // Conteúdo expandido
            if model.isResultExpanded, let text = model.lastLLMResult {
                if !model.lastTranscription.isEmpty {
                    LLMSplitDiffBlock(
                        original: model.lastTranscription,
                        revised: text,
                        isApplying: model.isApplyingPrompt
                    )
                } else {
                    LLMTextBlock(text: text, isApplying: model.isApplyingPrompt)
                }
            }
        }
    }
}

/// Texto final produzido pela LLM. Durante streaming, mostra o parcial; quando
/// ainda não chegou nada, mantém um placeholder para o usuário saber que o app
/// está esperando o modelo.
private struct LLMTextBlock: View {
    let text: String
    let isApplying: Bool

    private var displayText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && isApplying {
            return "Aguardando resposta da LLM..."
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Tratado pela LLM", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))

            ScrollView {
                Text(displayText)
                    .font(.caption)
                    .foregroundStyle(displayText == "Aguardando resposta da LLM..." ? .white.opacity(0.62) : .white.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityLabel("Texto tratado pela LLM")
                    .accessibilityValue(displayText)
            }
            .frame(maxHeight: 108)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: OverlayTheme.innerRadius, style: .continuous)
                .fill(OverlayTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OverlayTheme.innerRadius, style: .continuous)
                .strokeBorder(OverlayTheme.surfaceStroke, lineWidth: 0.5)
        )
    }
}

/// Comparação lado a lado em estilo diff split do VS Code/Git:
/// esquerda = transcrição capturada, direita = texto tratado pela LLM.
/// Remoções ficam destacadas em vermelho no lado esquerdo; adições em verde
/// no lado direito.
private struct LLMSplitDiffBlock: View {
    let original: String
    let revised: String
    let isApplying: Bool

    private var isWaitingForLLM: Bool {
        revised.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isApplying
    }

    private var diff: PromptSideBySideDiff {
        if isWaitingForLLM {
            return PromptSideBySideDiff(
                left: [PromptDiffSegment(kind: .equal, text: original)],
                right: []
            )
        }
        return PromptWordDiff.sideBySide(original: original, revised: revised)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Comparação", systemImage: "rectangle.split.2x1")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))

            HStack(alignment: .top, spacing: 8) {
                PromptDiffColumn(
                    title: "Transcrito",
                    systemImage: "quote.bubble",
                    segments: diff.left,
                    placeholder: "Sem transcrição"
                )

                PromptDiffColumn(
                    title: "Tratado pela LLM",
                    systemImage: "sparkles",
                    segments: diff.right,
                    placeholder: isWaitingForLLM ? "Aguardando resposta da LLM..." : "Sem texto tratado"
                )
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: OverlayTheme.innerRadius, style: .continuous)
                .fill(OverlayTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OverlayTheme.innerRadius, style: .continuous)
                .strokeBorder(OverlayTheme.surfaceStroke, lineWidth: 0.5)
        )
    }
}

private struct PromptDiffColumn: View {
    let title: String
    let systemImage: String
    let segments: [PromptDiffSegment]
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.78))

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if segments.isEmpty {
                        Text(placeholder)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.62))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    } else {
                        PromptInlineDiffText(segments: segments)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 168)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.16), lineWidth: 0.5)
        )
    }
}

private struct PromptInlineDiffText: View {
    let segments: [PromptDiffSegment]

    private var text: Text {
        var output = Text("")
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                output = output + Text(" ")
            }
            output = output + styledText(for: segment)
        }
        return output
    }

    var body: some View {
        text
            .font(.caption)
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Texto com diferencas destacadas")
    }

    private func styledText(for segment: PromptDiffSegment) -> Text {
        switch segment.kind {
        case .equal:
            return Text(segment.text)
                .foregroundColor(.white.opacity(0.88))
        case .removed:
            return Text(segment.text)
                .foregroundColor(.red.opacity(0.98))
                .strikethrough(true, color: .red.opacity(0.9))
        case .added:
            return Text(segment.text)
                .foregroundColor(.green.opacity(0.98))
                .bold()
        }
    }
}

private struct PromptSideBySideDiff {
    let left: [PromptDiffSegment]
    let right: [PromptDiffSegment]
}

private struct PromptDiffSegment: Identifiable {
    enum Kind {
        case equal
        case removed
        case added
    }

    let id = UUID()
    let kind: Kind
    let text: String
}

private enum PromptWordDiff {
    private enum Edit {
        case equal(String)
        case removed(String)
        case added(String)
    }

    static func sideBySide(original: String, revised: String) -> PromptSideBySideDiff {
        let originalTokens = tokenize(original)
        let revisedTokens = tokenize(revised)
        guard !originalTokens.isEmpty || !revisedTokens.isEmpty else {
            return PromptSideBySideDiff(left: [], right: [])
        }

        let edits = edits(originalTokens: originalTokens, revisedTokens: revisedTokens)
        return groupedSideBySide(from: edits)
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        let normalizedLeft = normalized(lhs)
        let normalizedRight = normalized(rhs)
        guard !normalizedLeft.isEmpty, !normalizedRight.isEmpty else {
            return lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return normalizedLeft == normalizedRight
    }

    private static func normalized(_ token: String) -> String {
        token
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private static func edits(originalTokens: [String], revisedTokens: [String]) -> [Edit] {
        let originalCount = originalTokens.count
        let revisedCount = revisedTokens.count
        var table = Array(
            repeating: Array(repeating: 0, count: revisedCount + 1),
            count: originalCount + 1
        )

        if originalCount > 0 && revisedCount > 0 {
            for i in stride(from: originalCount - 1, through: 0, by: -1) {
                for j in stride(from: revisedCount - 1, through: 0, by: -1) {
                    if equivalent(originalTokens[i], revisedTokens[j]) {
                        table[i][j] = table[i + 1][j + 1] + 1
                    } else {
                        table[i][j] = max(table[i + 1][j], table[i][j + 1])
                    }
                }
            }
        }

        var result: [Edit] = []
        var i = 0
        var j = 0

        while i < originalCount && j < revisedCount {
            if equivalent(originalTokens[i], revisedTokens[j]) {
                result.append(.equal(revisedTokens[j]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                result.append(.removed(originalTokens[i]))
                i += 1
            } else {
                result.append(.added(revisedTokens[j]))
                j += 1
            }
        }

        while i < originalCount {
            result.append(.removed(originalTokens[i]))
            i += 1
        }

        while j < revisedCount {
            result.append(.added(revisedTokens[j]))
            j += 1
        }

        return result
    }

    private static func groupedSideBySide(from edits: [Edit]) -> PromptSideBySideDiff {
        var left: [PromptDiffSegment] = []
        var right: [PromptDiffSegment] = []

        var leftKind: PromptDiffSegment.Kind?
        var leftWords: [String] = []
        var rightKind: PromptDiffSegment.Kind?
        var rightWords: [String] = []

        func flushLeft() {
            guard let kind = leftKind else { return }
            let text = leftWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                left.append(PromptDiffSegment(kind: kind, text: text))
            }
            leftKind = nil
            leftWords = []
        }

        func flushRight() {
            guard let kind = rightKind else { return }
            let text = rightWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                right.append(PromptDiffSegment(kind: kind, text: text))
            }
            rightKind = nil
            rightWords = []
        }

        func appendLeft(kind: PromptDiffSegment.Kind, word: String) {
            if leftKind != kind {
                flushLeft()
                leftKind = kind
            }
            leftWords.append(word)
        }

        func appendRight(kind: PromptDiffSegment.Kind, word: String) {
            if rightKind != kind {
                flushRight()
                rightKind = kind
            }
            rightWords.append(word)
        }

        for edit in edits {
            switch edit {
            case .equal(let word):
                appendLeft(kind: .equal, word: word)
                appendRight(kind: .equal, word: word)
            case .removed(let word):
                appendLeft(kind: .removed, word: word)
            case .added(let word):
                appendRight(kind: .added, word: word)
            }
        }

        flushLeft()
        flushRight()

        return PromptSideBySideDiff(left: left, right: right)
    }
}

/// Campo de texto editável dentro do overlay no Modo Prompt (issue #13, #27).
///
/// UX explícita: o usuário digita ou cola texto e confirma com o botão "Aplicar
/// prompt". A heurística antiga de detectar paste via `delta > 20 chars` era
/// frágil — disparava em IME/autocomplete e perdia paste curto. Agora a decisão
/// de aplicar é sempre do usuário.
///
/// Empty state: quando não há prompt selecionado, o campo é substituído por uma
/// mensagem instrutiva com CTA para abrir a aba de prompts em Settings.
struct TextInputBlock: View {
    let model: OverlayModel
    @State private var text: String = ""
    @FocusState private var isFocused: Bool
    @Environment(\.openSettings) private var openSettings

    /// Botão só habilita quando: (1) existe prompt selecionado, (2) campo não
    /// está vazio após trim, (3) LLM não está ocupado. Evita disparos espúrios.
    private var canApply: Bool {
        guard model.selectedPrompt != nil, !model.isApplyingPrompt else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.selectedPrompt == nil && model.prompts.isEmpty {
                // Empty state: nenhum prompt cadastrado ainda
                emptyState(
                    message: "Nenhum prompt cadastrado. Crie um para começar.",
                    buttonTitle: "Abrir configurações de prompts"
                )
            } else if model.selectedPrompt == nil {
                // Empty state: há prompts, mas nenhum selecionado
                emptyState(
                    message: "Selecione um prompt na lista abaixo para aplicar.",
                    buttonTitle: "Abrir configurações de prompts"
                )
            } else {
                inputField
                applyButton
            }
        }
    }

    /// Campo de entrada — TextField com placeholder manual (o nativo fica
    /// invisível em fundo escuro).
    private var inputField: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Cole ou digite um texto para o prompt processar...")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.body)
                .foregroundStyle(.white.opacity(0.95))
                .tint(.white.opacity(0.85))
                .focused($isFocused)
                .onSubmit {
                    if canApply { apply() }
                }
                .accessibilityLabel("Campo de entrada do prompt")
                .accessibilityHint("Digite ou cole um texto e confirme com o botão Aplicar prompt")
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: OverlayTheme.innerRadius, style: .continuous)
                .fill(OverlayTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OverlayTheme.innerRadius, style: .continuous)
                .stroke(.white.opacity(isFocused ? 0.35 : 0.2), lineWidth: 0.5)
        )
    }

    /// Botão explícito — substitui a heurística de detecção automática de paste.
    private var applyButton: some View {
        HStack {
            Spacer()
            Button(action: apply) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                    Text("Aplicar prompt")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(canApply ? Color.accentColor.opacity(0.85) : Color.white.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .disabled(!canApply)
            .help(canApply ? "Aplica o prompt selecionado ao texto" : "Digite um texto e selecione um prompt")
            .accessibilityLabel("Aplicar prompt ao texto do campo")
            .accessibilityHint(
                canApply
                    ? "Envia o texto para o prompt \(model.selectedPrompt?.name ?? "selecionado")"
                    : "Desabilitado: campo vazio ou nenhum prompt selecionado"
            )
        }
    }

    private func apply() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.onTextInputApply?(trimmed)
        text = ""
    }

    /// Bloco de empty state com mensagem + CTA para abrir Settings na aba de prompts.
    /// Usa `openSettings()` do macOS 14+ — a aba específica não é selecionável
    /// via API pública, mas o usuário já abre a janela certa e navega.
    private func emptyState(message: String, buttonTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .accessibilityHidden(true)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                // LSUIElement: precisa ativar o app antes, senão Settings
                // abre atrás de outras janelas.
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gear")
                        .font(.caption2)
                    Text(buttonTitle)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.white.opacity(0.25), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(buttonTitle)
            .accessibilityHint("Abre a janela de configurações para gerenciar prompts")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: OverlayTheme.innerRadius, style: .continuous)
                .fill(OverlayTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OverlayTheme.innerRadius, style: .continuous)
                .strokeBorder(OverlayTheme.surfaceStroke, lineWidth: 0.5)
        )
    }
}

/// HUD de voz com histórico rolante (estilo Voice Memos): cada barra é uma
/// amostra real do nível de voz; novas amostras entram pela direita e a linha
/// desliza continuamente para a esquerda, com fade nas bordas e cauda que
/// esmaece. Silêncio vira uma linha de pontos com respiração sutil. O relógio
/// de gravação vive no chip de estado do header (OverlayStatusChip).
struct WaveformView: View {
    let model: OverlayModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barCount = 52
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 3.5
    private let minimumBarHeight: CGFloat = 3
    private let maximumBarHeight: CGFloat = 34
    private let waveformHeight: CGFloat = 40
    private let recordingColor = Color.white
    /// Cadência de amostragem — 52 barras ≈ 2,3 s de histórico visível.
    private let samplePeriod: TimeInterval = 0.045

    @State private var history: [Float] = []
    @State private var smoothedLevel: Float = 0
    /// Amostra anterior — par da atual na interpolação contínua do glow.
    @State private var previousSmoothedLevel: Float = 0
    @State private var lastSampleAt: TimeInterval = Date.timeIntervalSinceReferenceDate
    @State private var sampleTask: Task<Void, Never>?
    @State private var animationStartTime: TimeInterval = Date.timeIntervalSinceReferenceDate

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            let isFrozen = model.waveformAnimationPhaseOverride != nil
            let progress: CGFloat = isFrozen
                ? 0
                : CGFloat(min(max((now - lastSampleAt) / samplePeriod, 0), 1))
            // Nível contínuo a 60fps: interpola a amostra anterior e a atual
            // no mesmo relógio da rolagem — glow e respiração fluem em vez de
            // pular a cada amostra. Snapshots usam o override determinístico.
            let glowLevel: CGFloat = model.waveformLevelOverride.map { CGFloat($0) }
                ?? CGFloat(WaveformDynamics.interpolatedLevel(
                    previous: previousSmoothedLevel,
                    current: smoothedLevel,
                    progress: Float(progress)
                ))

            ZStack {
                // Glow ambiente que respira com a voz — profundidade sem
                // depender de shadow por barra.
                Capsule()
                    .fill(recordingColor)
                    .frame(
                        width: waveformWidth * (0.42 + 0.34 * glowLevel),
                        height: 12 + 12 * glowLevel
                    )
                    .blur(radius: 16)
                    .opacity(0.05 + 0.15 * Double(glowLevel))

                Canvas { canvas, size in
                    drawWaveform(
                        in: &canvas,
                        size: size,
                        now: now,
                        progress: progress,
                        liveLevel: glowLevel,
                        attack: isFrozen ? 0 : max(0, smoothedLevel - previousSmoothedLevel)
                    )
                }
                .frame(width: waveformWidth, height: waveformHeight)
                .mask(edgeFade)
                // Respiração de conjunto: a linha inteira ganha um leve
                // alongamento vertical com o volume da voz.
                .scaleEffect(x: 1, y: 1 + 0.05 * glowLevel, anchor: .center)
                .shadow(
                    color: recordingColor.opacity(0.05 + Double(glowLevel) * 0.12),
                    radius: 3 + glowLevel * 5,
                    x: 0,
                    y: 0
                )
            }
        }
        .onAppear {
            animationStartTime = Date.timeIntervalSinceReferenceDate
            startSampling()
        }
        .onDisappear {
            stopSampling()
        }
    }

    private var pitch: CGFloat { barWidth + barSpacing }

    private var waveformWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    /// Fade horizontal nas bordas: barras nascem suaves à direita e morrem
    /// suaves à esquerda — esconde a entrada/saída de amostras da rolagem.
    private var edgeFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.07),
                .init(color: .black, location: 0.93),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// Loop de amostragem em GRADE AGENDADA: dorme até o próximo deadline
    /// absoluto (`lastSampleAt + período`) em vez de "período após o trabalho".
    /// O padrão antigo acumulava atraso a cada ciclo e o relógio da rolagem
    /// (progress = (now - lastSampleAt)/período, clampado em 1) congelava um
    /// instante a CADA amostra — a micro-trava percebida durante a fala.
    /// `lastSampleAt` avança em múltiplos exatos do período (timestamp
    /// agendado, não o horário real da execução), então a rolagem nunca satura.
    @MainActor
    private func startSampling() {
        guard sampleTask == nil else { return }
        lastSampleAt = Date.timeIntervalSinceReferenceDate
        sampleTask = Task { @MainActor in
            while !Task.isCancelled {
                let now = Date.timeIntervalSinceReferenceDate
                let nextDeadline = lastSampleAt + samplePeriod
                if nextDeadline > now {
                    try? await Task.sleep(for: .seconds(nextDeadline - now))
                }
                guard !Task.isCancelled else { break }
                appendPendingSamples()
            }
        }
    }

    @MainActor
    private func stopSampling() {
        sampleTask?.cancel()
        sampleTask = nil
    }

    @MainActor
    private func appendPendingSamples() {
        let now = Date.timeIntervalSinceReferenceDate
        let slots = WaveformDynamics.pendingSampleSlots(
            scheduledLastSampleAt: lastSampleAt,
            now: now,
            samplePeriod: samplePeriod,
            maximumSlots: barCount + 1
        )
        guard slots > 0 else { return }

        let level = model.getAudioLevel?() ?? 0
        for _ in 0..<slots {
            previousSmoothedLevel = smoothedLevel
            smoothedLevel = WaveformDynamics.nextDisplayLevel(
                rawLevel: level,
                previousLevel: smoothedLevel
            )
            // +1 de capacidade: uma amostra extra fora da tela para o deslize
            // contínuo não descartar a barra que ainda está saindo pela esquerda.
            history = WaveformDynamics.appending(smoothedLevel, to: history, capacity: barCount + 1)
        }

        if slots >= barCount + 1 {
            // Stall maior que a janela visível: reancora a grade no presente
            // em vez de correr atrás de slots que já saíram da tela.
            lastSampleAt = now
        } else {
            lastSampleAt += Double(slots) * samplePeriod
        }

        // Aviso de clipping pega carona no mesmo loop de amostragem.
        let clipping = model.getMicClipping?() ?? false
        if model.micClippingActive != clipping {
            model.micClippingActive = clipping
        }
    }

    private func drawWaveform(
        in context: inout GraphicsContext,
        size: CGSize,
        now: TimeInterval,
        progress: CGFloat,
        liveLevel: CGFloat,
        attack: Float
    ) {
        // Snapshots congelam via phase override; previews sem áudio usam o
        // histórico sintético determinístico.
        let phase = model.waveformAnimationPhaseOverride ?? max(0, now - animationStartTime)

        let rawSamples: [Float]
        if let levelOverride = model.waveformLevelOverride {
            rawSamples = WaveformDynamics.syntheticSpeechHistory(
                count: barCount + 1,
                level: levelOverride,
                phase: phase
            )
        } else {
            rawSamples = history
        }
        // Perfil suavizado: vizinhas se conectam como onda, sem serrilhado.
        let samples = WaveformDynamics.smoothedProfile(rawSamples)

        let rightmostX = size.width - barWidth
        let centerY = size.height / 2

        for distance in 0...barCount {
            let x = WaveformDynamics.scrollingBarX(
                distanceFromNewest: distance,
                sampleProgress: progress,
                pitch: pitch,
                rightmostX: rightmostX
            )
            guard x > -barWidth, x < size.width + barWidth else { continue }

            let sampleIndex = samples.count - 1 - distance
            var level = sampleIndex >= 0 ? min(max(samples[sampleIndex], 0), 1) : 0

            // "Caneta" ao vivo: a barra mais recente acompanha o nível
            // interpolado em tempo real e congela exatamente no valor
            // amostrado quando envelhece — altura contínua, sem pop de
            // entrada. Snapshots (override) mantêm o perfil sintético.
            if distance == 0, model.waveformLevelOverride == nil {
                level = Float(liveLevel)
            }

            // Linha de base respira de leve no silêncio (determinística por
            // slot+phase; desativada com Reduce Motion).
            if !reduceMotion {
                level = max(level, WaveformDynamics.idleBreathLevel(slot: distance, phase: phase))
            }

            let height = WaveformDynamics.scrollingBarHeight(
                level: level,
                minimumHeight: minimumBarHeight,
                maximumHeight: maximumBarHeight
            )

            let position = 1 - (CGFloat(distance) + progress) / CGFloat(barCount)
            let opacity = min(
                WaveformDynamics.scrollingBarOpacity(level: level, positionProgress: position)
                    + WaveformDynamics.recencyBoost(distanceFromNewest: distance)
                    + WaveformDynamics.onsetBoost(attack: attack, distanceFromNewest: distance),
                0.98
            )

            let rect = CGRect(
                x: x,
                y: centerY - height / 2,
                width: barWidth,
                height: height
            )
            let bar = Path(roundedRect: rect, cornerRadius: barWidth / 2)

            // Temperatura de cor: cauda antiga esfria (branco-azulado), o
            // presente é branco puro — reforça a leitura de "agora" à direita.
            let coolness = 1 - position
            let tint = Color(
                red: 1 - 0.20 * coolness,
                green: 1 - 0.16 * coolness,
                blue: 1 - 0.05 * coolness
            )

            // Gradiente vertical por barra: núcleo brilhante, pontas suaves —
            // profundidade de "energia" em vez de retângulo chapado.
            context.fill(
                bar,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: tint.opacity(opacity * 0.62), location: 0),
                        .init(color: tint.opacity(opacity), location: 0.5),
                        .init(color: tint.opacity(opacity * 0.62), location: 1),
                    ]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )
        }
    }
}

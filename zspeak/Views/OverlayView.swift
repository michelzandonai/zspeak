import SwiftUI
import AppKit

/// Modelo observável do overlay — atualizado in-place para evitar recriação de views
@Observable
@MainActor
final class OverlayModel {
    var state: AppState.RecordingState = .idle
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
    /// Closure para ler audioLevel direto do AudioCapture (evita pipeline redundante)
    var getAudioLevel: (@Sendable () async -> Float)?
    /// Usado apenas por snapshots para congelar a fase da animacao.
    var waveformAnimationPhaseOverride: TimeInterval?
    /// Usado apenas por snapshots para renderizar a waveform em estado ativo.
    var waveformLevelOverride: Float?

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
        VStack(spacing: 8) {
            if model.translationVisible {
                if model.selectionTranslationPresentation == .compactLookup {
                    CompactSelectionLookupOverlayContent(model: model)
                } else {
                    SelectionTranslationOverlayContent(model: model)
                }
            } else {
            // Linha superior: app em foco + branding (estilo Spokenly)
            HStack(spacing: 8) {
                if let icon = model.focusedAppIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .accessibilityHidden(true)
                }

                Text(model.focusedAppName)
                    .font(.system(.body, design: .default).weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .accessibilityLabel("App em foco: \(model.focusedAppName)")

                Spacer()

                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityHidden(true)
                Text("zspeak")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .accessibilityHidden(true)
            }

            // Bloco central por estado
            if state == .preparing {
                // Engine subindo entre o press do hotkey e o 1º sample real.
                // Mostra um spinner discreto com o mesmo footprint vertical da
                // waveform para evitar "pulo" de layout na transição → recording.
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.7))
                        .accessibilityHidden(true)
                    Text("Preparando microfone...")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
                .frame(height: 20)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Preparando microfone")
            } else if state == .recording {
                WaveformView(model: model)
                    .frame(height: 48)
                    .accessibilityLabel("Forma de onda do áudio capturado")

                // Nome do mic ativo durante gravação — reativo via MicrophoneManager.
                // Tipografia pequena e secundária para não competir com a waveform.
                // Trunca no meio se o nome do device for muito longo.
                // Dynamic Type limitado a xLarge: em tamanhos a11y, o nome do mic
                // cresceria demais e quebraria o layout lateral do overlay.
                let micName = model.effectiveMicrophoneName
                if !micName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .accessibilityHidden(true)
                        Text(micName)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .dynamicTypeSize(...DynamicTypeSize.xLarge)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Microfone ativo: \(micName)")
                }
            } else if state == .processing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.7))
                    .frame(height: 20)
                    .accessibilityLabel("Processando transcrição")
            }

            if state == .recording || state == .processing {
                TranscriptionPreviewBlock(
                    text: model.liveTranscriptionPreview,
                    state: state
                )
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
                    .background(.white.opacity(0.25))

                PromptSelectorBar(model: model)

                if let error = model.errorMessage {
                    PromptErrorView(message: error)
                }

                // Resultado da última correção LLM (toggleável)
                if model.lastLLMResult != nil {
                    Divider()
                        .background(.white.opacity(0.25))

                    LLMResultView(model: model)
                }
            }
            }
        }
        .padding(.horizontal, model.selectionTranslationPresentation == .compactLookup ? 11 : 16)
        .padding(.vertical, model.selectionTranslationPresentation == .compactLookup ? 9 : 12)
        .frame(width: overlayWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.045, green: 0.047, blue: 0.050).opacity(0.96),
                            Color(red: 0.010, green: 0.012, blue: 0.014).opacity(0.94),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.36), radius: 16, y: 6)
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
        if state == .recording || state == .processing { return 520 }
        return model.promptModeEnabled ? 520 : 320
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "quote.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))

            ScrollView {
                if isWaitingForText {
                    Text(waitingMessage)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.62))
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
            .frame(maxHeight: 96)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.2), lineWidth: 0.5)
        )
    }
}

private struct ProgressiveTranscriptText: View {
    let text: String
    let animate: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderedText: String = ""
    @State private var targetText: String = ""
    @State private var revealTask: Task<Void, Never>?

    var body: some View {
        Text(renderedText)
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
            renderedText = target
            return
        }

        if renderedText.isEmpty {
            renderedText = ProgressiveTextReveal.startText(
                current: renderedText,
                target: target
            )
        }

        guard revealTask == nil else { return }
        revealTask = Task { @MainActor in
            await revealCurrentTarget()
        }
    }

    @MainActor
    private func revealCurrentTarget() async {
        defer {
            let shouldContinue = !Task.isCancelled && renderedText != targetText && animate && !reduceMotion
            revealTask = nil
            if shouldContinue {
                updateRevealTarget(targetText)
            }
        }

        while renderedText != targetText, !Task.isCancelled {
            var current = ProgressiveTextReveal.startText(
                current: renderedText,
                target: targetText
            )

            if current != renderedText {
                withAnimation(.smooth(duration: 0.055)) {
                    renderedText = current
                }
            } else {
                let remaining = ProgressiveTextReveal.remainingCharacterCount(
                    current: current,
                    target: targetText
                )
                let batchSize = ProgressiveTextReveal.batchSize(
                    remainingCharacterCount: remaining
                )
                let duration = ProgressiveTextReveal.animationDuration(
                    remainingCharacterCount: remaining
                )
                current = ProgressiveTextReveal.nextText(
                    current: current,
                    target: targetText,
                    maxCharacters: batchSize
                )

                withAnimation(.smooth(duration: duration)) {
                    renderedText = current
                }
            }

            let remainingAfterStep = ProgressiveTextReveal.remainingCharacterCount(
                current: current,
                target: targetText
            )
            let delay = ProgressiveTextReveal.frameDelayMilliseconds(
                remainingCharacterCount: remainingAfterStep
            )

            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(Int64(delay)))
            } else {
                renderedText = current
                await Task.yield()
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
                        Text(model.selectedPrompt?.name ?? "Selecionar prompt")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white.opacity(0.25), lineWidth: 0.5)
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
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.white.opacity(0.25), lineWidth: 0.5)
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
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.2), lineWidth: 0.5)
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
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.2), lineWidth: 0.5)
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

private struct PromptDiffSegmentRow: View {
    let segment: PromptDiffSegment

    private var tint: Color {
        switch segment.kind {
        case .equal: return .white
        case .removed: return .red
        case .added: return .green
        }
    }

    private var marker: String {
        switch segment.kind {
        case .equal: return " "
        case .removed: return "-"
        case .added: return "+"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(marker)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(tint.opacity(segment.kind == .equal ? 0.25 : 0.95))
                .frame(width: 12, alignment: .center)

            Text(segment.text)
                .font(.caption)
                .foregroundStyle(.white.opacity(segment.kind == .equal ? 0.86 : 0.96))
                .strikethrough(segment.kind == .removed, color: .white.opacity(0.75))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(segment.kind == .equal ? .white.opacity(0.035) : tint.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(segment.kind == .equal ? .white.opacity(0.06) : tint.opacity(0.36), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(segment.text)
    }

    private var accessibilityLabel: String {
        switch segment.kind {
        case .equal: return "Sem alteração"
        case .removed: return "Removido"
        case .added: return "Adicionado"
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

/// Diff simples em estilo GitHub: vermelho para trechos removidos da
/// transcrição bruta e verde para trechos adicionados pelo prompt/LLM.
private struct LLMDiffBlock: View {
    let original: String
    let revised: String

    private var chunks: [PromptDiffChunk] {
        PromptWordDiff.chunks(original: original, revised: revised)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Mudanças", systemImage: "plus.forwardslash.minus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))

            if chunks.isEmpty {
                Text("Sem mudanças relevantes.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.62))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(chunks) { chunk in
                            PromptDiffRow(chunk: chunk)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.2), lineWidth: 0.5)
        )
    }
}

private struct PromptDiffRow: View {
    let chunk: PromptDiffChunk

    private var tint: Color {
        switch chunk.kind {
        case .removed: return .red
        case .added: return .green
        }
    }

    private var prefix: String {
        switch chunk.kind {
        case .removed: return "-"
        case .added: return "+"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(prefix)
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(tint.opacity(0.95))
                .frame(width: 12, alignment: .center)

            Text(chunk.text)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.94))
                .strikethrough(chunk.kind == .removed, color: .white.opacity(0.75))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(tint.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(tint.opacity(0.36), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(chunk.kind == .removed ? "Removido" : "Adicionado")
        .accessibilityValue(chunk.text)
    }
}

private struct PromptDiffChunk: Identifiable {
    enum Kind {
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

    static func chunks(original: String, revised: String) -> [PromptDiffChunk] {
        let originalTokens = tokenize(original)
        let revisedTokens = tokenize(revised)
        guard !originalTokens.isEmpty || !revisedTokens.isEmpty else { return [] }

        let edits = edits(originalTokens: originalTokens, revisedTokens: revisedTokens)
        return groupedChunks(from: edits)
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

    private static func groupedChunks(from edits: [Edit]) -> [PromptDiffChunk] {
        var chunks: [PromptDiffChunk] = []
        var currentKind: PromptDiffChunk.Kind?
        var currentWords: [String] = []

        func flush() {
            guard let kind = currentKind else { return }
            let text = currentWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                chunks.append(PromptDiffChunk(kind: kind, text: text))
            }
            currentKind = nil
            currentWords = []
        }

        for edit in edits {
            switch edit {
            case .equal:
                flush()
            case .removed(let word):
                if currentKind != .removed {
                    flush()
                    currentKind = .removed
                }
                currentWords.append(word)
            case .added(let word):
                if currentKind != .added {
                    flush()
                    currentKind = .added
                }
                currentWords.append(word)
            }
        }

        flush()
        return chunks
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
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
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
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.2), lineWidth: 0.5)
        )
    }
}

/// HUD de voz inspirado no padrão mobile do ChatGPT: barras discretas,
/// preview ao vivo separado e relógio visual desacoplado do volume.
struct WaveformView: View {
    let model: OverlayModel

    private let barCount = 32
    private let sampleCount = 32
    private let barWidth: CGFloat = 4
    private let barSpacing: CGFloat = 3
    private let minimumBarHeight: CGFloat = 4
    private let maximumBarHeight: CGFloat = 30
    private let waveformHeight: CGFloat = 40
    private let recordingColor = Color.white
    private let renderPeriod: TimeInterval = 1.0 / 60.0

    @State private var history: [Float] = Array(repeating: 0, count: 32)
    @State private var smoothedLevel: Float = 0
    @State private var sampleTask: Task<Void, Never>?
    @State private var animationStartTime: TimeInterval = Date.timeIntervalSinceReferenceDate

    var body: some View {
        TimelineView(.animation(minimumInterval: renderPeriod)) { context in
            let phase = model.waveformAnimationPhaseOverride ?? max(
                0,
                context.date.timeIntervalSinceReferenceDate - animationStartTime
            )
            HStack(spacing: 10) {
                Canvas { canvas, size in
                    drawWaveform(
                        in: &canvas,
                        size: size,
                        phase: phase
                    )
                }
                .frame(width: waveformWidth, height: waveformHeight)

                Text(formattedElapsedTime(phase))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(width: 34, alignment: .leading)
                    .accessibilityHidden(true)
            }
            .frame(height: waveformHeight)
            .shadow(
                color: recordingColor.opacity(0.10 + Double(smoothedLevel) * 0.18),
                radius: 5 + CGFloat(smoothedLevel) * 8,
                x: 0,
                y: 0
            )
        }
        .onAppear {
            animationStartTime = Date.timeIntervalSinceReferenceDate
            startSampling()
        }
        .onDisappear {
            stopSampling()
        }
    }

    private var waveformWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
    }

    @MainActor
    private func startSampling() {
        guard sampleTask == nil else { return }
        sampleTask = Task { @MainActor in
            while !Task.isCancelled {
                await updateAudioLevel()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    @MainActor
    private func stopSampling() {
        sampleTask?.cancel()
        sampleTask = nil
    }

    @MainActor
    private func updateAudioLevel() async {
        let level = await model.getAudioLevel?() ?? 0
        smoothedLevel = WaveformDynamics.nextDisplayLevel(
            rawLevel: level,
            previousLevel: smoothedLevel
        )
        history = WaveformDynamics.appending(smoothedLevel, to: history, capacity: sampleCount)
    }

    private func drawWaveform(in context: inout GraphicsContext, size: CGSize, phase: TimeInterval) {
        let level = model.waveformLevelOverride ?? smoothedLevel
        let centerY = size.height / 2

        for index in 0..<barCount {
            let energy = WaveformDynamics.chatGPTWaveformBarEnergy(
                index: index,
                count: barCount,
                level: level,
                history: history,
                phase: phase
            )
            let height = WaveformDynamics.chatGPTWaveformBarHeight(
                index: index,
                count: barCount,
                level: level,
                history: history,
                phase: phase,
                minimumHeight: minimumBarHeight,
                maximumHeight: maximumBarHeight
            )
            let opacity = WaveformDynamics.chatGPTWaveformBarOpacity(
                index: index,
                count: barCount,
                energy: energy
            )
            let x = CGFloat(index) * (barWidth + barSpacing)
            let rect = CGRect(
                x: x,
                y: centerY - height / 2,
                width: barWidth,
                height: height
            )
            var bar = Path()
            bar.addRoundedRect(
                in: rect,
                cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2)
            )
            context.fill(
                bar,
                with: .color(recordingColor.opacity(opacity))
            )
        }
    }

    private func formattedElapsedTime(_ elapsed: TimeInterval) -> String {
        let totalSeconds = max(0, Int(elapsed.rounded(.down)))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }

}

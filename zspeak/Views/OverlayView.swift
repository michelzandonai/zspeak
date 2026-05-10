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

    /// Último resultado gerado pela LLM (para exibir no overlay)
    var lastLLMResult: String?
    var lastLLMPromptName: String?

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
                    .frame(height: 20)
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

            if model.promptModeEnabled {
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

                // Resultado da última correção LLM (toggleável)
                if model.lastLLMResult != nil {
                    Divider()
                        .background(.white.opacity(0.25))

                    LLMResultView(model: model)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: model.promptModeEnabled ? 520 : 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        // VoiceOver: anuncia o estado corrente do overlay como valor do container.
        // O label de cada bloco interno (preparing/recording/processing) também
        // é exposto, mas esse valor global ajuda a orientar quem entra no overlay.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Overlay do zspeak")
        .accessibilityValue(stateAccessibilityLabel)
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
            return "Gravando... a transcrição aparecerá aqui ao finalizar."
        case .processing:
            return "Processando transcrição..."
        case .idle:
            return "Nenhuma transcrição capturada ainda."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Transcrição capturada", systemImage: "quote.bubble")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))

            ScrollView {
                Text(isWaitingForText ? waitingMessage : text)
                    .font(.body)
                    .foregroundStyle(isWaitingForText ? .white.opacity(0.62) : .white.opacity(0.95))
                    .italic(isWaitingForText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityLabel("Transcrição capturada")
                    .accessibilityValue(isWaitingForText ? waitingMessage : text)
            }
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

/// Waveform estilo Spokenly — barras que rolam da direita pra esquerda como áudio gravando.
///
/// Pipeline anterior (removido): `Timer.scheduledTimer(0.033)` por WaveformView +
/// `Task { @MainActor }` em cada tick + `.animation(value: barHeight(for:))`
/// reavaliando a função a cada frame, acoplado a um tap em 94 Hz que também
/// enfileirava `Task { @MainActor }` por callback. Três caminhos concorrentes
/// passando o mesmo `Float`.
///
/// Agora: `TimelineView(.periodic)` acoplada ao compositor (CoreAnimation), não
/// ao MainActor. O SwiftUI agenda 30 ticks/s sem criar `Task` unstructured. O
/// valor é puxado do closure `model.getAudioLevel` (read sync sob `os_unfair_lock`
/// no `AudioLevelMonitor`) via `.task(id:)` do context date, e a altura é
/// calculada a partir do `history` local.
///
/// A animação foi movida para dentro de `withAnimation` quando atualizamos o
/// histórico — não fica mais em `.animation(value:)` reavaliando `barHeight(for:)`
/// a cada render.
struct WaveformView: View {
    let model: OverlayModel

    private let barCount = 30
    private let barWidth: CGFloat = 4.5
    private let barSpacing: CGFloat = 2.5
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 24
    /// Período de amostragem — 0.016 s ≈ 60 fps, acompanha display a 60/120 Hz.
    /// Em monitor ProMotion (120 Hz) o TimelineView interpola visualmente.
    private let samplePeriod: TimeInterval = 0.016

    @State private var history: [Float] = Array(repeating: 0, count: 30)
    @State private var smoothedLevel: Float = 0

    /// Fator de suavização EMA — 0.35 = transição visual natural.
    /// Com sample a 60 Hz, um fator alto tornaria a resposta errática
    /// (picos de RMS entre buffers). 0.35 dá rise/decay perceptível
    /// sem eco e sem gelatinosidade.
    private let smoothingFactor: Float = 0.35

    var body: some View {
        TimelineView(.animation(minimumInterval: samplePeriod)) { context in
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(.white.opacity(barOpacity(for: index)))
                        .frame(width: barWidth, height: barHeight(for: index))
                }
            }
            // `.task(id: context.date)` re-executa a cada tick do TimelineView.
            // Atualização SEM `withAnimation`: o redraw periódico do
            // TimelineView já pinta cada frame com os valores atuais de
            // `history`, resultando em movimento fluido. `withAnimation` +
            // spring por tick fazia 30 springs concorrentes se cancelarem
            // entre si (duração 80 ms > intervalo 16-33 ms), dando sensação
            // de travamento.
            .task(id: context.date) {
                let level = await model.getAudioLevel?() ?? 0
                let amplified = min(level * 2.5, 1.0)
                let newSmoothed = smoothingFactor * amplified + (1 - smoothingFactor) * smoothedLevel
                smoothedLevel = newSmoothed
                history.append(newSmoothed)
                if history.count > barCount {
                    history.removeFirst(history.count - barCount)
                }
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard index < history.count else { return minHeight }
        let value = CGFloat(history[index])
        return minHeight + value * (maxHeight - minHeight)
    }

    private func barOpacity(for index: Int) -> Double {
        guard index < history.count else { return 0.2 }
        let recency = Double(index) / Double(max(barCount - 1, 1))
        let value = Double(history[index])
        return 0.25 + recency * 0.3 + value * 0.45
    }
}

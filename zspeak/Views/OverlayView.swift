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

    var body: some View {
        VStack(spacing: 8) {
            // Linha superior: app em foco + branding (estilo Spokenly)
            HStack(spacing: 8) {
                if let icon = model.focusedAppIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                Text(model.focusedAppName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)

                Spacer()

                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Text("zspeak")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Bloco central por estado
            if state == .preparing {
                // Engine subindo entre o press do hotkey e o 1º sample real.
                // Mostra um spinner discreto com o mesmo footprint vertical da
                // waveform para evitar "pulo" de layout na transição → recording.
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.6))
                    Text("Preparando microfone...")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .frame(height: 20)
            } else if state == .recording {
                WaveformView(model: model)
                    .frame(height: 20)

                // Nome do mic ativo durante gravação — reativo via MicrophoneManager.
                // Tipografia pequena e secundária para não competir com a waveform.
                // Trunca no meio se o nome do device for muito longo.
                let micName = model.effectiveMicrophoneName
                if !micName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.35))
                        Text(micName)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } else if state == .processing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.6))
                    .frame(height: 20)
            } else if model.promptModeEnabled {
                if !model.lastTranscription.isEmpty {
                    // Mostra a transcrição captada para o usuário revisar antes de aplicar LLM
                    ScrollView {
                        Text(model.lastTranscription)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 100)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white.opacity(0.1), lineWidth: 0.5)
                    )
                } else {
                    // TextField editável — usuário pode colar texto para o LLM (TASK-013)
                    TextInputBlock(model: model)
                }
            }

            // Seção inferior: seletor de prompt + botão aplicar (Modo Prompt)
            if model.promptModeEnabled {
                Divider()
                    .background(.white.opacity(0.1))

                PromptSelectorBar(model: model)

                // Resultado da última correção LLM (toggleável)
                if model.lastLLMResult != nil {
                    Divider()
                        .background(.white.opacity(0.1))

                    LLMResultView(model: model)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: model.promptModeEnabled ? 440 : 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}

/// Barra inferior do overlay no Modo Prompt: Menu dropdown com todos os prompts + botão Aplicar
struct PromptSelectorBar: View {
    let model: OverlayModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isApplyingPrompt {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.7))
                Text("Aplicando \(model.selectedPrompt?.name ?? "")...")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer()
            } else {
                // Dropdown de prompts — Menu com label custom (chevron no lugar certo)
                Menu {
                    ForEach(model.prompts) { prompt in
                        Button {
                            model.selectedPromptID = prompt.id
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
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.white.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.white.opacity(0.15), lineWidth: 0.5)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                // Botão "colar do clipboard" — usa texto do clipboard como input do LLM (TASK-012)
                Button {
                    model.onPasteAndApply?()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.white.opacity(0.15), lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Aplicar prompt no texto do clipboard")

                Spacer()

                // Botão Aplicar
                Button {
                    if let prompt = model.selectedPrompt {
                        model.onApplyPrompt?(prompt)
                    }
                } label: {
                    Text("Aplicar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.accentColor.opacity(0.8))
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.selectedPrompt == nil)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Visualização do último resultado da LLM — pode ser expandida ou colapsada
struct LLMResultView: View {
    let model: OverlayModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header com toggle expand/collapse + nome do prompt + botão copiar
            HStack(spacing: 6) {
                if model.isApplyingPrompt {
                    // Spinner enquanto LLM gera (TASK-011) — feedback visual de streaming ao vivo
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.5))
                        .frame(width: 12)
                } else {
                    Image(systemName: model.isResultExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 12)
                }

                Text("Resultado")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))

                if let name = model.lastLLMPromptName {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.3))
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
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
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Copiar resultado")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    model.isResultExpanded.toggle()
                }
            }

            // Conteúdo expandido
            if model.isResultExpanded, let text = model.lastLLMResult {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                )
            }
        }
    }
}

/// Campo de texto editável dentro do overlay no Modo Prompt (TASK-013).
/// Aceita digitação e paste; ao detectar paste (mudança brusca > 20 chars), dispara
/// automaticamente o LLM via `model.onTextInputApply`. Limpa o campo após disparar
/// para indicar que o texto foi consumido.
struct TextInputBlock: View {
    let model: OverlayModel
    @State private var text: String = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Placeholder manual — TextField padrão tem placeholder com cor de sistema
            // que fica invisível em fundo escuro
            if text.isEmpty {
                Text("Cole um texto aqui para o LLM processar...")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .allowsHitTesting(false)
            }

            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .tint(.white.opacity(0.7))
                .onChange(of: text) { oldValue, newValue in
                    // Heurística: aumento brusco (> 20 chars) é provável paste.
                    // Digitação humana raramente adiciona mais de ~5 chars por evento.
                    let delta = newValue.count - oldValue.count
                    if delta > 20 {
                        let pasted = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !pasted.isEmpty {
                            model.onTextInputApply?(pasted)
                            // Limpa o campo após consumir — feedback visual de "processado"
                            text = ""
                        }
                    }
                }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}

/// Waveform estilo Spokenly — barras que rolam da direita pra esquerda como áudio gravando
struct WaveformView: View {
    let model: OverlayModel

    private let barCount = 30
    private let barWidth: CGFloat = 4.5
    private let barSpacing: CGFloat = 2.5
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 24

    @State private var history: [Float] = []
    @State private var smoothedLevel: Float = 0
    @State private var timer: Timer?

    /// Fator de suavização EMA — 0.8 = 80% valor novo, 20% histórico
    private let smoothingFactor: Float = 0.8

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(.white.opacity(barOpacity(for: index)))
                    .frame(width: barWidth, height: barHeight(for: index))
                    .animation(.spring(duration: 0.08, bounce: 0.1), value: barHeight(for: index))
            }
        }
        .onAppear {
            history = Array(repeating: 0, count: barCount)
            timer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak model] _ in
                Task { @MainActor in
                    guard let model else { return }
                    let level = await model.getAudioLevel?() ?? 0
                    let amplified = min(level * 2.5, 1.0)
                    smoothedLevel = smoothingFactor * amplified + (1 - smoothingFactor) * smoothedLevel
                    history.append(smoothedLevel)
                    if history.count > barCount {
                        history.removeFirst(history.count - barCount)
                    }
                }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
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

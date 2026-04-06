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
    var microphoneName: String = ""
    /// Closure para ler audioLevel direto do AudioCapture (evita pipeline redundante)
    var getAudioLevel: (@Sendable () async -> Float)?

    // Prompts LLM para o overlay
    var prompts: [CorrectionPrompt] = []
    var activePromptName: String = ""
    var showPromptSelector: Bool = false

    // Callbacks para ações do overlay
    var onApplyPrompt: (() -> Void)?
    var onSwitchAndApplyPrompt: ((CorrectionPrompt) -> Void)?
    var onDismissPromptReady: (() -> Void)?
}

/// Overlay visual estilo Spokenly — barra escura com waveform reativa
struct OverlayView: View {
    let model: OverlayModel

    private var state: AppState.RecordingState { model.state }

    var body: some View {
        VStack(spacing: 8) {
            // Linha superior: app em foco + branding (estilo Spokenly)
            HStack(spacing: 8) {
                // Ícone + nome do app em foco
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

                // Branding
                Image(systemName: "waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                Text("zspeak")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }

            // Waveform estilo Spokenly
            if state == .recording {
                WaveformView(model: model)
                    .frame(height: 20)

                // Nome do microfone
                if !model.microphoneName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.white.opacity(0.35))
                        Text(model.microphoneName)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                    }
                }
            } else if state == .processing {
                // Animação de progresso durante transcrição
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.6))
                    .frame(height: 20)
            } else if state == .promptReady {
                // Botão de aplicar prompt com seletor
                HStack(spacing: 0) {
                    // Área clicável principal — aplica prompt ativo
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                            .foregroundStyle(.yellow)
                        Text(model.activePromptName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.onApplyPrompt?()
                    }

                    // Chevron para lista de prompts
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.showPromptSelector.toggle()
                        }

                    // Separador vertical
                    Rectangle()
                        .fill(.white.opacity(0.15))
                        .frame(width: 1, height: 20)
                        .padding(.horizontal, 4)

                    // Botão dismiss
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.onDismissPromptReady?()
                        }
                }
                .overlay(alignment: .top) {
                    if model.showPromptSelector {
                        PromptSelectorView(
                            prompts: model.prompts,
                            onSelect: { prompt in
                                model.showPromptSelector = false
                                model.onSwitchAndApplyPrompt?(prompt)
                            }
                        )
                        .offset(y: -8)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            } else if state == .applyingPrompt {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.6))
                    Text("Aplicando \(model.activePromptName)...")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(height: 20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 320)
        .background(.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    private var statusText: String {
        switch state {
        case .recording: return "Gravando..."
        case .processing: return "Transcrevendo..."
        case .idle: return "Pronto"
        case .promptReady: return "Prompt disponível"
        case .applyingPrompt: return "Aplicando prompt..."
        }
    }
}

/// Seletor de prompts que aparece acima do overlay no estado promptReady
struct PromptSelectorView: View {
    let prompts: [CorrectionPrompt]
    let onSelect: (CorrectionPrompt) -> Void

    var body: some View {
        VStack(spacing: 2) {
            ForEach(prompts) { prompt in
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow.opacity(0.7))
                    Text(prompt.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    onSelect(prompt)
                }
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white.opacity(0.05))
                )
            }
        }
        .padding(6)
        .background(.black.opacity(0.95))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
        .frame(width: 200)
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
            // Timer a ~30 FPS — animação SwiftUI interpola entre frames
            timer = Timer.scheduledTimer(withTimeInterval: 0.033, repeats: true) { [weak model] _ in
                Task { @MainActor in
                    guard let model else { return }
                    let level = await model.getAudioLevel?() ?? 0
                    let amplified = min(level * 2.5, 1.0)
                    // Suavização exponencial (EMA) — elimina jitter
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

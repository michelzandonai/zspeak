import SwiftUI
import AppKit

/// Modelo observável do overlay — atualizado in-place para evitar recriação de views
@Observable
@MainActor
final class OverlayModel {
    var state: AppState.RecordingState = .idle
    var audioLevel: Float = 0
    var isModelReady: Bool = false
    var focusedAppName: String = ""
    var focusedAppIcon: NSImage?
    var microphoneName: String = ""
}

/// Overlay visual estilo Spokenly — barra escura com waveform reativa
struct OverlayView: View {
    let model: OverlayModel

    private var state: AppState.RecordingState { model.state }
    private var audioLevel: Float { model.audioLevel }

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
        }
    }
}

/// Waveform estilo Spokenly — barras que rolam da direita pra esquerda como áudio gravando
struct WaveformView: View {
    let model: OverlayModel

    private let barCount = 30
    private let barWidth: CGFloat = 4.5
    private let barSpacing: CGFloat = 2.5
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 20

    @State private var history: [Float] = []
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(.white.opacity(barOpacity(for: index)))
                    .frame(width: barWidth, height: barHeight(for: index))
            }
        }
        .onAppear {
            history = Array(repeating: 0, count: barCount)
            // Timer a ~80 FPS — lê level direto do model (sempre atualizado)
            timer = Timer.scheduledTimer(withTimeInterval: 0.022, repeats: true) { [weak model] _ in
                Task { @MainActor in
                    guard let model else { return }
                    let amplified = min(model.audioLevel * 3.5, 1.0)
                    history.append(amplified)
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

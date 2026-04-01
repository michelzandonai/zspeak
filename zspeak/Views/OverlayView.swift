import SwiftUI

/// Modelo observável do overlay — atualizado in-place para evitar recriação de views
@Observable
@MainActor
final class OverlayModel {
    var state: AppState.RecordingState = .idle
    var audioLevel: Float = 0
    var isModelReady: Bool = false
}

/// Overlay visual de feedback durante gravação e transcrição
struct OverlayView: View {
    let model: OverlayModel

    private var state: AppState.RecordingState { model.state }
    private var audioLevel: Float { model.audioLevel }
    private var isModelReady: Bool { model.isModelReady }

    // Animação do pulsing
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 14) {
            // Indicador de estado (círculo colorido)
            statusIndicator

            // Texto + barras de áudio
            VStack(alignment: .leading, spacing: 4) {
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)

                if state == .recording {
                    AudioBarsView(level: audioLevel)
                        .frame(height: 16)
                }
            }

            Spacer()

            // Atalho de teclado como dica
            if state == .recording {
                Text("⌨ para parar")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 280, height: 72)
        .background(.ultraThinMaterial.opacity(0.95))
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .onChange(of: state) { _, newState in
            isPulsing = newState == .recording
        }
    }

    // MARK: - Indicador de estado

    @ViewBuilder
    private var statusIndicator: some View {
        switch state {
        case .recording:
            Circle()
                .fill(.red)
                .frame(width: 14, height: 14)
                .scaleEffect(isPulsing ? 1.3 : 1.0)
                .opacity(isPulsing ? 0.7 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)
                .onAppear { isPulsing = true }

        case .processing:
            ProgressView()
                .controlSize(.small)
                .tint(.yellow)

        case .idle:
            Circle()
                .fill(.green)
                .frame(width: 14, height: 14)
        }
    }

    // MARK: - Texto de status

    private var statusText: String {
        switch state {
        case .recording: return "Gravando..."
        case .processing: return "Transcrevendo..."
        case .idle: return "Pronto"
        }
    }
}

/// Barras animadas de nível de áudio
struct AudioBarsView: View {
    let level: Float

    private let barCount = 20

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: index))
                    .frame(width: 4, height: barHeight(for: index))
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let normalizedIndex = Float(index) / Float(barCount)
        let threshold = level * 1.2

        if normalizedIndex < threshold {
            // Barras ativas - altura baseada no nível
            let height = CGFloat(level) * 16 + CGFloat.random(in: 2...6)
            return min(max(height, 3), 16)
        } else {
            return 3 // Barras inativas
        }
    }

    private func barColor(for index: Int) -> Color {
        let normalizedIndex = Float(index) / Float(barCount)
        if normalizedIndex < level * 0.6 {
            return .green
        } else if normalizedIndex < level * 0.85 {
            return .yellow
        } else if normalizedIndex < level {
            return .red
        }
        return .white.opacity(0.2)
    }
}

import SwiftUI

/// Design system dedicado ao modo tray.
///
/// Mantém o tray alinhado ao overlay principal sem herdar a densidade dele:
/// superfícies azul-grafite, texto de alto contraste e vermelho reservado ao
/// estado de captura ao vivo.
enum ZSTrayTheme {
    static let panelWidth: CGFloat = 520
    static let minimumPanelWidth: CGFloat = 360
    static let minimumPanelHeight: CGFloat = 96
    static let panelMaxHeight: CGFloat = 150

    static let cornerRadius: CGFloat = 16
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 10
    static let inlineSpacing: CGFloat = 9

    static let textPrimary = ZSDesign.textPrimary
    static let textSecondary = ZSDesign.textSecondary
    static let textTertiary = ZSDesign.textTertiary

    static let surface = ZSDesign.cardBackground.opacity(0.94)
    static let surfaceStroke = ZSDesign.hairline
    static let divider = ZSDesign.divider
    static let waveform = Color.white.opacity(0.72)

    static let recordingAccent = ZSDesign.dangerAccent
    static let preparingAccent = ZSDesign.warningAccent
    static let processingAccent = ZSDesign.accent
}

/// Fita de áudio compacta do tray. O desenho usa níveis reais do microfone;
/// nos snapshots, `levelsOverride` congela um perfil determinístico.
struct ZSTraySignalWaveform: View {
    let isActive: Bool
    let getAudioLevel: (() -> Float)?
    let levelsOverride: [Float]?
    let reduceMotion: Bool

    private let sampleCount = 34
    private let samplePeriod: Duration = .milliseconds(55)

    @State private var history: [Float] = []
    @State private var sampleTask: Task<Void, Never>?

    var body: some View {
        Canvas { context, size in
            let samples = visibleSamples
            let centerY = size.height / 2

            var centerLine = Path()
            centerLine.move(to: CGPoint(x: 0, y: centerY))
            centerLine.addLine(to: CGPoint(x: size.width, y: centerY))
            context.stroke(centerLine, with: .color(ZSTrayTheme.waveform.opacity(0.24)), lineWidth: 0.7)

            context.fill(
                ribbonPath(samples: samples, size: size, scale: 1.0, floor: 1.2),
                with: .color(ZSTrayTheme.waveform.opacity(0.18))
            )
            context.fill(
                ribbonPath(samples: samples, size: size, scale: 0.66, floor: 1.0),
                with: .color(ZSTrayTheme.waveform.opacity(0.34))
            )
            context.fill(
                ribbonPath(samples: samples, size: size, scale: 0.30, floor: 0.75),
                with: .color(ZSTrayTheme.waveform.opacity(0.72))
            )
        }
        .frame(height: 26)
        .accessibilityHidden(true)
        .onAppear { startSamplingIfNeeded() }
        .onChange(of: isActive) { _, _ in startSamplingIfNeeded() }
        .onChange(of: reduceMotion) { _, _ in startSamplingIfNeeded() }
        .onDisappear { stopSampling() }
    }

    private var visibleSamples: [Float] {
        let source = levelsOverride ?? history
        if source.count >= sampleCount {
            return Array(source.suffix(sampleCount))
        }
        return Array(repeating: 0, count: sampleCount - source.count) + source
    }

    private func ribbonPath(
        samples: [Float],
        size: CGSize,
        scale: CGFloat,
        floor: CGFloat
    ) -> Path {
        let centerY = size.height / 2
        let pitch = size.width / CGFloat(max(sampleCount - 1, 1))
        let maximumAmplitude = max(0, size.height / 2 - 1)
        let amplitudes = samples.map {
            floor + CGFloat($0) * max(0, maximumAmplitude - floor) * scale
        }

        let upper = amplitudes.indices.map {
            CGPoint(x: CGFloat($0) * pitch, y: centerY - amplitudes[$0])
        }
        let lower = amplitudes.indices.reversed().map {
            CGPoint(x: CGFloat($0) * pitch, y: centerY + amplitudes[$0])
        }

        var path = Path()
        path.move(to: upper[0])
        appendSmoothCurve(upper, to: &path)
        path.addLine(to: lower[0])
        appendSmoothCurve(lower, to: &path)
        path.closeSubpath()
        return path
    }

    private func appendSmoothCurve(_ points: [CGPoint], to path: inout Path) {
        guard points.count > 1, let last = points.last else { return }
        if points.count == 2 {
            path.addLine(to: points[1])
            return
        }

        for index in 1..<(points.count - 1) {
            let current = points[index]
            let next = points[index + 1]
            let midpoint = CGPoint(
                x: (current.x + next.x) / 2,
                y: (current.y + next.y) / 2
            )
            path.addQuadCurve(to: midpoint, control: current)
        }
        path.addQuadCurve(to: last, control: points[points.count - 2])
    }

    @MainActor
    private func startSamplingIfNeeded() {
        stopSampling()
        guard isActive, levelsOverride == nil else { return }

        sampleTask = Task { @MainActor in
            while !Task.isCancelled {
                let level = min(max(getAudioLevel?() ?? 0, 0), 1)
                history.append(level)
                if history.count > sampleCount {
                    history.removeFirst(history.count - sampleCount)
                }
                if reduceMotion {
                    try? await Task.sleep(for: .milliseconds(110))
                } else {
                    try? await Task.sleep(for: samplePeriod)
                }
            }
        }
    }

    @MainActor
    private func stopSampling() {
        sampleTask?.cancel()
        sampleTask = nil
    }
}

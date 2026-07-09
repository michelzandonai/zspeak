import AppKit
import Foundation
import Testing
@testable import zspeak

/// Harness de MOVIMENTO do mini-overlay — gated por env, para inspeção
/// visual da datilografia/transições e medição de fluidez do MainActor
/// enquanto o texto é bombeado como num ditado real.
///
/// Captura o contentView do painel REAL (cacheDisplay) em instantes-chave de
/// um ditado sintético e salva PNGs `motion-*.png`; em paralelo um ticker de
/// 8ms mede gaps do MainActor (mesma técnica do OverlayAnimationSmoothness).
/// Rodar com:
/// `TEST_RUNNER_ZSPEAK_RENDER_TRAY_HARNESS=1 TEST_RUNNER_ZSPEAK_TRAY_HARNESS_DIR=/caminho \
///  xcodebuild ... test -only-testing:zspeakTests/TrayInfoOverlayMotionHarness`
@Suite("TrayInfoOverlayMotionHarness", .serialized)
@MainActor
struct TrayInfoOverlayMotionHarness {

    @MainActor
    private final class GapRecorder {
        var gaps: [Double] = []
    }

    private static let sentence = "hoje eu preciso ajustar o deploy do serviço de transcrição para o overlay ficar perfeito sem engasgar e o texto fluir como digitação natural"

    @Test(
        "Sequência de ditado: captura frames e mede gaps do MainActor",
        .enabled(if: ProcessInfo.processInfo.environment["ZSPEAK_RENDER_TRAY_HARNESS"] == "1")
    )
    func dictationMotionSequence() async throws {
        _ = NSApplication.shared
        await UIHarnessLock.shared.acquire()
        defer { Task { await UIHarnessLock.shared.release() } }

        let outputPath = ProcessInfo.processInfo.environment["ZSPEAK_TRAY_HARNESS_DIR"]
            ?? NSTemporaryDirectory().appending("tray-harness")
        let outputDir = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let panel = TrayInfoOverlayPanel()
        panel.prefersReducedMotion = { false }
        defer { panel.orderOut(nil) }

        // Ticker de fluidez: mede a folga do MainActor durante o ditado.
        let recorder = GapRecorder()
        let ticker = Task { @MainActor in
            var last = Date.timeIntervalSinceReferenceDate
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(8))
                let now = Date.timeIntervalSinceReferenceDate
                recorder.gaps.append(now - last)
                last = now
            }
        }

        func present(_ state: AppState.RecordingState, _ text: String) {
            panel.present(
                TrayLivePreview.presentation(
                    state: state, previewText: text, enabled: true,
                    maxWidth: TrayLivePreview.defaultMaxWidth),
                anchoredTo: nil
            )
        }

        func capture(_ name: String) throws {
            guard let content = panel.contentView else { return }
            guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: rep)

            // Composita sobre fundo escuro — a janela é transparente.
            let size = content.bounds.size
            let composed = NSImage(size: size)
            composed.lockFocus()
            NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            NSImage(size: size, flipped: false) { rect in
                rep.draw(in: rect)
                return true
            }.draw(in: NSRect(origin: .zero, size: size))
            composed.unlockFocus()

            guard
                let tiff = composed.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else { return }
            let url = outputDir.appendingPathComponent("\(name).png")
            try png.write(to: url, options: .atomic)
            print("[tray-motion] \(name): \(url.path)")
        }

        // 1. Entrada + placeholder "Ouvindo…".
        present(.recording, "")
        try await Task.sleep(for: .milliseconds(120))
        try capture("motion-1-entrada")
        try await Task.sleep(for: .milliseconds(300))
        try capture("motion-2-ouvindo")

        // 2. Ditado sintético: preview cresce palavra a palavra a ~8 palavras/s
        // (cadência de fala real do ASR).
        let words = Self.sentence.split(separator: " ").map(String.init)
        var checkpoints: [Int: String] = [
            5: "motion-3-digitando-inicio",
            12: "motion-4-digitando-meio",
            words.count - 1: "motion-5-multilinha",
        ]
        for index in words.indices {
            let text = words[0...index].joined(separator: " ")
            present(.recording, text)
            try await Task.sleep(for: .milliseconds(120))
            if let name = checkpoints.removeValue(forKey: index) {
                // Deixa a datilografia alcançar o alvo antes de capturar.
                try await Task.sleep(for: .milliseconds(600))
                try capture(name)
            }
        }

        // 3. Processing (waveform animada) e saída.
        present(.processing, Self.sentence)
        try await Task.sleep(for: .milliseconds(400))
        try capture("motion-6-processing")

        panel.dismiss()
        try await Task.sleep(for: .milliseconds(80))
        try capture("motion-7-saida")
        try await Task.sleep(for: .milliseconds(300))

        ticker.cancel()
        try? await Task.sleep(for: .milliseconds(50))

        // Fluidez: o pill não pode engasgar o MainActor durante o ditado.
        let gaps = recorder.gaps
        try #require(gaps.count > 100, "Ticker não rodou o suficiente (\(gaps.count) ticks)")
        let total = gaps.reduce(0, +)
        let maxGap = gaps.max() ?? 0
        let hitchTime = gaps.filter { $0 > 0.034 }.reduce(0, +)
        let sorted = gaps.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        print(String(
            format: "[tray-motion] ticks=%d maxGap=%.1fms p95=%.1fms hitchTime=%.0fms (%.1f%% da janela)",
            gaps.count, maxGap * 1000, p95 * 1000, hitchTime * 1000, hitchTime / total * 100
        ))
        #expect(maxGap < 0.25, "Stall de \(Int(maxGap * 1000))ms no MainActor durante o ditado no tray")
        #expect(hitchTime < total * 0.15, "MainActor passou \(Int(hitchTime * 1000))ms em hitches (>34ms)")
    }
}

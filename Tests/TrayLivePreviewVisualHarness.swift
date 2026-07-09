import AppKit
import Foundation
import Testing
@testable import zspeak

/// Harness VISUAL do preview no tray — gated por env, para inspeção manual.
///
/// O NSStatusBarButton real desenha o título com vibrancy, que sai
/// transparente em capturas offscreen. Para inspecionar tipografia, dot,
/// espaçamento e truncamento, o harness renderiza um NSButton comum
/// configurado pelo MESMO `TrayLivePreview.configure(button:)` do app, em
/// fitas dark e light na altura da barra de menu, com régua nas bordas.
/// Rodar com:
/// `TEST_RUNNER_ZSPEAK_RENDER_TRAY_HARNESS=1 TEST_RUNNER_ZSPEAK_TRAY_HARNESS_DIR=/caminho \
///  xcodebuild ... test -only-testing:zspeakTests/TrayLivePreviewVisualHarness`
@Suite("TrayLivePreviewVisualHarness", .serialized)
@MainActor
struct TrayLivePreviewVisualHarness {

    private static let longPreview = "hoje eu preciso ajustar o deploy do serviço de transcrição para o overlay ficar perfeito sem engasgar"
    private static let barHeight: CGFloat = 24

    @Test(
        "Renderiza cenários do tray para inspeção visual",
        .enabled(if: ProcessInfo.processInfo.environment["ZSPEAK_RENDER_TRAY_HARNESS"] == "1")
    )
    func renderTrayScenarios() async throws {
        _ = NSApplication.shared
        let outputPath = ProcessInfo.processInfo.environment["ZSPEAK_TRAY_HARNESS_DIR"]
            ?? NSTemporaryDirectory().appending("tray-harness")
        let outputDir = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let maxWidth = TrayLivePreview.defaultMaxWidth
        let scenarios: [(name: String, presentation: TrayPreviewPresentation)] = [
            ("1-idle", TrayLivePreview.presentation(
                state: .idle, previewText: "", enabled: true, maxWidth: maxWidth)),
            ("2-preparing", TrayLivePreview.presentation(
                state: .preparing, previewText: "", enabled: true, maxWidth: maxWidth)),
            ("3-recording-vazio", TrayLivePreview.presentation(
                state: .recording, previewText: "", enabled: true, maxWidth: maxWidth)),
            ("4-recording-curto", TrayLivePreview.presentation(
                state: .recording, previewText: "hoje eu preciso ajustar", enabled: true, maxWidth: maxWidth)),
            ("5-recording-longo", TrayLivePreview.presentation(
                state: .recording, previewText: Self.longPreview, enabled: true, maxWidth: maxWidth)),
            ("6-processing", TrayLivePreview.presentation(
                state: .processing, previewText: Self.longPreview, enabled: true, maxWidth: maxWidth)),
            // Selo compacto usado quando o mini-overlay mostra o texto embaixo.
            ("7-badge-recording", TrayLivePreview.compactBadge(state: .recording)),
            ("8-badge-processing", TrayLivePreview.compactBadge(state: .processing)),
        ]

        for scenario in scenarios {
            let image = try Self.renderStrips(for: scenario.presentation)
            let url = outputDir.appendingPathComponent("\(scenario.name).png")
            try Self.pngData(for: image).write(to: url, options: .atomic)
            print("[tray-harness] \(scenario.name): \(url.path) (length=\(Int(scenario.presentation.length)))")
        }
    }

    /// Renderiza a apresentação em duas fitas empilhadas (dark em cima,
    /// light embaixo) na altura da barra de menu, com régua vermelha nas
    /// bordas laterais do item.
    private static func renderStrips(for presentation: TrayPreviewPresentation) throws -> NSImage {
        let width = presentation.length
        let darkStrip = try renderStrip(for: presentation, appearance: .darkAqua, background: NSColor(calibratedWhite: 0.12, alpha: 1))
        let lightStrip = try renderStrip(for: presentation, appearance: .aqua, background: NSColor(calibratedWhite: 0.92, alpha: 1))

        let composed = NSImage(size: NSSize(width: width, height: barHeight * 2 + 2))
        composed.lockFocus()
        NSColor.systemRed.withAlphaComponent(0.6).setFill()
        NSRect(x: 0, y: 0, width: width, height: barHeight * 2 + 2).fill()
        darkStrip.draw(in: NSRect(x: 0, y: barHeight + 2, width: width, height: barHeight))
        lightStrip.draw(in: NSRect(x: 0, y: 0, width: width, height: barHeight))
        composed.unlockFocus()
        return composed
    }

    private static func renderStrip(
        for presentation: TrayPreviewPresentation,
        appearance: NSAppearance.Name,
        background: NSColor
    ) throws -> NSImage {
        let size = NSSize(width: presentation.length, height: barHeight)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.appearance = NSAppearance(named: appearance)
        container.wantsLayer = true
        container.layer?.backgroundColor = background.cgColor

        let button = NSButton(frame: container.bounds)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        TrayLivePreview.configure(button: button, with: presentation)
        container.addSubview(button)
        container.layoutSubtreeIfNeeded()

        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else {
            throw HarnessError.bitmapFailed
        }
        container.cacheDisplay(in: container.bounds, to: rep)

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static func pngData(for image: NSImage) throws -> Data {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            throw HarnessError.encodingFailed
        }
        return png
    }

    enum HarnessError: Error {
        case bitmapFailed
        case encodingFailed
    }
}

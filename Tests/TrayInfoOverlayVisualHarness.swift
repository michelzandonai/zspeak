import AppKit
import Foundation
import SwiftUI
import Testing
@testable import zspeak

/// Harness VISUAL do mini-overlay do modo tray — gated por env, para inspeção
/// manual de tipografia, quebra de linha, cauda e placeholder em dark/light.
/// Rodar com:
/// `TEST_RUNNER_ZSPEAK_RENDER_TRAY_HARNESS=1 TEST_RUNNER_ZSPEAK_TRAY_HARNESS_DIR=/caminho \
///  xcodebuild ... test -only-testing:zspeakTests/TrayInfoOverlayVisualHarness`
@Suite("TrayInfoOverlayVisualHarness", .serialized)
@MainActor
struct TrayInfoOverlayVisualHarness {

    private static let longPreview = "hoje eu preciso ajustar o deploy do serviço de transcrição para o overlay ficar perfeito sem engasgar, revisar o pipeline de captura, conferir o VAD e garantir que o texto ao vivo apareça completo no topo da tela"

    @Test(
        "Renderiza cenários do mini-overlay para inspeção visual",
        .enabled(if: ProcessInfo.processInfo.environment["ZSPEAK_RENDER_TRAY_HARNESS"] == "1")
    )
    func renderInfoOverlayScenarios() async throws {
        let outputPath = ProcessInfo.processInfo.environment["ZSPEAK_TRAY_HARNESS_DIR"]
            ?? NSTemporaryDirectory().appending("tray-harness")
        let outputDir = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let maxWidth = TrayLivePreview.defaultMaxWidth
        let overflow = (1...120).map { "palavra\($0)" }.joined(separator: " ")
        let scenarios: [(name: String, presentation: TrayPreviewPresentation)] = [
            ("info-1-ouvindo", TrayLivePreview.presentation(
                state: .recording, previewText: "", enabled: true, maxWidth: maxWidth)),
            ("info-2-curto", TrayLivePreview.presentation(
                state: .recording, previewText: "hoje eu preciso ajustar", enabled: true, maxWidth: maxWidth)),
            ("info-3-longo-quebra", TrayLivePreview.presentation(
                state: .recording, previewText: Self.longPreview, enabled: true, maxWidth: maxWidth)),
            ("info-4-estouro-cauda", TrayLivePreview.presentation(
                state: .recording, previewText: overflow, enabled: true, maxWidth: maxWidth)),
            ("info-5-processing", TrayLivePreview.presentation(
                state: .processing, previewText: Self.longPreview, enabled: true, maxWidth: maxWidth)),
        ]

        for scenario in scenarios {
            let image = try Self.renderStrips(for: scenario.presentation)
            let url = outputDir.appendingPathComponent("\(scenario.name).png")
            try Self.pngData(for: image).write(to: url, options: .atomic)
            print("[tray-harness] \(scenario.name): \(url.path)")
        }
    }

    /// Renderiza o mini-overlay na largura default sobre fundos dark e light
    /// empilhados (simulando o wallpaper atrás do material translúcido).
    private static func renderStrips(for presentation: TrayPreviewPresentation) throws -> NSImage {
        let dark = try renderStrip(for: presentation, scheme: .dark, background: Color(white: 0.15))
        let light = try renderStrip(for: presentation, scheme: .light, background: Color(white: 0.9))

        let width = max(dark.size.width, light.size.width)
        let height = dark.size.height + light.size.height + 2
        let composed = NSImage(size: NSSize(width: width, height: height))
        composed.lockFocus()
        NSColor.systemRed.withAlphaComponent(0.6).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        dark.draw(in: NSRect(x: 0, y: light.size.height + 2, width: dark.size.width, height: dark.size.height))
        light.draw(in: NSRect(x: 0, y: 0, width: light.size.width, height: light.size.height))
        composed.unlockFocus()
        return composed
    }

    private static func renderStrip(
        for presentation: TrayPreviewPresentation,
        scheme: ColorScheme,
        background: Color
    ) throws -> NSImage {
        // Render estático: pill visível, sem datilografia (ImageRenderer não
        // roda Tasks) e sem efeitos repetidos (pulso/variable color).
        let model = TrayInfoOverlayModel()
        model.presentation = presentation
        model.isShown = true
        model.typingEnabled = false
        model.reduceMotionOverride = true

        let content = TrayInfoOverlayView(model: model)
            .background(background)
            .environment(\.colorScheme, scheme)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        // Mesma proposta do painel real: pill abraça o conteúdo e quebra
        // linhas ao atingir o teto (o windowPadding já é o respiro da sombra).
        renderer.proposedSize = ProposedViewSize(
            width: TrayInfoOverlay.defaultWidth + TrayInfoOverlay.windowPadding * 2,
            height: nil)
        guard let image = renderer.nsImage else {
            throw HarnessError.renderFailed
        }
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
        case renderFailed
        case encodingFailed
    }
}

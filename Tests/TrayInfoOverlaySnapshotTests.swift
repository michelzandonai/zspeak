import SwiftUI
import Testing
@testable import zspeak

@MainActor
@Suite(
    "Tray Info Overlay Snapshot",
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "Materiais e fontes variam no runner CI; a baseline é validada localmente."
    )
)
struct TrayInfoOverlaySnapshotTests {

    @Test("Gravação preserva a faixa aprovada")
    func recordingDesign() throws {
        let model = TrayInfoOverlayModel()
        model.presentation = TrayLivePreview.presentation(
            state: .recording,
            previewText: "Vamos ajustar o deploy e revisar o banco.",
            enabled: true,
            maxWidth: TrayLivePreview.defaultMaxWidth
        )
        model.isShown = true
        model.typingEnabled = false
        model.reduceMotionOverride = true
        model.elapsedTimeOverride = 12
        model.waveformLevelsOverride = [
            0.12, 0.18, 0.24, 0.34, 0.28, 0.22, 0.30, 0.42, 0.58,
            0.72, 0.54, 0.38, 0.28, 0.36, 0.62, 0.84, 0.64, 0.42,
            0.30, 0.46, 0.76, 0.92, 0.68, 0.44, 0.32, 0.54, 0.78,
            0.58, 0.40, 0.30, 0.24, 0.18, 0.14, 0.10,
        ]

        let size = CGSize(
            width: TrayInfoOverlay.defaultWidth + TrayInfoOverlay.windowPadding * 2,
            height: ZSTrayTheme.minimumPanelHeight + TrayInfoOverlay.windowPadding * 2
        )
        let renderer = ImageRenderer(
            content: TrayInfoOverlayView(model: model)
                .background(Color(white: 0.12))
                .frame(width: size.width, height: size.height, alignment: .topLeading)
        )
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        let image = try #require(renderer.nsImage, "Falha ao renderizar o tray")

        try SnapshotTestHelpers.assertSnapshot(
            named: "tray-info-overlay-recording",
            image: image
        )
    }
}

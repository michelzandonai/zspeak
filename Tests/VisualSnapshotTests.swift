import AppKit
import SwiftUI
import Testing
@testable import zspeak

@MainActor
@Suite(
    "Visual Snapshots",
    .disabled(
        if: ProcessInfo.processInfo.environment["CI"] != nil,
        "Rendering SwiftUI difere entre runner CI e Xcode local (fonts, materials); baselines são locais."
    )
)
struct VisualSnapshotTests {

    @Test("Overlay recording permanece estável")
    func testOverlayRecordingSnapshot() throws {
        let model = OverlayModel()
        model.state = .recording
        model.focusedAppName = "Cursor"
        model.microphoneName = "MacBook Pro Microphone"
        model.getAudioLevel = { 0.42 }

        try SnapshotTestHelpers.assertSnapshot(
            named: "overlay-recording",
            of: OverlayView(model: model),
            size: CGSize(width: 320, height: 88)
        )
    }

    @Test("Overlay prompt com resultado expandido permanece estável")
    func testOverlayPromptSnapshot() throws {
        let model = OverlayModel()
        model.state = .idle
        model.promptModeEnabled = true
        model.focusedAppName = "VS Code"
        model.prompts = [
            CorrectionPrompt(name: "Correção geral", systemPrompt: "", isActive: true),
            CorrectionPrompt(name: "Formalizar", systemPrompt: "", isActive: false),
        ]
        model.selectedPromptID = model.prompts.first?.id
        model.lastTranscription = "preciso ajustar o pipeline de deploy no kubernetes e revisar o banco"
        model.lastLLMResult = "Preciso ajustar o pipeline de deploy no Kubernetes e revisar o banco."
        model.lastLLMPromptName = "Correção geral"
        model.isResultExpanded = true

        try SnapshotTestHelpers.assertSnapshot(
            named: "overlay-prompt",
            of: OverlayView(model: model),
            size: CGSize(width: 440, height: 260)
        )
    }

    @Test("Audio file processing permanece estável")
    func testAudioFileProcessingSnapshot() throws {
        let appState = AppState(skipBundlePermissionCheck: true)
        let store = TranscriptionStore(baseDirectory: makeTemporaryDirectory())

        let view = AudioFileView(
            appState: appState,
            store: store,
            initialState: .processing,
            initialMode: .plain,
            initialPhase: .transcribing(current: 2, total: 5),
            initialFileName: "daily-standup.m4a"
        )

        try SnapshotTestHelpers.assertSnapshot(
            named: "audio-file-processing",
            of: view,
            size: CGSize(width: 720, height: 520)
        )
    }

    @Test("Audio file result meeting permanece estável")
    func testAudioFileResultMeetingSnapshot() throws {
        let appState = AppState(skipBundlePermissionCheck: true)
        appState.lastTranscription = "texto qualquer"

        let tempDir = makeTemporaryDirectory()
        let store = TranscriptionStore(baseDirectory: tempDir)

        let result = FileTranscriptionResult(
            text: """
            00:00 Ana: vamos revisar o deploy

            00:05 Bruno: eu ajusto o banco
            """,
            segments: [
                TranscribedSegment(
                    speakerId: "Speaker 0",
                    startTimeSeconds: 0,
                    endTimeSeconds: 4.8,
                    text: "vamos revisar o deploy"
                ),
                TranscribedSegment(
                    speakerId: "Speaker 1",
                    startTimeSeconds: 5,
                    endTimeSeconds: 9.2,
                    text: "eu ajusto o banco"
                ),
            ],
            sourceFileName: "reuniao-opus.opus",
            durationSeconds: 9.2,
            samples: Array(repeating: 0.05, count: 16000 * 9)
        )

        let view = AudioFileView(
            appState: appState,
            store: store,
            initialState: .result(result),
            initialMode: .plain,
            initialSpeakerNames: [
                "Speaker 0": "Ana",
                "Speaker 1": "Bruno",
            ]
        )

        try SnapshotTestHelpers.assertSnapshot(
            named: "audio-file-meeting-result",
            of: view,
            size: CGSize(width: 720, height: 700)
        )
    }

    // MARK: - Overlay states

    @Test("Overlay preparing permanece estável")
    func testOverlayPreparingSnapshot() throws {
        let model = OverlayModel()
        model.state = .preparing
        model.focusedAppName = "Cursor"

        try SnapshotTestHelpers.assertSnapshot(
            named: "overlay-preparing",
            of: OverlayView(model: model),
            size: CGSize(width: 320, height: 88)
        )
    }

    @Test("Overlay transcribing permanece estável")
    func testOverlayTranscribingSnapshot() throws {
        let model = OverlayModel()
        model.state = .processing
        model.focusedAppName = "Cursor"

        try SnapshotTestHelpers.assertSnapshot(
            named: "overlay-transcribing",
            of: OverlayView(model: model),
            size: CGSize(width: 320, height: 88)
        )
    }

    @Test("Overlay idle vazio permanece estável")
    func testOverlayIdleEmptySnapshot() throws {
        let model = OverlayModel()
        model.state = .idle
        model.focusedAppName = "Cursor"
        model.promptModeEnabled = false
        model.lastTranscription = ""

        try SnapshotTestHelpers.assertSnapshot(
            named: "overlay-idle-empty",
            of: OverlayView(model: model),
            size: CGSize(width: 320, height: 88)
        )
    }

    @Test("Overlay prompt mode sem prompts permanece estável")
    func testOverlayPromptModeNoPromptsSnapshot() throws {
        // Cenário do bug UX da issue #13: modo prompt ativo mas sem prompts
        // cadastrados — o seletor deve mostrar "Selecionar prompt" e o botão
        // Aplicar fica desabilitado.
        let model = OverlayModel()
        model.state = .idle
        model.promptModeEnabled = true
        model.focusedAppName = "VS Code"
        model.prompts = []
        model.selectedPromptID = nil
        model.lastTranscription = ""
        model.lastLLMResult = nil

        try SnapshotTestHelpers.assertSnapshot(
            named: "overlay-prompt-mode-no-prompts",
            of: OverlayView(model: model),
            size: CGSize(width: 440, height: 200)
        )
    }

    // MARK: - MenuBar
    //
    // Snapshots de `MenuBarView` ficam pra Onda 2: hoje ele depende de
    // `microphoneManager.permissionState` (global, lido via AVCaptureDevice) e
    // `accessibilityManager.isGranted` (global, AXIsProcessTrusted). Ambos
    // variam com o ambiente de execução e tornam o snapshot não-determinístico.
    // Depois da refatoração do AppState (issue #24) os managers terão injeção
    // de dependência com estado mockável e esses testes voltam.

    // MARK: - Helpers

    private func makeTemporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

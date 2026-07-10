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
        model.focusedAppName = "Claude Code"
        model.microphoneName = "MacBook Pro Microphone"
        model.liveTranscriptionPreview = "Vamos transformar esta reunião em um resumo com decisões, riscos e próximos passos."
        model.getAudioLevel = { 0.42 }
        model.waveformAnimationPhaseOverride = 12.42
        model.waveformLevelOverride = 0.70

        try SnapshotTestHelpers.assertSnapshot(
            named: "overlay-recording",
            of: OverlayView(model: model),
            size: CGSize(width: 410, height: 233)
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
        // Congela a rolagem/respiração da waveform — sem o override, o offset
        // contínuo varia entre runs e o snapshot fica não-determinístico.
        model.waveformAnimationPhaseOverride = 0.42

        try SnapshotTestHelpers.assertSnapshot(
            named: "overlay-preparing",
            of: OverlayView(model: model),
            size: CGSize(width: 410, height: 104)
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
            size: CGSize(width: 410, height: 157)
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

    // MARK: - Settings

    @Test("Sidebar principal permanece estável")
    func testSettingsSidebarSnapshot() throws {
        try SnapshotTestHelpers.assertSnapshot(
            named: "settings-sidebar-overview",
            of: SettingsSidebar(selection: .constant(.overview)),
            size: CGSize(width: 240, height: 720)
        )
    }

    @Test("Settings overview permanece estável")
    func testSettingsOverviewSnapshot() throws {
        let context = makeSettingsContext()
        context.historyStore.addRecord(
            text: "Preciso revisar o pipeline de deploy no Kubernetes e abrir um pull request.",
            modelName: "Parakeet TDT 0.6B V3",
            duration: 4.2,
            targetAppName: "Cursor",
            samples: nil
        )

        try SnapshotTestHelpers.assertSnapshot(
            named: "settings-overview",
            of: settingsEnvironment(OverviewPage(), context: context),
            size: CGSize(width: 980, height: 720)
        )
    }

    @Test("Settings history permanece estável")
    func testSettingsHistorySnapshot() throws {
        let context = makeSettingsContext()
        context.historyStore.addRecord(
            text: "Vamos ajustar o fluxo de permissões e validar a nova tela em dark mode.",
            modelName: "Parakeet TDT 0.6B V3",
            duration: 5.1,
            targetAppName: "Xcode",
            samples: nil
        )
        context.historyStore.addRecord(
            text: "Correção geral aplicada ao texto transcrito com termos técnicos em inglês.",
            modelName: "LLM local",
            duration: 0.8,
            targetAppName: "Cursor",
            samples: nil
        )

        try SnapshotTestHelpers.assertSnapshot(
            named: "settings-history",
            of: HistoryView(store: context.historyStore),
            size: CGSize(width: 980, height: 720)
        )
    }

    @Test("Settings benchmark permanece estável")
    func testSettingsBenchmarkSnapshot() throws {
        let context = makeSettingsContext()
        context.benchmarkStore.fixtures = [
            BenchmarkFixture(
                id: UUID(),
                name: "Frase técnica PT-BR",
                expectedText: "Ajustar o pipeline de deploy no Kubernetes",
                audioFileName: "fixture-pt.wav",
                duration: 4.8,
                lastResult: BenchmarkResult(
                    transcribedText: "Ajustar o pipeline de deploy no Kubernetes",
                    latency: 0.84,
                    timestamp: Date(),
                    similarity: 0.96,
                    wordErrorRate: 0.04,
                    characterErrorRate: 0.02
                )
            ),
            BenchmarkFixture(
                id: UUID(),
                name: "Code-switching",
                expectedText: "Abrir pull request e revisar cache Redis",
                audioFileName: "fixture-code.wav",
                duration: 3.6,
                lastResult: BenchmarkResult(
                    transcribedText: "Abrir pull request e revisar cache Redis",
                    latency: 0.66,
                    timestamp: Date(),
                    similarity: 0.92,
                    wordErrorRate: 0.08,
                    characterErrorRate: 0.03
                )
            ),
        ]

        try SnapshotTestHelpers.assertSnapshot(
            named: "settings-benchmark",
            of: BenchmarkView(
                appState: context.appState,
                store: context.benchmarkStore,
                historyStore: context.historyStore,
                initialIsLoadingFixtures: false
            ),
            size: CGSize(width: 980, height: 820)
        )
    }

    @Test("Settings vocabulary permanece estável")
    func testSettingsVocabularySnapshot() throws {
        let context = makeSettingsContext()
        context.vocabularyStore.addEntry(term: "GitHub Actions", aliases: ["guithub actions", "git actions"], weight: 14)
        context.vocabularyStore.addEntry(term: "CoreML", aliases: ["core ml"], weight: 12)

        try SnapshotTestHelpers.assertSnapshot(
            named: "settings-vocabulary",
            of: VocabularyView(appState: context.appState, store: context.vocabularyStore),
            size: CGSize(width: 980, height: 760)
        )
    }

    @Test("Settings vocabulary edição de termo permanece estável")
    func testSettingsVocabularyEditingSnapshot() throws {
        let context = makeSettingsContext()
        while let entry = context.vocabularyStore.entries.first {
            context.vocabularyStore.deleteEntry(entry)
        }

        context.vocabularyStore.addEntry(
            term: "branch stage",
            aliases: ["brent stage", "brand stage", "brain stage"],
            weight: 15
        )

        let entryID = try #require(context.vocabularyStore.entries.first?.id)

        try SnapshotTestHelpers.assertSnapshot(
            named: "settings-vocabulary-editing",
            of: VocabularyView(
                appState: context.appState,
                store: context.vocabularyStore,
                initialExpandedIDs: [entryID]
            ),
            size: CGSize(width: 980, height: 760)
        )
    }

    @Test("Modal de novo termo do vocabulário permanece estável")
    func testVocabularyNewTermSheetSnapshot() throws {
        try SnapshotTestHelpers.assertSnapshot(
            named: "settings-vocabulary-new-term",
            of: NewVocabularyTermSheet { _, _, _, _ in },
            size: CGSize(width: 440, height: 440)
        )
    }

    @Test("Settings correction permanece estável")
    func testSettingsCorrectionSnapshot() throws {
        let context = makeSettingsContext()

        try SnapshotTestHelpers.assertSnapshot(
            named: "settings-correction",
            of: CorrectionPromptsView(appState: context.appState, store: context.correctionPromptStore),
            size: CGSize(width: 980, height: 900)
        )
    }

    @Test("Settings keyboard permanece estável")
    func testSettingsKeyboardSnapshot() throws {
        let context = makeSettingsContext()

        try SnapshotTestHelpers.assertSnapshot(
            named: "settings-keyboard",
            of: settingsEnvironment(KeyboardPage(), context: context),
            size: CGSize(width: 980, height: 720)
        )
    }

    @Test("Settings microphone permanece estável")
    func testSettingsMicrophoneSnapshot() throws {
        let context = makeSettingsContext()

        try SnapshotTestHelpers.assertSnapshot(
            named: "settings-microphone",
            of: settingsEnvironment(MicrophonePage(), context: context),
            size: CGSize(width: 980, height: 720)
        )
    }

    @Test("Settings general permanece estável")
    func testSettingsGeneralSnapshot() throws {
        try SnapshotTestHelpers.assertSnapshot(
            named: "settings-general",
            of: GeneralPage(),
            size: CGSize(width: 980, height: 720)
        )
    }

    @Test("Settings permissions permanece estável")
    func testSettingsPermissionsSnapshot() throws {
        let context = makeSettingsContext()

        try SnapshotTestHelpers.assertSnapshot(
            named: "settings-permissions",
            of: settingsEnvironment(PermissionsPage(refreshOnAppear: false), context: context),
            size: CGSize(width: 980, height: 760)
        )
    }

    @Test("Settings about permanece estável")
    func testSettingsAboutSnapshot() throws {
        try SnapshotTestHelpers.assertSnapshot(
            named: "settings-about",
            of: AboutPage(),
            size: CGSize(width: 980, height: 720)
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

    private struct SettingsSnapshotContext {
        let appState: AppState
        let historyStore: TranscriptionStore
        let benchmarkStore: BenchmarkStore
        let vocabularyStore: VocabularyStore
        let correctionPromptStore: CorrectionPromptStore
        let activationKeyManager: ActivationKeyManager
        let accessibilityManager: AccessibilityManager
        let promptModeManager: PromptModeManager
    }

    private func makeSettingsContext() -> SettingsSnapshotContext {
        let appState = AppState(skipBundlePermissionCheck: true)
        let historyStore = TranscriptionStore(baseDirectory: makeTemporaryDirectory())
        let benchmarkStore = BenchmarkStore(baseDirectory: makeTemporaryDirectory())
        let vocabularyStore = VocabularyStore(baseDirectory: makeTemporaryDirectory())
        let correctionPromptStore = CorrectionPromptStore(baseDirectory: makeTemporaryDirectory())
        let promptModeManager = PromptModeManager()
        let activationKeyManager = ActivationKeyManager()
        let accessibilityManager = AccessibilityManager(initialIsGranted: true, startPolling: false)

        appState.microphoneManager.permissionState = .authorized
        appState.microphoneManager.useSystemDefault = false
        appState.microphoneManager.microphones = []
        appState.accessibilityGranted = true

        activationKeyManager.selectedKey = .rightCommand
        activationKeyManager.activationMode = .toggle
        activationKeyManager.escapeToCancel = true
        activationKeyManager.customShortcutDescription = ""

        appState.store = historyStore
        appState.benchmarkStore = benchmarkStore
        appState.vocabularyStore = vocabularyStore
        appState.correctionPromptStore = correctionPromptStore
        appState.promptModeManager = promptModeManager

        return SettingsSnapshotContext(
            appState: appState,
            historyStore: historyStore,
            benchmarkStore: benchmarkStore,
            vocabularyStore: vocabularyStore,
            correctionPromptStore: correctionPromptStore,
            activationKeyManager: activationKeyManager,
            accessibilityManager: accessibilityManager,
            promptModeManager: promptModeManager
        )
    }

    private func settingsEnvironment<V: View>(_ view: V, context: SettingsSnapshotContext) -> some View {
        view
            .environment(context.appState)
            .environment(context.appState.microphoneManager)
            .environment(context.activationKeyManager)
            .environment(context.accessibilityManager)
            .environment(context.historyStore)
            .environment(context.benchmarkStore)
            .environment(context.vocabularyStore)
            .environment(context.correctionPromptStore)
            .environment(context.promptModeManager)
    }
}

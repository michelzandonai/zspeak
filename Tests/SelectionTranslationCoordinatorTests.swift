import AppKit
import Foundation
import Testing
@testable import zspeak

@MainActor
@Suite(
    "SelectionTranslationCoordinator",
    .serialized
)
struct SelectionTranslationCoordinatorTests {
    @Test("traduz selecao e atualiza estado do overlay")
    func translatesSelectionAndUpdatesOverlayState() async throws {
        let anchor = NSRect(x: 120, y: 240, width: 80, height: 18)
        let reader = FakeSelectionReader(
            selection: SelectedTextSelection(
                text: "Hello, world.",
                bounds: anchor
            )
        )
        let llm = FakeTranslationLLM(result: "Olá, mundo.")
        let coordinator = SelectionTranslationCoordinator(
            llmManager: llm,
            selectionReader: reader,
            ambientLookupEnabled: false
        )

        coordinator.translateSelection()

        #expect(coordinator.isVisible)
        #expect(coordinator.isTranslating)

        try await waitUntilOnMain(timeout: .seconds(5)) {
            coordinator.isTranslating == false
                && coordinator.translatedText == "Olá, mundo."
        }

        #expect(coordinator.sourceText == "Hello, world.")
        #expect(coordinator.translatedText == "Olá, mundo.")
        #expect(coordinator.anchorRect?.origin.x == anchor.origin.x)
        #expect(coordinator.anchorRect?.origin.y == anchor.origin.y)
        #expect(coordinator.errorMessage == nil)
        #expect(await llm.receivedText() == "Hello, world.")
        #expect(await llm.receivedTargetLanguage() == "português brasileiro")
        #expect(await llm.keepAliveSequence() == [true])

        coordinator.dismiss()
        try await waitUntil(timeout: .seconds(1)) {
            await llm.keepAliveSequence() == [true, false]
        }
    }

    @Test("traduz palavra do texto original com cache")
    func looksUpWordTranslationWithCache() async throws {
        let reader = FakeSelectionReader(
            selection: SelectedTextSelection(
                text: "This feature is fast.",
                bounds: nil
            )
        )
        let llm = FakeTranslationLLM(
            result: "Esse recurso é rápido.",
            termResults: ["feature": "recurso"]
        )
        let coordinator = SelectionTranslationCoordinator(
            llmManager: llm,
            selectionReader: reader,
            ambientLookupEnabled: false
        )

        coordinator.translateSelection()
        try await waitUntilOnMain(timeout: .seconds(2)) {
            coordinator.isTranslating == false
        }

        coordinator.lookupWord("feature.", immediate: true)
        try await waitUntilOnMain(timeout: .seconds(2)) {
            coordinator.isLookingUpTerm == false && coordinator.lookupTranslation == "recurso"
        }

        #expect(coordinator.selectedLookupTerm == "feature")
        #expect(coordinator.lookupTranslation == "recurso")
        #expect(await llm.receivedTerms() == ["feature"])
        #expect(await llm.receivedTermContexts() == ["This feature is fast."])

        coordinator.lookupWord("feature", immediate: true)
        #expect(coordinator.lookupTranslation == "recurso")
        #expect(await llm.receivedTerms() == ["feature"])
    }

    @Test("selecao curta usa bolha compacta de dicionario")
    func shortSelectionUsesCompactLookupBubble() async throws {
        let anchor = NSRect(x: 40, y: 80, width: 32, height: 16)
        let reader = FakeSelectionReader(
            selection: SelectedTextSelection(
                text: "feature",
                bounds: anchor
            )
        )
        let llm = FakeTranslationLLM(
            result: "recurso",
            termResults: ["feature": "recurso"]
        )
        let coordinator = SelectionTranslationCoordinator(
            llmManager: llm,
            selectionReader: reader,
            ambientLookupEnabled: false
        )

        coordinator.translateSelection()

        try await waitUntilOnMain(timeout: .seconds(2)) {
            coordinator.isLookingUpTerm == false && coordinator.lookupTranslation == "recurso"
        }

        #expect(coordinator.isVisible)
        #expect(coordinator.presentation == .compactLookup)
        #expect(coordinator.selectedLookupTerm == "feature")
        #expect(coordinator.lookupTranslation == "recurso")
        #expect(coordinator.translatedText == nil)
        #expect(coordinator.anchorRect?.origin.x == anchor.origin.x)
        #expect(await llm.receivedText() == nil)
        #expect(await llm.receivedTerms() == ["feature"])
    }

    @Test("modo traducao observa selecao curta automaticamente")
    func ambientLookupPollsCurrentSelection() async throws {
        let anchor = NSRect(x: 72, y: 120, width: 44, height: 18)
        let reader = FakeSelectionReader(
            selection: SelectedTextSelection(
                text: "clean",
                bounds: anchor
            )
        )
        let llm = FakeTranslationLLM(
            result: "limpo",
            termResults: ["clean": "limpo"]
        )
        let coordinator = SelectionTranslationCoordinator(
            llmManager: llm,
            selectionReader: reader,
            ambientLookupEnabled: true
        )

        try await waitUntilOnMain(timeout: .seconds(2)) {
            coordinator.presentation == .compactLookup
                && coordinator.lookupTranslation == "limpo"
        }

        #expect(coordinator.isVisible)
        #expect(coordinator.sourceText == "clean")
        #expect(coordinator.anchorRect?.origin.x == anchor.origin.x)
        #expect(await llm.receivedTerms() == ["clean"])

        coordinator.setAmbientLookupEnabled(false)
    }
}

@MainActor
private struct FakeSelectionReader: SelectedTextReading {
    let selection: SelectedTextSelection

    func readSelectedText(
        preferSavedFocusedApp: Bool,
        allowClipboardFallback: Bool
    ) async throws -> SelectedTextSelection {
        selection
    }
}

private actor FakeTranslationLLM: LLMCorrecting {
    var modelState: LLMCorrectionManager.ModelState = .ready
    var selectedModel: LLMModelOption = .defaultModel

    private let result: String
    private let termResults: [String: String]
    private var text: String?
    private var targetLanguage: String?
    private var terms: [String] = []
    private var termContexts: [String] = []
    private var keepAliveValues: [Bool] = []

    init(result: String, termResults: [String: String] = [:]) {
        self.result = result
        self.termResults = termResults
    }

    func setKeepAlive(_ alive: Bool) {
        keepAliveValues.append(alive)
    }

    func selectModel(id: String) -> LLMCorrectionManager.ModelState {
        modelState
    }

    func downloadModel() async throws {}

    func downloadProgressSnapshot() -> LLMDownloadProgressSnapshot? {
        nil
    }

    func cancelDownloadAndCleanup() throws {}

    func loadModel() async throws {}

    func deleteModel() throws {}

    func deleteModel(id: String) throws {}

    func modelSizeOnDisk() -> Int64? {
        nil
    }

    func cachedModelsOnDisk() -> [LLMCorrectionManager.CachedModelInfo] {
        []
    }

    func correct(
        text: String,
        systemPrompt: String,
        maxTokens: Int,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        text
    }

    func translate(
        text: String,
        targetLanguage: String,
        maxTokens: Int,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        self.text = text
        self.targetLanguage = targetLanguage
        onPartial?("Olá")
        return result
    }

    func translateTerm(
        term: String,
        context: String?,
        targetLanguage: String,
        maxTokens: Int,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        terms.append(term)
        termContexts.append(context ?? "")
        let translated = termResults[term] ?? term
        onPartial?(translated)
        return translated
    }

    func receivedText() -> String? {
        text
    }

    func receivedTargetLanguage() -> String? {
        targetLanguage
    }

    func receivedTerms() -> [String] {
        terms
    }

    func receivedTermContexts() -> [String] {
        termContexts
    }

    func keepAliveSequence() -> [Bool] {
        keepAliveValues
    }
}

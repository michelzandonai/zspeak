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

        try await waitUntilOnMain(timeout: .seconds(15)) {
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
        try await waitUntil(timeout: .seconds(15)) {
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
        try await waitUntilOnMain(timeout: .seconds(15)) {
            coordinator.isTranslating == false
        }

        coordinator.lookupWord("feature.", immediate: true)
        try await waitUntilOnMain(timeout: .seconds(15)) {
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

        try await waitUntilOnMain(timeout: .seconds(15)) {
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

        try await waitUntilOnMain(timeout: .seconds(15)) {
            coordinator.presentation == .compactLookup
                && coordinator.lookupTranslation == "limpo"
        }

        #expect(coordinator.isVisible)
        #expect(coordinator.sourceText == "clean")
        #expect(coordinator.anchorRect?.origin.x == anchor.origin.x)
        #expect(await llm.receivedTerms() == ["clean"])

        coordinator.setAmbientLookupEnabled(false)
    }

    // MARK: - Regressão: parciais atrasadas (hop Task { @MainActor } não herda cancelamento)

    @Test("parcial atrasada nao sobrescreve a traducao final")
    func latePartialDoesNotOverwriteFinalTranslation() async throws {
        let reader = FakeSelectionReader(
            selection: SelectedTextSelection(
                text: "Hello there, my good friend.",
                bounds: nil
            )
        )
        let llm = FakeTranslationLLM(
            result: "Olá, meu bom amigo.",
            latePartial: "Olá"
        )
        let coordinator = SelectionTranslationCoordinator(
            llmManager: llm,
            selectionReader: reader,
            ambientLookupEnabled: false
        )

        coordinator.translateSelection()
        try await waitUntilOnMain(timeout: .seconds(15)) {
            coordinator.isTranslating == false
                && coordinator.translatedText == "Olá, meu bom amigo."
        }

        // Dá tempo da parcial atrasada aterrissar no MainActor. Antes do fix
        // (guard por runID), ela sobrescrevia a tradução completa com o prefixo.
        try await Task.sleep(for: .milliseconds(250))
        #expect(coordinator.translatedText == "Olá, meu bom amigo.")
    }

    @Test("parcial atrasada apos dismiss nao ressuscita estado do overlay")
    func latePartialAfterDismissIsDiscarded() async throws {
        let reader = FakeSelectionReader(
            selection: SelectedTextSelection(
                text: "Hello there, my good friend.",
                bounds: nil
            )
        )
        let llm = FakeTranslationLLM(
            result: "Olá, meu bom amigo.",
            latePartial: "Olá"
        )
        let coordinator = SelectionTranslationCoordinator(
            llmManager: llm,
            selectionReader: reader,
            ambientLookupEnabled: false
        )

        coordinator.translateSelection()
        try await waitUntilOnMain(timeout: .seconds(15)) {
            coordinator.isTranslating == false
        }

        coordinator.dismiss()

        try await Task.sleep(for: .milliseconds(250))
        #expect(coordinator.translatedText == nil)
        #expect(!coordinator.isVisible)
    }

    @Test("parcial atrasada de lookup nao sobrescreve o resultado final")
    func lateLookupPartialDoesNotOverwriteFinal() async throws {
        let reader = FakeSelectionReader(
            selection: SelectedTextSelection(
                text: "This feature is fast.",
                bounds: nil
            )
        )
        let llm = FakeTranslationLLM(
            result: "Esse recurso é rápido.",
            termResults: ["feature": "recurso"],
            lateTermPartial: "rec"
        )
        let coordinator = SelectionTranslationCoordinator(
            llmManager: llm,
            selectionReader: reader,
            ambientLookupEnabled: false
        )

        coordinator.translateSelection()
        try await waitUntilOnMain(timeout: .seconds(15)) {
            coordinator.isTranslating == false
        }

        coordinator.lookupWord("feature", immediate: true)
        try await waitUntilOnMain(timeout: .seconds(15)) {
            coordinator.isLookingUpTerm == false && coordinator.lookupTranslation == "recurso"
        }

        try await Task.sleep(for: .milliseconds(250))
        #expect(coordinator.lookupTranslation == "recurso")
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
    /// Quando setados, disparam um onPartial ~80ms DEPOIS do resultado final —
    /// simula o hop atrasado no MainActor que causava a race de sobrescrita.
    private let latePartial: String?
    private let lateTermPartial: String?
    private var text: String?
    private var targetLanguage: String?
    private var terms: [String] = []
    private var termContexts: [String] = []
    private var keepAliveValues: [Bool] = []

    init(
        result: String,
        termResults: [String: String] = [:],
        latePartial: String? = nil,
        lateTermPartial: String? = nil
    ) {
        self.result = result
        self.termResults = termResults
        self.latePartial = latePartial
        self.lateTermPartial = lateTermPartial
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
        if let latePartial {
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                onPartial?(latePartial)
            }
        }
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
        if let lateTermPartial {
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                onPartial?(lateTermPartial)
            }
        }
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

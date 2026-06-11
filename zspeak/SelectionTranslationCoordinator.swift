import AppKit
import Foundation
import os.log

private let selectionTranslationLogger = Logger(subsystem: "com.zspeak", category: "SelectionTranslation")

enum SelectionTranslationPresentation: Sendable, Equatable {
    case fullTranslation
    case compactLookup
}

@MainActor
@Observable
final class SelectionTranslationCoordinator {
    private static let ambientLookupEnabledDefaultsKey = "selectionAmbientLookupEnabled"

    var isVisible: Bool = false
    var isTranslating: Bool = false
    var sourceText: String = ""
    var translatedText: String?
    var anchorRect: NSRect?
    var presentation: SelectionTranslationPresentation = .fullTranslation
    var errorMessage: String? {
        didSet { onErrorMessageChange?(errorMessage) }
    }
    var selectedLookupTerm: String?
    var lookupTranslation: String?
    var isLookingUpTerm: Bool = false
    var lookupErrorMessage: String?
    var isAmbientLookupEnabled: Bool {
        didSet {
            guard oldValue != isAmbientLookupEnabled else { return }
            UserDefaults.standard.set(isAmbientLookupEnabled, forKey: Self.ambientLookupEnabledDefaultsKey)
            handleAmbientLookupModeChange()
        }
    }

    var onErrorMessageChange: (@MainActor (String?) -> Void)?

    private let llmManager: any LLMCorrecting
    private let selectionReader: any SelectedTextReading
    private var translationTask: Task<Void, Never>?
    private var lookupTask: Task<Void, Never>?
    private var ambientLookupTask: Task<Void, Never>?
    private var ambientPollingTask: Task<Void, Never>?
    private var ambientDismissTask: Task<Void, Never>?
    private var ambientEventTap: CFMachPort?
    private var ambientRunLoopSource: CFRunLoopSource?
    private var lookupCache: [String: String] = [:]
    private var activeLookupCacheKey: String?
    private var lastAmbientSelectionKey: String?

    init(
        llmManager: any LLMCorrecting,
        selectionReader: any SelectedTextReading,
        ambientLookupEnabled: Bool? = nil
    ) {
        self.llmManager = llmManager
        self.selectionReader = selectionReader
        self.isAmbientLookupEnabled = ambientLookupEnabled
            ?? UserDefaults.standard.bool(forKey: Self.ambientLookupEnabledDefaultsKey)

        if isAmbientLookupEnabled {
            createAmbientLookupEventTap()
            startAmbientSelectionPolling()
            Task {
                await llmManager.setKeepAlive(true)
            }
        }
    }

    func translateSelection(targetLanguage: String = "português brasileiro") {
        translationTask?.cancel()
        TextInserter.saveFocusedApp()

        isVisible = true
        isTranslating = true
        presentation = .fullTranslation
        sourceText = ""
        translatedText = nil
        anchorRect = NSRect(origin: NSEvent.mouseLocation, size: .zero)
        errorMessage = nil
        resetLookupState(clearCache: true)

        translationTask = Task {
            await llmManager.setKeepAlive(true)

            do {
                let selection = try await selectionReader.readSelectedText()
                guard !Task.isCancelled else { return }

                sourceText = selection.text
                anchorRect = selection.bounds ?? anchorRect

                if let term = Self.compactLookupTerm(from: selection.text) {
                    startCompactLookup(
                        term: term,
                        selectedText: selection.text,
                        anchor: selection.bounds,
                        targetLanguage: targetLanguage,
                        immediate: true
                    )
                    isTranslating = false
                    translationTask = nil
                    return
                }

                let translated = try await llmManager.translate(
                    text: selection.text,
                    targetLanguage: targetLanguage,
                    maxTokens: maxTokens(for: selection.text),
                    onPartial: { [weak self] partial in
                        Task { @MainActor in
                            guard let self, !Task.isCancelled else { return }
                            self.translatedText = partial
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    translatedText = nil
                    errorMessage = "Tradução vazia."
                } else {
                    translatedText = trimmed
                    selectionTranslationLogger.info("Seleção traduzida: \(selection.text.count) -> \(trimmed.count) chars")
                }
            } catch is CancellationError {
                selectionTranslationLogger.debug("Tradução de seleção cancelada")
            } catch {
                guard !Task.isCancelled else { return }
                translatedText = nil
                errorMessage = error.localizedDescription
                selectionTranslationLogger.error("Tradução de seleção falhou: \(error.localizedDescription)")
            }

            if !Task.isCancelled {
                isTranslating = false
            }
            translationTask = nil
        }
    }

    func setAmbientLookupEnabled(_ enabled: Bool) {
        isAmbientLookupEnabled = enabled
    }

    func toggleAmbientLookupEnabled() {
        isAmbientLookupEnabled.toggle()
    }

    func refreshAmbientLookupEventTap() {
        guard isAmbientLookupEnabled else { return }
        createAmbientLookupEventTap()
        startAmbientSelectionPolling()
    }

    func lookupWord(
        _ rawWord: String,
        targetLanguage: String = "português brasileiro",
        immediate: Bool = false
    ) {
        let term = Self.lookupTerm(from: rawWord)
        guard !term.isEmpty,
              term.rangeOfCharacter(from: .letters) != nil
        else { return }

        startTermLookup(
            term: term,
            context: sourceText,
            targetLanguage: targetLanguage,
            immediate: immediate
        )
    }

    private func startCompactLookup(
        term: String,
        selectedText: String,
        anchor: NSRect?,
        targetLanguage: String,
        immediate: Bool
    ) {
        ambientDismissTask?.cancel()
        ambientDismissTask = nil
        translationTask?.cancel()
        presentation = .compactLookup
        isVisible = true
        isTranslating = false
        sourceText = selectedText
        translatedText = nil
        anchorRect = anchor ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)
        errorMessage = nil

        startTermLookup(
            term: term,
            context: selectedText,
            targetLanguage: targetLanguage,
            immediate: immediate
        )
    }

    private func startTermLookup(
        term: String,
        context: String?,
        targetLanguage: String,
        immediate: Bool
    ) {
        let cacheKey = Self.lookupCacheKey(for: term)
        if activeLookupCacheKey == cacheKey,
           (isLookingUpTerm || lookupTranslation != nil || lookupErrorMessage != nil) {
            return
        }

        lookupTask?.cancel()
        selectedLookupTerm = term
        activeLookupCacheKey = cacheKey
        lookupErrorMessage = nil

        if let cached = lookupCache[cacheKey] {
            lookupTranslation = cached
            isLookingUpTerm = false
            return
        }

        lookupTranslation = nil
        isLookingUpTerm = true

        lookupTask = Task { [weak self] in
            guard let self else { return }

            do {
                if !immediate {
                    try await Task.sleep(for: .milliseconds(240))
                }

                let translated = try await llmManager.translateTerm(
                    term: term,
                    context: context,
                    targetLanguage: targetLanguage,
                    maxTokens: 64,
                    onPartial: { [weak self] partial in
                        Task { @MainActor in
                            guard let self,
                                  self.activeLookupCacheKey == cacheKey,
                                  !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            else { return }
                            self.lookupTranslation = partial
                        }
                    }
                )

                guard !Task.isCancelled, activeLookupCacheKey == cacheKey else { return }

                let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    lookupTranslation = nil
                    lookupErrorMessage = "Sem tradução."
                } else {
                    lookupCache[cacheKey] = trimmed
                    lookupTranslation = trimmed
                    lookupErrorMessage = nil
                    selectionTranslationLogger.debug("Termo traduzido no overlay: \(term, privacy: .public)")
                }
            } catch is CancellationError {
                selectionTranslationLogger.debug("Lookup de termo cancelado")
            } catch {
                guard !Task.isCancelled, activeLookupCacheKey == cacheKey else { return }
                lookupTranslation = nil
                lookupErrorMessage = error.localizedDescription
                selectionTranslationLogger.error("Lookup de termo falhou: \(error.localizedDescription)")
            }

            if !Task.isCancelled, activeLookupCacheKey == cacheKey {
                isLookingUpTerm = false
                lookupTask = nil
            }
        }
    }

    @discardableResult
    func dismiss(releaseKeepAlive: Bool? = nil) -> Bool {
        let wasVisible = isVisible
        translationTask?.cancel()
        translationTask = nil
        lookupTask?.cancel()
        lookupTask = nil
        ambientLookupTask?.cancel()
        ambientLookupTask = nil
        ambientDismissTask?.cancel()
        ambientDismissTask = nil
        isVisible = false
        isTranslating = false
        presentation = .fullTranslation
        sourceText = ""
        translatedText = nil
        anchorRect = nil
        errorMessage = nil
        resetLookupState(clearCache: true)

        let shouldReleaseKeepAlive = releaseKeepAlive ?? !isAmbientLookupEnabled
        if shouldReleaseKeepAlive {
            Task {
                await llmManager.setKeepAlive(false)
            }
        }
        return wasVisible
    }

    private func handleAmbientLookupModeChange() {
        if isAmbientLookupEnabled {
            createAmbientLookupEventTap()
            startAmbientSelectionPolling()
            Task {
                await llmManager.setKeepAlive(true)
            }
        } else {
            removeAmbientLookupEventTap()
            ambientLookupTask?.cancel()
            ambientLookupTask = nil
            stopAmbientSelectionPolling()
            lastAmbientSelectionKey = nil
            if presentation == .compactLookup {
                dismiss(releaseKeepAlive: false)
            }
            Task {
                await llmManager.setKeepAlive(false)
            }
        }
    }

    private func createAmbientLookupEventTap() {
        removeAmbientLookupEventTap()

        guard AXIsProcessTrusted() else {
            selectionTranslationLogger.debug("Modo Tradução ativo, mas Accessibility ainda não foi concedida")
            return
        }

        let eventMask = 1 << CGEventType.leftMouseUp.rawValue
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard type == .leftMouseUp, let refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let coordinator = Unmanaged<SelectionTranslationCoordinator>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()

                Task { @MainActor in
                    coordinator.handleAmbientMouseUp()
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            selectionTranslationLogger.error("Não foi possível criar event tap do Modo Tradução")
            return
        }

        ambientEventTap = tap
        ambientRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let ambientRunLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), ambientRunLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        selectionTranslationLogger.debug("Event tap do Modo Tradução criado")
    }

    private func removeAmbientLookupEventTap() {
        if let source = ambientRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            ambientRunLoopSource = nil
        }

        if let tap = ambientEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            ambientEventTap = nil
        }
    }

    private func handleAmbientMouseUp() {
        guard isAmbientLookupEnabled else { return }

        ambientLookupTask?.cancel()
        ambientLookupTask = Task { [weak self] in
            guard let self else { return }

            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await readAmbientSelection(allowClipboardFallback: false)
        }
    }

    private func startAmbientSelectionPolling() {
        guard ambientPollingTask == nil else { return }

        ambientPollingTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                await readAmbientSelection(allowClipboardFallback: false)
            }
        }
    }

    private func stopAmbientSelectionPolling() {
        ambientPollingTask?.cancel()
        ambientPollingTask = nil
    }

    private func readAmbientSelection(allowClipboardFallback: Bool) async {
        guard isAmbientLookupEnabled else { return }

        do {
            let selection = try await selectionReader.readSelectedText(
                preferSavedFocusedApp: false,
                allowClipboardFallback: allowClipboardFallback
            )
            guard isAmbientLookupEnabled else { return }
            guard let term = Self.compactLookupTerm(from: selection.text) else {
                clearAmbientCompactLookupIfNeeded()
                return
            }

            let selectionKey = Self.ambientSelectionKey(term: term, anchor: selection.bounds)
            if selectionKey == lastAmbientSelectionKey,
               presentation == .compactLookup,
               (isLookingUpTerm || lookupTranslation != nil || lookupErrorMessage != nil) {
                return
            }

            lastAmbientSelectionKey = selectionKey
            startCompactLookup(
                term: term,
                selectedText: selection.text,
                anchor: selection.bounds,
                targetLanguage: "português brasileiro",
                immediate: false
            )
        } catch {
            clearAmbientCompactLookupIfNeeded()
        }
    }

    private func clearAmbientCompactLookupIfNeeded() {
        guard lastAmbientSelectionKey != nil else { return }
        lastAmbientSelectionKey = nil

        guard presentation == .compactLookup, isVisible else { return }

        ambientDismissTask?.cancel()
        ambientDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled else { return }
            _ = dismiss(releaseKeepAlive: false)
        }
    }

    private func maxTokens(for text: String) -> Int {
        min(1_024, max(256, text.count / 2 + 128))
    }

    private func resetLookupState(clearCache: Bool) {
        lookupTask?.cancel()
        lookupTask = nil
        selectedLookupTerm = nil
        lookupTranslation = nil
        isLookingUpTerm = false
        lookupErrorMessage = nil
        activeLookupCacheKey = nil
        if clearCache {
            lookupCache.removeAll()
        }
    }

    private static func lookupTerm(from rawWord: String) -> String {
        rawWord
            .split(whereSeparator: { $0.isWhitespace })
            .map { cleanLookupToken(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func cleanLookupToken(_ rawToken: String) -> String {
        let edgeTrimmed = rawToken.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var result = ""

        for scalar in edgeTrimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == "'"
                || scalar == "-" {
                result.unicodeScalars.append(scalar)
            }
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
    }

    private static func compactLookupTerm(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \.isNewline)
        else { return nil }

        let rawWordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        if rawWordCount > 1 {
            var phrasePunctuation = CharacterSet.punctuationCharacters
            phrasePunctuation.remove(charactersIn: "'-")
            guard trimmed.rangeOfCharacter(from: phrasePunctuation) == nil else { return nil }
        }

        let term = lookupTerm(from: trimmed)
        let wordCount = term.split(whereSeparator: { $0.isWhitespace }).count
        guard wordCount > 0,
              wordCount <= 3,
              term.count <= 48,
              term.rangeOfCharacter(from: .letters) != nil
        else { return nil }

        return term
    }

    private static func lookupCacheKey(for term: String) -> String {
        term
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func ambientSelectionKey(term: String, anchor: NSRect?) -> String {
        let normalizedTerm = lookupCacheKey(for: term)
        guard let anchor else { return normalizedTerm }

        return [
            normalizedTerm,
            String(Int(anchor.origin.x.rounded())),
            String(Int(anchor.origin.y.rounded())),
            String(Int(anchor.width.rounded())),
            String(Int(anchor.height.rounded()))
        ].joined(separator: "|")
    }
}

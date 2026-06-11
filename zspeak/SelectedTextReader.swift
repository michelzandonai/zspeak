import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os.log

private let selectedTextLogger = Logger(subsystem: "com.zspeak", category: "SelectedTextReader")

struct SelectedTextSelection {
    let text: String
    let bounds: NSRect?
}

enum SelectedTextReadError: LocalizedError {
    case accessibilityNotGranted
    case noFocusedApplication
    case noSelection

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Permissão de Acessibilidade necessária para ler a seleção."
        case .noFocusedApplication:
            return "Nenhum app em foco para ler a seleção."
        case .noSelection:
            return "Nenhum texto selecionado."
        }
    }
}

@MainActor
protocol SelectedTextReading {
    func readSelectedText(
        preferSavedFocusedApp: Bool,
        allowClipboardFallback: Bool
    ) async throws -> SelectedTextSelection
}

extension SelectedTextReading {
    func readSelectedText() async throws -> SelectedTextSelection {
        try await readSelectedText(preferSavedFocusedApp: true, allowClipboardFallback: true)
    }

    func readSelectedText(preferSavedFocusedApp: Bool) async throws -> SelectedTextSelection {
        try await readSelectedText(
            preferSavedFocusedApp: preferSavedFocusedApp,
            allowClipboardFallback: true
        )
    }
}

@MainActor
struct SelectedTextReader: SelectedTextReading {
    func readSelectedText(
        preferSavedFocusedApp: Bool = true,
        allowClipboardFallback: Bool = true
    ) async throws -> SelectedTextSelection {
        guard AXIsProcessTrusted() else {
            throw SelectedTextReadError.accessibilityNotGranted
        }

        let selectedApp = preferSavedFocusedApp
            ? TextInserter.previousApp ?? NSWorkspace.shared.frontmostApplication
            : NSWorkspace.shared.frontmostApplication

        guard let app = selectedApp else {
            throw SelectedTextReadError.noFocusedApplication
        }

        if let selection = readViaAccessibility(from: app) {
            return selection
        }

        guard allowClipboardFallback else {
            throw SelectedTextReadError.noSelection
        }

        if let selection = await readViaClipboardFallback() {
            return selection
        }

        throw SelectedTextReadError.noSelection
    }

    private func readViaAccessibility(from app: NSRunningApplication) -> SelectedTextSelection? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let element = focusedElement(in: appElement) ?? focusedSystemElement()
        guard let element else { return nil }

        guard let text = stringAttribute(kAXSelectedTextAttribute, from: element)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else {
            return nil
        }

        return SelectedTextSelection(
            text: text,
            bounds: selectedTextBounds(in: element)
        )
    }

    private func focusedElement(in appElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard error == .success else { return nil }
        return value as! AXUIElement?
    }

    private func focusedSystemElement() -> AXUIElement? {
        let systemElement = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard error == .success else { return nil }
        return value as! AXUIElement?
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else { return nil }
        return value as? String
    }

    private func selectedTextBounds(in element: AXUIElement) -> NSRect? {
        var rangeValue: CFTypeRef?
        let rangeError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )
        guard rangeError == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let rangeAXValue = rangeValue as! AXValue
        guard
              AXValueGetType(rangeAXValue) == .cfRange
        else {
            return nil
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(rangeAXValue, .cfRange, &selectedRange),
              selectedRange.length > 0,
              let rangeParameter = AXValueCreate(.cfRange, &selectedRange)
        else {
            return nil
        }

        var boundsValue: CFTypeRef?
        let boundsError = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeParameter,
            &boundsValue
        )
        guard boundsError == .success,
              let boundsValue,
              CFGetTypeID(boundsValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let boundsAXValue = boundsValue as! AXValue
        guard
              AXValueGetType(boundsAXValue) == .cgRect
        else {
            return nil
        }

        var cgRect = CGRect.zero
        guard AXValueGetValue(boundsAXValue, .cgRect, &cgRect),
              !cgRect.isNull,
              !cgRect.isEmpty
        else {
            return nil
        }

        return AccessibilityCoordinateConverter.appKitRect(fromAccessibilityRect: cgRect)
    }

    private func readViaClipboardFallback() async -> SelectedTextSelection? {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        let baselineChangeCount = pasteboard.changeCount

        guard simulateCopy() else {
            snapshot.restore(to: pasteboard)
            return nil
        }

        for _ in 0..<12 {
            try? await Task.sleep(for: .milliseconds(25))
            if pasteboard.changeCount != baselineChangeCount {
                break
            }
        }

        let copied = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        snapshot.restore(to: pasteboard)

        guard let copied, !copied.isEmpty else { return nil }
        return SelectedTextSelection(
            text: copied,
            bounds: NSRect(origin: NSEvent.mouseLocation, size: .zero)
        )
    }

    private func simulateCopy() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        else {
            selectedTextLogger.error("CGEvent retornou nil ao simular Cmd+C")
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let itemSnapshots = (pasteboard.pasteboardItems ?? []).map { item in
            var snapshot: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    snapshot[type] = data
                }
            }
            return snapshot
        }
        return PasteboardSnapshot(items: itemSnapshots)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restoredItems = items.map { snapshot in
            let item = NSPasteboardItem()
            for (type, data) in snapshot {
                item.setData(data, forType: type)
            }
            return item
        }

        pasteboard.writeObjects(restoredItems)
    }
}

private enum AccessibilityCoordinateConverter {
    static func appKitRect(fromAccessibilityRect rect: CGRect) -> NSRect {
        guard let screen = screen(containingAccessibilityRect: rect),
              let displayID = screen.displayID
        else {
            return NSRect(origin: NSEvent.mouseLocation, size: rect.size)
        }

        let displayBounds = CGDisplayBounds(displayID)
        let screenFrame = screen.frame
        let x = screenFrame.minX + (rect.minX - displayBounds.minX)
        let y = screenFrame.maxY - (rect.maxY - displayBounds.minY)

        return NSRect(
            x: x,
            y: y,
            width: rect.width,
            height: rect.height
        )
    }

    private static func screen(containingAccessibilityRect rect: CGRect) -> NSScreen? {
        let point = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { screen in
            guard let displayID = screen.displayID else { return false }
            return CGDisplayBounds(displayID).contains(point)
        } ?? NSScreen.main
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let displayID = deviceDescription[key] as? CGDirectDisplayID {
            return displayID
        }
        if let number = deviceDescription[key] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return nil
    }
}

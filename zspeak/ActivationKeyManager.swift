import Foundation

enum ActivationMode: String, CaseIterable, Codable {
    case toggle = "Toggle"
    case hold = "Hold"
    case doubleTap = "Double Tap"
}

enum ActivationKey: String, CaseIterable, Codable, Identifiable {
    case notSpecified = "Not specified"
    case rightCommand = "Right ⌘"
    case rightOption = "Right ⌥"
    case rightShift = "Right ⇧"
    case rightControl = "Right ⌃"
    case optionCommand = "⌥ + ⌘"
    case controlCommand = "⌃ + ⌘"
    case controlOption = "⌃ + ⌥"
    case shiftCommand = "⇧ + ⌘"
    case optionShift = "⌥ + ⇧"
    case controlShift = "⌃ + ⇧"
    case fn = "Fn"
    case custom = "Record shortcut..."

    var id: String { rawValue }
}

@Observable
@MainActor
final class ActivationKeyManager {
    var selectedKey: ActivationKey {
        didSet { UserDefaults.standard.set(selectedKey.rawValue, forKey: "activationKey") }
    }

    var activationMode: ActivationMode {
        didSet { UserDefaults.standard.set(activationMode.rawValue, forKey: "activationMode") }
    }

    var escapeToCancel: Bool {
        didSet { UserDefaults.standard.set(escapeToCancel, forKey: "escapeToCancel") }
    }

    var customShortcutDescription: String {
        didSet { UserDefaults.standard.set(customShortcutDescription, forKey: "customShortcutDescription") }
    }

    init() {
        if let keyRaw = UserDefaults.standard.string(forKey: "activationKey"),
           let key = ActivationKey(rawValue: keyRaw) {
            self.selectedKey = key
        } else {
            self.selectedKey = .rightCommand
        }

        if let modeRaw = UserDefaults.standard.string(forKey: "activationMode"),
           let mode = ActivationMode(rawValue: modeRaw) {
            self.activationMode = mode
        } else {
            self.activationMode = .toggle
        }

        let escapeKey = "escapeToCancel"
        if UserDefaults.standard.object(forKey: escapeKey) != nil {
            self.escapeToCancel = UserDefaults.standard.bool(forKey: escapeKey)
        } else {
            self.escapeToCancel = true
        }

        self.customShortcutDescription = UserDefaults.standard.string(forKey: "customShortcutDescription") ?? ""
    }
}

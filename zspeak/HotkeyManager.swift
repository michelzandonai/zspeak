import Cocoa
import KeyboardShortcuts
import os.log

private let hotkeyLogger = Logger(subsystem: "com.zspeak", category: "HotkeyManager")

private let legacyTranslateSelectionShortcut = KeyboardShortcuts.Shortcut(
    .t,
    modifiers: [.command, .option]
)

private let defaultTranslateSelectionShortcut = KeyboardShortcuts.Shortcut(
    .t,
    modifiers: [.control, .option]
)

extension KeyboardShortcuts.Name {
    static let togglePromptMode = Self("togglePromptMode")
    static let toggleSelectionLookupMode = Self("toggleSelectionLookupMode")
    static let translateSelection = Self(
        "translateSelection",
        default: defaultTranslateSelectionShortcut
    )
}

/// Keycodes para teclas modificadoras individuais (left/right)
private enum KeyCode: UInt16 {
    case rightCommand = 54
    case leftCommand = 55
    case rightOption = 61
    case leftOption = 58
    case rightShift = 60
    case leftShift = 56
    case rightControl = 62
    case leftControl = 59
    case fn = 63
    case escape = 53
}

/// Gerencia hotkeys globais via CGEvent tap, suportando modos toggle/hold/doubleTap
@MainActor
final class HotkeyManager {

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let activationKeyManager: ActivationKeyManager

    /// Indica se o event tap está ativo e monitorando teclas
    private(set) var isEventTapActive: Bool = false

    // Callbacks
    private var onToggle: (@MainActor () -> Void)?
    private var onStartRecording: (@MainActor () -> Void)?
    private var onStopRecording: (@MainActor () -> Void)?
    private var onCancelRecording: (@MainActor () -> Void)?
    private var onTranslateSelection: (@MainActor () -> Void)?
    private var onToggleSelectionLookupMode: (@MainActor () -> Void)?

    /// Gerenciador do Modo Prompt LLM (setado externamente via App.swift)
    var promptModeManager: PromptModeManager?

    // Estado interno para double tap
    private var lastTapTime: Date?
    private let doubleTapInterval: TimeInterval = 0.3

    // Estado interno para hold mode
    private var isHolding = false

    // Guarda as flags anteriores para detectar key-up de modificadores
    private var previousFlags: CGEventFlags = []

    // Evita duplo disparo quando Carbon e CGEvent tap capturam o mesmo atalho.
    private var lastTranslateShortcutAt: Date?
    private let translateShortcutDebounce: TimeInterval = 0.45

    init(activationKeyManager: ActivationKeyManager) {
        self.activationKeyManager = activationKeyManager
    }

    // deinit não necessário — HotkeyManager vive durante toda a execução do app

    /// Configura os callbacks e inicia o monitoramento de teclas globais
    func setup(
        onToggle: @escaping @MainActor () -> Void,
        onStartRecording: @escaping @MainActor () -> Void,
        onStopRecording: @escaping @MainActor () -> Void,
        onCancelRecording: @escaping @MainActor () -> Void,
        onTranslateSelection: @escaping @MainActor () -> Void,
        onToggleSelectionLookupMode: @escaping @MainActor () -> Void
    ) {
        self.onToggle = onToggle
        self.onStartRecording = onStartRecording
        self.onStopRecording = onStopRecording
        self.onCancelRecording = onCancelRecording
        self.onTranslateSelection = onTranslateSelection
        self.onToggleSelectionLookupMode = onToggleSelectionLookupMode
        migrateTranslateSelectionShortcutIfNeeded()
        createEventTap()

        // Atalho global de toggle do Modo Prompt LLM.
        // Salva o frontmost app ANTES de toggle (TASK-013) — garante que o paste do
        // resultado LLM vá para o app destino correto, mesmo quando o usuário entra
        // no Modo Prompt sem gravar antes.
        KeyboardShortcuts.onKeyDown(for: .togglePromptMode) { [weak self] in
            TextInserter.saveFocusedApp()
            self?.promptModeManager?.toggle()
        }

        // Caminho principal para atalhos de combinação. O CGEvent tap abaixo
        // permanece como fallback, mas Carbon é mais confiável para atalhos
        // customizáveis gravados pelo KeyboardShortcuts.Recorder.
        KeyboardShortcuts.onKeyDown(for: .translateSelection) { [weak self] in
            self?.triggerTranslateSelection(source: "KeyboardShortcuts")
        }

        KeyboardShortcuts.onKeyDown(for: .toggleSelectionLookupMode) { [weak self] in
            self?.onToggleSelectionLookupMode?()
        }
    }

    private func migrateTranslateSelectionShortcutIfNeeded() {
        guard KeyboardShortcuts.getShortcut(for: .translateSelection) == legacyTranslateSelectionShortcut else {
            return
        }

        KeyboardShortcuts.setShortcut(defaultTranslateSelectionShortcut, for: .translateSelection)
        hotkeyLogger.info("Atalho de tradução migrado de ⌥⌘T para ⌃⌥T para evitar conflito com a tecla de gravação")
    }

    /// Recria o event tap (usado quando a permissão de Accessibility é concedida após o startup)
    func recreateEventTap() {
        createEventTap()
    }

    // MARK: - CGEvent Tap

    private func createEventTap() {
        removeEventTap()

        // Verificar permissão de Accessibility antes de tentar criar o tap
        guard AXIsProcessTrusted() else {
            isEventTapActive = false
            return
        }

        // Captura flagsChanged (modificadores) e keyDown (para Escape)
        let eventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        // Pointer estável para self (capturado como Unmanaged)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

                // Se o tap for desabilitado pelo sistema, reabilitar
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let eventTap = manager.eventTap {
                        CGEvent.tapEnable(tap: eventTap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                manager.handleEvent(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            isEventTapActive = false
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isEventTapActive = true
    }

    private func removeEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        isEventTapActive = false
    }

    // MARK: - Event Handling (chamado da callback C — NÃO é @MainActor)

    /// Nota: esta função é chamada da callback do CGEvent tap (thread do RunLoop),
    /// mas como o tap é adicionado ao RunLoop principal, roda na main thread.
    private nonisolated func handleEvent(type: CGEventType, event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        MainActor.assumeIsolated {
            if type == .keyDown {
                if keyCode == KeyCode.escape.rawValue {
                    handleEscape()
                    return
                }

                if !isAutoRepeat,
                   matchesKeyboardShortcut(keyCode: keyCode, flags: flags, name: .translateSelection) {
                    triggerTranslateSelection(source: "CGEvent")
                    return
                }
            }

            if type == .flagsChanged {
                handleFlagsChanged(keyCode: keyCode, flags: flags)
            }
        }
    }

    private func triggerTranslateSelection(source: String) {
        let now = Date()
        if let lastTranslateShortcutAt,
           now.timeIntervalSince(lastTranslateShortcutAt) < translateShortcutDebounce {
            hotkeyLogger.debug("Atalho de tradução ignorado por debounce (\(source, privacy: .public))")
            return
        }

        lastTranslateShortcutAt = now
        hotkeyLogger.debug("Atalho de tradução da seleção acionado via \(source, privacy: .public)")
        TextInserter.saveFocusedApp()
        onTranslateSelection?()
    }

    private func matchesKeyboardShortcut(
        keyCode: UInt16,
        flags: CGEventFlags,
        name: KeyboardShortcuts.Name
    ) -> Bool {
        guard let configuredShortcut = KeyboardShortcuts.getShortcut(for: name),
              configuredShortcut.carbonKeyCode == Int(keyCode)
        else {
            return false
        }

        return modifierFlags(from: flags) == shortcutModifierFlags(configuredShortcut.modifiers)
    }

    private func modifierFlags(from flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var modifiers = NSEvent.ModifierFlags()
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        return modifiers
    }

    private func shortcutModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        var modifiers = NSEvent.ModifierFlags()
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }

    // MARK: - Escape

    private func handleEscape() {
        // Se modo prompt está ativo, ESC desativa o modo (prioridade sobre cancel recording)
        if let modeManager = promptModeManager, modeManager.isEnabled {
            modeManager.disable()
            return
        }

        guard activationKeyManager.escapeToCancel else { return }
        onCancelRecording?()
    }

    // MARK: - Flags Changed (modificadores)

    private func handleFlagsChanged(keyCode: UInt16, flags: CGEventFlags) {
        let selectedKey = activationKeyManager.selectedKey
        guard selectedKey != .notSpecified && selectedKey != .custom else { return }

        let isKeyDown = isModifierKeyDown(keyCode: keyCode, flags: flags)

        // Para teclas individuais, verifica se o keycode corresponde
        if let expectedKeyCode = singleKeyCode(for: selectedKey) {
            if keyCode == expectedKeyCode {
                handleActivation(isDown: isKeyDown)
            }
        }
        // Para combinações, verifica se ambos os flags estão ativos
        else if let combo = comboFlags(for: selectedKey) {
            let bothActive = flags.contains(combo.0) && flags.contains(combo.1)
            handleActivation(isDown: bothActive)
        }

        previousFlags = flags
    }

    /// Verifica se o modificador foi pressionado (down) ou solto (up)
    private func isModifierKeyDown(keyCode: UInt16, flags: CGEventFlags) -> Bool {
        // Para Fn, verificar flag secundário
        if keyCode == KeyCode.fn.rawValue {
            return flags.contains(.maskSecondaryFn)
        }
        // Para outros modificadores, verificar se o flag correspondente está ativo
        guard let flag = flagForKeyCode(keyCode) else { return false }
        return flags.contains(flag)
    }

    /// Retorna o CGEventFlags para um keycode de modificador
    private func flagForKeyCode(_ keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case KeyCode.leftCommand.rawValue, KeyCode.rightCommand.rawValue:
            return .maskCommand
        case KeyCode.leftOption.rawValue, KeyCode.rightOption.rawValue:
            return .maskAlternate
        case KeyCode.leftShift.rawValue, KeyCode.rightShift.rawValue:
            return .maskShift
        case KeyCode.leftControl.rawValue, KeyCode.rightControl.rawValue:
            return .maskControl
        default:
            return nil
        }
    }

    // MARK: - Mapeamento ActivationKey → KeyCode/Flags

    /// Retorna o keycode esperado para teclas individuais (não-combo)
    private func singleKeyCode(for key: ActivationKey) -> UInt16? {
        switch key {
        case .rightCommand: return KeyCode.rightCommand.rawValue
        case .rightOption: return KeyCode.rightOption.rawValue
        case .rightShift: return KeyCode.rightShift.rawValue
        case .rightControl: return KeyCode.rightControl.rawValue
        case .fn: return KeyCode.fn.rawValue
        default: return nil
        }
    }

    /// Retorna par de flags para combinações de teclas
    private func comboFlags(for key: ActivationKey) -> (CGEventFlags, CGEventFlags)? {
        switch key {
        case .optionCommand: return (.maskAlternate, .maskCommand)
        case .controlCommand: return (.maskControl, .maskCommand)
        case .controlOption: return (.maskControl, .maskAlternate)
        case .shiftCommand: return (.maskShift, .maskCommand)
        case .optionShift: return (.maskAlternate, .maskShift)
        case .controlShift: return (.maskControl, .maskShift)
        default: return nil
        }
    }

    // MARK: - Lógica de Ativação por Modo

    private func handleActivation(isDown: Bool) {
        let mode = activationKeyManager.activationMode

        switch mode {
        case .toggle:
            // Ativa no key-down
            if isDown {
                onToggle?()
            }

        case .hold:
            if isDown && !isHolding {
                isHolding = true
                onStartRecording?()
            } else if !isDown && isHolding {
                isHolding = false
                onStopRecording?()
            }

        case .doubleTap:
            if isDown {
                let now = Date()
                if let last = lastTapTime, now.timeIntervalSince(last) < doubleTapInterval {
                    lastTapTime = nil
                    onToggle?()
                } else {
                    lastTapTime = now
                }
            }
        }
    }
}

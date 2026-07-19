import AppKit
import Carbon.HIToolbox

/// A Carbon-compatible global keyboard shortcut. Carbon is used for the
/// registration so the app does not need Accessibility permission.
struct GlobalShortcut: Equatable {
    static let defaultShortcut = GlobalShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey),
        keyLabel: "Space"
    )

    private static let keyCodeDefaultsKey = "toggleShortcutKeyCode"
    private static let modifiersDefaultsKey = "toggleShortcutModifiers"
    private static let keyLabelDefaultsKey = "toggleShortcutKeyLabel"

    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init(defaults: UserDefaults) {
        guard defaults.object(forKey: Self.keyCodeDefaultsKey) != nil,
              defaults.object(forKey: Self.modifiersDefaultsKey) != nil else {
            self = Self.defaultShortcut
            return
        }

        guard let keyCode = UInt32(exactly: defaults.integer(forKey: Self.keyCodeDefaultsKey)),
              let modifiers = UInt32(exactly: defaults.integer(forKey: Self.modifiersDefaultsKey)) else {
            self = Self.defaultShortcut
            return
        }
        let allowedModifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let hasPrimaryModifier = modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
        guard modifiers & ~allowedModifiers == 0, hasPrimaryModifier else {
            self = Self.defaultShortcut
            return
        }

        let savedLabel = defaults.string(forKey: Self.keyLabelDefaultsKey)
            .flatMap { $0.isEmpty || $0.count > 12 ? nil : $0 }
        self.init(
            keyCode: keyCode,
            modifiers: modifiers,
            keyLabel: savedLabel ?? Self.keyLabel(for: keyCode, fallback: nil)
        )
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }

        // Shift alone would consume normal capital-letter typing system-wide.
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }

        let keyCode = UInt32(event.keyCode)
        self.init(
            keyCode: keyCode,
            modifiers: modifiers,
            keyLabel: Self.keyLabel(for: keyCode, fallback: event.charactersIgnoringModifiers)
        )
    }

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }

    func persist(to defaults: UserDefaults = .standard) {
        defaults.set(Int(keyCode), forKey: Self.keyCodeDefaultsKey)
        defaults.set(Int(modifiers), forKey: Self.modifiersDefaultsKey)
        defaults.set(keyLabel, forKey: Self.keyLabelDefaultsKey)
    }

    private static func keyLabel(for keyCode: UInt32, fallback: String?) -> String {
        let specialKeys: [UInt32: String] = [
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Return): "↩",
            UInt32(kVK_Tab): "⇥",
            UInt32(kVK_Delete): "⌫",
            UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_Home): "↖",
            UInt32(kVK_End): "↘",
            UInt32(kVK_PageUp): "⇞",
            UInt32(kVK_PageDown): "⇟",
            UInt32(kVK_LeftArrow): "←",
            UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑",
            UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_F1): "F1",
            UInt32(kVK_F2): "F2",
            UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4",
            UInt32(kVK_F5): "F5",
            UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7",
            UInt32(kVK_F8): "F8",
            UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10",
            UInt32(kVK_F11): "F11",
            UInt32(kVK_F12): "F12",
            UInt32(kVK_F13): "F13",
            UInt32(kVK_F14): "F14",
            UInt32(kVK_F15): "F15",
            UInt32(kVK_F16): "F16",
            UInt32(kVK_F17): "F17",
            UInt32(kVK_F18): "F18",
            UInt32(kVK_F19): "F19",
            UInt32(kVK_F20): "F20",
        ]
        if let special = specialKeys[keyCode] { return special }
        if let fallback, !fallback.isEmpty {
            return fallback.uppercased()
        }
        return "Key \(keyCode)"
    }
}

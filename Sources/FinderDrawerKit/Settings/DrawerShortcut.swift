import AppKit
import Carbon

public struct DrawerShortcut: Codable, Equatable, Hashable, Sendable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let keyLabel: String

    public static let controlOptionSpace = DrawerShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey), keyLabel: "Space")
    public static let controlShiftSpace = DrawerShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | shiftKey), keyLabel: "Space")
    public static let optionSpace = DrawerShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey), keyLabel: "Space")

    public init?(rawValue: String) {
        switch rawValue {
        case "controlOptionSpace": self = .controlOptionSpace
        case "controlShiftSpace": self = .controlShiftSpace
        case "optionSpace": self = .optionSpace
        default: return nil
        }
    }

    init(keyCode: UInt32, carbonModifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty,
              ![53, 57, 54, 55, 56, 58, 59, 60, 61, 62, 63].contains(event.keyCode) else { return nil }
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let names: [UInt16: String] = [49: "Space", 36: "↵", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
                                         122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                                         98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
                                         105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"]
        let name = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: modifiers, keyLabel: name)
    }

    public var label: String {
        var value = ""
        for (mask, glyph) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if carbonModifiers & UInt32(mask) != 0 { value += glyph }
        }
        return value + keyLabel
    }
}

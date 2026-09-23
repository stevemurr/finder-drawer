import AppKit
import SwiftTerm

/// Stable preference identifiers; the native appearance remains the default.
enum TerminalTheme: String, CaseIterable, Identifiable {
    case system, catppuccinMocha, dracula, nord, solarizedDark
    case catppuccinLatte, solarizedLight, nordSnow

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "System"
        case .catppuccinMocha: "Catppuccin Mocha"
        case .dracula: "Dracula"
        case .nord: "Nord"
        case .solarizedDark: "Solarized Dark"
        case .catppuccinLatte: "Catppuccin Latte"
        case .solarizedLight: "Solarized Light"
        case .nordSnow: "Nord Snow (adapted)"
        }
    }
    var isDark: Bool {
        switch self {
        case .catppuccinMocha, .dracula, .nord, .solarizedDark: true
        default: false
        }
    }
    static func choices(dark: Bool) -> [Self] {
        allCases.filter { $0 == .system || $0.isDark == dark }
    }

    var palette: TerminalPalette? {
        switch self {
        case .system: return nil
        case .catppuccinMocha:
            return .init(background: 0x1e1e2e, foreground: 0xcdd6f4, selection: 0x45475a, cursor: 0xf5e0dc,
                         ansi: [0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de,
                                0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8])
        case .dracula:
            return .init(background: 0x282a36, foreground: 0xf8f8f2, selection: 0x44475a, cursor: 0xff79c6,
                         ansi: [0x21222c, 0xff5555, 0x50fa7b, 0xf1fa8c, 0xbd93f9, 0xff79c6, 0x8be9fd, 0xf8f8f2,
                                0x6272a4, 0xff6e6e, 0x69ff94, 0xffffa5, 0xd6acff, 0xff92df, 0xa4ffff, 0xffffff])
        case .nord:
            return .init(background: 0x2e3440, foreground: 0xeceff4, selection: 0x434c5e, cursor: 0x88c0d0,
                         ansi: [0x3b4252, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x88c0d0, 0xe5e9f0,
                                0x4c566a, 0xbf616a, 0xa3be8c, 0xebcb8b, 0x81a1c1, 0xb48ead, 0x8fbcbb, 0xeceff4])
        case .catppuccinLatte:
            return .init(background: 0xeff1f5, foreground: 0x4c4f69, selection: 0xccd0da, cursor: 0x8839ef,
                         ansi: [0x5c5f77, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xacb0be,
                                0x6c6f85, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xbcc0cc])
        case .solarizedDark, .solarizedLight:
            let dark = self == .solarizedDark
            return .init(background: dark ? 0x002b36 : 0xfdf6e3, foreground: dark ? 0x93a1a1 : 0x586e75,
                         selection: dark ? 0x194b55 : 0xded8c5, cursor: dark ? 0xb58900 : 0x176d9a,
                         ansi: [0x073642, 0xdc322f, 0x859900, 0xb58900, 0x268bd2, 0xd33682, 0x2aa198, 0xeee8d5,
                                0x002b36, 0xcb4b16, 0x586e75, 0x657b83, 0x839496, 0x6c71c4, 0x93a1a1, 0xfdf6e3])
        case .nordSnow:
            // Light adaptation of Nord; darker accents remain visible on snow.
            return .init(background: 0xeceff4, foreground: 0x2e3440, selection: 0xd8dee9, cursor: 0x476a8b,
                         ansi: [0x2e3440, 0xa33e49, 0x466534, 0x8a671d, 0x476a8b, 0x875a80, 0x32727c, 0xd8dee9,
                                0x4c566a, 0xa33e49, 0x466534, 0x8a671d, 0x476a8b, 0x875a80, 0x32727c, 0xeceff4])
        }
    }
}

struct TerminalPalette {
    let background, foreground, selection, cursor: UInt32
    let ansi: [UInt32]
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    var terminalColors: [SwiftTerm.Color] {
        ansi.map { SwiftTerm.Color(red: UInt16(($0 >> 16) & 255) * 257,
                                  green: UInt16(($0 >> 8) & 255) * 257,
                                  blue: UInt16($0 & 255) * 257) }
    }
}

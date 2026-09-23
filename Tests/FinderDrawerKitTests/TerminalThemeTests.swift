import AppKit
import SwiftTerm
import XCTest
@testable import FinderDrawerKit

@MainActor
final class TerminalThemeTests: XCTestCase {
    func testPreferencesRoundTripAndRejectUnknownOrWrongAppearance() throws {
        let suite = "terminal-themes-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = BrowserPreferences(defaults: defaults)
        XCTAssertEqual(preferences.lightTerminalTheme, .system)
        XCTAssertEqual(preferences.darkTerminalTheme, .system)
        preferences.lightTerminalTheme = .nordSnow
        preferences.darkTerminalTheme = .catppuccinMocha
        let restored = BrowserPreferences(defaults: defaults)
        XCTAssertEqual(restored.lightTerminalTheme, .nordSnow)
        XCTAssertEqual(restored.darkTerminalTheme, .catppuccinMocha)
        defaults.set("missing-theme", forKey: "terminalDarkTheme")
        defaults.set("dracula", forKey: "terminalLightTheme")
        let invalid = BrowserPreferences(defaults: defaults)
        XCTAssertEqual(invalid.lightTerminalTheme, .system)
        XCTAssertEqual(invalid.darkTerminalTheme, .system)
    }

    func testEveryThemeAppliesForegroundBackgroundSelectionCursorAndANSI() throws {
        _ = NSApplication.shared
        let view = AppearanceFollowingTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        XCTAssertEqual(TerminalTheme.allCases.count, 8) // Seven palettes plus System.
        for theme in TerminalTheme.allCases where theme != .system {
            let palette = try XCTUnwrap(theme.palette)
            XCTAssertEqual(palette.terminalColors.count, 16)
            view.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
            view.setThemes(light: theme.isDark ? .system : theme, dark: theme.isDark ? theme : .system)
            XCTAssertEqual(rgb(view.nativeBackgroundColor), palette.background, theme.label)
            XCTAssertEqual(rgb(view.nativeForegroundColor), palette.foreground, theme.label)
            XCTAssertEqual(rgb(view.selectedTextBackgroundColor), palette.selection, theme.label)
            XCTAssertEqual(rgb(view.caretColor), palette.cursor, theme.label)
            XCTAssertEqual(rgb(try XCTUnwrap(view.caretTextColor)), palette.background, theme.label)
            XCTAssertGreaterThanOrEqual(contrast(palette.cursor, palette.background), 3, theme.label)
            XCTAssertGreaterThanOrEqual(contrast(palette.foreground, palette.background), 4.5, theme.label)
        }
        view.setThemes(light: .system, dark: .system)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            XCTAssertEqual(rgb(view.nativeBackgroundColor), rgb(.textBackgroundColor))
            XCTAssertEqual(rgb(view.caretColor), rgb(.textColor))
        }
    }

    func testWorkspaceChangesUpdateRetainedAndFutureTerminalsWithoutRestarting() async throws {
        _ = NSApplication.shared
        let suite = "theme-workspace-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let workspace = try DrawerWorkspace(databaseURL: directory.appendingPathComponent("index.sqlite3"),
                                             defaults: defaults, initialFolders: [directory], restoresFolders: false)
        defer { workspace.stop() }
        workspace.newTerminal(at: directory)
        let session = try XCTUnwrap(workspace.terminal)
        let view = session.makeView()
        view.appearance = NSAppearance(named: .darkAqua)
        session.startIfNeeded(executable: "/bin/sh", arguments: ["-c", "printf 'THEME_SCROLLBACK\\n'; read value"])
        func output() -> String { String(data: view.getTerminal().getBufferAsData(), encoding: .utf8) ?? "" }
        for _ in 0..<100 {
            if output().contains("THEME_SCROLLBACK") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(output().contains("THEME_SCROLLBACK"))
        let pid = view.process.shellPid
        workspace.newTab(at: directory) // Terminal is now in the background.
        workspace.preferences.darkTerminalTheme = .dracula
        workspace.preferences.lightTerminalTheme = .nordSnow
        XCTAssertEqual(rgb(view.nativeBackgroundColor), 0x282a36)
        XCTAssertEqual(rgb(view.caretColor), 0xff79c6)
        XCTAssertTrue(session.makeView() === view)
        XCTAssertEqual(view.process.shellPid, pid)
        XCTAssertTrue(view.process.running)
        XCTAssertTrue(output().contains("THEME_SCROLLBACK"))
        view.appearance = NSAppearance(named: .aqua)
        view.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(rgb(view.nativeBackgroundColor), 0xeceff4)
        workspace.newTerminal(at: directory)
        let next = try XCTUnwrap(workspace.terminal).makeView()
        next.appearance = NSAppearance(named: .darkAqua)
        next.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(rgb(next.nativeBackgroundColor), 0x282a36)
    }

    private func rgb(_ color: NSColor) -> UInt32 {
        let c = color.usingColorSpace(.sRGB)!
        return UInt32((c.redComponent * 255).rounded()) << 16 |
            UInt32((c.greenComponent * 255).rounded()) << 8 |
            UInt32((c.blueComponent * 255).rounded())
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ c: UInt32) -> Double {
            let values = [16, 8, 0].map { shift -> Double in
                let v = Double((c >> shift) & 255) / 255
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

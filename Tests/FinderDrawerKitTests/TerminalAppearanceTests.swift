import AppKit
import SwiftTerm
import XCTest
@testable import FinderDrawerKit

@MainActor
final class TerminalAppearanceTests: XCTestCase {
    func testWindowAppearanceUpdatesResolvedTerminalColorsInBothDirections() async throws {
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        let window = makeWindow()
        defer { window.close() }
        let view = session.makeView()
        window.contentView = view
        window.orderFront(nil)

        for name: NSAppearance.Name in [.aqua, .darkAqua, .aqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            window.appearance = appearance
            let expectedForeground = components(of: .textColor, in: appearance)
            let expectedBackground = components(of: .textBackgroundColor, in: appearance)
            try await waitUntil {
                self.components(of: view.getTerminal().foregroundColor) == expectedForeground &&
                self.components(of: view.getTerminal().backgroundColor) == expectedBackground
            }
            XCTAssertEqual(components(of: view.getTerminal().foregroundColor), expectedForeground)
            XCTAssertEqual(components(of: view.getTerminal().backgroundColor), expectedBackground)
        }
    }

    func testRemountUsesDestinationAppearanceAndKeepsShellAndScrollback() async throws {
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        let window = makeWindow()
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        let view = session.makeView()
        window.contentView?.addSubview(view)
        window.orderFront(nil)
        session.startIfNeeded(executable: "/bin/sh", arguments: ["-c", "printf 'KEPT_OUTPUT\\n'; read value; printf 'RECEIVED:%s\\n' \"$value\""])
        func output() -> String { String(data: view.getTerminal().getBufferAsData(), encoding: .utf8) ?? "" }
        try await waitUntil { output().contains("KEPT_OUTPUT") }
        let pid = view.process.shellPid

        view.removeFromSuperview()
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        window.appearance = dark
        // Resolve against the destination view, even under an unrelated ambient
        // drawing appearance, as can happen during SwiftUI mounting.
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            window.contentView?.addSubview(session.makeView())
        }
        let expected = components(of: .textBackgroundColor, in: dark)
        try await waitUntil { self.components(of: view.getTerminal().backgroundColor) == expected }
        XCTAssertTrue(session.makeView() === view)
        XCTAssertEqual(view.process.shellPid, pid)
        XCTAssertTrue(view.process.running)
        XCTAssertTrue(output().contains("KEPT_OUTPUT"))
        view.send(txt: "still-running\n")
        try await waitUntil { session.hasExited }
        XCTAssertTrue(output().contains("RECEIVED:still-running"))
        XCTAssertEqual(session.exitCode, 0)
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func components(of color: SwiftTerm.Color) -> [UInt16] {
        [color.red, color.green, color.blue]
    }

    private func components(of color: NSColor, in appearance: NSAppearance) -> [UInt16] {
        var components: [UInt16] = []
        appearance.performAsCurrentDrawingAppearance {
            let rgb = color.usingColorSpace(.sRGB)!
            components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
                .map { UInt16(min(max($0, 0), 1) * 65535) }
        }
        return components
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<150 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected terminal state did not arrive")
    }
}

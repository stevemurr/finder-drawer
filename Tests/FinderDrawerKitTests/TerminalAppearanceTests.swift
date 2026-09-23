import AppKit
import Metal
import SwiftTerm
import XCTest
@testable import FinderDrawerKit

@MainActor
final class TerminalAppearanceTests: XCTestCase {
    func testTerminalFontContainsShellIconsWhenNerdFontIsInstalled() throws {
        guard NSFont(name: "FiraCodeNF-Reg", size: 13) != nil ||
                NSFont(name: "FiraCodeNFM-Reg", size: 13) != nil else {
            throw XCTSkip("Fira Code Nerd Font is not installed on this machine")
        }
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        let font = session.makeView().font
        XCTAssertEqual(font.pointSize, 13)
        // Include supplementary-plane icons used by Nerd Fonts 3, which older
        // Powerline/Meslo installations can lack despite showing folder icons.
        let icons: [Unicode.Scalar] = ["\u{f115}", "\u{f016}", "\u{e609}", "\u{e627}",
                                       "\u{f0318}", "\u{f0c7a}", "\u{f000d}"]
        for icon in icons {
            XCTAssertTrue(font.coveredCharacterSet.contains(icon),
                          "Missing shell icon U+\(String(icon.value, radix: 16)) in \(font.fontName)")
        }
    }

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

    /// OSC 7 names this Mac on every prompt. Recognising it must not depend
    /// on `Host.current()`, whose blocking resolution stalled each prompt.
    func testDirectoryReportsFromThisMacAreRecognisedWithoutNameResolution() {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        XCTAssertEqual(gethostname(&buffer, buffer.count), 0)
        let name = String(cString: buffer)
        XCTAssertTrue(TerminalSession.isLocalHost(nil))
        XCTAssertTrue(TerminalSession.isLocalHost(""))
        XCTAssertTrue(TerminalSession.isLocalHost("localhost"))
        XCTAssertTrue(TerminalSession.isLocalHost(name))
        XCTAssertTrue(TerminalSession.isLocalHost(name.uppercased()))
        XCTAssertFalse(TerminalSession.isLocalHost("remote-build-host.example.com"))

        let session = TerminalSession(directory: FileManager.default.temporaryDirectory)
        let view = session.makeView()
        session.hostCurrentDirectoryUpdate(source: view, directory: "file://\(name)/usr/bin")
        XCTAssertEqual(session.directory.path, "/usr/bin")
        session.hostCurrentDirectoryUpdate(source: view, directory: "file://remote-build-host.example.com/etc")
        XCTAssertEqual(session.directory.path, "/usr/bin", "A remote shell's path does not exist here")
    }

    /// Reattaching after a tab switch under an unchanged appearance must not
    /// reinstall every color — each SwiftTerm color setter repaints the whole
    /// screen — and so leaves colors a program set itself alone.
    func testRemountUnderTheSameAppearanceDoesNotReinstallColors() throws {
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        let window = makeWindow()
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        let view = session.makeView()
        window.contentView?.addSubview(view)

        let programBackground = NSColor(srgbRed: 0.2, green: 0.1, blue: 0.3, alpha: 1)
        view.nativeBackgroundColor = programBackground
        view.removeFromSuperview()
        window.contentView?.addSubview(view)
        XCTAssertEqual(components(of: view.getTerminal().backgroundColor),
                       components(of: programBackground, in: try XCTUnwrap(NSAppearance(named: .aqua))))

        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        window.appearance = dark
        view.viewDidChangeEffectiveAppearance()
        XCTAssertEqual(components(of: view.getTerminal().backgroundColor),
                       components(of: .textBackgroundColor, in: dark),
                       "A real appearance change still resolves system colors")
    }

    func testGPURenderingPreferenceSwitchesRendererOnceMounted() throws {
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        let window = makeWindow()
        defer { window.close() }
        let view = session.makeView()
        session.setUsesGPU(true)
        XCTAssertFalse(view.isUsingMetalRenderer, "Metal needs a window before it can start")

        window.contentView?.addSubview(view)
        guard MTLCreateSystemDefaultDevice() != nil else {
            XCTAssertFalse(view.isUsingMetalRenderer, "Without a device the view keeps Core Graphics")
            return
        }
        XCTAssertTrue(view.isUsingMetalRenderer, "The packaged shader library must load")

        view.removeFromSuperview()
        window.contentView?.addSubview(view)
        XCTAssertTrue(view.isUsingMetalRenderer, "A tab switch keeps the GPU renderer")

        session.setUsesGPU(false)
        XCTAssertFalse(view.isUsingMetalRenderer)
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

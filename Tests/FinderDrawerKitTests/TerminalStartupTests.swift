import AppKit
import SwiftUI
import XCTest
@testable import FinderDrawerKit

@MainActor
final class TerminalStartupTests: XCTestCase {
    func testDiscardedMeasurementHostCannotStealMountedTerminal() throws {
        _ = NSApplication.shared
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let visibleHost = TerminalHostView(session: session) {}
        window.contentView = visibleHost
        visibleHost.layoutSubtreeIfNeeded()
        let terminal = session.makeView()
        XCTAssertTrue(terminal.superview === visibleHost)
        for _ in 0..<10 {
            let measuringHost = TerminalHostView(session: session) {}
            measuringHost.frame = NSRect(x: 0, y: 0, width: 400, height: 250)
            measuringHost.layoutSubtreeIfNeeded()
            XCTAssertTrue(terminal.superview === visibleHost)
            XCTAssertTrue(terminal.window === window)
            withExtendedLifetime(measuringHost) {}
        }
        XCTAssertTrue(terminal.superview === visibleHost)
    }

    func testTerminalFillsActualDrawerPaneAndStarts() async throws {
        let suite = "terminal-drawer-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let controller = try FinderDrawerController(databaseURL: root.appendingPathComponent("index.sqlite3"), defaults: defaults, initialFolders: [root], restoresFolders: false)
        defer { controller.shutdown() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.workspace.newTerminal(at: root)
        let session = try XCTUnwrap(controller.workspace.terminal)
        for _ in 0..<100 {
            window.contentView?.layoutSubtreeIfNeeded()
            if session.hasStarted { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let view = try XCTUnwrap(session.terminalView)
        var ancestors: [String] = []
        var ancestor: NSView? = view
        while let current = ancestor {
            ancestors.append("\(type(of: current)): frame=\(current.frame) hidden=\(current.isHidden)")
            ancestor = current.superview
        }
        let geometry = ancestors.joined(separator: "\n")
        XCTAssertTrue(view.window === window, geometry)
        XCTAssertGreaterThan(view.visibleRect.height, 100, geometry)
        XCTAssertGreaterThan(view.visibleRect.width, 100, geometry)
        XCTAssertTrue(session.hasStarted, geometry)
    }

    func testStartupWaitsForLayoutAndCancelsWhenDetachedOrClosed() async throws {
        _ = NSApplication.shared
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var starts = 0
        let host = TerminalHostView(session: session) {
            starts += 1
            session.startIfNeeded(executable: "/bin/sh", arguments: ["-c", "stty size; printf 'STARTED\\n'; read value"])
        }
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(starts, 0, "A mounted but unsized terminal must wait")
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 400)
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        host.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(starts, 0, "A discarded mount must cancel queued startup")

        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        // Wait for the last line, not the first output: the PTY can deliver
        // `stty size` and STARTED in separate reads.
        func output() -> String {
            session.terminalView.flatMap { String(data: $0.getTerminal().getBufferAsData(), encoding: .utf8) } ?? ""
        }
        for _ in 0..<100 {
            if output().contains("STARTED") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(session.hasReceivedOutput)
        let view = try XCTUnwrap(session.terminalView)
        let size = view.getWindowSize()
        XCTAssertGreaterThan(size.ws_col, 50)
        XCTAssertGreaterThan(size.ws_row, 10)
        let output = String(data: view.getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("\(size.ws_row) \(size.ws_col)"), "Child receives the mounted grid at launch")
        XCTAssertTrue(output.contains("STARTED"))
        session.stop()
        host.removeFromSuperview()
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(starts, 1, "Remounting a closed terminal must not restart it")
    }

    func testClosingBeforeQueuedStartupDoesNotLaunchShell() async throws {
        _ = NSApplication.shared
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var starts = 0
        let host = TerminalHostView(session: session) { starts += 1 }
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 400)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        session.stop()
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(session.hasStarted)
    }

    func testUnmountedSurfaceDoesNotLaunchShell() async throws {
        _ = NSApplication.shared
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        let host = NSHostingView(rootView: TerminalSurface(session: session))
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 450)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(session.terminalView, "Exercise the representable's creation path")
        XCTAssertNil(session.terminalView?.window)
        XCTAssertFalse(session.hasStarted, "Do not launch until the terminal is mounted and sized")
        withExtendedLifetime(host) {}
    }

    func testRepeatedSurfaceRemountRetainsVisibleShell() async throws {
        _ = NSApplication.shared
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory)
        defer { session.stop() }
        session.startIfNeeded(executable: "/bin/sh", arguments: ["-c", "printf 'READY\\n'; while read value; do printf 'REPLY:%s\\n' \"$value\"; done"])
        let view = try XCTUnwrap(session.terminalView)
        let pid = view.process.shellPid
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for iteration in 0..<12 {
            window.contentView = NSHostingView(rootView: TerminalSurface(session: session))
            window.orderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertTrue(view.window === window)
            XCTAssertGreaterThan(view.visibleRect.width, 100)
            XCTAssertGreaterThan(view.visibleRect.height, 100)
            XCTAssertEqual(view.process.shellPid, pid)
            view.send(txt: "MOUNT_\(iteration)\n")
            for _ in 0..<100 {
                if String(data: view.getTerminal().getBufferAsData(), encoding: .utf8)?.contains("REPLY:MOUNT_\(iteration)") == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(String(data: view.getTerminal().getBufferAsData(), encoding: .utf8)?.contains("REPLY:MOUNT_\(iteration)") == true)
            window.contentView = NSView()
        }
    }
}

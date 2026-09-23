import AppKit
import XCTest
@testable import FinderDrawerKit

@MainActor
final class DrawerInteractionTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var workspace: DrawerWorkspace!

    override func setUpWithError() throws {
        suite = "drawer-interaction-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspace = try DrawerWorkspace(databaseURL: root.appendingPathComponent("index.sqlite3"),
                                       defaults: defaults, initialFolders: [root], restoresFolders: false)
    }
    override func tearDownWithError() throws {
        workspace.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testCustomShortcutCapturesKeyAndModifiersAndMigratesPreset() throws {
        defaults.set("optionSpace", forKey: "drawerShortcut")
        let preferences = BrowserPreferences(defaults: defaults)
        XCTAssertEqual(preferences.shortcut, .optionSpace)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                                                  modifierFlags: [.control, .command], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "j",
                                                  charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        preferences.shortcut = try XCTUnwrap(DrawerShortcut(event: event))
        let restored = BrowserPreferences(defaults: defaults).shortcut
        XCTAssertEqual(restored.keyCode, 38)
        XCTAssertEqual(restored.label, "⌃⌘J")
        XCTAssertEqual(restored, preferences.shortcut)
        let plain = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: "j",
                                                  charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        XCTAssertNil(DrawerShortcut(event: plain))
        XCTAssertEqual(BrowserCommand.matching(keyCode: 40, modifiers: .command), .actions)
        XCTAssertEqual(BrowserCommand.matching(keyCode: 3, modifiers: .command), .search)
        XCTAssertEqual(BrowserCommand.matching(keyCode: 17, modifiers: .command), .newTerminal)
        XCTAssertEqual(BrowserCommand.matching(keyCode: 45, modifiers: .command), .newTab)
        XCTAssertEqual(BrowserCommand.matching(keyCode: 45, modifiers: [.command, .shift]), .newFolder)
    }

    func testTerminalActionUsesSelectedFilesParentAndPreservesBrowser() async throws {
        let folder = root.appendingPathComponent("Folder with 'quotes' and spaces")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("report.txt")
        try Data("test".utf8).write(to: file)
        workspace.browser?.setRoot(folder)
        try await waitUntil { self.workspace.browser?.columns.first?.entries.contains { $0.url.standardizedFileURL == file.standardizedFileURL } == true }
        let entry = try XCTUnwrap(workspace.browser?.columns.first?.entries.first { $0.url.standardizedFileURL == file.standardizedFileURL })
        workspace.browser?.select(entry.id, inColumn: 0)
        XCTAssertEqual(workspace.browser?.focusedEntry?.url.standardizedFileURL, file.standardizedFileURL)
        let browser = workspace.browser
        workspace.presentActions()
        workspace.actionQuery = "terminal here"
        XCTAssertEqual(workspace.filteredActions.count, 1)
        workspace.executeSelectedAction()
        let terminal = try XCTUnwrap(workspace.terminal)
        XCTAssertEqual(terminal.directory, folder.standardizedFileURL)
        XCTAssertFalse(terminal.hasStarted)
        XCTAssertFalse(workspace.isActionsPresented)
        workspace.cycleTab(by: -1)
        XCTAssertTrue(workspace.browser === browser)
        workspace.cycleTab(by: 1)
        XCTAssertTrue(workspace.terminal === terminal)
        workspace.closeTab(terminal.id)
        XCTAssertTrue(terminal.isClosed)
        terminal.startIfNeeded()
        XCTAssertFalse(terminal.hasStarted, "Closing before mount must cancel deferred shell startup")
    }

    func testActionShortcutCanRunAnAvailableCommandWhileFiltering() {
        workspace.presentActions()
        workspace.actionQuery = "copy"
        XCTAssertTrue(workspace.executeAction(for: .newTerminal))
        XCTAssertNotNil(workspace.terminal)
        XCTAssertFalse(workspace.isActionsPresented)
    }

    func testMixedTabsRestoreTypesAndDirectoryWithoutStartingShells() throws {
        workspace.newTerminal(at: root)
        let firstTerminal = try XCTUnwrap(workspace.terminal)
        workspace.persistTabs()
        workspace.stop()
        workspace = try DrawerWorkspace(databaseURL: root.appendingPathComponent("restored.sqlite3"), defaults: defaults)
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertNotNil(workspace.tabs[0].browser)
        XCTAssertNotNil(workspace.tabs[1].terminal)
        XCTAssertEqual(workspace.terminal?.directory, root.standardizedFileURL)
        XCTAssertFalse(workspace.terminal?.hasStarted ?? true)
        XCTAssertFalse(workspace.terminal === firstTerminal)
    }

    func testContextActionsRespectMultiSelectionAndCanFilterToNoResults() async throws {
        let a = root.appendingPathComponent("a.txt"), b = root.appendingPathComponent("b.txt")
        try Data().write(to: a)
        try Data().write(to: b)
        workspace.browser?.setRoot(root)
        try await waitUntil { self.workspace.browser?.columns.first?.entries.contains { $0.url.standardizedFileURL == b.standardizedFileURL } == true }
        let entries = workspace.browser?.columns.first?.entries.filter { ["a.txt", "b.txt"].contains($0.displayName) } ?? []
        XCTAssertEqual(entries.count, 2)
        workspace.browser?.select(ids: Set(entries.map(\.id)), primary: entries.first?.id, inColumn: 0)
        workspace.presentActions()
        XCTAssertFalse(workspace.contextActions.contains { $0.id == "rename" })
        XCTAssertTrue(workspace.contextActions.contains { $0.id == "copyPath" })
        workspace.actionQuery = "does not exist"
        workspace.moveActionSelection(by: 10)
        workspace.executeSelectedAction()
        XCTAssertTrue(workspace.isActionsPresented)
        workspace.dismissActions()
        XCTAssertFalse(workspace.isActionsPresented)
    }

    func testTerminalPTYAcceptsInputAndUsesLiteralWorkingDirectory() async throws {
        let directory = root.appendingPathComponent("Terminal 'test' space")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = TerminalSession(directory: directory)
        defer { session.stop() }
        session.startIfNeeded(executable: "/bin/sh", arguments: ["-c", "pwd > cwd.txt; printf 'READY\\n'; read value; printf 'GOT:%s\\n' \"$value\"; stty size"])
        let view = try XCTUnwrap(session.terminalView)
        func output() -> String { String(data: view.getTerminal().getBufferAsData(), encoding: .utf8) ?? "" }
        try await waitUntil { output().contains("READY") }
        view.send(txt: "keyboard works\n")
        try await waitUntil { session.hasExited }
        let reportedPath = try String(contentsOf: directory.appendingPathComponent("cwd.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(URL(fileURLWithPath: reportedPath).standardizedFileURL, directory.standardizedFileURL)
        XCTAssertTrue(output().contains("GOT:keyboard works"))
        XCTAssertEqual(session.exitCode, 0)
    }

    func testActionsTakeNativeKeyboardFocusAndFilterTypedInput() async throws {
        let controller = try FinderDrawerController(databaseURL: root.appendingPathComponent("window.sqlite3"),
                                                    defaults: defaults, initialFolders: [root], restoresFolders: false)
        defer { controller.shutdown() }
        let window = try XCTUnwrap(controller.window)
        window.orderFront(nil)
        controller.workspace.presentActions()
        func field() -> NSTextField? {
            window.contentView.flatMap { AppKitSearchFieldFocusLocator.field(withAccessibilityIdentifier: controller.workspace.paletteInputIdentifier, in: $0) }
        }
        try await waitUntil { field().map { AppKitSearchFieldFocusLocator.ownsFirstResponder($0) } == true }
        field()?.currentEditor()?.insertText("terminal")
        try await waitUntil { controller.workspace.actionQuery == "terminal" }
        XCTAssertEqual(controller.workspace.filteredActions.map(\.id), ["terminal", "splitTerminal"])
        controller.workspace.dismissActions()
        XCTAssertFalse(controller.workspace.isActionsPresented)
    }

    func testSwitchingTabsKeepsShellAndClosingTabStopsIt() async throws {
        workspace.newTerminal(at: root)
        let session = try XCTUnwrap(workspace.terminal)
        session.startIfNeeded(executable: "/bin/sh", arguments: ["-c", "read value"])
        let view = try XCTUnwrap(session.terminalView)
        let pid = view.process.shellPid
        XCTAssertTrue(view.process.running)
        workspace.cycleTab(by: -1)
        XCTAssertTrue(view.process.running)
        workspace.closeTab(session.id)
        XCTAssertTrue(session.isClosed)
        try await waitUntil { kill(pid, 0) == -1 && errno == ESRCH }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "Expected state did not arrive")
    }
}

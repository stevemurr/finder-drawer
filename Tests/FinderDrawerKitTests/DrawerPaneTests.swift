import AppKit
import XCTest
@testable import FinderDrawerKit

@MainActor
final class DrawerPaneTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var workspace: DrawerWorkspace!

    override func setUpWithError() throws {
        suite = "pane-tests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspace = try DrawerWorkspace(databaseURL: root.appendingPathComponent("index.sqlite3"), defaults: defaults,
                                       initialFolders: [root], restoresFolders: false)
    }
    override func tearDownWithError() throws {
        workspace.stop()
        workspace = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testSplitBrowsersKeepIndependentLocationsAndSelection() async throws {
        let folder = try makeFolder("Other")
        let left = try XCTUnwrap(workspace.browser)
        workspace.splitPane(terminal: false)
        let right = try XCTUnwrap(workspace.browser)
        XCTAssertTrue(workspace.isSplit)
        XCTAssertFalse(left === right)
        right.setRoot(folder)
        workspace.focusPane(.primary)
        XCTAssertTrue(workspace.browser === left)
        XCTAssertEqual(left.currentRoot?.path, root.path)
        XCTAssertEqual(right.currentRoot?.path, folder.path)
        workspace.perform(.focusOtherPane)
        XCTAssertTrue(workspace.browser === right)
    }

    func testMixedAndTerminalSplitsNeverMountTheSameSessionTwice() throws {
        let first = try XCTUnwrap(workspace.selectedTabID)
        workspace.splitPane(terminal: true)
        let shell = try XCTUnwrap(workspace.terminal)
        XCTAssertEqual(workspace.tab(in: .primary)?.id, first)
        XCTAssertTrue(workspace.tab(in: .secondary)?.terminal === shell)
        workspace.selectTab(first)
        XCTAssertEqual(workspace.tab(in: .primary)?.id, first)
        XCTAssertTrue(workspace.tab(in: .secondary)?.terminal === shell)
        XCTAssertEqual(workspace.activePane, .primary)
        workspace.closeSplit()
        workspace.selectTab(shell.id)
        workspace.splitPane(terminal: true)
        let secondShell = try XCTUnwrap(workspace.terminal)
        XCTAssertFalse(secondShell === shell)
        XCTAssertTrue(workspace.tab(in: .primary)?.terminal === shell)
        workspace.closeSplit()
        XCTAssertFalse(workspace.isSplit)
        XCTAssertTrue(workspace.terminal === secondShell)
        XCTAssertFalse(shell.isClosed, "Single-pane mode keeps dormant tabs and their shells alive")
    }

    func testClosingVisibleTabRepairsPaneAssignments() throws {
        workspace.splitPane(terminal: true)
        let terminal = try XCTUnwrap(workspace.terminal)
        workspace.closeTab(terminal.id)
        XCTAssertTrue(terminal.isClosed)
        XCTAssertFalse(workspace.isSplit)
        XCTAssertNotNil(workspace.browser)
        XCTAssertEqual(workspace.activePane, .primary)
    }

    func testNewTabOpensSingleAndPreservesThePair() throws {
        workspace.splitPane(terminal: true)
        let left = workspace.tab(in: .primary)?.id
        let oldRight = workspace.tab(in: .secondary)?.id
        let pair = try XCTUnwrap(workspace.selectedGroupID)
        workspace.newTab(at: root)
        XCTAssertFalse(workspace.isSplit)
        XCTAssertEqual(workspace.tabGroups.count, 2)
        XCTAssertTrue(workspace.tabs.contains { $0.id == oldRight })
        workspace.selectGroup(pair)
        XCTAssertEqual(workspace.tab(in: .primary)?.id, left)
        XCTAssertEqual(workspace.tab(in: .secondary)?.id, oldRight)
    }

    func testSplitAssignmentAndActivePaneRestore() throws {
        workspace.splitPane(terminal: true)
        workspace.focusPane(.primary)
        workspace.persistTabs()
        workspace.stop()
        workspace = try DrawerWorkspace(databaseURL: root.appendingPathComponent("restored.sqlite3"), defaults: defaults)
        XCTAssertTrue(workspace.isSplit)
        XCTAssertEqual(workspace.activePane, .primary)
        XCTAssertNotNil(workspace.tab(in: .primary)?.browser)
        XCTAssertNotNil(workspace.tab(in: .secondary)?.terminal)
        XCTAssertFalse(workspace.tab(in: .secondary)?.terminal?.hasStarted ?? true)
    }

    func testActionsCannotActOnAnotherPaneAfterFocusChanges() async throws {
        let file = root.appendingPathComponent("sample.txt")
        try Data().write(to: file)
        let left = try XCTUnwrap(workspace.browser)
        try await waitUntil { left.columns.first?.entries.contains { $0.displayName == "sample.txt" } == true }
        let entry = try XCTUnwrap(left.columns.first?.entries.first { $0.displayName == "sample.txt" })
        left.select(entry.id, inColumn: 0)
        workspace.splitPane(terminal: false)
        workspace.focusPane(.primary)
        workspace.presentActions()
        workspace.actionQuery = "rename"
        workspace.focusPane(.secondary, requestFocus: false)
        workspace.executeSelectedAction()
        XCTAssertNil(left.renamingURL)
        XCTAssertNil(workspace.browser?.renamingURL)
    }

    func testPaletteModesDoNotReplaceOrRerootVisibleBrowsers() {
        let tab = workspace.selectedTabID
        workspace.beginSearch()
        XCTAssertTrue(workspace.isPalettePresented)
        XCTAssertEqual(workspace.selectedTabID, tab)
        workspace.perform(.goToFolder)
        XCTAssertFalse(workspace.isSearchPresented)
        XCTAssertTrue(workspace.isLocationPresented)
        XCTAssertEqual(workspace.locations.query, "")
        workspace.presentActions()
        XCTAssertTrue(workspace.isActionsPresented)
        XCTAssertFalse(workspace.isLocationPresented)
        workspace.dismissPalette()
        XCTAssertFalse(workspace.isPalettePresented)
    }

    func testLocationPickerFuzzilyFindsRecentsAndOpensExactUnindexedPath() async throws {
        let folder = try makeFolder("Personal Documents")
        workspace.locations.remember(folder)
        workspace.beginLocations()
        workspace.locations.query = "prsdoc"
        await workspace.locations.refresh(index: workspace.index)
        XCTAssertEqual(workspace.locations.visibleSuggestions.first?.path, folder.path)
        workspace.openSelectedLocation()
        XCTAssertEqual(workspace.browser?.currentRoot?.path, folder.path)
        XCTAssertFalse(workspace.isPalettePresented)
        workspace.beginLocations()
        workspace.locations.query = root.path
        // Return immediately, before async suggestions: it must open the typed path.
        workspace.openSelectedLocation()
        XCTAssertEqual(workspace.browser?.currentRoot?.path, root.path)
    }

    func testInvalidPathKeepsPaletteOpenWithErrorAndTabCompletesFolder() async throws {
        let folder = try makeFolder("Documents")
        workspace.beginLocations()
        workspace.locations.query = root.appendingPathComponent("Doc").path
        await workspace.locations.refresh(index: workspace.index)
        XCTAssertEqual(workspace.locations.selectedURL?.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        let completedPath = try XCTUnwrap(workspace.locations.selectedURL).path
        workspace.locations.completeSelection()
        XCTAssertEqual(workspace.locations.query, completedPath + "/")
        workspace.locations.query = root.appendingPathComponent("missing").path
        workspace.openSelectedLocation()
        XCTAssertTrue(workspace.isLocationPresented)
        XCTAssertNotNil(workspace.locations.errorMessage)
        XCTAssertEqual(workspace.browser?.currentRoot?.path, root.path)
    }

    func testRecentPathsPersistAndAreDeduplicated() {
        workspace.locations.remember(root)
        workspace.locations.remember(root)
        let restored = DrawerLocationPicker(defaults: defaults)
        XCTAssertEqual(restored.recent.filter { $0.path == root.path }.count, 1)
        XCTAssertEqual(restored.recent.first?.path, root.path)
    }

    func testPaneMarkersResolveNativeClickCoordinates() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let left = PaneMarkerView(pane: .primary)
        left.frame = NSRect(x: 0, y: 0, width: 450, height: 500)
        let right = PaneMarkerView(pane: .secondary)
        right.frame = NSRect(x: 450, y: 0, width: 450, height: 500)
        content.addSubview(left); content.addSubview(right)
        XCTAssertEqual(PaneMarkerView.pane(at: NSPoint(x: 100, y: 200), in: content), .primary)
        XCTAssertEqual(PaneMarkerView.pane(at: NSPoint(x: 700, y: 200), in: content), .secondary)
        XCTAssertNil(left.hitTest(NSPoint(x: 100, y: 100)))
    }

    func testWidthAndHeightPersistIndependentlyAndClampInvalidSavedValues() {
        workspace.preferences.drawerWidth = 0.95
        workspace.preferences.drawerHeight = 0.5
        let restored = BrowserPreferences(defaults: defaults)
        XCTAssertEqual(restored.drawerWidth, 0.95)
        XCTAssertEqual(restored.drawerHeight, 0.5)
        defaults.set(Double.infinity, forKey: "drawerWidth")
        XCTAssertEqual(BrowserPreferences(defaults: defaults).drawerWidth, 0.8)
        XCTAssertEqual(BrowserCommand.matching(keyCode: 31, modifiers: []), .goToFolder)
        XCTAssertEqual(BrowserCommand.matching(keyCode: 42, modifiers: .command), .splitPane)
    }

    func testRapidPaletteModeSwitchFocusesTheNewNativeField() async throws {
        _ = NSApplication.shared
        let controller = try FinderDrawerController(databaseURL: root.appendingPathComponent("focus.sqlite3"),
            defaults: defaults, initialFolders: [root], restoresFolders: false)
        defer { controller.shutdown() }
        controller.workspace.preferences.animateDrawer = false
        controller.show()
        controller.workspace.beginSearch()
        try await waitUntil {
            guard let content = controller.window?.contentView,
                  let field = AppKitSearchFieldFocusLocator.field(withAccessibilityIdentifier: controller.workspace.paletteInputIdentifier, in: content) else { return false }
            return AppKitSearchFieldFocusLocator.ownsFirstResponder(field)
        }
        let searchIdentifier = controller.workspace.paletteInputIdentifier
        controller.workspace.dismissPalette()
        XCTAssertFalse(controller.window?.firstResponder is NSTextView, "Escape must immediately release the palette editor")
        controller.workspace.beginLocations()
        XCTAssertNotEqual(controller.workspace.paletteInputIdentifier, searchIdentifier)
        try await waitUntil {
            guard let content = controller.window?.contentView,
                  let field = AppKitSearchFieldFocusLocator.field(withAccessibilityIdentifier: controller.workspace.paletteInputIdentifier, in: content) else { return false }
            return field.placeholderString == "Type a path or find a recent folder…"
                && AppKitSearchFieldFocusLocator.ownsFirstResponder(field)
        }
        let content = try XCTUnwrap(controller.window?.contentView)
        let field = try XCTUnwrap(AppKitSearchFieldFocusLocator.field(withAccessibilityIdentifier: controller.workspace.paletteInputIdentifier, in: content))
        field.currentEditor()?.insertText(root.path)
        try await waitUntil { controller.workspace.locations.query == self.root.path }
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out")
    }

    /// With Metal on, a click lands on SwiftTerm's MTKView, which never takes
    /// first responder: in a split, the other terminal kept the keyboard.
    func testClickingASplitTerminalGivesItTheKeyboard() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let sessions = [TerminalSession(directory: root), TerminalSession(directory: root)]
        defer { sessions.forEach { $0.stop() } }
        let views = sessions.enumerated().map { index, session in
            session.setUsesGPU(true)
            let view = session.makeView()
            view.frame = NSRect(x: CGFloat(index) * 500, y: 0, width: 500, height: 400)
            window.contentView?.addSubview(view)
            return view
        }
        guard views.allSatisfy(\.isUsingMetalRenderer) else { throw XCTSkip("Metal renderer unavailable") }

        for (target, other) in [(views[0], views[1]), (views[1], views[0])] {
            window.makeFirstResponder(other)
            let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
            // A test window is never key, so `sendEvent` would not deliver the
            // click; hand it to whatever the click actually hits instead.
            let content = try XCTUnwrap(window.contentView)
            let hit = try XCTUnwrap(content.hitTest(content.convert(point, from: nil)))
            XCTAssertTrue(hit !== target && hit.isDescendant(of: target), "the click lands on a renderer subview")
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            hit.mouseDown(with: event)
            XCTAssertTrue(window.firstResponder === target, "the clicked terminal must take the keyboard")
        }
    }
}

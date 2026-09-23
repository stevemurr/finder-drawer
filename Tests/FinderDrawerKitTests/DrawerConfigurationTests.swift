import AppKit
import XCTest
@testable import FinderDrawerKit

@MainActor
final class DrawerConfigurationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var root: URL!

    override func setUpWithError() throws {
        suite = "drawer-configuration-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testBroadFileAccessDoesNotExpandSearchIndex() throws {
        let workspace = try DrawerWorkspace(databaseURL: root.appendingPathComponent("index.sqlite3"),
                                           defaults: defaults, initialFolders: [root],
                                           restoresFolders: false, allowsSystemWideAccess: true)
        defer { workspace.stop() }
        let outside = URL(fileURLWithPath: "/Volumes/Example/file.txt")
        XCTAssertTrue(workspace.folders.canWrite(to: outside))
        XCTAssertEqual(workspace.index.indexRoots, [root.standardizedFileURL])
        workspace.folders.allowsSystemWideAccess = false
        XCTAssertFalse(workspace.folders.canWrite(to: outside))
        XCTAssertTrue(workspace.folders.canWrite(to: root.appendingPathComponent("file.txt")))
        let restored = FolderAccessManager(defaults: defaults, allowsSystemWideAccess: true)
        XCTAssertFalse(restored.allowsSystemWideAccess)
    }

    func testRemovingLastIndexedFolderPreservesUnrestrictedBrowsing() throws {
        let workspace = try DrawerWorkspace(databaseURL: root.appendingPathComponent("index.sqlite3"),
                                           defaults: defaults, initialFolders: [root],
                                           restoresFolders: false, allowsSystemWideAccess: true)
        defer { workspace.stop() }
        let browser = workspace.browser
        workspace.removeFolder(root)
        XCTAssertTrue(workspace.index.indexRoots.isEmpty)
        XCTAssertTrue(workspace.browser === browser)
        XCTAssertTrue(workspace.folders.canWrite(to: root.appendingPathComponent("file.txt")))
    }

    func testFirstLaunchCanBrowseHomeWithoutIndexingIt() throws {
        let workspace = try DrawerWorkspace(databaseURL: root.appendingPathComponent("index.sqlite3"),
                                           defaults: defaults, allowsSystemWideAccess: true)
        defer { workspace.stop() }
        XCTAssertEqual(workspace.browser?.currentRoot, FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertTrue(workspace.index.indexRoots.isEmpty)
    }

    func testSettingsCommandRequestsIndependentWindowAndPreservesSearch() throws {
        let workspace = try DrawerWorkspace(databaseURL: root.appendingPathComponent("index.sqlite3"),
                                           defaults: defaults, initialFolders: [root], restoresFolders: false)
        defer { workspace.stop() }
        var requests = 0
        workspace.onShowSettings = { requests += 1 }
        workspace.beginSearch()
        workspace.search.searchText = "report"
        workspace.perform(.settings)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(workspace.isSearchPresented)
        XCTAssertEqual(workspace.search.searchText, "report")
        XCTAssertFalse(workspace.isLocationPresented)
    }

    func testShortcutChangeNotifiesHostAndPreferencesSurviveRelaunch() {
        let preferences = BrowserPreferences(defaults: defaults)
        var changes = 0
        preferences.onShortcutChange = { changes += 1 }
        preferences.shortcut = .controlShiftSpace
        preferences.hideOnDeactivate = false
        preferences.animateDrawer = false
        preferences.drawerHeight = 0.8
        let restored = BrowserPreferences(defaults: defaults)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(restored.shortcut, .controlShiftSpace)
        XCTAssertFalse(restored.hideOnDeactivate)
        XCTAssertFalse(restored.animateDrawer)
        XCTAssertEqual(restored.drawerHeight, 0.8)
    }

    func testDrawerAnchorsToTopOfOffsetDisplayAndFitsSmallDisplay() {
        let display = NSRect(x: -1600, y: 100, width: 1600, height: 960)
        let frame = DrawerGeometry.frame(in: display, preferredWidth: 1120, heightFraction: 0.65)
        XCTAssertEqual(frame.maxY, display.maxY)
        XCTAssertEqual(frame.midX, display.midX)
        XCTAssertTrue(display.contains(frame))
        let small = NSRect(x: 0, y: 0, width: 720, height: 400)
        XCTAssertTrue(small.contains(DrawerGeometry.frame(in: small, preferredWidth: 1120, heightFraction: 0.9)))
    }

    func testDrawerModeDefaultsOnAndWindowPreferencesSurviveRelaunch() {
        let preferences = BrowserPreferences(defaults: defaults)
        XCTAssertTrue(preferences.isDrawerEnabled)
        XCTAssertNil(preferences.lastWindowFrame)
        preferences.isDrawerEnabled = false
        preferences.lastWindowFrame = NSRect(x: -1200, y: 180, width: 900, height: 500)
        let restored = BrowserPreferences(defaults: defaults)
        XCTAssertFalse(restored.isDrawerEnabled)
        XCTAssertEqual(restored.lastWindowFrame, preferences.lastWindowFrame)
    }

    func testRegularWindowPreservesPositionThroughHideShowModeChangesAndRelaunch() throws {
        let controller = try FinderDrawerController(databaseURL: root.appendingPathComponent("window.sqlite3"),
                                                    defaults: defaults, initialFolders: [root], restoresFolders: false)
        defer { controller.shutdown() }
        let window = try XCTUnwrap(controller.window)
        let preferences = controller.workspace.preferences
        preferences.isDrawerEnabled = false
        // Leave animation enabled: regular windows must still hide without sliding.
        controller.show()
        let area = try XCTUnwrap(window.screen).visibleFrame
        let movedFrame = NSRect(x: area.minX + 30, y: area.minY + 25, width: 800, height: 450)
        window.setFrame(movedFrame, display: false)
        let actualFrame = window.frame
        controller.hide()
        XCTAssertFalse(window.isVisible)
        XCTAssertEqual(window.frame, actualFrame)
        controller.show()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.frame, actualFrame)

        preferences.isDrawerEnabled = true
        preferences.animateDrawer = false
        controller.hide()
        controller.show()
        let pointerScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        let drawerArea = try XCTUnwrap(pointerScreen).visibleFrame
        let expectedDrawerFrame = DrawerGeometry.frame(in: drawerArea,
                                                       preferredWidth: drawerArea.width * preferences.drawerWidth,
                                                       heightFraction: preferences.drawerHeight)
        // AppKit aligns the frame to the display's backing pixels.
        XCTAssertEqual(window.frame.minX, expectedDrawerFrame.minX, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, expectedDrawerFrame.maxY, accuracy: 1)
        XCTAssertEqual(window.frame.width, expectedDrawerFrame.width, accuracy: 1)
        XCTAssertEqual(window.frame.height, expectedDrawerFrame.height, accuracy: 1)

        preferences.isDrawerEnabled = false
        window.setFrame(actualFrame, display: false)
        controller.shutdown()
        let restored = try FinderDrawerController(databaseURL: root.appendingPathComponent("restored-window.sqlite3"),
                                                  defaults: defaults, initialFolders: [root], restoresFolders: false)
        defer { restored.shutdown() }
        restored.show()
        XCTAssertEqual(restored.window?.frame, actualFrame)
    }

    func testRestoringWindowKeepsItsDisplayAndRecoversDisconnectedDisplays() {
        let main = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let other = NSRect(x: -1600, y: 100, width: 1600, height: 960)
        let frame = NSRect(x: -1500, y: 180, width: 900, height: 500)
        XCTAssertEqual(DrawerGeometry.restoredFrame(frame, in: [main, other], fallback: main), frame)
        let recovered = DrawerGeometry.restoredFrame(frame, in: [main], fallback: main)
        XCTAssertTrue(main.contains(recovered))
        XCTAssertEqual(recovered.size, frame.size)
        let oversized = NSRect(x: -100, y: -100, width: 2000, height: 1200)
        XCTAssertEqual(DrawerGeometry.restoredFrame(oversized, in: [main], fallback: main), main)
    }

    func testFullWidthDrawerReachesBothUsableScreenEdges() {
        let display = NSRect(x: -1600, y: 100, width: 1600, height: 960)
        let frame = DrawerGeometry.frame(in: display, preferredWidth: display.width, heightFraction: 0.65)
        XCTAssertEqual(frame.minX, display.minX)
        XCTAssertEqual(frame.maxX, display.maxX)
        XCTAssertEqual(frame.width, display.width)
    }
}

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
}

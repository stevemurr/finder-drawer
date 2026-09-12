import AppKit
import XCTest
@testable import FinderDrawerKit

@MainActor
final class DrawerWorkspaceTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var workspace: DrawerWorkspace!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("drawer-workspace-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "drawer-workspace-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        workspace = try DrawerWorkspace(
            databaseURL: root.appendingPathComponent("index.sqlite3"),
            defaults: defaults,
            initialFolders: [root],
            restoresFolders: false
        )
    }

    override func tearDownWithError() throws {
        workspace.stop()
        workspace = nil
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testSearchResultRevealsFileInColumnBrowser() async throws {
        let folder = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("report.txt")
        try Data("hello".utf8).write(to: file)
        workspace.beginSearch()
        workspace.reveal(FileSearchResult.fixture(url: file))

        try await waitUntil { self.workspace.browser?.focusedEntry?.url.standardizedFileURL == file.standardizedFileURL }
        XCTAssertFalse(workspace.isSearchPresented)
        XCTAssertEqual(workspace.browser?.columns.count, 2)
    }

    func testTabsKeepIndependentNavigationAndPersistRoots() throws {
        let first = try XCTUnwrap(workspace.browser)
        let folder = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        workspace.newTab(at: folder)
        let second = try XCTUnwrap(workspace.browser)
        XCTAssertFalse(first === second)
        XCTAssertEqual(first.currentRoot?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(second.currentRoot?.standardizedFileURL, folder.standardizedFileURL)
        workspace.selectTab(first.id)
        XCTAssertTrue(workspace.browser === first)
        XCTAssertEqual(defaults.stringArray(forKey: "browserTabRoots"), [root.path, folder.path])
    }

    func testRemovingRootRevokesWritesAndSearchResults() async throws {
        try await workspace.index.database.beginRebuild()
        try await workspace.index.database.insert([
            IndexedFile(path: root.appendingPathComponent("report.txt").path, name: "report.txt",
                        contentType: "public.plain-text", size: 1, createdAt: nil, modifiedAt: nil),
        ])
        try await workspace.index.database.finishRebuild()
        workspace.search.searchText = "report"
        try await waitUntil { !self.workspace.search.isSearching }
        XCTAssertEqual(workspace.search.results.count, 1)

        workspace.removeFolder(root)

        XCTAssertTrue(workspace.search.results.isEmpty)
        XCTAssertFalse(workspace.folders.canWrite(to: root.appendingPathComponent("new.txt")))
        XCTAssertNil(workspace.browser?.currentRoot)
    }

    func testResultSelectionFollowsNewResultsAndClampsNavigation() async throws {
        try await workspace.index.database.beginRebuild()
        try await workspace.index.database.insert([
            IndexedFile(path: root.appendingPathComponent("report.txt").path, name: "report.txt",
                        contentType: "public.plain-text", size: 1, createdAt: nil, modifiedAt: nil),
        ])
        try await workspace.index.database.finishRebuild()
        workspace.search.searchText = "report"
        try await waitUntil { !self.workspace.search.isSearching }
        workspace.resultsDidChange()
        workspace.moveResultSelection(by: 10)
        XCTAssertEqual(workspace.selectedResult?.displayName, "report.txt")
        workspace.search.searchText = "missing"
        try await waitUntil { !self.workspace.search.isSearching }
        workspace.resultsDidChange()
        XCTAssertNil(workspace.selectedResult)
    }

    func testClosingLastTabRequestsHideWithoutDestroyingBrowser() throws {
        let browser = try XCTUnwrap(workspace.browser)
        var didHide = false
        workspace.onHide = { didHide = true }
        workspace.closeTab(browser.id)
        XCTAssertTrue(didHide)
        XCTAssertTrue(workspace.browser === browser)
    }

    func testNewTabLeavesSearchAndRetainsItsQuery() {
        workspace.beginSearch()
        workspace.search.searchText = "report"
        workspace.newTab()
        XCTAssertFalse(workspace.isSearchPresented)
        XCTAssertEqual(workspace.search.searchText, "report")
        XCTAssertEqual(workspace.tabs.count, 2)
    }

    func testRestoringTabsKeepsTheSelectedTab() throws {
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let firstID = try XCTUnwrap(workspace.browser?.id)
        workspace.newTab(at: second)
        workspace.selectTab(firstID)
        workspace.stop()
        workspace = try DrawerWorkspace(databaseURL: root.appendingPathComponent("restored.sqlite3"), defaults: defaults)

        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.browser?.currentRoot?.standardizedFileURL, root.standardizedFileURL)
        XCTAssertEqual(defaults.integer(forKey: "selectedBrowserTab"), 0)
    }

    func testShutdownDoesNotErasePersistedTabsOnRepeatedCallbacks() {
        let expected = defaults.stringArray(forKey: "browserTabRoots")
        workspace.stop()
        workspace.persistTabs()
        workspace.stop()
        XCTAssertEqual(defaults.stringArray(forKey: "browserTabRoots"), expected)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Expected workspace state did not arrive")
    }
}

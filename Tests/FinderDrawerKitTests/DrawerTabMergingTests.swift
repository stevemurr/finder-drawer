import AppKit
import XCTest
@testable import FinderDrawerKit

@MainActor
final class DrawerTabMergingTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var workspace: DrawerWorkspace!

    override func setUpWithError() throws {
        suite = "tab-merge-tests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspace = try makeWorkspace(restoring: false)
    }

    override func tearDownWithError() throws {
        workspace.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testMergeKeepsStripOrderAndBothLiveSessionsInEitherDragDirection() throws {
        let browser = try XCTUnwrap(workspace.browser)
        workspace.newTerminal(at: root)
        let terminal = try XCTUnwrap(workspace.terminal)
        terminal.startIfNeeded(executable: "/bin/sh", arguments: ["-c", "read value"])
        let pid = try XCTUnwrap(terminal.terminalView?.process.shellPid)
        workspace.newTab(at: root)
        let untouched = try XCTUnwrap(workspace.selectedGroupID)

        for sourceIndex in [0, 1] {
            let groups = workspace.tabGroups
            let source = groups[sourceIndex], target = groups[1 - sourceIndex]
            XCTAssertTrue(workspace.mergeGroups(source.id, into: target.id))
            XCTAssertEqual(workspace.tabGroups.map(\.id), [target.id, untouched])
            XCTAssertEqual(workspace.selectedGroup?.memberIDs, [browser.id, terminal.id])
            XCTAssertEqual(workspace.selectedTabID, source.primaryID)
            XCTAssertTrue(workspace.tab(withID: browser.id)?.browser === browser)
            XCTAssertTrue(workspace.tab(withID: terminal.id)?.terminal === terminal)
            XCTAssertEqual(terminal.terminalView?.process.shellPid, pid)
            XCTAssertEqual(terminal.terminalView?.process.running, true)
            XCTAssertEqual(workspace.tabs.count, 3)
            workspace.unpairGroup(target.id)
            XCTAssertEqual(workspace.tabGroups.prefix(2).map(\.primaryID), [browser.id, terminal.id])
        }
    }

    func testMergeRejectsNonNeighborsPairsAndMissingGroupsWithoutChangingSelection() throws {
        workspace.newTab(at: root)
        workspace.newTab(at: root)
        let ids = workspace.tabGroups.map(\.id)
        let selected = workspace.selectedGroupID
        XCTAssertFalse(workspace.mergeGroups(ids[0], into: ids[2]))
        XCTAssertFalse(workspace.mergeGroups(ids[0], into: ids[0]))
        XCTAssertFalse(workspace.mergeGroups(UUID(), into: ids[1]))
        XCTAssertFalse(workspace.mergeGroups(ids[0], into: UUID()))
        XCTAssertEqual(workspace.tabGroups.map(\.id), ids)
        XCTAssertEqual(workspace.selectedGroupID, selected)

        workspace.splitPane(terminal: false)
        let pair = try XCTUnwrap(workspace.selectedGroup)
        XCTAssertFalse(workspace.mergeGroups(ids[1], into: pair.id))
        XCTAssertFalse(workspace.mergeGroups(pair.id, into: ids[1]))
        XCTAssertEqual(workspace.selectedGroup?.memberIDs, pair.memberIDs)
        XCTAssertEqual(workspace.tabs.count, 4)
    }

    func testPreviewReactsToEntryExitAndReentryWithoutMutatingWorkspace() throws {
        workspace.newTab(at: root)
        let groups = workspace.tabGroups, saved = defaults.data(forKey: "drawerTabGroups")
        let state = dragState(groups: groups, source: 0)
        state.location = CGPoint(x: 230, y: 24)
        XCTAssertEqual(state.mergeTarget(in: groups), groups[1].id)
        state.location.y = 50
        XCTAssertNil(state.mergeTarget(in: groups), "Strip tolerance must not extend the merge target")
        state.location = CGPoint(x: 320, y: 24)
        XCTAssertNil(state.mergeTarget(in: groups))
        state.location = CGPoint(x: 230, y: 24)
        XCTAssertEqual(state.mergeTarget(in: groups), groups[1].id)
        XCTAssertEqual(workspace.tabGroups.map(\.id), groups.map(\.id))
        XCTAssertEqual(defaults.data(forKey: "drawerTabGroups"), saved)
        state.cancel()
        XCTAssertNil(state.mergeTarget(in: groups))
        XCTAssertEqual(state.translation, .zero)
    }

    func testReleaseMergesAndRestoresPairWithDraggedPaneFocused() throws {
        workspace.newTerminal(at: root)
        let state = dragState(groups: workspace.tabGroups, source: 1)
        state.location = CGPoint(x: 80, y: 24)
        XCTAssertTrue(state.finish(in: workspace))
        XCTAssertTrue(workspace.isSplit)
        XCTAssertNotNil(workspace.tab(in: .primary)?.browser)
        XCTAssertNotNil(workspace.tab(in: .secondary)?.terminal)
        XCTAssertEqual(workspace.activePane, .secondary)
        XCTAssertNil(state.sourceID)
        XCTAssertEqual(state.translation, .zero)
        workspace.stop()
        workspace = try makeWorkspace(restoring: true)
        XCTAssertEqual(workspace.tabGroups.count, 1)
        XCTAssertTrue(workspace.isSplit)
        XCTAssertNotNil(workspace.tab(in: .primary)?.browser)
        XCTAssertNotNil(workspace.tab(in: .secondary)?.terminal)
        XCTAssertEqual(workspace.activePane, .secondary)
    }

    func testReleaseOutsideStripCancelsAndReleaseAtEdgeStillReorders() {
        workspace.newTab(at: root)
        let groups = workspace.tabGroups
        let state = dragState(groups: groups, source: 0)
        state.location = CGPoint(x: 230, y: 24)
        XCTAssertNotNil(state.mergeTarget(in: groups))
        state.location.y = 90
        XCTAssertFalse(state.finish(in: workspace))
        XCTAssertEqual(workspace.tabGroups.map(\.id), groups.map(\.id))
        XCTAssertNil(state.sourceID)

        state.sourceID = groups[0].id
        state.location = CGPoint(x: 310, y: 24)
        XCTAssertNil(state.mergeTarget(in: groups))
        XCTAssertTrue(state.finish(in: workspace))
        XCTAssertEqual(workspace.tabGroups.map(\.id), groups.reversed().map(\.id))
        XCTAssertTrue(workspace.tabGroups.allSatisfy { $0.secondaryID == nil })
    }

    func testOnlyAdjacentSinglesCanShowPreviewAndSourceSlotDoesNotTargetItself() {
        var groups = (0..<3).map { _ in DrawerTabGroup(primaryID: UUID()) }
        let state = dragState(groups: groups, source: 0)
        state.location = CGPoint(x: 80, y: 24)
        XCTAssertNil(state.mergeTarget(in: groups))
        state.location = CGPoint(x: 400, y: 24)
        XCTAssertNil(state.mergeTarget(in: groups))
        state.location = CGPoint(x: 230, y: 24)
        XCTAssertNotNil(state.mergeTarget(in: groups))
        groups[1].secondaryID = UUID()
        XCTAssertNil(state.mergeTarget(in: groups))
        state.sourceID = groups[1].id
        state.location = CGPoint(x: 80, y: 24)
        XCTAssertNil(state.mergeTarget(in: groups))
    }

    private func dragState(groups: [DrawerTabGroup], source: Int) -> DrawerTabDragState {
        let state = DrawerTabDragState()
        state.frames = Dictionary(uniqueKeysWithValues: groups.enumerated().map { index, group in
            (group.id, CGRect(x: 8 + index * 156, y: 7, width: 150, height: 34))
        })
        state.sourceID = groups[source].id
        state.translation = CGSize(width: 120, height: 0)
        return state
    }

    private func makeWorkspace(restoring: Bool) throws -> DrawerWorkspace {
        try DrawerWorkspace(databaseURL: root.appendingPathComponent("index.sqlite3"),
                            defaults: defaults, initialFolders: [root], restoresFolders: restoring)
    }
}

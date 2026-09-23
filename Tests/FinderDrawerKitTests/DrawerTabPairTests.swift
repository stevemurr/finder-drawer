import AppKit
import XCTest
@testable import FinderDrawerKit

@MainActor
final class DrawerTabPairTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var workspace: DrawerWorkspace!

    override func setUpWithError() throws {
        suite = "tab-pair-tests-\(UUID())"
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

    func testMultiplePairsSwitchAndCycleAsUnitsWithRememberedPaneFocus() throws {
        workspace.splitPane(terminal: true)
        let first = try XCTUnwrap(workspace.selectedGroup)
        workspace.focusPane(.primary)
        workspace.newTerminal(at: root)
        workspace.splitPane(terminal: true)
        let second = try XCTUnwrap(workspace.selectedGroup)
        XCTAssertEqual(workspace.tabs.count, 4)
        XCTAssertEqual(workspace.tabGroups.count, 2)
        workspace.cycleTab(by: 1)
        XCTAssertEqual(workspace.selectedGroupID, first.id)
        XCTAssertEqual(workspace.primaryTabID, first.primaryID)
        XCTAssertEqual(workspace.secondaryTabID, first.secondaryID)
        XCTAssertEqual(workspace.activePane, .primary)
        workspace.cycleTab(by: -1)
        XCTAssertEqual(workspace.selectedGroupID, second.id)
        XCTAssertEqual(workspace.secondaryTabID, second.secondaryID)
        XCTAssertEqual(workspace.activePane, .secondary)
        workspace.selectTab(first.secondaryID!)
        XCTAssertEqual(workspace.selectedGroupID, first.id)
        XCTAssertEqual(workspace.primaryTabID, first.primaryID, "Focusing a member must not swap the pair")
        XCTAssertEqual(workspace.activePane, .secondary)
    }

    func testExplicitSplitShortcutsChoosePaneTypeAndPreserveExistingPair() throws {
        XCTAssertEqual(BrowserCommand.matching(keyCode: 2, modifiers: .command), .splitTerminal)
        XCTAssertEqual(BrowserCommand.matching(keyCode: 1, modifiers: .command), .splitFiles)
        XCTAssertEqual(BrowserCommand.matching(keyCode: 2, modifiers: [.command, .shift]), .duplicate)
        workspace.perform(.splitTerminal)
        XCTAssertNotNil(workspace.tab(in: .primary)?.browser)
        XCTAssertNotNil(workspace.tab(in: .secondary)?.terminal)
        let pair = try XCTUnwrap(workspace.selectedGroup)
        workspace.perform(.splitFiles)
        XCTAssertEqual(workspace.selectedGroup?.memberIDs, pair.memberIDs)
        workspace.closeSplit()
        workspace.perform(.splitFiles)
        XCTAssertNotNil(workspace.tab(in: .primary)?.terminal)
        XCTAssertNotNil(workspace.tab(in: .secondary)?.browser)
        workspace.closeSplit()
        workspace.perform(.splitFiles)
        XCTAssertNotNil(workspace.tab(in: .primary)?.browser)
        XCTAssertNotNil(workspace.tab(in: .secondary)?.browser)
    }

    func testReorderMovesPairsAsUnitsWithoutChangingSelectionOrSessions() throws {
        let first = try XCTUnwrap(workspace.selectedGroupID)
        workspace.newTerminal(at: root)
        workspace.perform(.splitFiles)
        let pair = try XCTUnwrap(workspace.selectedGroup)
        let shell = try XCTUnwrap(workspace.tab(withID: pair.primaryID)?.terminal)
        shell.startIfNeeded(executable: "/bin/sh", arguments: ["-c", "read value"])
        let pid = shell.terminalView?.process.shellPid
        workspace.newTab(at: root)
        let last = try XCTUnwrap(workspace.selectedGroupID)
        workspace.selectGroup(pair.id)
        XCTAssertTrue(workspace.moveGroup(pair.id, relativeTo: first))
        XCTAssertEqual(workspace.tabGroups.map(\.id), [pair.id, first, last])
        XCTAssertEqual(workspace.selectedGroupID, pair.id)
        XCTAssertEqual(workspace.selectedGroup?.focusedID, pair.focusedID)
        XCTAssertEqual(workspace.selectedGroup?.memberIDs, pair.memberIDs)
        XCTAssertTrue(workspace.tab(withID: pair.primaryID)?.terminal === shell)
        XCTAssertEqual(shell.terminalView?.process.shellPid, pid)
        XCTAssertTrue(shell.terminalView?.process.running == true)
        XCTAssertTrue(workspace.moveGroup(pair.id, relativeTo: last, after: true))
        XCTAssertEqual(workspace.tabGroups.map(\.id), [first, last, pair.id])
        XCTAssertTrue(workspace.moveGroup(first, relativeTo: nil))
        XCTAssertEqual(workspace.tabGroups.map(\.id), [last, pair.id, first])
        workspace.moveGroup(first, by: -1)
        XCTAssertEqual(workspace.tabGroups.map(\.id), [last, first, pair.id])
    }

    func testReorderedGroupsAndFocusedMemberRestoreInDisplayOrder() throws {
        workspace.perform(.splitTerminal)
        let pair = try XCTUnwrap(workspace.selectedGroupID)
        workspace.newTerminal(at: root)
        workspace.newTab(at: root)
        workspace.moveGroup(pair, relativeTo: nil)
        workspace.selectGroup(pair)
        workspace.stop()
        workspace = try makeWorkspace(restoring: true)
        XCTAssertEqual(workspace.tabGroups.map { $0.memberIDs.count }, [1, 1, 2])
        XCTAssertNotNil(workspace.tab(withID: workspace.tabGroups[0].primaryID)?.terminal)
        XCTAssertNotNil(workspace.tab(withID: workspace.tabGroups[1].primaryID)?.browser)
        XCTAssertEqual(workspace.selectedGroupID, workspace.tabGroups[2].id)
        XCTAssertEqual(workspace.activePane, .secondary)
        XCTAssertNotNil(workspace.terminal)
    }

    func testStaleOrSelfDropsLeaveOrderAndSelectionIntact() throws {
        workspace.newTab(at: root)
        let ids = workspace.tabGroups.map(\.id)
        let selected = workspace.selectedGroupID
        XCTAssertFalse(workspace.moveGroup(UUID(), relativeTo: ids[0]))
        XCTAssertFalse(workspace.moveGroup(ids[0], relativeTo: UUID()))
        XCTAssertFalse(workspace.moveGroup(ids[0], relativeTo: ids[0]))
        XCTAssertFalse(workspace.moveGroup(ids[0], relativeTo: ids[1]))
        workspace.moveGroup(ids[0], by: -1)
        XCTAssertEqual(workspace.tabGroups.map(\.id), ids)
        XCTAssertEqual(workspace.selectedGroupID, selected)
    }

    func testDragDestinationUsesWholePairWidthAndSupportsBothEnds() {
        let groups = (0..<3).map { _ in DrawerTabGroup(primaryID: UUID()) }
        let state = DrawerTabDragState()
        state.frames = [
            groups[0].id: CGRect(x: 8, y: 7, width: 150, height: 34),
            groups[1].id: CGRect(x: 164, y: 7, width: 340, height: 34),
            groups[2].id: CGRect(x: 510, y: 7, width: 150, height: 34),
        ]
        state.sourceID = groups[2].id
        state.location = CGPoint(x: 20, y: 24)
        XCTAssertEqual(state.destination(in: groups), groups[0].id)
        XCTAssertTrue(state.isInsideStrip)
        state.location.x = 280
        XCTAssertEqual(state.destination(in: groups), groups[1].id)
        state.location.x = 400
        XCTAssertNil(state.destination(in: groups))
        state.sourceID = groups[1].id
        state.location.x = 690
        XCTAssertNil(state.destination(in: groups))
        state.location.y = 100
        XCTAssertFalse(state.isInsideStrip)
        state.cancel()
        XCTAssertNil(state.sourceID)
        XCTAssertFalse(state.isInsideStrip)
    }

    func testUnpairKeepsBothSessionsAliveAndMakesAdjacentSingles() throws {
        workspace.newTerminal(at: root)
        let left = try XCTUnwrap(workspace.terminal)
        left.startIfNeeded(executable: "/bin/sh", arguments: ["-c", "read value"])
        workspace.splitPane(terminal: true)
        let right = try XCTUnwrap(workspace.terminal)
        right.startIfNeeded(executable: "/bin/sh", arguments: ["-c", "read value"])
        let leftPID = left.terminalView?.process.shellPid
        let rightPID = right.terminalView?.process.shellPid
        let pair = try XCTUnwrap(workspace.selectedGroup)
        let count = workspace.tabs.count
        workspace.unpairGroup(pair.id)
        XCTAssertFalse(workspace.isSplit)
        XCTAssertEqual(workspace.selectedTabID, right.id)
        XCTAssertEqual(workspace.tabs.count, count)
        XCTAssertTrue(workspace.tabGroups.allSatisfy { $0.secondaryID == nil })
        let leftIndex = try XCTUnwrap(workspace.tabGroups.firstIndex { $0.primaryID == left.id })
        XCTAssertEqual(workspace.tabGroups[leftIndex + 1].primaryID, right.id)
        XCTAssertTrue(workspace.tab(withID: left.id)?.terminal === left)
        XCTAssertTrue(workspace.terminal === right)
        XCTAssertFalse(left.isClosed)
        XCTAssertFalse(right.isClosed)
        XCTAssertEqual(left.terminalView?.process.shellPid, leftPID)
        XCTAssertEqual(right.terminalView?.process.shellPid, rightPID)
        XCTAssertEqual(left.terminalView?.process.running, true)
        XCTAssertEqual(right.terminalView?.process.running, true)
    }

    func testUnpairBackgroundPairDoesNotChangeVisibleTab() throws {
        workspace.splitPane(terminal: true)
        let pair = try XCTUnwrap(workspace.selectedGroupID)
        workspace.newTab(at: root)
        let selected = workspace.selectedTabID
        let selectedGroup = workspace.selectedGroupID
        workspace.unpairGroup(pair)
        XCTAssertEqual(workspace.selectedGroupID, selectedGroup)
        XCTAssertEqual(workspace.selectedTabID, selected)
        XCTAssertEqual(workspace.tabGroups.count, 3)
    }

    func testClosePairClosesBothShellsAndPreservesOtherGroups() throws {
        let files = workspace.selectedTabID
        workspace.newTerminal(at: root)
        let left = try XCTUnwrap(workspace.terminal)
        workspace.splitPane(terminal: true)
        let right = try XCTUnwrap(workspace.terminal)
        workspace.perform(.closeTab)
        XCTAssertTrue(left.isClosed)
        XCTAssertTrue(right.isClosed)
        XCTAssertEqual(workspace.tabGroups.count, 1)
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(workspace.selectedTabID, files)
    }

    func testSplitDoesNotReplaceMemberOfAnExistingPair() throws {
        workspace.splitPane(terminal: false)
        let pair = try XCTUnwrap(workspace.selectedGroup)
        workspace.splitPane(terminal: true)
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.selectedGroup?.memberIDs, pair.memberIDs)
    }

    func testAllPairsAndActiveMembersRestoreAcrossRelaunch() throws {
        workspace.splitPane(terminal: true)
        workspace.focusPane(.primary)
        workspace.newTerminal(at: root)
        workspace.splitPane(terminal: true)
        workspace.newTab(at: root)
        workspace.selectGroup(workspace.tabGroups[1].id)
        workspace.persistTabs()
        workspace.stop()
        workspace = try makeWorkspace(restoring: true)
        XCTAssertEqual(workspace.tabs.count, 5)
        XCTAssertEqual(workspace.tabGroups.map { $0.memberIDs.count }, [2, 2, 1])
        XCTAssertEqual(workspace.selectedGroupID, workspace.tabGroups[1].id)
        XCTAssertEqual(workspace.activePane, .secondary)
        XCTAssertTrue(workspace.tabs.compactMap(\.terminal).allSatisfy { !$0.hasStarted })
        workspace.selectGroup(workspace.tabGroups[0].id)
        XCTAssertEqual(workspace.activePane, .primary)
        XCTAssertNotNil(workspace.tab(in: .primary)?.browser)
        XCTAssertNotNil(workspace.tab(in: .secondary)?.terminal)
    }

    func testLegacySplitMigratesToOnePersistentPair() throws {
        workspace.stop()
        let saved = [SavedDrawerTab(kind: .browser, path: root.path),
                     SavedDrawerTab(kind: .terminal, path: root.path),
                     SavedDrawerTab(kind: .browser, path: root.path)]
        defaults.set(try JSONEncoder().encode(saved), forKey: "drawerTabs")
        defaults.removeObject(forKey: "drawerTabGroups")
        defaults.set(0, forKey: "drawerPrimaryTab")
        defaults.set(1, forKey: "drawerSecondaryTab")
        defaults.set("secondary", forKey: "drawerActivePane")
        workspace = try makeWorkspace(restoring: true)
        XCTAssertEqual(workspace.tabGroups.map { $0.memberIDs.count }, [2, 1])
        XCTAssertTrue(workspace.isSplit)
        XCTAssertEqual(workspace.activePane, .secondary)
        XCTAssertNotNil(workspace.terminal)
    }

    func testMissingSavedMemberBecomesSingleWithoutPairingWrongTabs() throws {
        let missing = root.appendingPathComponent("removed")
        workspace.stop()
        let saved = [SavedDrawerTab(kind: .browser, path: missing.path),
                     SavedDrawerTab(kind: .terminal, path: root.path),
                     SavedDrawerTab(kind: .browser, path: root.path)]
        let groups = [SavedDrawerTabGroup(members: [0, 1], focusedMember: 1),
                      SavedDrawerTabGroup(members: [2], focusedMember: 0)]
        defaults.set(try JSONEncoder().encode(saved), forKey: "drawerTabs")
        defaults.set(try JSONEncoder().encode(groups), forKey: "drawerTabGroups")
        defaults.set(0, forKey: "selectedDrawerGroup")
        workspace = try makeWorkspace(restoring: true)
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.tabGroups.map { $0.memberIDs.count }, [1, 1])
        XCTAssertNotNil(workspace.terminal)
        XCTAssertFalse(workspace.isSplit)
    }

    private func makeWorkspace(restoring: Bool) throws -> DrawerWorkspace {
        try DrawerWorkspace(databaseURL: root.appendingPathComponent("index.sqlite3"),
                            defaults: defaults, initialFolders: [root], restoresFolders: restoring)
    }
}

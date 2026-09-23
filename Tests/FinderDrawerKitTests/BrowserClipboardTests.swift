import AppKit
import XCTest
@testable import FinderDrawerKit

@MainActor
final class BrowserClipboardTests: XCTestCase {
    private var root: URL!
    private var destination: URL!
    private var clipboard: BrowserFileClipboard!
    private var browser: BrowserViewModel!
    private var defaults: UserDefaults!
    private var suite: String!
    private var operations: BrowserFileOperations!

    override func setUpWithError() throws {
        suite = "file-clipboard-tests-\(UUID())"
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)!
        clipboard = BrowserFileClipboard(pasteboard: NSPasteboard(name: .init(suite)))
        let access = FolderAccessManager(defaults: defaults, loadStoredPaths: false, initialFolders: [root])
        operations = BrowserFileOperations(folderAccess: access)
        browser = BrowserViewModel(folderAccess: access, preferences: BrowserPreferences(defaults: defaults),
                                   quickLook: QuickLookController(), clipboard: clipboard)
    }

    override func tearDownWithError() throws {
        browser = nil
        clipboard.pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testCopyUsesFinderCompatibleFileURLsAndTextIsNotTreatedAsFiles() throws {
        let files = try [write("first.txt"), write("second.txt")]
        XCTAssertTrue(clipboard.write(files))
        let exported = clipboard.pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(exported?.map(\.path), files.map(\.path))
        XCTAssertFalse(clipboard.isCut)
        clipboard.pasteboard.clearContents()
        clipboard.pasteboard.setString(files[0].path, forType: .string)
        XCTAssertTrue(clipboard.urls.isEmpty)
    }

    func testPasteCopiesMultipleFilesAndUndoRedoPreservesTheirContents() async throws {
        let files = try [write("first.txt", "first"), write("second.txt", "second")]
        clipboard.write(files)
        try await show(destination)
        XCTAssertTrue(browser.canPerform(.paste))
        browser.perform(.paste)
        try await finishTransfer()
        for file in files { XCTAssertTrue(exists(file)); XCTAssertTrue(exists(destination.appendingPathComponent(file.lastPathComponent))) }
        XCTAssertEqual(Set(browser.focusedEntries.map(\.displayName)), ["first.txt", "second.txt"])
        browser.perform(.undo)
        XCTAssertFalse(exists(destination.appendingPathComponent("first.txt")))
        browser.perform(.redo)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("second.txt"), encoding: .utf8), "second")
    }

    func testCutDoesNotDeleteUntilPasteAndCanBeUndone() async throws {
        let file = try write("cut.txt", "keep me")
        try await show(root)
        try select("cut.txt")
        browser.perform(.cut)
        XCTAssertTrue(exists(file))
        XCTAssertTrue(clipboard.isCut)
        try await show(destination)
        browser.perform(.paste)
        try await finishTransfer()
        XCTAssertFalse(exists(file))
        let moved = destination.appendingPathComponent("cut.txt")
        XCTAssertTrue(exists(moved))
        XCTAssertEqual(clipboard.urls.map(\.path), [moved.path])
        XCTAssertFalse(clipboard.isCut)
        browser.perform(.undo)
        XCTAssertTrue(exists(file))
        XCTAssertFalse(exists(moved))
        browser.perform(.redo)
        XCTAssertTrue(exists(moved))
    }

    func testMoveHereMovesCopiedFilesWithoutCutMarker() async throws {
        let file = try write("move.txt")
        clipboard.write([file])
        try await show(destination)
        browser.perform(.moveHere)
        try await finishTransfer()
        XCTAssertFalse(exists(file))
        XCTAssertTrue(exists(destination.appendingPathComponent("move.txt")))
    }

    func testDuplicateAndSameDirectoryCopyChooseUniqueNames() throws {
        let file = try write("report.txt", "source")
        let first = try operations.duplicate([file])
        let second = try operations.copy([file], to: root)
        XCTAssertEqual(first.map(\.lastPathComponent), ["report copy.txt"])
        XCTAssertEqual(second.map(\.lastPathComponent), ["report copy 2.txt"])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "source")
    }

    func testCollisionKeepsBothFilesAndDanglingSymlink() throws {
        let file = try write("report.txt", "new")
        let existing = destination.appendingPathComponent("report.txt")
        try Data("existing".utf8).write(to: existing)
        let copied = try operations.copy([file], to: destination)
        XCTAssertEqual(copied.first?.lastPathComponent, "report 2.txt")
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
        let link = destination.appendingPathComponent("report 3.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertEqual(try operations.copy([file], to: destination).first?.lastPathComponent, "report 4.txt")
    }

    func testRecursiveDestinationsIncludingSymlinksAreRejectedBeforeAnyCopies() throws {
        let file = try write("first.txt")
        let child = destination.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: child)
        XCTAssertThrowsError(try operations.copy([file, destination], to: child))
        XCTAssertFalse(exists(child.appendingPathComponent("first.txt")))
        XCTAssertThrowsError(try operations.copy([destination], to: alias))
        XCTAssertThrowsError(try operations.copy([destination], to: destination))
    }

    func testMissingSourcePreflightDoesNotMoveEarlierFiles() throws {
        let file = try write("original.txt")
        XCTAssertThrowsError(try operations.prepareTransfer([file, root.appendingPathComponent("gone")], to: destination, mode: .move))
        XCTAssertTrue(exists(file))
        XCTAssertFalse(exists(destination.appendingPathComponent("original.txt")))
    }

    func testMoveRefusesUnauthorizedSourceWhileCopyCanImportIt() throws {
        let file = try write("original.txt")
        let restricted = BrowserFileOperations { $0.standardizedFileURL.path.hasPrefix(self.destination.standardizedFileURL.path) }
        XCTAssertThrowsError(try restricted.prepareTransfer([file], to: destination, mode: .move))
        XCTAssertTrue(exists(file))
        XCTAssertEqual(try restricted.copy([file], to: destination).count, 1)
    }

    func testRuntimeFailureReportsExactlyWhichTransfersCompleted() throws {
        let a = try write("a.txt"), b = try write("b.txt")
        let plan = try operations.prepareTransfer([a, b], to: destination, mode: .copy)
        try FileManager.default.removeItem(at: b)
        XCTAssertThrowsError(try plan.execute()) { error in
            XCTAssertEqual((error as? BrowserTransferFailure)?.completed.map(\.source.path), [a.path])
        }
        XCTAssertTrue(exists(a))
        XCTAssertTrue(exists(destination.appendingPathComponent("a.txt")))
    }

    func testUndoMoveRefusesToOverwriteNewFileAtOriginalPath() throws {
        let file = try write("original.txt", "old")
        let moved = try XCTUnwrap(operations.move([file], to: destination).first)
        let history = BrowserFileHistory()
        history.record("Move", undo: [.init(source: moved, destination: file)])
        try Data("new".utf8).write(to: file)
        XCTAssertThrowsError(try history.undo())
        XCTAssertTrue(history.canUndo)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "old")
    }

    func testNativeMenuActionsUseBrowserClipboardAndValidation() async throws {
        _ = try write("menu.txt")
        try await show(root)
        try select("menu.txt")
        let surface = BrowserColumnTableView(viewModel: browser, index: 0, column: browser.columns[0], renamingURL: nil, isFocusedColumn: true)
        let coordinator = surface.makeCoordinator()
        let table = FileColumnTableView()
        table.coordinator = coordinator
        let item = NSMenuItem(title: "Copy", action: #selector(FileColumnTableView.copy(_:)), keyEquivalent: "c")
        XCTAssertTrue(table.validateUserInterfaceItem(item))
        table.copy(nil)
        XCTAssertEqual(clipboard.urls.first?.lastPathComponent, "menu.txt")
        browser.select(nil, inColumn: 0)
        XCTAssertFalse(table.validateUserInterfaceItem(item))
    }

    func testRenameTrashAndNewFolderCanBeUndoneAndRedone() async throws {
        let file = try write("original.txt")
        try await show(root)
        browser.commitRename(file, to: "renamed.txt")
        browser.perform(.undo)
        XCTAssertTrue(exists(file))
        browser.perform(.redo)
        XCTAssertTrue(exists(root.appendingPathComponent("renamed.txt")))
        try await show(root)
        try select("renamed.txt")
        browser.perform(.moveToTrash)
        XCTAssertFalse(exists(root.appendingPathComponent("renamed.txt")))
        browser.perform(.undo)
        XCTAssertTrue(exists(root.appendingPathComponent("renamed.txt")))
        browser.perform(.redo)
        XCTAssertFalse(exists(root.appendingPathComponent("renamed.txt")))
        browser.perform(.undo) // Restore the fixture so teardown removes it.
        try await show(destination)
        browser.perform(.newFolder)
        browser.cancelRename()
        XCTAssertTrue(exists(destination.appendingPathComponent("untitled folder")))
        browser.perform(.undo)
        XCTAssertFalse(exists(destination.appendingPathComponent("untitled folder")))
        browser.perform(.redo)
        XCTAssertTrue(exists(destination.appendingPathComponent("untitled folder")))
    }

    func testUndoDoesNotTouchAReplacementAtTheSamePath() throws {
        let file = try write("original.txt")
        let history = BrowserFileHistory()
        history.record("Paste", undo: [.init(source: file, destination: nil)])
        let replacement = try write("replacement.txt", "unrelated")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)
        XCTAssertThrowsError(try history.undo())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "unrelated")
    }

    func testTransferDoesNotOverwriteNewClipboardOrChangeNewLocation() async throws {
        let file = try write("cut.txt"), newer = try write("newer.txt")
        clipboard.write([file], cut: true)
        try await show(destination)
        browser.perform(.paste)
        clipboard.write([newer])
        browser.setRoot(root)
        try await finishTransfer()
        XCTAssertEqual(clipboard.urls.map(\.path), [newer.path])
        XCTAssertEqual(browser.currentRoot?.path, root.path)
        XCTAssertTrue(browser.focusedEntries.isEmpty)
        XCTAssertTrue(exists(destination.appendingPathComponent("cut.txt")))
    }

    func testDuplicateFolderCopiesItsContentsBesideOriginal() throws {
        let folder = root.appendingPathComponent("project.v2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: folder.appendingPathComponent("file.txt"))
        let duplicate = try XCTUnwrap(operations.duplicate([folder]).first)
        XCTAssertEqual(duplicate.lastPathComponent, "project.v2 copy")
        XCTAssertEqual(try String(contentsOf: duplicate.appendingPathComponent("file.txt"), encoding: .utf8), "inside")
    }

    func testEmptySpacePasteTargetsColumnInsteadOfPreviouslySelectedFolder() async throws {
        let file = try write("sample.txt")
        clipboard.write([file])
        try await show(root)
        try select("Destination")
        let surface = BrowserColumnTableView(viewModel: browser, index: 0, column: browser.columns[0], renamingURL: nil, isFocusedColumn: true)
        let coordinator = surface.makeCoordinator()
        let menu = try XCTUnwrap(coordinator.menu(forRow: -1))
        XCTAssertTrue(menu.items.contains { ($0.representedObject as? BrowserCommand) == .paste })
        XCTAssertEqual(browser.activeDirectory?.path, root.path)
        XCTAssertTrue(browser.focusedEntries.isEmpty)
        browser.perform(.paste)
        try await finishTransfer()
        XCTAssertTrue(exists(root.appendingPathComponent("sample copy.txt")))
        XCTAssertFalse(exists(destination.appendingPathComponent("sample.txt")))
    }

    func testShortcutsMatchExpectedFileCommands() {
        for (key, command) in [(UInt16(8), BrowserCommand.copy), (7, .cut), (9, .paste), (6, .undo)] {
            XCTAssertEqual(BrowserCommand.matching(keyCode: key, modifiers: .command), command)
        }
        XCTAssertEqual(BrowserCommand.matching(keyCode: 9, modifiers: [.command, .option]), .moveHere)
        XCTAssertEqual(BrowserCommand.matching(keyCode: 2, modifiers: [.command, .shift]), .duplicate)
        XCTAssertEqual(BrowserCommand.matching(keyCode: 6, modifiers: [.command, .shift]), .redo)
    }

    private func write(_ name: String, _ text: String = "payload") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func select(_ name: String) throws {
        let entry = try XCTUnwrap(browser.columns[0].entries.first { $0.displayName == name })
        browser.select(entry.id, inColumn: 0)
    }
    private func show(_ url: URL) async throws {
        browser.setRoot(url)
        try await waitUntil { self.browser.columns.first?.isLoading == false }
    }
    private func finishTransfer() async throws {
        try await waitUntil { !self.browser.isTransferringFiles && self.browser.columns.allSatisfy { !$0.isLoading } }
        XCTAssertNil(browser.errorMessage)
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for file operation")
    }
}

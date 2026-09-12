import AppKit
import Foundation
import PDFKit
import XCTest
@testable import FinderDrawerKit

final class DirectoryListerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-lister-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFoldersSortAheadOfFiles() async throws {
        try write("zebra.txt")
        try makeDirectory("alpha")

        let entries = try await DirectoryLister().contents(of: root, showHidden: false, sort: .name)

        XCTAssertEqual(entries.map(\.displayName), ["alpha", "zebra.txt"])
        XCTAssertTrue(entries[0].isDirectory)
    }

    func testNamesSortNaturallyRatherThanLexically() async throws {
        for name in ["file10.txt", "file2.txt", "file1.txt"] { try write(name) }

        let entries = try await DirectoryLister().contents(of: root, showHidden: false, sort: .name)

        XCTAssertEqual(entries.map(\.displayName), ["file1.txt", "file2.txt", "file10.txt"])
    }

    func testHiddenFilesAreExcludedUnlessRequested() async throws {
        try write("visible.txt")
        try write(".hidden")

        let lister = DirectoryLister()
        let without = try await lister.contents(of: root, showHidden: false, sort: .name)
        let with = try await lister.contents(of: root, showHidden: true, sort: .name)

        XCTAssertEqual(without.map(\.displayName), ["visible.txt"])
        XCTAssertEqual(with.count, 2)
    }

    /// A bundle is a directory on disk, but the browser must treat it as a leaf
    /// the way Finder does — descending into an app would be a dead end.
    func testPackagesAreLeavesNotFolders() async throws {
        let bundle = root.appendingPathComponent("Thing.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let entries = try await DirectoryLister().contents(of: root, showHidden: false, sort: .name)

        let entry = try XCTUnwrap(entries.first)
        XCTAssertTrue(entry.isPackage)
        XCTAssertFalse(entry.isDirectory, "Descending into a package would strand the user")
    }

    func testUnreadableDirectorySurfacesATypedError() async throws {
        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)

        do {
            _ = try await DirectoryLister().contents(of: missing, showHidden: false, sort: .name)
            XCTFail("Listing a missing directory should fail")
        } catch let error as DirectoryListerError {
            guard case let .unreadable(url, _) = error else {
                return XCTFail("Expected .unreadable, got \(error)")
            }
            XCTAssertEqual(url, missing)
        }
    }

    // MARK: - Helpers

    private func write(_ name: String) throws {
        try Data("x".utf8).write(to: root.appendingPathComponent(name))
    }

    private func makeDirectory(_ name: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
}

@MainActor
final class FileChangeWatcherTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-watcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testNotifiesForInPlaceContentWrite() async throws {
        let file = directory.appendingPathComponent("resident.txt")
        try Data("before".utf8).write(to: file)
        let changed = expectation(description: "file content change")
        let watcher = FileChangeWatcher(url: file) {
            changed.fulfill()
        }

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("after".utf8))
        try handle.close()

        await fulfillment(of: [changed], timeout: 3)
        watcher.stop()
    }

    func testNotifiesAfterAtomicReplacementAndContinuesWatching() async throws {
        let file = directory.appendingPathComponent("resident.txt")
        try Data("one".utf8).write(to: file)
        let replaced = expectation(description: "atomic replacement")
        let subsequentWrite = expectation(description: "write after replacement")
        var notifications = 0
        let watcher = FileChangeWatcher(url: file) {
            notifications += 1
            if notifications == 1 {
                replaced.fulfill()
            } else if notifications == 2 {
                subsequentWrite.fulfill()
            }
        }

        try Data("two".utf8).write(to: file, options: .atomic)
        await fulfillment(of: [replaced], timeout: 3)

        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("three".utf8))
        try handle.close()

        await fulfillment(of: [subsequentWrite], timeout: 3)
        watcher.stop()
    }

    /// PDFKit updates file metadata merely by opening a document. That is not
    /// a content change, and reporting it makes the PDF preview reload itself
    /// forever: load → NOTE_ATTRIB → load.
    func testOpeningAPDFDoesNotReportAFileChange() async throws {
        let file = directory.appendingPathComponent("resident.pdf")
        try writePDF(to: file)
        let changed = expectation(description: "metadata-only PDF read")
        changed.isInverted = true
        let watcher = FileChangeWatcher(url: file) {
            changed.fulfill()
        }

        XCTAssertNotNil(PDFDocument(url: file))

        await fulfillment(of: [changed], timeout: 0.7)
        watcher.stop()
    }

    func testAttributeOnlyChangeDoesNotReportAFileChange() async throws {
        let file = directory.appendingPathComponent("resident.txt")
        try Data("unchanged".utf8).write(to: file)
        let changed = expectation(description: "attribute-only change")
        changed.isInverted = true
        let watcher = FileChangeWatcher(url: file) {
            changed.fulfill()
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let currentPermissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        ).uint16Value
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: currentPermissions ^ 0o100)],
            ofItemAtPath: file.path
        )

        await fulfillment(of: [changed], timeout: 0.7)
        watcher.stop()
    }

    private func writePDF(to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 240)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(mediaBox)
        context.endPDFPage()
        context.closePDF()
    }
}

@MainActor
final class BrowserFileOperationsTests: XCTestCase {
    private var root: URL!
    private var operations: BrowserFileOperations!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-ops-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let root = root!
        operations = BrowserFileOperations { url in
            url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testNewFolderUniquesItsNameInsteadOfFailing() throws {
        let first = try operations.newFolder(in: root)
        let second = try operations.newFolder(in: root)
        let third = try operations.newFolder(in: root)

        XCTAssertEqual(first.lastPathComponent, "untitled folder")
        XCTAssertEqual(second.lastPathComponent, "untitled folder 2")
        XCTAssertEqual(third.lastPathComponent, "untitled folder 3")
    }

    func testRenameMovesTheItem() throws {
        let file = root.appendingPathComponent("before.txt")
        try Data("x".utf8).write(to: file)

        let renamed = try operations.rename(file, to: "after.txt")

        XCTAssertEqual(renamed.lastPathComponent, "after.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testRenameRejectsNamesThatWouldEscapeTheDirectory() throws {
        let file = root.appendingPathComponent("safe.txt")
        try Data("x".utf8).write(to: file)

        for candidate in ["", "   ", "../evil", "a/b", "a:b", ".."] {
            XCTAssertThrowsError(try operations.rename(file, to: candidate),
                                 "“\(candidate)” must be rejected")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testRenameRefusesToClobberAnExistingItem() throws {
        let file = root.appendingPathComponent("a.txt")
        let other = root.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: file)
        try Data("b".utf8).write(to: other)

        XCTAssertThrowsError(try operations.rename(file, to: "b.txt")) { error in
            XCTAssertEqual(error as? BrowserFileOperationError, .alreadyExists("b.txt"))
        }
        XCTAssertEqual(try Data(contentsOf: other), Data("b".utf8))
    }

    func testTrashRemovesTheItemFromItsDirectory() throws {
        let file = root.appendingPathComponent("disposable.txt")
        try Data("x".utf8).write(to: file)

        try operations.trash([file])

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// The sandbox would deny this anyway; the gate is what turns the denial
    /// into a re-authorization prompt instead of an opaque failure.
    func testOperationsOutsideGrantedRootsAreRefusedBeforeTouchingDisk() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-ops-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }

        let file = outside.appendingPathComponent("untouched.txt")
        try Data("x".utf8).write(to: file)

        XCTAssertThrowsError(try operations.newFolder(in: outside)) { error in
            XCTAssertEqual(error as? BrowserFileOperationError, .notAuthorized(outside))
        }
        XCTAssertThrowsError(try operations.rename(file, to: "renamed.txt")) { error in
            XCTAssertEqual(error as? BrowserFileOperationError, .notAuthorized(file))
        }
        XCTAssertThrowsError(try operations.trash([file])) { error in
            XCTAssertEqual(error as? BrowserFileOperationError, .notAuthorized(file))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testMoveRelocatesAndCopyDuplicates() throws {
        let destination = try operations.newFolder(in: root, baseName: "target")
        let file = root.appendingPathComponent("payload.txt")
        try Data("x".utf8).write(to: file)

        try operations.copy([file], to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Copy must leave the source in place")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("payload.txt").path
        ))

        let second = root.appendingPathComponent("moved.txt")
        try Data("y".utf8).write(to: second)
        try operations.move([second], to: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("moved.txt").path
        ))
    }

    func testMoveFromOutsideWritableRootsCopiesWithoutRemovingSource() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-ops-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let external = outside.appendingPathComponent("external.txt")
        try Data("outside".utf8).write(to: external)
        let destination = try operations.newFolder(in: root, baseName: "target")

        let imported = try operations.move([external], to: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(try String(contentsOf: imported[0], encoding: .utf8), "outside")
    }
}

@MainActor
final class BrowserViewModelTests: XCTestCase {
    private var root: URL!
    private var viewModel: BrowserViewModel!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var fileSystemChangeCount = 0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-vm-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("file.txt"))
        try Data("y".utf8).write(to: nested.appendingPathComponent("inner.txt"))

        suiteName = "browser-vm-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        viewModel = BrowserViewModel(
            folderAccess: FolderAccessManager(
                defaults: defaults,
                loadStoredPaths: false,
                initialFolders: [root]
            ),
            preferences: BrowserPreferences(defaults: defaults),
            quickLook: QuickLookController(),
            onFileSystemChange: { [weak self] in
                self?.fileSystemChangeCount += 1
            }
        )
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func testSelectingAFolderAppendsAColumn() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)

        let folder = try XCTUnwrap(viewModel.columns[0].entries.first { $0.isDirectory })
        viewModel.select(folder.id, inColumn: 0)

        XCTAssertEqual(viewModel.columns.count, 2)
        XCTAssertEqual(viewModel.columns[1].url, folder.url)
    }

    func testSelectingAFileDoesNotAppendAColumn() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)

        let file = try XCTUnwrap(viewModel.columns[0].entries.first { !$0.isDirectory })
        viewModel.select(file.id, inColumn: 0)

        XCTAssertEqual(viewModel.columns.count, 1)
        XCTAssertEqual(viewModel.previewEntry?.url, file.url)
    }

    func testLeavingAFileSelectionCancelsItsPendingPreview() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)
        let file = try XCTUnwrap(viewModel.columns[0].entries.first { !$0.isDirectory })
        let folder = try XCTUnwrap(viewModel.columns[0].entries.first { $0.isDirectory })
        var previewed: URL?
        var cancellationCount = 0
        viewModel.onPreviewFile = { previewed = $0 }
        viewModel.onCancelPreview = { cancellationCount += 1 }

        viewModel.select(file.id, inColumn: 0)
        viewModel.select(folder.id, inColumn: 0)

        XCTAssertEqual(previewed, file.url)
        XCTAssertEqual(cancellationCount, 1)
    }

    /// Moving the selection in a parent column must discard everything to its
    /// right, or the browser would show a path that no longer exists.
    func testSelectingAShallowerRowTruncatesDeeperColumns() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)

        let folder = try XCTUnwrap(viewModel.columns[0].entries.first { $0.isDirectory })
        viewModel.select(folder.id, inColumn: 0)
        XCTAssertEqual(viewModel.columns.count, 2)

        let file = try XCTUnwrap(viewModel.columns[0].entries.first { !$0.isDirectory })
        viewModel.select(file.id, inColumn: 0)

        XCTAssertEqual(viewModel.columns.count, 1)
        XCTAssertEqual(viewModel.focusedColumnIndex, 0)
    }

    func testRerootingReleasesWatchersFromTheOldColumnPath() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)
        let folder = try XCTUnwrap(viewModel.columns[0].entries.first { $0.isDirectory })
        viewModel.select(folder.id, inColumn: 0)
        try await waitForColumn(1)
        XCTAssertEqual(viewModel.watchedDirectoryCount, 2)

        viewModel.setRoot(root)
        try await waitForColumn(0)

        XCTAssertEqual(
            viewModel.watchedDirectoryCount,
            1,
            "Re-rooting must not retain vnode sources for discarded columns"
        )
    }

    func testFocusColumnMovesFocusWithoutChangingTheParentSelection() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)

        let folder = try XCTUnwrap(viewModel.columns[0].entries.first { $0.isDirectory })
        viewModel.select(folder.id, inColumn: 0)
        try await waitForColumn(1)

        viewModel.focusColumn(by: 1)

        XCTAssertEqual(viewModel.focusedColumnIndex, 1)
        XCTAssertEqual(viewModel.columns[0].primarySelectedID, folder.id,
                       "Descending must not disturb which folder the parent column has selected")
    }

    func testFocusColumnAlsoRequestsTheRealTableResponder() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)
        let folder = try XCTUnwrap(viewModel.columns[0].entries.first { $0.isDirectory })
        viewModel.select(folder.id, inColumn: 0)
        try await waitForColumn(1)

        var focusRequests = 0
        viewModel.onRequestColumnFocus = { focusRequests += 1 }
        viewModel.focusColumn(at: 1)

        XCTAssertEqual(viewModel.focusedColumnIndex, 1)
        XCTAssertEqual(focusRequests, 1,
                       "Visual focus and AppKit first responder must move together")
    }

    func testFocusColumnStopsAtTheEdges() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)

        viewModel.focusColumn(by: -1)
        XCTAssertEqual(viewModel.focusedColumnIndex, 0)

        viewModel.focusColumn(by: 1)
        XCTAssertEqual(viewModel.focusedColumnIndex, 0, "There is no column to the right yet")
    }

    // MARK: - Multi-selection

    func testOpenWithRequiresExactlyOneSelectionAndForwardsToHost() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)
        var forwarded: [BrowserCommand] = []
        viewModel.onHostCommand = { forwarded.append($0) }

        XCTAssertFalse(viewModel.canPerform(.openWith))
        viewModel.perform(.openWith)
        XCTAssertTrue(forwarded.isEmpty)

        let file = try XCTUnwrap(viewModel.columns[0].entries.first { !$0.isDirectory })
        viewModel.select(file.id, inColumn: 0)

        XCTAssertTrue(viewModel.canPerform(.openWith))
        viewModel.perform(.openWith)
        XCTAssertEqual(forwarded, [.openWith])

        let all = Set(viewModel.columns[0].entries.map(\.id))
        viewModel.select(ids: all, primary: file.id, inColumn: 0)
        viewModel.perform(.openWith)
        XCTAssertEqual(
            forwarded,
            [.openWith],
            "A multi-selection must not be forwarded as a single Open With target"
        )
    }

    /// With several rows selected there is no single "next" folder, so the
    /// browser must not descend — otherwise a ⇧-click spanning a folder would
    /// silently open a column for it.
    func testMultiSelectionDoesNotDescendIntoAFolder() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)

        let all = Set(viewModel.columns[0].entries.map(\.id))
        let folder = try XCTUnwrap(viewModel.columns[0].entries.first { $0.isDirectory })
        viewModel.select(ids: all, primary: folder.id, inColumn: 0)

        XCTAssertEqual(viewModel.columns[0].selectedIDs, all)
        XCTAssertEqual(viewModel.columns.count, 1, "A multi-selection must not open a child column")
    }

    func testMultiSelectionHasExplicitCommandCardinality() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)
        let all = viewModel.columns[0].entries
        viewModel.select(ids: Set(all.map(\.id)), primary: all.first?.id, inColumn: 0)

        XCTAssertFalse(viewModel.canPerform(.open))
        XCTAssertFalse(viewModel.canPerform(.openWith))
        XCTAssertFalse(viewModel.canPerform(.quickLook))
        XCTAssertFalse(viewModel.canPerform(.openWith))
        XCTAssertFalse(viewModel.canPerform(.rename))
        XCTAssertTrue(viewModel.canPerform(.moveToTrash))
        XCTAssertTrue(viewModel.canPerform(.showInFinder))
        XCTAssertTrue(viewModel.canPerform(.copyPath))
        XCTAssertTrue(viewModel.canPerform(.newFolder))
        XCTAssertNil(viewModel.previewEntry,
                     "A multi-selection must not impersonate a single-file preview")
        XCTAssertEqual(viewModel.title(for: .copyPath), "Copy \(all.count) Paths")
    }

    func testContextPrimaryChangesWithoutDroppingMultiSelection() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)
        let entries = viewModel.columns[0].entries
        let selected = Set(entries.map(\.id))
        viewModel.select(ids: selected, primary: entries.first?.id, inColumn: 0)

        viewModel.makePrimary(entries.last!.id, inColumn: 0)

        XCTAssertEqual(viewModel.columns[0].selectedIDs, selected)
        XCTAssertEqual(viewModel.columns[0].primarySelectedID, entries.last?.id)
    }

    func testColumnPresentationStatesAreDistinct() {
        let url = URL(fileURLWithPath: "/tmp/example", isDirectory: true)
        var column = BrowserColumn(url: url)
        XCTAssertEqual(column.presentationState, .loading)

        column.isLoading = false
        XCTAssertEqual(column.presentationState, .empty)

        column.errorMessage = "Permission denied"
        XCTAssertEqual(column.presentationState, .error("Permission denied"))

        column.errorMessage = nil
        column.entries = [
            DirectoryEntry(
                url: url.appendingPathComponent("file.txt"),
                displayName: "file.txt",
                isDirectory: false,
                isPackage: false,
                isHidden: false,
                fileSize: 1,
                modifiedAt: nil,
                contentType: nil
            )
        ]
        XCTAssertEqual(column.presentationState, .content)
    }

    func testSingleSelectionStillDescends() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)

        let folder = try XCTUnwrap(viewModel.columns[0].entries.first { $0.isDirectory })
        viewModel.select(ids: [folder.id], primary: folder.id, inColumn: 0)

        XCTAssertEqual(viewModel.columns.count, 2)
    }

    /// A reload must not cost the user their multi-selection — external changes
    /// fire the directory watcher constantly.
    func testMultiSelectionSurvivesAColumnReload() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)

        let all = Set(viewModel.columns[0].entries.map(\.id))
        viewModel.select(ids: all, primary: all.first, inColumn: 0)

        // Re-list the same directory, as the directory watcher does on any
        // external change.
        viewModel.applyPreferenceChange()
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(viewModel.columns[0].selectedIDs, all)
    }

    func testPresentKeepsLoadedColumnsResidentInsteadOfReloadingDuringTheSlide() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)
        let entries = viewModel.columns[0].entries
        let listingRevision = viewModel.columns[0].listingRevision
        let contentRevision = viewModel.columns[0].contentRevision

        viewModel.present()

        XCTAssertFalse(viewModel.columns[0].isLoading)
        XCTAssertEqual(viewModel.columns[0].entries, entries)
        XCTAssertEqual(viewModel.columns[0].listingRevision, listingRevision)
        XCTAssertEqual(viewModel.columns[0].contentRevision, contentRevision)
    }

    func testNewFolderSelectsTheListedRowAndBeginsRename() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)

        viewModel.createFolder()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let entry = viewModel.columns[0].entries.first(where: {
                $0.displayName == "untitled folder"
            }),
               viewModel.columns[0].primarySelectedID == entry.id,
               viewModel.renamingURL == entry.id {
                XCTAssertEqual(viewModel.renameText, entry.displayName)
                XCTAssertEqual(fileSystemChangeCount, 1)
                // AppKit may echo its programmatic selection after the reload.
                // That must not open the new folder's child column and steal
                // focus from the inline editor.
                viewModel.select(ids: [entry.id], primary: entry.id, inColumn: 0)
                XCTAssertEqual(viewModel.columns.count, 1)
                XCTAssertEqual(viewModel.renamingURL, entry.id)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The created directory never became the selected rename target")
    }

    func testCancelledNewFolderRenameIsNotResurrectedByItsReload() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)

        viewModel.createFolder()
        XCTAssertNotNil(viewModel.renamingURL)
        // `createFolder` has scheduled, but not yet completed, its actor-backed
        // directory reload. This reproduces Escape/panel hide in that window.
        viewModel.cancelRename()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let created = viewModel.columns[0].entries.first(where: {
                $0.displayName == "untitled folder"
            }) {
                XCTAssertNil(
                    viewModel.renamingURL,
                    "The completed listing must not revive a cancelled editor"
                )
                XCTAssertEqual(
                    viewModel.columns[0].primarySelectedID,
                    created.id,
                    "Cancelling edit should not lose the newly created row's selection"
                )
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The created directory never appeared in the refreshed listing")
    }

    func testTrashRemovesEverySelectedRow() async throws {
        // Written before the first listing: a reload does not flip `isLoading`,
        // so waiting on it would not guarantee these had been picked up.
        for name in ["a.tmp", "b.tmp"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        viewModel.setRoot(root)
        try await waitForColumn(0)

        let doomed = viewModel.columns[0].entries.filter { $0.url.pathExtension == "tmp" }
        XCTAssertEqual(doomed.count, 2)
        viewModel.select(ids: Set(doomed.map(\.id)), primary: doomed.last?.id, inColumn: 0)

        viewModel.trashSelection()
        try await waitForColumn(0)

        for entry in doomed {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: entry.url.path),
                "\(entry.displayName) should have been trashed"
            )
        }
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(fileSystemChangeCount, 1)
    }

    func testRenameAndDropNotifyTheIndexAfterSuccessfulChanges() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)
        let file = try XCTUnwrap(viewModel.columns[0].entries.first { !$0.isDirectory })

        viewModel.commitRename(file.url, to: "renamed.txt")
        XCTAssertEqual(fileSystemChangeCount, 1)

        let renamed = root.appendingPathComponent("renamed.txt")
        let destination = root.appendingPathComponent("folder", isDirectory: true)
        viewModel.drop([renamed], into: destination, copy: true)
        XCTAssertEqual(fileSystemChangeCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("renamed.txt").path
        ))
    }

    func testUnchangedRenameDoesNotReloadOrNotifyTheIndex() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)
        let folder = try XCTUnwrap(viewModel.columns[0].entries.first { $0.isDirectory })
        viewModel.select(ids: [folder.id], primary: folder.id, inColumn: 0)
        XCTAssertEqual(viewModel.columns.count, 2)

        viewModel.beginRename()
        viewModel.commitRename(folder.url, to: folder.displayName)

        XCTAssertNil(viewModel.renamingURL)
        XCTAssertEqual(fileSystemChangeCount, 0)
        XCTAssertEqual(
            viewModel.columns.count,
            2,
            "Ending an unchanged edit must not reload and navigate again"
        )
    }

    func testRenamingAFolderKeepsSelectionInItsParentColumn() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)
        let folder = try XCTUnwrap(viewModel.columns[0].entries.first { $0.isDirectory })

        viewModel.commitRename(folder.url, to: "renamed folder")

        let renamed = root.appendingPathComponent("renamed folder", isDirectory: true)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if viewModel.columns[0].primarySelectedID?.standardizedFileURL
                == renamed.standardizedFileURL {
                XCTAssertEqual(viewModel.columns.count, 1)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The renamed folder was not restored as the parent-column selection")
    }

    func testRenameCompletionDoesNotOverrideANewerClickSelection() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)
        let file = try XCTUnwrap(viewModel.columns[0].entries.first { !$0.isDirectory })
        let folder = try XCTUnwrap(viewModel.columns[0].entries.first { $0.isDirectory })

        viewModel.select(file.id, inColumn: 0)
        viewModel.beginRename()
        viewModel.commitRename(file.url, to: "renamed.txt")
        // This is the model ordering produced by Finder-style click-away:
        // responder loss commits first, then NSTableView selects the row that
        // was actually clicked while the rename reload is in flight.
        viewModel.select(folder.id, inColumn: 0)

        let renamed = root.appendingPathComponent("renamed.txt")
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if viewModel.columns[0].entries.contains(where: {
                $0.id.standardizedFileURL == renamed.standardizedFileURL
            }) {
                XCTAssertEqual(viewModel.columns[0].primarySelectedID, folder.id)
                XCTAssertEqual(viewModel.columns.last?.url, folder.url)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The renamed file never appeared in the refreshed listing")
    }

    func testCopyPathWritesEverySelectedPath() async throws {
        viewModel.setRoot(root)
        try await waitForColumn(0)

        let all = viewModel.columns[0].entries
        viewModel.select(ids: Set(all.map(\.id)), primary: all.first?.id, inColumn: 0)
        viewModel.copySelectedPaths()

        let written = NSPasteboard.general.string(forType: .string) ?? ""
        for entry in all {
            XCTAssertTrue(written.contains(entry.url.path))
        }
    }

    /// A programmatic Navigator reveal has to land on files, not just folders —
    /// the file ends up highlighted in its parent's column.
    func testNavigatingToAFileSelectsItInItsParentColumn() async throws {
        // From the granted root rather than `root`, so the walk exercises the
        // granted-root branch — the two differ by symlink normalization.
        let base = try XCTUnwrap(viewModel.navigationRoots.first)
        let target = base
            .appendingPathComponent("folder", isDirectory: true)
            .appendingPathComponent("inner.txt")

        viewModel.navigate(to: target)
        try await waitForColumn(1)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              viewModel.columns[1].primarySelectedID?.standardizedFileURL != target.standardizedFileURL {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(viewModel.columns[0].url.standardizedFileURL, base.standardizedFileURL)
        XCTAssertEqual(
            viewModel.columns[1].primarySelectedID?.standardizedFileURL,
            target.standardizedFileURL,
            "The file itself must be selected, not merely its folder opened"
        )
        XCTAssertEqual(viewModel.focusedColumnIndex, 1)
        // A file is a leaf: revealing it must not spawn an empty child column.
        XCTAssertEqual(viewModel.columns.count, 2)
    }

    func testNavigatorOnlyFileRevealSelectsWithoutPublishingViewerPreview() async throws {
        let base = try XCTUnwrap(viewModel.navigationRoots.first)
        let target = base
            .appendingPathComponent("folder", isDirectory: true)
            .appendingPathComponent("inner.txt")
        var previewed: [URL] = []
        viewModel.onPreviewFile = { previewed.append($0) }

        viewModel.navigate(to: target, previewsFileSelection: false)
        try await waitForColumn(1)

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline,
              viewModel.columns[1].primarySelectedID?.standardizedFileURL != target.standardizedFileURL {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(
            viewModel.columns[1].primarySelectedID?.standardizedFileURL,
            target.standardizedFileURL
        )
        XCTAssertTrue(previewed.isEmpty)
        XCTAssertEqual(viewModel.previewEntry?.url.standardizedFileURL, target.standardizedFileURL)
    }

    private func waitForColumn(_ index: Int, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if viewModel.columns.indices.contains(index), !viewModel.columns[index].isLoading { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Column \(index) never finished loading")
    }
}

import AppKit
import SwiftUI
import XCTest
@testable import FinderDrawerKit

@MainActor
final class BrowserColumnSizingTests: XCTestCase {
    func testNaturalWidthTracksRenderedFilenameLength() {
        let short = BrowserColumnSizing.naturalWidth(displayNames: ["a.txt"])
        let long = BrowserColumnSizing.naturalWidth(
            displayNames: ["A substantially longer project filename.swift"]
        )

        XCTAssertGreaterThan(long, short)
        XCTAssertGreaterThanOrEqual(short, BrowserColumnSizing.minimumWidth)
        XCTAssertLessThanOrEqual(long, BrowserColumnSizing.maximumWidth)
    }

    func testOnePathologicalNameDoesNotDominateTheColumn() {
        let normal = Array(repeating: "Quarterly Report.txt", count: 9)
        let withOutlier = normal + [String(repeating: "generated-", count: 80) + ".txt"]

        XCTAssertEqual(
            BrowserColumnSizing.naturalWidth(displayNames: withOutlier),
            BrowserColumnSizing.naturalWidth(displayNames: normal),
            accuracy: 0.5,
            "The 90th percentile should ignore one pathological filename"
        )
    }

    func testLargeDirectoryMeasurementIsBoundedAndRepresentative() {
        let root = URL(fileURLWithPath: "/tmp/large", isDirectory: true)
        let entries = (0..<50_000).map { index in
            DirectoryEntry(
                url: root.appendingPathComponent("file-\(index).txt"),
                displayName: "file-\(index).txt",
                isDirectory: false,
                isPackage: false,
                isHidden: false,
                fileSize: nil,
                modifiedAt: nil,
                contentType: nil
            )
        }

        let sample = BrowserColumnSizing.representativeDisplayNames(from: entries)

        XCTAssertEqual(sample.count, BrowserColumnSizing.measurementSampleLimit)
        XCTAssertEqual(sample.first, entries.first?.displayName)
        XCTAssertEqual(sample.last, entries.last?.displayName)
    }

    func testCachedWidthHintAvoidsRemeasuringEntriesOnRender() {
        let directory = URL(fileURLWithPath: "/tmp/cached", isDirectory: true)
        var column = BrowserColumn(url: directory)
        column.naturalWidthHint = 310
        column.entries = [
            DirectoryEntry(
                url: directory.appendingPathComponent(String(repeating: "x", count: 500)),
                displayName: String(repeating: "x", count: 500),
                isDirectory: false,
                isPackage: false,
                isHidden: false,
                fileSize: nil,
                modifiedAt: nil,
                contentType: nil
            )
        ]

        let widths = BrowserColumnSizing.widths(
            for: [column],
            availableWidth: 310,
            focusedIndex: 0
        )

        XCTAssertEqual(widths, [310])
    }

    func testListingRevisionChangesOnlyWhenRowsChange() {
        let directory = URL(fileURLWithPath: "/tmp/revision", isDirectory: true)
        let file = DirectoryEntry(
            url: directory.appendingPathComponent("file.txt"),
            displayName: "file.txt",
            isDirectory: false,
            isPackage: false,
            isHidden: false,
            fileSize: nil,
            modifiedAt: nil,
            contentType: nil
        )
        var column = BrowserColumn(url: directory)

        column.entries = [file]
        let loadedRevision = column.listingRevision
        let loadedContentRevision = column.contentRevision
        column.selectedIDs = [file.id]
        column.primarySelectedID = file.id

        XCTAssertEqual(column.listingRevision, loadedRevision)
        XCTAssertEqual(column.selectedEntry, file)
        XCTAssertEqual(column.selectedEntries, [file])

        let metadataEcho = DirectoryEntry(
            url: file.url,
            displayName: file.displayName,
            isDirectory: file.isDirectory,
            isPackage: file.isPackage,
            isHidden: file.isHidden,
            fileSize: 42,
            modifiedAt: Date(),
            contentType: file.contentType
        )
        column.entries = [metadataEcho]
        XCTAssertEqual(
            column.listingRevision,
            loadedRevision,
            "A metadata-only watcher echo must not rebuild a table and end inline editing"
        )
        XCTAssertGreaterThan(
            column.contentRevision,
            loadedContentRevision,
            "Metadata changes still need to refresh visible cells"
        )
        let metadataRevision = column.contentRevision
        column.entries = [metadataEcho]
        XCTAssertEqual(
            column.contentRevision,
            metadataRevision,
            "An identical watcher echo should be ignored"
        )

        column.entries = []
        XCTAssertGreaterThan(column.listingRevision, loadedRevision)
    }

    func testCoordinatorGuardsAgainstEqualRevisionReplacementAndRefreshesMetadata() {
        let defaultsName = "listing-sync-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let directory = URL(fileURLWithPath: "/tmp/listing-sync", isDirectory: true)
        let folderAccess = FolderAccessManager(
            defaults: defaults,
            loadStoredPaths: false,
            initialFolders: [directory]
        )
        let viewModel = BrowserViewModel(
            folderAccess: folderAccess,
            preferences: BrowserPreferences(defaults: defaults),
            quickLook: QuickLookController()
        )
        let first = DirectoryEntry(
            url: directory.appendingPathComponent("first.txt"),
            displayName: "first.txt",
            isDirectory: false,
            isPackage: false,
            isHidden: false,
            fileSize: 1,
            modifiedAt: nil,
            contentType: nil
        )
        var column = BrowserColumn(url: directory)
        column.entries = [first]
        let representable = BrowserColumnTableView(
            viewModel: viewModel,
            index: 0,
            column: column,
            renamingURL: nil,
            isFocusedColumn: true
        )
        let coordinator = representable.makeCoordinator()
        let table = FileColumnTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("name")))
        table.dataSource = coordinator
        table.delegate = coordinator

        // A replacement column starts its own counter, so a different row can
        // legitimately arrive with the same revision value.
        let second = DirectoryEntry(
            url: directory.appendingPathComponent("second.txt"),
            displayName: "second.txt",
            isDirectory: false,
            isPackage: false,
            isHidden: false,
            fileSize: 2,
            modifiedAt: nil,
            contentType: nil
        )
        var replacementColumn = BrowserColumn(url: directory)
        replacementColumn.entries = [second]
        coordinator.syncListing(replacementColumn, in: table)
        XCTAssertEqual(coordinator.entries, [second])

        let metadataUpdate = DirectoryEntry(
            url: second.url,
            displayName: second.displayName,
            isDirectory: second.isDirectory,
            isPackage: second.isPackage,
            isHidden: second.isHidden,
            fileSize: 99,
            modifiedAt: Date(),
            contentType: second.contentType
        )
        replacementColumn.entries = [metadataUpdate]
        coordinator.syncListing(replacementColumn, in: table)
        XCTAssertEqual(coordinator.entries, [metadataUpdate])

        viewModel.renamingURL = metadataUpdate.url
        viewModel.renameText = metadataUpdate.displayName
        coordinator.parent = BrowserColumnTableView(
            viewModel: viewModel,
            index: 0,
            column: replacementColumn,
            renamingURL: metadataUpdate.url,
            isFocusedColumn: true
        )
        table.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        table.reloadData()
        coordinator.syncEditing(in: table)
        let activeCell = table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: false
        ) as? BrowserRowCellView
        let activeEditor = activeCell?.subviews
            .compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "rename-field" }
        activeEditor?.stringValue = "draft name.txt"

        let inserted = DirectoryEntry(
            url: directory.appendingPathComponent("inserted.txt"),
            displayName: "inserted.txt",
            isDirectory: false,
            isPackage: false,
            isHidden: false,
            fileSize: 3,
            modifiedAt: nil,
            contentType: nil
        )
        replacementColumn.entries = [inserted, metadataUpdate]
        coordinator.syncListing(replacementColumn, in: table)
        coordinator.syncEditing(in: table)
        XCTAssertEqual(viewModel.renameText, "draft name.txt")
        let remountedCell = table.view(
            atColumn: 0,
            row: 1,
            makeIfNecessary: false
        ) as? BrowserRowCellView
        XCTAssertEqual(
            remountedCell?.editingText,
            "draft name.txt",
            "A structural watcher refresh must preserve the active rename draft"
        )
    }

    func testInlineRenameUsesARealTextFieldAndRestoresTheFileIdentifier() throws {
        let directory = URL(fileURLWithPath: "/tmp/rename-role", isDirectory: true)
        let entry = DirectoryEntry(
            url: directory.appendingPathComponent("file.txt"),
            displayName: "file.txt",
            isDirectory: false,
            isPackage: false,
            isHidden: false,
            fileSize: nil,
            modifiedAt: nil,
            contentType: nil
        )
        let cell = BrowserRowCellView(identifier: .init("row"))
        cell.configure(with: entry)
        cell.beginEditing(initialValue: entry.displayName)

        let editor = try XCTUnwrap(
            cell.subviews
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "rename-field" }
        )
        // AppKit does not vend a concrete accessibility role until a view is
        // attached to a window, so verify the properties that make this a
        // native editable text field here. The UI test covers its AXTextField
        // exposure in the running app.
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.isSelectable)
        XCTAssertFalse(editor.isHidden)

        XCTAssertTrue(
            cell.control(
                editor,
                textView: NSTextView(),
                doCommandBy: #selector(NSResponder.cancelOperation(_:))
            )
        )
        XCTAssertNil(
            cell.subviews
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "rename-field" }
        )
        XCTAssertNotNil(
            cell.subviews
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "browser-item-file.txt" }
        )

        var callbackCount = 0
        cell.onCommitRename = { _ in callbackCount += 1 }
        cell.onCancelRename = { callbackCount += 1 }
        cell.beginEditing(initialValue: entry.displayName)
        _ = cell.stopEditingFromModel()
        XCTAssertEqual(
            callbackCount,
            0,
            "Model-driven teardown must not commit a rename while the panel hides"
        )
        XCTAssertNil(
            cell.subviews
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "rename-field" }
        )
    }

    func testRowSizeMetadataCanBeShownAndHiddenWithoutReplacingTheCell() throws {
        let entry = DirectoryEntry(
            url: URL(fileURLWithPath: "/tmp/report.pdf"),
            displayName: "report.pdf",
            isDirectory: false,
            isPackage: false,
            isHidden: false,
            fileSize: 1_536,
            modifiedAt: nil,
            contentType: nil
        )
        let cell = BrowserRowCellView(identifier: .init("row"))

        cell.configure(with: entry, showsItemSize: true)
        let sizeLabel = try XCTUnwrap(
            cell.subviews
                .compactMap { $0 as? NSTextField }
                .first { $0.accessibilityIdentifier() == "browser-item-size-report.pdf" }
        )
        XCTAssertFalse(sizeLabel.isHidden)
        XCTAssertFalse(sizeLabel.stringValue.isEmpty)

        cell.configure(with: entry, showsItemSize: false)
        XCTAssertTrue(sizeLabel.isHidden)
        XCTAssertTrue(sizeLabel.stringValue.isEmpty)
        XCTAssertEqual(sizeLabel.accessibilityIdentifier(), "")
    }

    func testPendingNewFolderRenameSurvivesUntilItsListingArrives() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pending-rename-\(UUID().uuidString)", isDirectory: true)
        let target = directory.appendingPathComponent("untitled folder", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let defaultsName = "pending-rename-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let viewModel = BrowserViewModel(
            folderAccess: FolderAccessManager(
                defaults: defaults,
                loadStoredPaths: false,
                initialFolders: [directory]
            ),
            preferences: BrowserPreferences(defaults: defaults),
            quickLook: QuickLookController()
        )
        viewModel.renamingURL = target
        var column = BrowserColumn(url: directory)
        column.isLoading = false
        let representable = BrowserColumnTableView(
            viewModel: viewModel,
            index: 0,
            column: column,
            renamingURL: target,
            isFocusedColumn: true
        )
        let coordinator = representable.makeCoordinator()
        let table = FileColumnTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("name")))

        coordinator.syncEditing(in: table)
        XCTAssertEqual(
            viewModel.renamingURL,
            target,
            "An on-disk target can be pending the async listing after New Folder"
        )

        try FileManager.default.removeItem(at: target)
        coordinator.syncEditing(in: table)
        XCTAssertNil(
            viewModel.renamingURL,
            "A target removed from both disk and listing should cancel stale edit state"
        )
    }

    func testSpareViewportWidthIsDistributedAndFocusedColumnGetsPriority() {
        let widths = BrowserColumnSizing.distribute(
            naturalWidths: [240, 240, 240],
            availableWidth: 1_050,
            focusedIndex: 1
        )

        XCTAssertEqual(
            widths.reduce(0, +) + 2 * BrowserColumnSizing.dividerWidth,
            1_050,
            accuracy: 1
        )
        XCTAssertGreaterThan(widths[1], widths[0])
        XCTAssertGreaterThanOrEqual(widths[2], widths[0],
                                    "The newest column should share the second priority")
    }

    func testSingleColumnAbsorbsWideViewportBeyondNaturalWidthCap() {
        let widths = BrowserColumnSizing.distribute(
            naturalWidths: [BrowserColumnSizing.maximumWidth],
            availableWidth: 900,
            focusedIndex: 0
        )

        XCTAssertEqual(widths, [900])
    }

    func testFocusedAndTrailingColumnsAbsorbResidualInsteadOfLeavingBlankSpace() {
        let widths = BrowserColumnSizing.distribute(
            naturalWidths: Array(repeating: BrowserColumnSizing.maximumWidth, count: 3),
            availableWidth: 2_000,
            focusedIndex: 0
        )

        XCTAssertEqual(
            widths.reduce(0, +) + 2 * BrowserColumnSizing.dividerWidth,
            2_000,
            accuracy: 1
        )
        XCTAssertGreaterThan(widths[0], BrowserColumnSizing.maximumWidth)
        XCTAssertEqual(widths[1], BrowserColumnSizing.maximumWidth)
        XCTAssertGreaterThan(widths[2], BrowserColumnSizing.maximumWidth)
    }

    func testCompressionProtectsFocusedColumn() {
        let widths = BrowserColumnSizing.distribute(
            naturalWidths: [430, 430, 430],
            availableWidth: 900,
            focusedIndex: 2
        )

        XCTAssertEqual(
            widths.reduce(0, +) + 2 * BrowserColumnSizing.dividerWidth,
            900,
            accuracy: 1
        )
        XCTAssertGreaterThan(widths[2], widths[0])
        XCTAssertTrue(widths.allSatisfy { $0 >= BrowserColumnSizing.minimumWidth })
    }

    func testReadableMinimaOverflowWhenViewportCannotFitThem() {
        let widths = BrowserColumnSizing.distribute(
            naturalWidths: [300, 300, 300],
            availableWidth: 500,
            focusedIndex: 2
        )

        XCTAssertEqual(
            widths,
            Array(repeating: BrowserColumnSizing.minimumWidth, count: 3),
            "Horizontal scrolling is preferable to unreadably skinny columns"
        )
        XCTAssertGreaterThan(widths.reduce(0, +), 500)
    }

    func testLoadingToContentTransitionKeepsTheSameFocusableTableMounted() throws {
        let defaultsName = "column-layout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let directory = URL(fileURLWithPath: "/tmp/slow-folder", isDirectory: true)
        let folderAccess = FolderAccessManager(
            defaults: defaults,
            loadStoredPaths: false,
            initialFolders: [directory]
        )
        let viewModel = BrowserViewModel(
            folderAccess: folderAccess,
            preferences: BrowserPreferences(defaults: defaults),
            quickLook: QuickLookController()
        )
        var column = BrowserColumn(url: directory)
        let host = NSHostingView(
            rootView: BrowserColumnContentView(
                viewModel: viewModel,
                index: 0,
                column: column
            )
            .frame(width: 320, height: 300)
        )
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 300)
        host.layoutSubtreeIfNeeded()

        let loadingTable = try XCTUnwrap(firstTable(in: host))
        XCTAssertTrue(loadingTable.acceptsFirstResponder)
        XCTAssertEqual(loadingTable.accessibilityIdentifier(), "browser-column-0")

        column.isLoading = false
        column.entries = [
            DirectoryEntry(
                url: directory.appendingPathComponent("ready.txt"),
                displayName: "ready.txt",
                isDirectory: false,
                isPackage: false,
                isHidden: false,
                fileSize: 5,
                modifiedAt: nil,
                contentType: nil
            )
        ]
        host.rootView = BrowserColumnContentView(
            viewModel: viewModel,
            index: 0,
            column: column
        )
        .frame(width: 320, height: 300)
        host.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            firstTable(in: host) === loadingTable,
            "Finishing a slow load must reveal the table already holding first responder"
        )
    }

    func testCustomRowExposesItsSelectionToAccessibility() {
        let row = BrowserColumnRowView()
        row.isSelected = true

        XCTAssertTrue(row.isAccessibilitySelected())
    }

    private func firstTable(in view: NSView) -> FileColumnTableView? {
        if let table = view as? FileColumnTableView { return table }
        for child in view.subviews {
            if let table = firstTable(in: child) { return table }
        }
        return nil
    }
}

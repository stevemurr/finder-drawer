import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One Miller column, backed by a real `NSTableView`.
///
/// The previous hand-rolled SwiftUI list could not do what a file list has to:
/// there was no right-click menu, no ⇧/⌘-click selection, a 1pt gap between
/// rows that swallowed clicks, and an auto-scroll on every selection change
/// that moved the list out from under the cursor. A table gives all of that
/// correctly for free, and recycles rows so a 50k-entry folder stays smooth.
struct BrowserColumnTableView: NSViewRepresentable {
    @Bindable var viewModel: BrowserViewModel
    let index: Int
    let column: BrowserColumn
    /// Passed explicitly rather than read off the view model inside the
    /// coordinator: SwiftUI only re-invokes `updateNSView` when the
    /// representable's own inputs change, so a rename starting would otherwise
    /// never reach the table.
    let renamingURL: URL?
    let isFocusedColumn: Bool
    var showsItemSizes = false
    var style: BrowserColumnSurfaceStyle = .standard
    var accessibilityPrefix = "browser"

    static let rowHeight: CGFloat = 28

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileColumnTableView()
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.style = .plain
        table.backgroundColor = .clear
        // Keep AppKit's real selection machinery enabled. The row view
        // overrides `drawSelection(in:)` to customize its appearance; setting
        // the table to `.none` prevents that lifecycle and leaves stale paint
        // behind when a plain click replaces the old row.
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.tableDoubleClicked(_:))
        table.coordinator = context.coordinator
        table.setAccessibilityIdentifier("\(accessibilityPrefix)-column-\(index)")

        let tableColumn = NSTableColumn(identifier: .init("name"))
        tableColumn.resizingMask = .autoresizingMask
        table.addTableColumn(tableColumn)

        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.move, .copy], forLocal: false)

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        // The same thin overlay scroller the transcript and the editor use, so
        // a Miller column does not carry a permanent 17 pt legacy bar under
        // "Show scroll bars: Always" — which on a narrow column is a real
        // fraction of the filename it is drawn over.
        scrollView.applyDrawerThinOverlayScroller()
        scrollView.drawsBackground = isFocusedColumn
        scrollView.backgroundColor = isFocusedColumn ? style.focusedColumnBackground : .clear
        table.isFocusedColumn = isFocusedColumn
        table.surfaceStyle = style
        context.coordinator.table = table
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scrollView.documentView as? FileColumnTableView else { return }

        table.isFocusedColumn = isFocusedColumn
        scrollView.drawsBackground = isFocusedColumn
        scrollView.backgroundColor = isFocusedColumn ? style.focusedColumnBackground : .clear
        table.surfaceStyle = style

        context.coordinator.syncListing(
            column.entries,
            columnInstanceID: column.instanceID,
            listingRevision: column.listingRevision,
            contentRevision: column.contentRevision,
            in: table
        )
        context.coordinator.syncItemSizePresentation(in: table)
        context.coordinator.syncSelection(in: table)
        context.coordinator.syncEditing(in: table)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: BrowserColumnTableView
        private(set) var entries: [DirectoryEntry] = []
        private var columnInstanceID: UUID
        private(set) var listingRevision: UInt64 = 0
        private var contentRevision: UInt64 = 0
        private var rowByID: [URL: Int] = [:]
        weak var table: NSTableView?
        /// Set while pushing model state into the table, so the resulting
        /// `selectionDidChange` is not echoed straight back into the model.
        private var isSyncingSelection = false
        /// NSTableView can deliver a reload/selection notification at the end
        /// of the current run-loop turn. A generation keeps suppression alive
        /// through that delivery without an older release clearing a newer one.
        private var selectionSyncGeneration: UInt64 = 0
        private var lastScrollToken = 0
        /// Row metadata can change without a directory reload. Keep this bit
        /// separate from the listing revisions so the toolbar toggle updates
        /// only the recycled cells currently on screen.
        private var showsItemSizes: Bool
        /// The most recent row AppKit asked to add to selection. Its
        /// `selectedRow` is not the "last touched" row for an extended
        /// selection, so without this a Command-click can make the wrong item
        /// primary.
        private var primaryRowHint: Int?
        /// The cell currently presenting inline rename. SwiftUI/model state can
        /// cancel or replace the session without destroying the table, so the
        /// coordinator must explicitly dismantle the old field.
        private weak var editingCell: BrowserRowCellView?
        private var editingURL: URL?

        init(_ parent: BrowserColumnTableView) {
            self.parent = parent
            columnInstanceID = parent.column.instanceID
            showsItemSizes = parent.showsItemSizes
            super.init()
            replaceListing(
                parent.column.entries,
                columnInstanceID: parent.column.instanceID,
                listingRevision: parent.column.listingRevision,
                contentRevision: parent.column.contentRevision
            )
        }

        // MARK: Data

        func replaceListing(
            _ entries: [DirectoryEntry],
            columnInstanceID: UUID,
            listingRevision: UInt64,
            contentRevision: UInt64
        ) {
            self.entries = entries
            self.columnInstanceID = columnInstanceID
            self.listingRevision = listingRevision
            self.contentRevision = contentRevision
            rowByID = Dictionary(
                uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) }
            )
        }

        /// Reload and restore model selection as one transaction. Letting the
        /// reload's temporary empty selection escape into the model can descend
        /// into a just-created folder and steal focus from its rename field.
        func reloadListing(
            _ entries: [DirectoryEntry],
            columnInstanceID: UUID,
            listingRevision: UInt64,
            contentRevision: UInt64,
            in table: NSTableView
        ) {
            suppressSelectionFeedback {
                replaceListing(
                    entries,
                    columnInstanceID: columnInstanceID,
                    listingRevision: listingRevision,
                    contentRevision: contentRevision
                )
                table.reloadData()
                table.selectRowIndexes(desiredSelection, byExtendingSelection: false)
                updateSelectionAccessibility(in: table)
            }
        }

        /// Synchronizes both row structure and metadata.
        ///
        /// The column instance ID is the ABA guard for a same-URL reroot.
        /// Revisions then make the common unchanged path O(1), even for a
        /// 50k-entry folder. Metadata-only changes update recycled/visible
        /// cells in place so icons and disclosure state stay truthful without a
        /// `reloadData` that would tear down an active inline editor.
        func syncListing(
            _ newEntries: [DirectoryEntry],
            columnInstanceID newColumnInstanceID: UUID,
            listingRevision newListingRevision: UInt64,
            contentRevision newContentRevision: UInt64,
            in table: NSTableView
        ) {
            if columnInstanceID != newColumnInstanceID
                || listingRevision != newListingRevision {
                // A real external add/delete/reorder can land while the user
                // is typing. `reloadData` tears down AppKit's field editor, so
                // first capture the draft and mark the teardown as
                // coordinator-driven; otherwise responder loss commits a
                // partial filename. `syncEditing` below remounts the field on
                // the target's new row with the preserved text.
                if let draft = editingCell?.editingText {
                    parent.viewModel.renameText = draft
                    stopEditing(in: table)
                }
                reloadListing(
                    newEntries,
                    columnInstanceID: newColumnInstanceID,
                    listingRevision: newListingRevision,
                    contentRevision: newContentRevision,
                    in: table
                )
                return
            }
            guard contentRevision != newContentRevision else { return }

            entries = newEntries
            contentRevision = newContentRevision
            table.enumerateAvailableRowViews { _, row in
                guard newEntries.indices.contains(row),
                      let cell = table.view(
                          atColumn: 0,
                          row: row,
                          makeIfNecessary: false
                      ) as? BrowserRowCellView
                else { return }
                cell.configure(with: newEntries[row], showsItemSize: parent.showsItemSizes)
                cell.setSelectionAccessibility(table.selectedRowIndexes.contains(row))
            }
        }

        func syncItemSizePresentation(in table: NSTableView) {
            guard showsItemSizes != parent.showsItemSizes else { return }
            showsItemSizes = parent.showsItemSizes
            table.enumerateAvailableRowViews { _, row in
                guard entries.indices.contains(row),
                      let cell = table.view(
                          atColumn: 0,
                          row: row,
                          makeIfNecessary: false
                      ) as? BrowserRowCellView
                else { return }
                cell.configure(with: entries[row], showsItemSize: showsItemSizes)
                cell.setSelectionAccessibility(table.selectedRowIndexes.contains(row))
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard entries.indices.contains(row) else { return nil }
            let entry = entries[row]
            let identifier = NSUserInterfaceItemIdentifier("row")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? BrowserRowCellView)
                ?? BrowserRowCellView(identifier: identifier)
            cell.configure(with: entry, showsItemSize: parent.showsItemSizes)
            cell.setSelectionAccessibility(tableView.selectedRowIndexes.contains(row))
            cell.onCommitRename = { [weak self] newName in
                guard let self,
                      Self.sameFile(self.parent.viewModel.renamingURL, entry.url)
                else { return }
                self.parent.viewModel.commitRename(entry.url, to: newName)
            }
            cell.onCancelRename = { [weak self] in
                guard let self,
                      Self.sameFile(self.parent.viewModel.renamingURL, entry.url)
                else { return }
                self.parent.viewModel.cancelRename()
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = BrowserColumnRowView()
            rowView.isFocusedColumn = parent.isFocusedColumn
            rowView.surfaceStyle = parent.style
            return rowView
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let table = notification.object as? NSTableView else { return }
            let indexes = table.selectedRowIndexes
            let ids = Set(indexes.compactMap { entries.indices.contains($0) ? entries[$0].id : nil })
            // The primary row anchors descent and preview. Prefer the row the
            // pointer actually touched, then AppKit's current row, then the
            // final selected index for keyboard-only changes.
            let hinted = primaryRowHint.flatMap { indexes.contains($0) ? $0 : nil }
            let primaryRow = hinted
                ?? (entries.indices.contains(table.selectedRow) ? table.selectedRow : indexes.last)
            let primary = primaryRow.flatMap { entries.indices.contains($0) ? entries[$0].id : nil }
            parent.viewModel.select(ids: ids, primary: primary, inColumn: parent.index)
            primaryRowHint = nil
            updateSelectionAccessibility(in: table)
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            // A row can be clicked while another app window is key.
            // Claim both window and responder at the delegate boundary so the
            // next shortcut belongs to Files. Doing this in an NSTableView
            // `mouseDown` override disables AppKit gesture-recognizer support
            // for the whole table.
            if let event = NSApp.currentEvent,
               event.type == .leftMouseDown || event.type == .rightMouseDown {
                tableView.window?.makeKeyAndOrderFront(nil)
                tableView.window?.makeFirstResponder(tableView)
            }
            if entries.indices.contains(row) { primaryRowHint = row }
            return true
        }

        /// Pushes model selection into the table without echoing back.
        ///
        /// Deliberately does **not** scroll: scrolling on every selection change
        /// is what made clicks land on the wrong row, because the list moved
        /// under the cursor. Keyboard moves scroll explicitly instead.
        func syncSelection(in table: NSTableView) {
            let desired = desiredSelection
            if desired != table.selectedRowIndexes {
                suppressSelectionFeedback {
                    table.selectRowIndexes(desired, byExtendingSelection: false)
                }
                updateSelectionAccessibility(in: table)
            }

            // Follow the selection only when it moved by keyboard or reveal.
            // A click must never scroll, or the list shifts under the pointer.
            let token = parent.viewModel.scrollToSelectionToken
            if token != lastScrollToken {
                lastScrollToken = token
                if let primary = parent.column.primarySelectedID,
                   let row = rowByID[primary] {
                    table.scrollRowToVisible(row)
                }
            }
        }

        private var desiredSelection: IndexSet {
            IndexSet(parent.column.selectedIDs.compactMap { rowByID[$0] })
        }

        private func suppressSelectionFeedback(_ updates: () -> Void) {
            selectionSyncGeneration &+= 1
            let generation = selectionSyncGeneration
            isSyncingSelection = true
            updates()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionSyncGeneration == generation else { return }
                self.isSyncingSelection = false
            }
        }

        private func updateSelectionAccessibility(in table: NSTableView) {
            table.enumerateAvailableRowViews { rowView, row in
                let selected = table.selectedRowIndexes.contains(row)
                rowView.setAccessibilitySelected(selected)
                (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BrowserRowCellView)?
                    .setSelectionAccessibility(selected)
            }
        }

        func syncEditing(in table: NSTableView) {
            guard let renaming = parent.renamingURL else {
                guard editingCell != nil || editingURL != nil else { return }
                stopEditing(in: table)
                return
            }
            // A newly-created URL and FileManager's listed URL can disagree
            // only in representation (`/var` vs `/private/var` is the common
            // case). Exact lookup keeps normal updates O(1); the path fallback
            // runs only while rename is active.
            guard let row = rowByID[renaming] ?? entries.firstIndex(where: {
                $0.url.standardizedFileURL.path == renaming.standardizedFileURL.path
            }) else {
                stopEditing(in: table)
                // New Folder publishes its on-disk URL before the actor-backed
                // directory listing arrives. Keep that pending session alive;
                // only a target missing from both the table and filesystem is
                // an external deletion that should cancel editing.
                if !FileManager.default.fileExists(atPath: renaming.path) {
                    parent.viewModel.cancelRename()
                }
                return
            }
            // A freshly created folder has no row view yet — the table has only
            // just reloaded — so the view must be made rather than fetched, or
            // the rename field silently never appears.
            table.scrollRowToVisible(row)
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? BrowserRowCellView
            else { return }
            if editingCell !== cell || !Self.sameFile(editingURL, renaming) {
                stopEditing(in: table)
                editingCell = cell
                editingURL = renaming
            }
            cell.beginEditing(initialValue: parent.viewModel.renameText)
        }

        private func stopEditing(in table: NSTableView) {
            var shouldRestoreTableFocus = editingCell?.stopEditingFromModel() == true

            // Defensive cleanup for a recycled row or a representable update
            // that outlived the weak cell reference.
            table.enumerateAvailableRowViews { _, row in
                guard let cell = table.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: false
                ) as? BrowserRowCellView else { return }
                if cell !== self.editingCell {
                    shouldRestoreTableFocus = cell.stopEditingFromModel() || shouldRestoreTableFocus
                }
            }
            editingCell = nil
            editingURL = nil
            if shouldRestoreTableFocus {
                table.window?.makeFirstResponder(table)
            }
        }

        private static func sameFile(_ lhs: URL?, _ rhs: URL?) -> Bool {
            guard let lhs, let rhs else { return false }
            return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
        }

        // MARK: Actions

        @objc func tableDoubleClicked(_ sender: Any?) {
            guard let table = table, entries.indices.contains(table.clickedRow) else { return }
            parent.viewModel.select(entries[table.clickedRow].id, inColumn: parent.index)
            parent.viewModel.requestOpenSelection()
        }

        /// Right-click. Finder selects the row under the cursor unless it is
        /// already part of a multi-selection, so a context menu never silently
        /// acts on something other than what is highlighted.
        func menu(forRow row: Int) -> NSMenu? {
            if let table {
                table.window?.makeFirstResponder(table)
            }
            guard entries.indices.contains(row) else { return emptySpaceMenu() }
            if !parent.column.selectedIDs.contains(entries[row].id) {
                parent.viewModel.select(entries[row].id, inColumn: parent.index)
            } else {
                parent.viewModel.makePrimary(entries[row].id, inColumn: parent.index)
            }
            return buildMenu(BrowserCommand.contextMenuOrder)
        }

        private func emptySpaceMenu() -> NSMenu {
            parent.viewModel.focusColumn(at: parent.index)
            return buildMenu([.newFolder, .goToFolder, nil, .toggleHiddenFiles])
        }

        private func buildMenu(_ commands: [BrowserCommand?]) -> NSMenu {
            let menu = NSMenu()
            var pendingSeparator = false
            for command in commands {
                guard let command else {
                    if !menu.items.isEmpty { pendingSeparator = true }
                    continue
                }
                // A menu is a compact action surface. Omit commands whose
                // cardinality is invalid instead of presenting traps such as
                // Rename for a genuine multi-selection.
                if !parent.viewModel.canPerform(command) { continue }
                if pendingSeparator {
                    menu.addItem(.separator())
                    pendingSeparator = false
                }
                let item = NSMenuItem(
                    title: parent.viewModel.title(for: command),
                    action: #selector(runCommand(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = command
                item.image = NSImage(
                    systemSymbolName: command.symbol,
                    accessibilityDescription: nil
                )
                menu.addItem(item)
            }
            return menu
        }

        @objc private func runCommand(_ sender: NSMenuItem) {
            guard let command = sender.representedObject as? BrowserCommand else { return }
            parent.viewModel.perform(command)
        }

        // MARK: Drag and drop

        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> NSPasteboardWriting? {
            guard entries.indices.contains(row) else { return nil }
            return entries[row].url as NSURL
        }

        /// Dropping *on* a folder row targets that folder; dropping between rows
        /// targets the column's own directory. The old whole-column drop target
        /// could not tell those apart.
        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            if dropOperation == .on {
                guard entries.indices.contains(row), entries[row].isDirectory else {
                    tableView.setDropRow(row, dropOperation: .above)
                    return isOptionHeld ? .copy : .move
                }
                return isOptionHeld ? .copy : .move
            }
            return isOptionHeld ? .copy : .move
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            let urls = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            guard !urls.isEmpty else { return false }

            let destination: URL
            if dropOperation == .on, entries.indices.contains(row), entries[row].isDirectory {
                destination = entries[row].url
            } else {
                destination = parent.column.url
            }
            parent.viewModel.drop(urls, into: destination, copy: isOptionHeld)
            return true
        }

        private var isOptionHeld: Bool {
            NSEvent.modifierFlags.contains(.option)
        }
    }
}

/// `NSTableView` subclass that routes right-clicks and the keys the browser
/// owns back to the coordinator.
@MainActor
final class FileColumnTableView: NSTableView {
    weak var coordinator: BrowserColumnTableView.Coordinator?

    var surfaceStyle: BrowserColumnSurfaceStyle = .standard {
        didSet {
            guard oldValue != surfaceStyle else { return }
            enumerateAvailableRowViews { rowView, _ in
                (rowView as? BrowserColumnRowView)?.surfaceStyle = surfaceStyle
            }
            needsDisplay = true
        }
    }

    var isFocusedColumn = false {
        didSet {
            guard oldValue != isFocusedColumn else { return }
            enumerateAvailableRowViews { rowView, _ in
                (rowView as? BrowserColumnRowView)?.isFocusedColumn = isFocusedColumn
            }
            needsDisplay = true
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return coordinator?.menu(forRow: row(at: point))
    }

    /// The first click in Files both activates the panel and selects the row.
    /// Responder ownership itself is finalized by the delegate's
    /// `shouldSelectRow`, which also covers clicks delivered after key-window changes.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// ↑/↓ are handled by `super` — that is the whole point of using a table —
    /// so `PanelKeyMonitor` must not also bind them. Everything the browser
    /// owns beyond that is forwarded and swallowed here.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (event.keyCode, modifiers) {
        case (48, []), (49, []), (36, []), (76, []), (123, []), (124, []):
            // Tab, Space, Return, ←, → belong to the browser, not the table.
            nextResponder?.keyDown(with: event)
        default:
            super.keyDown(with: event)
        }
    }
}

/// Custom selection communicates two independent states:
///
/// - selected: this row anchors a path or a multi-selection;
/// - focused: this column receives the next keyboard command.
///
/// A soft fill preserves the selection in every column. The focused column
/// earns the narrow indigo rail from the design review, so focus never depends
/// on a barely perceptible shade change alone.
@MainActor
final class BrowserColumnRowView: NSTableRowView {
    var surfaceStyle: BrowserColumnSurfaceStyle = .standard {
        didSet {
            if oldValue != surfaceStyle { needsDisplay = true }
        }
    }

    var isFocusedColumn = false {
        didSet {
            if oldValue != isFocusedColumn { needsDisplay = true }
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none, isSelected else { return }
        let selectionRect = bounds.insetBy(dx: 6, dy: 2)
        let fill = isFocusedColumn
            ? surfaceStyle.focusedSelection
            : surfaceStyle.unfocusedSelection
        fill.setFill()
        NSBezierPath(roundedRect: selectionRect, xRadius: 7, yRadius: 7).fill()

        guard isFocusedColumn else {
            // Parent-column rows describe the open path. An outline keeps that
            // anchor legible without impersonating the actionable selection
            // in the keyboard-focused column.
            NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
            let outline = NSBezierPath(roundedRect: selectionRect, xRadius: 7, yRadius: 7)
            outline.lineWidth = 1
            outline.stroke()
            return
        }
        surfaceStyle.focusRail.setFill()
        let rail = NSRect(
            x: selectionRect.minX,
            y: selectionRect.minY + 3,
            width: 2,
            height: max(selectionRect.height - 6, 0)
        )
        NSBezierPath(roundedRect: rail, xRadius: 1, yRadius: 1).fill()
    }

    /// NSTableView already exposes selected rows as a collection; explicitly
    /// mirror the row state too so VoiceOver and XCUITest can query the item
    /// itself, even though its selection artwork is custom.
    override func isAccessibilitySelected() -> Bool {
        isSelected
    }
}

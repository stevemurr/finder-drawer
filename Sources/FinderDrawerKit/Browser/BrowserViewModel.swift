import AppKit
import Foundation
import Observation

/// One Miller column: a directory listing plus what is selected inside it.
struct BrowserColumn: Identifiable {
    enum PresentationState: Equatable {
        case loading
        case empty
        case content
        case error(String)
    }

    /// Distinguishes a newly-created column from an older column at the same
    /// URL. Revision counters are local to one column lifetime, so this makes
    /// them safe as O(1) synchronization tokens without comparing every row as
    /// an ABA guard.
    let instanceID = UUID()
    let url: URL
    var entries: [DirectoryEntry] = [] {
        didSet {
            guard entries != oldValue else { return }
            contentRevision &+= 1

            // Directory watchers commonly echo the explicit reload triggered
            // by our own file operation. Metadata can differ between those two
            // reads, but NSTableView only needs rebuilding when row identity or
            // order changes. Reloading the same rows tears down an active
            // inline editor.
            let structureChanged = entries.count != oldValue.count
                || !zip(entries, oldValue).allSatisfy { pair in
                    pair.0.id == pair.1.id
                }
            guard structureChanged else { return }
            rowByID = Dictionary(
                uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) }
            )
            listingRevision &+= 1
        }
    }
    /// O(1) listing identity for AppKit synchronization. Selection/focus
    /// updates leave this stable, so a 50k-row column never compares two full
    /// arrays merely because the highlight moved.
    private(set) var listingRevision: UInt64 = 0
    /// Advances for either structural or metadata changes. Together with
    /// `listingRevision`, this lets the AppKit table distinguish a cheap
    /// visible-cell refresh from a full reload without comparing whole arrays
    /// during unrelated SwiftUI updates.
    private(set) var contentRevision: UInt64 = 0
    private var rowByID: [URL: Int] = [:]
    /// Everything selected. Multi-selection drives batch operations.
    var selectedIDs: Set<URL> = []
    /// The row that anchors single-item behaviour — descent into a child
    /// column, the preview pane, rename. With one row selected this is that
    /// row; with several it is the most recent, matching Finder.
    var primarySelectedID: URL?
    var isLoading = true
    var errorMessage: String?
    /// Cached when a listing arrives. Selection changes re-render the browser
    /// frequently; filename measurement must not walk a 50k-entry folder every
    /// time the focus rail moves.
    var naturalWidthHint: CGFloat?

    init(url: URL) {
        self.url = url
    }

    var id: URL { url }

    var selectedEntry: DirectoryEntry? {
        guard let primarySelectedID,
              let row = rowByID[primarySelectedID],
              entries.indices.contains(row)
        else { return nil }
        return entries[row]
    }

    /// Selected rows in display order, which is the order batch operations
    /// should act in.
    var selectedEntries: [DirectoryEntry] {
        selectedIDs
            .compactMap { rowByID[$0] }
            .sorted()
            .compactMap { entries.indices.contains($0) ? entries[$0] : nil }
    }

    func rowIndex(for id: URL) -> Int? { rowByID[id] }

    var presentationState: PresentationState {
        if isLoading { return .loading }
        if let errorMessage { return .error(errorMessage) }
        return entries.isEmpty ? .empty : .content
    }
}

/// Drives the column browser: which directories are open, what is selected in
/// each, and the file operations run against that selection.
@MainActor
@Observable
final class BrowserViewModel: Identifiable {
    /// Stable across the browser host location's life as it changes roots.
    nonisolated let id = UUID()

    /// Columns left to right. `columns[0]` is the current location root.
    private(set) var columns: [BrowserColumn] = []
    /// Which column arrow keys and file operations act on.
    private(set) var focusedColumnIndex = 0
    /// Set while a row is being renamed inline, so the column view can swap the
    /// label for a text field and the key monitor can stand down.
    var renamingURL: URL?
    /// Initial text supplied when the native inline editor begins.
    var renameText = ""
    var errorMessage: String?
    private(set) var isTransferringFiles = false
    let fileHistory = BrowserFileHistory()
    @ObservationIgnored private let clipboard: BrowserFileClipboard
    /// Incremented whenever the selection moved by keyboard or a programmatic
    /// reveal — never by a click. The table scrolls only when this changes, so
    /// clicking cannot move the list out from under the pointer (which is what
    /// made the *next* click land on the wrong row).
    ///
    /// A token rather than a flag because the table reads it during a later
    /// SwiftUI update pass, long after the mutating call has returned.
    private(set) var scrollToSelectionToken = 0

    /// Set by the browser host coordinator so the table can ask its owning surface
    /// to open a file, which is a window concern the model cannot reach.
    @ObservationIgnored var onOpenSelection: (() -> Void)?
    /// Commands the model itself cannot service, handed to its browser host host.
    @ObservationIgnored var onHostCommand: ((BrowserCommand) -> Void)?
    /// Asks browser host to put keyboard focus back on the active column table.
    @ObservationIgnored var onRequestColumnFocus: (() -> Void)?
    /// Notifies the host of a file selection, allowing it to update a preview.
    @ObservationIgnored var onPreviewFile: ((URL) -> Void)?
    /// Cancels a debounced preview when the selection no longer identifies
    /// exactly one file. Without this, a quick file → folder/multi-selection
    /// move can open a stale file after the browser already points elsewhere.
    @ObservationIgnored var onCancelPreview: (() -> Void)?
    /// Promotes the current work-pane preview into an ordinary persistent tab
    /// before an explicit Open/double-click hands the file elsewhere.
    @ObservationIgnored var onPinPreviewFile: ((URL) -> Void)?
    /// Diagnostic/test seam that also documents the bounded resource contract:
    /// one vnode watcher per currently open column, never per navigation
    /// history entry.
    var watchedDirectoryCount: Int { watchers.count }

    @ObservationIgnored private let lister = DirectoryLister()
    @ObservationIgnored private let operations: BrowserFileOperations
    @ObservationIgnored private let preferences: BrowserPreferences
    @ObservationIgnored private let folderAccess: FolderAccessManager
    @ObservationIgnored private let quickLook: QuickLookController
    @ObservationIgnored private let onFileSystemChange: () -> Void
    @ObservationIgnored private var watchers: [URL: DirectoryWatcher] = [:]
    /// Advances only for a new selection/focus intent, not when a directory
    /// reload prunes a vanished row. Rename completion uses it to avoid
    /// snapping selection back after a click-away commit.
    @ObservationIgnored private var selectionIntentRevision: UInt64 = 0

    init(
        folderAccess: FolderAccessManager,
        preferences: BrowserPreferences,
        quickLook: QuickLookController,
        clipboard: BrowserFileClipboard? = nil,
        onFileSystemChange: @escaping () -> Void = {}
    ) {
        self.folderAccess = folderAccess
        self.preferences = preferences
        self.quickLook = quickLook
        self.clipboard = clipboard ?? BrowserFileClipboard()
        self.onFileSystemChange = onFileSystemChange
        operations = BrowserFileOperations(folderAccess: folderAccess)
    }

    // MARK: - Roots

    /// Folder roots explicitly granted to this workspace.
    var navigationRoots: [URL] {
        var seen = Set<String>()
        return folderAccess.folders.filter {
            seen.insert($0.standardizedFileURL.path).inserted
        }
    }

    var currentRoot: URL? { columns.first?.url }

    /// The deepest selected item, which is what the preview column and every
    /// file action operate on.
    var focusedEntry: DirectoryEntry? {
        guard columns.indices.contains(focusedColumnIndex) else { return nil }
        return columns[focusedColumnIndex].selectedEntry
    }

    var focusedSelectionCount: Int {
        guard columns.indices.contains(focusedColumnIndex) else { return 0 }
        return columns[focusedColumnIndex].selectedIDs.count
    }

    var focusedEntries: [DirectoryEntry] {
        guard columns.indices.contains(focusedColumnIndex) else { return [] }
        return columns[focusedColumnIndex].selectedEntries
    }

    /// The file (never a directory) to show in the trailing preview column.
    var previewEntry: DirectoryEntry? {
        guard focusedSelectionCount == 1,
              let entry = focusedEntry,
              !entry.isDirectory
        else { return nil }
        return entry
    }

    /// Where a new folder or a drop lands: the focused column's selected
    /// directory if there is one, else the focused column itself.
    var activeDirectory: URL? {
        guard columns.indices.contains(focusedColumnIndex) else { return nil }
        if focusedSelectionCount == 1, let selected = columns[focusedColumnIndex].selectedEntry, selected.isDirectory {
            return selected.url
        }
        return columns[focusedColumnIndex].url
    }

    func present() {
        if renamingURL != nil { renamingURL = nil }
        if errorMessage != nil { errorMessage = nil }
        if columns.isEmpty, let root = navigationRoots.first {
            setRoot(root)
        }
    }

    func setRoot(_ url: URL) {
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
        onCancelPreview?()
        columns = [BrowserColumn(url: url)]
        focusedColumnIndex = 0
        renamingURL = nil
        errorMessage = nil
        loadColumn(at: 0)
        // The column exists synchronously even though its listing does not.
        // The browser host coordinator dispatches this to the next run-loop turn, by which
        // time SwiftUI has mounted the replacement NSTableView.
        requestColumnFocus()
    }

    // MARK: - Navigation

    /// Single-row selection — the keyboard and programmatic path, which does
    /// want the table to scroll the row into view.
    func select(_ entryID: URL?, inColumn index: Int) {
        select(
            ids: entryID.map { [$0] } ?? [],
            primary: entryID,
            inColumn: index
        )
        scrollToSelectionToken += 1
    }

    /// Multi-row selection — what the table pushes back after ⇧/⌘-click.
    ///
    /// A column only spawns a child when exactly one directory is selected:
    /// with several rows highlighted there is no single "next" folder, and
    /// Finder likewise stops descending.
    func select(ids: Set<URL>, primary: URL?, inColumn index: Int) {
        applySelection(
            ids: ids,
            primary: primary,
            inColumn: index,
            descendsIntoDirectories: true
        )
    }

    private func selectWithoutDescending(_ entryID: URL, inColumn index: Int) {
        applySelection(
            ids: [entryID],
            primary: entryID,
            inColumn: index,
            descendsIntoDirectories: false
        )
        scrollToSelectionToken += 1
    }

    private func applySelection(
        ids: Set<URL>,
        primary: URL?,
        inColumn index: Int,
        descendsIntoDirectories: Bool,
        publishesPreviewIntent: Bool = true
    ) {
        guard columns.indices.contains(index) else { return }
        let resolvedPrimary = primary.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        if columns[index].selectedIDs != ids
            || columns[index].primarySelectedID != resolvedPrimary
            || focusedColumnIndex != index {
            selectionIntentRevision &+= 1
        }
        columns[index].selectedIDs = ids
        columns[index].primarySelectedID = resolvedPrimary
        focusedColumnIndex = index
        // Selecting in a column invalidates everything to its right.
        truncateColumns(after: index)
        if descendsIntoDirectories,
           ids.count <= 1,
           let entry = columns[index].selectedEntry,
           entry.isDirectory,
           // Selection synchronization can echo after a freshly-created row
           // enters inline edit. Opening its child column at that point steals
           // first responder and commits the rename before the user types.
           renamingURL?.standardizedFileURL.path != entry.url.standardizedFileURL.path {
            columns.append(BrowserColumn(url: entry.url))
            loadColumn(at: index + 1)
        }
        quickLook.refreshIfVisible(with: previewEntry.map(FileSearchResult.init(entry:)))
        guard publishesPreviewIntent else { return }
        // Selecting a file shows it in the work pane — the same role the
        // QuickLook preview column used to play, now editable.
        if let entry = previewEntry {
            onPreviewFile?(entry.url)
        } else {
            onCancelPreview?()
        }
    }

    /// Makes a row the primary target while retaining a genuine multi-
    /// selection. Context-click uses this so single-item metadata (the path
    /// anchor, for example) follows the row under the pointer without silently
    /// dropping a Command/Shift selection before a batch action.
    func makePrimary(_ entryID: URL, inColumn index: Int) {
        guard columns.indices.contains(index),
              columns[index].selectedIDs.contains(entryID)
        else { return }
        if columns[index].primarySelectedID != entryID || focusedColumnIndex != index {
            selectionIntentRevision &+= 1
        }
        columns[index].primarySelectedID = entryID
        focusedColumnIndex = index
        quickLook.refreshIfVisible(with: previewEntry.map(FileSearchResult.init(entry:)))
    }

    /// ← / →. Moving right descends into the already-loaded child column;
    /// moving left steps back toward the root.
    func focusColumn(by delta: Int) {
        focusColumn(at: focusedColumnIndex + delta)
    }

    /// The sole programmatic column-focus entry point.
    ///
    /// Updating `focusedColumnIndex` alone only changes the tint. The old
    /// NSTableView remains first responder and consumes the next ↑/↓, making
    /// visual focus and keyboard focus disagree. Every breadcrumb, arrow-key,
    /// and browser host-location path routes through here so drawer can move the
    /// actual AppKit responder in the same transaction.
    func focusColumn(at target: Int) {
        guard columns.indices.contains(target) else { return }
        focusedColumnIndex = target
        // A column the user has never touched has no selection yet; land on its
        // first row so the arrow keys keep working.
        if columns[target].primarySelectedID == nil, let first = columns[target].entries.first {
            select(first.id, inColumn: target)
        }
        requestColumnFocus()
    }

    /// Re-roots one level up. Used by ⌘↑ when already at the leftmost column.
    func goToParent() {
        guard focusedColumnIndex == 0, let root = currentRoot else {
            focusColumn(by: -1)
            return
        }
        let parent = root.deletingLastPathComponent()
        guard parent != root, folderAccess.canWrite(to: parent) || FileManager.default.isReadableFile(atPath: parent.path) else {
            return
        }
        setRoot(parent)
        // Re-select the folder we came from once the new root has loaded, so
        // going up and back down retraces the same path instead of starting over.
        load(parent) { [weak self] in
            self?.select(root.standardizedFileURL, inColumn: 0)
        }
    }

    /// Descend into a folder, or hand a file to Launch Services.
    /// Returns true when the panel should hide (a file was opened).
    @discardableResult
    func openSelection() -> Bool {
        guard canPerform(.open), let entry = focusedEntry else { return false }
        if entry.isDirectory {
            focusColumn(by: 1)
            return false
        }
        onPinPreviewFile?(entry.url)
        NSWorkspace.shared.open(entry.url)
        return true
    }

    /// Asks the owning browser host to open the selection. Used by double-click
    /// and context-menu paths, which have no route to drawer themselves.
    func requestOpenSelection() {
        if let handler = onOpenSelection {
            handler()
        } else {
            openSelection()
        }
    }

    @discardableResult
    func revealSelection() -> Bool {
        let urls = columns.indices.contains(focusedColumnIndex)
            ? columns[focusedColumnIndex].selectedEntries.map(\.url)
            : []
        guard !urls.isEmpty else { return false }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        return true
    }

    /// Runs a command from the shared list. Commands the browser cannot service
    /// itself — search, tabs, settings — are forwarded to the panel.
    func perform(_ command: BrowserCommand) {
        guard canPerform(command) else { return }
        switch command {
        case .open:
            requestOpenSelection()
        case .quickLook:
            quickLookSelection()
        case .rename:
            beginRename()
        case .newFolder:
            createFolder()
        case .moveToTrash:
            trashSelection()
        case .showInFinder:
            revealSelection()
        case .undo, .redo:
            do {
                if command == .undo { try fileHistory.undo() } else { try fileHistory.redo() }
            } catch { errorMessage = error.localizedDescription }
            onFileSystemChange()
            reloadAllColumns()
        case .copy: clipboard.write(focusedEntries.map(\.url))
        case .cut: clipboard.write(focusedEntries.map(\.url), cut: true)
        case .paste: pasteFiles(move: clipboard.isCut)
        case .moveHere: pasteFiles(move: true)
        case .duplicate: transferFiles(focusedEntries.map(\.url), to: nil, mode: .duplicate)
        case .copyPath:
            copySelectedPaths()
        case .toggleHiddenFiles:
            preferences.showHiddenFiles.toggle()
        case .splitPane, .closeSplit, .focusOtherPane, .openWith, .goToFolder, .newTab, .closeTab,
             .search, .settings, .actions, .newTerminal, .toggleSidebar, .nextTab, .previousTab:
            onHostCommand?(command)
        }
    }

    func requestColumnFocus() { onRequestColumnFocus?() }

    func title(for command: BrowserCommand) -> String {
        if command == .undo { return fileHistory.undoTitle }
        if command == .redo { return fileHistory.redoTitle }
        if focusedSelectionCount > 1 {
            switch command {
            case .moveToTrash:
                return "Move \(focusedSelectionCount) Items to Trash"
            case .showInFinder:
                return "Show \(focusedSelectionCount) Items in Finder"
            case .copy: return "Copy \(focusedSelectionCount) Items"
            case .cut: return "Cut \(focusedSelectionCount) Items"
            case .duplicate: return "Duplicate \(focusedSelectionCount) Items"
            case .copyPath:
                return "Copy \(focusedSelectionCount) Paths"
            default:
                break
            }
        }
        return command.title(showHiddenFiles: preferences.showHiddenFiles)
    }

    func canPerform(_ command: BrowserCommand) -> Bool {
        guard command.selectionRequirement.isSatisfied(by: focusedSelectionCount) else { return false }
        switch command {
        case .undo: return !isTransferringFiles && fileHistory.canUndo
        case .redo: return !isTransferringFiles && fileHistory.canRedo
        case .paste, .moveHere:
            guard !isTransferringFiles, let directory = activeDirectory, folderAccess.canWrite(to: directory),
                  !clipboard.urls.isEmpty else { return false }
            return command != .moveHere && !clipboard.isCut || clipboard.urls.allSatisfy { folderAccess.canWrite(to: $0) }
        case .cut, .rename, .moveToTrash:
            return !isTransferringFiles && focusedEntries.allSatisfy { folderAccess.canWrite(to: $0.url) }
        case .duplicate:
            return !isTransferringFiles && focusedEntries.allSatisfy { folderAccess.canWrite(to: $0.url.deletingLastPathComponent()) }
        case .newFolder:
            return !isTransferringFiles && activeDirectory.map { folderAccess.canWrite(to: $0) } == true
        default: return true
        }
    }

    /// Re-lists every open column and hands keyboard focus back to it.
    ///
    /// `load` reads sort order and hidden-file visibility at call time, so
    /// changing either only takes effect on the next listing — without this a
    /// sort change appeared to do nothing until the user navigated away.
    func applyPreferenceChange() {
        reloadAllColumns()
        requestColumnFocus()
    }

    func copySelectedPaths() {
        guard columns.indices.contains(focusedColumnIndex) else { return }
        let paths = columns[focusedColumnIndex].selectedEntries.map(\.url.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    func quickLookSelection() {
        guard canPerform(.quickLook) else { return }
        quickLook.toggle(for: focusedEntry.map(FileSearchResult.init(entry:)))
    }

    // MARK: - File operations

    func beginRename() {
        guard canPerform(.rename), let entry = focusedEntry else { return }
        guard folderAccess.canWrite(to: entry.url) else {
            reportNotAuthorized(entry.url)
            return
        }
        renameText = entry.displayName
        renamingURL = entry.url
    }

    func commitRename(_ url: URL, to newName: String) {
        let selectionRevisionAtCommit = selectionIntentRevision
        renamingURL = nil
        do {
            let renamed = try operations.rename(url, to: newName)
            // Losing field-editor focus can end an unchanged inline edit. It
            // is not a filesystem mutation and must not reload the table or
            // descend into a selected folder.
            guard renamed.standardizedFileURL != url.standardizedFileURL else { return }
            fileHistory.record("Rename", undo: [.init(source: renamed, destination: url)])
            onFileSystemChange()
            let parent = url.deletingLastPathComponent()
            // Re-select after the reload lands, so the user does not lose their
            // place in the column.
            reloadColumn(at: parent) { [weak self] in
                guard let self, let index = self.columns.firstIndex(where: {
                    $0.url.standardizedFileURL == parent.standardizedFileURL
                }),
                self.selectionIntentRevision == selectionRevisionAtCommit
                else { return }
                self.selectWithoutDescending(renamed, inColumn: index)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelRename() {
        if renamingURL != nil { renamingURL = nil }
    }

    func createFolder() {
        guard let directory = activeDirectory else { return }
        let selectionRevisionAtCreation = selectionIntentRevision
        do {
            let created = try operations.newFolder(in: directory)
            fileHistory.record("New Folder", undo: [.init(source: created, destination: nil)])
            onFileSystemChange()
            // Publish the rename target before the async reload. Once the new
            // row lands, the table can enter editing on that same update
            // instead of waiting for a second observation pass.
            renameText = created.lastPathComponent
            renamingURL = created
            reloadColumn(at: directory) { [weak self] in
                guard let self,
                      let index = self.columns.firstIndex(where: {
                          $0.url.standardizedFileURL.path == directory.standardizedFileURL.path
                      }),
                      let entry = self.columns[index].entries.first(where: {
                          $0.url.standardizedFileURL.path == created.standardizedFileURL.path
                      })
                else { return }
                // Escape cancels editing, not creation or the new row's
                // selection. A genuinely newer click wins, however.
                guard self.selectionIntentRevision == selectionRevisionAtCreation else { return }
                let shouldContinueRenaming =
                    self.renamingURL?.standardizedFileURL.path
                        == created.standardizedFileURL.path
                // FileManager may return directory URLs with a different
                // trailing-slash representation than the creation API. Keep
                // selection and rename identity tied to the listed row.
                self.selectWithoutDescending(entry.id, inColumn: index)
                if shouldContinueRenaming {
                    self.renamingURL = entry.id
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Trashes every selected row, not just the primary one.
    func trashSelection() {
        guard columns.indices.contains(focusedColumnIndex) else { return }
        let doomed = columns[focusedColumnIndex].selectedEntries
        guard let last = doomed.last else { return }
        let parent = last.url.deletingLastPathComponent()
        // Pick the survivor to land on before the rows disappear.
        let successor = neighbourID(after: last, in: focusedColumnIndex, skipping: Set(doomed.map(\.id)))
        var undoSteps: [BrowserFileHistory.Step] = []
        defer {
            fileHistory.record("Move to Trash", undo: undoSteps)
        }
        do {
            try operations.trash(doomed.map(\.url)) { source, destination in
                undoSteps.append(.init(source: destination, destination: source))
            }
            onFileSystemChange()
            reloadColumn(at: parent) { [weak self] in
                guard let self, let index = self.columns.firstIndex(where: { $0.url == parent }) else { return }
                self.select(successor ?? self.columns[index].entries.first?.id, inColumn: index)
            }
        } catch {
            if !undoSteps.isEmpty { onFileSystemChange(); reloadAllColumns() }
            errorMessage = error.localizedDescription
        }
    }

    private func pasteFiles(move: Bool) {
        guard let directory = activeDirectory else { return }
        transferFiles(clipboard.urls, to: directory, mode: move ? .move : .copy,
                      clipboardChangeCount: move ? clipboard.pasteboard.changeCount : nil)
    }

    /// Copies and moves can be large. Keep the UI responsive and use the captured
    /// destination even if the user changes selection while disk work is running.
    private func transferFiles(_ urls: [URL], to directory: URL?, mode: BrowserTransferPlan.Mode,
                               clipboardChangeCount: Int? = nil, allowsCopyFallback: Bool = false) {
        guard !isTransferringFiles, !urls.isEmpty else { return }
        do {
            let plan = try operations.prepareTransfer(urls, to: directory, mode: mode,
                                                      allowsCopyFallback: allowsCopyFallback)
            guard !plan.items.isEmpty else { return }
            isTransferringFiles = true
            let selectionRevision = selectionIntentRevision
            let columnIdentity = columns.first?.instanceID
            Task { [self] in
                let result = await Task.detached(priority: .userInitiated) { Result { try plan.execute() } }.value
                isTransferringFiles = false
                let completed: [BrowserTransferPlan.Item]
                switch result {
                case .success: completed = plan.items
                case .failure(let error):
                    completed = (error as? BrowserTransferFailure)?.completed ?? []
                    errorMessage = error.localizedDescription
                }
                let name = mode == .move ? "Move" : mode == .duplicate ? "Duplicate" : "Paste"
                fileHistory.record(name, undo: completed.reversed().map {
                    .init(source: $0.destination, destination: $0.movesSource ? $0.source : nil)
                })
                if let clipboardChangeCount, !completed.isEmpty {
                    let moved = Dictionary(uniqueKeysWithValues: completed.filter(\.movesSource).map {
                        ($0.source.standardizedFileURL.path, $0.destination)
                    })
                    let updated = urls.map { moved[$0.standardizedFileURL.path] ?? $0 }
                    if clipboard.pasteboard.changeCount == clipboardChangeCount {
                        clipboard.write(updated, cut: completed.count != plan.items.count)
                    }
                }
                // Refresh even after a partial failure: the completed items are real.
                onFileSystemChange()
                reloadAllColumns()
                guard let target = completed.first?.destination.deletingLastPathComponent() else { return }
                reloadColumn(at: target) { [weak self] in
                    guard let self, self.selectionIntentRevision == selectionRevision,
                          self.columns.first?.instanceID == columnIdentity,
                          let index = self.columns.firstIndex(where: { $0.url.standardizedFileURL.path == target.standardizedFileURL.path }) else { return }
                    let paths = Set(completed.map { $0.destination.standardizedFileURL.path })
                    let ids = self.columns[index].entries.filter { paths.contains($0.url.standardizedFileURL.path) }.map(\.id)
                    self.applySelection(ids: Set(ids), primary: ids.first, inColumn: index, descendsIntoDirectories: false)
                    self.scrollToSelectionToken += 1
                    self.requestColumnFocus()
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    /// Drag-and-drop landing point. `copy` mirrors holding ⌥ during the drag.
    func drop(_ urls: [URL], into directory: URL, copy: Bool) {
        transferFiles(urls, to: directory, mode: copy ? .copy : .move, allowsCopyFallback: true)
    }

    /// Navigates to a location, opening the columns down to it and leaving it
    /// selected. A browser host-only reveal can suppress the final file preview so
    /// one explicit action never also opens the retained Viewer.
    func navigate(to url: URL, previewsFileSelection: Bool = true) {
        let target = url.standardizedFileURL
        // Outside every configured root — an index entry whose root was since
        // removed, say — the target's own folder becomes a one-off root, so the
        // walk below still has somewhere to start and the file still ends up
        // selected rather than merely on screen.
        let root = navigationRoots.first {
            target.path == $0.standardizedFileURL.path
                || target.path.hasPrefix($0.standardizedFileURL.path + "/")
        } ?? (Self.isDirectory(target) ? target : target.deletingLastPathComponent())

        setRoot(root)
        Task { [weak self] in
            await self?.revealPath(
                from: root,
                to: target,
                previewsFileSelection: previewsFileSelection
            )
            // Only after the walk: the column the user lands on does not exist
            // until its listing has arrived, so focusing earlier would put the
            // keyboard on the root column and undo the reveal on the next
            // arrow press.
            self?.requestColumnFocus()
        }
    }

    /// `URL.hasDirectoryPath` only reports the trailing slash, which a path
    /// rebuilt from the search index does not carry. This asks the disk.
    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    // MARK: - Loading

    private func loadColumn(at index: Int) {
        guard columns.indices.contains(index) else { return }
        let url = columns[index].url
        columns[index].isLoading = true
        columns[index].errorMessage = nil
        installWatcher(for: url)
        load(url)
    }

    func retryColumn(at index: Int) {
        guard columns.indices.contains(index) else { return }
        loadColumn(at: index)
        focusColumn(at: index)
    }

    /// `DirectoryLister` is an actor, so the `contentsOfDirectory` call already
    /// runs off the main actor; this only awaits it and folds the result back in.
    private func load(_ url: URL, then completion: (() -> Void)? = nil) {
        let showHidden = preferences.showHiddenFiles
        let sort = preferences.sortOrder
        Task { [weak self] in
            guard let self else { return }
            let result: Result<[DirectoryEntry], Error>
            do {
                result = .success(try await self.lister.contents(of: url, showHidden: showHidden, sort: sort))
            } catch {
                result = .failure(error)
            }
            self.apply(result, to: url)
            completion?()
        }
    }

    private func apply(_ result: Result<[DirectoryEntry], Error>, to url: URL) {
        // The column may have been truncated while the listing was in flight.
        guard let index = columns.firstIndex(where: { $0.url == url }) else { return }
        columns[index].isLoading = false
        switch result {
        case let .success(entries):
            columns[index].entries = entries
            columns[index].naturalWidthHint = BrowserColumnSizing.naturalWidth(entries: entries)
            columns[index].errorMessage = nil
            // Drop anything that no longer exists — a rename or an external
            // change can delete rows out from under the selection. Rows that
            // survived stay selected, so a reload doesn't cost the user their
            // multi-selection.
            let surviving = Set(entries.map(\.id))
            columns[index].selectedIDs.formIntersection(surviving)
            if let primary = columns[index].primarySelectedID, !surviving.contains(primary) {
                columns[index].primarySelectedID = columns[index].selectedIDs.first
                truncateColumns(after: index)
            }
        case let .failure(error):
            columns[index].entries = []
            columns[index].errorMessage = error.localizedDescription
        }
    }

    private func reloadAllColumns() {
        for index in columns.indices { loadColumn(at: index) }
    }

    private func reloadColumn(at directory: URL, then completion: (() -> Void)? = nil) {
        guard let index = columns.firstIndex(where: {
            $0.url.standardizedFileURL == directory.standardizedFileURL
        }) else { return }
        load(columns[index].url, then: completion)
    }

    private func truncateColumns(after index: Int) {
        guard columns.count > index + 1 else { return }
        for column in columns[(index + 1)...] { watchers.removeValue(forKey: column.url)?.stop() }
        columns.removeSubrange((index + 1)...)
        focusedColumnIndex = min(focusedColumnIndex, columns.count - 1)
    }

    private func installWatcher(for url: URL) {
        guard watchers[url] == nil else { return }
        watchers[url] = DirectoryWatcher(url: url) { [weak self] in
            self?.reloadColumn(at: url)
        }
    }

    /// The row to land on after `skipping` disappears: the nearest survivor
    /// below, else the nearest above. Without the skip set a multi-row trash
    /// would select a row that is about to vanish too.
    private func neighbourID(
        after entry: DirectoryEntry,
        in columnIndex: Int,
        skipping: Set<URL> = []
    ) -> URL? {
        guard columns.indices.contains(columnIndex) else { return nil }
        let entries = columns[columnIndex].entries
        guard let index = columns[columnIndex].rowIndex(for: entry.id) else { return nil }
        if let below = entries[(index + 1)...].first(where: { !skipping.contains($0.id) }) {
            return below.id
        }
        return entries[..<index].last(where: { !skipping.contains($0.id) })?.id
    }

    /// Walks `root` down to `target`, one column at a time, waiting for each
    /// listing so the selection lands on a row that actually exists yet.
    private func revealPath(
        from root: URL,
        to target: URL,
        previewsFileSelection: Bool
    ) async {
        let rootComponents = root.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        guard targetComponents.count > rootComponents.count else { return }

        var current = root.standardizedFileURL
        for component in targetComponents[rootComponents.count...] {
            guard let index = columns.firstIndex(where: { $0.url.standardizedFileURL == current }) else { return }
            // Wait out the in-flight listing for this column.
            for _ in 0..<50 where columns.indices.contains(index) && columns[index].isLoading {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard columns.indices.contains(index) else { return }
            current = current.appendingPathComponent(component)
            guard let match = columns[index].entries.first(where: {
                $0.url.standardizedFileURL == current
            }) else { return }
            // The entry's own URL, never the standardized `current`. A row's id
            // *is* its raw URL, and standardizing rewrites `/private/var` to
            // `/var` — so selecting `current` set a `primarySelectedID` that
            // matched no entry, and the walk stalled one column short of the
            // target with nothing selected.
            let isTarget = match.url.standardizedFileURL == target.standardizedFileURL
            applySelection(
                ids: [match.url],
                primary: match.url,
                inColumn: index,
                descendsIntoDirectories: true,
                publishesPreviewIntent: previewsFileSelection || !isTarget || match.isDirectory
            )
            scrollToSelectionToken += 1
        }
    }

    private func reportNotAuthorized(_ url: URL) {
        errorMessage = BrowserFileOperationError.notAuthorized(url).localizedDescription
    }
}

extension FileSearchResult {
    /// Bridges a browser row into the shape Quick Look and the detail pane
    /// already understand, so neither needed a second model.
    init(entry: DirectoryEntry) {
        self.init(
            url: entry.url,
            displayName: entry.displayName,
            contentType: entry.contentType?.identifier,
            fileSize: entry.fileSize,
            createdAt: nil,
            modifiedAt: entry.modifiedAt,
            lastUsedAt: nil
        )
    }
}

import AppKit

@MainActor
struct DrawerAction: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let shortcut: String
    let run: () -> Void
}

extension DrawerWorkspace {
    var filteredActions: [DrawerAction] {
        let words = actionQuery.split(whereSeparator: \.isWhitespace)
        return contextActions.filter { action in
            words.allSatisfy { action.title.localizedCaseInsensitiveContains($0) }
        }
    }

    func presentActions() {
        if isActionsPresented { dismissActions(); return }
        let wasSearching = isSearchPresented
        let searchSelection = selectedResult
        let directory = contextDirectory
        dismissPalette(restoringFocus: false)
        quickLook.close()
        actionQuery = ""
        selectedActionIndex = 0
        var actions: [DrawerAction] = []
        func add(_ id: String, _ title: String, _ symbol: String, _ shortcut: String = "", _ run: @escaping () -> Void) {
            actions.append(DrawerAction(id: id, title: title, symbol: symbol, shortcut: shortcut, run: run))
        }
        if wasSearching, let result = searchSelection {
            actionContextTitle = result.displayName
            add("open", "Open", "arrow.up.forward.app", "↵") { [weak self] in self?.openResult(result) }
            add("reveal", "Reveal in Browser", "folder") { [weak self] in self?.reveal(result) }
            add("finder", "Show in Finder", "finder") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
            add("copy", "Copy", "doc.on.doc", BrowserCommand.copy.shortcutDescription) {
                BrowserFileClipboard().write([result.url])
            }
            add("copyPath", "Copy Path", "doc.on.clipboard", BrowserCommand.copyPath.shortcutDescription) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.url.path, forType: .string)
            }
        } else if let browser, !wasSearching {
            let selection = browser.focusedEntries.map(\.url)
            actionContextTitle = selection.count > 1 ? "\(selection.count) selected items"
                : browser.focusedEntry?.displayName ?? directory.lastPathComponent
            for command in [BrowserCommand.open, .quickLook, .copy, .cut, .paste, .moveHere, .duplicate, .rename, .newFolder, .showInFinder, .copyPath, .moveToTrash, .undo, .redo] {
                guard browser.canPerform(command) else { continue }
                if [.rename, .moveToTrash].contains(command), !selection.allSatisfy({ folders.canWrite(to: $0) }) { continue }
                if command == .newFolder, !folders.canWrite(to: directory) { continue }
                add(command.rawValue, browser.title(for: command), command.symbol, command.shortcutDescription) { [weak self, weak browser] in
                    guard let self, let browser, self.browser === browser,
                          browser.focusedEntries.map(\.url) == selection else { return }
                    browser.perform(command)
                }
            }
        } else {
            actionContextTitle = terminal.map { "Terminal · \($0.directory.lastPathComponent)" } ?? "Finder Drawer"
        }
        add("terminal", "Open Terminal Here in New Tab", "terminal", BrowserCommand.newTerminal.shortcutDescription) { [weak self] in self?.newTerminal(at: directory) }
        add("files", "Open Folder in New Tab", "folder.badge.plus", BrowserCommand.newTab.shortcutDescription) { [weak self] in self?.newTab(at: directory) }
        for command in [BrowserCommand.search, .goToFolder, .splitPane, .closeSplit, .focusOtherPane, .toggleSidebar, .nextTab, .previousTab, .closeTab, .settings] {
            if [.closeSplit, .focusOtherPane].contains(command) && !isSplit { continue }
            add(command.rawValue, command.title, command.symbol, command.shortcutDescription) { [weak self] in self?.perform(command) }
        }
        contextActions = actions
        isActionsPresented = true
        requestPaletteFocus()
    }

    func dismissActions(restoringFocus: Bool = true) {
        isActionsPresented = false
        contextActions = []
        if restoringFocus { onRequestColumnFocus?() }
    }

    func moveActionSelection(by offset: Int) {
        selectedActionIndex = min(max(0, selectedActionIndex + offset), max(0, filteredActions.count - 1))
    }

    func executeSelectedAction() {
        guard filteredActions.indices.contains(selectedActionIndex) else { return }
        runAction(filteredActions[selectedActionIndex])
    }

    func executeAction(for command: BrowserCommand) -> Bool {
        let id = command == .newTerminal ? "terminal" : command == .newTab ? "files" : command.rawValue
        guard let action = contextActions.first(where: { $0.id == id }) else { return false }
        runAction(action)
        return true
    }

    private func runAction(_ action: DrawerAction) {
        dismissActions(restoringFocus: false)
        action.run()
        if !isPalettePresented && browser?.renamingURL == nil { onRequestColumnFocus?() }
    }
}

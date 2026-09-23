import AppKit

/// Every action the browser can perform, declared once.
///
/// Context menus and the drawer key handler share these definitions.
enum BrowserCommand: String, CaseIterable, Identifiable, Sendable {
    case open
    case openWith
    case quickLook
    case rename
    case newFolder
    case moveToTrash
    case showInFinder
    case copyPath
    case copy, cut, paste, moveHere, duplicate, undo, redo
    case goToFolder
    case toggleHiddenFiles
    case newTab
    case closeTab
    case search
    case settings
    case actions, newTerminal, toggleSidebar, nextTab, previousTab
    case splitPane, splitTerminal, splitFiles, closeSplit, focusOtherPane

    var id: Self { self }

    var title: String {
        title(showHiddenFiles: false)
    }

    func title(showHiddenFiles: Bool) -> String {
        switch self {
        case .open: "Open"
        case .openWith: "Open With…"
        case .quickLook: "Quick Look"
        case .rename: "Rename"
        case .newFolder: "New Folder"
        case .moveToTrash: "Move to Trash"
        case .showInFinder: "Show in Finder"
        case .undo: "Undo"
        case .redo: "Redo"
        case .copy: "Copy"
        case .cut: "Cut"
        case .paste: "Paste"
        case .moveHere: "Move Item Here"
        case .duplicate: "Duplicate"
        case .copyPath: "Copy Path"
        case .goToFolder: "Go to Folder…"
        case .toggleHiddenFiles: showHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files"
        case .newTab: "New File Tab"
        case .closeTab: "Close Tab"
        case .search: "Search Files"
        case .settings: "Settings…"
        case .splitPane: "Split Right"
        case .splitTerminal: "Split with Terminal"
        case .splitFiles: "Split with File Browser"
        case .closeSplit: "Unpair Tabs"
        case .focusOtherPane: "Focus Other Pane"
        case .actions: "Actions"
        case .newTerminal: "Open Terminal Here in New Tab"
        case .toggleSidebar: "Toggle Sidebar"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        }
    }

    var symbol: String {
        switch self {
        case .open: "arrow.up.forward.app"
        case .openWith: "square.and.arrow.up"
        case .quickLook: "eye"
        case .rename: "pencil"
        case .newFolder: "folder.badge.plus"
        case .moveToTrash: "trash"
        case .showInFinder: "finder"
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .copy: "doc.on.doc"
        case .cut: "scissors"
        case .paste: "doc.on.clipboard"
        case .moveHere: "arrow.down.doc"
        case .duplicate: "plus.square.on.square"
        case .copyPath: "doc.on.clipboard"
        case .goToFolder: "arrow.right.circle"
        case .toggleHiddenFiles: "eye.slash"
        case .newTab: "plus.rectangle.on.rectangle"
        case .closeTab: "xmark.rectangle"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        case .splitPane, .splitTerminal, .splitFiles: "rectangle.split.2x1"
        case .closeSplit: "rectangle"
        case .focusOtherPane: "arrow.left.arrow.right"
        case .actions: "slider.horizontal.3"
        case .newTerminal: "terminal"
        case .toggleSidebar: "sidebar.left"
        case .nextTab: "arrow.right"
        case .previousTab: "arrow.left"
        }
    }

    /// Display form of the primary shortcut, e.g. "⇧⌘N".
    var shortcutDescription: String {
        guard let primaryShortcut else { return "" }
        return primaryShortcut.modifierGlyphs + primaryShortcut.character
    }

    struct Shortcut: Equatable {
        let keyCode: UInt16
        let character: String
        let modifiers: NSEvent.ModifierFlags

        func matches(
            keyCode candidateKeyCode: UInt16,
            modifiers candidateModifiers: NSEvent.ModifierFlags
        ) -> Bool {
            keyCode == candidateKeyCode && modifiers == candidateModifiers
        }

        var modifierGlyphs: String {
            var glyphs = ""
            if modifiers.contains(.control) { glyphs += "⌃" }
            if modifiers.contains(.option) { glyphs += "⌥" }
            if modifiers.contains(.shift) { glyphs += "⇧" }
            if modifiers.contains(.command) { glyphs += "⌘" }
            return glyphs
        }
    }

    /// The binding shown in menus and the drawer omnibox.
    var primaryShortcut: Shortcut? {
        switch self {
        case .open: Shortcut(keyCode: 36, character: "↵", modifiers: .command)
        case .openWith: Shortcut(keyCode: 31, character: "O", modifiers: [.command, .shift])
        case .quickLook: Shortcut(keyCode: 49, character: "Space", modifiers: [])
        case .rename: Shortcut(keyCode: 36, character: "↵", modifiers: [])
        case .newFolder: Shortcut(keyCode: 45, character: "N", modifiers: [.command, .shift])
        case .moveToTrash: Shortcut(keyCode: 51, character: "⌫", modifiers: .command)
        case .showInFinder: Shortcut(keyCode: 15, character: "R", modifiers: [.command, .shift])
        case .undo: Shortcut(keyCode: 6, character: "Z", modifiers: .command)
        case .redo: Shortcut(keyCode: 6, character: "Z", modifiers: [.command, .shift])
        case .copy: Shortcut(keyCode: 8, character: "C", modifiers: .command)
        case .cut: Shortcut(keyCode: 7, character: "X", modifiers: .command)
        case .paste: Shortcut(keyCode: 9, character: "V", modifiers: .command)
        case .moveHere: Shortcut(keyCode: 9, character: "V", modifiers: [.command, .option])
        case .duplicate: Shortcut(keyCode: 2, character: "D", modifiers: [.command, .shift])
        case .copyPath: Shortcut(keyCode: 8, character: "C", modifiers: [.command, .option])
        case .goToFolder: Shortcut(keyCode: 5, character: "G", modifiers: [.command, .shift])
        case .toggleHiddenFiles: Shortcut(keyCode: 47, character: ".", modifiers: .command)
        case .newTab: Shortcut(keyCode: 45, character: "N", modifiers: .command)
        case .closeTab: Shortcut(keyCode: 13, character: "W", modifiers: .command)
        case .search: Shortcut(keyCode: 3, character: "F", modifiers: .command)
        case .splitPane: Shortcut(keyCode: 42, character: "\\", modifiers: .command)
        case .splitTerminal: Shortcut(keyCode: 2, character: "D", modifiers: .command)
        case .splitFiles: Shortcut(keyCode: 1, character: "S", modifiers: .command)
        case .closeSplit: Shortcut(keyCode: 42, character: "\\", modifiers: [.command, .shift])
        case .focusOtherPane: Shortcut(keyCode: 124, character: "→", modifiers: [.command, .option])
        case .actions: Shortcut(keyCode: 40, character: "K", modifiers: .command)
        case .newTerminal: Shortcut(keyCode: 17, character: "T", modifiers: .command)
        case .toggleSidebar: Shortcut(keyCode: 1, character: "S", modifiers: [.command, .control])
        case .nextTab: Shortcut(keyCode: 48, character: "⇥", modifiers: .control)
        case .previousTab: Shortcut(keyCode: 48, character: "⇥", modifiers: [.control, .shift])
        case .settings: Shortcut(keyCode: 43, character: ",", modifiers: .command)
        }
    }

    /// Additional accepted bindings that are intentionally not advertised
    /// beside the command.
    var alternateShortcuts: [Shortcut] {
        switch self {
        case .open:
            [
                Shortcut(keyCode: 76, character: "↵", modifiers: .command),
                Shortcut(keyCode: 125, character: "↓", modifiers: .command),
            ]
        case .quickLook:
            [Shortcut(keyCode: 16, character: "Y", modifiers: .command)]
        case .rename:
            [Shortcut(keyCode: 76, character: "↵", modifiers: [])]
        case .showInFinder:
            [Shortcut(keyCode: 34, character: "I", modifiers: .command)]
        case .goToFolder:
            [Shortcut(keyCode: 31, character: "O", modifiers: [])]
        case .focusOtherPane:
            [Shortcut(keyCode: 123, character: "←", modifiers: [.command, .option])]
        case .search:
            [Shortcut(keyCode: 44, character: "/", modifiers: .command)]
        case .undo, .redo, .copy, .cut, .paste, .moveHere, .duplicate,
             .openWith, .newFolder, .moveToTrash, .copyPath, .splitPane, .splitTerminal, .splitFiles, .closeSplit,
             .toggleHiddenFiles, .newTab, .closeTab,
             .settings, .actions, .newTerminal, .toggleSidebar, .nextTab, .previousTab:
            []
        }
    }

    var shortcuts: [Shortcut] {
        (primaryShortcut.map { [$0] } ?? []) + alternateShortcuts
    }

    /// How many browser rows a command can sensibly act on.
    ///
    /// A command being keyboard-reachable must not make it bypass the same
    /// cardinality rules as the context menu. In particular, there is no
    /// honest meaning for "Rename" or "Quick Look" when three rows are
    /// selected, while trash, reveal, and copy-path are deliberately batch
    /// operations.
    enum SelectionRequirement: Equatable, Sendable {
        case none
        case exactlyOne
        case oneOrMore

        func isSatisfied(by count: Int) -> Bool {
            switch self {
            case .none:
                true
            case .exactlyOne:
                count == 1
            case .oneOrMore:
                count > 0
            }
        }
    }

    var selectionRequirement: SelectionRequirement {
        switch self {
        case .open, .openWith, .quickLook, .rename:
            .exactlyOne
        case .copy, .cut, .duplicate, .moveToTrash, .showInFinder, .copyPath:
            .oneOrMore
        case .undo, .redo, .paste, .moveHere, .newFolder, .goToFolder, .toggleHiddenFiles,
             .splitPane, .splitTerminal, .splitFiles, .closeSplit, .focusOtherPane, .newTab, .closeTab, .search, .settings, .actions, .newTerminal, .toggleSidebar, .nextTab, .previousTab:
            .none
        }
    }

    static func matching(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> BrowserCommand? {
        allCases.first { command in
            command.shortcuts.contains {
                $0.matches(keyCode: keyCode, modifiers: modifiers)
            }
        }
    }

    /// Commands offered in a row's context menu, in menu order. `nil` marks a
    /// separator.
    static let contextMenuOrder: [BrowserCommand?] = [
        .open, .openWith, .quickLook,
        nil,
        .copy, .cut, .paste, .moveHere, .duplicate,
        nil,
        .rename, .newFolder, .moveToTrash,
        nil,
        .showInFinder, .copyPath,
        nil,
    ]
}

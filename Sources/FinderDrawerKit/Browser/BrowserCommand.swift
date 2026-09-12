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
    case goToFolder
    case toggleHiddenFiles
    case newTab
    case closeTab
    case search
    case settings

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
        case .copyPath: "Copy Path"
        case .goToFolder: "Go to Folder…"
        case .toggleHiddenFiles: showHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files"
        case .newTab: "New Tab"
        case .closeTab: "Close Tab"
        case .search: "Search Files"
        case .settings: "Settings…"
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
        case .copyPath: "doc.on.clipboard"
        case .goToFolder: "arrow.right.circle"
        case .toggleHiddenFiles: "eye.slash"
        case .newTab: "plus.rectangle.on.rectangle"
        case .closeTab: "xmark.rectangle"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
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
        case .copyPath: Shortcut(keyCode: 8, character: "C", modifiers: [.command, .option])
        case .goToFolder: Shortcut(keyCode: 5, character: "G", modifiers: [.command, .shift])
        case .toggleHiddenFiles: Shortcut(keyCode: 47, character: ".", modifiers: .command)
        case .newTab: Shortcut(keyCode: 17, character: "T", modifiers: .command)
        case .closeTab: Shortcut(keyCode: 13, character: "W", modifiers: .command)
        case .search: Shortcut(keyCode: 40, character: "K", modifiers: .command)
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
        case .search:
            [Shortcut(keyCode: 44, character: "/", modifiers: .command)]
        case .openWith, .newFolder, .moveToTrash, .copyPath, .goToFolder,
             .toggleHiddenFiles, .newTab, .closeTab,
             .settings:
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
        case .moveToTrash, .showInFinder, .copyPath:
            .oneOrMore
        case .newFolder, .goToFolder, .toggleHiddenFiles,
             .newTab, .closeTab, .search, .settings:
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
        .rename, .newFolder, .moveToTrash,
        nil,
        .showInFinder, .copyPath,
        nil,
    ]
}

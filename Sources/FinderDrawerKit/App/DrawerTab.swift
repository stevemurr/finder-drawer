import Foundation

@MainActor
struct DrawerTab: Identifiable {
    let id: UUID
    let browser: BrowserViewModel?
    let terminal: TerminalSession?
    init(browser: BrowserViewModel) { id = browser.id; self.browser = browser; terminal = nil }
    init(terminal: TerminalSession) { id = terminal.id; self.terminal = terminal; browser = nil }
    var currentRoot: URL? { browser?.currentRoot ?? terminal?.directory }
    var title: String {
        if let terminal { return terminal.title == "Terminal" ? "Terminal · \(terminal.directory.lastPathComponent)" : terminal.title }
        return currentRoot.map { $0.lastPathComponent.isEmpty ? "/" : $0.lastPathComponent } ?? "Files"
    }
    var symbol: String { terminal == nil ? "folder" : "terminal" }
}

struct SavedDrawerTab: Codable {
    enum Kind: String, Codable { case browser, terminal }
    let kind: Kind
    let path: String
}

/// The tab strip owns groups; each group presents one session or a lasting pair.
struct DrawerTabGroup: Identifiable {
    let id: UUID
    var primaryID: UUID
    var secondaryID: UUID?
    var focusedID: UUID

    init(id: UUID = UUID(), primaryID: UUID, secondaryID: UUID? = nil, focusedID: UUID? = nil) {
        self.id = id
        self.primaryID = primaryID
        self.secondaryID = secondaryID
        self.focusedID = focusedID == secondaryID ? secondaryID ?? primaryID : primaryID
    }

    var memberIDs: [UUID] { [primaryID] + (secondaryID.map { [$0] } ?? []) }
}

struct SavedDrawerTabGroup: Codable {
    /// Indices into the saved session list; kept separate from runtime UUIDs.
    let members: [Int]
    let focusedMember: Int
}

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

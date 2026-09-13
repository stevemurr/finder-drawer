import AppKit

/// Real file URLs make copies interoperable with Finder and other macOS apps.
/// Cutting is only an intent; the originals remain intact until a successful paste.
@MainActor
struct BrowserFileClipboard {
    private static let cutType = NSPasteboard.PasteboardType("com.stevemurr.finder-drawer.cut-files")
    let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    var urls: [URL] {
        let values = pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        var seen = Set<String>()
        return values.filter { $0.isFileURL && seen.insert($0.standardizedFileURL.path).inserted }
    }

    var isCut: Bool { pasteboard.string(forType: Self.cutType) == "move" }

    @discardableResult
    func write(_ urls: [URL], cut: Bool = false) -> Bool {
        guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls.map { $0 as NSURL }) else { return false }
        if cut { pasteboard.setString("move", forType: Self.cutType) }
        return true
    }

}

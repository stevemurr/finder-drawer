import Foundation
import UniformTypeIdentifiers

/// How a browser column orders its rows.
enum BrowserSort: String, CaseIterable, Identifiable, Sendable {
    case name
    case modified
    case size
    case kind

    var id: Self { self }

    var label: String {
        switch self {
        case .name: "Name"
        case .modified: "Date Modified"
        case .size: "Size"
        case .kind: "Kind"
        }
    }
}

/// One row in a browser column.
struct DirectoryEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let displayName: String
    /// True only for directories the browser should descend into. Packages such
    /// as `.app` and `.rtfd` are directories on disk but leaves here, matching
    /// how Finder presents them.
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    let fileSize: Int64?
    let modifiedAt: Date?
    let contentType: UTType?
    /// Resolved once when the entry is built, off the main actor.
    /// `UTType.localizedDescription` is a Launch Services lookup, and rows
    /// read it on every configure and the Kind sort on every comparison.
    let kindDescription: String

    var id: URL { url }

    init(
        url: URL,
        displayName: String,
        isDirectory: Bool,
        isPackage: Bool,
        isHidden: Bool,
        fileSize: Int64?,
        modifiedAt: Date?,
        contentType: UTType?,
        kindDescription: String? = nil
    ) {
        self.url = url
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.contentType = contentType
        self.kindDescription = kindDescription
            ?? contentType?.localizedDescription
            ?? (isDirectory ? "Folder" : "Document")
    }
}

/// One directory read, plus the width measured from it while still off the
/// main actor.
struct DirectoryListing: Sendable {
    let entries: [DirectoryEntry]
    let naturalWidth: CGFloat
}

enum DirectoryListerError: LocalizedError {
    case unreadable(URL, underlying: String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(url, underlying):
            "Can't read \(url.lastPathComponent): \(underlying)"
        }
    }
}

/// Reads directory contents off the main actor.
///
/// A plain `contentsOfDirectory` call on a large folder is slow enough to drop
/// frames while browser host opens, so every listing is hopped off the
/// main actor even though the API itself is synchronous.
actor DirectoryLister {
    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .isHiddenKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .localizedNameKey,
        .contentTypeKey,
    ]

    func contents(
        of directory: URL,
        showHidden: Bool,
        sort: BrowserSort
    ) throws -> [DirectoryEntry] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Self.resourceKeys,
                options: showHidden ? [] : [.skipsHiddenFiles]
            )
        } catch {
            throw DirectoryListerError.unreadable(directory, underlying: error.localizedDescription)
        }

        let entries = urls.compactMap { Self.makeEntry(for: $0) }
        return Self.sorted(entries, by: sort)
    }

    /// Lists and measures in one hop, so filename measurement for a large
    /// folder never runs on the main actor when the listing lands.
    func listing(
        of directory: URL,
        showHidden: Bool,
        sort: BrowserSort
    ) throws -> DirectoryListing {
        let entries = try contents(of: directory, showHidden: showHidden, sort: sort)
        return DirectoryListing(
            entries: entries,
            naturalWidth: BrowserColumnSizing.naturalWidth(entries: entries)
        )
    }

    private static let resourceKeySet = Set(resourceKeys)

    static func makeEntry(for url: URL) -> DirectoryEntry? {
        let values = try? url.resourceValues(forKeys: resourceKeySet)
        let isPackage = values?.isPackage ?? false
        return DirectoryEntry(
            url: url,
            displayName: values?.localizedName ?? url.lastPathComponent,
            isDirectory: (values?.isDirectory ?? false) && !isPackage,
            isPackage: isPackage,
            isHidden: values?.isHidden ?? false,
            fileSize: (values?.fileSize).map(Int64.init),
            modifiedAt: values?.contentModificationDate,
            contentType: values?.contentType
        )
    }

    /// Folders sort ahead of files in every mode, as in Finder's column view.
    static func sorted(_ entries: [DirectoryEntry], by sort: BrowserSort) -> [DirectoryEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            switch sort {
            case .name:
                break
            case .modified:
                let left = lhs.modifiedAt ?? .distantPast
                let right = rhs.modifiedAt ?? .distantPast
                if left != right { return left > right }
            case .size:
                let left = lhs.fileSize ?? 0
                let right = rhs.fileSize ?? 0
                if left != right { return left > right }
            case .kind:
                let left = lhs.kindDescription
                let right = rhs.kindDescription
                if left != right { return left.localizedStandardCompare(right) == .orderedAscending }
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }
}

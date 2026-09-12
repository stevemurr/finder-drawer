import AppKit
import Foundation
import UniformTypeIdentifiers

struct FileSearchResult: Identifiable, Hashable, Sendable {
    let url: URL
    let displayName: String
    let contentType: String?
    let fileSize: Int64?
    let createdAt: Date?
    let modifiedAt: Date?
    let lastUsedAt: Date?

    var id: URL { url }

    var isDirectory: Bool {
        guard let contentType, let type = UTType(contentType) else { return false }
        return type.conforms(to: .directory)
    }

    var kindDescription: String {
        guard let contentType, let description = UTType(contentType)?.localizedDescription else {
            return url.pathExtension.isEmpty ? "File" : "\(url.pathExtension.uppercased()) file"
        }
        return description
    }

    var parentPath: String {
        url.deletingLastPathComponent().path
    }

    static func fixture(url: URL) -> FileSearchResult {
        FileSearchResult(
            url: url,
            displayName: url.lastPathComponent,
            contentType: nil,
            fileSize: nil,
            createdAt: nil,
            modifiedAt: nil,
            lastUsedAt: nil
        )
    }
}

enum SearchScope: String {
    case thisMac = "This Mac"
    case home = "Home Folder"
    case iCloud = "iCloud Drive"

    var pathPrefix: String? {
        switch self {
        case .thisMac:
            nil
        case .home:
            FileManager.default.homeDirectoryForCurrentUser.path
        case .iCloud:
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents", isDirectory: true).path
        }
    }

    static var indexRoots: [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var roots = [home, URL(fileURLWithPath: "/Users/Shared", isDirectory: true)]
        let externalVolumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsBrowsableKey],
            options: [.skipHiddenVolumes]
        )?.filter { url in
            url.path.hasPrefix("/Volumes/")
                && (try? url.resourceValues(forKeys: [.volumeIsBrowsableKey]).volumeIsBrowsable) != false
        } ?? []
        roots.append(contentsOf: externalVolumes)
        return roots
    }
}

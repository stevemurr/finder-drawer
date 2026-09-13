import AppKit
import Foundation
import Observation

/// Persists the roots chosen for browsing, indexing, and file writes.
/// This standalone app uses plain paths and is not App Sandbox enabled.
/// A sandboxed embedding app must supply security-scoped access separately.
@MainActor
@Observable
final class FolderAccessManager {
    private static let pathsKey = "indexedFolderPaths"

    var allowsSystemWideAccess: Bool {
        didSet { defaults.set(allowsSystemWideAccess, forKey: "browserSystemWideAccess") }
    }

    private(set) var folders: [URL] = []
    private(set) var errorMessage: String?

    @ObservationIgnored private let defaults: UserDefaults

    /// - Parameter initialFolders: roots supplied directly rather than read from
    ///   defaults. Only the UI-test composition uses this.
    init(
        defaults: UserDefaults = .standard,
        loadStoredPaths: Bool = true,
        initialFolders: [URL] = [],
        allowsSystemWideAccess: Bool = false
    ) {
        self.defaults = defaults
        self.allowsSystemWideAccess = loadStoredPaths
            ? (defaults.object(forKey: "browserSystemWideAccess") as? Bool ?? allowsSystemWideAccess)
            : allowsSystemWideAccess
        if loadStoredPaths { restoreFolders() }
        folders.append(contentsOf: initialFolders.map(\.standardizedFileURL))
        if !initialFolders.isEmpty { normalizeFolders() }
    }

    /// Whether `url` sits inside a granted root, and so may be modified.
    func canWrite(to url: URL) -> Bool {
        writableRoot(containing: url) != nil
    }

    /// The configured root containing `url`, if any.
    func writableRoot(containing url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        // This is an application policy, not a macOS permission grant. The OS
        // still enforces TCC, filesystem permissions, and protected volumes.
        if allowsSystemWideAccess { return URL(fileURLWithPath: "/", isDirectory: true) }
        let path = Self.resolvedPath(url)
        return folders.first { root in
            let rootPath = Self.resolvedPath(root)
            if path == rootPath { return true }
            return path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
        }
    }

    /// Standardization alone leaves symlink components intact. Resolving them
    /// makes the configured roots an actual filesystem boundary, including
    /// for a not-yet-created leaf whose parent contains a symlink.
    private static func resolvedPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().path
        }
        let parent = standardized.deletingLastPathComponent()
            .resolvingSymlinksInPath()
        return parent.appendingPathComponent(standardized.lastPathComponent).path
    }

    @discardableResult
    func chooseFolders() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Choose Folders to Index"
        panel.message = "Choose one or more folders. Finder Drawer will index their names and let you manage files inside them."
        panel.prompt = "Choose Folders"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return false }

        var addedAny = false
        for url in panel.urls {
            let standardized = url.standardizedFileURL
            guard !folders.contains(where: { $0.standardizedFileURL == standardized }) else { continue }
            folders.append(standardized)
            addedAny = true
        }
        if addedAny {
            normalizeFolders()
            persistFolders()
            errorMessage = nil
        }
        return addedAny
    }

    func removeFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        folders.removeAll { $0.standardizedFileURL.path == path }
        persistFolders()
    }

    // MARK: - Persistence

    private func restoreFolders() {
        folders = defaults.standardizedFileURLs(forKey: Self.pathsKey)
        normalizeFolders()
    }

    private func normalizeFolders() {
        folders.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func persistFolders() {
        defaults.setStandardizedFileURLs(folders, forKey: Self.pathsKey)
    }
}

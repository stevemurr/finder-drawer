import Foundation

enum BrowserFileOperationError: LocalizedError, Equatable {
    /// The target is outside every folder configured as a writable root.
    case notAuthorized(URL)
    case emptyName
    case invalidName(String)
    case alreadyExists(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .notAuthorized(url):
            "Finder Drawer doesn't have permission to change items in “\(url.lastPathComponent)”."
        case .emptyName:
            "The name can't be empty."
        case let .invalidName(name):
            "“\(name)” isn't a valid name. Names can't contain “/” or “:”."
        case let .alreadyExists(name):
            "An item named “\(name)” already exists here."
        case let .failed(message):
            message
        }
    }
}

/// The write half of the browser, kept separate from `BrowserViewModel` so the
/// destructive paths can be tested against a temp directory without a view model
/// or a running app.
@MainActor
struct BrowserFileOperations {
    /// Gate on configured roots. Injected as a closure so tests can exercise
    /// the operations without a `FolderAccessManager`.
    let canWrite: (URL) -> Bool

    init(canWrite: @escaping (URL) -> Bool) {
        self.canWrite = canWrite
    }

    init(folderAccess: FolderAccessManager) {
        self.init { folderAccess.canWrite(to: $0) }
    }

    // MARK: - Create

    /// Creates "untitled folder", then "untitled folder 2", 3, … as Finder does.
    func newFolder(in directory: URL, baseName: String = "untitled folder") throws -> URL {
        guard canWrite(directory) else { throw BrowserFileOperationError.notAuthorized(directory) }
        let target = uniqueURL(in: directory, baseName: baseName, extension: "")
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        } catch {
            throw BrowserFileOperationError.failed(error.localizedDescription)
        }
        return target
    }

    // MARK: - Rename

    @discardableResult
    func rename(_ url: URL, to newName: String) throws -> URL {
        guard canWrite(url) else { throw BrowserFileOperationError.notAuthorized(url) }
        let name = try Self.validated(newName)
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        guard destination.standardizedFileURL != url.standardizedFileURL else { return url }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BrowserFileOperationError.alreadyExists(name)
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            throw BrowserFileOperationError.failed(error.localizedDescription)
        }
        return destination
    }

    static func validated(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BrowserFileOperationError.emptyName }
        // "/" is the path separator and ":" is still the HFS separator that the
        // Finder-facing APIs reject; everything else is fair game on APFS.
        guard !trimmed.contains("/"), !trimmed.contains(":") else {
            throw BrowserFileOperationError.invalidName(trimmed)
        }
        guard trimmed != ".", trimmed != ".." else {
            throw BrowserFileOperationError.invalidName(trimmed)
        }
        return trimmed
    }

    // MARK: - Trash

    /// Moves to the Trash rather than deleting, so the action stays undoable in
    /// Finder. This is the only destructive operation the browser offers.
    @discardableResult
    func trash(_ urls: [URL]) throws -> [URL] {
        for url in urls where !canWrite(url) {
            throw BrowserFileOperationError.notAuthorized(url)
        }
        var trashed: [URL] = []
        for url in urls {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                trashed.append(url)
            } catch {
                throw BrowserFileOperationError.failed(error.localizedDescription)
            }
        }
        return trashed
    }

    // MARK: - Move / copy

    @discardableResult
    func move(_ urls: [URL], to directory: URL) throws -> [URL] {
        try transfer(urls, to: directory) { source, destination in
            // A drag from Finder may originate outside every configured root.
            // In that case "move" would mutate an unauthorized location by
            // deleting its source, so import it as a copy instead.
            if canWrite(source) {
                try FileManager.default.moveItem(at: source, to: destination)
            } else {
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }
    }

    @discardableResult
    func copy(_ urls: [URL], to directory: URL) throws -> [URL] {
        try transfer(urls, to: directory) { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private func transfer(
        _ urls: [URL],
        to directory: URL,
        using body: (URL, URL) throws -> Void
    ) throws -> [URL] {
        guard canWrite(directory) else { throw BrowserFileOperationError.notAuthorized(directory) }
        var results: [URL] = []
        for source in urls {
            guard source.deletingLastPathComponent().standardizedFileURL != directory.standardizedFileURL else {
                continue
            }
            let destination = uniqueURL(
                in: directory,
                baseName: source.deletingPathExtension().lastPathComponent,
                extension: source.pathExtension
            )
            do {
                try body(source, destination)
            } catch {
                throw BrowserFileOperationError.failed(error.localizedDescription)
            }
            results.append(destination)
        }
        return results
    }

    // MARK: - Naming

    private func uniqueURL(in directory: URL, baseName: String, extension ext: String) -> URL {
        func candidate(_ suffix: Int) -> URL {
            let name = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            return ext.isEmpty
                ? directory.appendingPathComponent(name)
                : directory.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var suffix = 1
        var url = candidate(suffix)
        while FileManager.default.fileExists(atPath: url.path) {
            suffix += 1
            url = candidate(suffix)
        }
        return url
    }
}

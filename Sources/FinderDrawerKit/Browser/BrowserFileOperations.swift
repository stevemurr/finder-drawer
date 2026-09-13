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
    func trash(_ urls: [URL], didTrash: (URL, URL) -> Void = { _, _ in }) throws -> [URL] {
        for url in urls where !canWrite(url) {
            throw BrowserFileOperationError.notAuthorized(url)
        }
        var trashed: [URL] = []
        for url in urls {
            do {
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                trashed.append(url)
                if let resulting { didTrash(url, resulting as URL) }
            } catch {
                throw BrowserFileOperationError.failed(error.localizedDescription)
            }
        }
        return trashed
    }

    // MARK: - Move / copy

    @discardableResult
    func move(_ urls: [URL], to directory: URL) throws -> [URL] {
        try prepareTransfer(urls, to: directory, mode: .move, allowsCopyFallback: true).execute()
    }

    @discardableResult
    func copy(_ urls: [URL], to directory: URL) throws -> [URL] {
        try prepareTransfer(urls, to: directory, mode: .copy).execute()
    }

    @discardableResult
    func duplicate(_ urls: [URL]) throws -> [URL] {
        try prepareTransfer(urls, to: nil, mode: .duplicate).execute()
    }

    /// Validate the entire batch before starting; the immutable plan can execute
    /// off the main thread without consulting UI-owned permission state.
    func prepareTransfer(_ urls: [URL], to directory: URL?, mode: BrowserTransferPlan.Mode,
                         allowsCopyFallback: Bool = false) throws -> BrowserTransferPlan {
        let fm = FileManager.default
        var reserved = Set<String>()
        var seen = Set<String>()
        var items: [BrowserTransferPlan.Item] = []
        for source in urls {
            guard source.isFileURL, seen.insert(source.standardizedFileURL.path).inserted else { continue }
            let targetFolder = directory ?? source.deletingLastPathComponent()
            guard canWrite(targetFolder) else { throw BrowserFileOperationError.notAuthorized(targetFolder) }
            let moving = mode == .move && canWrite(source)
            if mode == .move && !moving && !allowsCopyFallback {
                throw BrowserFileOperationError.notAuthorized(source)
            }
            let attributes = try fm.attributesOfItem(atPath: source.path)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: targetFolder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw BrowserFileOperationError.failed("The destination folder no longer exists.")
            }
            let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
            let targetPath = targetFolder.resolvingSymlinksInPath().standardizedFileURL.path
            if attributes[.type] as? FileAttributeType == .typeDirectory,
               targetPath == sourcePath || targetPath.hasPrefix(sourcePath + "/") {
                throw BrowserFileOperationError.failed("A folder can’t be placed inside itself: “\(source.lastPathComponent)”.")
            }
            let sameFolder = source.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == targetPath
            // Moving within the same directory is a no-op; copying there duplicates.
            if moving && sameFolder { continue }
            let values = try? source.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let plainFolder = values?.isDirectory == true && values?.isPackage != true
            let ext = plainFolder ? "" : source.pathExtension
            let stem = ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
            let baseName = mode == .duplicate || sameFolder ? stem + " copy" : stem
            let destination = uniqueURL(in: targetFolder, baseName: baseName, extension: ext, reserved: reserved)
            reserved.insert(destination.standardizedFileURL.path.lowercased())
            items.append(.init(source: source, destination: destination, movesSource: moving))
        }
        return BrowserTransferPlan(items: items)
    }

    // MARK: - Naming

    private func uniqueURL(in directory: URL, baseName: String, extension ext: String, reserved: Set<String> = []) -> URL {
        func candidate(_ suffix: Int) -> URL {
            let name = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            return ext.isEmpty
                ? directory.appendingPathComponent(name)
                : directory.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var suffix = 1
        var url = candidate(suffix)
        while (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
            || reserved.contains(url.standardizedFileURL.path.lowercased()) {
            suffix += 1
            url = candidate(suffix)
        }
        return url
    }
}


struct BrowserTransferPlan: Sendable {
    enum Mode { case copy, move, duplicate }
    struct Item: Sendable {
        let source: URL
        let destination: URL
        let movesSource: Bool
    }
    let items: [Item]

    func execute() throws -> [URL] {
        var completed: [Item] = []
        for item in items {
            do {
                if item.movesSource {
                    try FileManager.default.moveItem(at: item.source, to: item.destination)
                } else {
                    try FileManager.default.copyItem(at: item.source, to: item.destination)
                }
                completed.append(item)
            } catch {
                throw BrowserTransferFailure(completed: completed,
                    message: "Couldn’t \(item.movesSource ? "move" : "copy") “\(item.source.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
        return completed.map(\.destination)
    }
}

struct BrowserTransferFailure: LocalizedError {
    let completed: [BrowserTransferPlan.Item]
    let message: String
    var errorDescription: String? {
        completed.isEmpty ? message : "\(completed.count) item(s) completed. " + message
    }
}

import AppKit
import UniformTypeIdentifiers

/// Row icons without a synchronous Launch Services/disk lookup per row.
///
/// `NSWorkspace.icon(forFile:)` runs on the main actor every time a recycled
/// row scrolls into view. Ordinary documents only ever show their type's icon,
/// so those resolve once per content type. Only items that can carry a custom
/// or bundle-provided icon — folders, packages, apps, aliases, unknown types —
/// still ask for their own path, and that answer is remembered by path.
@MainActor
enum FileIconCache {
    private static let byType: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 512; return cache
    }()
    private static let byPath: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>(); cache.countLimit = 2048; return cache
    }()

    static func icon(for entry: DirectoryEntry) -> NSImage {
        icon(url: entry.url, contentType: entry.contentType, isContainer: entry.isDirectory || entry.isPackage)
    }

    static func icon(for result: FileSearchResult) -> NSImage {
        let type = result.contentType.flatMap { UTType($0) }
        return icon(url: result.url, contentType: type, isContainer: result.isDirectory)
    }

    static func icon(url: URL, contentType: UTType?, isContainer: Bool) -> NSImage {
        if !isContainer, let contentType, !Self.mayHaveOwnIcon(contentType) {
            let key = contentType.identifier as NSString
            if let cached = byType.object(forKey: key) { return cached }
            let image = NSWorkspace.shared.icon(for: contentType)
            byType.setObject(image, forKey: key)
            return image
        }
        let key = url.path as NSString
        if let cached = byPath.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        byPath.setObject(image, forKey: key)
        return image
    }

    private static var ownIconByType: [String: Bool] = [:]

    /// Types whose icon comes from the item itself rather than its type.
    /// Conformance checks are Launch Services queries too, so each type is
    /// classified once.
    private static func mayHaveOwnIcon(_ type: UTType) -> Bool {
        if let known = ownIconByType[type.identifier] { return known }
        let own = type.conforms(to: .directory) || type.conforms(to: .package) || type.conforms(to: .bundle)
            || type.conforms(to: .application) || type.conforms(to: .aliasFile)
            || type.conforms(to: .symbolicLink) || type.conforms(to: .volume)
            || type.isDynamic
        ownIconByType[type.identifier] = own
        return own
    }
}

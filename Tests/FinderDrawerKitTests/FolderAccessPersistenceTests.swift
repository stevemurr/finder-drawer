import Foundation
import XCTest
@testable import FinderDrawerKit

@MainActor
final class FolderAccessPersistenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var directory: URL!
    private var secondDirectory: URL!

    override func setUpWithError() throws {
        suiteName = "folder-access-persistence-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-access-\(UUID().uuidString)", isDirectory: true)
        secondDirectory = directory.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(
            at: secondDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func testStoredPathsAreRestoredStandardizedAndSorted() {
        let unstandardized = secondDirectory
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("Second", isDirectory: true)
        defaults.set(
            [unstandardized.path, directory.path],
            forKey: "indexedFolderPaths"
        )

        let manager = FolderAccessManager(defaults: defaults)

        XCTAssertEqual(
            manager.folders.map(\.standardizedFileURL),
            [directory.standardizedFileURL, secondDirectory.standardizedFileURL]
        )
    }

    func testRemovingFolderPersistsTheRemainingPaths() {
        defaults.set(
            [directory.path, secondDirectory.path],
            forKey: "indexedFolderPaths"
        )
        let manager = FolderAccessManager(defaults: defaults)

        manager.removeFolder(directory)

        XCTAssertEqual(manager.folders, [secondDirectory.standardizedFileURL])
        XCTAssertEqual(
            defaults.array(forKey: "indexedFolderPaths") as? [String],
            [secondDirectory.standardizedFileURL.path]
        )
    }

    func testNothingStoredProducesAnEmptyFolderList() {
        XCTAssertTrue(FolderAccessManager(defaults: defaults).folders.isEmpty)
    }

    func testWritableRootsAreBoundarySafe() {
        let manager = FolderAccessManager(
            defaults: defaults,
            loadStoredPaths: false,
            initialFolders: [directory]
        )

        XCTAssertTrue(manager.canWrite(to: directory))
        XCTAssertTrue(manager.canWrite(to: directory.appendingPathComponent("nested/file.txt")))
        XCTAssertFalse(manager.canWrite(to: URL(fileURLWithPath: "/tmp/elsewhere/file.txt")))
        XCTAssertFalse(
            manager.canWrite(to: URL(fileURLWithPath: directory.path + "-other/file.txt")),
            "A sibling sharing the root's string prefix is not inside that root"
        )
    }

    func testSymlinkInsideRootDoesNotAuthorizeOutsideTarget() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-access-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = directory.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let manager = FolderAccessManager(
            defaults: defaults,
            loadStoredPaths: false,
            initialFolders: [directory]
        )

        XCTAssertFalse(manager.canWrite(to: link.appendingPathComponent("secret.txt")))
    }

    func testNavigatorDisplayPreferencesRestoreFromDefaults() {
        let preferences = BrowserPreferences(defaults: defaults)
        preferences.showItemSizes = true

        let restored = BrowserPreferences(defaults: defaults)

        XCTAssertTrue(restored.showItemSizes)
    }
}

import Foundation
import XCTest
@testable import FinderDrawerKit

final class FileIndexTests: XCTestCase {
    func testTrigramIndexFindsFilenameSubstring() async throws {
        let fixture = try await makeFixtureIndex()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let matches = try await fixture.database.search(text: "port", scope: .thisMac)
        XCTAssertEqual(matches.map(\.displayName), ["Quarterly Report 2026.txt"])
    }

    func testIndexSupportsShortQueries() async throws {
        let fixture = try await makeFixtureIndex()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let matches = try await fixture.database.search(text: "Q", scope: .thisMac)
        XCTAssertEqual(matches.map(\.displayName), ["Quarterly Report 2026.txt"])
    }

    func testShortQueriesUseUnicodeCaseInsensitiveMatching() async throws {
        let fixture = try await makeFixtureIndex()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try await fixture.database.beginRebuild()
        try await fixture.database.insert([
            IndexedFile(
                path: "/tmp/Éclair.txt",
                name: "Éclair.txt",
                contentType: "public.plain-text",
                size: 1,
                createdAt: nil,
                modifiedAt: Date()
            ),
        ])
        try await fixture.database.finishRebuild()

        let oneCharacter = try await fixture.database.search(text: "é", scope: .thisMac)
        let twoCharacters = try await fixture.database.search(text: "éC", scope: .thisMac)

        XCTAssertEqual(oneCharacter.map(\.displayName), ["Éclair.txt"])
        XCTAssertEqual(twoCharacters.map(\.displayName), ["Éclair.txt"])
    }

    func testIndexReturnsFolders() async throws {
        let fixture = try await makeFixtureIndex()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let matches = try await fixture.database.search(text: "Projects", scope: .thisMac)
        XCTAssertEqual(matches.map(\.displayName), ["Projects"])
        XCTAssertEqual(matches.first?.isDirectory, true)
    }

    func testRebuildReplacesStaleFiles() async throws {
        let fixture = try await makeFixtureIndex()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try await fixture.database.beginRebuild()
        try await fixture.database.insert([
            IndexedFile(
                path: "/tmp/Budget.xlsx",
                name: "Budget.xlsx",
                contentType: "org.openxmlformats.spreadsheetml.sheet",
                size: 12,
                createdAt: nil,
                modifiedAt: Date()
            )
        ])
        try await fixture.database.finishRebuild()

        let staleMatches = try await fixture.database.search(text: "Quarterly", scope: .thisMac)
        let newMatches = try await fixture.database.search(text: "budget", scope: .thisMac)
        XCTAssertTrue(staleMatches.isEmpty)
        XCTAssertEqual(newMatches.first?.displayName, "Budget.xlsx")
    }

    func testCrawlerStreamsFilesAndFolders() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-index-crawler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("one".utf8).write(to: root.appendingPathComponent("One.txt"))
        try Data("two".utf8).write(to: root.appendingPathComponent("Two.txt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Projects", isDirectory: true),
            withIntermediateDirectories: true
        )

        var files: [IndexedFile] = []
        for await batch in FileIndexCrawler.files(in: [root], batchSize: 1) {
            files.append(contentsOf: batch)
        }
        XCTAssertEqual(Set(files.map(\.name)), ["One.txt", "Two.txt", "Projects"])
    }

    func testPathPrefixRespectsFolderBoundaryAndCombinesWithQuery() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-index-prefix-\(UUID().uuidString)", isDirectory: true)
        let database = try FileIndexDatabase(url: directory.appendingPathComponent("index.sqlite3"))
        defer { try? FileManager.default.removeItem(at: directory) }
        try await database.beginRebuild()
        try await database.insert([
            IndexedFile(
                path: "/Users/tester/RootA/x.txt",
                name: "x.txt",
                contentType: "public.plain-text",
                size: 1,
                createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: 30)
            ),
            IndexedFile(
                path: "/Users/tester/RootA/Sub/y.txt",
                name: "y.txt",
                contentType: "public.plain-text",
                size: 2,
                createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: 20)
            ),
            IndexedFile(
                path: "/Users/tester/RootAB/z.txt",
                name: "z.txt",
                contentType: "public.plain-text",
                size: 3,
                createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: 10)
            )
        ])
        try await database.finishRebuild()

        let scoped = try await database.search(
            text: "",
            scope: .thisMac,
            pathPrefix: "/Users/tester/RootA"
        )
        XCTAssertEqual(scoped.map(\.displayName), ["x.txt", "y.txt"])

        let all = try await database.search(text: "", scope: .thisMac, pathPrefix: nil)
        XCTAssertEqual(all.map(\.displayName), ["x.txt", "y.txt", "z.txt"])

        let combined = try await database.search(
            text: "y",
            scope: .thisMac,
            pathPrefix: "/Users/tester/RootA"
        )
        XCTAssertEqual(combined.map(\.displayName), ["y.txt"])
    }

    func testFilesystemRootPathPrefixIncludesAbsoluteDescendants() async throws {
        let fixture = try await makeFixtureIndex()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let matches = try await fixture.database.search(
            text: "",
            scope: .thisMac,
            pathPrefix: "/"
        )

        XCTAssertEqual(
            Set(matches.map(\.displayName)),
            ["Quarterly Report 2026.txt", "Vacation.jpg", "Projects"]
        )
    }

    func testPathPrefixMatchingPreservesPathCase() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-index-path-case-\(UUID().uuidString)", isDirectory: true)
        let database = try FileIndexDatabase(url: directory.appendingPathComponent("index.sqlite3"))
        defer { try? FileManager.default.removeItem(at: directory) }
        try await database.beginRebuild()
        try await database.insert([
            IndexedFile(
                path: "/Volumes/CaseSensitive/Root/Visible.txt",
                name: "Visible.txt",
                contentType: "public.plain-text",
                size: 1,
                createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: 2)
            ),
            IndexedFile(
                path: "/Volumes/CaseSensitive/root/Private.txt",
                name: "Private.txt",
                contentType: "public.plain-text",
                size: 1,
                createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
        ])
        try await database.finishRebuild()

        let matches = try await database.search(
            text: "",
            scope: .thisMac,
            pathPrefix: "/Volumes/CaseSensitive/Root"
        )

        XCTAssertEqual(matches.map(\.displayName), ["Visible.txt"])
    }

    func testAllowedRootsAreAppliedBeforeLimit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-index-live-roots-\(UUID().uuidString)", isDirectory: true)
        let database = try FileIndexDatabase(url: directory.appendingPathComponent("index.sqlite3"))
        defer { try? FileManager.default.removeItem(at: directory) }
        try await database.beginRebuild()
        try await database.insert([
            IndexedFile(
                path: "/Users/tester/Removed/Newer.txt",
                name: "Newer.txt",
                contentType: "public.plain-text",
                size: 1,
                createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: 20)
            ),
            IndexedFile(
                path: "/Users/tester/Allowed/Older.txt",
                name: "Older.txt",
                contentType: "public.plain-text",
                size: 1,
                createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: 10)
            ),
        ])
        try await database.finishRebuild()

        let matches = try await database.search(
            text: "",
            scope: .thisMac,
            allowedRootPaths: ["/Users/tester/Allowed"],
            limit: 1
        )

        XCTAssertEqual(matches.map(\.displayName), ["Older.txt"])
    }

    private func makeFixtureIndex() async throws -> (database: FileIndexDatabase, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-index-db-\(UUID().uuidString)", isDirectory: true)
        let database = try FileIndexDatabase(url: directory.appendingPathComponent("index.sqlite3"))
        try await database.beginRebuild()
        try await database.insert([
            IndexedFile(
                path: "/tmp/Quarterly Report 2026.txt",
                name: "Quarterly Report 2026.txt",
                contentType: "public.plain-text",
                size: 42,
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2)
            ),
            IndexedFile(
                path: "/tmp/Vacation.jpg",
                name: "Vacation.jpg",
                contentType: "public.jpeg",
                size: 84,
                createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
            IndexedFile(
                path: "/tmp/Projects",
                name: "Projects",
                contentType: "public.folder",
                size: nil,
                createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: 3)
            )
        ])
        try await database.finishRebuild()
        return (database, directory)
    }
}

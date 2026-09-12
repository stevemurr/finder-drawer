import Foundation
@testable import FinderDrawerKit
import XCTest

/// The index crawler must filter the same way the shell composer's path
/// completion does — one app, two file pickers, one answer.
final class FileIndexCrawlerIgnoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("topside-crawler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        try super.tearDownWithError()
    }

    private func write(_ relative: String, _ contents: String = "x") throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func crawl() async -> [String] {
        var names: [String] = []
        let rootPath = root.standardizedFileURL.path
        for await batch in FileIndexCrawler.files(in: [root], batchSize: 64) {
            for file in batch {
                let relative = String(file.path.dropFirst(rootPath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !relative.isEmpty { names.append(relative) }
            }
        }
        return names
    }

    /// The headline case: a project's own ignore file decides, and the crawler
    /// used to index every one of these.
    func testAGitignoredDirectoryIsNotIndexed() async throws {
        try write(".gitignore", "target/\ndist/\n")
        try write("src/main.rs")
        try write("target/debug/binary")
        try write("dist/bundle.js")

        let indexed = await crawl()

        XCTAssertTrue(indexed.contains("src/main.rs"))
        XCTAssertFalse(
            indexed.contains { $0.hasPrefix("target") },
            "an ignored directory must not be walked: \(indexed)"
        )
        XCTAssertFalse(indexed.contains { $0.hasPrefix("dist") })
    }

    /// A nested ignore file governs its own subtree and nothing else. This is
    /// the case the prefix-popping exists for: two siblings at the same depth,
    /// where only the first declares rules.
    func testANestedIgnoreDoesNotLeakToASibling() async throws {
        try write("alpha/.gitignore", "secret.txt\n")
        try write("alpha/secret.txt")
        try write("alpha/keep.txt")
        try write("beta/secret.txt")

        let indexed = await crawl()

        XCTAssertFalse(indexed.contains("alpha/secret.txt"))
        XCTAssertTrue(indexed.contains("alpha/keep.txt"))
        XCTAssertTrue(
            indexed.contains("beta/secret.txt"),
            "alpha's rules must not govern beta: \(indexed)"
        )
    }

    /// A negation in a nested file has to be able to re-include something its
    /// parent excluded, or the shared rule is only half implemented.
    func testANestedNegationReInclues() async throws {
        try write(".gitignore", "*.log\n")
        try write("logs/.gitignore", "!keep.log\n")
        try write("logs/keep.log")
        try write("logs/drop.log")
        try write("other.log")

        let indexed = await crawl()

        XCTAssertTrue(indexed.contains("logs/keep.log"), "\(indexed)")
        XCTAssertFalse(indexed.contains("logs/drop.log"))
        XCTAssertFalse(indexed.contains("other.log"))
    }

    /// `node_modules` is excluded by name as well, because it is routinely the
    /// largest thing on the disk and is not always inside a repository.
    func testNodeModulesIsSkippedWithoutAnIgnoreFile() async throws {
        try write("app/index.js")
        try write("app/node_modules/left-pad/index.js")

        let indexed = await crawl()

        XCTAssertTrue(indexed.contains("app/index.js"))
        XCTAssertFalse(indexed.contains { $0.contains("node_modules") })
    }

    /// **`build` is no longer a blind name match.** It was, and it hid
    /// directories that were somebody's actual source. Inside a repository the
    /// project's own ignore file still excludes it — that is the mechanism, and
    /// it knows about the exceptions.
    func testAnUnignoredBuildDirectoryIsIndexed() async throws {
        try write("build/notes.md")

        let indexed = await crawl()

        XCTAssertTrue(
            indexed.contains("build/notes.md"),
            "only a .gitignore may decide this: \(indexed)"
        )
    }

    func testAGitignoredBuildDirectoryIsStillSkipped() async throws {
        try write(".gitignore", "build/\n")
        try write("build/artifact.o")
        try write("keep.md")

        let indexed = await crawl()

        XCTAssertTrue(indexed.contains("keep.md"))
        XCTAssertFalse(indexed.contains { $0.hasPrefix("build") })
    }

    /// Go's module cache is inside no repository, so no ignore file anywhere
    /// declares it. That is precisely why it needs its own entry.
    func testTheGoModuleCacheIsExcludedByPath() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let paths = FileSearchExclusions.paths(home: home)

        XCTAssertTrue(paths.contains("/Users/example/go/pkg"))
    }

    /// **The whole of `~/Library`, not three folders inside it.** macOS hides
    /// this from Finder, but the hidden flag is not reliably set on it, so
    /// `.skipsHiddenFiles` walks straight in.
    func testTheWholeLibraryIsExcluded() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let paths = FileSearchExclusions.paths(home: home)

        XCTAssertTrue(paths.contains("/Users/example/Library"))
    }

    /// A directory *called* Library that is not the home one stays searchable —
    /// this is a path exclusion, not a name.
    func testAProjectFolderNamedLibraryIsNotExcluded() async throws {
        try write("Library/notes.md")

        let indexed = await crawl()

        XCTAssertTrue(
            indexed.contains("Library/notes.md"),
            "only ~/Library is excluded, by path: \(indexed)"
        )
    }

    /// The exclusion list is a set of judgements, not an accumulating denylist.
    /// If this grows, each addition should have had to argue that no
    /// `.gitignore` could have covered it.
    func testTheNameExclusionsStayShort() {
        XCTAssertFalse(FileSearchExclusions.directoryNames.contains("build"))
        XCTAssertTrue(FileSearchExclusions.directoryNames.contains("node_modules"))
        XCTAssertLessThanOrEqual(FileSearchExclusions.directoryNames.count, 4)
    }
}

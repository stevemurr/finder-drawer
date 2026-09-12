import Foundation
import XCTest
@testable import FinderDrawerKit

final class FileIndexServiceTests: XCTestCase {
    @MainActor
    func testStartClearsStaleIndexWhenThereAreNoAuthorizedRoots() async throws {
        let directory = makeTemporaryDirectory(named: "empty-roots")
        let batches = ControlledFileBatchSource(roots: [[]])
        var service: FileIndexService? = try FileIndexService(
            databaseURL: directory.appendingPathComponent("index.sqlite3"),
            indexRoots: [],
            fileBatches: { roots in batches.files(in: roots) }
        )
        defer {
            service?.stop()
            service = nil
            try? FileManager.default.removeItem(at: directory)
        }

        try await service!.database.beginRebuild()
        try await service!.database.insert([
            indexedFile(path: "/previously-authorized/Secret.txt", name: "Secret.txt")
        ])
        try await service!.database.finishRebuild()

        service!.start()

        guard await eventually({ batches.wasRequested(for: []) }) else {
            XCTFail("Starting with no roots must run an empty rebuild to clear stale metadata")
            return
        }
        batches.finish(roots: [])

        let databaseWasCleared = try await eventuallyFileCount(0, in: service!.database)
        let serviceBecameIdle = await eventually({ !service!.isIndexing && !service!.isSearching })
        XCTAssertTrue(databaseWasCleared)
        XCTAssertTrue(serviceBecameIdle)
        XCTAssertTrue(service!.results.isEmpty)
    }

    @MainActor
    func testReplacingRootsDuringRebuildSchedulesLatestRoots() async throws {
        let directory = makeTemporaryDirectory(named: "replace-roots")
        let rootA = directory.appendingPathComponent("RootA", isDirectory: true)
        let rootB = directory.appendingPathComponent("RootB", isDirectory: true)
        let batches = ControlledFileBatchSource(roots: [[rootA], [rootB]])
        var service: FileIndexService? = try FileIndexService(
            databaseURL: directory.appendingPathComponent("index.sqlite3"),
            indexRoots: [rootA],
            fileBatches: { roots in batches.files(in: roots) }
        )
        defer {
            service?.stop()
            service = nil
            try? FileManager.default.removeItem(at: directory)
        }

        service!.rebuildIndex()
        guard await eventually({ batches.wasRequested(for: [rootA]) }) else {
            XCTFail("The first rebuild never requested RootA")
            return
        }

        service!.replaceIndexRoots([rootB])
        batches.finish(
            roots: [rootA],
            files: [indexedFile(path: rootA.appendingPathComponent("Old.txt").path, name: "Old.txt")]
        )

        guard await eventually({ batches.wasRequested(for: [rootB]) }) else {
            XCTFail("Replacing roots during a rebuild must schedule a follow-up rebuild")
            return
        }
        batches.finish(
            roots: [rootB],
            files: [indexedFile(path: rootB.appendingPathComponent("Latest.txt").path, name: "Latest.txt")]
        )

        let serviceBecameIdle = await eventually({ !service!.isIndexing })
        XCTAssertTrue(serviceBecameIdle)
        let oldMatches = try await service!.database.search(text: "Old", scope: .thisMac)
        let latestMatches = try await service!.database.search(text: "Latest", scope: .thisMac)
        XCTAssertTrue(oldMatches.isEmpty)
        XCTAssertEqual(latestMatches.map(\.displayName), ["Latest.txt"])
    }

    @MainActor
    func testReplacingRootsImmediatelyRemovesResultsFromRevokedRoots() async throws {
        let directory = makeTemporaryDirectory(named: "live-root-filter")
        let allowed = directory.appendingPathComponent("Allowed", isDirectory: true)
        let removed = directory.appendingPathComponent("Removed", isDirectory: true)
        var service: FileIndexService? = try FileIndexService(
            databaseURL: directory.appendingPathComponent("index.sqlite3"),
            indexRoots: [allowed, removed]
        )
        defer {
            service?.stop()
            service = nil
            try? FileManager.default.removeItem(at: directory)
        }
        try await service!.database.beginRebuild()
        try await service!.database.insert([
            indexedFile(path: allowed.appendingPathComponent("Visible.txt").path, name: "Visible.txt"),
            indexedFile(path: removed.appendingPathComponent("Secret.txt").path, name: "Secret.txt"),
        ])
        try await service!.database.finishRebuild()

        service!.search(text: "", scope: .thisMac, immediately: true)
        guard await eventually({ service!.results.count == 2 }) else {
            XCTFail("Initial results were not published")
            return
        }

        service!.replaceIndexRoots([allowed], rebuild: false)

        XCTAssertEqual(service!.results.map(\.displayName), ["Visible.txt"])
        guard await eventually({ !service!.isSearching }) else {
            XCTFail("Root-filtered search did not settle")
            return
        }
        XCTAssertEqual(service!.results.map(\.displayName), ["Visible.txt"])
    }

    @MainActor
    func testLiteralPathCompletionDoesNotBlockTheMainActor() async throws {
        let directory = makeTemporaryDirectory(named: "completion-executor")
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let heartbeat = DispatchSemaphore(value: 0)
        var service: FileIndexService? = try FileIndexService(
            databaseURL: directory.appendingPathComponent("index.sqlite3"),
            directoryCompletions: { _, _ in
                started.signal()
                release.wait()
                return []
            }
        )
        defer {
            release.signal()
            service?.stop()
            service = nil
            try? FileManager.default.removeItem(at: directory)
        }

        let lookup = Task { await service!.matchingFolders(for: "/tmp/example") }
        let mainActorStayedResponsive = await Task.detached {
            guard started.wait(timeout: .now() + 1) == .success else {
                release.signal()
                return false
            }
            Task { @MainActor in heartbeat.signal() }
            let responsive = heartbeat.wait(timeout: .now() + 1) == .success
            release.signal()
            return responsive
        }.value
        _ = await lookup.value

        XCTAssertTrue(
            mainActorStayedResponsive,
            "Filesystem enumeration must not occupy the main actor"
        )
    }

    private func makeTemporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("file-index-service-\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    private func indexedFile(path: String, name: String) -> IndexedFile {
        IndexedFile(
            path: path,
            name: name,
            contentType: "public.plain-text",
            size: 1,
            createdAt: nil,
            modifiedAt: Date()
        )
    }

    @MainActor
    private func eventually(
        timeout: TimeInterval = 2,
        _ predicate: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    private func eventuallyFileCount(
        _ expectedCount: Int,
        in database: FileIndexDatabase,
        timeout: TimeInterval = 2
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await database.fileCount() == expectedCount { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return try await database.fileCount() == expectedCount
    }
}

private final class ControlledFileBatchSource: @unchecked Sendable {
    private struct Feed {
        let stream: AsyncStream<[IndexedFile]>
        let continuation: AsyncStream<[IndexedFile]>.Continuation
    }

    private let lock = NSLock()
    private var feeds: [String: Feed] = [:]
    private var requests: Set<String> = []

    init(roots: [[URL]]) {
        for roots in roots {
            var continuation: AsyncStream<[IndexedFile]>.Continuation?
            let stream = AsyncStream<[IndexedFile]> { continuation = $0 }
            feeds[Self.key(for: roots)] = Feed(
                stream: stream,
                continuation: continuation!
            )
        }
    }

    func files(in roots: [URL]) -> AsyncStream<[IndexedFile]> {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(for: roots)
        requests.insert(key)
        return feeds[key]!.stream
    }

    func wasRequested(for roots: [URL]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return requests.contains(Self.key(for: roots))
    }

    func finish(roots: [URL], files: [IndexedFile] = []) {
        lock.lock()
        let continuation = feeds[Self.key(for: roots)]!.continuation
        lock.unlock()
        if !files.isEmpty { continuation.yield(files) }
        continuation.finish()
    }

    private static func key(for roots: [URL]) -> String {
        roots.map { $0.standardizedFileURL.path }.joined(separator: "\u{0}")
    }
}

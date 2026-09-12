import Foundation
import Observation

@MainActor
@Observable
final class FileIndexService {
    static let visibleSearchResultLimit = 200

    typealias FileBatchSource = @Sendable ([URL]) -> AsyncStream<[IndexedFile]>
    typealias DirectoryCompletionSource = @Sendable (String, Int) -> [URL]

    /// One database actor shared by the search state and folder completions.
    let database: FileIndexDatabase
    private(set) var indexRoots: [URL]
    private var searchTask: Task<Void, Never>?
    private var indexingTask: Task<Void, Never>?
    private var rebuildRequested = false
    private var searchGeneration = 0
    private var currentText = ""
    private var currentScope: SearchScope = .thisMac
    @ObservationIgnored private let fileBatches: FileBatchSource
    @ObservationIgnored private let directoryCompletions: DirectoryCompletionSource

    private(set) var results: [FileSearchResult] = []
    private(set) var resultsAreCapped = false
    private(set) var isSearching = false
    private(set) var isIndexing = false
    private(set) var indexedFileCount = 0
    private(set) var statusText = "Preparing index…"
    private(set) var errorMessage: String?

    init(
        databaseURL: URL,
        indexRoots: [URL] = SearchScope.indexRoots,
        fileBatches: @escaping FileBatchSource = { FileIndexCrawler.files(in: $0) },
        directoryCompletions: @escaping DirectoryCompletionSource = {
            FileIndexService.directories(matchingPath: $0, limit: $1)
        }
    ) throws {
        database = try FileIndexDatabase(url: databaseURL)
        self.indexRoots = indexRoots
        self.fileBatches = fileBatches
        self.directoryCompletions = directoryCompletions
    }

    func start() {
        Task { [weak self] in
            guard let self else { return }
            do {
                self.indexedFileCount = try await self.database.fileCount()
                self.updateStatus()
                if self.indexRoots.isEmpty {
                    self.searchTask?.cancel()
                    self.searchGeneration += 1
                    self.isSearching = false
                    self.results = []
                    self.resultsAreCapped = false
                } else {
                    self.search(text: "", scope: .thisMac, immediately: true)
                }
                self.rebuildIndex()
            } catch {
                self.errorMessage = error.localizedDescription
                self.statusText = "Index unavailable"
            }
        }
    }

    func replaceIndexRoots(_ roots: [URL], rebuild: Bool = true) {
        indexRoots = roots
        results = results.filter { Self.contains($0.url, in: roots) }
        if results.count < Self.visibleSearchResultLimit { resultsAreCapped = false }
        search(text: currentText, scope: currentScope, immediately: true)
        if rebuild { rebuildIndex() }
    }

    /// Directories matching `text`, for the ⌘P "Go to Folder" completion list.
    ///
    /// Runs against the same FTS index as search rather than walking the disk, so
    /// it stays instant on a deep tree. An empty query returns the indexed
    /// roots, which is the useful starting point.
    func matchingFolders(for text: String, limit: Int = 40) async -> [URL] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return indexRoots }

        // A typed path is answered from the filesystem: it is exact, and the
        // index only stores names.
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            let directoryCompletions = directoryCompletions
            return await Task.detached(priority: .userInitiated) {
                directoryCompletions(trimmed, limit)
            }.value
        }

        let results = (try? await database.search(
            text: trimmed,
            scope: .thisMac,
            pathPrefix: nil,
            allowedRootPaths: indexRoots.map { $0.standardizedFileURL.path },
            limit: limit * 4
        )) ?? []
        return results.filter(\.isDirectory).prefix(limit).map(\.url)
    }

    /// Completions for a literal path: siblings of the last component that
    /// share its prefix.
    nonisolated private static func directories(matchingPath path: String, limit: Int) -> [URL] {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        let parent = expanded.hasSuffix("/") ? url : url.deletingLastPathComponent()
        let prefix = expanded.hasSuffix("/") ? "" : url.lastPathComponent.lowercased()

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return contents
            .filter { candidate in
                guard (try? candidate.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                else { return false }
                return prefix.isEmpty || candidate.lastPathComponent.lowercased().hasPrefix(prefix)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(limit)
            .map { $0 }
    }

    func search(text: String, scope: SearchScope, immediately: Bool = false) {
        currentText = text
        currentScope = scope
        searchGeneration += 1
        let generation = searchGeneration
        searchTask?.cancel()
        isSearching = true

        searchTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(90)) }
            guard !Task.isCancelled, let self else { return }
            do {
                let allowedRootPaths = self.indexRoots.map { $0.standardizedFileURL.path }
                let matches = try await self.database.search(
                    text: text,
                    scope: scope,
                    allowedRootPaths: allowedRootPaths,
                    limit: Self.visibleSearchResultLimit + 1
                )
                guard !Task.isCancelled, self.searchGeneration == generation else { return }
                self.resultsAreCapped = matches.count > Self.visibleSearchResultLimit
                self.results = Array(matches.prefix(Self.visibleSearchResultLimit))
                self.errorMessage = nil
            } catch {
                guard self.searchGeneration == generation else { return }
                self.results = []
                self.resultsAreCapped = false
                self.errorMessage = error.localizedDescription
            }
            if self.searchGeneration == generation { self.isSearching = false }
        }
    }

    func rebuildIndex() {
        guard indexingTask == nil else {
            rebuildRequested = true
            return
        }
        let roots = indexRoots
        isIndexing = true
        errorMessage = nil
        statusText = indexedFileCount == 0 ? "Building index…" : "Refreshing index…"

        indexingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.database.beginRebuild()
                var crawledCount = 0

                for await batch in self.fileBatches(roots) {
                    guard !Task.isCancelled else { return }
                    try await self.database.insert(batch)
                    crawledCount += batch.count
                    self.statusText = "Indexing \(crawledCount.formatted()) items…"

                    // During the first build, rows go directly into FTS. Keep
                    // the visible query live as each batch becomes searchable.
                    if self.indexedFileCount == 0, crawledCount % 2_000 < batch.count {
                        self.search(text: self.currentText, scope: self.currentScope, immediately: true)
                    }
                }

                guard !Task.isCancelled else { return }
                try await self.database.finishRebuild()
                self.indexedFileCount = try await self.database.fileCount()
                self.errorMessage = nil
                self.search(text: self.currentText, scope: self.currentScope, immediately: true)
            } catch {
                self.errorMessage = error.localizedDescription
            }

            self.isIndexing = false
            self.indexingTask = nil
            self.updateStatus()
            if self.rebuildRequested {
                self.rebuildRequested = false
                self.rebuildIndex()
            }
        }
    }

    func stop() {
        searchTask?.cancel()
        indexingTask?.cancel()
    }

    private func updateStatus() {
        if isIndexing { return }
        statusText = indexedFileCount == 0
            ? "Index has not been built"
            : "\(indexedFileCount.formatted()) items indexed"
    }

    nonisolated private static func contains(_ url: URL, in roots: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return roots.contains { root in
            let rootPath = root.standardizedFileURL.path
            return path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/")
        }
    }
}

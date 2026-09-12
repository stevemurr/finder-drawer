import Foundation

struct IndexedFile: Sendable {
    let path: String
    let name: String
    let contentType: String?
    let size: Int64?
    let createdAt: Date?
    let modifiedAt: Date?
}

/// Streams file and folder metadata to the index, respecting nested ignore
/// rules and shared cache exclusions. Cancellation stops the detached crawl.
enum FileIndexCrawler {
    static func files(in roots: [URL], batchSize: Int = 500) -> AsyncStream<[IndexedFile]> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                let keys: Set<URLResourceKey> = [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .contentTypeKey,
                    .fileSizeKey,
                    .creationDateKey,
                    .contentModificationDateKey
                ]
                let ignoredDirectoryNames = FileSearchExclusions.directoryNames
                let ignoredPaths = FileSearchExclusions.paths()
                let fileManager = FileManager.default

                var seenPaths: Set<String> = []
                var batch: [IndexedFile] = []

                for root in roots where !Task.isCancelled {
                    guard let enumerator = fileManager.enumerator(
                        at: root,
                        includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles, .skipsPackageDescendants],
                        errorHandler: { _, _ in true }
                    ) else { continue }

                    // **The stack is popped by path prefix, not by depth.**
                    // `FileManager.enumerator` is depth-first but hands back a
                    // flat sequence with no "left a directory" signal, and
                    // `enumerator.level` cannot distinguish two sibling subtrees
                    // at the same depth — so a `.gitignore` in the first would
                    // have gone on governing the second. Comparing prefixes is
                    // the only thing that is right without a callback the API
                    // does not offer.
                    let rootPath = root.standardizedFileURL.path
                    var stack: [GitignoreScope] = []
                    let rootRules = GitignoreScopes.rules(
                        in: rootPath, at: "", fileManager: fileManager
                    )
                    if !rootRules.isEmpty {
                        stack.append(GitignoreScope(prefix: "", rules: rootRules))
                    }

                    while let url = enumerator.nextObject() as? URL {
                        if Task.isCancelled { break }
                        let path = url.standardizedFileURL.path
                        guard seenPaths.insert(path).inserted else { continue }

                        let values = try? url.resourceValues(forKeys: keys)
                        let isDirectory = values?.isDirectory == true
                        if isDirectory {
                            if ignoredDirectoryNames.contains(url.lastPathComponent)
                                || ignoredPaths.contains(path) {
                                enumerator.skipDescendants()
                                continue
                            }
                        }
                        guard isDirectory || values?.isRegularFile == true else { continue }

                        // Everything below is relative to this root, which is
                        // the frame every pattern in the stack is written in.
                        guard path.hasPrefix(rootPath) else { continue }
                        let relative = String(path.dropFirst(rootPath.count))
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        guard !relative.isEmpty else { continue }

                        // Leave any scope this path is no longer inside. The
                        // root's own scope has an empty prefix and never pops.
                        while let top = stack.last, !top.prefix.isEmpty,
                              relative != top.prefix,
                              !relative.hasPrefix(top.prefix + "/") {
                            stack.removeLast()
                        }

                        if GitignoreScopes.isIgnored(
                            relative, isDirectory: isDirectory, stack: stack
                        ) {
                            if isDirectory { enumerator.skipDescendants() }
                            continue
                        }

                        // Pushed only after the directory itself survived, so an
                        // ignored directory's own ignore file is never read.
                        if isDirectory {
                            let own = GitignoreScopes.rules(
                                in: rootPath, at: relative, fileManager: fileManager
                            )
                            if !own.isEmpty {
                                stack.append(
                                    GitignoreScope(prefix: relative, rules: own)
                                )
                            }
                        }

                        batch.append(IndexedFile(
                            path: path,
                            name: url.lastPathComponent,
                            contentType: values?.contentType?.identifier
                                ?? (isDirectory ? "public.folder" : nil),
                            size: isDirectory ? nil : values?.fileSize.map(Int64.init),
                            createdAt: values?.creationDate,
                            modifiedAt: values?.contentModificationDate
                        ))

                        if batch.count >= batchSize {
                            continuation.yield(batch)
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                }

                if !batch.isEmpty { continuation.yield(batch) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

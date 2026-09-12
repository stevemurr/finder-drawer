import Foundation

/// A `.gitignore` and the subtree it governs.
///
/// `prefix` is the ignore file's own directory, relative to the walk's root and
/// without a trailing slash; empty for the root's own file. Patterns inside are
/// relative to that directory, which is what makes a `Tests/.gitignore` mean
/// what it says.
struct GitignoreScope {
    let prefix: String
    let rules: GitignoreRules
}

/// The rule for reading a stack of nested `.gitignore` files, in one place.
///
/// **Three surfaces search files in this app and they must agree.** The shell
/// composer's path completion walks breadth-first carrying a stack per queue
/// entry; the omnibox's index crawler and the agent's `@` mention picker both
/// walk a flat `FileManager.enumerator` and pop their stack by path prefix. The
/// walks genuinely differ — but "is this path ignored, given these nested
/// files" is one question with one answer, and copies of it would drift on
/// exactly the case nobody tested. Only the decision is shared; each walk keeps
/// its own bookkeeping.
enum GitignoreScopes {
    /// **Innermost first, and the first *opinion* wins** — not the first ignore.
    ///
    /// A nested file that says nothing about this path must fall through to its
    /// parent; one that negates must stop the search, or a `!fixture.json` in a
    /// subdirectory could never re-include anything its parent excluded.
    static func isIgnored(
        _ relative: String,
        isDirectory: Bool,
        stack: [GitignoreScope]
    ) -> Bool {
        for scope in stack.reversed() {
            // Patterns are relative to the file that declared them.
            let scoped = scope.prefix.isEmpty
                ? relative
                : String(relative.dropFirst(scope.prefix.count + 1))
            guard !scoped.isEmpty else { continue }
            if let decision = scope.rules.decision(for: scoped, isDirectory: isDirectory) {
                return decision
            }
        }
        return false
    }

    /// Reads the `.gitignore` governing one directory, or `.empty` if it has none.
    ///
    /// **Applied wherever one is found, including outside a repository.** Git
    /// itself only honours these inside a working tree; a file *picker* is not
    /// git, somebody who wrote a `.gitignore` in a folder meant those paths to
    /// be uninteresting, and checking for a `.git` at every level would cost a
    /// stat per directory to arrive at a more surprising answer. Both search
    /// surfaces already behaved this way; this only writes it down.
    static func rules(
        in root: String,
        at relative: String,
        fileManager: FileManager = .default
    ) -> GitignoreRules {
        let directory = relative.isEmpty
            ? root
            : (root as NSString).appendingPathComponent(relative)
        let path = (directory as NSString).appendingPathComponent(".gitignore")
        guard fileManager.fileExists(atPath: path),
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return .empty
        }
        return GitignoreRules(contentsOf: text)
    }
}

/// Directories worth skipping that **no `.gitignore` can reach**, in one place.
///
/// **There were four file searches in this app and four disagreeing answers.**
/// The index crawler skipped `Caches, DerivedData, node_modules, build`; the
/// shell composer's path completion skipped a different nine; the agent's `@`
/// mention picker skipped a different thirteen *and* honoured no ignore file at
/// all. So the same directory was offered by one picker and hidden by the next,
/// and a user reporting "why is this here" had to be told which box they typed
/// into before the question could even be answered.
///
/// The rule for what belongs here is exactly "would a `.gitignore` have covered
/// this". `node_modules` is declared by the ignore file of the repository that
/// contains it — but it is also enormous, never hand-authored, and frequently
/// sitting outside a repository, so it earns a name entry too. Go's module
/// cache at `~/go/pkg/mod` is inside no repository at all, so nothing declares
/// it and nothing else could exclude it. That is the distinction.
enum FileSearchExclusions {
    /// Skipped by name at any depth, in every picker.
    ///
    /// **`build`, `dist`, `target` and `vendor` are deliberately absent, and
    /// two of the pickers used to list them.** Each is an ordinary English word
    /// as well as a convention: matching the bare name everywhere also hid
    /// directories that were somebody's actual source. Inside a repository the
    /// project's own `.gitignore` excludes them, which is the correct mechanism
    /// and knows about the exceptions — and every picker honours it now, which
    /// is what makes dropping them safe.
    ///
    /// The survivors are the ones where volume, not convention, is the
    /// argument: a machine with a dozen JavaScript projects has more files
    /// under `node_modules` than in the rest of the home directory combined.
    static let directoryNames: Set<String> = [
        "node_modules",
        // Both still earn a name entry despite `~/Library` now being excluded
        // whole: neither lives only there. Xcode's DerivedData is routinely
        // relocated into a project, and a `Caches` directory turns up inside
        // application bundles, containers and plenty of tools' own trees.
        "Caches",
        "DerivedData",
    ]

    /// Skipped by name as well, but only relevant to a picker that shows hidden
    /// files at all.
    ///
    /// The index crawler passes `.skipsHiddenFiles` and so never sees these;
    /// the shell walk and the `@` picker can both be asked for hidden entries,
    /// and "show me hidden files" has never meant "show me the object files in
    /// `.build`".
    static let hiddenDirectoryNames: Set<String> = [
        ".git", ".build", ".swiftpm", ".venv", ".next", ".gradle", ".cache",
        "__pycache__",
    ]

    /// Absolute paths, resolved against the current home directory.
    ///
    /// **This is the category the bug reports were about.** A name match cannot
    /// express "the Go module cache", because the directory is called `mod` and
    /// the thing that makes it uninteresting is *where* it is. No ignore file
    /// exists above it, because it is inside no repository. The same is true of
    /// every entry here.
    ///
    /// **Excluded from *discovery*, not from reach.** Nothing here stops a
    /// typed path resolving: `pathCompletions` lists a directory the reader
    /// names, and the omnibox answers a typed path from the filesystem. What
    /// these remove is the recursive walk that offers you things you did not
    /// ask for — so `~/Library/Fonts/` still completes the moment you type it,
    /// and simply stops appearing when you search for something else.
    static func paths(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Set<String> {
        [
            // **The whole of `~/Library`, not three folders inside it.** It was
            // `Caches`, `Developer` and `Containers` — which left `Application
            // Support`, `Group Containers`, `Mobile Documents`, `Mail`,
            // `Messages` and `Preferences` in the index, none of which is ever
            // what somebody means when they search their own machine.
            //
            // macOS hides this folder from Finder, but the hidden *flag* is not
            // reliably set on it — checked on a live machine and it was absent —
            // so `.skipsHiddenFiles` walks straight in. That is why it needs an
            // entry rather than being covered for free like `.git` and `.venv`.
            "Library",
            // Go's module cache and build cache. The module cache alone is
            // routinely six figures of read-only files of other people's source.
            "go/pkg",
        ].reduce(into: Set<String>()) { result, relative in
            result.insert(
                home.appendingPathComponent(relative).standardizedFileURL.path
            )
        }
    }

    /// The one question every picker asks: may this directory be descended?
    ///
    /// `path` is absolute and standardized. `includesHidden` says whether the
    /// caller is showing hidden entries at all — when it is not, it has already
    /// dropped them itself and the hidden list is redundant rather than wrong.
    static func skipsDirectory(
        named name: String,
        at path: String,
        includesHidden: Bool,
        excludedPaths: Set<String>
    ) -> Bool {
        if directoryNames.contains(name) { return true }
        if includesHidden, hiddenDirectoryNames.contains(name) { return true }
        return excludedPaths.contains(path)
    }
}

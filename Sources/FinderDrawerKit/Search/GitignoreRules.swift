import Foundation

/// A useful subset of `.gitignore`, applied while walking a tree.
///
/// **Matching is `fnmatch(3)`, not a hand-rolled glob.** Gitignore patterns are
/// POSIX globs with two additions, and the parts that look easy — `*` stopping
/// at a slash, `?`, character classes like `[0-9]`, negated classes, escapes —
/// are exactly where a hand-rolled matcher is quietly wrong on the tenth
/// pattern nobody tested. `FNM_PATHNAME` gives the "`*` does not cross `/`" rule
/// for free, which is the one every naive implementation gets backwards.
///
/// **What is supported**, because a filter is only trustworthy if its limits are
/// written down: comments and blank lines; negation with `!`; directory-only
/// patterns with a trailing `/`; anchoring, where a pattern containing a slash
/// matches from the file it was declared in rather than at any depth; `**` for
/// crossing directories; and everything `fnmatch` handles inside one segment.
/// Nested `.gitignore` files apply to their own subtree, which is what git does
/// and what a repository with a `Tests/.gitignore` relies on.
///
/// **What is not**: `.git/info/exclude`, the global excludes file, and
/// `core.excludesFile`. Those live outside the tree being walked, and reading a
/// user's global git configuration to decide what a file picker shows is a
/// surprise waiting to happen. `.git` itself is always skipped regardless.
struct GitignoreRules {
    private struct Rule {
        let pattern: String
        let isNegated: Bool
        let directoriesOnly: Bool
        /// Anchored patterns match from the directory that declared them;
        /// unanchored ones match a path's trailing components at any depth.
        let isAnchored: Bool
    }

    private let rules: [Rule]

    static let empty = GitignoreRules(rules: [])

    private init(rules: [Rule]) {
        self.rules = rules
    }

    init(contentsOf text: String) {
        var parsed: [Rule] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            // A trailing backslash escapes the space before it; anything else
            // trailing is insignificant, which is what git does.
            while line.hasSuffix(" "), !line.hasSuffix("\\ ") {
                line.removeLast()
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            var negated = false
            if line.hasPrefix("!") {
                negated = true
                line.removeFirst()
            } else if line.hasPrefix("\\!") || line.hasPrefix("\\#") {
                // An escaped leading `!` or `#` is a literal one.
                line.removeFirst()
            }
            guard !line.isEmpty else { continue }

            var directoriesOnly = false
            if line.hasSuffix("/") {
                directoriesOnly = true
                line.removeLast()
            }
            guard !line.isEmpty else { continue }

            // A slash anywhere but the end anchors the pattern. A leading slash
            // anchors and is otherwise not part of the pattern.
            let anchored = line.dropLast().contains("/") || line.hasPrefix("/")
            if line.hasPrefix("/") { line.removeFirst() }
            guard !line.isEmpty else { continue }

            parsed.append(Rule(
                pattern: line,
                isNegated: negated,
                directoriesOnly: directoriesOnly,
                isAnchored: anchored
            ))
        }
        rules = parsed
    }

    var isEmpty: Bool { rules.isEmpty }

    /// What these rules say about `path`, relative to the directory they were
    /// declared in. `nil` means no rule matched — which is **not** the same as
    /// "not ignored".
    ///
    /// **Three states, not two.** A nested `.gitignore` overrides its parent
    /// only where it has something to say; collapsing "no opinion" into "not
    /// ignored" would make every nested file silently re-include everything its
    /// parent excluded. That distinction is the whole mechanism behind a
    /// `Tests/.gitignore` that re-admits one fixture.
    ///
    /// **The last matching rule wins** within one file, which is what makes `!`
    /// work: reversing the order breaks every repository that re-includes.
    func decision(for path: String, isDirectory: Bool) -> Bool? {
        var verdict: Bool?
        for rule in rules {
            if rule.directoriesOnly, !isDirectory { continue }
            if matches(rule, path: path) { verdict = !rule.isNegated }
        }
        return verdict
    }

    /// Two-state convenience for a single file's rules, where "no opinion" and
    /// "not ignored" really are the same answer.
    func ignores(_ path: String, isDirectory: Bool) -> Bool {
        decision(for: path, isDirectory: isDirectory) ?? false
    }

    private func matches(_ rule: Rule, path: String) -> Bool {
        if rule.isAnchored { return Self.fnmatch(rule.pattern, path) }
        // Unanchored: git matches the pattern against the path's basename and
        // against any trailing run of components, so `build` ignores
        // `a/b/build` and `node_modules` ignores it at every depth.
        var suffix = Substring(path)
        while true {
            if Self.fnmatch(rule.pattern, String(suffix)) { return true }
            guard let slash = suffix.firstIndex(of: "/") else { return false }
            suffix = suffix[suffix.index(after: slash)...]
        }
    }

    /// `**` is git's, not POSIX's, so it is translated before `fnmatch` sees it:
    /// a `**` segment may cross separators, which is precisely what
    /// `FNM_PATHNAME` forbids. Splitting on `**` and matching the parts is how
    /// the two rules coexist without giving up `FNM_PATHNAME` everywhere else.
    private static func fnmatch(_ pattern: String, _ path: String) -> Bool {
        guard pattern.contains("**") else {
            return Darwin.fnmatch(pattern, path, FNM_PATHNAME) == 0
        }
        let parts = pattern.components(separatedBy: "**")
        var remainder = Substring(path)
        for (index, part) in parts.enumerated() {
            let piece = part.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if piece.isEmpty { continue }
            var found = false
            var candidate = remainder
            while true {
                if Darwin.fnmatch(piece + "*", String(candidate), 0) == 0 {
                    found = true
                    break
                }
                guard let slash = candidate.firstIndex(of: "/") else { break }
                candidate = candidate[candidate.index(after: slash)...]
            }
            guard found else { return false }
            remainder = candidate
            _ = index
        }
        return true
    }
}

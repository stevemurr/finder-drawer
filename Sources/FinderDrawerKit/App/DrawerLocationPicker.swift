import Foundation
import Observation

@MainActor
@Observable
final class DrawerLocationPicker {
    var query = "" { didSet { selectedIndex = 0; errorMessage = nil } }
    var selectedIndex = 0
    var errorMessage: String?
    private(set) var suggestions: [URL] = []
    private(set) var recent: [URL]
    private var suggestionQuery = ""
    private var baseDirectory = FileManager.default.homeDirectoryForCurrentUser
    private var favorites: [URL] = []
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        recent = defaults.standardizedFileURLs(forKey: "drawerRecentLocations")
    }

    var visibleSuggestions: [URL] { suggestionQuery == query ? suggestions : [] }
    var selectedURL: URL? {
        if visibleSuggestions.indices.contains(selectedIndex) { return visibleSuggestions[selectedIndex] }
        return query.isEmpty ? nil : Self.resolve(query, relativeTo: baseDirectory)
    }

    func begin(at directory: URL, favorites: [URL]) {
        baseDirectory = directory
        self.favorites = favorites
        query = ""
        selectedIndex = 0
        suggestions = Self.unique([directory] + recent + favorites)
        suggestionQuery = ""
    }

    func remember(_ url: URL) {
        recent = Array(Self.unique([url.standardizedFileURL] + recent).prefix(40))
        defaults.setStandardizedFileURLs(recent, forKey: "drawerRecentLocations")
    }

    func refresh(index: FileIndexService) async {
        let input = query
        let base = baseDirectory
        let history = Self.unique([base] + recent + favorites)
        if input.isEmpty {
            suggestions = history; suggestionQuery = input; return
        }
        let typed = Self.resolve(input, relativeTo: base)
        let isPath = input.contains("/") || input.hasPrefix("~") || input.hasPrefix(".")
        let diskMatches = await Task.detached(priority: .userInitiated) {
            var matches: [URL] = []
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: typed.path, isDirectory: &directory), directory.boolValue {
                matches.append(typed)
            }
            if isPath {
                let parent = input.hasSuffix("/") ? typed : typed.deletingLastPathComponent()
                let prefix = input.hasSuffix("/") ? "" : typed.lastPathComponent
                let children = (try? FileManager.default.contentsOfDirectory(at: parent,
                    includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
                matches += children.filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && (prefix.isEmpty || $0.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()))
                }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.prefix(40)
            }
            return matches
        }.value
        let indexed = isPath ? [] : await index.matchingFolders(for: input)
        guard !Task.isCancelled, input == query else { return }
        let fuzzy = history.compactMap { url -> (URL, Int)? in
            Self.fuzzyScore(input, in: url.path).map { (url, $0) }
        }.sorted { $0.1 > $1.1 }.map(\.0)
        suggestions = Self.unique(diskMatches + fuzzy + indexed)
        suggestionQuery = input
        selectedIndex = 0
    }

    func move(by offset: Int) {
        selectedIndex = min(max(0, selectedIndex + offset), max(0, visibleSuggestions.count - 1))
    }

    func completeSelection() {
        guard let selectedURL else { return }
        query = selectedURL.path + (selectedURL.path == "/" ? "" : "/")
    }

    nonisolated static func resolve(_ input: String, relativeTo base: URL) -> URL {
        let expanded = (input as NSString).expandingTildeInPath
        return (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded, isDirectory: true)
                : base.appendingPathComponent(expanded, isDirectory: true)).standardizedFileURL
    }

    nonisolated static func fuzzyScore(_ needle: String, in haystack: String) -> Int? {
        let query = Array(needle.lowercased()), text = Array(haystack.lowercased())
        guard !query.isEmpty else { return 0 }
        var index = 0, score = 0, previous = -2
        for (position, character) in text.enumerated() where index < query.count {
            if character == query[index] {
                score += 10 + (position == previous + 1 ? 8 : 0)
                if position == 0 || text[position - 1] == "/" { score += 12 }
                previous = position
                index += 1
            }
        }
        return index == query.count ? score - text.count : nil
    }

    nonisolated private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

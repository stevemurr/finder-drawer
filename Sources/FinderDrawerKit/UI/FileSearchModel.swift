import Foundation
import Observation

/// Observable query state for the indexed filename search.
///
/// Selection, presentation, and actions belong to `DrawerWorkspace`;
/// this adapter only starts index queries and publishes their progress/results.
@MainActor
@Observable
final class FileSearchModel {
    private let searchService: FileIndexService

    var searchText = "" {
        didSet { startSearch() }
    }

    init(searchService: FileIndexService) {
        self.searchService = searchService
    }

    /// An empty query shows nothing rather than recently-modified files.
    ///
    /// The underlying service can still return recently modified files for
    /// clients that explicitly request an empty query.
    var results: [FileSearchResult] {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? []
            : searchService.results
    }

    var isSearching: Bool { searchService.isSearching }
    var isIndexing: Bool { searchService.isIndexing }
    var resultsAreCapped: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && searchService.resultsAreCapped
    }
    var indexStatus: String { searchService.statusText }
    var errorMessage: String? { searchService.errorMessage }

    var resultCountDescription: String {
        let count = results.count
        let amount = resultsAreCapped ? "\(count)+" : "\(count)"
        return "\(amount) \(count == 1 && !resultsAreCapped ? "result" : "results")"
    }

    private func startSearch() {
        searchService.search(
            text: searchText,
            scope: .thisMac,
            immediately: false
        )
    }
}

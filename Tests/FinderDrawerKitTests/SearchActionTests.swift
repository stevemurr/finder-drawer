import Foundation
import XCTest
@testable import FinderDrawerKit

@MainActor
final class SearchActionTests: XCTestCase {
    private var directory: URL!
    private var service: FileIndexService!
    private var viewModel: FileSearchModel!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        service = try FileIndexService(
            databaseURL: directory.appendingPathComponent("index.sqlite3"),
            indexRoots: [directory]
        )
        viewModel = FileSearchModel(searchService: service)
    }

    override func tearDownWithError() throws {
        service.stop()
        service = nil
        viewModel = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testEmptyQueryNeverReportsZeroPlusWhenUnderlyingSearchWasCapped() async throws {
        try await populateIndex(count: FileIndexService.visibleSearchResultLimit + 1)
        service.search(text: "", scope: .thisMac, immediately: true)
        try await waitUntil { !self.service.isSearching }

        XCTAssertTrue(service.resultsAreCapped)
        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertFalse(viewModel.resultsAreCapped)
        XCTAssertEqual(viewModel.resultCountDescription, "0 results")
    }

    func testNonemptyCappedQueryReportsAtLeastTheVisibleCount() async throws {
        try await populateIndex(count: FileIndexService.visibleSearchResultLimit + 1)
        viewModel.searchText = "Report"
        try await waitUntil { !self.viewModel.isSearching }

        XCTAssertEqual(viewModel.results.count, FileIndexService.visibleSearchResultLimit)
        XCTAssertTrue(viewModel.resultsAreCapped)
        XCTAssertEqual(
            viewModel.resultCountDescription,
            "\(FileIndexService.visibleSearchResultLimit)+ results"
        )
    }

    private func populateIndex(count: Int) async throws {
        let files = (0..<count).map { index in
            IndexedFile(
                path: directory.appendingPathComponent("Report \(index).txt").path,
                name: "Report \(index).txt",
                contentType: "public.plain-text",
                size: 1,
                createdAt: nil,
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        try await service.database.beginRebuild()
        try await service.database.insert(files)
        try await service.database.finishRebuild()
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Condition never became true")
    }
}

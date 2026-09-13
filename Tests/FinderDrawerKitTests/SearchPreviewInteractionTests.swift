import AppKit
import QuickLookUI
import XCTest
@testable import FinderDrawerKit

@MainActor
final class SearchPreviewInteractionTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var controller: FinderDrawerController!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        suite = "search-preview-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<15 {
            let name = String(format: "Preview Report %02d.txt", index)
            try Data("Document \(index)\nA readable preview of this file.\n".utf8)
                .write(to: root.appendingPathComponent(name))
        }
        controller = try FinderDrawerController(databaseURL: root.appendingPathComponent("index.sqlite3"),
            defaults: defaults, initialFolders: [root], restoresFolders: false)
        controller.workspace.preferences.animateDrawer = false
        controller.show()
    }

    override func tearDownWithError() throws {
        controller.shutdown()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func testNativeSearchKeyboardUpdatesSelectionAndEmbeddedPreviewWithoutMovingField() async throws {
        let workspace = controller.workspace
        try await waitUntil { !workspace.index.isIndexing && workspace.index.indexedFileCount >= 15 }
        workspace.beginSearch()
        let field = try await focusedField()
        field.currentEditor()?.insertText("Preview Report")
        try await waitUntil { workspace.search.results.count == 15 && workspace.selectedResult != nil }
        let initialURL = try XCTUnwrap(workspace.selectedResultID)
        let preview = try await previewView()
        try await waitUntil { preview.previewItem?.previewItemURL == initialURL }
        let fieldFrame = field.convert(field.bounds, to: nil)
        let previewFrame = preview.convert(preview.bounds, to: nil)
        XCTAssertFalse(preview.autostarts)

        // Exercise the native field editor's delegate routing, not just the model.
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        let secondURL = workspace.search.results[1].id
        try await waitUntil { workspace.selectedResultID == secondURL && preview.previewItem?.previewItemURL == secondURL }
        XCTAssertTrue(AppKitSearchFieldFocusLocator.ownsFirstResponder(field))
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        XCTAssertEqual(workspace.selectedResultID, initialURL)

        workspace.moveResultSelection(by: 100)
        XCTAssertEqual(workspace.selectedResultID, workspace.search.results.last?.id)
        workspace.moveResultSelection(by: -100)
        XCTAssertEqual(workspace.selectedResultID, workspace.search.results.first?.id)

        workspace.search.searchText = "Preview Report 00"
        try await waitUntil { !workspace.search.isSearching && workspace.search.results.count == 1 }
        try await waitUntil { preview.previewItem?.previewItemURL == workspace.selectedResultID }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(field.convert(field.bounds, to: nil).minY, fieldFrame.minY, accuracy: 1)
        XCTAssertEqual(preview.convert(preview.bounds, to: nil).height, previewFrame.height, accuracy: 1)

        workspace.search.searchText = "no-such-match"
        try await waitUntil { !workspace.search.isSearching && workspace.search.results.isEmpty && workspace.selectedResultID == nil }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(field.convert(field.bounds, to: nil).minY, fieldFrame.minY, accuracy: 1)
        XCTAssertNil(findPreview(in: controller.window?.contentView))
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertNil(workspace.selectedResultID)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(workspace.isPalettePresented)
    }

    func testReturnRevealsKeyboardSelectedResultAndDismissesSearch() async throws {
        let workspace = controller.workspace
        try await waitUntil { !workspace.index.isIndexing && workspace.index.indexedFileCount >= 15 }
        workspace.beginSearch()
        let field = try await focusedField()
        field.currentEditor()?.insertText("Preview Report")
        try await waitUntil { workspace.search.results.count == 15 && workspace.selectedResult != nil }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        let selectedURL = try XCTUnwrap(workspace.selectedResultID)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertFalse(workspace.isPalettePresented)
        try await waitUntil { workspace.browser?.focusedEntry?.url.standardizedFileURL == selectedURL.standardizedFileURL }
    }

    private func focusedField() async throws -> NSTextField {
        func field() -> NSTextField? {
            guard let content = controller.window?.contentView else { return nil }
            return AppKitSearchFieldFocusLocator.field(withAccessibilityIdentifier: controller.workspace.paletteInputIdentifier, in: content)
        }
        try await waitUntil { field().map(AppKitSearchFieldFocusLocator.ownsFirstResponder) == true }
        return try XCTUnwrap(field())
    }

    private func previewView() async throws -> QLPreviewView {
        try await waitUntil { self.findPreview(in: self.controller.window?.contentView) != nil }
        return try XCTUnwrap(findPreview(in: controller.window?.contentView))
    }

    private func findPreview(in view: NSView?) -> QLPreviewView? {
        guard let view else { return nil }
        if let preview = view as? QLPreviewView { return preview }
        return view.subviews.lazy.compactMap { self.findPreview(in: $0) }.first
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected search preview state did not arrive")
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import FinderDrawerKit

/// Guards the per-row work a large folder pays while scrolling.
@MainActor
final class BrowserRenderingTests: XCTestCase {
    func testDocumentIconsResolveOncePerContentType() {
        let root = URL(fileURLWithPath: "/tmp/icon-cache-\(UUID().uuidString)", isDirectory: true)
        let first = FileIconCache.icon(url: root.appendingPathComponent("a.txt"), contentType: .plainText, isContainer: false)
        let second = FileIconCache.icon(url: root.appendingPathComponent("b.txt"), contentType: .plainText, isContainer: false)

        XCTAssertTrue(first === second, "Ordinary documents share their type's icon")
    }

    func testContainersAndAppsKeepTheirOwnIcons() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("icon-folders-\(UUID().uuidString)", isDirectory: true)
        let one = root.appendingPathComponent("one", isDirectory: true)
        let two = root.appendingPathComponent("two", isDirectory: true)
        for url in [one, two] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }

        let folder = FileIconCache.icon(url: one, contentType: .folder, isContainer: true)
        XCTAssertTrue(folder === FileIconCache.icon(url: one, contentType: .folder, isContainer: true),
                      "A folder's icon is remembered by path")
        XCTAssertFalse(folder === FileIconCache.icon(url: two, contentType: .folder, isContainer: true),
                       "Folders can carry custom icons, so they are never shared by type")

        let app = root.appendingPathComponent("Tool.app")
        XCTAssertFalse(FileIconCache.icon(url: app, contentType: .application, isContainer: false)
                        === FileIconCache.icon(url: root.appendingPathComponent("Other.app"),
                                               contentType: .application, isContainer: false),
                       "Apps provide their own icons even when not marked as containers")
    }

    func testScrollingALargeColumnRecyclesRowViews() throws {
        let defaultsName = "row-recycling-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let directory = URL(fileURLWithPath: "/tmp/recycling", isDirectory: true)
        let viewModel = BrowserViewModel(
            folderAccess: FolderAccessManager(defaults: defaults, loadStoredPaths: false, initialFolders: [directory]),
            preferences: BrowserPreferences(defaults: defaults),
            quickLook: QuickLookController()
        )
        var column = BrowserColumn(url: directory)
        column.isLoading = false
        column.entries = (0..<500).map { index in
            DirectoryEntry(
                url: directory.appendingPathComponent("file-\(index).txt"),
                displayName: "file-\(index).txt",
                isDirectory: false,
                isPackage: false,
                isHidden: false,
                fileSize: nil,
                modifiedAt: nil,
                contentType: .plainText
            )
        }

        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(
            rootView: BrowserColumnContentView(viewModel: viewModel, index: 0, column: column)
                .frame(width: 320, height: 300)
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(firstTable(in: host))

        // Hold every instance seen: comparing identifiers alone would miss
        // fresh allocations that land at a freed row view's address.
        var seen: [NSTableRowView] = []
        for row in stride(from: 0, to: 500, by: 5) {
            table.scrollRowToVisible(row)
            table.layoutSubtreeIfNeeded()
            table.enumerateAvailableRowViews { rowView, _ in
                XCTAssertEqual(rowView.identifier, BrowserColumnRowView.reuseIdentifier)
                if !seen.contains(where: { $0 === rowView }) { seen.append(rowView) }
            }
        }

        XCTAssertGreaterThan(seen.count, 0)
        XCTAssertLessThan(seen.count, 60, "Scrolling 500 rows must reuse row views, not allocate one per row")
    }

    private func firstTable(in view: NSView) -> FileColumnTableView? {
        if let table = view as? FileColumnTableView { return table }
        for child in view.subviews {
            if let table = firstTable(in: child) { return table }
        }
        return nil
    }
}

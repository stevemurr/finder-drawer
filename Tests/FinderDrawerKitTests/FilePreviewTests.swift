import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers
import XCTest
import SwiftUI
@testable import FinderDrawerKit

@MainActor
final class FilePreviewTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func entry(_ name: String, type: UTType? = nil) -> DirectoryEntry {
        .init(url: root.appendingPathComponent(name), displayName: name, isDirectory: false, isPackage: false,
              isHidden: false, fileSize: nil, modifiedAt: nil, contentType: type ?? UTType(filenameExtension: (name as NSString).pathExtension))
    }
    func testClassificationRecognizesAllApprovedPreviewTypes() {
        for (name, kind) in [("clip.mov", FilePreviewDocument.Kind.video), ("sound.wav", .audio), ("book.pdf", .pdf),
                             ("photo.png", .image), ("main.swift", .code), ("script.py", .code), ("README.md", .markdown), ("notes.txt", .text)] {
            XCTAssertEqual(FilePreviewDocument.kind(for: entry(name).url, contentType: entry(name).contentType), kind)
        }
    }
    func testTextPreviewBoundsReadsAndPreservesUnicode() async throws {
        let item = entry("large.txt")
        try Data(repeating: 65, count: FilePreviewDocument.textLimit + 500).write(to: item.url)
        let preview = try await FilePreviewDocument.load(item)
        XCTAssertEqual(preview.text?.utf8.count, FilePreviewDocument.textLimit)
        XCTAssertNotNil(preview.notice)
        let unicode = entry("notes.txt")
        try "Résumé 🌿\r\nSecond line".write(to: unicode.url, atomically: true, encoding: .utf8)
        let text = try await FilePreviewDocument.load(unicode)
        XCTAssertEqual(text.text, "Résumé 🌿\r\nSecond line")
        XCTAssertEqual(text.details.first { $0.label == "Line endings" }?.value, "CRLF")
    }
    func testBinaryMasqueradingAsTextAndMissingFileFailCleanly() async throws {
        let binary = entry("data.txt")
        try Data([0, 1, 2, 3]).write(to: binary.url)
        do { _ = try await FilePreviewDocument.load(binary); XCTFail("Binary must not render as text") } catch { XCTAssertTrue(error is PreviewError) }
        do { _ = try await FilePreviewDocument.load(entry("missing.png")); XCTFail("Missing file must fail") } catch { }
    }
    func testImageAndPDFReadActualDimensionsAndPageCount() async throws {
        let image = NSImage(size: NSSize(width: 80, height: 40), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let imageEntry = entry("sample.tiff")
        try XCTUnwrap(image.tiffRepresentation).write(to: imageEntry.url)
        let preview = try await FilePreviewDocument.load(imageEntry)
        XCTAssertNotNil(preview.image)
        XCTAssertEqual(preview.details.first { $0.label == "Dimensions" }?.value, "80 × 40")
        let pdf = PDFDocument()
        pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 1)
        let pdfEntry = entry("book.pdf")
        XCTAssertTrue(pdf.write(to: pdfEntry.url))
        let document = try await FilePreviewDocument.load(pdfEntry)
        XCTAssertEqual(document.pdf?.pageCount, 2)
        XCTAssertEqual(document.details.first { $0.label == "Pages" }?.value, "2")
    }
    func testAudioMetadataAndWaveformUseTheFilesChannels() async throws {
        let item = entry("stereo.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
        buffer.frameLength = 48000
        for i in 0..<48000 {
            buffer.floatChannelData![0][i] = Float(sin(Double(i) * .pi * 2 * 440 / 48000) * 0.5)
            buffer.floatChannelData![1][i] = 0
        }
        do {
            let file = try AVAudioFile(forWriting: item.url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
            try file.write(from: buffer)
        }
        let preview = try await FilePreviewDocument.load(item)
        XCTAssertEqual(preview.duration, 1, accuracy: 0.01)
        XCTAssertEqual(preview.details.first { $0.label == "Sample rate" }?.value, "48 kHz")
        XCTAssertEqual(preview.details.first { $0.label == "Audio bit depth" }?.value, "16-bit")
        XCTAssertEqual(preview.waveform.count, 2)
        XCTAssertEqual(preview.waveform.first?.count, 180)
        XCTAssertGreaterThan(preview.waveform[0].max() ?? 0, 0.4)
        XCTAssertEqual(preview.waveform[1].max(), 0)
        let playback = PreviewPlayback()
        playback.start(item.url); XCTAssertNotNil(playback.player.currentItem)
        playback.seek(0.5); XCTAssertEqual(playback.position, 0.5)
        playback.stop(); XCTAssertNil(playback.player.currentItem); XCTAssertFalse(playback.isPlaying)
    }
    func testCancelledLoadDoesNotPublishResult() async throws {
        let item = entry("cancel.txt")
        try "Hello".write(to: item.url, atomically: true, encoding: .utf8)
        let task = Task { try await FilePreviewDocument.load(item) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request must not return a stale preview") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testSyntaxColoringPreservesSourceAndMarkdownKeepsStructure() {
        let source = "// Preview\nlet title = \"Hello\"\nreturn 42"
        let highlighted = PreviewSyntax.attributed(source, language: "Swift")
        XCTAssertEqual(highlighted.string, source)
        let range = (source as NSString).range(of: "let")
        XCTAssertEqual(highlighted.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, .systemPink)
        let string = (source as NSString).range(of: "\"Hello\"")
        XCTAssertEqual(highlighted.attribute(.foregroundColor, at: string.location, effectiveRange: nil) as? NSColor, .systemRed)
        let blocks = MarkdownPreviewBlock.parse("# Title\n\nA paragraph.\n\n> Quote\n- Item\n```swift\nlet x = 1\n```")
        XCTAssertEqual(blocks.map(\.kind), [.heading(1), .paragraph, .quote, .list, .code])
        XCTAssertEqual(blocks.last?.text, "let x = 1")
    }
    func testFolderHistoryTraversesAndTruncatesForwardPath() {
        var history = BrowserLocationHistory()
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B"), c = root.appendingPathComponent("C")
        history.visit(a); history.visit(b); history.visit(c)
        XCTAssertEqual(history.move(-1), b.standardizedFileURL)
        history.visit(b); XCTAssertTrue(history.canGoForward)
        history.visit(a); XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.urls.count, 3)
        XCTAssertNil(history.move(10))
    }
    func testNativeCodePreviewHasVisibleTextAndIsReadOnly() async throws {
        let host = NSHostingView(rootView: TextFilePreview(text: "import SwiftUI\nlet title = \"Hello\"", language: "Swift"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        func textView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.compactMap { textView(in: $0) }.first
        }
        let text = try XCTUnwrap(textView(in: host))
        XCTAssertGreaterThan(text.frame.width, 100)
        XCTAssertGreaterThan(text.frame.height, 100)
        let ruler = try XCTUnwrap(text.enclosingScrollView?.verticalRulerView)
        XCTAssertLessThan(ruler.bounds.width, 60)
        XCTAssertFalse(text.isEditable)
        XCTAssertTrue(text.isSelectable)
        XCTAssertEqual(text.string, "import SwiftUI\nlet title = \"Hello\"")
    }

    func testBrowserPreviewKeepsTableResidentAndListFolderHasNoPreview() async throws {
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "Hello".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "Child".write(to: folder.appendingPathComponent("child.txt"), atomically: true, encoding: .utf8)
        let suite = "preview-residency-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let workspace = try DrawerWorkspace(databaseURL: root.appendingPathComponent("index.sqlite3"), defaults: defaults, initialFolders: [root], restoresFolders: false)
        let browser = try XCTUnwrap(workspace.browser)
        let host = NSHostingView(rootView: BrowserPaneView(browser: browser, preferences: workspace.preferences))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.close(); workspace.stop(); defaults.removePersistentDomain(forName: suite) }
        try await Task.sleep(for: .milliseconds(200))
        let table = try XCTUnwrap(BrowserColumnTableLocator.table(for: browser, columnIndex: 0, in: host))
        let file = try XCTUnwrap(browser.columns[0].entries.first { $0.displayName == "notes.txt" })
        browser.select(file.id, inColumn: 0)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(browser.previewEntry)
        XCTAssertTrue(table === BrowserColumnTableLocator.table(for: browser, columnIndex: 0, in: host))
        workspace.preferences.browserListView = true
        let directory = try XCTUnwrap(browser.columns[0].entries.first { $0.isDirectory })
        browser.select(directory.id, inColumn: 0)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(browser.previewEntry)
        XCTAssertEqual(browser.focusedColumnIndex, 1)
        XCTAssertNotNil(BrowserColumnTableLocator.table(for: browser, columnIndex: 1, in: host))
    }

}

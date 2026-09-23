import AppKit
import PDFKit
import QuickLookUI
import SwiftUI

struct FilePreviewPane: View {
    let entry: DirectoryEntry
    var browser: BrowserViewModel?
    @State private var document: FilePreviewDocument?
    @State private var error: String?
    @State private var retry = 0
    private var identity: String { entry.url.path + "|\(entry.modifiedAt?.timeIntervalSince1970 ?? 0)|\(entry.fileSize ?? 0)|\(retry)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Preview", systemImage: "eye")
                Spacer()
                Text("Follows selection")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 14).frame(height: 38)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(nsImage: FileIconCache.icon(for: entry)).resizable().frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.displayName).font(.system(size: 15, weight: .medium)).lineLimit(2).truncationMode(.middle)
                            Text([entry.kindDescription, entry.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    if let document {
                        preview(document).id(identity)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(DrawerTheme.line).allowsHitTesting(false))
                        if let notice = document.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                        if !document.details.isEmpty {
                            Text(sectionTitle(document.kind)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)], alignment: .leading, spacing: 14) {
                                ForEach(document.details) { detail in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(detail.label).font(.system(size: 11)).foregroundStyle(.secondary)
                                        Text(detail.value).font(.system(size: 12)).textSelection(.enabled)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    } else if let error {
                        VStack(spacing: 10) {
                            Image(systemName: "doc.questionmark").font(.title)
                            Text(error).font(.callout).multilineTextAlignment(.center)
                            Button("Try Again") { retry += 1 }
                        }.frame(maxWidth: .infinity, minHeight: 220).foregroundStyle(.secondary)
                    } else { ProgressView("Loading preview…").frame(maxWidth: .infinity, minHeight: 260) }
                    Divider()
                    DisclosureGroup("File information") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(entry.url.path).textSelection(.enabled)
                            if let date = entry.modifiedAt { Text("Modified \(date.formatted(date: .abbreviated, time: .shortened))") }
                        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(16)
            }
        }
        .background(DrawerTheme.surface)
        .accessibilityIdentifier("file-preview-canvas")
        .task(id: identity) {
            document = nil; error = nil
            do {
                try await Task.sleep(for: .milliseconds(80))
                let loaded = try await FilePreviewDocument.load(entry)
                try Task.checkCancellation()
                document = loaded
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    @ViewBuilder private func preview(_ document: FilePreviewDocument) -> some View {
        switch document.kind {
        case .image:
            if let image = document.image { ImageFilePreview(image: image) }
        case .audio, .video: MediaFilePreview(document: document, browser: browser)
        case .pdf:
            if let pdf = document.pdf { PDFFilePreview(document: pdf) }
        case .code, .text: TextFilePreview(text: document.text ?? "", language: document.language)
        case .markdown: MarkdownFilePreview(text: document.text ?? "")
        case .other: QuickLookFilePreview(url: document.url).frame(height: 300)
        }
    }
    private func sectionTitle(_ kind: FilePreviewDocument.Kind) -> String {
        switch kind {
        case .image: "Image details"
        case .audio: "Audio details"
        case .video: "Video details"
        case .code: "Source details"
        case .text: "Text details"
        default: "Document details"
        }
    }
}

private struct ImageFilePreview: View {
    let image: NSImage
    @State private var zoom: CGFloat = 1
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let fit = min(geometry.size.width / max(1, image.size.width), geometry.size.height / max(1, image.size.height))
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: image.size.width * fit * zoom, height: image.size.height * fit * zoom)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
            }.frame(height: 280).background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack(spacing: 16) {
                Button { zoom = max(1, zoom - 0.25) } label: { Image(systemName: "minus") }.accessibilityLabel("Zoom out")
                Text(zoom == 1 ? "Fit" : "\(Int(zoom * 100))% of fit").font(.caption).foregroundStyle(.secondary)
                Button { zoom = min(6, zoom + 0.25) } label: { Image(systemName: "plus") }.accessibilityLabel("Zoom in")
                Button { zoom = 1 } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("Fit image")
            }.buttonStyle(.plain).frame(maxWidth: .infinity).frame(height: 42)
        }
    }
}

private struct PDFFilePreview: View {
    let document: PDFDocument
    @State private var page = 0
    @State private var zoom: CGFloat = 1
    var body: some View {
        VStack(spacing: 0) {
            PDFPreviewSurface(document: document, page: page, zoom: zoom).frame(height: 330)
            Divider()
            HStack(spacing: 12) {
                Button { page -= 1 } label: { Image(systemName: "chevron.left") }.disabled(page == 0).accessibilityLabel("Previous page")
                Text("\(min(page + 1, document.pageCount)) / \(document.pageCount)").font(.caption).foregroundStyle(.secondary)
                Button { page += 1 } label: { Image(systemName: "chevron.right") }.disabled(page + 1 >= document.pageCount).accessibilityLabel("Next page")
                Divider().frame(height: 14)
                Button { zoom = max(1, zoom - 0.5) } label: { Image(systemName: "minus") }.accessibilityLabel("Zoom out PDF")
                Button { zoom = min(5, zoom + 0.5) } label: { Image(systemName: "plus") }.accessibilityLabel("Zoom in PDF")
                Button("Fit") { zoom = 1 }.font(.caption)
            }.buttonStyle(.plain).frame(maxWidth: .infinity).frame(height: 42)
        }
    }
}
private struct PDFPreviewSurface: NSViewRepresentable {
    let document: PDFDocument
    let page: Int
    let zoom: CGFloat
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.displayMode = .singlePage; view.autoScales = true
        view.backgroundColor = .underPageBackgroundColor; view.document = document
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        if let target = document.page(at: page), view.currentPage !== target { view.go(to: target) }
        view.autoScales = zoom == 1
        if zoom != 1 { view.scaleFactor = view.scaleFactorForSizeToFit * zoom }
    }
}
private struct QuickLookFilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .compact)! }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.previewItem = nil; view.close() }
}

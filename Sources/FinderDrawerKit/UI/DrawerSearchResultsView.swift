import AppKit
import QuickLookUI
import SwiftUI

/// A stable split surface: changing the query only changes its contents.
struct DrawerSearchResultsView: View {
    @Bindable var workspace: DrawerWorkspace

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                results
                    .frame(width: (geometry.size.width - 1) * 0.4)
                Divider().frame(width: 1)
                preview
                    .frame(width: (geometry.size.width - 1) * 0.6)
            }
        }
        .onAppear { workspace.resultsDidChange() }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    if workspace.search.results.isEmpty {
                        emptyResults
                    } else {
                        ForEach(workspace.search.results) { result in
                            resultRow(result).id(result.id)
                        }
                    }
                }.padding(8)
            }
            .accessibilityIdentifier("file-search-results")
            .onChange(of: workspace.selectedResultID, initial: true) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onChange(of: workspace.search.results) { _, _ in
                if let id = workspace.selectedResultID { proxy.scrollTo(id) }
            }
        }
    }

    private func resultRow(_ result: FileSearchResult) -> some View {
        let selected = result.id == workspace.selectedResultID
        return Button {
            workspace.selectedResultID = result.id
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: FileIconCache.icon(for: result))
                    .resizable().scaledToFit().frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.displayName).font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text(result.parentPath).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).frame(height: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? Color.accentColor.opacity(0.45) : .clear))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .simultaneousGesture(TapGesture(count: 2).onEnded { workspace.reveal(result) })
        .accessibilityLabel(result.displayName)
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction(named: "Reveal in browser") { workspace.reveal(result) }
    }

    private var emptyResults: some View {
        let emptyQuery = workspace.search.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 25)).foregroundStyle(.tertiary)
            Text(emptyQuery ? "Search by filename" : workspace.search.isSearching ? "Searching…" : "No matching files")
                .font(.system(size: 14, weight: .medium))
            Text(emptyQuery ? "Type a file or folder name to search your indexed folders." :
                    workspace.search.errorMessage ?? (workspace.search.isIndexing ? "Your folders are still being indexed." : "Try a different file name."))
                .font(.callout).foregroundStyle(.secondary)
            if emptyQuery && workspace.folders.folders.isEmpty {
                Button("Choose Folders…", action: workspace.chooseFolders).buttonStyle(.bordered)
            }
        }
        .multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let result = workspace.selectedResult {
                VStack(alignment: .leading, spacing: 5) {
                    Text(result.displayName).font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(result.url.path).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(result.url.path)
                }.padding(16)
                Divider().opacity(0.5)
                EmbeddedFilePreview(url: result.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                HStack(spacing: 8) {
                    Text(result.kindDescription)
                    if let size = result.fileSize, !result.isDirectory {
                        Text("·")
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).padding(12)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.viewfinder").font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text("File preview").font(.system(size: 14, weight: .medium))
                    Text("Select a result with ↑ or ↓ to preview it here.")
                        .font(.callout).foregroundStyle(.secondary)
                }.multilineTextAlignment(.center).padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
        .background(.primary.opacity(0.025))
        .accessibilityIdentifier("file-search-preview")
    }
}

/// Quick Look loads supported documents asynchronously and supplies its native
/// fallback for formats without a preview provider. Reuse the view on selection
/// changes, and release the provider when the palette is dismissed.
struct EmbeddedFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = false
        view.shouldCloseWithWindow = false
        view.setAccessibilityIdentifier("embedded-file-preview")
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if view.previewItem?.previewItemURL != url {
            view.previewItem = url as NSURL
        }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}

import AppKit
import SwiftUI

struct BrowserPaneView: View {
    @Bindable var browser: BrowserViewModel
    @Bindable var preferences: BrowserPreferences
    @State private var history = BrowserLocationHistory()
    private var location: URL? { browser.activeDirectory ?? browser.currentRoot }

    var body: some View {
        VStack(spacing: 8) {
            navigation
            GeometryReader { geometry in
                let preview = browser.previewEntry
                let previewWidth = preview == nil ? 0 : min(620, max(300, geometry.size.width * 0.56))
                let browserWidth = preview == nil ? geometry.size.width : max(220, geometry.size.width - previewWidth - 8)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            VStack(spacing: 0) {
                                HStack {
                                    Text((browser.columns.last?.url ?? location)?.lastPathComponent ?? "Files").lineLimit(1)
                                    Spacer()
                                    Picker("Sort files", selection: $preferences.sortOrder) {
                                        ForEach(BrowserSort.allCases, id: \.self) { sort in Text(sort.rawValue.capitalized).tag(sort) }
                                    }.labelsHidden().fixedSize().controlSize(.small)
                                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 36)
                                Divider()
                                BrowserColumnSurface(viewModel: browser, showsItemSizes: preferences.showItemSizes,
                                                     showsOnlyFocusedColumn: preferences.browserListView)
                            }.drawerPaneBezel().frame(width: browserWidth)
                            if let preview {
                                FilePreviewPane(entry: preview, browser: browser).id(preview.url)
                                    .drawerPaneBezel().frame(width: previewWidth).id("file-preview")
                            }
                        }.frame(height: geometry.size.height)
                    }.scrollIndicators(.hidden)
                        .onChange(of: preview?.url) { _, url in
                            if url != nil, browserWidth + previewWidth + 8 > geometry.size.width {
                                proxy.scrollTo("file-preview", anchor: .trailing)
                            }
                        }
                }
            }
        }
        .onChange(of: browser.columns.count) { _, _ in focusListColumn() }
        .onChange(of: preferences.browserListView) { _, _ in focusListColumn() }
        .onChange(of: location, initial: true) { _, url in if let url { history.visit(url) } }
    }

    private var navigation: some View {
        HStack(spacing: 6) {
            Button { travel(-1) } label: { Image(systemName: "chevron.left") }.disabled(!history.canGoBack).help("Back")
            Button { travel(1) } label: { Image(systemName: "chevron.right") }.disabled(!history.canGoForward).help("Forward")
            Button { browser.goToParent() } label: { Image(systemName: "arrow.up") }.help("Go to parent folder (⌘↑)")
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(Array(browser.columns.enumerated()), id: \.element.id) { index, column in
                        if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8)) }
                        Button(column.url.lastPathComponent.isEmpty ? "/" : column.url.lastPathComponent) {
                            browser.browseColumn(at: index)
                        }.help(column.url.path)
                    }
                }.padding(.horizontal, 4)
            }.scrollIndicators(.hidden)
            if browser.isTransferringFiles { ProgressView().controlSize(.mini) }
            Button { preferences.browserListView = false } label: {
                Image(systemName: "rectangle.split.2x1").foregroundStyle(preferences.browserListView ? Color.secondary : .accentColor)
            }.help("Column view").accessibilityLabel("Column view")
            Button { preferences.browserListView = true } label: {
                Image(systemName: "list.bullet").foregroundStyle(preferences.browserListView ? Color.accentColor : .secondary)
            }.help("List view").accessibilityLabel("List view")
        }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 28).padding(.horizontal, 6)
    }
    private func focusListColumn() {
        guard preferences.browserListView, browser.columns.count > browser.focusedColumnIndex + 1 else { return }
        browser.browseColumn(at: browser.columns.count - 1)
    }
    private func travel(_ delta: Int) {
        if let url = history.move(delta) { browser.setRoot(url); browser.present(); browser.onRequestColumnFocus?() }
    }
}

/// Only folder URLs are retained: browsing history never retains directory
/// listings, file handles, or media players.
struct BrowserLocationHistory {
    private(set) var urls: [URL] = []
    private(set) var index = -1
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < urls.count }
    mutating func visit(_ url: URL) {
        let url = url.standardizedFileURL
        if urls.indices.contains(index), urls[index] == url { return }
        urls = Array(urls.prefix(index + 1)); urls.append(url)
        if urls.count > 80 { urls.removeFirst(urls.count - 80) }
        index = urls.count - 1
    }
    mutating func move(_ delta: Int) -> URL? {
        guard urls.indices.contains(index + delta) else { return nil }
        index += delta; return urls[index]
    }
}

private struct DrawerPaneBezel: ViewModifier {
    let enabled: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.background(DrawerTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(2)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DrawerTheme.line).allowsHitTesting(false))
        } else { content }
    }
}
extension View {
    func drawerPaneBezel(enabled: Bool = true) -> some View { modifier(DrawerPaneBezel(enabled: enabled)) }
}

import AppKit
import QuickLookUI
import SwiftUI

struct DrawerRootView: View {
    @Bindable var workspace: DrawerWorkspace
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 188)
                Divider()
                VStack(spacing: 0) {
                    tabBar
                    Divider()
                    if workspace.isSearchPresented {
                        searchResults
                    } else if let browser = workspace.browser, browser.currentRoot != nil {
                        VStack(spacing: 0) {
                            breadcrumbs(browser)
                            Divider()
                            BrowserColumnSurface(
                                viewModel: browser,
                                showsItemSizes: workspace.preferences.showItemSizes
                            )
                        }
                    } else {
                        ContentUnavailableView {
                            Label("Your files, a shortcut away", systemImage: "folder")
                        } description: {
                            Text("Choose the folders you want to browse and search.")
                        } actions: {
                            Button("Choose Folders…", action: workspace.chooseFolders)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 760, minHeight: 380)
        .onChange(of: workspace.searchFocusToken) { searchFocused = true }
        .onChange(of: workspace.isSearchPresented) { _, presented in searchFocused = presented }
        .onChange(of: workspace.search.results) { workspace.resultsDidChange() }
        .onChange(of: workspace.selectedResultID) {
            workspace.quickLook.refreshIfVisible(with: workspace.selectedResult)
        }
        .onChange(of: workspace.browser?.currentRoot) { workspace.persistTabs() }
        .onChange(of: workspace.preferences.showHiddenFiles) { workspace.applyPreferences() }
        .onChange(of: workspace.preferences.sortOrder) { workspace.applyPreferences() }
        .sheet(isPresented: $workspace.isFolderPickerPresented) { FolderPickerView(workspace: workspace) }
        .sheet(isPresented: $workspace.isPreferencesPresented) { preferences }
        .alert("Couldn’t complete the action", isPresented: Binding(
            get: { workspace.errorMessage != nil || workspace.browser?.errorMessage != nil },
            set: { if !$0 { workspace.errorMessage = nil; workspace.browser?.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { workspace.errorMessage = nil; workspace.browser?.errorMessage = nil }
        } message: {
            Text(workspace.errorMessage ?? workspace.browser?.errorMessage ?? "")
        }
    }

    private var toolbar: some View {
        @Bindable var search = workspace.search
        @Bindable var preferences = workspace.preferences
        return HStack(spacing: 14) {
            Label("Finder Drawer", systemImage: "folder.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 170, alignment: .leading)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                AppKitSearchField(
                    text: $search.searchText,
                    placeholder: "Search files and folders",
                    focus: $searchFocused,
                    accessibilityIdentifier: "file-search",
                    fontSize: 14,
                    onBeginEditing: { workspace.isSearchPresented = true },
                    onCommand: handleSearchCommand
                )
                if !workspace.search.searchText.isEmpty {
                    Button { workspace.search.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.buttonStyle(.plain).help("Clear search")
                }
                Text("⌘K").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator.opacity(0.6)))
            .frame(maxWidth: 560)
            Spacer(minLength: 0)
            Button { workspace.perform(.goToFolder) } label: {
                Image(systemName: "folder.badge.gearshape")
            }.help("Go to Folder (⇧⌘G)")
            Menu {
                Button("Choose Folders…", action: workspace.chooseFolders)
                Button("Refresh Search Index", action: workspace.index.rebuildIndex)
                Divider()
                Toggle("Show Hidden Files", isOn: $preferences.showHiddenFiles)
                Toggle("Show File Sizes", isOn: $preferences.showItemSizes)
                Picker("Sort by", selection: $preferences.sortOrder) {
                    ForEach(BrowserSort.allCases) { Text($0.label).tag($0) }
                }
                Divider()
                Button("Settings…") { workspace.isPreferencesPresented = true }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FOLDERS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(workspace.folders.folders, id: \.self) { root in
                        Button { workspace.navigate(to: root) } label: {
                            Label(root.lastPathComponent, systemImage: "folder")
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(
                                    workspace.browser?.currentRoot?.standardizedFileURL == root.standardizedFileURL
                                        ? Color.accentColor.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(root.path)
                        .contextMenu {
                            Button("Open in New Tab") { workspace.newTab(at: root) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                            Divider()
                            Button("Remove from Drawer") { workspace.removeFolder(root) }
                        }
                    }
                }.padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            Button(action: workspace.chooseFolders) { Label("Add Folders…", systemImage: "plus") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 14)
        }
        .padding(.top, 18)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.45))
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(workspace.tabs) { tab in
                        HStack(spacing: 8) {
                            Button { workspace.selectTab(tab.id) } label: {
                                Label(tab.currentRoot?.lastPathComponent ?? "Files", systemImage: "folder")
                                    .lineLimit(1).frame(minWidth: 80, maxWidth: 170, alignment: .leading)
                            }
                            Button { workspace.closeTab(tab.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            }.help("Close tab")
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(tab.id == workspace.selectedTabID ? Color(nsColor: .controlBackgroundColor) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                }.padding(.horizontal, 8)
            }.scrollIndicators(.hidden)
            Button { workspace.newTab() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("New Tab (⌘T)").padding(.horizontal, 12)
        }
        .font(.system(size: 12)).frame(height: 42)
    }

    private func breadcrumbs(_ browser: BrowserViewModel) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Button { browser.goToParent() } label: { Image(systemName: "arrow.up") }
                    .help("Go to parent folder (⌘↑)")
                ForEach(Array(browser.columns.enumerated()), id: \.element.id) { index, column in
                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8)) }
                    Button(column.url.lastPathComponent.isEmpty ? "/" : column.url.lastPathComponent) {
                        browser.focusColumn(at: index)
                    }.help(column.url.path)
                }
            }.buttonStyle(.plain).padding(.horizontal, 14)
        }
        .scrollIndicators(.hidden).font(.system(size: 11)).foregroundStyle(.secondary).frame(height: 33)
    }

    @ViewBuilder private var searchResults: some View {
        if workspace.search.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView("Search your folders", systemImage: "magnifyingglass",
                                   description: Text("Type part of a file or folder name. Results come from your selected folders."))
        } else if workspace.search.results.isEmpty {
            ContentUnavailableView(workspace.search.isSearching ? "Searching…" : "No matching files",
                                   systemImage: "magnifyingglass",
                                   description: Text(workspace.search.isIndexing ? "The index is still being built. Results appear as files are indexed." : "Try a different name or add another folder."))
        } else {
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    List(selection: $workspace.selectedResultID) {
                        ForEach(workspace.search.results) { result in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: result.url.path))
                                    .resizable().frame(width: 24, height: 24)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(result.parentPath).font(.system(size: 10)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .padding(.vertical, 3)
                            .tag(result.id).id(result.id)
                            .onTapGesture(count: 2) { workspace.reveal(result) }
                            .contextMenu {
                                Button("Reveal in Browser") { workspace.reveal(result) }
                                Button("Open") { workspace.openResult(result) }
                                Button("Quick Look") { workspace.quickLook.toggle(for: result) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.url]) }
                                Button("Copy Path") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(result.url.path, forType: .string)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .onChange(of: workspace.selectedResultID) { _, id in if let id { proxy.scrollTo(id) } }
                }.frame(minWidth: 290, idealWidth: 390, maxWidth: .infinity)
                Divider()
                if let result = workspace.selectedResult {
                    VStack(alignment: .leading, spacing: 12) {
                        if result.isDirectory {
                            Image(systemName: "folder.fill").font(.system(size: 70)).foregroundStyle(.tint)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            FilePreview(url: result.url).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        Text(result.displayName).font(.headline).textSelection(.enabled)
                        Text(result.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Text(result.kindDescription)
                            if let size = result.fileSize { Text("• " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                        }.font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Reveal in Browser") { workspace.reveal(result) }.buttonStyle(.borderedProminent)
                            Button("Open") { workspace.openResult(result) }
                        }
                    }.padding(18).frame(minWidth: 220, idealWidth: 290, maxWidth: 360)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if workspace.search.isIndexing { ProgressView().controlSize(.mini) }
            Text(workspace.search.errorMessage ?? workspace.search.indexStatus)
                .foregroundStyle(workspace.search.errorMessage == nil ? Color.secondary : .red)
            Spacer()
            if workspace.isSearchPresented {
                Text(workspace.search.resultCountDescription)
                Text("·  ↵ Reveal  ·  Esc Browse").foregroundStyle(.tertiary)
            } else if let browser = workspace.browser {
                Text(browser.focusedSelectionCount > 0 ? "\(browser.focusedSelectionCount) selected" : "Space to Quick Look")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .padding(.horizontal, 16).frame(height: 30)
    }

    private var preferences: some View {
        @Bindable var preferences = workspace.preferences
        return VStack(alignment: .leading, spacing: 18) {
            Text("Finder Drawer Settings").font(.title2.bold())
            Toggle("Show hidden files while browsing", isOn: $preferences.showHiddenFiles)
            Toggle("Show file sizes", isOn: $preferences.showItemSizes)
            Picker("Sort folders by", selection: $preferences.sortOrder) {
                ForEach(BrowserSort.allCases) { Text($0.label).tag($0) }
            }
            Text("Search indexes names in the folders you choose. Hidden files and ignored paths are excluded from search.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Show or hide the drawer with ⌃⌥Space, or use its menu bar icon.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Refresh Search Index", action: workspace.index.rebuildIndex)
                Spacer()
                Button("Done") { workspace.isPreferencesPresented = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 430)
    }

    private func handleSearchCommand(_ command: AppKitSearchField.Command) -> Bool {
        switch command {
        case .moveUp: workspace.moveResultSelection(by: -1)
        case .moveDown: workspace.moveResultSelection(by: 1)
        case .submit: if let result = workspace.selectedResult { workspace.reveal(result) }
        case .cancel: workspace.dismissSearch()
        case .moveLeft, .moveRight, .switchScope: return false
        }
        return true
    }
}

private struct FilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView { QLPreviewView(frame: .zero, style: .normal)! }
    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) != url as NSURL { view.previewItem = url as NSURL }
    }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

private struct FolderPickerView: View {
    @Bindable var workspace: DrawerWorkspace
    @State private var query = ""
    @State private var folders: [URL] = []
    @State private var selection: URL?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Go to Folder").font(.title2.bold())
            TextField("Folder name or /absolute/path", text: $query)
                .textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit { openSelection() }
            List(folders, id: \.self, selection: $selection) { folder in
                Label(folder.path, systemImage: "folder").lineLimit(1).truncationMode(.middle).tag(folder)
                    .onTapGesture(count: 2) { selection = folder; openSelection() }
            }.frame(height: 220)
            HStack {
                Button("Cancel") { workspace.isFolderPickerPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Go", action: openSelection).keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
        }.padding(24).frame(width: 520)
            .onAppear { focused = true }
            .task(id: query) {
                let matches = await workspace.index.matchingFolders(for: query)
                guard !Task.isCancelled else { return }
                folders = matches
                selection = matches.first
            }
    }

    private func openSelection() {
        guard let selection else { return }
        workspace.isFolderPickerPresented = false
        workspace.navigate(to: selection)
    }
}

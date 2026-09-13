import SwiftUI

struct DrawerActionsView: View {
    @Bindable var workspace: DrawerWorkspace
    var maximumListHeight: CGFloat = 350
    var availableWidth: CGFloat = 680
    var focusIdentifier = "context-actions-search"
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var mode: String { workspace.isLocationPresented ? "location" : workspace.isSearchPresented ? "search" : "actions" }
    private var title: String { mode == "location" ? "Go to Folder" : mode == "search" ? "Search Files" : workspace.actionContextTitle }
    private var query: Binding<String> {
        Binding(get: {
            mode == "location" ? workspace.locations.query : mode == "search" ? workspace.search.searchText : workspace.actionQuery
        }, set: {
            if mode == "location" { workspace.locations.query = $0 }
            else if mode == "search" { workspace.search.searchText = $0 }
            else { workspace.actionQuery = $0; workspace.selectedActionIndex = 0 }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .lineLimit(1).padding(.horizontal, 18).padding(.top, 15)
            HStack(spacing: 10) {
                Image(systemName: mode == "location" ? "folder" : "magnifyingglass").foregroundStyle(.secondary)
                AppKitSearchField(text: query,
                    placeholder: mode == "location" ? "Type a path or find a recent folder…" : mode == "search" ? "Search files…" : "Search actions…",
                    focus: $focused, accessibilityIdentifier: focusIdentifier, fontSize: 17, onCommand: handle)
                Text("esc").font(.system(size: 11)).foregroundStyle(.tertiary)
            }.padding(.horizontal, 18).frame(height: 52)
            Divider().opacity(0.5)
            if mode == "search" {
                DrawerSearchResultsView(workspace: workspace)
                    .frame(height: maximumListHeight)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            if mode == "actions" {
                                ForEach(Array(workspace.filteredActions.enumerated()), id: \.element.id) { index, action in
                                    paletteRow(action.title, symbol: action.symbol, shortcut: action.shortcut,
                                               selected: index == workspace.selectedActionIndex) {
                                        workspace.selectedActionIndex = index; workspace.executeSelectedAction()
                                    }.id(index)
                                }
                                if workspace.filteredActions.isEmpty { emptyState("No matching actions", detail: "Try another command name.") }
                            } else if mode == "location" {
                                ForEach(Array(workspace.locations.visibleSuggestions.enumerated()), id: \.element.path) { index, url in
                                    paletteRow(url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent, detail: url.path,
                                               symbol: "folder", selected: index == workspace.locations.selectedIndex) {
                                        workspace.locations.selectedIndex = index; workspace.openSelectedLocation()
                                    }.id(index)
                                }
                                if workspace.locations.visibleSuggestions.isEmpty {
                                    if workspace.locations.query.isEmpty { emptyState("Your recent folders appear here", detail: "Type a path to open any folder.") }
                                    else {
                                        paletteRow("Open typed path", detail: workspace.locations.query, symbol: "arrow.turn.down.right", selected: true) {
                                            workspace.openSelectedLocation()
                                        }
                                    }
                                }
                                if let error = workspace.locations.errorMessage {
                                    Text(error).font(.callout).foregroundStyle(.red).padding(12)
                                }
                            }
                        }.padding(8)
                    }
                    .frame(height: maximumListHeight)
                    .onChange(of: workspace.selectedActionIndex) { _, index in proxy.scrollTo(index) }
                    .onChange(of: workspace.locations.selectedIndex) { _, index in proxy.scrollTo(index) }
                }
            }
            Divider().opacity(0.5)
            HStack {
                Text("↑ ↓ Navigate")
                if mode == "location" { Text("·  Tab Complete") }
                if mode == "search" { Text("·  ↵ Reveal") }
                Spacer()
                Text(mode == "search" ? workspace.search.resultCountDescription : "↵ Open")
            }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).padding(13)
        }
        .frame(width: min(mode == "search" ? 1040 : 660, max(300, availableWidth)))
        .background {
            if reduceTransparency { RoundedRectangle(cornerRadius: 20).fill(Color(nsColor: .windowBackgroundColor)) }
            else { RoundedRectangle(cornerRadius: 20).fill(.regularMaterial) }
        }
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 28, y: 10)
        .onAppear { focused = true }
        .onChange(of: mode) { focused = true }
        .task(id: workspace.locations.query) {
            if workspace.isLocationPresented { await workspace.locations.refresh(index: workspace.index) }
        }
    }

    private func paletteRow(_ title: String, detail: String? = nil, symbol: String, shortcut: String = "",
                            selected: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 16)).frame(width: 24).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 8)
                if !shortcut.isEmpty {
                    Text(shortcut).font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
                }
            }.padding(.horizontal, 12).frame(height: detail == nil ? 41 : 53)
                .contentShape(Rectangle())
                .background(selected ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 14, weight: .medium))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(25).frame(maxWidth: .infinity)
    }

    private func handle(_ command: AppKitSearchField.Command) -> Bool {
        switch command {
        case .moveUp: workspace.movePaletteSelection(by: -1)
        case .moveDown: workspace.movePaletteSelection(by: 1)
        case .submit: workspace.submitPalette()
        case .cancel: workspace.dismissPalette()
        case .switchScope:
            guard workspace.isLocationPresented else { return false }
            workspace.locations.completeSelection()
        default: return false
        }
        return true
    }
}

extension DrawerWorkspace {
    func movePaletteSelection(by offset: Int) {
        if isLocationPresented { locations.move(by: offset) }
        else if isSearchPresented { moveResultSelection(by: offset) }
        else { moveActionSelection(by: offset) }
    }
    func submitPalette() {
        if isLocationPresented { openSelectedLocation() }
        else if isSearchPresented { if let selectedResult { reveal(selectedResult) } }
        else { executeSelectedAction() }
    }
}

import AppKit
import QuickLookUI
import SwiftUI

struct DrawerRootView: View {
    @Bindable var workspace: DrawerWorkspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hoveringTabs = false

    var body: some View {
        HStack(spacing: 0) {
            if workspace.preferences.isSidebarVisible {
                sidebar.frame(width: DrawerWorkspace.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            VStack(spacing: 0) {
                tabBar
                Divider()
                if workspace.isSplit {
                    HSplitView {
                        pane(.primary).frame(minWidth: 240)
                        pane(.secondary).frame(minWidth: 240)
                    }
                } else { pane(.primary) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: workspace.preferences.isSidebarVisible)
        .allowsHitTesting(!workspace.isPalettePresented)
        .overlay {
            GeometryReader { geometry in
                if workspace.isPalettePresented {
                    ZStack {
                        Color.black.opacity(0.035).contentShape(Rectangle()).onTapGesture { workspace.dismissPalette() }
                        DrawerActionsView(workspace: workspace,
                            maximumListHeight: max(80, min(400, geometry.size.height - 180)),
                            availableWidth: geometry.size.width - 48, focusIdentifier: workspace.paletteInputIdentifier)
                        .id(workspace.paletteInputIdentifier)
                        .transition(reduceMotion ? .opacity : .offset(x: -geometry.size.width * 0.3, y: geometry.size.height * 0.3)
                            .combined(with: .scale(scale: 0.15, anchor: .bottomLeading)).combined(with: .opacity))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.9), value: workspace.isPalettePresented)
        }
        .frame(minWidth: 760, minHeight: 380)
        .onChange(of: workspace.search.results) { workspace.resultsDidChange() }
        .onChange(of: workspace.selectedTab?.currentRoot) { workspace.persistTabs() }
        .onChange(of: workspace.preferences.showHiddenFiles) { workspace.applyPreferences() }
        .onChange(of: workspace.preferences.sortOrder) { workspace.applyPreferences() }
        .alert("Couldn’t complete the action", isPresented: Binding(
            get: { workspace.errorMessage != nil || workspace.browser?.errorMessage != nil },
            set: { if !$0 { workspace.errorMessage = nil; workspace.browser?.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { workspace.errorMessage = nil; workspace.browser?.errorMessage = nil }
        } message: { Text(workspace.errorMessage ?? workspace.browser?.errorMessage ?? "") }
    }

    @ViewBuilder private func pane(_ pane: DrawerWorkspace.Pane) -> some View {
        if let tab = workspace.tab(in: pane) {
            VStack(spacing: 0) {
                if workspace.isSplit {
                    HStack(spacing: 8) {
                        Circle().fill(workspace.activePane == pane ? Color.accentColor : .clear).frame(width: 6, height: 6)
                        Image(systemName: tab.symbol)
                        Text(tab.title).lineLimit(1)
                        Spacer(minLength: 4)
                        if tab.browser?.isTransferringFiles == true { ProgressView().controlSize(.mini) }
                        Button { workspace.focusPane(pane); workspace.closeSplit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .buttonStyle(.plain).help("Keep this pane")
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).frame(height: 33)
                        .background(workspace.activePane == pane ? Color.accentColor.opacity(0.035) : .clear)
                    Divider()
                }
                if let terminal = tab.terminal {
                    TerminalSurface(session: terminal).id(terminal.id)
                } else if let browser = tab.browser, browser.currentRoot != nil {
                    breadcrumbs(browser)
                    Divider()
                    BrowserColumnSurface(viewModel: browser, showsItemSizes: workspace.preferences.showItemSizes)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "folder").font(.system(size: 32)).foregroundStyle(.secondary)
                        Text("Choose a folder to get started")
                        Button("Open Location…") { workspace.focusPane(pane); workspace.beginLocations() }
                            .buttonStyle(.bordered)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(DrawerPaneMarker(pane: pane))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("drawer-pane-" + pane.rawValue)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Favorites")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            ScrollView {
                VStack(spacing: 3) {
                    location("Home", symbol: "house", url: FileManager.default.homeDirectoryForCurrentUser)
                    location("Applications", symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications"))
                    location("Computer", symbol: "desktopcomputer", url: URL(fileURLWithPath: "/"))
                    location("Volumes", symbol: "externaldrive", url: URL(fileURLWithPath: "/Volumes"))
                    if !workspace.folders.folders.isEmpty {
                        Text("Indexed Folders").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 5)
                    }
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
            Button(action: workspace.chooseFolders) { Label("Add Folders…", systemImage: "plus") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 5)
            Divider().padding(.horizontal, 12)
            HStack(spacing: 10) {
                Button { workspace.perform(.settings) } label: { Image(systemName: "gearshape") }
                    .help("Settings (⌘,)").accessibilityLabel("Settings")
                Button { workspace.presentActions() } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Actions (⌘K)").accessibilityLabel("Actions")
                Button { workspace.beginSearch() } label: { Image(systemName: "magnifyingglass") }
                    .help("Search Files (⌘F)").accessibilityLabel("Search Files")
                Spacer()
            }.buttonStyle(DrawerIconButtonStyle()).padding(.horizontal, 12).padding(.bottom, 10)
        }
        .padding(.top, 18)
        .frame(maxHeight: .infinity)
        .background(DrawerSidebarMaterial().ignoresSafeArea(.container, edges: .top))
    }

    private func location(_ name: String, symbol: String, url: URL) -> some View {
        Button { workspace.navigate(to: url) } label: {
            Label(name, systemImage: symbol)
                .symbolRenderingMode(.hierarchical)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(workspace.browser?.currentRoot?.standardizedFileURL == url.standardizedFileURL
                            ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help(url.path)
    }

    private var tabBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(workspace.tabs) { tab in
                    DrawerTabButton(tab: tab, isSelected: tab.id == workspace.selectedTabID,
                                    select: { workspace.selectTab(tab.id) }, close: { workspace.closeTab(tab.id) })
                }
                HStack(spacing: 3) {
                    Menu {
                        Button("New File Tab", action: { workspace.newTab() }).keyboardShortcut("n")
                        Button("New Terminal Here", action: { workspace.newTerminal() }).keyboardShortcut("t")
                    } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .medium)).frame(width: 28, height: 30)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("New tab").accessibilityLabel("New Tab")
                    Divider().frame(height: 14)
                    Menu {
                        Button("Split with File Browser") { workspace.splitPane(terminal: false) }
                        Button("Split with Terminal") { workspace.splitPane(terminal: true) }
                        if workspace.isSplit {
                            Divider()
                            Button("Focus Other Pane") { workspace.perform(.focusOtherPane) }
                            Button("Single Pane") { workspace.closeSplit() }
                        }
                    } label: {
                        Image(systemName: "rectangle.split.2x1").font(.system(size: 14)).frame(width: 28, height: 30)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Split View (⌘\\)").accessibilityLabel("Split View")
                }
                .padding(.horizontal, 4)
                .opacity(hoveringTabs ? 1 : 0.55)
            }.padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden).font(.system(size: 12)).frame(height: 48)
        .onHover { hoveringTabs = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hoveringTabs)
    }

    private func breadcrumbs(_ browser: BrowserViewModel) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if browser.isTransferringFiles { ProgressView().controlSize(.mini) }
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

}

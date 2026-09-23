import AppKit
import QuickLookUI
import SwiftUI

struct DrawerRootView: View {
    @Bindable var workspace: DrawerWorkspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            if workspace.preferences.isSidebarVisible {
                sidebar.frame(width: DrawerWorkspace.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }
            VStack(spacing: 0) {
                Group {
                    if workspace.isSplit {
                        HSplitView {
                            pane(.primary).padding(.trailing, 4).frame(minWidth: 240)
                            pane(.secondary).padding(.leading, 4).frame(minWidth: 240)
                        }
                    } else { pane(.primary) }
                }
                .padding(8)
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
                            .buttonStyle(.plain).help("Unpair tabs")
                    }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).frame(height: 33)
                        .background(workspace.activePane == pane ? Color.accentColor.opacity(0.035) : .clear)
                    Divider()
                }
                if let terminal = tab.terminal {
                    TerminalSurface(session: terminal).id(terminal.id)
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor))
                } else if let browser = tab.browser, browser.currentRoot != nil {
                    BrowserPaneView(browser: browser, preferences: workspace.preferences)
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
            .drawerPaneBezel(enabled: tab.browser == nil)
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

}

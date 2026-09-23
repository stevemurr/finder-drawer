import SwiftUI

struct DrawerTabBar: View {
    @Bindable var workspace: DrawerWorkspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoveringTabs = false
    @State private var tabDrag = DrawerTabDragState()
    @Namespace private var tabAnimation

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(workspace.tabGroups) { group in
                    if let left = workspace.tab(withID: group.primaryID) {
                        Group {
                            if let rightID = group.secondaryID, let right = workspace.tab(withID: rightID) {
                                DrawerTabPairButton(left: left, right: right,
                                    isSelected: group.id == workspace.selectedGroupID, focusedID: group.focusedID,
                                    select: { workspace.selectTab($0) }, close: { workspace.closeGroup(group.id) },
                                    unpair: { workspace.unpairGroup(group.id) },
                                    drag: DrawerTabDragGesture(workspace: workspace, state: tabDrag, groupID: group.id),
                                    tabAnimation: tabAnimation)
                            } else {
                                DrawerTabButton(tab: left, isSelected: group.id == workspace.selectedGroupID,
                                    select: { workspace.selectGroup(group.id) }, close: { workspace.closeGroup(group.id) },
                                    drag: DrawerTabDragGesture(workspace: workspace, state: tabDrag, groupID: group.id),
                                    tabAnimation: tabAnimation)
                            }
                        }
                        .modifier(DrawerTabReordering(workspace: workspace, state: tabDrag, groupID: group.id))
                    }
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
                        Button("Split with File Browser") { workspace.perform(.splitFiles) }.keyboardShortcut("s").disabled(workspace.isSplit)
                        Button("Split with Terminal") { workspace.perform(.splitTerminal) }.keyboardShortcut("d").disabled(workspace.isSplit)
                        if workspace.isSplit {
                            Divider()
                            Button("Focus Other Pane") { workspace.perform(.focusOtherPane) }
                            Button("Unpair Tabs") { workspace.closeSplit() }
                        }
                    } label: {
                        Image(systemName: "rectangle.split.2x1").font(.system(size: 14)).frame(width: 28, height: 30)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Split: Terminal (⌘D) · Files (⌘S)").accessibilityLabel("Split View")
                }
                .padding(.horizontal, 4)
                .opacity(hoveringTabs ? 1 : 0.8)
                .modifier(DrawerTabReordering(workspace: workspace, state: tabDrag, groupID: nil))
            }.padding(.horizontal, 8)
                .coordinateSpace(name: "drawer-tab-strip")
        }
        // `.never`, not `.hidden`: under "Show scroll bars: Always" `.hidden`
        // still shows a legacy scroller once the tabs overflow, and it takes
        // its height out of the strip, clipping the top of the tabs.
        .scrollIndicators(.never).font(.system(size: 12)).frame(height: 40)
        .scrollClipDisabled(tabDrag.sourceID != nil)
        .zIndex(1)
        .onHover { hoveringTabs = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hoveringTabs)
    }
}

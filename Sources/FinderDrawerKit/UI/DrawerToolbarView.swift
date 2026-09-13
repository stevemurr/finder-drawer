import SwiftUI

struct DrawerToolbarView: View {
    @Bindable var workspace: DrawerWorkspace

    var body: some View {
        HStack(spacing: 0) {
            HStack {
                Button { workspace.perform(.toggleSidebar) } label: { Image(systemName: "sidebar.left") }
                    .help("Toggle Sidebar (⌃⌘S)").accessibilityLabel("Toggle Sidebar")
                Spacer(minLength: 0)
            }.frame(width: workspace.preferences.isSidebarVisible ? workspace.toolbarLeadingWidth : 40)
            if workspace.preferences.isSidebarVisible { Divider().frame(maxHeight: .infinity) }
            HStack(spacing: 8) {
                Image(systemName: workspace.selectedTab?.symbol ?? "folder")
                Text(workspace.selectedTab?.title ?? "Finder Drawer")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 8)
            }.padding(.leading, 14).padding(.trailing, 4)
        }
        .buttonStyle(DrawerIconButtonStyle())
        .frame(maxWidth: .infinity).frame(height: 40)
    }
}

struct DrawerIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { IconBody(configuration: configuration) }
    private struct IconBody: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label.font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary).frame(width: 30, height: 30)
                .background(.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0),
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8)).onHover { hovering = $0 }
        }
    }
}

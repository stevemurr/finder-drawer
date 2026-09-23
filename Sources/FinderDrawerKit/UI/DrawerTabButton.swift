import SwiftUI

struct DrawerTabButton: View {
    let tab: DrawerTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    let drag: DrawerTabDragGesture
    let tabAnimation: Namespace.ID
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var appearance: DrawerTabAppearance { DrawerTabAppearance(colorScheme: colorScheme) }

    private let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                DrawerTabLabel(tab: tab, emphasized: isSelected, selected: isSelected)
                    .padding(.leading, 14).padding(.trailing, 10).frame(height: 36)
                    .matchedGeometryEffect(id: tab.id, in: tabAnimation)
                    .contentShape(Rectangle())
                    .modifier(drag)
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(tab.currentRoot?.path ?? tab.title)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appearance.close).frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }.help("Close \(tab.title)").accessibilityLabel("Close \(tab.title)")
                .padding(.trailing, 5)
        }
        .buttonStyle(.plain)
        .background {
            shape.fill(appearance.fill(selected: isSelected, hovering: hovering))
                .matchedGeometryEffect(id: drag.groupID, in: tabAnimation)
        }
        .overlay {
            shape.strokeBorder(appearance.border(selected: isSelected), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(isSelected ? 0.07 : 0), radius: 3, y: 1)
        .onHover { hovering = $0 }
    }
}

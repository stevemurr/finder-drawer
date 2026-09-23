import SwiftUI

/// One outlined tab with two segments reflects the persistent left/right pair.
struct DrawerTabPairButton: View {
    let left: DrawerTab
    let right: DrawerTab
    let isSelected: Bool
    let focusedID: UUID
    let select: (UUID) -> Void
    let close: () -> Void
    let unpair: () -> Void
    let drag: DrawerTabDragGesture
    let tabAnimation: Namespace.ID
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    private var appearance: DrawerTabAppearance { DrawerTabAppearance(colorScheme: colorScheme) }

    private let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
    private var title: String { left.title + " + " + right.title }

    var body: some View {
        HStack(spacing: 0) {
            segment(left)
            Divider().frame(height: 18)
            segment(right)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(appearance.close).frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }.padding(.trailing, 5).help("Close both tabs").accessibilityLabel("Close pair: " + title)
        }
        .buttonStyle(.plain)
        .background(shape.fill(appearance.fill(selected: isSelected, hovering: hovering))
            .matchedGeometryEffect(id: drag.groupID, in: tabAnimation))
        .overlay(shape.strokeBorder(appearance.border(selected: isSelected))
            .allowsHitTesting(false))
        .shadow(color: .black.opacity(isSelected ? 0.07 : 0), radius: 3, y: 1)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Unpair Tabs", action: unpair)
            Divider()
            Button("Close Pair", action: close)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Split pair: " + title)
        .accessibilityIdentifier("split-tab-pair")
        .accessibilityAction(named: "Unpair Tabs", unpair)
    }

    private func segment(_ tab: DrawerTab) -> some View {
        Button { select(tab.id) } label: {
            DrawerTabLabel(tab: tab, emphasized: isSelected && focusedID == tab.id, selected: isSelected)
                .padding(.horizontal, 14).frame(height: 36)
                .matchedGeometryEffect(id: tab.id, in: tabAnimation)
                .contentShape(Rectangle())
                .background(isSelected && focusedID == tab.id ? Color.primary.opacity(0.06) : .clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .modifier(drag)
        }
        .help(tab.currentRoot?.path ?? tab.title)
        .accessibilityAddTraits(isSelected && focusedID == tab.id ? .isSelected : [])
    }
}

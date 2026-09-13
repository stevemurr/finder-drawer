import SwiftUI

struct DrawerTabButton: View {
    let tab: DrawerTab
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    private let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                Label(tab.title, systemImage: tab.symbol)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1).frame(minWidth: 82, maxWidth: 170, alignment: .leading)
                    .padding(.leading, 11).padding(.trailing, 7).frame(height: 34)
                    .contentShape(Rectangle())
            }
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .help(tab.currentRoot?.path ?? tab.title)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 24, height: 34)
                    .contentShape(Rectangle())
            }.help("Close \(tab.title)").accessibilityLabel("Close \(tab.title)")
                .padding(.trailing, 3)
        }
        .buttonStyle(.plain)
        .background {
            shape.fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.primary.opacity(hovering ? 0.065 : 0.035))
        }
        .overlay {
            shape.strokeBorder(isSelected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(isSelected ? 0.07 : 0), radius: 3, y: 1)
        .onHover { hovering = $0 }
    }
}

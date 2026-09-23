import SwiftUI

/// Shared typography and contrast for standalone tabs and paired segments.
struct DrawerTabAppearance {
    let colorScheme: ColorScheme

    var inactiveText: Color { .primary.opacity(colorScheme == .dark ? 0.88 : 0.8) }
    var close: Color { .primary.opacity(0.6) }

    func fill(selected: Bool, hovering: Bool) -> Color {
        if selected {
            return colorScheme == .dark
                ? Color(red: 0.208, green: 0.267, blue: 0.329)
                : Color(red: 0.86, green: 0.91, blue: 0.97)
        }
        return .primary.opacity(hovering ? 0.09 : 0.045)
    }

    func border(selected: Bool) -> Color {
        selected ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1)
    }
}

struct DrawerTabLabel: View {
    let tab: DrawerTab
    let emphasized: Bool
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.symbol)
                .font(.system(size: 13, weight: .regular))
                .opacity(0.85)
            Text(tab.title)
                .font(.system(size: 14, weight: emphasized ? .semibold : .medium))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: 240, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(selected ? Color.primary : DrawerTabAppearance(colorScheme: colorScheme).inactiveText)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
    }
}

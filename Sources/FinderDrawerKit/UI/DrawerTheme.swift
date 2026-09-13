import AppKit
import SwiftUI

enum DrawerTheme {
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    static let shellFill = Color.accentColor.opacity(0.12)
    static let shell = Color.accentColor
    static let text = Color.primary
    static let muted = Color.secondary
}

/// Native Liquid Glass for controls; older systems use vibrancy and an edge.
/// File rows retain an opaque surface so names stay legible over any desktop.
private struct DrawerGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var interactive: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: RoundedRectangle(cornerRadius: 12))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.16)))
        }
    }
}

extension View {
    func drawerGlass(interactive: Bool = false) -> some View {
        modifier(DrawerGlass(interactive: interactive))
    }
}

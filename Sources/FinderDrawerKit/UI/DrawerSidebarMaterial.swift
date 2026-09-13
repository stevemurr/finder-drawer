import AppKit
import SwiftUI

/// Samples the desktop behind the window, rather than blurring the app's gray backing.
struct DrawerSidebarMaterial: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            SidebarVibrancy()
                .overlay(Color.white.opacity(colorScheme == .dark ? 0.025 : 0.46)
                    .allowsHitTesting(false))
                .overlay {
                    LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.07 : 0.22),
                                            .white.opacity(0.015), .accentColor.opacity(0.025)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .allowsHitTesting(false)
                }
        }
    }
}

private struct SidebarVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

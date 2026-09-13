import AppKit
import SwiftUI

/// A non-interactive marker lets the window resolve native table/terminal clicks
/// to a pane before dispatching commands, without intercepting their input.
struct DrawerPaneMarker: NSViewRepresentable {
    let pane: DrawerWorkspace.Pane
    func makeNSView(context: Context) -> PaneMarkerView { PaneMarkerView(pane: pane) }
    func updateNSView(_ view: PaneMarkerView, context: Context) { view.pane = pane }
}

final class PaneMarkerView: NSView {
    var pane: DrawerWorkspace.Pane
    init(pane: DrawerWorkspace.Pane) { self.pane = pane; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Use init(pane:)") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    static func pane(at point: NSPoint, in view: NSView) -> DrawerWorkspace.Pane? {
        if let marker = view as? PaneMarkerView, marker.convert(marker.bounds, to: nil).contains(point) {
            return marker.pane
        }
        for child in view.subviews {
            if let pane = pane(at: point, in: child) { return pane }
        }
        return nil
    }
}

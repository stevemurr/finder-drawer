import AppKit
import SwiftUI

/// How wide the deck draws a vertical scroller, in points.
///
/// **Measured against `NSScroller.scrollerWidth(for:scrollerStyle:)` on this
/// SDK**, because the sizes are not what they are usually assumed to be:
///
///     legacy  .regular  17      overlay .regular  17
///     legacy  .small    13      overlay .small    15
///                               overlay .mini     15
///
/// So a stock scroller forced to `.overlay` is still 17 — `controlSize` is the
/// only stock lever and under overlay it bottoms out at 15. Anything narrower
/// needs `DrawerThinScroller`, which is the only reason that class exists.
enum DrawerScrollerMetrics {
    static let thickness: CGFloat = 9
}

/// A scroller narrower than any control size AppKit offers, that is still
/// allowed to be an overlay.
///
/// **`isCompatibleWithOverlayScrollers` is load-bearing, not decoration.**
/// `NSScrollView` asks the scroller's *class* whether it can cope with overlay
/// metrics before it honours `scrollerStyle = .overlay`, and `NSScroller`
/// answers `false` for every subclass by default. Without the override the
/// assignment appears to succeed and then silently loses: `scrollerStyle` reads
/// back as `.legacy`, the clip view narrows by the scroller's width, and the bar
/// is back to taking layout space and never fading. The width override alone
/// does nothing.
final class DrawerThinScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        DrawerScrollerMetrics.thickness
    }
}

extension NSScrollView {
    /// Makes this scroll view's vertical scroller thin, and overlay-styled so it
    /// fades out when scrolling stops.
    ///
    /// **Deliberately does not touch `hasVerticalScroller`.** Whether there is a
    /// scroller at all belongs to the call site: SwiftUI writes that property
    /// from `.scrollIndicators(_:)`, and forcing it here would put a scrollbar
    /// back onto the stage rail and the workspace shelf, which ask for `.never`
    /// on purpose. This decides only how a scroller looks once something else
    /// has decided to show one.
    ///
    /// **Forcing `.overlay` overrides a system preference, and that is the
    /// point.** Under "Show scroll bars: Always" — and under "Automatically"
    /// with a mouse attached — `NSScroller.preferredScrollerStyle` is `.legacy`,
    /// which draws a permanent 17 pt bar *and* takes those 17 points out of the
    /// content's width. On the transcript that is roughly three columns of
    /// monospace permanently spent on a control that is idle almost all of the
    /// time, which is the same argument `workspaceShelfGutter(canvasWidth:)` is
    /// written on. The browser uses the same rule in every column.
    ///
    /// Idempotent, so it is safe to call from `updateNSView` and from a
    /// preference-change notification.
    func applyDrawerThinOverlayScroller() {
        if !(verticalScroller is DrawerThinScroller) {
            verticalScroller = DrawerThinScroller()
        }
        autohidesScrollers = true
        scrollerStyle = .overlay
    }
}

extension NSView {
    /// Applies the treatment to every `NSScrollView` *inside* this view.
    ///
    /// **For the views that own their scroller rather than sit in one.**
    /// `PDFView` builds and manages its own scroll view as a private subview,
    /// so `enclosingScrollView` from a child never reaches it and the SwiftUI
    /// tuner cannot help. Walking down is the only handle, and it is bounded:
    /// this is called once at set-up on a view whose subtree is a handful of
    /// nodes deep.
    func applyDrawerThinOverlayScrollerToDescendants() {
        if let scrollView = self as? NSScrollView {
            scrollView.applyDrawerThinOverlayScroller()
        }
        for subview in subviews {
            subview.applyDrawerThinOverlayScrollerToDescendants()
        }
    }
}

/// Applies the deck's scroller treatment to the `NSScrollView` behind a SwiftUI
/// `ScrollView`. SwiftUI has no scroller-width or scroller-style API on macOS,
/// so reaching the backing scroll view is the only route.
///
/// **Must go inside the scroll view's content, never on the `ScrollView`
/// itself.** SwiftUI hosts a representable's `NSView` inside whatever container
/// holds it: placed in the content it lands under the clip view's document view,
/// where `enclosingScrollView` resolves; applied as a `.background` on the
/// `ScrollView` it lands *beside* the scroll view in the hosting view and
/// resolves to nil.
///
/// Zero-sized, so it draws nothing, measures nothing and cannot take a click.
struct DrawerThinOverlayScrollers: View {
    var body: some View {
        ThinScrollerTuner()
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

private struct ThinScrollerTuner: NSViewRepresentable {
    func makeNSView(context: Context) -> ThinScrollerTunerView {
        ThinScrollerTunerView()
    }

    func updateNSView(_ view: ThinScrollerTunerView, context: Context) {
        // SwiftUI rewrites the backing scroll view's scroller configuration on
        // its own updates; re-applying here keeps the treatment across them.
        view.apply()
    }
}

private final class ThinScrollerTunerView: NSView {
    private var styleObserver: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
        guard styleObserver == nil else { return }
        // AppKit re-reads `preferredScrollerStyle` when the user flips "Show
        // scroll bars", or plugs in a mouse under "Automatically". The
        // per-instance override survives, but re-applying is free and also
        // covers SwiftUI rebuilding the hosting scroll view.
        styleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
    }

    func apply() {
        enclosingScrollView?.applyDrawerThinOverlayScroller()
    }

    deinit {
        if let styleObserver {
            NotificationCenter.default.removeObserver(styleObserver)
        }
    }
}

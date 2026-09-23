import AppKit
import OSLog
import SwiftTerm

/// SwiftTerm resolves NSColor into RGB values and caches its drawing colors.
/// Reassign them inside this view's appearance whenever AppKit changes it.
final class AppearanceFollowingTerminalView: LocalProcessTerminalView {
    var onFirstOutput: (() -> Void)?
    private var lightTheme: TerminalTheme = .system
    private var darkTheme: TerminalTheme = .system
    private var overlayScroller: TerminalOverlayScroller?

    private func installOverlayScroller() {
        // SwiftTerm owns a standalone NSScroller, not an NSScrollView. Hiding
        // it also releases the column width that SwiftTerm reserves for it.
        subviews.compactMap { $0 as? NSScroller }.forEach { $0.isHidden = true }
        let scroller = TerminalOverlayScroller()
        scroller.translatesAutoresizingMaskIntoConstraints = false
        scroller.target = self
        scroller.action = #selector(scrollFromOverlay(_:))
        addSubview(scroller)
        NSLayoutConstraint.activate([
            scroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroller.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            scroller.widthAnchor.constraint(equalToConstant: 9)
        ])
        overlayScroller = scroller
        updateOverlayScroller()
    }

    private func updateOverlayScroller() {
        guard let overlayScroller else { return }
        let positionChanged = overlayScroller.doubleValue != scrollPosition
        if overlayScroller.isEnabled != canScroll { overlayScroller.isEnabled = canScroll }
        if overlayScroller.doubleValue != scrollPosition { overlayScroller.doubleValue = scrollPosition }
        if overlayScroller.knobProportion != scrollThumbsize { overlayScroller.knobProportion = scrollThumbsize }
        if !canScroll { overlayScroller.conceal() }
        else if positionChanged { overlayScroller.reveal() }
    }

    @objc private func scrollFromOverlay(_ sender: NSScroller) {
        switch sender.hitPart {
        case .decrementPage: scroll(toPosition: max(0, scrollPosition - Double(scrollThumbsize)))
        case .incrementPage: scroll(toPosition: min(1, scrollPosition + Double(scrollThumbsize)))
        default: scroll(toPosition: sender.doubleValue)
        }
        updateOverlayScroller()
    }

    override func scrolled(source terminal: Terminal, yDisp: Int) {
        super.scrolled(source: terminal, yDisp: yDisp)
        updateOverlayScroller()
        // Output can scroll without moving the position (pinned to the
        // bottom); still surface the thumb. `reveal` is cheap when repeated.
        overlayScroller?.reveal()
    }

    /// With Metal on, clicks land on SwiftTerm's MTKView subview, which does
    /// not accept first responder, so AppKit's click-to-focus never reaches
    /// this view: in a split, the other terminal keeps the keyboard. The
    /// MTKView passes the click up the responder chain to here.
    override func mouseDown(with event: NSEvent) {
        if let window, window.firstResponder !== self { window.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        updateOverlayScroller()
    }

    /// SwiftTerm invalidates this view's whole frame on every scroll step,
    /// even though its `draw(_:)` returns immediately while an MTKView renders
    /// the content. Each invalidation still costs AppKit a full-size backing
    /// store pass per frame. Skip it while Metal owns the pixels; subviews
    /// (caret, find bar, overlay scroller) invalidate their own layers.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        guard isUsingMetalRenderer else {
            super.setNeedsDisplay(invalidRect)
            return
        }
        // No display pass means no `viewWillDraw`; keep the thumb in sync here.
        updateOverlayScroller()
    }

    func setThemes(light: TerminalTheme, dark: TerminalTheme) {
        guard light != lightTheme || dark != darkTheme else { return }
        lightTheme = light
        darkTheme = dark
        refreshSystemColors()
    }
    private var receivedOutput = false
    private var isReadyForAppearanceUpdates = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isReadyForAppearanceUpdates = true
        refreshSystemColors()
        installOverlayScroller()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isReadyForAppearanceUpdates = true
        refreshSystemColors()
        installOverlayScroller()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSystemColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { overlayScroller?.conceal() }
        // A retained terminal may have been offscreen during an appearance
        // change. Resolve again when it rejoins a window after a tab switch.
        if window != nil {
            refreshSystemColors()
            applyRendererPreference()
        }
    }

    private static let logger = Logger(subsystem: "com.stevemurr.finder-drawer", category: "TerminalRenderer")

    /// SwiftTerm's Metal path rebuilds only dirty rows from a glyph atlas,
    /// where the Core Graphics path re-creates attributed strings and CTLines
    /// for every dirty row on every frame.
    var prefersMetal = false {
        didSet { if prefersMetal != oldValue { applyRendererPreference() } }
    }
    /// Set once pipeline creation fails, so each tab switch does not retry a
    /// device or shader library that cannot work.
    private var metalUnavailable = false

    /// SwiftTerm requires a window before Metal can be enabled.
    private func applyRendererPreference() {
        guard window != nil else { return }
        let wantsMetal = prefersMetal && !metalUnavailable
        guard wantsMetal != isUsingMetalRenderer else { return }
        do {
            try setUseMetal(wantsMetal)
        } catch {
            metalUnavailable = true
            Self.logger.error("Metal terminal renderer unavailable; using Core Graphics: \(String(describing: error), privacy: .public)")
            try? setUseMetal(false)
        }
    }

    /// What the installed colors were resolved from. SwiftTerm's color setters
    /// never short-circuit: each one clears its attribute caches, rebuilds the
    /// 256-color palette, and invalidates the whole screen. Re-resolving only
    /// when this changes keeps a tab switch from repainting every cell.
    private struct AppliedColors: Equatable {
        let appearance: NSAppearance.Name
        let theme: TerminalTheme
    }
    private var appliedColors: AppliedColors?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        if !receivedOutput, !slice.isEmpty {
            receivedOutput = true
            onFirstOutput?()
        }
    }

    private func refreshSystemColors() {
        // AppKit can deliver appearance callbacks during superclass setup,
        // before SwiftTerm has created its terminal and drawing state.
        guard isReadyForAppearanceUpdates else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let theme = dark ? darkTheme : lightTheme
        // The full appearance name, not just light/dark: System colors differ
        // between standard and high-contrast variants.
        let applied = AppliedColors(appearance: effectiveAppearance.name, theme: theme)
        guard applied != appliedColors else { return }
        appliedColors = applied
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let palette = theme.palette {
                nativeForegroundColor = TerminalPalette.color(palette.foreground)
                nativeBackgroundColor = TerminalPalette.color(palette.background)
                selectedTextForegroundColor = TerminalPalette.color(palette.foreground)
                selectedTextBackgroundColor = TerminalPalette.color(palette.selection)
                caretColor = TerminalPalette.color(palette.cursor)
                caretTextColor = TerminalPalette.color(palette.background)
                installColors(palette.terminalColors)
            } else {
                nativeForegroundColor = .textColor
                nativeBackgroundColor = .textBackgroundColor
                selectedTextForegroundColor = .selectedTextColor
                selectedTextBackgroundColor = .selectedTextBackgroundColor
                // SwiftTerm caches the caret independently of its text colors.
                caretColor = NSColor.textColor.usingColorSpace(.sRGB) ?? .textColor
                caretTextColor = NSColor.textBackgroundColor.usingColorSpace(.sRGB)
                installColors(SwiftTerm.Color.terminalAppColors)
            }
        }
        // The setters above already schedule SwiftTerm's throttled full-screen
        // update; a separate `needsDisplay` would only add a second repaint.
    }
}

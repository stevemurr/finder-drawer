import AppKit

/// A standalone thumb with its own idle lifecycle, since SwiftTerm does not
/// embed its terminal in an NSScrollView to manage overlay fading for it.
final class TerminalOverlayScroller: NSScroller {
    private var fadeTask: Task<Void, Never>?
    private var isHovering = false
    private var isDragging = false
    private var hoverArea: NSTrackingArea?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollerStyle = .overlay
        wantsLayer = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    override func draw(_ dirtyRect: NSRect) {
        guard isEnabled, knobProportion < 1 else { return }
        let knob = rect(for: .knob)
        let thumb = NSRect(x: bounds.midX - 2.5, y: knob.minY, width: 5, height: knob.height)
        NSColor.labelColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 2.5, yRadius: 2.5).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; reveal() }
    override func mouseExited(with event: NSEvent) { isHovering = false; reveal() }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        reveal()
        super.mouseDown(with: event)
        isDragging = false
        reveal()
    }

    /// Scrolling and streaming output call this for every step. Extend one
    /// pending fade's deadline instead of cancelling and spawning a task each time.
    private var fadeDeadline = ContinuousClock.now

    func reveal() {
        guard isEnabled, knobProportion < 1 else { conceal(); return }
        if alphaValue != 1 { alphaValue = 1 }
        guard !isHovering, !isDragging else { fadeTask?.cancel(); fadeTask = nil; return }
        fadeDeadline = .now + .milliseconds(850)
        guard fadeTask == nil else { return }
        fadeTask = Task { @MainActor [weak self] in
            while let deadline = self?.fadeDeadline, deadline > .now {
                do { try await Task.sleep(until: deadline) } catch { return }
            }
            guard let self else { return }
            self.fadeTask = nil
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
                self.animator().alphaValue = 0
            }
        }
    }

    func conceal() {
        fadeTask?.cancel()
        fadeTask = nil
        if alphaValue != 0 { alphaValue = 0 }
    }

    deinit { fadeTask?.cancel() }
}

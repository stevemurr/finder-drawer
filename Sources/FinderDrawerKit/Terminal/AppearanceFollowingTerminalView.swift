import AppKit
import SwiftTerm

/// SwiftTerm resolves NSColor into RGB values and caches its drawing colors.
/// Reassign them inside this view's appearance whenever AppKit changes it.
final class AppearanceFollowingTerminalView: LocalProcessTerminalView {
    private var isReadyForAppearanceUpdates = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        isReadyForAppearanceUpdates = true
        refreshSystemColors()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isReadyForAppearanceUpdates = true
        refreshSystemColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshSystemColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A retained terminal may have been offscreen during an appearance
        // change. Resolve again when it rejoins a window after a tab switch.
        if window != nil { refreshSystemColors() }
    }

    private func refreshSystemColors() {
        // AppKit can deliver appearance callbacks during superclass setup,
        // before SwiftTerm has created its terminal and drawing state.
        guard isReadyForAppearanceUpdates else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeForegroundColor = .textColor
            nativeBackgroundColor = .textBackgroundColor
            selectedTextForegroundColor = .selectedTextColor
            selectedTextBackgroundColor = .selectedTextBackgroundColor
        }
        needsDisplay = true
    }
}

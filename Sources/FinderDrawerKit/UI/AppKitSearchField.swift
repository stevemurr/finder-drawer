import AppKit
import SwiftUI

/// SwiftUI's native TextField can fail to install its field editor when it is
/// hosted in a borderless NSPanel. Keeping the actual NSTextField in the view
/// tree gives the panel a deterministic first responder.
struct AppKitSearchField: NSViewRepresentable {
    enum Command: Equatable {
        case moveUp
        case moveDown
        case submit
        case cancel
        case moveLeft
        case moveRight
        case switchScope
    }

    @Binding var text: String
    let placeholder: String
    var focus: FocusState<Bool>.Binding
    var accessibilityIdentifier: String
    var fontSize: CGFloat = 18
    /// Called when the field actually starts editing.
    ///
    /// **`focus` cannot carry this message, and that is the bug.** A
    /// `FocusState.Binding` written from an AppKit delegate does not read back:
    /// `focus.wrappedValue` stays false, so the owning drawer surface's
    /// `.onChange(of: browserSearchFocused)` — the only thing that presented the
    /// search workspace — never fired, and clicking the toolbar field did
    /// nothing. A plain callback says the same thing without depending on a
    /// value round-tripping through a property wrapper that will not carry it.
    var onBeginEditing: (() -> Void)?
    /// Optional key routing for the owning transient surface, keeping arrows,
    /// Return, and Escape attached to the field editor that actually owns first
    /// responder.
    var onCommand: ((Command) -> Bool)?

    static func command(for selector: Selector) -> Command? {
        switch NSStringFromSelector(selector) {
        case "moveUp:": .moveUp
        case "moveDown:": .moveDown
        case "insertNewline:": .submit
        case "cancelOperation:": .cancel
        case "moveLeft:": .moveLeft
        case "moveRight:": .moveRight
        case "insertTab:", "insertBacktab:": .switchScope
        default: nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier(accessibilityIdentifier)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.accessibilityIdentifier() != accessibilityIdentifier {
            field.setAccessibilityIdentifier(accessibilityIdentifier)
        }
        guard focus.wrappedValue, field.window?.firstResponder !== field.currentEditor() else { return }
        DispatchQueue.main.async { [weak field] in
            guard let field, field.window != nil else { return }
            field.window?.makeFirstResponder(field)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AppKitSearchField

        init(parent: AppKitSearchField) { self.parent = parent }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.focus.wrappedValue = true
            parent.onBeginEditing?()
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.focus.wrappedValue = false
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard let command = AppKitSearchField.command(for: commandSelector)
            else { return false }
            return parent.onCommand?(command) ?? false
        }
    }
}

/// Finds the native field behind a rendered SwiftUI search surface and reports
/// actual AppKit responder ownership.
///
/// A successful `makeFirstResponder(_:)` request is not itself an
/// acknowledgement: text entry belongs to the window field editor. Callers
/// use `ownsFirstResponder` to stop retrying only after that editor is installed
/// and is the window's real first responder.
enum AppKitSearchFieldFocusLocator {
    static func field(
        withAccessibilityIdentifier identifier: String,
        in root: NSView
    ) -> NSTextField? {
        if let field = root as? NSTextField,
           field.accessibilityIdentifier() == identifier {
            return field
        }

        for subview in root.subviews {
            if let field = field(
                withAccessibilityIdentifier: identifier,
                in: subview
            ) {
                return field
            }
        }
        return nil
    }

    static func ownsFirstResponder(_ field: NSTextField) -> Bool {
        guard let editor = field.currentEditor() else { return false }
        return field.window?.firstResponder === editor
    }
}

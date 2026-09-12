import AppKit

/// One row: icon, name, and a disclosure chevron for folders.
///
/// Inline rename swaps the static name label for a dedicated editable
/// `NSTextField`. AppKit then owns first responder, the field editor, and
/// select-all on begin, none of which the old SwiftUI overlay handled reliably
/// inside a borderless panel.
@MainActor
final class BrowserRowCellView: NSTableCellView, NSTextFieldDelegate {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let editor = NSTextField()
    private let sizeLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    var onCommitRename: ((String) -> Void)?
    var onCancelRename: (() -> Void)?

    private var isEditing = false
    private var displayName = ""
    var editingText: String? { isEditing ? editor.stringValue : nil }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.imageScaling = .scaleProportionallyDown
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 13)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        sizeLabel.textColor = .tertiaryLabelColor
        sizeLabel.alignment = .right
        sizeLabel.lineBreakMode = .byClipping
        sizeLabel.setAccessibilityLabel("Size")
        sizeLabel.setContentHuggingPriority(.required, for: .horizontal)
        sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        sizeLabel.isHidden = true

        // A label-created NSTextField keeps an AXStaticText role even if it is
        // later made editable. Use a separate native field so inline rename is
        // announced and addressable as an actual text field.
        editor.font = .systemFont(ofSize: 13)
        editor.delegate = self
        editor.isEditable = true
        editor.isSelectable = true
        editor.isBordered = true
        editor.drawsBackground = true
        editor.backgroundColor = .textBackgroundColor
        editor.focusRingType = .none
        editor.isHidden = true

        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.symbolConfiguration = .init(pointSize: 9, weight: .semibold)

        for view in [icon, label, editor, sizeLabel, chevron] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = label
        imageView = icon

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: sizeLabel.leadingAnchor, constant: -8),

            editor.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            editor.centerYAnchor.constraint(equalTo: centerYAnchor),
            editor.trailingAnchor.constraint(equalTo: sizeLabel.leadingAnchor, constant: -8),

            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            sizeLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with entry: DirectoryEntry, showsItemSize: Bool = false) {
        displayName = entry.displayName
        icon.image = NSWorkspace.shared.icon(forFile: entry.url.path)
        label.stringValue = entry.displayName
        label.toolTip = entry.displayName
        editor.toolTip = entry.displayName
        toolTip = entry.url.path
        if showsItemSize {
            let formattedSize = entry.fileSize.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            } ?? "—"
            sizeLabel.stringValue = formattedSize
            sizeLabel.toolTip = "Size: \(formattedSize)"
            sizeLabel.setAccessibilityIdentifier("browser-item-size-\(entry.displayName)")
            sizeLabel.isHidden = false
        } else {
            sizeLabel.stringValue = ""
            sizeLabel.toolTip = nil
            sizeLabel.setAccessibilityIdentifier(nil)
            sizeLabel.isHidden = true
        }
        chevron.isHidden = !entry.isDirectory
        setAccessibilityIdentifier("browser-item-\(entry.displayName)")
        label.setAccessibilityIdentifier("browser-item-\(entry.displayName)")
        if !isEditing { endEditing() }
    }

    /// Mirrors the enclosing NSTableRowView's selected state onto the
    /// identifier-bearing static text. That gives VoiceOver and XCUITest a
    /// selected trait on the same element that announces the filename.
    func setSelectionAccessibility(_ selected: Bool) {
        setAccessibilitySelected(selected)
        label.setAccessibilitySelected(selected)
        editor.setAccessibilitySelected(selected)
    }

    func beginEditing(initialValue: String) {
        guard !isEditing else { return }
        isEditing = true
        editor.stringValue = initialValue
        editor.setAccessibilityIdentifier("rename-field")
        label.isHidden = true
        editor.isHidden = false
        window?.makeFirstResponder(editor)
        editor.currentEditor()?.selectAll(nil)
    }

    /// Ends presentation without committing or cancelling the model.
    ///
    /// Model-driven cancellation (panel hide, reroot, or a newer rename
    /// session) must dismantle a stale field without letting responder loss
    /// invoke `controlTextDidEndEditing` and resurrect the old operation.
    /// Returns whether this cell owned first responder so the coordinator can
    /// hand keyboard navigation back to its table.
    @discardableResult
    func stopEditingFromModel() -> Bool {
        guard isEditing else { return false }
        let fieldEditor = editor.currentEditor()
        let firstResponder = window?.firstResponder
        let ownedFirstResponder = firstResponder === editor || firstResponder === fieldEditor
        endEditing()
        return ownedFirstResponder
    }

    private func endEditing() {
        isEditing = false
        editor.isHidden = true
        editor.setAccessibilityIdentifier(nil)
        label.isHidden = false
        label.stringValue = displayName
        label.setAccessibilityIdentifier("browser-item-\(displayName)")
    }

    // MARK: - NSTextFieldDelegate

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy selector: Selector
    ) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let value = editor.stringValue
            endEditing()
            onCommitRename?(value)
            focusEnclosingTable()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            onCancelRename?()
            focusEnclosingTable()
            return true
        default:
            return false
        }
    }

    /// Clicking away from a rename in progress commits it, matching Finder.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard isEditing else { return }
        let value = editor.stringValue
        endEditing()
        onCommitRename?(value)
    }

    /// Explicit keyboard commit/cancel consumes AppKit's default command, so
    /// it must also complete the normal responder transition. Click-away
    /// commits arrive through `controlTextDidEndEditing` and intentionally do
    /// not call this, preserving the control the user clicked.
    private func focusEnclosingTable() {
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView {
                table.window?.makeFirstResponder(table)
                return
            }
            ancestor = view.superview
        }
    }
}

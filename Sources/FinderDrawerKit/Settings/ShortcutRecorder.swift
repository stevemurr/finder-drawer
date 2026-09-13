import AppKit
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let preferences: BrowserPreferences

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.preferences = preferences
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(RecorderButton.startRecording)
        button.setAccessibilityLabel("Record global shortcut")
        return button
    }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.title = preferences.isRecordingShortcut ? "Press shortcut…" : preferences.shortcut.label
    }
    static func dismantleNSView(_ button: RecorderButton, coordinator: ()) { button.finishRecording() }
}

final class RecorderButton: NSButton {
    var preferences: BrowserPreferences!
    override var acceptsFirstResponder: Bool { true }

    @objc func startRecording() {
        preferences.shortcutError = nil
        window?.makeFirstResponder(self)
        preferences.isRecordingShortcut = true
    }
    func finishRecording() { preferences?.isRecordingShortcut = false }
    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard preferences.isRecordingShortcut else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard preferences.isRecordingShortcut else { super.keyDown(with: event); return }
        if event.keyCode == 53 { finishRecording(); return }
        guard let shortcut = DrawerShortcut(event: event) else {
            preferences.shortcutError = "Include Control, Option, or Command with your key."
            return
        }
        preferences.shortcut = shortcut
        finishRecording()
    }
}

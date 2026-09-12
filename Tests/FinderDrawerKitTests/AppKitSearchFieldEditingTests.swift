import AppKit
@testable import FinderDrawerKit
import XCTest

/// **When does an `NSTextField` say it began editing?**
///
/// This exists to settle one factual question that
/// `testToolbarSearchFieldRaisesTheSearchWorkspace` has been failing on since
/// it was written, across four recorded VM runs with the same message every
/// time. `docs/open-issues.md` item 1 calls it undiagnosed and `0bdc92b`'s
/// commit body narrows it to "the remaining question is only which event should
/// call it" — but neither says what AppKit actually does, and every proposed
/// fix has been an argument about that rather than a measurement of it.
///
/// The two candidate signals, and why the answer decides the design:
///
/// - `controlTextDidBeginEditing` — what the field uses today. If it fires only
///   on the first *change*, then clicking a search field can never raise
///   anything, and the UI test is asserting behaviour the app does not have.
/// - `becomeFirstResponder` — tried and reverted. `0bdc92b` records the cost:
///   the browser's toolbar field acquires first responder at *launch*, so the
///   search overlay covered the browser in every test that expected it, and
///   2 failures became 26.
///
/// Nothing here touches Topside's own types. The claim is about AppKit, so the
/// test is about AppKit — a test that ran our coordinator would be measuring
/// our wiring and calling it a platform fact.
@MainActor
final class AppKitSearchFieldEditingTests: XCTestCase {
    /// Counts the delegate callbacks a real field editor produces.
    private final class Recorder: NSObject, NSTextFieldDelegate {
        var beganEditing = 0
        var changed = 0

        func controlTextDidBeginEditing(_: Notification) { beganEditing += 1 }
        func controlTextDidChange(_: Notification) { changed += 1 }
    }

    private var window: NSWindow!
    private var field: NSTextField!
    private var recorder: Recorder!

    override func setUp() {
        super.setUp()
        recorder = Recorder()
        field = NSTextField()
        field.delegate = recorder
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // **Both lines are load-bearing and both were learned by crashing.** A
        // programmatically created NSWindow releases itself on `close()`, which
        // over-releases what ARC is also holding; and a window that was never
        // ordered in does not install a field editor, so `makeFirstResponder`
        // silently does nothing and the measurement below is vacuous.
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        window.contentView?.addSubview(field)
        field.frame = NSRect(x: 8, y: 8, width: 300, height: 24)
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        field = nil
        recorder = nil
        super.tearDown()
    }

    /// **The measurement.** Focus alone does not begin editing.
    ///
    /// This is why clicking the toolbar field raises nothing: `XCUIElement.click()`
    /// on a text field moves first responder and installs the field editor, and
    /// that is all it does. `controlTextDidBeginEditing` is not a focus
    /// notification, and reading its name as one is the whole of the bug.
    func testFocusAloneDoesNotBeginEditing() {
        window.makeFirstResponder(field)

        XCTAssertTrue(
            window.firstResponder === field.currentEditor(),
            "the field editor was never installed, so this test measured nothing"
        )
        XCTAssertEqual(
            recorder.beganEditing,
            0,
            "controlTextDidBeginEditing fired on focus — if this ever becomes "
                + "true, the toolbar search field can raise the workspace on a "
                + "click and the UI test is right as written"
        )
    }

    /// And the partner, so the test above is not satisfied by a delegate that
    /// is simply never called: the first *edit* is what begins editing.
    func testTheFirstEditIsWhatBeginsEditing() {
        window.makeFirstResponder(field)
        field.currentEditor()?.insertText("q")

        XCTAssertEqual(recorder.beganEditing, 1)
        XCTAssertEqual(recorder.changed, 1)
    }

    /// The launch-time acquisition `0bdc92b` was reverted over, stated as a
    /// fact rather than as commit prose: a field can hold first responder with
    /// no person having touched it, which is exactly why focus is not a usable
    /// proxy for intent here.
    func testAFieldCanHoldFirstResponderWithoutAnyoneHavingEdited() {
        window.makeFirstResponder(field)

        XCTAssertTrue(window.firstResponder === field.currentEditor())
        XCTAssertEqual(recorder.beganEditing, 0)
        XCTAssertTrue(field.stringValue.isEmpty)
    }

    func testFocusLocatorAcknowledgesOnlyTheInstalledFieldEditor() throws {
        field.setAccessibilityIdentifier("focused-search-field")

        let located = try XCTUnwrap(AppKitSearchFieldFocusLocator.field(
            withAccessibilityIdentifier: "focused-search-field",
            in: try XCTUnwrap(window.contentView)
        ))
        XCTAssertTrue(located === field)
        XCTAssertFalse(AppKitSearchFieldFocusLocator.ownsFirstResponder(field))

        XCTAssertTrue(window.makeFirstResponder(field))

        XCTAssertTrue(AppKitSearchFieldFocusLocator.ownsFirstResponder(field))
        XCTAssertTrue(window.firstResponder === field.currentEditor())
    }

    func testFlightDeckFieldCommandsMapOnlyNavigationAndSubmissionSelectors() {
        XCTAssertEqual(
            AppKitSearchField.command(for: Selector(("moveUp:"))),
            .moveUp
        )
        XCTAssertEqual(
            AppKitSearchField.command(for: Selector(("moveDown:"))),
            .moveDown
        )
        XCTAssertEqual(
            AppKitSearchField.command(for: Selector(("insertNewline:"))),
            .submit
        )
        XCTAssertEqual(
            AppKitSearchField.command(for: Selector(("cancelOperation:"))),
            .cancel
        )
        XCTAssertEqual(
            AppKitSearchField.command(for: Selector(("moveLeft:"))),
            .moveLeft
        )
        XCTAssertEqual(
            AppKitSearchField.command(for: Selector(("moveRight:"))),
            .moveRight
        )
        XCTAssertNil(AppKitSearchField.command(for: Selector(("deleteBackward:"))))
    }
}

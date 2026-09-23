import AppKit
import XCTest
@testable import FinderDrawerKit

@MainActor
final class TerminalScrollerTests: XCTestCase {
    func testEmptyTerminalHasNoVisibleTrack() {
        let terminal = AppearanceFollowingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let scrollers = terminal.subviews.compactMap { $0 as? NSScroller }
        XCTAssertEqual(scrollers.count, 2)
        XCTAssertTrue(scrollers.filter { !($0 is TerminalOverlayScroller) }.allSatisfy(\.isHidden))
        let overlay = scrollers.first { $0 is TerminalOverlayScroller }
        XCTAssertEqual(overlay?.alphaValue, 0)
        XCTAssertEqual(overlay?.isEnabled, false)
    }

    func testScrollableThumbAppearsThenFades() async throws {
        let scroller = TerminalOverlayScroller(frame: NSRect(x: 0, y: 0, width: 9, height: 400))
        scroller.isEnabled = true
        scroller.knobProportion = 0.25
        XCTAssertGreaterThan(scroller.rect(for: .knob).height, 0)
        scroller.reveal()
        XCTAssertEqual(scroller.alphaValue, 1)
        try await Task.sleep(for: .milliseconds(1400))
        XCTAssertEqual(scroller.alphaValue, 0, accuracy: 0.01)
        scroller.isEnabled = false
        scroller.reveal()
        XCTAssertEqual(scroller.alphaValue, 0)
    }

    func testThumbTracksTerminalScrollback() throws {
        let terminal = AppearanceFollowingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        terminal.feed(text: (0..<200).map { "Line \($0)\r\n" }.joined())
        terminal.scroll(toPosition: 0.4)
        terminal.viewWillDraw()
        let overlay = try XCTUnwrap(terminal.subviews.compactMap { $0 as? TerminalOverlayScroller }.first)
        XCTAssertTrue(overlay.isEnabled)
        XCTAssertEqual(overlay.doubleValue, terminal.scrollPosition, accuracy: 0.001)
        XCTAssertEqual(overlay.knobProportion, terminal.scrollThumbsize, accuracy: 0.001)
        XCTAssertEqual(overlay.alphaValue, 1)
        terminal.feed(text: "\u{1b}[?1049h")
        terminal.viewWillDraw()
        XCTAssertFalse(overlay.isEnabled)
        XCTAssertEqual(overlay.alphaValue, 0)
    }
}

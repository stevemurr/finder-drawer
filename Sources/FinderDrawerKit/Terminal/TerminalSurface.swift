import AppKit
import SwiftUI
import SwiftTerm

struct TerminalSurface: View {
    let session: TerminalSession
    var body: some View {
        VStack(spacing: 0) {
            TerminalRepresentable(session: session)
            if session.hasExited {
                HStack {
                    Image(systemName: "terminal")
                    Text("Shell exited" + (session.exitCode.map { " (\($0))" } ?? ""))
                    Spacer()
                    Text("⌘W Close tab · ⌘T New terminal")
                }.font(.caption).foregroundStyle(.secondary).padding(10)
            }
        }
    }
}

private struct TerminalRepresentable: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> TerminalHostView {
        TerminalHostView(session: session) { session.startIfNeeded() }
    }
    func updateNSView(_ view: TerminalHostView, context: Context) {
        view.needsLayout = true
    }
    // The session owns its terminal across tab switches; only closing the tab stops it.
}

/// SwiftUI can create and measure a representable before it is mounted, and
/// can discard it before the next main-queue turn. Start from actual AppKit
/// attachment/layout, then recheck those conditions when the queued work runs.
final class TerminalHostView: NSView {
    private let session: TerminalSession
    private let start: () -> Void
    private var startupScheduled = false

    init(session: TerminalSession, start: @escaping () -> Void) {
        self.session = session
        self.start = start
        super.init(frame: .zero)
        // SwiftUI also creates throwaway hosts to measure alternate layouts.
        // Never reparent the session's retained terminal during creation:
        // a discarded measuring host would steal it from the visible pane.
        _ = session.makeView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachTerminalIfMounted()
        needsLayout = true
        scheduleStartupIfReady()
    }

    override func layout() {
        super.layout()
        attachTerminalIfMounted()
        guard let terminal = session.terminalView, terminal.superview === self,
              bounds.width >= 80, bounds.height >= 32 else { return }
        // SwiftTerm's setFrameSize recomputes the grid and repaints every
        // cell; SwiftUI requests layout on unrelated updates.
        if terminal.frame != bounds { terminal.frame = bounds }
        scheduleStartupIfReady()
    }

    private func attachTerminalIfMounted() {
        guard window != nil else { return }
        let terminal = session.makeView()
        guard terminal.superview !== self else { return }
        terminal.removeFromSuperview()
        // Retain the last valid grid until this host receives a usable size.
        terminal.autoresizingMask = []
        addSubview(terminal)
    }

    private var isReady: Bool {
        guard let terminal = session.terminalView else { return false }
        return window != nil && terminal.superview === self &&
            bounds.width >= 80 && bounds.height >= 32 && terminal.frame == bounds
    }

    private func scheduleStartupIfReady() {
        guard !session.hasStarted, !session.isClosed, !startupScheduled, isReady else { return }
        startupScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.startupScheduled = false
            guard self.isReady, !self.session.isClosed, !self.session.hasStarted else { return }
            self.start()
        }
    }
}

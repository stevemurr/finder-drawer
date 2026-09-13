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
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let terminal = session.makeView()
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        DispatchQueue.main.async { session.startIfNeeded() }
        return container
    }
    func updateNSView(_ view: NSView, context: Context) {}
    // The session owns its terminal across tab switches; only closing the tab stops it.
}

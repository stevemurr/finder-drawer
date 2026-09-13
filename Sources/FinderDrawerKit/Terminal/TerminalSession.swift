import AppKit
import Observation
import SwiftTerm

@MainActor
@Observable
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let id = UUID()
    private(set) var directory: URL
    private(set) var title = "Terminal"
    private(set) var hasStarted = false
    private(set) var isClosed = false
    private(set) var hasExited = false
    private(set) var exitCode: Int32?
    @ObservationIgnored private(set) var terminalView: LocalProcessTerminalView?

    init(directory: URL) { self.directory = directory.standardizedFileURL }

    func makeView() -> LocalProcessTerminalView {
        if let terminalView { return terminalView }
        let view = AppearanceFollowingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.processDelegate = self
        view.setAccessibilityIdentifier("terminal-\(id)")
        terminalView = view
        return view
    }

    func startIfNeeded(executable override: String? = nil, arguments: [String] = ["-l"]) {
        guard !hasStarted, !isClosed else { return }
        hasStarted = true
        let view = makeView()
        let shell = ProcessInfo.processInfo.environment["SHELL"]
            ?? getpwuid(getuid()).flatMap { $0.pointee.pw_shell }.map { String(cString: $0) } ?? "/bin/zsh"
        let executable = override ?? (FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh")
        // currentDirectory is passed to the PTY launcher, never interpolated into shell input.
        view.startProcess(executable: executable, args: arguments, currentDirectory: directory.path)
        if !view.process.running { hasExited = true; exitCode = -1 }
    }

    func stop() {
        isClosed = true
        guard let view = terminalView, view.process.running else { return }
        // Hang up this terminal's foreground job and shell before closing its PTY.
        let foreground = tcgetpgrp(view.process.childfd)
        if foreground > 0, foreground != getpgrp() { kill(-foreground, SIGHUP) }
        let shell = view.process.shellPid
        if shell > 0 { kill(shell, SIGHUP) }
        view.terminate()
        hasExited = true
        // SwiftTerm cancels its exit monitor on explicit termination. Reap the
        // child ourselves so repeated open/close cycles cannot leave zombies.
        if shell > 0 {
            Task.detached(priority: .utility) {
                var status: Int32 = 0
                for _ in 0..<50 {
                    let result = waitpid(shell, &status, WNOHANG)
                    if result == shell || (result == -1 && errno == ECHILD) { return }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                // Still our unreaped child: finish a shell that ignored hangup.
                if waitpid(shell, &status, WNOHANG) == 0 {
                    kill(shell, SIGKILL)
                    while waitpid(shell, &status, 0) == -1 && errno == EINTR {}
                }
            }
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        self.title = title.isEmpty ? "Terminal" : String(title.prefix(100))
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL,
              url.host == nil || url.host == "" || url.host == "localhost" || url.host == Host.current().name else { return }
        self.directory = url.standardizedFileURL
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        hasExited = true
        self.exitCode = exitCode
    }
}

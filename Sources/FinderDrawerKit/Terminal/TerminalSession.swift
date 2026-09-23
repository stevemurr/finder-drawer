import AppKit
import Observation
import OSLog
import SwiftTerm

@MainActor
@Observable
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    private static let logger = Logger(subsystem: "com.stevemurr.finder-drawer", category: "TerminalStartup")
    let id = UUID()
    private(set) var hasReceivedOutput = false
    @ObservationIgnored private var outputWatchdog: Task<Void, Never>?
    private(set) var directory: URL
    private(set) var title = "Terminal"
    private(set) var hasStarted = false
    private(set) var isClosed = false
    private(set) var hasExited = false
    private(set) var exitCode: Int32?
    @ObservationIgnored private(set) var terminalView: LocalProcessTerminalView?

    private var lightTheme: TerminalTheme = .system
    private var darkTheme: TerminalTheme = .system
    private var usesGPU = false

    init(directory: URL) { self.directory = directory.standardizedFileURL }

    func setThemes(light: TerminalTheme, dark: TerminalTheme) {
        lightTheme = light
        darkTheme = dark
        (terminalView as? AppearanceFollowingTerminalView)?.setThemes(light: light, dark: dark)
    }

    func setUsesGPU(_ enabled: Bool) {
        usesGPU = enabled
        (terminalView as? AppearanceFollowingTerminalView)?.prefersMetal = enabled
    }

    func makeView() -> LocalProcessTerminalView {
        if let terminalView { return terminalView }
        let view = AppearanceFollowingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 450))
        // eza and Starship use private-use Nerd Font glyphs. The system font's
        // automatic fallback does not reliably resolve those icon code points.
        view.font = NSFont(name: "FiraCodeNF-Reg", size: 13)
            ?? NSFont(name: "FiraCodeNFM-Reg", size: 13)
            ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.setThemes(light: lightTheme, dark: darkTheme)
        view.prefersMetal = usesGPU
        view.processDelegate = self
        view.onFirstOutput = { [weak self, weak view] in
            guard let self else { return }
            self.hasReceivedOutput = true
            self.outputWatchdog?.cancel()
            // Never log shell output, environment values, or directory paths.
            Self.logger.info("Terminal \(self.id.uuidString, privacy: .public) received first output; mounted=\(view?.window != nil)")
        }
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
        let size = view.getWindowSize()
        Self.logger.info("Terminal \(self.id.uuidString, privacy: .public) launching; mounted=\(view.window != nil) grid=\(size.ws_col)x\(size.ws_row)")
        // currentDirectory is passed to the PTY launcher, never interpolated into shell input.
        view.startProcess(executable: executable, args: arguments, currentDirectory: directory.path)
        if !view.process.running {
            hasExited = true; exitCode = -1
            Self.logger.error("Terminal \(self.id.uuidString, privacy: .public) failed to create a shell process")
        } else {
            Self.logger.info("Terminal \(self.id.uuidString, privacy: .public) shell started; pid=\(view.process.shellPid)")
            outputWatchdog = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, !self.isClosed, !self.hasExited, !self.hasReceivedOutput else { return }
                Self.logger.warning("Terminal \(self.id.uuidString, privacy: .public) has no output after 5 seconds; running=\(self.terminalView?.process.running == true) mounted=\(self.terminalView?.window != nil)")
            }
        }
    }

    func stop() {
        isClosed = true
        outputWatchdog?.cancel()
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
        // Shells and TUIs can rewrite the title on every prompt or redraw; an
        // unchanged value must not invalidate the tab strip.
        let title = title.isEmpty ? "Terminal" : String(title.prefix(100))
        if self.title != title { self.title = title }
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, let url = URL(string: directory), url.isFileURL,
              Self.isLocalHost(url.host) else { return }
        let standardized = url.standardizedFileURL
        if self.directory != standardized { self.directory = standardized }
    }

    /// OSC 7 arrives on every prompt and normally names this Mac. Resolve the
    /// local name once: `Host.current()` performs blocking name resolution,
    /// which stalled the main thread at each prompt.
    private static let localHostNames: Set<String> = {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count) == 0 else { return ["localhost"] }
        let name = String(cString: buffer).lowercased()
        let short = name.hasSuffix(".local") ? String(name.dropLast(".local".count)) : name
        return ["localhost", name, short, short + ".local"]
    }()

    static func isLocalHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return true }
        return localHostNames.contains(host.lowercased())
    }
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        outputWatchdog?.cancel()
        Self.logger.info("Terminal \(self.id.uuidString, privacy: .public) exited; status=\(exitCode ?? -1) receivedOutput=\(self.hasReceivedOutput)")
        hasExited = true
        self.exitCode = exitCode
    }
}

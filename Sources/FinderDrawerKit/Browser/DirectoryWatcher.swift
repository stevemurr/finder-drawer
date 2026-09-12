import Foundation

/// Watches a single directory for child add/remove/rename and reports changes
/// on the main actor.
///
/// A `DispatchSource` on the directory's own file descriptor is enough here —
/// the browser only ever has a handful of columns open at once, so the extra
/// machinery of an `FSEventStream` (and its coalescing latency) buys nothing.
@MainActor
final class DirectoryWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var pendingNotification: Task<Void, Never>?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit {
        // `source`'s cancel handler owns closing the descriptor; cancelling here
        // is safe from any thread and avoids a double close.
        source?.cancel()
    }

    private func start() {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        self.descriptor = descriptor

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleNotification()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    /// Bursts are common — an unarchive or a `git checkout` can fire dozens of
    /// events — so collapse them into one reload.
    private func scheduleNotification() {
        pendingNotification?.cancel()
        pendingNotification = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.onChange()
        }
    }

    func stop() {
        pendingNotification?.cancel()
        pendingNotification = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }
}

/// Watches one file across both in-place writes and atomic replacements.
///
/// A vnode source attached only to the parent directory misses ordinary writes
/// to an existing child. A source attached only to the file follows its old
/// inode after an atomic save. The file source catches content writes and is
/// reopened after each event; while the file is absent, a directory watcher
/// notices its recreation.
@MainActor
final class FileChangeWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var fileSource: DispatchSourceFileSystemObject?
    private var directoryWatcher: DirectoryWatcher?
    private var pendingNotification: Task<Void, Never>?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        installFileSource()
    }

    deinit {
        fileSource?.cancel()
    }

    private func installFileSource() {
        fileSource?.cancel()
        fileSource = nil

        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            installDirectoryWatcherIfNeeded()
            return
        }
        directoryWatcher?.stop()
        directoryWatcher = nil
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            // Metadata-only changes are deliberately excluded. PDFKit emits
            // NOTE_ATTRIB merely from opening a PDF; treating that read-side
            // event as a content mutation creates a reload → attribute event
            // → reload feedback loop. Writes and lifecycle events still cover
            // in-place edits, truncation, removal, and atomic replacement.
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleNotification()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        fileSource = source
    }

    /// The parent is only needed while the file is absent. Keeping both vnode
    /// sources active for a present file would report an atomic save twice.
    private func installDirectoryWatcherIfNeeded() {
        guard directoryWatcher == nil else { return }
        directoryWatcher = DirectoryWatcher(
            url: url.deletingLastPathComponent()
        ) { [weak self] in
            self?.scheduleNotification()
        }
    }

    private func scheduleNotification() {
        pendingNotification?.cancel()
        pendingNotification = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.installFileSource()
            self.onChange()
        }
    }

    func stop() {
        pendingNotification?.cancel()
        pendingNotification = nil
        directoryWatcher?.stop()
        directoryWatcher = nil
        fileSource?.cancel()
        fileSource = nil
    }
}

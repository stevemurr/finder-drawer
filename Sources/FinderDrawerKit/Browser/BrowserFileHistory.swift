import Foundation
import Observation

/// Undo uses reversible relocations. Copied items go to Trash, so even edits
/// made after a copy are preserved. Redo restores those exact items.
@MainActor
@Observable
final class BrowserFileHistory {
    struct Step {
        let source: URL
        /// nil means send to Trash; a URL means restore/move to that exact path.
        let destination: URL?
        private let identity: String?

        init(source: URL, destination: URL?) {
            self.source = source
            self.destination = destination
            identity = Self.fileIdentity(source)
        }
        var stillMatches: Bool { identity != nil && identity == Self.fileIdentity(source) }
        private static func fileIdentity(_ url: URL) -> String? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
            return "\(device):\(inode)"
        }
    }
    private struct Entry {
        let name: String
        var steps: [Step]
    }
    private var past: [Entry] = []
    private var future: [Entry] = []
    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }
    var undoTitle: String { past.last.map { "Undo " + $0.name } ?? "Undo" }
    var redoTitle: String { future.last.map { "Redo " + $0.name } ?? "Redo" }

    func record(_ name: String, undo steps: [Step]) {
        guard !steps.isEmpty else { return }
        past.append(Entry(name: name, steps: steps))
        future.removeAll()
    }

    func undo() throws { try apply(redo: false) }
    func redo() throws { try apply(redo: true) }

    private func apply(redo: Bool) throws {
        guard var entry = redo ? future.last : past.last else { return }
        let fm = FileManager.default
        // Preflight the entire batch. Never replace a file created after the
        // original operation, or silently resurrect a removed source.
        for step in entry.steps {
            _ = try fm.attributesOfItem(atPath: step.source.path)
            guard step.stillMatches else {
                throw BrowserFileOperationError.failed("“\(step.source.lastPathComponent)” was replaced since the original operation. It has been left unchanged.")
            }
            if let destination = step.destination,
               (try? fm.attributesOfItem(atPath: destination.path)) != nil {
                throw BrowserFileOperationError.alreadyExists(destination.lastPathComponent)
            }
        }
        var inverse: [Step] = []
        var failure: Error?
        var completedCount = 0
        for step in entry.steps {
            do {
                if let destination = step.destination {
                    try fm.moveItem(at: step.source, to: destination)
                    inverse.insert(Step(source: destination, destination: step.source), at: 0)
                } else {
                    var trashed: NSURL?
                    try fm.trashItem(at: step.source, resultingItemURL: &trashed)
                    if let trashed {
                        inverse.insert(Step(source: trashed as URL, destination: step.source), at: 0)
                    }
                }
                completedCount += 1
            } catch { failure = error; break }
        }
        // Preserve recovery for both halves if an external change interrupts a batch.
        if redo { future.removeLast() } else { past.removeLast() }
        if let failure {
            entry.steps.removeFirst(completedCount)
            if redo { future.append(entry) } else { past.append(entry) }
            if !inverse.isEmpty {
                let completed = Entry(name: entry.name, steps: inverse)
                if redo { past.append(completed) } else { future.append(completed) }
            }
            throw failure
        }
        let next = Entry(name: entry.name, steps: inverse)
        if !inverse.isEmpty {
            if redo { past.append(next) } else { future.append(next) }
        }
    }
}

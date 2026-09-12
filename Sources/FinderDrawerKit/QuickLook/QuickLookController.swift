import AppKit
import QuickLookUI

@MainActor
final class QuickLookController: NSObject {
    private(set) var currentURL: URL?

    init(currentURL: URL? = nil) {
        self.currentURL = currentURL
        super.init()
    }

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func toggle(for result: FileSearchResult?) {
        if isVisible {
            close()
            return
        }
        guard let result else { return }
        currentURL = result.url
        QLPreviewPanel.shared().makeKeyAndOrderFront(nil)
    }

    func refreshIfVisible(with result: FileSearchResult?) {
        guard let result else {
            // A directory or empty selection is an explicit request to stop
            // previewing the previously selected file.
            close()
            return
        }
        guard isVisible else { return }
        currentURL = result.url
        QLPreviewPanel.shared().reloadData()
    }

    func close() {
        currentURL = nil
        if isVisible { QLPreviewPanel.shared().orderOut(nil) }
    }
}

extension QuickLookController: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        currentURL.map { $0 as NSURL }
    }
}

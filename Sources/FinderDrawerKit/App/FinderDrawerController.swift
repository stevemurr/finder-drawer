import AppKit
import QuickLookUI
import SwiftUI

/// Standalone macOS host for the browser/search package. Retain one controller
/// for the application's lifetime; hiding the drawer keeps navigation resident.
@MainActor
public final class FinderDrawerController: NSWindowController, NSWindowDelegate {
    let workspace: DrawerWorkspace
    private var keyMonitor: Any?
    private var focusTask: Task<Void, Never>?
    private var animationGeneration = 0

    public init(
        databaseURL: URL? = nil,
        defaults: UserDefaults = .standard,
        initialFolders: [URL] = [],
        restoresFolders: Bool = true
    ) throws {
        let databaseURL = try databaseURL ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("FinderDrawer/index.sqlite3")
        workspace = try DrawerWorkspace(databaseURL: databaseURL, defaults: defaults,
                                        initialFolders: initialFolders, restoresFolders: restoresFolders)
        let panel = DrawerPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 620),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        panel.title = "Finder Drawer"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 760, height: 430)
        panel.quickLookController = workspace.quickLook
        panel.contentView = NSHostingView(rootView: DrawerRootView(workspace: workspace))
        super.init(window: panel)
        panel.delegate = self
        workspace.onHide = { [weak self] in self?.hide() }
        workspace.onRequestColumnFocus = { [weak self] in self?.focusColumns() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) == true }
            return handled ? nil : event
        }
        workspace.start()
    }

    required init?(coder: NSCoder) { fatalError("Use init(databaseURL:defaults:initialFolders:restoresFolders:)") }

    public func toggle() {
        if window?.isVisible == true { hide() } else { show() }
    }

    public func show() {
        guard let window else { return }
        animationGeneration += 1
        let wasVisible = window.isVisible
        if !wasVisible {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main
            if let screen {
                let area = screen.visibleFrame
                let size = NSSize(width: min(window.frame.width, area.width - 32),
                                  height: min(window.frame.height, area.height * 0.82))
                window.setFrame(NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height,
                                       width: size.width, height: size.height), display: false)
            }
            window.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if !wasVisible {
            let frame = window.frame
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                window.setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY + 28))
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    window.animator().alphaValue = 1
                    window.animator().setFrame(frame, display: true)
                }
            }
            workspace.index.rebuildIndex()
        } else { window.alphaValue = 1 }
        if workspace.isSearchPresented { focusSearch() } else { focusColumns() }
    }

    public func hide() {
        guard let window else { return }
        workspace.persistTabs()
        workspace.quickLook.close()
        animationGeneration += 1
        let generation = animationGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard self?.animationGeneration == generation else { return }
                window?.orderOut(nil)
                window?.alphaValue = 1
            }
        }
    }

    public func chooseFolders() { show(); workspace.chooseFolders() }
    public func search() { show(); workspace.beginSearch(); focusSearch() }

    public func shutdown() {
        focusTask?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        workspace.stop()
        window?.orderOut(nil)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }

    private func focusColumns() {
        focusTask?.cancel()
        focusTask = Task { @MainActor [weak self] in
            for _ in 0..<8 {
                guard !Task.isCancelled, let self, !workspace.isSearchPresented,
                      let window, window.isVisible, window.attachedSheet == nil,
                      let browser = workspace.browser, browser.renamingURL == nil,
                      let content = window.contentView else { return }
                if let table = BrowserColumnTableLocator.table(for: browser, columnIndex: browser.focusedColumnIndex, in: content) {
                    window.makeFirstResponder(table)
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func focusSearch() {
        focusTask?.cancel()
        guard let content = window?.contentView,
              let field = AppKitSearchFieldFocusLocator.field(withAccessibilityIdentifier: "file-search", in: content)
        else { return }
        window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil,
              NSApp.modalWindow == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let command = BrowserCommand.matching(keyCode: event.keyCode, modifiers: modifiers)
        if command == .search {
            workspace.beginSearch(); focusSearch(); return true
        }
        if let command, workspace.browser?.renamingURL == nil,
           [.newTab, .closeTab, .settings, .goToFolder].contains(command) {
            workspace.perform(command)
            return true
        }
        // Editing keeps its own arrows, Delete, Return, Escape and clipboard keys.
        if window.firstResponder is NSTextView { return false }
        if workspace.isSearchPresented {
            if modifiers.isEmpty {
                switch event.keyCode {
                case 53: workspace.dismissSearch(); return true
                case 36, 76:
                    if let result = workspace.selectedResult { workspace.reveal(result) }
                    return true
                case 49: workspace.quickLook.toggle(for: workspace.selectedResult); return true
                default: break
                }
            }
            if command == .open, let result = workspace.selectedResult { workspace.openResult(result); return true }
            // Commands targeting browser selection must not act behind search results.
            return false
        }
        guard let browser = workspace.browser, browser.renamingURL == nil else { return false }
        switch (event.keyCode, modifiers) {
        case (53, []): hide(); return true
        case (123, []): browser.focusColumn(by: -1); return true
        case (124, []): browser.focusColumn(by: 1); return true
        case (126, .command): browser.goToParent(); return true
        case (48, []): browser.focusColumn(by: 1); return true
        case (48, .shift): browser.focusColumn(by: -1); return true
        default: break
        }
        if let command { workspace.perform(command); return true }
        return false
    }
}

private final class DrawerPanel: NSPanel {
    var quickLookController: QuickLookController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLookController
        panel.delegate = quickLookController
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

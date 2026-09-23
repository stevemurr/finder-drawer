import AppKit
import QuickLookUI
import QuartzCore
import SwiftUI

/// Standalone macOS host for the browser/search package. Retain one controller
/// for the application's lifetime; hiding the drawer keeps navigation resident.
@MainActor
public final class FinderDrawerController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let workspace: DrawerWorkspace
    private var keyMonitor: Any?
    private var headerView: NSHostingView<DrawerToolbarView>?
    private static let headerIdentifier = NSToolbarItem.Identifier("drawer-header")
    private var focusTask: Task<Void, Never>?
    private var animationGeneration = 0
    private(set) var isPresented = false
    private var restingFrame: NSRect?
    private var previousApplication: NSRunningApplication?
    private var deactivationObserver: NSObjectProtocol?
    private var pendingFullScreenHide = false
    private lazy var settingsController = DrawerSettingsController(workspace: workspace)

    public var onVisibilityChange: (() -> Void)?
    public var onShortcutChange: (() -> Void)? {
        didSet { workspace.preferences.onShortcutChange = onShortcutChange }
    }
    public var isRecordingShortcut: Bool { workspace.preferences.isRecordingShortcut }
    public var shortcut: DrawerShortcut { workspace.preferences.shortcut }
    public func setShortcutError(_ message: String?) { workspace.preferences.shortcutError = message }
    public var hasVisibleWindows: Bool {
        isPresented || settingsController.window?.isVisible == true
    }

    public init(
        databaseURL: URL? = nil,
        defaults: UserDefaults = .standard,
        initialFolders: [URL] = [],
        restoresFolders: Bool = true,
        allowsSystemWideAccess: Bool = false
    ) throws {
        let databaseURL = try databaseURL ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("FinderDrawer/index.sqlite3")
        workspace = try DrawerWorkspace(databaseURL: databaseURL, defaults: defaults,
                                        initialFolders: initialFolders, restoresFolders: restoresFolders,
                                        allowsSystemWideAccess: allowsSystemWideAccess)
        let panel = DrawerWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        panel.title = "Finder Drawer"
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        // Keep the main header opaque; the sidebar background extends into its titlebar region.
        panel.backgroundColor = .windowBackgroundColor
        panel.titleVisibility = .hidden
        panel.toolbarStyle = .unifiedCompact
        panel.titlebarSeparatorStyle = .none
        panel.isReleasedWhenClosed = false
        panel.level = .normal
        panel.collectionBehavior = [.moveToActiveSpace, .managed, .fullScreenPrimary,
                                    .fullScreenAllowsTiling, .canJoinAllApplications]
        panel.animationBehavior = .none
        panel.tabbingMode = .disallowed
        panel.minSize = NSSize(width: 760, height: 430)
        panel.quickLookController = workspace.quickLook
        panel.contentView = NSHostingView(rootView: DrawerRootView(workspace: workspace))
        super.init(window: panel)
        panel.delegate = self
        headerView = NSHostingView(rootView: DrawerToolbarView(workspace: workspace))
        let toolbar = NSToolbar(identifier: "FinderDrawer.Toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        panel.toolbar = toolbar
        workspace.onShowSettings = { [weak self] in self?.showSettings() }
        settingsController.onClose = { [weak self] in self?.onVisibilityChange?() }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.workspace.preferences.hideOnDeactivate,
                      self.window?.attachedSheet == nil, NSApp.modalWindow == nil,
                      self.settingsController.window?.isVisible != true,
                      !self.workspace.quickLook.isVisible else { return }
                self.hide(restoringFocus: false)
            }
        }
        workspace.onHide = { [weak self] in self?.hide() }
        workspace.onRequestActionFocus = { [weak self] in self?.focusActions() }
        workspace.onRequestColumnFocus = { [weak self] in self?.focusColumns() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.type != .keyDown {
                MainActor.assumeIsolated {
                    if let self, event.window === self.window, !self.workspace.isPalettePresented,
                       let content = self.window?.contentView,
                       let pane = PaneMarkerView.pane(at: event.locationInWindow, in: content) {
                        self.workspace.focusPane(pane, requestFocus: false)
                    }
                }
                return event
            }
            let handled = MainActor.assumeIsolated { self?.handleKey(event) == true }
            return handled ? nil : event
        }
        workspace.start()
    }

    required init?(coder: NSCoder) { fatalError("Use init(databaseURL:defaults:initialFolders:restoresFolders:)") }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.headerIdentifier] }
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [Self.headerIdentifier] }
    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.headerIdentifier else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = headerView
        item.label = "Navigation and Actions"
        item.minSize = NSSize(width: 590, height: 40)
        item.maxSize = NSSize(width: 10000, height: 40)
        item.isBordered = false
        return item
    }

    public func toggle() {
        guard window?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        if isPresented && window?.isMiniaturized != true && window?.isKeyWindow == true {
            hide()
        } else { show() }
    }

    private var animates: Bool {
        workspace.preferences.isDrawerEnabled && workspace.preferences.animateDrawer
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public func show() {
        guard let window else { return }
        pendingFullScreenHide = false
        animationGeneration += 1
        let wasPresented = isPresented
        isPresented = true
        if !NSApp.isActive { previousApplication = NSWorkspace.shared.frontmostApplication }
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !wasPresented && !window.styleMask.contains(.fullScreen) {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main
            if let screen {
                let area = screen.visibleFrame
                let frame: NSRect
                if !workspace.preferences.isDrawerEnabled,
                   let savedFrame = restingFrame ?? workspace.preferences.lastWindowFrame {
                    frame = DrawerGeometry.restoredFrame(savedFrame, in: NSScreen.screens.map(\.visibleFrame), fallback: area)
                } else {
                    frame = DrawerGeometry.frame(in: area, preferredWidth: area.width * workspace.preferences.drawerWidth,
                                                 heightFraction: workspace.preferences.drawerHeight)
                }
                restingFrame = frame
                window.setFrame(frame, display: false)
                if animates { window.setFrameOrigin(NSPoint(x: frame.minX, y: screen.frame.maxY)) }
            }
        }
        window.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        alignToolbarWithSidebar()
        if !wasPresented {
            if let frame = restingFrame, animates, !window.styleMask.contains(.fullScreen) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.24
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().setFrame(frame, display: true)
                }
            }
            workspace.index.rebuildIndex()
        }
        onVisibilityChange?()
        if workspace.isPalettePresented { focusActions() } else { focusColumns() }
    }

    public func hide() { hide(restoringFocus: true) }

    private func hide(restoringFocus: Bool) {
        guard let window, isPresented, window.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        if window.styleMask.contains(.fullScreen) {
            pendingFullScreenHide = true
            window.toggleFullScreen(nil)
            return
        }
        focusTask?.cancel()
        workspace.dismissPalette(restoringFocus: false)
        workspace.persistTabs()
        workspace.quickLook.close()
        isPresented = false
        animationGeneration += 1
        let generation = animationGeneration
        // Preserve user resizing/tiling before the slide moves the frame offscreen.
        let frame = window.frame
        restingFrame = frame
        workspace.preferences.lastWindowFrame = frame
        if !animates || window.isMiniaturized {
            window.orderOut(nil)
            window.alphaValue = 1
            if restoringFocus, NSApp.isActive, settingsController.window?.isVisible != true {
                previousApplication?.activate(options: [])
            }
            onVisibilityChange?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animates && !window.isMiniaturized ? 0.18 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            if animates, let screen = window.screen, !window.isMiniaturized {
                window.animator().setFrameOrigin(NSPoint(x: frame.minX, y: screen.frame.maxY))
            }
            window.animator().alphaValue = 0
        } completionHandler: { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, self.animationGeneration == generation else { return }
                window?.orderOut(nil)
                window?.setFrame(frame, display: false)
                window?.alphaValue = 1
                if restoringFocus, NSApp.isActive, self.settingsController.window?.isVisible != true {
                    self.previousApplication?.activate(options: [])
                }
                self.onVisibilityChange?()
            }
        }
    }

    public func showSettings() {
        NSApp.setActivationPolicy(.regular)
        settingsController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsController.window?.makeKeyAndOrderFront(nil)
        onVisibilityChange?()
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        if pendingFullScreenHide { pendingFullScreenHide = false; hide() }
    }

    public func chooseFolders() { show(); workspace.chooseFolders() }
    public func search() { show(); workspace.beginSearch() }

    public func shutdown() {
        if isPresented, let window, !window.styleMask.contains(.fullScreen) {
            workspace.preferences.lastWindowFrame = window.frame
        }
        animationGeneration += 1
        isPresented = false
        pendingFullScreenHide = false
        focusTask?.cancel()
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        deactivationObserver = nil
        settingsController.close()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        workspace.stop()
        window?.orderOut(nil)
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }

    private func focusColumns() {
        guard !workspace.isPalettePresented else { return }
        focusTask?.cancel()
        // Escape must release the old field editor before the next key arrives.
        // Mounted panes can take focus synchronously; new tabs retry below.
        if let window, window.isVisible, window.attachedSheet == nil {
            if let terminal = workspace.terminal?.terminalView, terminal.window === window {
                window.makeFirstResponder(terminal)
                return
            }
            if let browser = workspace.browser, browser.renamingURL == nil,
               let content = window.contentView,
               let table = BrowserColumnTableLocator.table(for: browser, columnIndex: browser.focusedColumnIndex, in: content) {
                window.makeFirstResponder(table)
                return
            }
            if window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
        }
        focusTask = Task { @MainActor [weak self] in
            for _ in 0..<8 {
                guard !Task.isCancelled, let self, !workspace.isPalettePresented,
                      let window, window.isVisible, window.attachedSheet == nil else { return }
                if let terminal = workspace.terminal?.terminalView, terminal.window === window {
                    window.makeFirstResponder(terminal)
                    return
                }
                guard let browser = workspace.browser else {
                    try? await Task.sleep(for: .milliseconds(20))
                    continue
                }
                guard browser.renamingURL == nil, let content = window.contentView else { return }
                if let table = BrowserColumnTableLocator.table(for: browser, columnIndex: browser.focusedColumnIndex, in: content) {
                    window.makeFirstResponder(table)
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func focusActions() {
        focusTask?.cancel()
        focusTask = Task { @MainActor [weak self] in
            for _ in 0..<15 {
                guard !Task.isCancelled, let self, workspace.isPalettePresented,
                      let window, let content = window.contentView else { return }
                if let field = AppKitSearchFieldFocusLocator.field(withAccessibilityIdentifier: workspace.paletteInputIdentifier, in: content) {
                    window.makeFirstResponder(field)
                    if AppKitSearchFieldFocusLocator.ownsFirstResponder(field) { return }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    private func alignToolbarWithSidebar() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let header = self.headerView, header.window != nil else { return }
            let leading = header.convert(.zero, to: nil).x
            let width = max(34, DrawerWorkspace.sidebarWidth - leading)
            if abs(self.workspace.toolbarLeadingWidth - width) > 0.5 { self.workspace.toolbarLeadingWidth = width }
            self.alignWindowControlsWithHeader()
        }
    }

    public func windowDidResize(_ notification: Notification) { alignToolbarWithSidebar() }

    public func windowDidUpdate(_ notification: Notification) { alignWindowControlsWithHeader() }

    private func alignWindowControlsWithHeader() {
        guard let window, !window.styleMask.contains(.fullScreen),
              let header = headerView, header.window === window else { return }
        let offset = DrawerToolbarView.verticalContentOffset
        let center = NSPoint(x: header.bounds.midX,
                             y: header.bounds.midY + (header.isFlipped ? offset : -offset))
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
            // Derive an absolute position so repeated AppKit layout passes cannot accumulate offsets.
            let y = header.convert(center, to: parent).y - button.frame.height / 2
            if abs(button.frame.minY - y) > 0.5 {
                button.setFrameOrigin(NSPoint(x: button.frame.minX, y: y))
            }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, window.attachedSheet == nil,
              NSApp.modalWindow == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let command = BrowserCommand.matching(keyCode: event.keyCode, modifiers: modifiers)
        if command == .actions { workspace.presentActions(); return true }
        if command == .search { workspace.beginSearch(); return true }
        if workspace.isPalettePresented {
            if window.firstResponder is NSTextView,
               (modifiers == .command && [0, 6, 7, 8, 9].contains(event.keyCode)
                || modifiers == [.command, .shift] && event.keyCode == 6) { return false }
            if modifiers.isEmpty {
                switch event.keyCode {
                case 53: workspace.dismissPalette(); return true
                case 125: workspace.movePaletteSelection(by: 1); return true
                case 126: workspace.movePaletteSelection(by: -1); return true
                case 121 where workspace.isSearchPresented: workspace.moveResultSelection(by: 6); return true
                case 116 where workspace.isSearchPresented: workspace.moveResultSelection(by: -6); return true
                case 36, 76: workspace.submitPalette(); return true
                case 48 where workspace.isLocationPresented: workspace.locations.completeSelection(); return true
                default: break
                }
            }
            if workspace.isSearchPresented, modifiers == .control {
                if event.keyCode == 45 { workspace.moveResultSelection(by: 1); return true }
                if event.keyCode == 35 { workspace.moveResultSelection(by: -1); return true }
            }
            if let command, !modifiers.intersection([.command, .control]).isEmpty {
                if command == .goToFolder { workspace.beginLocations(); return true }
                if workspace.isActionsPresented, workspace.executeAction(for: command) { return true }
            }
            return false
        }
        let numberKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        if modifiers == .command, let index = numberKeys.firstIndex(of: event.keyCode), workspace.tabGroups.indices.contains(index) {
            workspace.selectGroup(workspace.tabGroups[index].id)
            return true
        }
        if let command, workspace.browser?.renamingURL == nil,
           [.newTab, .closeTab, .settings, .newTerminal, .toggleSidebar, .nextTab, .previousTab,
            .splitPane, .splitTerminal, .splitFiles, .closeSplit, .focusOtherPane].contains(command) {
            workspace.perform(command); return true
        }
        if command == .goToFolder, !modifiers.isEmpty { workspace.beginLocations(); return true }
        // Plain o, editing shortcuts and terminal input keep their native meaning.
        if workspace.terminal != nil { return false }
        if window.firstResponder is NSTextView || window.firstResponder is NSSlider { return false }
        guard let browser = workspace.browser, browser.renamingURL == nil else { return false }
        if command == .quickLook, modifiers.isEmpty, let playback = browser.previewPlayback,
           playback.url == browser.previewEntry?.url { playback.toggle(); return true }
        switch (event.keyCode, modifiers) {
        case (53, []) where browser.previewEntry != nil: browser.browseColumn(at: browser.focusedColumnIndex); return true
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

private final class DrawerWindow: NSWindow {
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

/// Shared sizing policy keeps the drawer inside the usable area on small displays.
enum DrawerGeometry {
    static func restoredFrame(_ frame: NSRect, in screens: [NSRect], fallback: NSRect) -> NSRect {
        guard frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            return self.frame(in: fallback, preferredWidth: 1120, heightFraction: 0.65)
        }
        // Keep the saved display when possible, and recover windows from disconnected displays.
        let area = screens.max { left, right in
            let a = left.intersection(frame), b = right.intersection(frame)
            return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
        }.flatMap { $0.intersects(frame) ? $0 : nil } ?? fallback
        let width = min(frame.width, area.width), height = min(frame.height, area.height)
        return NSRect(x: min(max(frame.minX, area.minX), area.maxX - width),
                      y: min(max(frame.minY, area.minY), area.maxY - height), width: width, height: height)
    }

    static func frame(in area: NSRect, preferredWidth: CGFloat, heightFraction: Double) -> NSRect {
        let width = min(max(preferredWidth, 760), max(1, area.width))
        let height = min(max(430, area.height * heightFraction), area.height)
        return NSRect(x: area.midX - width / 2, y: area.maxY - height, width: width, height: height)
    }
}

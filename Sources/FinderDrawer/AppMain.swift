import AppKit
import Carbon
import FinderDrawerKit

@main
enum FinderDrawerApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var drawer: FinderDrawerController?
    private var statusItem: NSStatusItem?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        do {
            // Smoke runs use only the explicitly supplied fixture folder and
            // their own index/preferences, leaving normal app state untouched.
            let arguments = ProcessInfo.processInfo.arguments
            if let offset = arguments.firstIndex(of: "--smoke-root"), arguments.indices.contains(offset + 1) {
                let root = URL(fileURLWithPath: arguments[offset + 1], isDirectory: true)
                let defaults = UserDefaults(suiteName: "FinderDrawer.Smoke")!
                defaults.removePersistentDomain(forName: "FinderDrawer.Smoke")
                drawer = try FinderDrawerController(databaseURL: root.appendingPathComponent(".drawer-index.sqlite3"),
                                                     defaults: defaults, initialFolders: [root], restoresFolders: false)
            } else {
                drawer = try FinderDrawerController(allowsSystemWideAccess: true)
            }
            drawer?.onVisibilityChange = { [weak self] in
                if self?.drawer?.hasVisibleWindows == false { NSApp.setActivationPolicy(.accessory) }
            }
            drawer?.onShortcutChange = { [weak self] in self?.registerHotKey() }
            installStatusItem()
            installHotKey()
            drawer?.show()
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert(error: error)
            alert.messageText = "Finder Drawer couldn’t start"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        drawer?.shutdown()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        drawer?.show(); return true
    }

    @objc private func showSettings() { drawer?.showSettings() }
    @objc private func toggleDrawer() { drawer?.toggle() }
    @objc private func chooseFolders() { drawer?.chooseFolders() }
    @objc private func searchFiles() { drawer?.search() }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Finder Drawer")
        let menu = NSMenu()
        for (title, action) in [("Show / Hide Drawer", #selector(toggleDrawer)),
                                ("Search Files…", #selector(searchFiles)),
                                ("Choose Folders…", #selector(chooseFolders)),
                                ("Settings…", #selector(showSettings))] {
            let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            entry.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Finder Drawer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    private func installMenu() {
        let menu = NSMenu()
        let appMenu = NSMenu()
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Finder Drawer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        let file = NSMenu(title: "File")
        for (title, action, key, modifiers) in [
            ("New Folder", "newFolder:", "n", NSEvent.ModifierFlags([.command, .shift])),
            ("Duplicate", "duplicate:", "d", .command),
            ("Rename", "renameFile:", "", []),
            ("Move to Trash", "moveToTrash:", "\u{8}", .command),
        ] {
            let item = file.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
        }
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        fileItem.submenu = file
        menu.addItem(fileItem)
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                     ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
                                     ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let redo = edit.insertItem(withTitle: "Redo", action: Selector("redo:"), keyEquivalent: "z", at: 1)
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        let moveHere = edit.addItem(withTitle: "Move Item Here", action: Selector("moveHere:"), keyEquivalent: "v")
        moveHere.keyEquivalentModifierMask = [.command, .option]
        let copyPath = edit.addItem(withTitle: "Copy Path", action: Selector("copyPath:"), keyEquivalent: "c")
        copyPath.keyEquivalentModifierMask = [.command, .option]
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit; menu.addItem(editItem)
        let windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let fullScreen = windows.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        windows.addItem(.separator())
        windows.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windows
        menu.addItem(windowItem)
        NSApp.windowsMenu = windows
        NSApp.mainMenu = menu
    }

    private func installHotKey() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().toggleDrawer()
            }
            return noErr
        }, 1, &event, userData, &eventHandler)
        guard installed == noErr else {
            drawer?.setShortcutError("Couldn’t listen for the shortcut. Use the menu bar to open the drawer.")
            return
        }
        registerHotKey()
    }

    private func registerHotKey() {
        guard eventHandler != nil, let drawer else { return }
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        guard !drawer.isRecordingShortcut else { return }
        let identifier = EventHotKeyID(signature: 0x46445257, id: 1)
        let result = RegisterEventHotKey(drawer.shortcut.keyCode, drawer.shortcut.carbonModifiers,
                                        identifier, GetApplicationEventTarget(), 0, &hotKey)
        drawer.setShortcutError(result == noErr ? nil : "\(drawer.shortcut.label) is unavailable. Choose another shortcut or use the menu bar.")
    }
}

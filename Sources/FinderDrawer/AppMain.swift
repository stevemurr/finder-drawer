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
                drawer = try FinderDrawerController()
            }
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

    @objc private func toggleDrawer() { drawer?.toggle() }
    @objc private func chooseFolders() { drawer?.chooseFolders() }
    @objc private func searchFiles() { drawer?.search() }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Finder Drawer")
        let menu = NSMenu()
        for (title, action) in [("Show / Hide Drawer  ⌃⌥Space", #selector(toggleDrawer)),
                                ("Search Files…", #selector(searchFiles)),
                                ("Choose Folders…", #selector(chooseFolders))] {
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
        appMenu.addItem(withTitle: "Quit Finder Drawer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; menu.addItem(appItem)
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"),
                                     ("Copy", "copy:", "c"), ("Paste", "paste:", "v"),
                                     ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit; menu.addItem(editItem)
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
        guard installed == noErr else { return }
        let identifier = EventHotKeyID(signature: 0x46445257, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                                        identifier, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr {
            let alert = NSAlert()
            alert.messageText = "The drawer shortcut is unavailable"
            alert.informativeText = "Another app may already use Control–Option–Space. You can still open Finder Drawer from its menu bar icon."
            alert.runModal()
        }
    }
}

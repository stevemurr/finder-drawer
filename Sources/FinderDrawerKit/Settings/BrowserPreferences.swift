import Foundation
import Observation

/// Browser preferences have their own app domain, independent of Topside.
@MainActor
@Observable
final class BrowserPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    var hideOnDeactivate: Bool {
        didSet { defaults.set(hideOnDeactivate, forKey: "drawerHideOnDeactivate") }
    }
    var animateDrawer: Bool {
        didSet { defaults.set(animateDrawer, forKey: "drawerAnimate") }
    }
    var drawerWidth: Double {
        didSet { defaults.set(drawerWidth, forKey: "drawerWidth") }
    }
    var drawerHeight: Double {
        didSet { defaults.set(drawerHeight, forKey: "drawerHeight") }
    }
    var shortcut: DrawerShortcut {
        didSet {
            defaults.set(try? JSONEncoder().encode(shortcut), forKey: "drawerShortcutData")
            onShortcutChange?()
        }
    }
    @ObservationIgnored var onShortcutChange: (() -> Void)?
    var isRecordingShortcut = false {
        didSet { onShortcutChange?() }
    }
    var isSidebarVisible: Bool {
        didSet { defaults.set(isSidebarVisible, forKey: "drawerSidebarVisible") }
    }
    var shortcutError: String?

    var showHiddenFiles: Bool {
        didSet { defaults.set(showHiddenFiles, forKey: "browserShowHiddenFiles") }
    }
    var showItemSizes: Bool {
        didSet { defaults.set(showItemSizes, forKey: "browserShowItemSizes") }
    }
    var sortOrder: BrowserSort {
        didSet { defaults.set(sortOrder.rawValue, forKey: "browserSortOrder") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hideOnDeactivate = defaults.object(forKey: "drawerHideOnDeactivate") as? Bool ?? false
        animateDrawer = defaults.object(forKey: "drawerAnimate") as? Bool ?? true
        let width = defaults.object(forKey: "drawerWidth") as? Double ?? 0.8
        drawerWidth = width.isFinite ? min(max(width, 0.4), 1) : 0.8
        let height = defaults.object(forKey: "drawerHeight") as? Double ?? 0.65
        drawerHeight = height.isFinite ? min(max(height, 0.35), 0.9) : 0.65
        isSidebarVisible = defaults.object(forKey: "drawerSidebarVisible") as? Bool ?? true
        shortcut = defaults.data(forKey: "drawerShortcutData").flatMap { try? JSONDecoder().decode(DrawerShortcut.self, from: $0) }
            ?? defaults.string(forKey: "drawerShortcut").flatMap(DrawerShortcut.init(rawValue:)) ?? .controlOptionSpace
        showHiddenFiles = defaults.bool(forKey: "browserShowHiddenFiles")
        showItemSizes = defaults.bool(forKey: "browserShowItemSizes")
        sortOrder = defaults.string(forKey: "browserSortOrder")
            .flatMap(BrowserSort.init(rawValue:)) ?? .name
    }
}

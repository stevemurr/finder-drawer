import AppKit
import Observation

/// Composes the extracted browser and index without a terminal or agent host.
@MainActor
@Observable
final class DrawerWorkspace {
    let folders: FolderAccessManager
    let preferences: BrowserPreferences
    let index: FileIndexService
    let search: FileSearchModel
    let quickLook = QuickLookController()
    private(set) var tabs: [DrawerTab] = []
    private(set) var tabGroups: [DrawerTabGroup] = []
    private(set) var selectedGroupID: UUID?
    enum Pane: String { case primary, secondary }
    var selectedGroup: DrawerTabGroup? { tabGroups.first { $0.id == selectedGroupID } }
    var primaryTabID: UUID? { selectedGroup?.primaryID }
    var secondaryTabID: UUID? { selectedGroup?.secondaryID }
    var activePane: Pane { secondaryTabID != nil && selectedTabID == secondaryTabID ? .secondary : .primary }
    var selectedTabID: UUID? { selectedGroup?.focusedID }
    var isSplit: Bool { secondaryTabID != nil }
    var toolbarLeadingWidth: CGFloat = 132
    static let sidebarWidth: CGFloat = 220
    var isSearchPresented = false
    let locations: DrawerLocationPicker
    var isLocationPresented = false
    var isPalettePresented: Bool { isActionsPresented || isSearchPresented || isLocationPresented }
    var selectedResultID: URL?
    var errorMessage: String?
    var searchFocusToken = 0
    private(set) var paletteInputIdentifier = "context-actions-search-" + UUID().uuidString
    var isActionsPresented = false
    var actionQuery = ""
    var selectedActionIndex = 0
    var actionContextTitle = "Actions"
    var contextActions: [DrawerAction] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored private var isRestoringTabs = true
    @ObservationIgnored var onRequestActionFocus: (() -> Void)?
    @ObservationIgnored var onRequestColumnFocus: (() -> Void)?
    @ObservationIgnored var onShowSettings: (() -> Void)?
    @ObservationIgnored var onHide: (() -> Void)?

    init(
        databaseURL: URL,
        defaults: UserDefaults = .standard,
        initialFolders: [URL] = [],
        restoresFolders: Bool = true,
        allowsSystemWideAccess: Bool = false
    ) throws {
        self.defaults = defaults
        locations = DrawerLocationPicker(defaults: defaults)
        folders = FolderAccessManager(defaults: defaults, loadStoredPaths: restoresFolders, initialFolders: initialFolders,
                                      allowsSystemWideAccess: allowsSystemWideAccess)
        preferences = BrowserPreferences(defaults: defaults)
        index = try FileIndexService(databaseURL: databaseURL, indexRoots: folders.folders)
        search = FileSearchModel(searchService: index)
        let restored = (restoresFolders ? defaults.standardizedFileURLs(forKey: "browserTabRoots") : [])
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
        let savedTabs = restoresFolders ? defaults.data(forKey: "drawerTabs").flatMap {
            try? JSONDecoder().decode([SavedDrawerTab].self, from: $0)
        } : nil
        let restoredSecondary = restoresFolders ? defaults.object(forKey: "drawerSecondaryTab") as? Int : nil
        let restoredPrimary = defaults.integer(forKey: "drawerPrimaryTab")
        let restoredActivePane = defaults.string(forKey: "drawerActivePane")
        let restoredSelection = defaults.integer(forKey: savedTabs == nil ? "selectedBrowserTab" : "selectedDrawerTab")
        let savedGroups = restoresFolders ? defaults.data(forKey: "drawerTabGroups").flatMap {
            try? JSONDecoder().decode([SavedDrawerTabGroup].self, from: $0)
        } : nil
        let restoredGroupIndex = defaults.integer(forKey: "selectedDrawerGroup")
        var restoredIDs: [Int: UUID] = [:]
        if let savedTabs {
            for (index, tab) in savedTabs.prefix(100).enumerated() {
                let root = URL(fileURLWithPath: tab.path, isDirectory: true)
                guard FileManager.default.isReadableFile(atPath: root.path),
                      (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if tab.kind == .terminal { newTerminal(at: root) }
                else { newTab(at: root) }
                restoredIDs[index] = selectedTabID
            }
        } else {
            for (index, root) in restored.prefix(100).enumerated() {
                newTab(at: root)
                restoredIDs[index] = selectedTabID
            }
        }
        if tabs.isEmpty { newTab(at: defaultLocation) }
        if let savedGroups {
            restoreGroups(savedGroups, selectedIndex: restoredGroupIndex, restoredIDs: restoredIDs)
        } else {
            if let id = restoredIDs[restoredSelection] { selectTab(id) }
            // Migrate the previously visible split to a persistent pair.
            if let restoredSecondary, let secondary = restoredIDs[restoredSecondary],
               let primary = restoredIDs[restoredPrimary], primary != secondary,
               let index = tabGroups.firstIndex(where: { $0.primaryID == primary }) {
                tabGroups[index].secondaryID = secondary
                tabGroups[index].focusedID = restoredActivePane == Pane.secondary.rawValue ? secondary : primary
                selectedGroupID = tabGroups[index].id
                tabGroups.removeAll { $0.primaryID == secondary }
            }
        }
        preferences.onTerminalThemeChange = { [weak self] in self?.applyTerminalThemes() }
        applyTerminalThemes()
        isRestoringTabs = false
        persistTabs()
    }

    var defaultLocation: URL? {
        folders.folders.first ?? (folders.allowsSystemWideAccess ? FileManager.default.homeDirectoryForCurrentUser : nil)
    }

    var selectedTab: DrawerTab? { tabs.first { $0.id == selectedTabID } }
    var browser: BrowserViewModel? { selectedTab?.browser }
    var terminal: TerminalSession? { selectedTab?.terminal }
    var selectedResult: FileSearchResult? { search.results.first { $0.id == selectedResultID } }

    func start() { index.start() }

    func stop() {
        guard !isStopped else { return }
        persistTabs()
        isStopped = true
        index.stop()
        quickLook.close()
        for tab in tabs { tab.terminal?.stop() }
        tabs.removeAll()
        tabGroups.removeAll()
        selectedGroupID = nil
    }

    func newTab(at root: URL? = nil) {
        dismissPalette(restoringFocus: false)
        let browser = BrowserViewModel(
            folderAccess: folders,
            preferences: preferences,
            quickLook: quickLook,
            onFileSystemChange: { [weak self] in self?.index.rebuildIndex() }
        )
        browser.onHostCommand = { [weak self] in self?.perform($0) }
        browser.onOpenSelection = { [weak self, weak browser] in
            guard let self, let browser else { return }
            if browser.openSelection() { self.onHide?() }
        }
        browser.onRequestColumnFocus = { [weak self, weak browser] in
            guard let self, let browser, self.browser === browser,
                  !self.isPalettePresented else { return }
            self.onRequestColumnFocus?()
        }
        browser.onPreviewFile = { [weak self, weak browser] url in
            guard let self, self.browser === browser else { return }
            self.quickLook.refreshIfVisible(with: .fixture(url: url))
        }
        browser.onCancelPreview = { [weak self, weak browser] in
            guard let self, self.browser === browser else { return }
            self.quickLook.close()
        }
        let destination = root ?? self.browser?.currentRoot ?? defaultLocation
        tabs.append(DrawerTab(browser: browser))
        appendSingleGroup(for: browser.id)
        if let destination { browser.setRoot(destination); locations.remember(destination) }
        persistTabs()
    }

    func newTerminal(at directory: URL? = nil) {
        let directory = directory ?? contextDirectory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorMessage = "That folder is no longer available."
            return
        }
        let session = TerminalSession(directory: directory)
        session.setThemes(light: preferences.lightTerminalTheme, dark: preferences.darkTerminalTheme)
        session.setUsesGPU(preferences.terminalUsesGPU)
        tabs.append(DrawerTab(terminal: session))
        appendSingleGroup(for: session.id)
        dismissPalette()
        persistTabs()
    }

    var contextDirectory: URL {
        if isSearchPresented, let result = selectedResult {
            return result.isDirectory ? result.url : result.url.deletingLastPathComponent()
        }
        return terminal?.directory ?? browser?.activeDirectory ?? defaultLocation ?? FileManager.default.homeDirectoryForCurrentUser
    }

    private func appendSingleGroup(for tabID: UUID) {
        let group = DrawerTabGroup(primaryID: tabID)
        tabGroups.append(group)
        selectedGroupID = group.id
    }

    func cycleTab(by offset: Int) {
        guard !tabGroups.isEmpty else { return }
        let current = tabGroups.firstIndex { $0.id == selectedGroupID } ?? 0
        let index = ((current + offset) % tabGroups.count + tabGroups.count) % tabGroups.count
        selectGroup(tabGroups[index].id)
    }

    func selectGroup(_ id: UUID) {
        guard tabGroups.contains(where: { $0.id == id }) else { return }
        selectedGroupID = id
        dismissPalette()
        persistTabs()
    }

    func selectTab(_ id: UUID) {
        guard let index = tabGroups.firstIndex(where: { $0.memberIDs.contains(id) }) else { return }
        tabGroups[index].focusedID = id
        selectGroup(tabGroups[index].id)
    }

    func tab(withID id: UUID) -> DrawerTab? { tabs.first { $0.id == id } }

    /// Move strip units without recreating sessions or changing pair focus.
    /// A nil target means the end of the strip.
    @discardableResult
    func moveGroup(_ id: UUID, relativeTo target: UUID?, after: Bool = false) -> Bool {
        guard let sourceIndex = tabGroups.firstIndex(where: { $0.id == id }),
              target != id,
              target == nil || tabGroups.contains(where: { $0.id == target }) else { return false }
        let originalOrder = tabGroups.map(\.id)
        let group = tabGroups.remove(at: sourceIndex)
        let targetIndex = target.flatMap { target in tabGroups.firstIndex { $0.id == target } }
        let insertion = targetIndex.map { $0 + (after ? 1 : 0) } ?? tabGroups.count
        tabGroups.insert(group, at: insertion)
        guard tabGroups.map(\.id) != originalOrder else { return false }
        persistTabs()
        return true
    }

    func moveGroup(_ id: UUID, by offset: Int) {
        guard let index = tabGroups.firstIndex(where: { $0.id == id }),
              tabGroups.indices.contains(index + offset) else { return }
        moveGroup(id, relativeTo: tabGroups[index + offset].id, after: offset > 0)
    }

    /// Join neighboring singles in strip order, keeping their sessions alive.
    /// Retain the target's identity so its outline can become the pair capsule.
    @discardableResult
    func mergeGroups(_ sourceID: UUID, into targetID: UUID) -> Bool {
        guard let sourceIndex = tabGroups.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = tabGroups.firstIndex(where: { $0.id == targetID }),
              abs(sourceIndex - targetIndex) == 1,
              tabGroups[sourceIndex].secondaryID == nil,
              tabGroups[targetIndex].secondaryID == nil else { return false }
        let range = min(sourceIndex, targetIndex)...max(sourceIndex, targetIndex)
        let pair = DrawerTabGroup(id: targetID,
                                  primaryID: tabGroups[range.lowerBound].primaryID,
                                  secondaryID: tabGroups[range.upperBound].primaryID,
                                  focusedID: tabGroups[sourceIndex].primaryID)
        tabGroups.replaceSubrange(range, with: [pair])
        selectedGroupID = pair.id
        dismissPalette()
        persistTabs()
        return true
    }

    func tab(in pane: Pane) -> DrawerTab? {
        let id = pane == .primary ? primaryTabID : secondaryTabID
        return tabs.first { $0.id == id }
    }

    func focusPane(_ pane: Pane, requestFocus: Bool = true) {
        guard let index = tabGroups.firstIndex(where: { $0.id == selectedGroupID }),
              let id = pane == .primary ? primaryTabID : secondaryTabID else { return }
        tabGroups[index].focusedID = id
        quickLook.close()
        if requestFocus { onRequestColumnFocus?() }
        persistTabs()
    }

    func splitPane(terminal: Bool? = nil) {
        guard !isSplit, let originalGroup = selectedGroup else { return }
        let directory = contextDirectory
        let useTerminal = terminal ?? (self.terminal != nil)
        if useTerminal { newTerminal(at: directory) } else { newTab(at: directory) }
        guard let addedID = selectedTabID, addedID != originalGroup.primaryID,
              let index = tabGroups.firstIndex(where: { $0.id == originalGroup.id }) else { return }
        let addedGroupID = selectedGroupID
        tabGroups[index].secondaryID = addedID
        tabGroups[index].focusedID = addedID
        tabGroups.removeAll { $0.id == addedGroupID }
        selectedGroupID = originalGroup.id
        dismissPalette()
        persistTabs()
    }

    func unpairGroup(_ id: UUID) {
        guard let index = tabGroups.firstIndex(where: { $0.id == id }),
              let secondaryID = tabGroups[index].secondaryID else { return }
        let pair = tabGroups[index]
        let left = DrawerTabGroup(id: pair.id, primaryID: pair.primaryID)
        let right = DrawerTabGroup(primaryID: secondaryID)
        tabGroups.replaceSubrange(index...index, with: [left, right])
        if selectedGroupID == pair.id {
            selectedGroupID = pair.focusedID == secondaryID ? right.id : left.id
            dismissPalette()
        }
        persistTabs()
    }

    func closeSplit() {
        if let selectedGroupID { unpairGroup(selectedGroupID) }
    }

    /// Closing a tab-strip item closes the whole pair. Closing an individual
    /// session (for example via an embedded host) leaves its partner as a single.
    func closeGroup(_ id: UUID) {
        guard let group = tabGroups.first(where: { $0.id == id }) else { return }
        if group.secondaryID == nil { closeTab(group.primaryID); return }
        removeTabs(Set(group.memberIDs))
    }

    func closeTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        guard tabs.count > 1 || tabs.first?.terminal != nil else { onHide?(); return }
        removeTabs([id])
    }

    private func removeTabs(_ ids: Set<UUID>) {
        let previousIndex = tabGroups.firstIndex { $0.id == selectedGroupID } ?? 0
        for tab in tabs where ids.contains(tab.id) { tab.terminal?.stop() }
        tabs.removeAll { ids.contains($0.id) }
        tabGroups = tabGroups.compactMap { group in
            let remaining = group.memberIDs.filter { !ids.contains($0) }
            guard let primary = remaining.first else { return nil }
            return DrawerTabGroup(id: group.id, primaryID: primary,
                                  secondaryID: remaining.dropFirst().first,
                                  focusedID: remaining.contains(group.focusedID) ? group.focusedID : primary)
        }
        if !tabGroups.contains(where: { $0.id == selectedGroupID }) {
            selectedGroupID = tabGroups[safe: min(previousIndex, tabGroups.count - 1)]?.id
        }
        if tabs.isEmpty { newTab() }
        onRequestColumnFocus?()
        persistTabs()
    }

    private func restoreGroups(_ saved: [SavedDrawerTabGroup], selectedIndex: Int, restoredIDs: [Int: UUID]) {
        var used = Set<UUID>()
        var groups: [DrawerTabGroup] = []
        var selected: UUID?
        for (index, entry) in saved.enumerated() {
            let members = entry.members.prefix(2).compactMap { restoredIDs[$0] }.filter { used.insert($0).inserted }
            guard let primary = members.first else { continue }
            let focused = entry.members[safe: entry.focusedMember].flatMap { restoredIDs[$0] }
            let group = DrawerTabGroup(primaryID: primary, secondaryID: members.dropFirst().first, focusedID: focused)
            groups.append(group)
            if index == selectedIndex { selected = group.id }
        }
        for tab in tabs where !used.contains(tab.id) { groups.append(DrawerTabGroup(primaryID: tab.id)) }
        tabGroups = groups
        selectedGroupID = selected ?? groups.first?.id
    }

    func persistTabs() {
        guard !isStopped, !isRestoringTabs else { return }
        let saved = tabs.compactMap { tab -> SavedDrawerTab? in
            guard let path = tab.currentRoot?.path else { return nil }
            return SavedDrawerTab(kind: tab.terminal == nil ? .browser : .terminal, path: path)
        }
        defaults.set(try? JSONEncoder().encode(saved), forKey: "drawerTabs")
        let savedIDs = tabs.filter { $0.currentRoot != nil }.map(\.id)
        let groups = tabGroups.compactMap { group -> (UUID, SavedDrawerTabGroup)? in
            let memberIDs = group.memberIDs.filter { savedIDs.contains($0) }
            guard !memberIDs.isEmpty else { return nil }
            let members = memberIDs.compactMap { savedIDs.firstIndex(of: $0) }
            return (group.id, SavedDrawerTabGroup(members: members,
                focusedMember: memberIDs.firstIndex(of: group.focusedID) ?? 0))
        }
        defaults.set(try? JSONEncoder().encode(groups.map(\.1)), forKey: "drawerTabGroups")
        defaults.set(groups.firstIndex { $0.0 == selectedGroupID } ?? 0, forKey: "selectedDrawerGroup")
        // Retain the legacy keys so older builds can restore the active pair.
        defaults.set(savedIDs.firstIndex { $0 == primaryTabID } ?? 0, forKey: "drawerPrimaryTab")
        defaults.set(savedIDs.firstIndex { $0 == secondaryTabID }, forKey: "drawerSecondaryTab")
        defaults.set(activePane.rawValue, forKey: "drawerActivePane")
        defaults.set(savedIDs.firstIndex { $0 == selectedTabID } ?? 0, forKey: "selectedDrawerTab")
        defaults.setStandardizedFileURLs(tabs.compactMap { $0.browser?.currentRoot }, forKey: "browserTabRoots")
        defaults.set(tabs.filter { $0.browser != nil }.firstIndex { $0.id == selectedTabID } ?? 0, forKey: "selectedBrowserTab")
    }

    func chooseFolders() {
        guard folders.chooseFolders() else { return }
        index.replaceIndexRoots(folders.folders)
        if browser?.currentRoot == nil { browser?.present() }
        persistTabs()
    }

    func removeFolder(_ root: URL) {
        folders.removeFolder(root)
        index.replaceIndexRoots(folders.folders)
        // Empty tabs do not retain a removed root as a writable-looking location.
        if folders.folders.isEmpty && !folders.allowsSystemWideAccess {
            removeTabs(Set(tabs.filter { $0.browser != nil }.map(\.id)))
            if browser == nil { newTab() }
        }
        persistTabs()
    }

    func navigate(to url: URL) {
        dismissPalette()
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        locations.remember(isDirectory.boolValue ? url : url.deletingLastPathComponent())
        if browser == nil { newTab(at: url.hasDirectoryPath ? url : url.deletingLastPathComponent()) }
        browser?.navigate(to: url, previewsFileSelection: false)
        persistTabs()
    }

    func beginSearch() {
        dismissPalette(restoringFocus: false)
        isSearchPresented = true
        searchFocusToken += 1
        requestPaletteFocus()
    }

    func beginLocations() {
        let directory = contextDirectory
        dismissPalette(restoringFocus: false)
        locations.begin(at: directory, favorites: folders.folders)
        isLocationPresented = true
        requestPaletteFocus()
    }

    func requestPaletteFocus() {
        paletteInputIdentifier = "context-actions-search-" + UUID().uuidString
        onRequestActionFocus?()
    }

    func dismissPalette(restoringFocus: Bool = true) {
        isActionsPresented = false
        isSearchPresented = false
        isLocationPresented = false
        contextActions = []
        quickLook.close()
        if restoringFocus { onRequestColumnFocus?() }
    }

    func openSelectedLocation() {
        guard let url = locations.selectedURL else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            locations.errorMessage = "That folder doesn’t exist or isn’t accessible."
            return
        }
        // A typed exact path is valid even when it is outside indexed folders.
        if browser == nil { newTab(at: url) } else { browser?.setRoot(url) }
        locations.remember(url)
        dismissPalette()
        persistTabs()
    }

    func dismissSearch() {
        isSearchPresented = false
        quickLook.close()
        onRequestColumnFocus?()
    }

    func reveal(_ result: FileSearchResult) { navigate(to: result.url) }

    func resultsDidChange() {
        if selectedResult == nil { selectedResultID = search.results.first?.id }
        quickLook.refreshIfVisible(with: selectedResult)
    }

    func moveResultSelection(by offset: Int) {
        guard !search.results.isEmpty else { selectedResultID = nil; return }
        let current = search.results.firstIndex { $0.id == selectedResultID } ?? (offset > 0 ? -1 : 0)
        selectedResultID = search.results[min(max(current + offset, 0), search.results.count - 1)].id
    }

    func openResult(_ result: FileSearchResult) {
        if result.isDirectory { reveal(result) }
        else if NSWorkspace.shared.open(result.url) { onHide?() }
        else { errorMessage = "Couldn’t open \(result.displayName). The file may have moved." }
    }

    func applyTerminalThemes() {
        for tab in tabs {
            tab.terminal?.setThemes(light: preferences.lightTerminalTheme, dark: preferences.darkTerminalTheme)
            tab.terminal?.setUsesGPU(preferences.terminalUsesGPU)
        }
    }

    func applyPreferences() {
        for tab in tabs { tab.browser?.applyPreferenceChange() }
    }

    func perform(_ command: BrowserCommand) {
        switch command {
        case .actions: presentActions()
        case .newTerminal: newTerminal()
        case .toggleSidebar: preferences.isSidebarVisible.toggle()
        case .nextTab: cycleTab(by: 1)
        case .previousTab: cycleTab(by: -1)
        case .search: beginSearch()
        case .goToFolder: beginLocations()
        case .splitPane: splitPane()
        case .splitTerminal: splitPane(terminal: true)
        case .splitFiles: splitPane(terminal: false)
        case .closeSplit: closeSplit()
        case .focusOtherPane: focusPane(activePane == .primary ? .secondary : .primary)
        case .newTab: newTab()
        case .closeTab: if let selectedGroupID { closeGroup(selectedGroupID) }
        case .settings: onShowSettings?()
        case .openWith: chooseApplication()
        default: browser?.perform(command)
        }
    }

    private func chooseApplication() {
        guard let url = browser?.focusedEntry?.url else { return }
        let panel = NSOpenPanel()
        panel.title = "Open With"
        panel.message = "Choose an application to open \(url.lastPathComponent)."
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let application = panel.url else { return }
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.errorMessage = error.localizedDescription }
                else { self?.onHide?() }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

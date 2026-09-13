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
    enum Pane: String { case primary, secondary }
    private(set) var primaryTabID: UUID?
    private(set) var secondaryTabID: UUID?
    private(set) var activePane: Pane = .primary
    private(set) var selectedTabID: UUID? {
        get { activePane == .secondary ? secondaryTabID ?? primaryTabID : primaryTabID }
        set { if activePane == .secondary { secondaryTabID = newValue } else { primaryTabID = newValue } }
    }
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
        if let savedTabs {
            for tab in savedTabs.prefix(20) {
                let root = URL(fileURLWithPath: tab.path, isDirectory: true)
                guard FileManager.default.isReadableFile(atPath: root.path) else { continue }
                if tab.kind == .terminal { newTerminal(at: root) }
                else { newTab(at: root) }
            }
        } else {
            for root in restored.prefix(20) { newTab(at: root) }
        }
        if tabs.isEmpty { newTab(at: defaultLocation) }
        if let tab = tabs[safe: restoredSelection] {
            selectedTabID = tab.id
        }
        if let restoredSecondary, let secondary = tabs[safe: restoredSecondary],
           let primary = tabs[safe: restoredPrimary], primary.id != secondary.id {
            primaryTabID = primary.id
            secondaryTabID = secondary.id
            activePane = restoredActivePane == Pane.secondary.rawValue ? .secondary : .primary
        }
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
        selectedTabID = browser.id
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
        tabs.append(DrawerTab(terminal: session))
        selectedTabID = session.id
        dismissPalette()
        persistTabs()
    }

    var contextDirectory: URL {
        if isSearchPresented, let result = selectedResult {
            return result.isDirectory ? result.url : result.url.deletingLastPathComponent()
        }
        return terminal?.directory ?? browser?.activeDirectory ?? defaultLocation ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func cycleTab(by offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedTabID } ?? 0
        selectTab(tabs[(current + offset + tabs.count) % tabs.count].id)
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if isSplit, tab(in: activePane == .primary ? .secondary : .primary)?.id == id {
            let old = selectedTabID
            if activePane == .primary { secondaryTabID = old } else { primaryTabID = old }
        }
        selectedTabID = id
        dismissPalette()
        persistTabs()
    }

    func tab(in pane: Pane) -> DrawerTab? {
        let id = pane == .primary ? primaryTabID : secondaryTabID
        return tabs.first { $0.id == id }
    }

    func focusPane(_ pane: Pane, requestFocus: Bool = true) {
        guard pane == .primary || isSplit else { return }
        activePane = pane
        quickLook.close()
        if requestFocus { onRequestColumnFocus?() }
        persistTabs()
    }

    func splitPane(terminal: Bool? = nil) {
        let directory = contextDirectory
        let useTerminal = terminal ?? (self.terminal != nil)
        let original = primaryTabID
        activePane = .secondary
        if useTerminal { newTerminal(at: directory) } else { newTab(at: directory) }
        primaryTabID = original
        if secondaryTabID == nil { activePane = .primary }
        dismissPalette()
        persistTabs()
    }

    func closeSplit() {
        guard isSplit else { return }
        primaryTabID = selectedTabID
        secondaryTabID = nil
        activePane = .primary
        dismissPalette()
        persistTabs()
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1 || tabs.first?.terminal != nil else { onHide?(); return }
        guard let offset = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[offset].terminal?.stop()
        tabs.remove(at: offset)
        if tabs.isEmpty {
            primaryTabID = nil; secondaryTabID = nil; activePane = .primary
            newTab(); return
        }
        if primaryTabID == id || secondaryTabID == id {
            let otherID = primaryTabID == id ? secondaryTabID : primaryTabID
            let replacement = tabs.first { $0.id != otherID }?.id
            if let replacement {
                if primaryTabID == id { primaryTabID = replacement } else { secondaryTabID = replacement }
            } else {
                primaryTabID = otherID ?? tabs[0].id
                secondaryTabID = nil
                activePane = .primary
            }
        }
        onRequestColumnFocus?()
        persistTabs()
    }

    func persistTabs() {
        guard !isStopped else { return }
        let saved = tabs.compactMap { tab -> SavedDrawerTab? in
            guard let path = tab.currentRoot?.path else { return nil }
            return SavedDrawerTab(kind: tab.terminal == nil ? .browser : .terminal, path: path)
        }
        defaults.set(try? JSONEncoder().encode(saved), forKey: "drawerTabs")
        let savedIDs = tabs.filter { $0.currentRoot != nil }.map(\.id)
        defaults.set(savedIDs.firstIndex { $0 == primaryTabID } ?? 0, forKey: "drawerPrimaryTab")
        defaults.set(savedIDs.firstIndex { $0 == secondaryTabID }, forKey: "drawerSecondaryTab")
        defaults.set(activePane.rawValue, forKey: "drawerActivePane")
        defaults.set(tabs.filter { $0.currentRoot != nil }.firstIndex { $0.id == selectedTabID } ?? 0, forKey: "selectedDrawerTab")
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
            tabs.removeAll { $0.browser != nil }
            primaryTabID = tabs.first?.id
            secondaryTabID = nil
            activePane = .primary
            newTab()
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
        case .closeSplit: closeSplit()
        case .focusOtherPane: focusPane(activePane == .primary ? .secondary : .primary)
        case .newTab: newTab()
        case .closeTab: if let selectedTabID { closeTab(selectedTabID) }
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

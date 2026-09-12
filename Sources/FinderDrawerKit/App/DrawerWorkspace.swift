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
    private(set) var tabs: [BrowserViewModel] = []
    private(set) var selectedTabID: UUID?
    var isSearchPresented = false
    var isFolderPickerPresented = false
    var isPreferencesPresented = false
    var selectedResultID: URL?
    var errorMessage: String?
    var searchFocusToken = 0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isStopped = false
    @ObservationIgnored var onRequestColumnFocus: (() -> Void)?
    @ObservationIgnored var onHide: (() -> Void)?

    init(
        databaseURL: URL,
        defaults: UserDefaults = .standard,
        initialFolders: [URL] = [],
        restoresFolders: Bool = true
    ) throws {
        self.defaults = defaults
        folders = FolderAccessManager(defaults: defaults, loadStoredPaths: restoresFolders, initialFolders: initialFolders)
        preferences = BrowserPreferences(defaults: defaults)
        index = try FileIndexService(databaseURL: databaseURL, indexRoots: folders.folders)
        search = FileSearchModel(searchService: index)
        let restored = (restoresFolders ? defaults.standardizedFileURLs(forKey: "browserTabRoots") : [])
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
        let restoredSelection = defaults.integer(forKey: "selectedBrowserTab")
        for root in restored.prefix(20) { newTab(at: root) }
        if tabs.isEmpty { newTab(at: folders.folders.first) }
        if let tab = tabs[safe: restoredSelection] {
            selectedTabID = tab.id
        }
        persistTabs()
    }

    var browser: BrowserViewModel? { tabs.first { $0.id == selectedTabID } }
    var selectedResult: FileSearchResult? { search.results.first { $0.id == selectedResultID } }

    func start() { index.start() }

    func stop() {
        guard !isStopped else { return }
        persistTabs()
        isStopped = true
        index.stop()
        quickLook.close()
        tabs.removeAll()
    }

    func newTab(at root: URL? = nil) {
        if isSearchPresented { dismissSearch() }
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
        browser.onRequestColumnFocus = { [weak self] in self?.onRequestColumnFocus?() }
        browser.onPreviewFile = { [weak self] url in
            self?.quickLook.refreshIfVisible(with: .fixture(url: url))
        }
        browser.onCancelPreview = { [weak self] in self?.quickLook.close() }
        let destination = root ?? self.browser?.currentRoot ?? folders.folders.first
        tabs.append(browser)
        selectedTabID = browser.id
        if let destination { browser.setRoot(destination) }
        persistTabs()
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        dismissSearch()
        persistTabs()
    }

    func closeTab(_ id: UUID) {
        guard tabs.count > 1 else { onHide?(); return }
        guard let offset = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: offset)
        if selectedTabID == id { selectedTabID = tabs[min(offset, tabs.count - 1)].id }
        onRequestColumnFocus?()
        persistTabs()
    }

    func persistTabs() {
        guard !isStopped else { return }
        defaults.setStandardizedFileURLs(tabs.compactMap(\.currentRoot), forKey: "browserTabRoots")
        defaults.set(tabs.firstIndex { $0.id == selectedTabID } ?? 0, forKey: "selectedBrowserTab")
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
        if folders.folders.isEmpty {
            tabs.removeAll()
            newTab()
        }
        persistTabs()
    }

    func navigate(to url: URL) {
        dismissSearch()
        browser?.navigate(to: url, previewsFileSelection: false)
        persistTabs()
    }

    func beginSearch() {
        isSearchPresented = true
        searchFocusToken += 1
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
        for tab in tabs { tab.applyPreferenceChange() }
    }

    func perform(_ command: BrowserCommand) {
        switch command {
        case .search: beginSearch()
        case .goToFolder: isFolderPickerPresented = true
        case .newTab: newTab()
        case .closeTab: if let selectedTabID { closeTab(selectedTabID) }
        case .settings: isPreferencesPresented = true
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

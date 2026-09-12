import Foundation
import Observation

/// Browser preferences have their own app domain, independent of Topside.
@MainActor
@Observable
final class BrowserPreferences {
    @ObservationIgnored private let defaults: UserDefaults

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
        showHiddenFiles = defaults.bool(forKey: "browserShowHiddenFiles")
        showItemSizes = defaults.bool(forKey: "browserShowItemSizes")
        sortOrder = defaults.string(forKey: "browserSortOrder")
            .flatMap(BrowserSort.init(rawValue:)) ?? .name
    }
}

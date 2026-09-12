import Foundation

extension UserDefaults {
    /// Reads directory paths as standardized file URLs.
    func standardizedFileURLs(forKey key: String) -> [URL] {
        (array(forKey: key) as? [String] ?? []).map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
    }

    /// Stores standardized directory paths without bookmark or access metadata.
    func setStandardizedFileURLs(_ urls: [URL], forKey key: String) {
        set(urls.map(\.standardizedFileURL.path), forKey: key)
    }
}

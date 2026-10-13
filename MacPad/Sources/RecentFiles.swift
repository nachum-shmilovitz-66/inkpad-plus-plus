import Foundation

/// The File ▸ Recent Files list: most recent first, no duplicates, bounded length.
struct RecentFiles: Equatable {
    /// Notepad++ keeps 10 by default.
    static let capacity = 10

    private(set) var paths: [String] = []

    init(paths: [String] = []) {
        self.paths = Array(paths.filter { !$0.isEmpty }.uniqued().prefix(RecentFiles.capacity))
    }

    var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }
    var isEmpty: Bool { paths.isEmpty }

    /// Opening or saving a file moves it to the front; the oldest entry falls off the end.
    mutating func record(_ path: String) {
        guard !path.isEmpty else { return }
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > RecentFiles.capacity { paths.removeLast(paths.count - RecentFiles.capacity) }
    }

    /// Used when an entry turns out to be gone from disk.
    mutating func remove(_ path: String) {
        paths.removeAll { $0 == path }
    }

    mutating func clear() {
        paths.removeAll()
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// The recent-files list as the app sees it, backed by user defaults.
final class RecentFilesStore {
    static let shared = RecentFilesStore()

    private let defaults: UserDefaults
    private let key: String
    private(set) var files: RecentFiles

    init(defaults: UserDefaults = AppEnvironment.defaults, key: String = "RecentFiles") {
        self.defaults = defaults
        self.key = key
        files = RecentFiles(paths: defaults.stringArray(forKey: key) ?? [])
    }

    func record(_ url: URL) {
        files.record(url.standardizedFileURL.path)
        flush()
    }

    func remove(_ url: URL) {
        files.remove(url.standardizedFileURL.path)
        flush()
    }

    func clear() {
        files.clear()
        flush()
    }

    private func flush() {
        defaults.set(files.paths, forKey: key)
    }
}

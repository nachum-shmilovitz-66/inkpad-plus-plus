import Foundation

/// Notepad++'s theme selection (MAC-36): "Default (stylers.xml)" plus every theme file in the
/// bundled themes folder and in the user's themes folder (Notepad++ themes import as they are).
/// The choice is remembered; a change is announced so every editor and panel repaints.
final class ThemeManager {
    static let shared = ThemeManager()
    static let didChange = Notification.Name("MacPadThemeDidChange")
    static let defaultName = "Default (stylers.xml)"

    struct Entry: Equatable {
        let name: String
        let url: URL?
    }

    private let defaults: UserDefaults
    private let bundledDirectory: URL?
    let userDirectory: URL
    /// The user's own stylers.xml (written by the Style Configurator), else Notepad++'s model.
    private let userStylers: URL
    private var cache: [URL: StyleTheme] = [:]
    private static let selectionKey = "SelectedTheme"

    init(defaults: UserDefaults = AppEnvironment.defaults,
         bundledDirectory: URL? = NppData.url("themes"),
         supportDirectory: URL = AppEnvironment.supportDirectory) {
        self.defaults = defaults
        self.bundledDirectory = bundledDirectory
        userDirectory = supportDirectory.appendingPathComponent("themes", isDirectory: true)
        userStylers = supportDirectory.appendingPathComponent("stylers.xml")
    }

    /// Default first, then the themes by name; a user theme replaces a bundled one of the same name.
    var available: [Entry] {
        var byName: [String: URL] = [:]
        for directory in [bundledDirectory, userDirectory].compactMap({ $0 }) {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension.lowercased() == "xml" {
                byName[file.deletingPathExtension().lastPathComponent] = file
            }
        }
        let themes = byName.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { Entry(name: $0, url: byName[$0]) }
        return [Entry(name: Self.defaultName, url: defaultURL)] + themes
    }

    private var defaultURL: URL? {
        FileManager.default.fileExists(atPath: userStylers.path) ? userStylers : NppData.url("stylers.model.xml")
    }

    /// The chosen theme's name; a theme that has gone away falls back to Default.
    var selectedName: String {
        let name = defaults.string(forKey: Self.selectionKey) ?? Self.defaultName
        return available.contains { $0.name == name } ? name : Self.defaultName
    }

    /// The Style Configurator's unsaved edits, shown live everywhere until Save or Cancel.
    private(set) var previewTheme: StyleTheme?

    var current: StyleTheme { previewTheme ?? theme(named: selectedName) }

    func preview(_ theme: StyleTheme?) {
        previewTheme = theme
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    func url(of name: String) -> URL? { available.first { $0.name == name }?.url }

    /// Where the Style Configurator saves a theme: Default in the user's stylers.xml, any other
    /// theme in the user's themes folder (a bundled theme is copied there, never edited in place).
    func savePath(for name: String) -> URL {
        name == Self.defaultName ? userStylers : userDirectory.appendingPathComponent(name + ".xml")
    }

    func theme(named name: String) -> StyleTheme {
        let url = available.first { $0.name == name }?.url ?? defaultURL
        guard let url else { return StyleTheme.default }
        if let cached = cache[url] { return cached }
        let theme = StyleTheme(url: url)
        cache[url] = theme
        return theme
    }

    func select(_ name: String) {
        let changed = name != selectedName
        defaults.set(name, forKey: Self.selectionKey)
        if changed { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    /// A theme file changed on disk (the Style Configurator saved it): read it again.
    func reload() {
        cache.removeAll()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

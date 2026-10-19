import Foundation

// MAC-78 legacy migration. Inkpad++ was called MacPad++ up to 1.1.3. On the first launch under the
// new name, the old preferences domain and Application Support folder are copied over, so settings,
// themes, macros, shortcuts, the session and Recent Files carry on. The old name appears only here,
// in the legacy block of scripts/pkg/postinstall and in their tests: delete them together once no
// MacPad++ installs are left.
enum LegacyMigration {
    static let oldFolderName = "MacPad++"
    static let doneKey = "LegacyMigrationDone"
    private static let newIDPrefix = "app.inkpad.Inkpad"
    private static let oldIDPrefix = "app.macpad.MacPad"

    /// The old preferences domain of this build: app.inkpad.Inkpad → app.macpad.MacPad, and
    /// app.inkpad.Inkpad.debug → app.macpad.MacPad.debug. Nil for anything else.
    static func legacyDomain(for bundleID: String) -> String? {
        guard bundleID.hasPrefix(newIDPrefix) else { return nil }
        return oldIDPrefix + bundleID.dropFirst(newIDPrefix.count)
    }

    /// A key under its new name: the window frame and the toolbar layout carry the app's name.
    static func renamedKey(_ key: String) -> String {
        key.replacingOccurrences(of: "MacPad", with: "Inkpad")
    }

    /// Copies the old domain into `defaults`, once. A key the new install already has wins.
    /// Returns how many keys were copied.
    @discardableResult
    static func migrateDefaults(from old: [String: Any]?, into defaults: UserDefaults) -> Int {
        guard !defaults.bool(forKey: doneKey) else { return 0 }
        defer { defaults.set(true, forKey: doneKey) }
        var copied = 0
        for (key, value) in old ?? [:] {
            let newKey = renamedKey(key)
            guard defaults.object(forKey: newKey) == nil else { continue }
            defaults.set(value, forKey: newKey)
            copied += 1
        }
        return copied
    }

    /// Copies the old Application Support folder while the new one does not exist yet.
    @discardableResult
    static func migrateSupportFolder(old: URL, new: URL, fileManager: FileManager = .default) -> Bool {
        guard !fileManager.fileExists(atPath: new.path), fileManager.fileExists(atPath: old.path) else { return false }
        do {
            try fileManager.copyItem(at: old, to: new)
            return true
        } catch {
            AppEnvironment.log.error("could not copy the old settings folder: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// At launch, before anything reads the settings. Never under test or in a manual check.
    static func run() {
        guard !AppEnvironment.isRunningTests, let bundleID = Bundle.main.bundleIdentifier,
              let domain = legacyDomain(for: bundleID) else { return }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: doneKey) {
            let copied = migrateDefaults(from: defaults.persistentDomain(forName: domain), into: defaults)
            if copied > 0 { AppEnvironment.log.notice("carried over \(copied) settings from the previous name") }
        }
        let support = AppEnvironment.supportDirectory
        migrateSupportFolder(old: support.deletingLastPathComponent().appendingPathComponent(oldFolderName), new: support)
    }
}

import AppKit

/// Where the app keeps its per-user state, and whether it is the unit tests' host.
///
/// The tests run inside the app, which has the installed MacPad++'s bundle id — so without this,
/// every test that opens a file would land in the user's Recent Files, and the test host would
/// restore and overwrite the user's session (MAC-23).
enum AppEnvironment {
    /// The unit tests' host — or a manual check launched with MACPAD_ISOLATED_STORAGE=1
    /// (`open --env MACPAD_ISOLATED_STORAGE=1 -a …`), which must not touch the user's data either.
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil
            || env["MACPAD_ISOLATED_STORAGE"] == "1"
    }()

    /// Recent Files storage: the real defaults, or a private suite (emptied at launch) under test.
    static let defaults: UserDefaults = {
        guard isRunningTests else { return .standard }
        let suite = "app.macpad.MacPad.tests"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }()

    /// The clipboard for MacPad++'s own copy commands (Copy Marked Text, bookmarked lines): a
    /// private pasteboard under test, so the tests never overwrite what the user copied.
    static let pasteboard: NSPasteboard = isRunningTests
        ? NSPasteboard(name: NSPasteboard.Name("app.macpad.MacPad.tests.pasteboard")) : .general

    /// Folder for session.json: Application Support, or a throwaway temp folder under test.
    static let supportDirectory: URL = {
        if isRunningTests {
            return FileManager.default.temporaryDirectory.appendingPathComponent("MacPad++Tests-\(ProcessInfo.processInfo.processIdentifier)")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MacPad++")
    }()

    /// Adds a file to macOS's recent documents (Dock menu, Open Recent) — never from the tests.
    static func noteRecentDocument(_ url: URL) {
        guard !isRunningTests else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }
}

import XCTest
@testable import MacPad

/// MAC-23: the test host must never touch the user's Recent Files or session.
final class AppEnvironmentTests: XCTestCase {
    func testTheTestHostIsDetected() {
        XCTAssertTrue(AppEnvironment.isRunningTests)
    }

    func testSessionLivesInATempFolderUnderTest() {
        XCTAssertFalse(SessionStore.defaultURL.path.contains("/Library/Application Support/"))
        XCTAssertTrue(SessionStore.defaultURL.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    func testRecentFilesUseAPrivateSuiteUnderTest() {
        XCTAssertFalse(AppEnvironment.defaults === UserDefaults.standard)
    }

    func testOpeningAFileInATestLeavesTheUsersRecentFilesAlone() throws {
        let realBefore = UserDefaults.standard.stringArray(forKey: "RecentFiles")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("env-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let tab = EditorTab(untitledNumber: 1)
        try tab.load(url)

        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "RecentFiles"), realBefore,
                       "the user's real Recent Files must not change")
        XCTAssertTrue(RecentFilesStore.shared.files.paths.contains(url.standardizedFileURL.path),
                      "the test host's own list still works")
    }
}

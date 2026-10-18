import XCTest
@testable import MacPad

/// MAC-66: the visible app name comes from the bundle (APP_DISPLAY_NAME), MacPad++ by default.
final class AppNameTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func testDisplayNameIsPreferred() {
        XCTAssertEqual(AppName.resolve(localized: nil, info: ["CFBundleDisplayName": "Notepad++", "CFBundleName": "MacPad++"]), "Notepad++")
    }

    func testBundleNameIsTheFallbackKey() {
        XCTAssertEqual(AppName.resolve(localized: nil, info: ["CFBundleName": "Other"]), "Other")
        XCTAssertEqual(AppName.resolve(localized: nil, info: ["CFBundleDisplayName": "  ", "CFBundleName": "Other"]), "Other")
    }

    func testMissingEmptyOrUnexpandedNamesFallBackToMacPad() {
        XCTAssertEqual(AppName.resolve(localized: nil, info: nil), "MacPad++")
        XCTAssertEqual(AppName.resolve(localized: nil, info: [:]), "MacPad++")
        XCTAssertEqual(AppName.resolve(localized: nil, info: ["CFBundleDisplayName": "", "CFBundleName": ""]), "MacPad++")
        XCTAssertEqual(AppName.resolve(localized: nil, info: ["CFBundleDisplayName": "$(APP_DISPLAY_NAME)"]), "MacPad++")
    }

    func testNamesAreTrimmed() {
        XCTAssertEqual(AppName.resolve(localized: nil, info: ["CFBundleDisplayName": " Notepad++\n"]), "Notepad++")
    }

    func testLocalizedNameWins() {
        XCTAssertEqual(AppName.resolve(localized: ["CFBundleDisplayName": "Notepad++"],
                                       info: ["CFBundleDisplayName": "MacPad++", "CFBundleName": "MacPad++"]), "Notepad++")
        XCTAssertEqual(AppName.resolve(localized: [:], info: ["CFBundleDisplayName": "MacPad++"]), "MacPad++")
    }

    func testTheBuiltAppUsesItsLocalizedName() {
        XCTAssertEqual(AppName.display, Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
        XCTAssertEqual(Bundle.main.localizedInfoDictionary?["CFBundleName"] as? String, AppName.display,
                       "menu bar and Dock agree")
    }

    /// Finder ignores the localized name when Info.plist's name differs from the file name.
    func testInfoPlistNameMatchesTheFileName() {
        let info = Bundle.main.infoDictionary
        XCTAssertEqual(info?["CFBundleDisplayName"] as? String, "MacPad++")
        XCTAssertEqual(info?["CFBundleName"] as? String, "MacPad++")
        XCTAssertEqual(Bundle.main.bundleURL.deletingPathExtension().lastPathComponent, "MacPad++")
    }

    /// Finder, the Dock and Spotlight read the localized name, not the .app file name.
    func testFinderSeesTheLocalizedName() throws {
        XCTAssertEqual(Bundle.main.infoDictionary?["LSHasLocalizedDisplayName"] as? Bool, true)
        let strings = try XCTUnwrap(Bundle.main.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil,
                                                    localization: "en"))
        let table = try XCTUnwrap(NSDictionary(contentsOf: strings) as? [String: String])
        XCTAssertEqual(table["CFBundleDisplayName"], AppName.display)
        XCTAssertEqual(table["CFBundleName"], AppName.display)
    }

    func testAppMenuUsesTheDisplayName() {
        let titles = (MainMenu.build().items.first?.submenu?.items ?? []).map(\.title)
        for title in ["About", "Hide", "Quit"] {
            XCTAssertTrue(titles.contains("\(title) \(AppName.display)"), "\(title) item in \(titles)")
        }
        XCTAssertTrue(titles.contains("Uninstall \(AppName.display)…"))
        XCTAssertFalse(titles.contains { $0.contains("MacPad++") && !$0.contains(AppName.display) }, "no hard-coded name")
    }

    func testUserFacingTextUsesTheDisplayName() {
        XCTAssertEqual(Uninstaller.prompt, "\(AppName.display) needs administrator rights to uninstall itself.")
        XCTAssertTrue(TextFile.TooLarge(size: 1).errorDescription?.contains("opened by \(AppName.display)") ?? false)
    }

    /// The repo's default stays MacPad++: "Notepad++" is Don Ho's trademark (CLAUDE.md), so only a
    /// personal, gitignored Config/Local.xcconfig may change it.
    func testCheckedInDefaultIsMacPad() throws {
        let config = try String(contentsOf: repo.appendingPathComponent("Config/App.xcconfig"), encoding: .utf8)
        XCTAssertTrue(config.contains("\nAPP_DISPLAY_NAME = MacPad++\n"))
        XCTAssertTrue(config.contains("#include? \"Local.xcconfig\""))
        let ignore = try String(contentsOf: repo.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertTrue(ignore.split(separator: "\n").contains("Config/Local.xcconfig"))
        let plist = try String(contentsOf: repo.appendingPathComponent("MacPad/Info.plist"), encoding: .utf8)
        XCTAssertFalse(plist.contains("Notepad++</string>"))
    }

    /// MAC-67: a Debug build (the test host) is never named like the installed app, whatever
    /// Config/Local.xcconfig says — a test copy in the Dock looked like the user's editor, "stuck".
    func testDebugBuildsHaveTheirOwnName() throws {
        let config = try String(contentsOf: repo.appendingPathComponent("Config/Debug.xcconfig"), encoding: .utf8)
        XCTAssertTrue(config.contains("#include \"App.xcconfig\""))
        XCTAssertTrue(config.contains("\nAPP_DISPLAY_NAME = MacPad++ Debug\n"))
        #if DEBUG
        XCTAssertEqual(AppName.display, "MacPad++ Debug")
        #endif
    }

    /// Internal identifiers never follow the visible name.
    func testIdentifiersStayMacPad() {
        XCTAssertTrue(Bundle.main.bundleIdentifier?.hasPrefix("app.macpad.MacPad") ?? false)
        XCTAssertEqual(Bundle.main.bundleURL.lastPathComponent, "MacPad++.app")
        XCTAssertEqual(WindowPlacement.autosaveName, "MacPad++ Main Window")
    }
}

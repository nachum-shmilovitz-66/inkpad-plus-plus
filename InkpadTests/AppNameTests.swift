import XCTest
@testable import Inkpad

/// MAC-66: the visible app name comes from the bundle (APP_DISPLAY_NAME), Inkpad++ by default.
final class AppNameTests: XCTestCase {
    private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func testDisplayNameIsPreferred() {
        XCTAssertEqual(AppName.resolve(localized: nil, info: ["CFBundleDisplayName": "upstream", "CFBundleName": "Inkpad++"]), "upstream")
    }

    func testBundleNameIsTheFallbackKey() {
        XCTAssertEqual(AppName.resolve(localized: nil, info: ["CFBundleName": "Other"]), "Other")
        XCTAssertEqual(AppName.resolve(localized: nil, info: ["CFBundleDisplayName": "  ", "CFBundleName": "Other"]), "Other")
    }

    func testMissingEmptyOrUnexpandedNamesFallBackToInkpad() {
        XCTAssertEqual(AppName.resolve(localized: nil, info: nil), "Inkpad++")
        XCTAssertEqual(AppName.resolve(localized: nil, info: [:]), "Inkpad++")
        XCTAssertEqual(AppName.resolve(localized: nil, info: ["CFBundleDisplayName": "", "CFBundleName": ""]), "Inkpad++")
        XCTAssertEqual(AppName.resolve(localized: nil, info: ["CFBundleDisplayName": "$(APP_DISPLAY_NAME)"]), "Inkpad++")
    }

    func testNamesAreTrimmed() {
        XCTAssertEqual(AppName.resolve(localized: nil, info: ["CFBundleDisplayName": " upstream\n"]), "upstream")
    }

    func testLocalizedNameWins() {
        XCTAssertEqual(AppName.resolve(localized: ["CFBundleDisplayName": "upstream"],
                                       info: ["CFBundleDisplayName": "Inkpad++", "CFBundleName": "Inkpad++"]), "upstream")
        XCTAssertEqual(AppName.resolve(localized: [:], info: ["CFBundleDisplayName": "Inkpad++"]), "Inkpad++")
    }

    func testTheBuiltAppUsesItsLocalizedName() {
        XCTAssertEqual(AppName.display, Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
        XCTAssertEqual(Bundle.main.localizedInfoDictionary?["CFBundleName"] as? String, AppName.display,
                       "menu bar and Dock agree")
    }

    /// Finder ignores the localized name when Info.plist's name differs from the file name.
    func testInfoPlistNameMatchesTheFileName() {
        let info = Bundle.main.infoDictionary
        XCTAssertEqual(info?["CFBundleDisplayName"] as? String, "Inkpad++")
        XCTAssertEqual(info?["CFBundleName"] as? String, "Inkpad++")
        XCTAssertEqual(Bundle.main.bundleURL.deletingPathExtension().lastPathComponent, "Inkpad++")
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
        XCTAssertFalse(titles.contains { $0.contains("Inkpad++") && !$0.contains(AppName.display) }, "no hard-coded name")
    }

    func testUserFacingTextUsesTheDisplayName() {
        XCTAssertEqual(Uninstaller.prompt, "\(AppName.display) needs administrator rights to uninstall itself.")
        XCTAssertTrue(TextFile.TooLarge(size: 1).errorDescription?.contains("opened by \(AppName.display)") ?? false)
    }

    /// The repo's default stays Inkpad++: "upstream" is Don Ho's trademark (CLAUDE.md), so only a
    /// personal, gitignored Config/Local.xcconfig may change it.
    func testCheckedInDefaultIsInkpad() throws {
        let config = try String(contentsOf: repo.appendingPathComponent("Config/App.xcconfig"), encoding: .utf8)
        XCTAssertTrue(config.contains("\nAPP_DISPLAY_NAME = Inkpad++\n"))
        XCTAssertTrue(config.contains("#include? \"Local.xcconfig\""))
        let ignore = try String(contentsOf: repo.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertTrue(ignore.split(separator: "\n").contains("Config/Local.xcconfig"))
        let plist = try String(contentsOf: repo.appendingPathComponent("Inkpad/Info.plist"), encoding: .utf8)
        XCTAssertFalse(plist.contains("upstream</string>"))
    }

    /// MAC-67: a Debug build (the test host) is never named like the installed app, whatever
    /// Config/Local.xcconfig says — a test copy in the Dock looked like the user's editor, "stuck".
    func testDebugBuildsHaveTheirOwnName() throws {
        let config = try String(contentsOf: repo.appendingPathComponent("Config/Debug.xcconfig"), encoding: .utf8)
        XCTAssertTrue(config.contains("#include \"App.xcconfig\""))
        XCTAssertTrue(config.contains("\nAPP_DISPLAY_NAME = Inkpad++ Debug\n"))
        #if DEBUG
        XCTAssertEqual(AppName.display, "Inkpad++ Debug")
        #endif
    }

    /// Internal identifiers never follow the visible name.
    func testIdentifiersStayInkpad() {
        XCTAssertTrue(Bundle.main.bundleIdentifier?.hasPrefix("app.inkpad.Inkpad") ?? false)
        XCTAssertEqual(Bundle.main.bundleURL.lastPathComponent, "Inkpad++.app")
        XCTAssertEqual(WindowPlacement.autosaveName, "Inkpad++ Main Window")
    }
}

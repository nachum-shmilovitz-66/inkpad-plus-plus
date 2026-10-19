import XCTest
@testable import Inkpad

/// MAC-36: theme selection.
final class ThemeManagerTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private let suite = "app.inkpad.Inkpad.tests.themes"

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("InkpadThemes-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("bundled"), withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
        ThemeManager.shared.select(ThemeManager.defaultName)
        super.tearDown()
    }

    private func theme(_ name: String, in folder: String, background: String = "000000") {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let xml = """
            <?xml version="1.0" encoding="UTF-8" ?>
            <NotepadPlus><LexerStyles/><GlobalStyles>
            <WidgetStyle name="Default Style" styleID="32" fgColor="FFFFFF" bgColor="\(background)" fontName="Courier New" fontSize="10" />
            </GlobalStyles></NotepadPlus>
            """
        try? Data(xml.utf8).write(to: dir.appendingPathComponent(name + ".xml"))
    }

    private func manager() -> ThemeManager {
        ThemeManager(defaults: defaults, bundledDirectory: root.appendingPathComponent("bundled"), supportDirectory: root)
    }

    func testDefaultFirstThenThemesByNameWithUserThemesWinning() {
        theme("Zenburn", in: "bundled")
        theme("bespin", in: "bundled")
        theme("Monokai", in: "themes")
        try? Data("x".utf8).write(to: root.appendingPathComponent("bundled/readme.txt"))
        let m = manager()
        XCTAssertEqual(m.available.map(\.name), [ThemeManager.defaultName, "bespin", "Monokai", "Zenburn"],
                       "Default first, then by name ignoring case; not-XML files ignored")
        theme("Zenburn", in: "themes", background: "333333")
        XCTAssertEqual(m.available.first { $0.name == "Zenburn" }?.url?.deletingLastPathComponent().lastPathComponent, "themes",
                       "a user theme replaces the bundled one of the same name")
    }

    func testSelectionIsRememberedAndAnnounced() {
        theme("Twilight", in: "bundled", background: "141414")
        let m = manager()
        XCTAssertEqual(m.selectedName, ThemeManager.defaultName)
        let changed = expectation(forNotification: ThemeManager.didChange, object: m)
        m.select("Twilight")
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(manager().selectedName, "Twilight", "kept across launches")
        XCTAssertEqual(m.current.global("Default Style")?.background, scintillaColour(fromHex: "141414"))
    }

    func testAMissingThemeFallsBackToDefault() {
        defaults.set("Gone", forKey: "SelectedTheme")
        XCTAssertEqual(manager().selectedName, ThemeManager.defaultName)
    }

    func testTheBundledUpstreamThemesAreListed() {
        let names = ThemeManager.shared.available.map(\.name)
        for name in ["Monokai", "Obsidian", "Solarized", "DarkModeDefault", "Zenburn"] {
            XCTAssertTrue(names.contains(name), name)
        }
        XCTAssertEqual(names.first, ThemeManager.defaultName)
    }

    func testChangingTheThemeRepaintsOpenEditors() throws {
        let window = MainWindowController()
        let tab = window.newTab()
        let defaultBack = tab.editor.send(SCI_STYLEGETBACK, Int(STYLE_DEFAULT))
        ThemeManager.shared.select("Monokai")
        let monokai = try XCTUnwrap(ThemeManager.shared.current.global("Default Style")?.background)
        XCTAssertEqual(tab.editor.send(SCI_STYLEGETBACK, Int(STYLE_DEFAULT)), monokai)
        XCTAssertNotEqual(monokai, defaultBack)
        XCTAssertEqual(window.searchResults.pane.send(SCI_STYLEGETBACK, Int(STYLE_DEFAULT)), monokai, "the results panel too")
        ThemeManager.shared.select(ThemeManager.defaultName)
        XCTAssertEqual(tab.editor.send(SCI_STYLEGETBACK, Int(STYLE_DEFAULT)), defaultBack)
        window.openTabs.forEach { $0.detach() }
    }

    func testTheThemeMenuTicksTheSelection() {
        ThemeManager.shared.select("Obsidian")
        let menu = NSMenu(title: "Theme")
        MainMenu.fillThemeMenu(menu)
        XCTAssertEqual(menu.items.first?.title, ThemeManager.defaultName)
        XCTAssertEqual(menu.items.first { $0.state == .on }?.title, "Obsidian")
        XCTAssertEqual(menu.items.last?.title, "Open Themes Folder…")
    }
}

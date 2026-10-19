import XCTest
@testable import Inkpad

/// MAC-35: the Language menu.
final class LanguageMenuTests: XCTestCase {
    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { $0.submenu.map(allItems) ?? [$0] }
    }

    func testTheMenuIsUpstreamCompactMenu() {
        let menu = MainMenu.languageMenu()
        XCTAssertEqual(menu.items.first?.title, "None (Normal Text)")
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertEqual(menu.items[2].title, "A")
        XCTAssertEqual(menu.items[2].submenu?.items.map(\.title),
                       ["ActionScript", "Ada", "ASN.1", "ASP", "Assembly", "AutoIt", "AviSynth"])
        XCTAssertNotNil(menu.items.first { $0.title == "KIXtart" && $0.submenu == nil }, "a letter with one language is a plain item")
        XCTAssertEqual(menu.items.last?.title, "YAML")
        XCTAssertNil(allItems(menu).first { $0.title.contains("User") }, "no User Defined Language yet")
    }

    func testEveryItemNamesAKnownLanguageAndEveryLexedLanguageIsListed() {
        let names = allItems(MainMenu.languageMenu()).compactMap { $0.representedObject as? String }
        XCTAssertEqual(names.count, 93, "upstream 8.9.8.1: 97 Language entries, less the 4 User Defined Language ones")
        for name in names {
            XCTAssertNotNil(LanguageCatalog.shared.language(named: name), name)
        }
        XCTAssertEqual(Set(names).count, names.count, "no duplicates")
        for wanted in ["c", "cpp", "python", "javascript.js", "json", "bash", "xml", "yaml", "swift", "rust", "sql"] {
            XCTAssertTrue(names.contains(wanted), wanted)
        }
    }

    func testChoosingALanguageReLexesTheTab() {
        let tab = EditorTab(untitledNumber: 1)
        tab.editor.setUTF8Bytes(Data("int x;".utf8))
        XCTAssertEqual(tab.language.name, "normal")
        let python = LanguageCatalog.shared.language(named: "python")!
        tab.setLanguage(python)
        XCTAssertEqual(tab.language.name, "python")
        XCTAssertEqual(tab.editor.send(SCI_GETLEXER), Int(SCLEX_PYTHON))
        tab.detach()
    }

    func testTheWindowMenuActionTicksTheCurrentLanguage() {
        let window = MainWindowController()
        let tab = window.newTab()
        let item = NSMenuItem(title: "C++", action: #selector(MainWindowController.selectLanguage(_:)), keyEquivalent: "")
        item.representedObject = "cpp"
        window.selectLanguage(item)
        XCTAssertEqual(tab.language.name, "cpp")
        XCTAssertTrue(window.validateMenuItem(item))
        XCTAssertEqual(item.state, .on)
        let other = NSMenuItem(title: "C", action: #selector(MainWindowController.selectLanguage(_:)), keyEquivalent: "")
        other.representedObject = "c"
        _ = window.validateMenuItem(other)
        XCTAssertEqual(other.state, .off)
        window.openTabs.forEach { $0.detach() }
    }

    func testTheChosenLanguageSurvivesInTheSession() throws {
        let doc = SessionState.Document(path: "/tmp/notes.txt", language: "sql")
        let data = try JSONEncoder().encode(SessionState(documents: [doc]))
        XCTAssertEqual(try JSONDecoder().decode(SessionState.self, from: data).documents.first?.language, "sql")
        let old = #"{"version":1,"activeIndex":0,"documents":[{"path":"/tmp/x.txt","caretPosition":0,"firstVisibleLine":0}]}"#
        XCTAssertNil(try JSONDecoder().decode(SessionState.self, from: Data(old.utf8)).documents.first?.language)
    }

    func testRestoringASessionAppliesTheLanguage() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("InkpadLang-\(UUID().uuidString).txt")
        try Data("select 1;".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let window = MainWindowController()
        XCTAssertTrue(window.restore(SessionState(documents: [SessionState.Document(path: url.path, language: "sql")])))
        XCTAssertEqual(window.activeTab?.language.name, "sql")
        XCTAssertEqual(window.captureSession().documents.first?.language, "sql")
        window.openTabs.forEach { $0.detach() }
    }

    func testEveryListedLanguageHasALexerInThisBuild() {
        let tab = EditorTab(untitledNumber: 1)
        var missing: [String] = []
        for name in allItems(MainMenu.languageMenu()).compactMap({ $0.representedObject as? String }) {
            guard let info = LanguageCatalog.shared.language(named: name), info.lexer != "null" else { continue }
            tab.setLanguage(info)
            let length = tab.editor.send(SCI_GETLEXERLANGUAGE)
            var buffer = [CChar](repeating: 0, count: length + 1)
            buffer.withUnsafeMutableBytes { _ = tab.editor.send(SCI_GETLEXERLANGUAGE, 0, pointer: $0.baseAddress) }
            // Case-insensitive: LexD calls itself "D". PHP is lexed as HTML (LexerRecipe).
            let expected = LexerRecipe.recipe(for: name).lexer ?? info.lexer
            if String(cString: buffer).lowercased() != expected.lowercased() { missing.append("\(name) (\(expected))") }
        }
        XCTAssertEqual(missing, [], "languages whose Lexilla lexer is not built in")
        tab.detach()
    }
}

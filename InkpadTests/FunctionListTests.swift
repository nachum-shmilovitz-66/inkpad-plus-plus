import XCTest
@testable import Inkpad

/// MAC-44: the Function List parsers, checked against upstream's own unit-test fixtures
/// (PowerEditor/Test/FunctionList/<lang>/unitTest + unitTest.expected.result).
final class FunctionListTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("vendor/upstream/PowerEditor/Test/FunctionList")

    private func editor(_ data: Data) -> ScintillaView {
        let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
        v.setUTF8Bytes(TextFile.decode(data).utf8)
        return v
    }

    /// Our tree for a fixture, in the export's shape, next to upstream's expected result.
    private func compare(_ language: String, folder: String? = nil) throws -> (Any, Any) {
        let dir = Self.fixtures.appendingPathComponent(folder ?? language)
        // upstream made the expected results from a Windows checkout, where these files have CRLF
        // line endings — except those whose results show a bare "\n" (nim). This checkout has LF.
        let expectedText = try String(contentsOf: dir.appendingPathComponent("unitTest.expected.result"), encoding: .utf8)
        let lfOnly = expectedText.contains("\\n") && !expectedText.contains("\\r\\n")
        let lf = String(decoding: try Data(contentsOf: dir.appendingPathComponent("unitTest")), as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
        let source = Data((lfOnly ? lf : lf.replacingOccurrences(of: "\n", with: "\r\n")).utf8)
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("unitTest.expected.result")))
        let def = try XCTUnwrap(FunctionParserDefinition.forLanguage(language), "no parser for \(language)")
        let entries = FunctionListParser(editor: editor(source), definition: def).parse()
        let tree = FunctionTree(root: "unitTest", entries: entries)
        let ours = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: tree.json))
        return (ours, expected)
    }

    func testEveryUpstreamFixtureMatches() throws {
        let languages = ["ada", "asm", "autoit", "bash", "batch", "c", "cpp", "cs", "css", "d", "fortran", "fortran77", "gdscript",
                         "haskell", "hollywood", "ini", "inno", "java", "latex", "lua", "makefile", "nim", "nsis", "pascal",
                         "perl", "php", "powershell", "python", "raku", "ruby", "rust", "sas", "sql", "tex", "toml",
                         "typescript", "vb", "vhdl", "xml"]
        var failures: [String] = []
        for language in languages {
            guard FileManager.default.fileExists(atPath: Self.fixtures.appendingPathComponent(language).path) else { continue }
            let (ours, expected) = try compare(language)
            if !(ours as AnyObject).isEqual(expected) { failures.append(language) }
        }
        let (js, jsExpected) = try compare("javascript.js", folder: "javascript")
        if !(js as AnyObject).isEqual(jsExpected) { failures.append("javascript") }
        XCTAssertEqual(failures, [], "fixtures whose tree differs from upstream's")
    }

    func testParserDefinitions() throws {
        let cpp = try XCTUnwrap(FunctionParserDefinition.forLanguage("cpp"))
        XCTAssertEqual(cpp.id, "cplusplus_syntax")
        XCTAssertNotNil(cpp.classRange, "C++ is a mixed parser")
        XCTAssertNotNil(cpp.function)
        XCTAssertNil(FunctionParserDefinition.forLanguage("json"), "no parser: an empty panel")
        XCTAssertEqual(FunctionParserDefinition.forLanguage("javascript")?.id, "javascript_function", "embedded JS uses JavaScript's")
    }

    func testTreeSortingAndSearch() {
        let entries = [FunctionEntry(name: "zeta", className: "", position: 10),
                       FunctionEntry(name: "beta", className: "K", position: 5),
                       FunctionEntry(name: "Alpha", className: "", position: 30),
                       FunctionEntry(name: "gamma", className: "K", position: 1)]
        let tree = FunctionTree(root: "f", entries: entries)
        XCTAssertEqual(tree.items.count, 3, "K holds both of its methods")
        let alpha = tree.sorted(alphabetically: true)
        XCTAssertEqual(alpha.leaves.map(\.name), ["Alpha", "beta", "gamma", "zeta"])
        let natural = tree.sorted(alphabetically: false)
        XCTAssertEqual(natural.leaves.map(\.name), ["gamma", "beta", "zeta", "Alpha"], "class K sorts by its first method's position")
        XCTAssertEqual(tree.filtered("ET").leaves.map(\.name), ["zeta", "beta"], "flat, ignoring case")
    }
}

/// MAC-44: the panel in the window.
final class FunctionListPanelTests: XCTestCase {
    func testThePanelParsesJumpsAndFollowsTheCaret() throws {
        let window = MainWindowController()
        let tab = window.newTab()
        tab.setLanguage(LanguageCatalog.shared.language(named: "python")!)
        tab.editor.setUTF8Bytes(Data("def alpha():\n    pass\n\nclass K:\n    def beta(self):\n        pass\n\ndef gamma():\n    pass\n".utf8))
        window.setFunctionListVisible(true)
        XCTAssertTrue(window.isFunctionListVisible)
        let tree = try XCTUnwrap(window.functionList.tree)
        XCTAssertEqual(tree.leaves.map(\.name), ["beta(self)", "alpha()", "gamma()"], "class methods first, as upstream adds them")
        XCTAssertEqual(window.functionList.outline.numberOfRows, 1 + 2 + 1, "root expanded: K, alpha, gamma; K collapsed")

        tab.editor.send(SCI_GOTOLINE, 8)
        window.functionList.markEntry(caretLine: 8)
        XCTAssertEqual(window.functionList.selectedTitle, "gamma()")
        tab.editor.send(SCI_GOTOLINE, 0)
        window.functionList.markEntry(caretLine: 0)
        XCTAssertEqual(window.functionList.selectedTitle, "alpha()")

        window.functionList.sortAlphabetically = true
        let row = (0..<window.functionList.outline.numberOfRows).first {
            (window.functionList.outline.item(atRow: $0) as? FunctionListPanel.Item)?.title == "gamma()"
        }!
        window.functionList.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        window.functionList.activateSelection(nil)
        XCTAssertEqual(tab.editor.send(SCI_LINEFROMPOSITION, tab.editor.send(SCI_GETCURRENTPOS)), 7)
        XCTAssertEqual(tab.editor.send(SCI_GETCURRENTPOS), tab.editor.send(SCI_POSITIONFROMLINE, 7) + 4, "at the name")

        window.functionList.searchField.stringValue = "ET"
        window.functionList.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertEqual(window.functionList.outline.numberOfRows, 2, "root + beta, flat")

        tab.setLanguage(LanguageCatalog.shared.language(named: "json")!)
        window.validateMenuItem(NSMenuItem())  // any refresh path
        window.reloadFunctionList()
        XCTAssertNil(window.functionList.tree, "no parser: an empty panel")
        window.setFunctionListVisible(false)
        XCTAssertFalse(window.isFunctionListVisible)
        window.openTabs.forEach { $0.detach() }
    }
}

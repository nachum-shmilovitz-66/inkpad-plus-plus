import XCTest
@testable import Inkpad

/// MAC-40: Convert Case, Indent, Comment/Uncomment, Copy to Clipboard, Read-Only, Begin/End Select.
final class EditCommandsTests: XCTestCase {
    private func editor(_ text: String) -> ScintillaView {
        let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
        v.send(SCI_SETTABWIDTH, 4)
        v.send(SCI_SETUSETABS, 0)
        v.setUTF8Bytes(Data(text.utf8))
        v.send(SCI_GOTOPOS, 0)
        return v
    }

    private func text(_ v: ScintillaView) -> String { String(decoding: v.utf8Bytes(), as: UTF8.self) }
    private func selectAll(_ v: ScintillaView) { v.send(SCI_SETSEL, 0, v.send(SCI_GETLENGTH)) }

    // MARK: Convert Case

    func testCaseConversions() {
        XCTAssertEqual(CaseConversion.upper.apply("straße é"), "STRAßE É", "one character to one (ß stays)")
        XCTAssertEqual(CaseConversion.lower.apply("ABC É"), "abc é")
        XCTAssertEqual(CaseConversion.invert.apply("aBc 1"), "AbC 1")
        XCTAssertEqual(CaseConversion.proper.apply("hello wORLD-wide don't 3d o'neil"), "Hello World-Wide Don't 3d O'neil")
        XCTAssertEqual(CaseConversion.properBlend.apply("iPHONE x"), "IPHONE X", "blend keeps the other letters")
        XCTAssertEqual(CaseConversion.sentence.apply("hELLO. how are you? i am fine. pi is 3.14 ok"),
                       "Hello. How are you? I am fine. Pi is 3.14 ok")
        XCTAssertEqual(CaseConversion.sentenceBlend.apply("hELLO wORLD. tEST"), "HELLO wORLD. TEST")
        XCTAssertEqual(CaseConversion.sentence.apply("one\n\ntwo\nthree"), "One\n\nTwo\nthree", "a blank line starts a sentence")
        let random = CaseConversion.random.apply("abcdefghij")
        XCTAssertEqual(random.lowercased(), "abcdefghij")
    }

    func testCaseConversionKeepsTheSelectionAndNeedsOne() {
        let v = editor("abc def")
        EditCommands(editor: v).convertCase(.upper)
        XCTAssertEqual(text(v), "abc def", "nothing selected: nothing changes")
        v.send(SCI_SETSEL, 4, 7)
        EditCommands(editor: v).convertCase(.upper)
        XCTAssertEqual(text(v), "abc DEF")
        XCTAssertEqual([v.send(SCI_GETSELECTIONSTART), v.send(SCI_GETSELECTIONEND)], [4, 7])
    }

    func testEachPieceOfAMultiSelectionOnItsOwn() {
        let v = editor("one two three")
        v.send(SCI_SETSELECTION, 0, 3)
        v.send(SCI_ADDSELECTION, 8, 13)
        EditCommands(editor: v).convertCase(.proper)
        XCTAssertEqual(text(v), "One two Three")
        XCTAssertEqual(v.send(SCI_GETSELECTIONS), 2)
    }

    // MARK: Indent

    func testIndentOneLineByATabWidth() {
        let v = editor("   x")
        v.send(SCI_GOTOPOS, 3)
        EditCommands(editor: v).indent(increase: true)
        XCTAssertEqual(text(v), "       x", "relative: 3 + 4, not snapped to a stop")
        XCTAssertEqual(v.send(SCI_GETCURRENTPOS), 7)
        EditCommands(editor: v).indent(increase: false)
        EditCommands(editor: v).indent(increase: false)
        XCTAssertEqual(text(v), "x", "never below zero")
    }

    func testIndentSeveralLinesUsesTab() {
        let v = editor("a\nb\nc")
        v.send(SCI_SETSEL, 0, 3)
        EditCommands(editor: v).indent(increase: true)
        XCTAssertEqual(text(v), "    a\n    b\nc")
    }

    // MARK: Comments

    private let cTokens = EditCommands.Tokens(line: "//", start: "/*", end: "*/")

    func testLineCommentAtTheIndentationSkippingBlankLines() {
        let v = editor("  int a;\n\n  int b;\nint c;")
        v.send(SCI_SETSEL, 0, 19)  // ends at column 0 of line 3: lines 0–2
        EditCommands(editor: v).lineComment(.comment, tokens: cTokens)
        XCTAssertEqual(text(v), "  // int a;\n\n  // int b;\nint c;")
        v.send(SCI_SETSEL, 0, v.send(SCI_GETLENGTH))
        EditCommands(editor: v).lineComment(.uncomment, tokens: cTokens)
        XCTAssertEqual(text(v), "  int a;\n\n  int b;\nint c;")
    }

    func testToggleWorksLineByLine() {
        let v = editor("// a\nb")
        selectAll(v)
        EditCommands(editor: v).lineComment(.toggle, tokens: cTokens)
        XCTAssertEqual(text(v), "a\n// b")
    }

    func testUncommentIgnoresCaseAndAMissingSpace() {
        let v = editor("REM x\nrem y\n//z")
        selectAll(v)
        EditCommands(editor: v).lineComment(.uncomment, tokens: EditCommands.Tokens(line: "rem"))
        XCTAssertEqual(text(v), "x\ny\n//z")
    }

    func testLanguagesWithoutALineTokenWrapEachLine() {
        let css = EditCommands.Tokens(line: nil, start: "/*", end: "*/")
        let v = editor("a {}\nb {}")
        selectAll(v)
        EditCommands(editor: v).lineComment(.comment, tokens: css)
        XCTAssertEqual(text(v), "/* a {} */\n/* b {} */")
        selectAll(v)
        EditCommands(editor: v).lineComment(.toggle, tokens: css)
        XCTAssertEqual(text(v), "a {}\nb {}")
    }

    func testBlockCommentAndUncomment() {
        let v = editor("x = 1 + 2;")
        v.send(SCI_SETSEL, 4, 9)
        EditCommands(editor: v).blockComment(tokens: cTokens)
        XCTAssertEqual(text(v), "x = /* 1 + 2 */;")
        XCTAssertEqual([v.send(SCI_GETSELECTIONSTART), v.send(SCI_GETSELECTIONEND)], [7, 12], "the original text stays selected")
        EditCommands(editor: v).blockUncomment(tokens: cTokens)
        XCTAssertEqual(text(v), "x = 1 + 2;")
    }

    func testBlockCommentWithoutASelectionTakesTheLineText() {
        let v = editor("    call();")
        v.send(SCI_GOTOPOS, 6)
        EditCommands(editor: v).blockComment(tokens: cTokens)
        XCTAssertEqual(text(v), "    /* call(); */")
    }

    func testTheLanguagesTokensComeFromLangsModel() {
        let python = EditCommands.tokens(for: LanguageCatalog.shared.language(named: "python")!)
        XCTAssertEqual(python.line, "#")
        let cpp = EditCommands.tokens(for: LanguageCatalog.shared.language(named: "cpp")!)
        XCTAssertEqual(cpp.line, "//")
        XCTAssertEqual(cpp.start, "/*")
        XCTAssertEqual(cpp.end, "*/")
    }

    // MARK: Begin/End Select

    func testBeginEndSelect() {
        let v = editor("abcdef")
        var begin: Int?
        v.send(SCI_GOTOPOS, 1)
        EditCommands.beginOrEndSelect(v, begin: &begin, columnMode: false)
        XCTAssertEqual(begin, 1)
        v.send(SCI_GOTOPOS, 4)
        EditCommands.beginOrEndSelect(v, begin: &begin, columnMode: false)
        XCTAssertNil(begin)
        XCTAssertEqual([v.send(SCI_GETSELECTIONSTART), v.send(SCI_GETSELECTIONEND)], [1, 4])
    }

    // MARK: Window: copy paths, read-only

    func testCopyToClipboardTexts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("InkpadCopy-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let window = MainWindowController()
        let untitled = window.newTab()
        untitled.editor.setUTF8Bytes(Data("draft".utf8))  // not pristine, so opening does not reuse it
        window.open(url)
        XCTAssertEqual(window.clipboardText(for: 0), url.path)
        XCTAssertEqual(window.clipboardText(for: 1), url.lastPathComponent)
        XCTAssertEqual(window.clipboardText(for: 2), url.deletingLastPathComponent().path)
        XCTAssertEqual(window.clipboardText(for: 3), "\(untitled.displayName)\r\n\(url.lastPathComponent)\r\n")
        window.selectTab(at: 0)
        XCTAssertEqual(window.clipboardText(for: 0), untitled.displayName, "an untitled document is its tab name")
        XCTAssertEqual(window.clipboardText(for: 2), "")
        window.openTabs.forEach { $0.detach() }
    }

    func testUserReadOnly() {
        let tab = EditorTab(untitledNumber: 1)
        tab.editor.setUTF8Bytes(Data("abc".utf8))
        tab.isUserReadOnly = true
        XCTAssertTrue(tab.isReadOnly)
        XCTAssertEqual(tab.editor.send(SCI_GETREADONLY), 1)
        XCTAssertTrue(tab.tabLabel.contains("🔒"))
        tab.editor.send(SCI_INSERTTEXT, 0, string: "x")
        XCTAssertEqual(String(decoding: tab.editor.utf8Bytes(), as: UTF8.self), "abc", "no edits")
        tab.isUserReadOnly = false
        XCTAssertEqual(tab.editor.send(SCI_GETREADONLY), 0)
        tab.detach()
    }

    func testLockedFileIsReadOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("InkpadLock-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        let tab = EditorTab(untitledNumber: 1)
        try tab.load(url)
        defer {
            try? tab.setFileLocked(false)
            try? FileManager.default.removeItem(at: url)
            tab.detach()
        }
        try tab.setFileLocked(true)
        XCTAssertTrue(tab.isReadOnly)
        XCTAssertEqual(try url.resourceValues(forKeys: [.isUserImmutableKey]).isUserImmutable, true)
        let again = EditorTab(untitledNumber: 2)
        try again.load(url)
        XCTAssertTrue(again.isFileLocked, "a locked file opens read-only")
        again.detach()
    }
}

import XCTest
@testable import Inkpad

// MAC-11: upstream's per-language lexer setup (defineDocType) and first-line detection.

private func editor(_ language: String, _ text: String = "") -> ScintillaView {
    let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    EditorStyler.configureEditor(v)
    v.setUTF8Bytes(Data(text.utf8))
    EditorStyler.apply(language: LanguageCatalog.shared.language(named: language)!, theme: StyleTheme.default, to: v)
    v.send(SCI_COLOURISE, 0, -1)
    return v
}

private func property(_ v: ScintillaView, _ key: String) -> String {
    key.withCString { k in
        let length = v.send(SCI_GETPROPERTY, Int(bitPattern: k), 0)
        var buffer = [CChar](repeating: 0, count: length + 1)
        buffer.withUnsafeMutableBytes { _ = v.send(SCI_GETPROPERTY, Int(bitPattern: k), Int(bitPattern: $0.baseAddress)) }
        return String(cString: buffer)
    }
}

private func lexerName(_ v: ScintillaView) -> String {
    var buffer = [CChar](repeating: 0, count: v.send(SCI_GETLEXERLANGUAGE) + 1)
    buffer.withUnsafeMutableBytes { _ = v.send(SCI_GETLEXERLANGUAGE, 0, pointer: $0.baseAddress) }
    return String(cString: buffer)
}

private func style(_ v: ScintillaView, at text: String) -> Int {
    let bytes = Array(v.utf8Bytes())
    let needle = Array(text.utf8)
    let index = (0...(bytes.count - needle.count)).first { Array(bytes[$0..<$0 + needle.count]) == needle }!
    return v.send(SCI_GETSTYLEAT, index)
}

final class LexerSetupTests: XCTestCase {
    func testSubstyleKeywordClasses() {
        XCTAssertEqual(keywordClassIndex("instre1"), 0)
        XCTAssertEqual(keywordClassIndex("type7"), 8)
        XCTAssertEqual(keywordClassIndex("substyle1"), 9)
        XCTAssertEqual(keywordClassIndex("substyle8"), 16)
        XCTAssertNil(keywordClassIndex("substyle9"))
    }

    func testHTMLColoursEmbeddedJavaScriptAndPHP() {
        let html = editor("html", "<html><script>function f() { return 1; }</script></html>")
        XCTAssertEqual(lexerName(html), "hypertext")
        XCTAssertEqual(style(html, at: "function"), Int(SCE_HJ_KEYWORD), "javascript keywords in set 1")
        XCTAssertEqual(html.send(SCI_GETSUBSTYLESSTART, Int(SCE_H_TAG)), 192)
        XCTAssertEqual(html.send(SCI_GETSUBSTYLESSTART, Int(SCE_HJ_WORD)), 200)
        XCTAssertEqual(html.send(SCI_GETSUBSTYLESSTART, Int(SCE_HPHP_WORD)), 208)
        XCTAssertEqual(html.send(SCI_GETSUBSTYLESSTART, Int(SCE_HB_WORD)), 216)
        XCTAssertEqual(html.send(SCI_STYLEGETEOLFILLED, Int(SCE_HJ_DEFAULT)), 1)
        XCTAssertEqual(property(html, "fold.html"), "1")

        let php = editor("php", "<?php echo $x; ?>")
        XCTAssertEqual(lexerName(php), "hypertext", "PHP is lexed as HTML, as upstream does")
        XCTAssertEqual(style(php, at: "echo"), Int(SCE_HPHP_WORD), "php keywords in set 4")
    }

    func testEmbeddedJavaScriptUsesTheJavascriptStylers() throws {
        let html = editor("html")
        let keyword = try XCTUnwrap(StyleTheme.default.lexerStyles["javascript"]?.first { $0.styleID == Int(SCE_HJ_WORD) })
        XCTAssertEqual(html.send(SCI_STYLEGETFORE, Int(SCE_HJ_WORD)), keyword.foreground)
    }

    func testXML() {
        let xml = editor("xml", "<?xml version=\"1.0\"?><a b=\"c\"/>")
        XCTAssertEqual(lexerName(xml), "xml")
        XCTAssertEqual(property(xml, "lexer.xml.allow.scripts"), "0")
        XCTAssertEqual(xml.send(SCI_GETSUBSTYLESSTART, Int(SCE_H_ATTRIBUTE)), 192)
        XCTAssertEqual(xml.send(SCI_GETSUBSTYLESLENGTH, Int(SCE_H_ATTRIBUTE)), 8)
    }

    func testCFamilyProperties() {
        let cpp = editor("cpp")
        XCTAssertEqual(property(cpp, "fold.preprocessor"), "1")
        XCTAssertEqual(property(cpp, "lexer.cpp.track.preprocessor"), "0")
        XCTAssertEqual(cpp.send(SCI_GETSUBSTYLESSTART, Int(SCE_C_IDENTIFIER)), 128)
        XCTAssertEqual(property(editor("go"), "lexer.cpp.backquoted.strings"), "1")
        XCTAssertEqual(property(editor("javascript.js"), "lexer.cpp.backquoted.strings"), "2")
    }

    func testOtherLanguageProperties() {
        XCTAssertEqual(property(editor("sql"), "sql.backslash.escapes"), "1")
        XCTAssertEqual(property(editor("json5"), "lexer.json.allow.comments"), "1")
        XCTAssertEqual(property(editor("json"), "lexer.json.allow.comments"), "")
        XCTAssertEqual(property(editor("python"), "fold.quotes.python"), "1")
        XCTAssertEqual(property(editor("tcl"), "fold"), "", "setTclLexer sends no properties")
        XCTAssertEqual(property(editor("bash"), "fold"), "1")
        XCTAssertEqual(editor("bash").send(SCI_GETSUBSTYLESSTART, Int(SCE_SH_SCALAR)), 132)
    }

    func testPythonTabsIndentGuidesAndFoldMargin() {
        let py = editor("python")
        XCTAssertEqual(py.send(SCI_GETTABWIDTH), 4)
        XCTAssertEqual(py.send(SCI_GETUSETABS), 0, "langs.model.xml tabSettings=132: spaces")
        XCTAssertEqual(py.send(SCI_GETINDENTATIONGUIDES), Int(SC_IV_LOOKFORWARD))
        let sql = editor("sql")
        XCTAssertEqual(sql.send(SCI_GETUSETABS), 1)
        XCTAssertEqual(sql.send(SCI_GETINDENTATIONGUIDES), Int(SC_IV_LOOKBOTH))
        XCTAssertEqual(editor("batch").send(SCI_GETMARGINWIDTHN, Margin.fold), 0)
        XCTAssertEqual(sql.send(SCI_GETMARGINWIDTHN, Margin.fold), 14)
    }

    func testSwitchingLanguagesFreesTheOldSubstyles() {
        let v = editor("python")
        EditorStyler.apply(language: LanguageCatalog.shared.language(named: "sql")!, theme: StyleTheme.default, to: v)
        XCTAssertEqual(v.send(SCI_GETSUBSTYLESLENGTH, Int(SCE_P_IDENTIFIER)), 0)
        XCTAssertEqual(lexerName(v), "sql")
    }
}

final class LanguageDetectionTests: XCTestCase {
    private func detect(_ text: String) -> String? { LanguageDetector.language(fromTextBeginning: Data(text.utf8)) }

    func testShebangs() {
        XCTAssertEqual(detect("#!/bin/bash\necho"), "bash")
        XCTAssertEqual(detect("#!/usr/bin/python3\n"), "python")
        XCTAssertEqual(detect("#!/usr/bin/env perl\n"), "perl")
        XCTAssertEqual(detect("#!/usr/bin/env node\n"), "javascript.js")
        XCTAssertEqual(detect("#!/usr/bin/ruby\n"), "ruby")
        XCTAssertEqual(detect("#!/usr/bin/zsh -f\n"), "bash", "\"sh\" is tested first")
        XCTAssertNil(detect("#!/usr/bin/awk -f\n"))
    }

    func testMarkupPrefixes() {
        XCTAssertEqual(detect("<?xml version=\"1.0\"?>"), "xml")
        XCTAssertEqual(detect("<?php echo 1;"), "php")
        XCTAssertEqual(detect("<html><body>"), "html")
        XCTAssertEqual(detect("<!DOCTYPE html>"), "html")
        XCTAssertNil(detect("<!doctype html>"), "case-sensitive, as in upstream")
        XCTAssertEqual(detect("<? short tag"), "php")
        XCTAssertNil(detect("@echo off\r\n"))
    }

    func testBOMBlankLinesAndLimits() {
        XCTAssertEqual(LanguageDetector.language(fromTextBeginning: Data([0xEF, 0xBB, 0xBF]) + Data("<?xml ?>".utf8)), "xml")
        XCTAssertEqual(detect("\n\n  \t<?xml ?>"), "xml", "leading blank space is skipped")
        XCTAssertNil(detect("<?x"), "3 bytes or fewer")
        XCTAssertNil(detect("#!" + String(repeating: "x", count: 40) + "python"), "only 40 bytes of the line")
        XCTAssertNil(detect("#!/bin/env\npython"), "the first line only")
    }

    func testFileNamesAndOpening() throws {
        XCTAssertEqual(LanguageCatalog.shared.language(for: URL(fileURLWithPath: "/x/SConstruct")).name, "python")
        XCTAssertEqual(LanguageCatalog.shared.language(for: URL(fileURLWithPath: "/x/PKGBUILD")).name, "bash")
        XCTAssertEqual(LanguageCatalog.shared.language(for: URL(fileURLWithPath: "/x/Vagrantfile")).name, "ruby")

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("InkpadDetect-\(UUID().uuidString)")
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let tab = EditorTab(untitledNumber: 1)
        try tab.load(url)
        XCTAssertEqual(tab.language.name, "bash")
        XCTAssertFalse(tab.isLanguageChosenByUser)
        tab.setLanguage(LanguageCatalog.shared.language(named: "perl")!)
        XCTAssertTrue(tab.isLanguageChosenByUser)
        tab.detach()

        XCTAssertEqual(EditorTab.language(for: URL(fileURLWithPath: "/x/a.py"), content: Data("<?xml ?>".utf8)).name, "python",
                       "the extension wins over the content")
    }
}

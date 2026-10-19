import XCTest
@testable import Inkpad

/// MAC-29: Scintilla runs upstream's Boost regex engine (SCI_OWNREGEX). Each test uses a feature
/// Scintilla's own engine does not have, so these fail if the switch is ever lost.
final class BoostRegexTests: XCTestCase {
    private func editor(_ text: String) -> ScintillaView {
        let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
        v.setUTF8Bytes(Data(text.utf8))
        return v
    }

    /// Searches the whole document; returns the matched text, nil for no match, or throws on an
    /// invalid pattern (Scintilla returns -2).
    private func find(_ pattern: String, in v: ScintillaView, flags: Int = Int(SCFIND_REGEXP)) throws -> String? {
        v.send(SCI_SETSEARCHFLAGS, flags)
        v.send(SCI_SETTARGETRANGE, 0, v.send(SCI_GETLENGTH))
        let pos = v.send(SCI_SEARCHINTARGET, pattern.utf8.count, string: pattern)
        if pos == -2 { throw NSError(domain: "regex", code: -2) }
        guard pos >= 0 else { return nil }
        let bytes = v.utf8Bytes()
        let start = v.send(SCI_GETTARGETSTART), end = v.send(SCI_GETTARGETEND)
        return String(decoding: bytes[start..<end], as: UTF8.self)
    }

    private func text(_ v: ScintillaView) -> String { String(decoding: v.utf8Bytes(), as: UTF8.self) }

    func testLookbehind() throws {
        XCTAssertEqual(try find("(?<=foo)bar", in: editor("xbar foobar")), "bar")
        let v = editor("xbar foobar")
        _ = try find("(?<=foo)bar", in: v)
        XCTAssertEqual(v.send(SCI_GETTARGETSTART), 8, "the bar after foo, not the first one")
    }

    func testBackslashRMatchesAnyLineBreak() throws {
        XCTAssertEqual(try find("a\\Rb", in: editor("a\r\nb")), "a\r\nb")
        XCTAssertEqual(try find("a\\Rb", in: editor("a\nb")), "a\nb")
    }

    func testHorizontalWhitespaceClass() throws {
        XCTAssertEqual(try find("x\\h+y", in: editor("x \t y")), "x \t y")
        XCTAssertNil(try find("x\\h+y", in: editor("x\ny")))
    }

    func testAtomicGroupDoesNotBacktrack() throws {
        XCTAssertNil(try find("(?>a+)ab", in: editor("aaab")))
        XCTAssertEqual(try find("a+ab", in: editor("aaab")), "aaab")
    }

    func testWordClassMatchesHebrew() throws {
        XCTAssertEqual(try find("\\w+", in: editor("  שלום עולם")), "שלום")
        XCTAssertEqual(try find("[[:alpha:]]+", in: editor("1 Ελλάδα")), "Ελλάδα")
    }

    func testCaseInsensitiveBeyondASCII() throws {
        XCTAssertEqual(try find("école", in: editor("ÉCOLE")), "ÉCOLE")
        XCTAssertEqual(try find("\\u\\w+", in: editor("ä Öl"), flags: Int(SCFIND_REGEXP | SCFIND_MATCHCASE)), "Öl")
    }

    func testCaseSensitivityFollowsMatchCase() throws {
        XCTAssertEqual(try find("hello", in: editor("HELLO")), "HELLO")
        XCTAssertNil(try find("hello", in: editor("HELLO"), flags: Int(SCFIND_REGEXP | SCFIND_MATCHCASE)))
    }

    func testDotMatchesNewlineIsUpstreamOption() throws {
        XCTAssertNil(try find("a.b", in: editor("a\nb")))
        XCTAssertEqual(try find("a.b", in: editor("a\nb"), flags: Int(SCFIND_REGEXP) | Int(SCFIND_REGEXP_DOTMATCHESNL)), "a\nb")
    }

    func testReplacementWithNumberedAndNamedGroups() throws {
        let v = editor("hello world")
        _ = try find("(\\w+) (?<second>\\w+)", in: v)
        let replacement = "$+{second} \\1"
        v.send(SCI_REPLACETARGETRE, replacement.utf8.count, string: replacement)
        XCTAssertEqual(text(v), "world hello")
    }

    func testDollarZeroIsTheWholeMatch() throws {
        let v = editor("abc")
        _ = try find("b", in: v)
        v.send(SCI_REPLACETARGETRE, 4, string: "[$0]")
        XCTAssertEqual(text(v), "a[b]c")
    }

    func testAnInvalidPatternIsReportedNotACrash() {
        XCTAssertThrowsError(try find("(unclosed", in: editor("text")))
        XCTAssertThrowsError(try find("a{2,1}", in: editor("aa")))
    }

    /// Regression (2026-10-14): patterns went to Boost unterminated, so it read past them; results
    /// changed between runs. The pattern must end where its bytes end.
    func testThePatternEndsWithItsBytes() {
        let v = editor("(a)")
        v.send(SCI_SETSEARCHFLAGS, Int(SCFIND_REGEXP))
        v.send(SCI_SETTARGETRANGE, 0, v.send(SCI_GETLENGTH))
        let pattern = Array("(a)".utf8)
        XCTAssertEqual(v.searchInTarget(Array(pattern.prefix(2))), -2, "\"(a\" alone is not a valid regex")
        v.send(SCI_SETTARGETRANGE, 0, v.send(SCI_GETLENGTH))
        XCTAssertEqual(v.searchInTarget(pattern), 1)
        let target = editor("abc")
        target.send(SCI_SETTARGETRANGE, 1, 2)
        target.send(SCI_SETSEARCHFLAGS, Int(SCFIND_REGEXP))
        target.send(SCI_SEARCHINTARGET, 1, string: "b")
        XCTAssertEqual(target.replaceTarget(Array("[$0]".utf8), regex: true), 3)
        XCTAssertEqual(String(decoding: target.utf8Bytes(), as: UTF8.self), "a[b]c")
    }
}

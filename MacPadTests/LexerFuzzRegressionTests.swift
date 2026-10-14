import XCTest
@testable import MacPad

/// MAC-65: inputs the MAC-25 fuzzing found that crashed or hung Lexilla's lexers on open, run
/// through the lexers MacPad++ really links (patched copies, see scripts/deps/lexer-patches).
/// Before the fix the Raku cases crash the test host and the Perl ones never return.
final class LexerFuzzRegressionTests: XCTestCase {
    private func lex(_ bytes: [UInt8], as language: String) throws -> TimeInterval {
        let info = try XCTUnwrap(LanguageCatalog.shared.language(named: language))
        let view = ScintillaView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
        EditorStyler.apply(language: info, theme: ThemeManager.shared.current, to: view)
        view.setUTF8Bytes(Data(bytes))
        let start = Date()
        view.send(SCI_COLOURISE, 0, -1)
        return Date().timeIntervalSince(start)
    }

    func testRakuLongWordsDoNotOverflow() throws {
        XCTAssertEqual(EditorStyler.lexerName(for: try XCTUnwrap(LanguageCatalog.shared.language(named: "raku"))), "raku")
        _ = try lex(Array(repeating: UInt8(ascii: "a"), count: 101), as: "raku")            // the fuzzer's raku-1.bin
        _ = try lex(Array(repeating: UInt8(ascii: "x"), count: 10_000), as: "raku")         // one 10 KB word
        _ = try lex(Array(("my $" + String(repeating: "v", count: 5000) + " = 1;\n").utf8), as: "raku")
    }

    func testPerlNulInAHereDocEnds() throws {
        XCTAssertLessThan(try lex([0x3C, 0x3C, 0x0A, 0x00], as: "perl"), 2)                // "<<\n\0", perl-hang-1.bin
        XCTAssertLessThan(try lex(Array("print <<EOF;\nab".utf8) + [0] + Array("cd\nEOF\n".utf8), as: "perl"), 2)
        XCTAssertLessThan(try lex(Array("print <<\"EOF\";\n".utf8) + [0] + Array("\nEOF\n".utf8), as: "perl"), 2)
    }

    func testPerlLongQuotedDelimiterEndingInAnEmojiDoesNotOverflow() throws {
        let delimiter = String(repeating: "D", count: 252) + "😀"
        _ = try lex(Array("print <<\"\(delimiter)\";\nbody\n\(delimiter)\n".utf8), as: "perl")
    }
}

import XCTest
@testable import Inkpad

/// EOL detection. upstream takes the first line ending in the file and keeps it on save,
/// including for files with mixed endings.
final class LineEndingTests: XCTestCase {
    private func detect(_ text: String) -> LineEnding? {
        LineEnding.detect(utf8: Data(text.utf8))
    }

    func testWindowsCRLF() {
        XCTAssertEqual(detect("one\r\ntwo"), .crlf)
    }

    func testUnixLF() {
        XCTAssertEqual(detect("one\ntwo"), .lf)
    }

    func testClassicMacCR() {
        XCTAssertEqual(detect("one\rtwo"), .cr)
    }

    func testLoneCRAtEndOfFile() {
        XCTAssertEqual(detect("one\r"), .cr)
    }

    func testNoLineEndingAtAll() {
        XCTAssertNil(detect("single line"))
        XCTAssertNil(detect(""))
    }

    func testMixedEndingsTakeTheFirstOne() {
        XCTAssertEqual(detect("one\ntwo\r\n"), .lf, "LF came first")
        XCTAssertEqual(detect("one\r\ntwo\n"), .crlf, "CRLF came first")
        XCTAssertEqual(detect("one\rtwo\n"), .cr, "CR came first")
    }

    func testEndingOnTheVeryFirstByte() {
        XCTAssertEqual(detect("\nrest"), .lf)
        XCTAssertEqual(detect("\r\nrest"), .crlf)
    }

    func testRawValuesAreScintillaEOLConstants() {
        // SC_EOL_CRLF = 0, SC_EOL_CR = 1, SC_EOL_LF = 2 — passed straight to SCI_SETEOLMODE.
        XCTAssertEqual(LineEnding.crlf.rawValue, 0)
        XCTAssertEqual(LineEnding.cr.rawValue, 1)
        XCTAssertEqual(LineEnding.lf.rawValue, 2)
    }

    func testStatusNamesMatchUpstream() {
        XCTAssertEqual(LineEnding.crlf.statusName, "Windows (CR LF)")
        XCTAssertEqual(LineEnding.cr.statusName, "Macintosh (CR)")
        XCTAssertEqual(LineEnding.lf.statusName, "Unix (LF)")
    }

    func testDecodeReportsTheLineEndingOfTheDecodedText() {
        // UTF-16 input: detection runs on the converted UTF-8 buffer, not the raw bytes,
        // where every CR/LF is preceded by a 0x00 byte.
        let utf16 = Data([0xFF, 0xFE]) + "a\r\nb".data(using: .utf16LittleEndian)!
        XCTAssertEqual(TextFile.decode(utf16).lineEnding, .crlf)
    }
}

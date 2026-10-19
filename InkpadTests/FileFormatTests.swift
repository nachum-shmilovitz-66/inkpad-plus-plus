import XCTest
@testable import Inkpad

/// Line-ending conversion (upstream's EOL Conversion) on raw UTF-8 bytes.
final class LineEndingConversionTests: XCTestCase {
    private func convert(_ text: String, to eol: LineEnding) -> String {
        String(decoding: LineEnding.convert(Data(text.utf8), to: eol), as: UTF8.self)
    }

    // MARK: Each direction

    func testWindowsToUnix() { XCTAssertEqual(convert("a\r\nb\r\n", to: .lf), "a\nb\n") }
    func testWindowsToMacintosh() { XCTAssertEqual(convert("a\r\nb\r\n", to: .cr), "a\rb\r") }
    func testUnixToWindows() { XCTAssertEqual(convert("a\nb\n", to: .crlf), "a\r\nb\r\n") }
    func testUnixToMacintosh() { XCTAssertEqual(convert("a\nb", to: .cr), "a\rb") }
    func testMacintoshToWindows() { XCTAssertEqual(convert("a\rb\r", to: .crlf), "a\r\nb\r\n") }
    func testMacintoshToUnix() { XCTAssertEqual(convert("a\rb", to: .lf), "a\nb") }

    // MARK: Mixed and edge cases

    func testMixedEndingsAllBecomeTheTarget() {
        XCTAssertEqual(convert("1\r\n2\n3\r4", to: .crlf), "1\r\n2\r\n3\r\n4")
        XCTAssertEqual(convert("1\r\n2\n3\r4", to: .lf), "1\n2\n3\n4")
    }

    func testCRFollowedByLFIsOneLineEndingNotTwo() {
        XCTAssertEqual(convert("a\r\nb", to: .lf), "a\nb")
    }

    func testLFFollowedByCRIsTwoLineEndings() {
        XCTAssertEqual(convert("a\n\rb", to: .lf), "a\n\nb")
    }

    func testBlankLinesArePreserved() {
        XCTAssertEqual(convert("a\r\n\r\n\r\nb", to: .lf), "a\n\n\nb")
    }

    func testTrailingLoneCRAtEndOfFile() {
        XCTAssertEqual(convert("a\r", to: .crlf), "a\r\n")
    }

    func testTextWithoutLineEndingsIsUnchanged() {
        XCTAssertEqual(convert("no line ending", to: .crlf), "no line ending")
    }

    func testEmptyText() {
        XCTAssertEqual(LineEnding.convert(Data(), to: .crlf), Data())
    }

    func testConvertingToTheSameEndingIsIdentity() {
        let text = "x\r\ny\r\n"
        XCTAssertEqual(convert(text, to: .crlf), text)
    }

    func testLineCountNeverChanges() {
        let text = "1\r\n2\n3\r4\r\n\n"
        for eol in LineEnding.menuOrder {
            let converted = convert(text, to: eol)
            XCTAssertEqual(converted.components(separatedBy: eol == .crlf ? "\r\n" : (eol == .lf ? "\n" : "\r")).count,
                           6, "line count changed converting to \(eol)")
        }
    }

    func testMultibyteCharactersAreUntouched() {
        XCTAssertEqual(convert("שלום\r\nעולם", to: .lf), "שלום\nעולם")
        XCTAssertEqual(convert("héllo\n🙂", to: .crlf), "héllo\r\n🙂")
    }

    func testConvertsADataSliceWithNonZeroStartIndex() {
        let whole = Data("XXa\nb".utf8)
        let slice = whole.dropFirst(2)  // startIndex 2
        XCTAssertEqual(String(decoding: LineEnding.convert(slice, to: .crlf), as: UTF8.self), "a\r\nb")
    }
}

/// Encoding conversion ("Convert to …") and the dirty state it implies.
final class FileFormatTests: XCTestCase {
    private let hebrew = Data("שלום".utf8)
    private let ascii = Data("hello".utf8)

    func testNewFormatIsNotChanged() {
        let format = FileFormat(encoding: .utf8)
        XCTAssertEqual(format.encoding, .utf8)
        XCTAssertFalse(format.isEncodingChanged)
    }

    func testConvertingChangesTheTargetAndMarksItChanged() throws {
        var format = FileFormat(encoding: .utf8)
        try format.convert(ascii, to: .utf16LE)
        XCTAssertEqual(format.encoding, .utf16LE)
        XCTAssertEqual(format.savedEncoding, .utf8)
        XCTAssertTrue(format.isEncodingChanged)
    }

    func testConvertingBackToTheSavedEncodingClearsTheChange() throws {
        var format = FileFormat(encoding: .utf8)
        try format.convert(ascii, to: .utf8BOM)
        try format.convert(ascii, to: .utf8)
        XCTAssertFalse(format.isEncodingChanged)
    }

    func testMarkSavedMakesTheTargetTheSavedEncoding() throws {
        var format = FileFormat(encoding: .ansi)
        try format.convert(ascii, to: .utf8)
        format.markSaved()
        XCTAssertEqual(format.savedEncoding, .utf8)
        XCTAssertFalse(format.isEncodingChanged)
    }

    func testUnrepresentableConversionThrowsAndChangesNothing() {
        var format = FileFormat(encoding: .utf8)
        XCTAssertThrowsError(try format.convert(hebrew, to: .ansi)) { error in
            guard case TextFile.SaveError.unrepresentable(.ansi) = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        XCTAssertEqual(format, FileFormat(encoding: .utf8))
    }

    func testEveryUnicodeEncodingAcceptsHebrew() throws {
        for target in [TextEncoding.utf8, .utf8BOM, .utf16LE, .utf16BE] {
            var format = FileFormat(encoding: .utf8)
            XCTAssertNoThrow(try format.convert(hebrew, to: target), "\(target.statusName)")
        }
    }

    func testPickerRefusesExactlyWhenSaveWould() {
        // The picker's check and the save path must agree for every encoding.
        let samples = [ascii, hebrew, Data("café".utf8), Data("emoji 🙂".utf8)]
        for sample in samples {
            for target in TextEncoding.menuOrder {
                var format = FileFormat(encoding: .utf8)
                let pickerAccepts = (try? format.convert(sample, to: target)) != nil
                let saveAccepts = (try? TextFile.encode(sample, as: target)) != nil
                XCTAssertEqual(pickerAccepts, saveAccepts, "\(target.statusName) on \(String(decoding: sample, as: UTF8.self))")
            }
        }
    }

    func testCafeConvertsToANSIAndSavesAsWindows1252() throws {
        var format = FileFormat(encoding: .utf8)
        let cafe = Data("café".utf8)
        try format.convert(cafe, to: .ansi)
        XCTAssertEqual(try TextFile.encode(cafe, as: format.encoding), Data([0x63, 0x61, 0x66, 0xE9]))
    }
}

/// The status bar's pop-up menus.
final class StatusBarMenuTests: XCTestCase {
    func testEncodingMenuFollowsUpstreamOrderAndChecksTheCurrentOne() {
        let items = StatusBarMenu.encodingItems(current: .utf8BOM)
        XCTAssertEqual(items.map(\.title), ["ANSI", "UTF-8", "UTF-8-BOM", "UTF-16 BE BOM", "UTF-16 LE BOM"])
        XCTAssertEqual(items.filter(\.isCurrent).map(\.value), [.utf8BOM])
    }

    func testEncodingMenuListsEveryEncodingOnce() {
        let values = StatusBarMenu.encodingItems(current: .utf8).map(\.value)
        XCTAssertEqual(values.count, 5)
        for e in [TextEncoding.utf8, .utf8BOM, .utf16LE, .utf16BE, .ansi] { XCTAssertTrue(values.contains(e)) }
    }

    func testLineEndingMenuFollowsUpstreamOrderAndChecksTheCurrentOne() {
        let items = StatusBarMenu.lineEndingItems(current: .lf)
        XCTAssertEqual(items.map(\.title), ["Windows (CR LF)", "Unix (LF)", "Macintosh (CR)"])
        XCTAssertEqual(items.filter(\.isCurrent).map(\.value), [.lf])
    }

    func testLineEndingRawValuesAreScintillaEOLModes() {
        // The menu round-trips through NSMenuItem.tag = rawValue; these must stay SC_EOL_*.
        XCTAssertEqual(LineEnding.crlf.rawValue, Int(SC_EOL_CRLF))
        XCTAssertEqual(LineEnding.cr.rawValue, Int(SC_EOL_CR))
        XCTAssertEqual(LineEnding.lf.rawValue, Int(SC_EOL_LF))
    }
}

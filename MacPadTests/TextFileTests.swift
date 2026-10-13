import XCTest
@testable import MacPad

/// Encoding detection, decode and byte-exact save. Expected values come from Notepad++'s own
/// behaviour: it reports the encoding in the status bar and never rewrites bytes it did not edit.
final class TextFileTests: XCTestCase {
    private let utf8BOM = Data([0xEF, 0xBB, 0xBF])
    private let utf16LEBOM = Data([0xFF, 0xFE])
    private let utf16BEBOM = Data([0xFE, 0xFF])

    // MARK: detection

    func testPlainASCIIIsUTF8WithoutBOM() {
        let loaded = TextFile.decode(Data("hello".utf8))
        XCTAssertEqual(loaded.encoding, .utf8)
        XCTAssertEqual(loaded.utf8, Data("hello".utf8))
    }

    func testMultibyteUTF8WithoutBOMIsDetectedAsUTF8() {
        // Valid UTF-8 must not be mistaken for a single-byte code page.
        let loaded = TextFile.decode(Data("שלום × café".utf8))
        XCTAssertEqual(loaded.encoding, .utf8)
        XCTAssertEqual(String(data: loaded.utf8, encoding: .utf8), "שלום × café")
    }

    func testUTF8BOMIsStrippedFromTheEditorBuffer() {
        let loaded = TextFile.decode(utf8BOM + Data("hello".utf8))
        XCTAssertEqual(loaded.encoding, .utf8BOM)
        XCTAssertEqual(loaded.utf8, Data("hello".utf8), "the BOM belongs to the file, not the buffer")
    }

    func testUTF16LittleEndianBOM() {
        let loaded = TextFile.decode(utf16LEBOM + "hi".data(using: .utf16LittleEndian)!)
        XCTAssertEqual(loaded.encoding, .utf16LE)
        XCTAssertEqual(loaded.utf8, Data("hi".utf8))
    }

    func testUTF16BigEndianBOM() {
        let loaded = TextFile.decode(utf16BEBOM + "hi".data(using: .utf16BigEndian)!)
        XCTAssertEqual(loaded.encoding, .utf16BE)
        XCTAssertEqual(loaded.utf8, Data("hi".utf8))
    }

    func testInvalidUTF8FallsBackToANSI() {
        // 0xE9 is "é" in Windows-1252 and an illegal lone lead byte in UTF-8.
        let loaded = TextFile.decode(Data([0x63, 0x61, 0x66, 0xE9]))
        XCTAssertEqual(loaded.encoding, .ansi)
        XCTAssertEqual(String(data: loaded.utf8, encoding: .utf8), "café")
    }

    func testByteUndefinedInWindows1252StillDecodes() {
        // 0x81 is unassigned in Windows-1252; the Latin-1 fallback keeps the file readable
        // instead of opening it empty.
        let loaded = TextFile.decode(Data([0x41, 0x81, 0x42]))
        XCTAssertEqual(loaded.encoding, .ansi)
        XCTAssertFalse(loaded.utf8.isEmpty)
    }

    func testEmptyFileIsUTF8WithNoLineEnding() {
        let loaded = TextFile.decode(Data())
        XCTAssertEqual(loaded.encoding, .utf8)
        XCTAssertNil(loaded.lineEnding)
        XCTAssertEqual(loaded.utf8, Data())
    }

    // MARK: save round-trip

    func testSaveIsByteExactForEveryEncoding() throws {
        let samples: [(TextEncoding, Data)] = [
            (.utf8, Data("plain".utf8)),
            (.utf8BOM, utf8BOM + Data("plain".utf8)),
            (.utf16LE, utf16LEBOM + "plain".data(using: .utf16LittleEndian)!),
            (.utf16BE, utf16BEBOM + "plain".data(using: .utf16BigEndian)!),
            (.ansi, Data([0x63, 0x61, 0x66, 0xE9])),
        ]
        for (encoding, original) in samples {
            let loaded = TextFile.decode(original)
            XCTAssertEqual(loaded.encoding, encoding)
            let saved = try TextFile.encode(loaded.utf8, as: loaded.encoding)
            XCTAssertEqual(saved, original, "re-saving an unedited \(encoding.statusName) file changed its bytes")
        }
    }

    func testSavingAsANSIRejectsCharactersItCannotRepresent() {
        // Notepad++ refuses rather than silently writing "?" for every Hebrew letter.
        XCTAssertThrowsError(try TextFile.encode(Data("שלום".utf8), as: .ansi)) { error in
            guard case TextFile.SaveError.unrepresentable(let encoding) = error else {
                return XCTFail("expected SaveError.unrepresentable, got \(error)")
            }
            XCTAssertEqual(encoding, .ansi)
        }
    }

    func testSavingAsUTF16KeepsHebrew() throws {
        let saved = try TextFile.encode(Data("שלום".utf8), as: .utf16LE)
        XCTAssertEqual(TextFile.decode(saved).utf8, Data("שלום".utf8))
    }

    // MARK: status bar

    func testStatusNamesMatchNotepadPlusPlus() {
        XCTAssertEqual(TextEncoding.utf8.statusName, "UTF-8")
        XCTAssertEqual(TextEncoding.utf8BOM.statusName, "UTF-8-BOM")
        XCTAssertEqual(TextEncoding.utf16LE.statusName, "UTF-16 LE BOM")
        XCTAssertEqual(TextEncoding.utf16BE.statusName, "UTF-16 BE BOM")
        XCTAssertEqual(TextEncoding.ansi.statusName, "ANSI")
    }
}

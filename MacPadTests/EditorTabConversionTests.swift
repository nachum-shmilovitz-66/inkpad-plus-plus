import XCTest
@testable import MacPad

/// The status-bar conversions end to end, through a real Scintilla editor: load a file, convert,
/// undo, save, and check the bytes on disk.
final class EditorTabConversionTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacPadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func tab(loading bytes: [UInt8], name: String = "sample.txt") throws -> (EditorTab, URL) {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        let tab = EditorTab(untitledNumber: 1)
        try tab.load(url)
        return (tab, url)
    }

    private func onDisk(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }

    // MARK: Save (MAC-18 regression)

    func testSaveWithoutACompletionStillWritesTheFile() throws {
        let (tab, url) = try tab(loading: Array("old".utf8))
        tab.editor.send(SCI_APPENDTEXT, 4, string: " new")
        XCTAssertTrue(tab.isModified)
        tab.save()  // no completion: this used to skip the write entirely
        XCTAssertEqual(try onDisk(url), Array("old new".utf8))
        XCTAssertFalse(tab.isModified)
    }

    func testSaveWithACompletionReportsSuccess() throws {
        let (tab, url) = try tab(loading: Array("x".utf8))
        tab.editor.send(SCI_APPENDTEXT, 1, string: "y")
        var reported: Bool?
        tab.save { reported = $0 }
        XCTAssertEqual(reported, true)
        XCTAssertEqual(try onDisk(url), Array("xy".utf8))
    }

    // MARK: Line endings

    func testConvertingLineEndingsRewritesTheBufferAndTheEOLMode() throws {
        let (tab, _) = try tab(loading: Array("one\r\ntwo\r\nthree".utf8))
        XCTAssertEqual(tab.lineEnding, .crlf)

        tab.convertLineEndings(to: .lf)

        XCTAssertEqual(String(decoding: tab.editor.utf8Bytes(), as: UTF8.self), "one\ntwo\nthree")
        XCTAssertEqual(tab.lineEnding, .lf)
        XCTAssertTrue(tab.isModified)
        XCTAssertEqual(tab.status().lineEnding, "Unix (LF)")
    }

    func testLineEndingConversionIsOneUndoStep() throws {
        let (tab, _) = try tab(loading: Array("a\r\nb\r\nc".utf8))
        tab.convertLineEndings(to: .cr)
        tab.editor.send(SCI_UNDO)
        XCTAssertEqual(String(decoding: tab.editor.utf8Bytes(), as: UTF8.self), "a\r\nb\r\nc")
        XCTAssertFalse(tab.isModified, "undo should return to the save point")
    }

    func testLineEndingConversionKeepsTheCaretOnItsLineAndColumn() throws {
        let (tab, _) = try tab(loading: Array("first\r\nsecond\r\nthird".utf8))
        // Line 2 ("third"), column 3.
        tab.editor.send(SCI_GOTOPOS, tab.editor.send(SCI_FINDCOLUMN, 2, 3))
        tab.convertLineEndings(to: .lf)
        let pos = tab.editor.send(SCI_GETCURRENTPOS)
        XCTAssertEqual(tab.editor.send(SCI_LINEFROMPOSITION, pos), 2)
        XCTAssertEqual(tab.editor.send(SCI_GETCOLUMN, pos), 3)
    }

    func testConvertingToTheCurrentLineEndingDoesNotDirtyTheDocument() throws {
        let (tab, _) = try tab(loading: Array("a\nb".utf8))
        tab.convertLineEndings(to: .lf)
        XCTAssertFalse(tab.isModified)
    }

    func testConvertedLineEndingsAreWhatGetsSaved() throws {
        let (tab, url) = try tab(loading: Array("a\nb\n".utf8))
        tab.convertLineEndings(to: .crlf)
        tab.save()
        XCTAssertEqual(try onDisk(url), Array("a\r\nb\r\n".utf8))
        XCTAssertFalse(tab.isModified)
    }

    // MARK: Encoding

    func testConvertingTheEncodingDirtiesTheTabAndSavesInTheNewEncoding() throws {
        let (tab, url) = try tab(loading: Array("hi\n".utf8))
        XCTAssertEqual(tab.encoding, .utf8)

        try tab.convertEncoding(to: .utf16LE)
        XCTAssertTrue(tab.isModified, "an encoding change alone must mark the document dirty")
        XCTAssertEqual(tab.status().encoding, "UTF-16 LE BOM")

        tab.save()
        XCTAssertEqual(try onDisk(url), [0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00, 0x0A, 0x00])
        XCTAssertFalse(tab.isModified)
        XCTAssertEqual(tab.encoding, .utf16LE)
    }

    func testConvertingBackBeforeSavingCleansTheTab() throws {
        let (tab, _) = try tab(loading: Array("hi".utf8))
        try tab.convertEncoding(to: .utf8BOM)
        try tab.convertEncoding(to: .utf8)
        XCTAssertFalse(tab.isModified)
    }

    func testUnrepresentableConversionIsRefusedAndTheFileIsUntouched() throws {
        let original = Array("שלום\n".utf8)
        let (tab, url) = try tab(loading: original)

        XCTAssertThrowsError(try tab.convertEncoding(to: .ansi))
        XCTAssertEqual(tab.encoding, .utf8)
        XCTAssertFalse(tab.isModified)

        tab.save()
        XCTAssertEqual(try onDisk(url), original, "nothing may be lost when the conversion is refused")
    }

    func testANSIFileConvertedToUTF8KeepsItsText() throws {
        let (tab, url) = try tab(loading: [0x63, 0x61, 0x66, 0xE9])  // "café" in Windows-1252
        XCTAssertEqual(tab.encoding, .ansi)
        try tab.convertEncoding(to: .utf8)
        tab.save()
        XCTAssertEqual(try onDisk(url), Array("café".utf8))
    }
}

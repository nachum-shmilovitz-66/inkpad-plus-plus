import XCTest
@testable import MacPad

/// MAC-41: the Column Editor.
final class ColumnEditorTests: XCTestCase {
    private func editor(_ text: String) -> ScintillaView {
        let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
        v.send(SCI_SETVIRTUALSPACEOPTIONS, Int(SCVS_RECTANGULARSELECTION))
        v.setUTF8Bytes(Data(text.utf8))
        v.send(SCI_GOTOPOS, 0)
        return v
    }

    private func text(_ v: ScintillaView) -> String { String(decoding: v.utf8Bytes(), as: UTF8.self) }

    private func numbers(_ initial: Int, _ increase: Int, _ repeatCount: Int = 0,
                         format: ColumnEditorSettings.Format = .dec, leading: ColumnEditorSettings.Leading = .none) -> ColumnEditorSettings {
        var s = ColumnEditorSettings()
        s.mode = .number
        (s.initial, s.increase, s.repeatCount, s.format, s.leading) = (initial, increase, repeatCount, format, leading)
        return s
    }

    func testNumberSequences() {
        XCTAssertEqual(ColumnEditor.numbers(count: 5, initial: 1, increase: 2, repeat: 0), [1, 3, 5, 7, 9])
        XCTAssertEqual(ColumnEditor.numbers(count: 5, initial: 0, increase: 1, repeat: 2), [0, 0, 1, 1, 2], "each value repeated")
        XCTAssertEqual(ColumnEditor.numbers(count: 3, initial: 7, increase: 0, repeat: 1), [7, 7, 7])
    }

    func testPaddingAndFormats() {
        XCTAssertEqual(ColumnEditor.numberStrings(count: 3, settings: numbers(8, 1, leading: .zeros)), ["08", "09", "10"])
        XCTAssertEqual(ColumnEditor.numberStrings(count: 3, settings: numbers(8, 1, leading: .spaces)), [" 8", " 9", "10"])
        XCTAssertEqual(ColumnEditor.numberStrings(count: 3, settings: numbers(8, 1)), ["8 ", "9 ", "10"], "None: left-aligned, trailing spaces")
        XCTAssertEqual(ColumnEditor.numberStrings(count: 3, settings: numbers(9, 1, format: .hex)), ["9", "a", "b"])
        XCTAssertEqual(ColumnEditor.numberStrings(count: 2, settings: numbers(10, 1, format: .hexUppercase)), ["A", "B"])
        XCTAssertEqual(ColumnEditor.numberStrings(count: 3, settings: numbers(1, 1, format: .bin, leading: .zeros)), ["01", "10", "11"])
        XCTAssertEqual(ColumnEditor.numberStrings(count: 2, settings: numbers(7, 1, format: .oct)), ["7 ", "10"])
    }

    func testParsingInTheChosenBase() {
        XCTAssertEqual(ColumnEditor.parse("ff", base: 16), 255)
        XCTAssertEqual(ColumnEditor.parse("", base: 10), 0, "empty reads as 0")
        XCTAssertNil(ColumnEditor.parse("9", base: 8))
        XCTAssertNil(ColumnEditor.parse("-1", base: 10))
        XCTAssertEqual(ColumnEditor.invalidMessage("9", base: 8), "Entered string \"9\":\nOct numbers only use 0-7!")
    }

    func testWithoutASelectionItInsertsFromTheCaretLineDown() {
        let v = editor("ab\nabcdef\na\nxyz")
        v.send(SCI_SETSEL, 5, 5)  // line 1, column 2
        ColumnEditor.apply(numbers(1, 1), to: v)
        XCTAssertEqual(text(v), "ab\nab1cdef\na 2\nxy3z", "short lines are padded to the column")
        v.send(SCI_UNDO)
        XCTAssertEqual(text(v), "ab\nabcdef\na\nxyz", "one undo step")
    }

    func testTextInARectangleReplacesItsContent() {
        let v = editor("aXXb\naXXb\naXXb")
        v.send(SCI_SETRECTANGULARSELECTIONANCHOR, 1)
        v.send(SCI_SETRECTANGULARSELECTIONCARET, 13)
        var s = ColumnEditorSettings()
        s.mode = .text
        s.text = "--"
        ColumnEditor.apply(s, to: v)
        XCTAssertEqual(text(v), "a--b\na--b\na--b")
        XCTAssertEqual(v.send(SCI_GETSELECTIONS), 3, "each line's insert is selected")
    }

    func testAnEmptyColumnPastShortLinesIsPadded() {
        let v = editor("abc\na\nabc")
        v.send(SCI_SETRECTANGULARSELECTIONANCHOR, 2)
        v.send(SCI_SETRECTANGULARSELECTIONCARET, 8)  // column 2 on the first and last line
        ColumnEditor.apply(numbers(1, 1), to: v)
        XCTAssertEqual(text(v).components(separatedBy: "\n").map { $0.count }, [4, 3, 4])
    }

    func testTheDialogValidatesAndRemembers() {
        let suite = "app.macpad.MacPad.tests.columneditor"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let v = editor("x\ny")
        let c = ColumnEditorController(defaults: defaults) { v }
        c.numberRadio.performClick(nil)
        c.initialField.stringValue = "abc"
        XCTAssertFalse(c.readControls())
        XCTAssertEqual(c.errorLabel.stringValue, "Entered string \"abc\":\nDecimal numbers only use 0-9!")
        c.initialField.stringValue = "5"
        c.increaseField.stringValue = "5"
        c.leadingPopup.selectItem(at: 1)
        c.confirm()
        XCTAssertEqual(text(v), "05x\n10y")
        XCTAssertEqual(ColumnEditorSettings.load(defaults).initial, 5)
        XCTAssertEqual(ColumnEditorSettings.load(defaults).leading, .zeros)
        defaults.removePersistentDomain(forName: suite)
    }
}

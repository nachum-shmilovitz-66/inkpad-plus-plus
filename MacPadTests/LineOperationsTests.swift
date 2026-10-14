import XCTest
@testable import MacPad

/// MAC-39: Notepad++'s Line Operations and Blank Operations.
final class LineOperationsTests: XCTestCase {
    private func editor(_ text: String, eol: LineEnding = .lf) -> ScintillaView {
        let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
        v.send(SCI_SETEOLMODE, eol.rawValue)
        v.send(SCI_SETTABWIDTH, 4)
        v.setUTF8Bytes(Data(text.utf8))
        v.send(SCI_EMPTYUNDOBUFFER)
        v.send(SCI_GOTOPOS, 0)
        return v
    }

    private func text(_ v: ScintillaView) -> String { String(decoding: v.utf8Bytes(), as: UTF8.self) }
    private func ops(_ v: ScintillaView) -> LineOperations { LineOperations(editor: v) }

    // MARK: Selection lines

    func testSelectionEndingAtColumnZeroLeavesThatLineOut() {
        let v = editor("a\nb\nc\n")
        v.send(SCI_SETSEL, 0, 4)  // "a\nb\n" — ends at column 0 of line 2
        XCTAssertEqual(ops(v).selectionLines, 0...1)
        v.send(SCI_SETSEL, 2, 2)
        XCTAssertEqual(ops(v).selectionLines, 1...1)
    }

    // MARK: Line Operations

    func testDuplicateAndMove() {
        let v = editor("one\ntwo")
        ops(v).duplicateLine()
        XCTAssertEqual(text(v), "one\none\ntwo")
        v.send(SCI_GOTOLINE, 2)
        ops(v).moveLines(up: true)
        XCTAssertEqual(text(v), "one\ntwo\none")
        ops(v).moveLines(up: false)
        XCTAssertEqual(text(v), "one\none\ntwo")
    }

    func testJoinLines() {
        let v = editor("a\nb \n\nc\nd")
        v.send(SCI_SETSEL, 0, 8)  // ends at column 0 of "d": that line stays out
        ops(v).joinLines()
        XCTAssertEqual(text(v), "a b c\nd", "a space added only where the line does not end with one; empty lines collapse")
        let one = editor("x\ny")
        ops(one).joinLines()
        XCTAssertEqual(text(one), "x\ny", "a single line does nothing")
    }

    func testSplitLinesAtTheEdgeColumn() {
        let v = editor("aaa bbb ccc ddd")
        v.send(SCI_SETEDGEMODE, Int(EDGE_LINE))
        v.send(SCI_SETEDGECOLUMN, 7)
        ops(v).splitLines()
        let lines = text(v).components(separatedBy: "\n")
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertEqual(lines.joined(), "aaa bbb ccc ddd", "only line endings are added")
    }

    func testInsertBlankLines() {
        let v = editor("a\r\nb", eol: .crlf)
        v.send(SCI_GOTOLINE, 1)
        ops(v).insertBlankLine(above: true)
        XCTAssertEqual(text(v), "a\r\n\r\nb")
        XCTAssertEqual(v.send(SCI_LINEFROMPOSITION, v.send(SCI_GETCURRENTPOS)), 1)
        v.send(SCI_GOTOLINE, 2)
        ops(v).insertBlankLine(above: false)
        XCTAssertEqual(text(v), "a\r\n\r\nb\r\n")
        XCTAssertEqual(v.send(SCI_LINEFROMPOSITION, v.send(SCI_GETCURRENTPOS)), 3)
        let top = editor("x")
        ops(top).insertBlankLine(above: true)
        XCTAssertEqual(text(top), "\nx")
    }

    func testRemoveDuplicateLinesKeepsTheFirst() {
        let v = editor("b\na\nb\nc\na")
        ops(v).removeDuplicateLines()
        XCTAssertEqual(text(v), "b\na\nc")
        v.send(SCI_UNDO)
        XCTAssertEqual(text(v), "b\na\nb\nc\na", "one undo step")
        let selected = editor("x\nx\ny\nx\n")
        selected.send(SCI_SETSEL, 0, 6)  // lines 0–2
        ops(selected).removeDuplicateLines()
        XCTAssertEqual(text(selected), "x\ny\nx\n", "only within the selection")
    }

    func testRemoveConsecutiveDuplicateLines() {
        let v = editor("a\na\nb\na\nb\nb")
        ops(v).removeConsecutiveDuplicateLines()
        XCTAssertEqual(text(v), "a\nb\na\nb")
    }

    func testRemoveEmptyLines() {
        let v = editor("a\n\n  \nb\n\n")
        ops(v).removeEmptyLines(includingBlank: false)
        XCTAssertEqual(text(v), "a\n  \nb", "the document's final line ending goes too, as in Notepad++")
        let w = editor("a\n\n \t\nb\n")
        ops(w).removeEmptyLines(includingBlank: true)
        XCTAssertEqual(text(w), "a\nb")
    }

    // MARK: Sorting

    func testLexicographicAndIgnoringCaseSorts() throws {
        let v = editor("b\nB\na\nA")
        try ops(v).sortLines(.lexicographic)
        XCTAssertEqual(text(v), "A\nB\na\nb")
        let w = editor("b\nB\na\nA")
        try ops(w).sortLines(.ignoringCase)
        XCTAssertEqual(text(w), "a\nA\nb\nB", "case-insensitive, ties kept in order")
        let d = editor("a\nc\nb")
        try ops(d).sortLines(.lexicographic, descending: true)
        XCTAssertEqual(text(d), "c\nb\na")
    }

    func testSortingTheWholeDocumentSortsTheFinalEmptyLineToo() throws {
        let v = editor("b\na\n")
        try ops(v).sortLines(.lexicographic)
        XCTAssertEqual(text(v), "\na\nb", "Notepad++'s behaviour with a trailing line ending")
    }

    func testSortingASelectionKeepsTheRest() throws {
        let v = editor("z\nc\nb\na\n")
        v.send(SCI_SETSEL, 2, 8)  // lines 1–3 ("c", "b", "a")
        try ops(v).sortLines(.lexicographic)
        XCTAssertEqual(text(v), "z\na\nb\nc\n")
        XCTAssertEqual(v.send(SCI_GETSELECTIONSTART), 2)
    }

    func testIntegerSortIsNatural() {
        XCTAssertEqual(LineSorterTestHelper.sortIntegers(["item10", "item2", "item1", "-5", "3", "007", "7", "abc"]),
                       ["-5", "3", "007", "7", "abc", "item1", "item2", "item10"], "007 is 7, after 3; then before 7")
        XCTAssertLessThan(LineSorter.naturalCompare("007", "7"), 0, "more leading zeros first")
        XCTAssertLessThan(LineSorter.naturalCompare("-10", "-2"), 0)
    }

    func testDecimalSorts() throws {
        XCTAssertEqual(try LineSorter.sort(["2.5", "abc", "-1", "10", "1e5"], .decimalsDot, descending: false),
                       ["abc", "-1", "1e5", "2.5", "10"], "non-numbers first, in order; 1e5 reads as 1")
        XCTAssertEqual(try LineSorter.sort(["1,5", "1,25"], .decimalsComma, descending: false), ["1,25", "1,5"])
        XCTAssertEqual(try LineSorter.sort(["2", "", "1"], .decimalsDot, descending: true), ["2", "1", ""], "descending: empties last")
        XCTAssertThrowsError(try LineSorter.sort(["1", "-", "2"], .decimalsDot, descending: false)) { error in
            XCTAssertEqual((error as? LineOperations.SortError)?.message, "Unable to perform numeric sorting due to line 2.")
        }
    }

    func testLengthLocaleReverseAndColumnSorts() throws {
        XCTAssertEqual(try LineSorter.sort(["ccc", "a", "bb"], .length, descending: false), ["a", "bb", "ccc"])
        XCTAssertEqual(try LineSorter.sort(["file10", "File2", "file1"], .locale, descending: false), ["file1", "File2", "file10"])
        XCTAssertEqual(try LineSorter.sort(["1", "2", "3"], .reverse, descending: false), ["3", "2", "1"])
        XCTAssertEqual(try LineSorter.sort(["x b", "y a", "z c"], .lexicographic, descending: false, columns: 2..<3), ["y a", "x b", "z c"])
        XCTAssertEqual(Set(try LineSorter.sort(["1", "2", "3"], .randomize, descending: false)), ["1", "2", "3"])
    }

    func testAColumnSelectionSortsByTheSelectedColumns() throws {
        let v = editor("x b\ny a\nz c")
        v.send(SCI_SETRECTANGULARSELECTIONANCHOR, 2)
        v.send(SCI_SETRECTANGULARSELECTIONCARET, 11)
        try ops(v).sortLines(.lexicographic)
        XCTAssertEqual(text(v), "y a\nx b\nz c")
    }

    func testANumericSortErrorLeavesTheTextAlone() {
        let v = editor("1\n.\n2")
        XCTAssertThrowsError(try ops(v).sortLines(.decimalsDot))
        XCTAssertEqual(text(v), "1\n.\n2")
    }

    // MARK: Blank Operations

    func testTrims() {
        let v = editor("  a  \n\tb\t\n")
        ops(v).trim(.trailing)
        XCTAssertEqual(text(v), "  a\n\tb\n")
        ops(v).trim(.leading)
        XCTAssertEqual(text(v), "a\nb\n")
        let w = editor(" x \n y \n z ")
        w.send(SCI_SETSEL, 4, 7)
        ops(w).trim(.both)
        XCTAssertEqual(text(w), " x \ny\n z ", "only the selected line")
    }

    func testEOLToSpace() {
        let v = editor("a\nb\n")
        ops(v).eolToSpace()
        XCTAssertEqual(text(v), "a b ")
        let w = editor(" a \n b ")
        ops(w).trimAndEolToSpace()
        XCTAssertEqual(text(w), "a b")
    }

    func testTabAndSpaceConversions() {
        XCTAssertEqual(LineOperations.tabsToSpaces("a\tb\t\tc", tabWidth: 4), "a   b       c")
        XCTAssertEqual(LineOperations.spacesToTabs("    x   y", tabWidth: 4, leadingOnly: false), "\tx\ty")
        XCTAssertEqual(LineOperations.spacesToTabs("    x       y", tabWidth: 4, leadingOnly: true), "\tx       y")
        XCTAssertEqual(LineOperations.spacesToTabs("abc d", tabWidth: 4, leadingOnly: false), "abc d", "a lone space at a stop stays")
        let v = editor("\tx\n  \ty")
        ops(v).convertTabs(.tabToSpace)
        XCTAssertEqual(text(v), "    x\n    y")
        v.send(SCI_UNDO)
        XCTAssertEqual(text(v), "\tx\n  \ty", "one undo step")
    }
}

private enum LineSorterTestHelper {
    static func sortIntegers(_ lines: [String]) -> [String] {
        (try? LineSorter.sort(lines, .integers, descending: false)) ?? []
    }
}

import XCTest
@testable import Inkpad

// MAC-34: incremental search and Go To.

private func makeEditor(_ text: String) -> ScintillaView {
    let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    EditorStyler.configureEditor(v)
    v.setUTF8Bytes(Data(text.utf8))
    v.send(SCI_GOTOPOS, 0)
    return v
}

private func selection(_ v: ScintillaView) -> Range<Int> { v.send(SCI_GETSELECTIONSTART)..<v.send(SCI_GETSELECTIONEND) }

final class IncrementalSearchTests: XCTestCase {
    func testTypingReMatchesFromTheCurrentMatch() {
        let v = makeEditor("ab abc abcd")
        let s = IncrementalSearch(editor: v)
        XCTAssertEqual(s.search("a", matchCase: false, kind: .first), .found)
        XCTAssertEqual(selection(v), 0..<1)
        XCTAssertEqual(s.search("ab", matchCase: false, kind: .first), .found)
        XCTAssertEqual(selection(v), 0..<2, "the match grows in place")
        XCTAssertEqual(s.search("abc", matchCase: false, kind: .first), .found)
        XCTAssertEqual(selection(v), 3..<6, "then moves to the next place it fits")
        XCTAssertEqual(v.send(SCI_GETCURRENTPOS), 6, "caret at the end")
    }

    func testNextAndPreviousWrapWithNotes() {
        let v = makeEditor("x1 x2 x3")
        let s = IncrementalSearch(editor: v)
        s.search("x", matchCase: false, kind: .first)
        XCTAssertEqual(s.search("x", matchCase: false, kind: .next), .found)
        XCTAssertEqual(selection(v), 3..<4)
        s.search("x", matchCase: false, kind: .next)
        XCTAssertEqual(s.search("x", matchCase: false, kind: .next), .endReached)
        XCTAssertEqual(selection(v), 0..<1)
        XCTAssertEqual(s.search("x", matchCase: false, kind: .previous), .topReached)
        XCTAssertEqual(selection(v), 6..<7)
    }

    func testLiteralTextAndMatchCase() {
        let v = makeEditor("A.c abc a.c")
        let s = IncrementalSearch(editor: v)
        XCTAssertEqual(s.search("a.c", matchCase: true, kind: .first), .found)
        XCTAssertEqual(selection(v), 8..<11, "no regex: the dot is literal; case kept")
        XCTAssertEqual(s.search("zzz", matchCase: false, kind: .first), .notFound)
        XCTAssertEqual(selection(v), 8..<11, "a failed search leaves the selection")
    }

    func testStatusText() {
        XCTAssertEqual(IncrementalSearch.statusText(.found, nth: 3, total: 1204), "3/1,204")
        XCTAssertEqual(IncrementalSearch.statusText(.endReached, nth: 1, total: 12), "1/12 - Reached end of page, continued from top")
        XCTAssertEqual(IncrementalSearch.statusText(.topReached, nth: nil, total: nil), "Reached top of page, continued from bottom")
        XCTAssertEqual(IncrementalSearch.statusText(.notFound, nth: 1, total: 2), "Phrase not found")
        XCTAssertEqual(IncrementalSearch.statusText(.found, nth: nil, total: nil), "")
    }

    func testHighlightAllMarksTheSelectedMatchEverywhere() {
        let v = makeEditor("Go go GO")
        let s = IncrementalSearch(editor: v)
        s.search("go", matchCase: false, kind: .first)
        s.highlightAll(enabled: true, fieldText: "go", matchCase: false)
        XCTAssertEqual(Marker(editor: v).ranges(of: MarkIndicator.incremental), [0..<2, 3..<5, 6..<8])
        s.highlightAll(enabled: true, fieldText: "go", matchCase: true)
        XCTAssertEqual(Marker(editor: v).ranges(of: MarkIndicator.incremental), [0..<2], "the selected text, \"Go\", with case")
        s.highlightAll(enabled: false, fieldText: "go", matchCase: false)
        XCTAssertEqual(Marker(editor: v).ranges(of: MarkIndicator.incremental), [])
        XCTAssertEqual(v.send(SCI_INDICGETFORE, MarkIndicator.incremental), scintillaColour(fromHex: "0080FF"))
    }
}

final class IncrementalSearchBarTests: XCTestCase {
    func testTheBarCountsColoursAndCloses() {
        let v = makeEditor("cat dog cat cat")
        let bar = IncrementalSearchBar()
        bar.editorProvider = { v }
        bar.field.stringValue = "cat"
        bar.textChanged()
        XCTAssertEqual(bar.statusLabel.stringValue, "1/3")
        bar.next()
        XCTAssertEqual(bar.statusLabel.stringValue, "2/3")
        bar.previous()
        bar.previous()
        XCTAssertEqual(bar.statusLabel.stringValue, "3/3 - Reached top of page, continued from bottom")
        bar.field.stringValue = "cow"
        bar.textChanged()
        XCTAssertEqual(bar.statusLabel.stringValue, "Phrase not found")
        XCTAssertEqual(bar.field.textColor, .white, "red field, white text")
        bar.field.stringValue = ""
        bar.textChanged()
        XCTAssertEqual(bar.statusLabel.stringValue, "")
        XCTAssertEqual(bar.field.textColor, .textColor)
        bar.highlightAllBox.state = .on
        bar.field.stringValue = "dog"
        bar.textChanged()
        XCTAssertEqual(Marker(editor: v).ranges(of: MarkIndicator.incremental), [4..<7])
        bar.close()
        XCTAssertTrue(bar.isHidden)
        XCTAssertEqual(Marker(editor: v).ranges(of: MarkIndicator.incremental), [], "closing clears the highlight")
        XCTAssertEqual(bar.field.stringValue, "dog", "the text stays for next time")
    }

    func testCountOffAndAStaleCount() {
        let v = makeEditor("a a")
        let bar = IncrementalSearchBar()
        bar.editorProvider = { v }
        bar.isHidden = false
        bar.countBox.state = .off
        bar.field.stringValue = "a"
        bar.textChanged()
        XCTAssertEqual(bar.statusLabel.stringValue, "")
        bar.countBox.state = .on
        bar.next()
        XCTAssertEqual(bar.statusLabel.stringValue, "2/2")
        v.send(SCI_APPENDTEXT, 2, string: " a")
        bar.resetCount()
        XCTAssertEqual(bar.statusLabel.stringValue, "", "the document changed: the count is cleared")
        bar.next()
        XCTAssertEqual(bar.statusLabel.stringValue, "3/3")
    }

    func testOpeningUsesTheSelection() {
        let v = makeEditor("one two two")
        v.send(SCI_SETSEL, 4, 7)
        let bar = IncrementalSearchBar()
        bar.editorProvider = { v }
        bar.open()
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(bar.field.stringValue, "two")
        XCTAssertEqual(bar.statusLabel.stringValue, "1/2")
    }

    func testTheMainWindowResetsTheCountWhenTheTextChanges() {
        let window = MainWindowController()
        let tab = window.newTab()
        tab.editor.setUTF8Bytes(Data("x x".utf8))
        window.incrementalBar.isHidden = false
        window.incrementalBar.field.stringValue = "x"
        window.incrementalBar.textChanged()
        XCTAssertEqual(window.incrementalBar.statusLabel.stringValue, "1/2")
        tab.editor.send(SCI_APPENDTEXT, 2, string: " x")
        XCTAssertEqual(window.incrementalBar.statusLabel.stringValue, "", "an edit makes the count stale")
        window.openTabs.forEach { $0.detach() }
    }
}

final class GoToTests: XCTestCase {
    func testLineMode() {
        let v = makeEditor("one\ntwo\nthree")
        v.send(SCI_GOTOPOS, 6)
        XCTAssertEqual(GoTo.current(v, mode: .line), 2)
        XCTAssertEqual(GoTo.maximum(v, mode: .line), 3)
        GoTo.go(v, mode: .line, to: 3)
        XCTAssertEqual(v.send(SCI_GETCURRENTPOS), 8, "column 0 of line 3")
        GoTo.go(v, mode: .line, to: 99)
        XCTAssertEqual(v.send(SCI_LINEFROMPOSITION, v.send(SCI_GETCURRENTPOS)), 2, "past the end: the last line")
        GoTo.go(v, mode: .line, to: 0)
        XCTAssertEqual(v.send(SCI_GETCURRENTPOS), 0)
    }

    func testOffsetModeIsBytesAndStaysOnCharacters() {
        let v = makeEditor("שלום\r\nx")
        v.send(SCI_GOTOPOS, 8)
        XCTAssertEqual(GoTo.current(v, mode: .offset), 8)
        XCTAssertEqual(GoTo.maximum(v, mode: .offset), 10)
        GoTo.go(v, mode: .offset, to: 3)
        XCTAssertEqual(v.send(SCI_GETCURRENTPOS), 4, "not inside a Hebrew letter")
        GoTo.go(v, mode: .offset, to: 9)
        XCTAssertEqual(v.send(SCI_GETCURRENTPOS), 10, "not between CR and LF")
        GoTo.go(v, mode: .offset, to: 500)
        XCTAssertEqual(v.send(SCI_GETCURRENTPOS), 11, "past the end: the end")
    }

    func testParsing() {
        XCTAssertNil(GoTo.parse(""))
        XCTAssertNil(GoTo.parse("  "))
        XCTAssertEqual(GoTo.parse("42"), 42)
        XCTAssertEqual(GoTo.parse("12abc"), 12)
        XCTAssertEqual(GoTo.parse("abc"), 0)
    }

    func testTheDialogGoesAndForgetsTheTypedValue() {
        let v = makeEditor("a\nb\nc\nd")
        let dialog = GoToLineController { v }
        dialog.refresh()
        XCTAssertEqual(dialog.currentLabel.stringValue, "1")
        XCTAssertEqual(dialog.maximumLabel.stringValue, "4")
        dialog.targetField.stringValue = "3"
        dialog.go()
        XCTAssertEqual(v.send(SCI_LINEFROMPOSITION, v.send(SCI_GETCURRENTPOS)), 2)
        XCTAssertEqual(dialog.targetField.stringValue, "")
        dialog.offsetRadio.performClick(nil)
        XCTAssertEqual(dialog.mode, .offset)
        XCTAssertEqual(dialog.currentLabel.stringValue, "4")
        XCTAssertEqual(dialog.maximumLabel.stringValue, "6")
        dialog.go()  // empty: nothing moves
        XCTAssertEqual(v.send(SCI_GETCURRENTPOS), 4)
    }
}

import XCTest
@testable import Inkpad

// MAC-31: Mark All, the five token styles and bookmarks, on a real Scintilla view.

private func makeEditor(_ text: String) -> ScintillaView {
    let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    EditorStyler.configureEditor(v)
    v.setUTF8Bytes(Data(text.utf8))
    v.send(SCI_EMPTYUNDOBUFFER)
    v.send(SCI_GOTOPOS, 0)
    return v
}

private func text(_ v: ScintillaView) -> String { String(decoding: v.utf8Bytes(), as: UTF8.self) }

final class MarkAllTests: XCTestCase {
    func testMarkAllPaintsEveryMatchWithTheFindMark() {
        let v = makeEditor("cat dog cat\ncat")
        let marker = Marker(editor: v)
        XCTAssertEqual(marker.markAll("cat", options: SearchOptions(), bookmarkLine: false, purge: false), .done(3, scope: .entireFile))
        XCTAssertEqual(marker.ranges(of: MarkIndicator.findMark), [0..<3, 8..<11, 12..<15])
        XCTAssertEqual(marker.bookmarkedLines, [])
    }

    func testBookmarkLineBookmarksEachLineAMatchSpans() {
        let v = makeEditor("a\nxy\nb\nx\ny")
        let marker = Marker(editor: v)
        _ = marker.markAll("x\\ny", options: SearchOptions(mode: .extended), bookmarkLine: true, purge: false)
        XCTAssertEqual(marker.bookmarkedLines, [3, 4], "the match x⏎y spans lines 3 and 4; 'xy' on line 1 is not a match")
    }

    func testMarksAccumulateUnlessPurged() {
        let v = makeEditor("one two")
        let marker = Marker(editor: v)
        _ = marker.markAll("one", options: SearchOptions(), bookmarkLine: false, purge: false)
        _ = marker.markAll("two", options: SearchOptions(), bookmarkLine: false, purge: false)
        XCTAssertEqual(marker.ranges(of: MarkIndicator.findMark), [0..<3, 4..<7])
        _ = marker.markAll("two", options: SearchOptions(), bookmarkLine: false, purge: true)
        XCTAssertEqual(marker.ranges(of: MarkIndicator.findMark), [4..<7])
    }

    func testPurgeDoesNothingWithoutSearchText() {
        let v = makeEditor("one")
        let marker = Marker(editor: v)
        _ = marker.markAll("one", options: SearchOptions(), bookmarkLine: false, purge: false)
        _ = marker.markAll("", options: SearchOptions(), bookmarkLine: false, purge: true)
        XCTAssertEqual(marker.ranges(of: MarkIndicator.findMark), [0..<3])
    }

    func testEmptyRegexMatchesAreNotMarked() {
        let v = makeEditor("ab\ncd")
        XCTAssertEqual(Marker(editor: v).markAll("^", options: SearchOptions(mode: .regex), bookmarkLine: true, purge: false),
                       .done(0, scope: .entireFile))
        XCTAssertEqual(Marker(editor: v).bookmarkedLines, [])
    }

    func testClearMarksKeepsBookmarksUnlessBookmarkLineIsTicked() {
        let v = makeEditor("x\nx")
        let marker = Marker(editor: v)
        _ = marker.markAll("x", options: SearchOptions(), bookmarkLine: true, purge: false)
        marker.clearMarks(inSelection: false, bookmarkLine: false)
        XCTAssertEqual(marker.ranges(of: MarkIndicator.findMark), [])
        XCTAssertEqual(marker.bookmarkedLines, [0, 1])
        marker.clearMarks(inSelection: false, bookmarkLine: true)
        XCTAssertEqual(marker.bookmarkedLines, [])
    }

    func testClearMarksInSelection() {
        let v = makeEditor("x\nx\nx")
        let marker = Marker(editor: v)
        _ = marker.markAll("x", options: SearchOptions(), bookmarkLine: true, purge: false)
        v.send(SCI_SETSEL, 2, 5)  // line 1 and the start of line 2
        marker.clearMarks(inSelection: true, bookmarkLine: true)
        XCTAssertEqual(marker.ranges(of: MarkIndicator.findMark), [0..<1])
        XCTAssertEqual(marker.bookmarkedLines, [0])
    }

    func testCopyMarkedTextJoinsWithCRLF() {
        let v = makeEditor("ab cd ab")
        let marker = Marker(editor: v)
        XCTAssertNil(marker.markedText([MarkIndicator.findMark]), "nothing marked: the clipboard is left alone")
        _ = marker.markAll("ab", options: SearchOptions(), bookmarkLine: false, purge: false)
        XCTAssertEqual(marker.markedText([MarkIndicator.findMark]), "ab\r\nab\r\n")
        let one = makeEditor("ab cd")
        _ = Marker(editor: one).markAll("cd", options: SearchOptions(), bookmarkLine: false, purge: false)
        XCTAssertEqual(Marker(editor: one).markedText([MarkIndicator.findMark]), "cd", "a single piece has no trailing line break")
    }

    func testCopyMarkedTextSeparatesMultiLinePieces() {
        let v = makeEditor("a\nb c a\nb")
        _ = Marker(editor: v).markAll("a\\nb", options: SearchOptions(mode: .extended), bookmarkLine: false, purge: false)
        XCTAssertEqual(Marker(editor: v).markedText([MarkIndicator.findMark]), "a\nb\r\n----\r\na\nb\r\n")
    }
}

final class TokenStyleTests: XCTestCase {
    func testStyleAllOccurrencesUsesTheWordAtTheCaretAsAWholeWordIgnoringCase() {
        let v = makeEditor("Foo food foo")
        v.send(SCI_GOTOPOS, 1)
        let marker = Marker(editor: v)
        XCTAssertEqual(marker.styleAllOccurrences(style: 0), 2)
        XCTAssertEqual(marker.ranges(of: MarkIndicator.styles[0]), [0..<3, 9..<12])
        XCTAssertEqual(v.send(SCI_GETSELECTIONEND), 3, "the word at the caret becomes selected")
    }

    func testEachStyleIsItsOwnIndicatorAndClearAllLeavesTheFindMark() {
        let v = makeEditor("a b")
        let marker = Marker(editor: v)
        v.send(SCI_SETSEL, 0, 1)
        marker.styleOneToken(style: 2)
        v.send(SCI_SETSEL, 2, 3)
        marker.styleOneToken(style: 4)
        _ = marker.markAll("a", options: SearchOptions(), bookmarkLine: false, purge: false)
        XCTAssertEqual(marker.ranges(of: MarkIndicator.styles[2]), [0..<1])
        XCTAssertEqual(marker.ranges(of: MarkIndicator.styles[4]), [2..<3])
        marker.clearStyle(MarkIndicator.styles[2])
        XCTAssertEqual(marker.ranges(of: MarkIndicator.styles[2]), [])
        marker.clearAllStyles()
        XCTAssertEqual(marker.ranges(of: MarkIndicator.styles[4]), [])
        XCTAssertEqual(marker.ranges(of: MarkIndicator.findMark), [0..<1])
    }

    func testJumpDownAndUpWrap() {
        let v = makeEditor("x a x a x")
        let marker = Marker(editor: v)
        _ = marker.markAll("x", options: SearchOptions(), bookmarkLine: false, purge: false)
        v.send(SCI_GOTOPOS, 1)
        XCTAssertTrue(marker.jump(to: MarkIndicator.findMark, down: true))
        XCTAssertEqual([v.send(SCI_GETSELECTIONSTART), v.send(SCI_GETSELECTIONEND), v.send(SCI_GETCURRENTPOS)], [4, 5, 5])
        XCTAssertTrue(marker.jump(to: MarkIndicator.findMark, down: true))
        XCTAssertTrue(marker.jump(to: MarkIndicator.findMark, down: true))
        XCTAssertEqual(v.send(SCI_GETSELECTIONSTART), 0, "wrapped to the top")
        XCTAssertTrue(marker.jump(to: MarkIndicator.findMark, down: false))
        XCTAssertEqual([v.send(SCI_GETSELECTIONSTART), v.send(SCI_GETCURRENTPOS)], [8, 8], "wrapped to the bottom, caret at the start")
        XCTAssertTrue(marker.jump(to: MarkIndicator.findMark, down: false))
        XCTAssertEqual(v.send(SCI_GETSELECTIONSTART), 4)
        XCTAssertFalse(marker.jump(to: MarkIndicator.styles[0], down: true), "no range of that style")
    }

    func testCopyStyledTextOfAllStylesIsInDocumentOrder() {
        let v = makeEditor("aa bb cc")
        let marker = Marker(editor: v)
        v.send(SCI_SETSEL, 6, 8)
        marker.styleOneToken(style: 0)
        v.send(SCI_SETSEL, 0, 2)
        marker.styleOneToken(style: 3)
        XCTAssertEqual(marker.markedText(MarkIndicator.styles), "aa\r\ncc\r\n")
    }

    func testIndicatorsUseUpstreamColoursAndStyle() {
        let v = makeEditor("")
        XCTAssertEqual(v.send(SCI_INDICGETSTYLE, MarkIndicator.findMark), Int(INDIC_ROUNDBOX))
        XCTAssertEqual(v.send(SCI_INDICGETALPHA, MarkIndicator.findMark), 100)
        XCTAssertEqual(v.send(SCI_INDICGETUNDER, MarkIndicator.styles[0]), 1)
        XCTAssertEqual(v.send(SCI_INDICGETFORE, MarkIndicator.findMark), scintillaColour(fromHex: "FF0000"))
        XCTAssertEqual(v.send(SCI_INDICGETFORE, MarkIndicator.styles[1]), scintillaColour(fromHex: "FF8000"))
    }
}

final class BookmarkTests: XCTestCase {
    func testToggleAndNavigateWithWrap() {
        let v = makeEditor("0\n1\n2\n3\n4")
        let marker = Marker(editor: v)
        marker.toggleBookmark(1)
        marker.toggleBookmark(3)
        XCTAssertEqual(marker.bookmarkedLines, [1, 3])
        XCTAssertTrue(marker.gotoBookmark(next: true))
        XCTAssertEqual(v.send(SCI_LINEFROMPOSITION, v.send(SCI_GETCURRENTPOS)), 1)
        marker.gotoBookmark(next: true)
        marker.gotoBookmark(next: true)
        XCTAssertEqual(v.send(SCI_LINEFROMPOSITION, v.send(SCI_GETCURRENTPOS)), 1, "wrapped")
        marker.gotoBookmark(next: false)
        XCTAssertEqual(v.send(SCI_LINEFROMPOSITION, v.send(SCI_GETCURRENTPOS)), 3, "wrapped backwards")
        marker.toggleBookmark()
        XCTAssertEqual(marker.bookmarkedLines, [1], "no argument: the caret line")
        marker.clearAllBookmarks()
        XCTAssertFalse(marker.gotoBookmark(next: true))
    }

    func testCopyAndCutBookmarkedLinesKeepTheirLineEndings() {
        let v = makeEditor("a\r\nb\r\nc\r\nd")
        let marker = Marker(editor: v)
        marker.setBookmarks([1, 3])
        XCTAssertEqual(marker.bookmarkedLinesText(), "b\r\nd")
        XCTAssertEqual(marker.cutBookmarkedLines(), "b\r\nd")
        XCTAssertEqual(text(v), "a\r\nc\r\n", "the last line goes, the previous line ending stays")
        XCTAssertEqual(marker.bookmarkedLines, [])
        v.send(SCI_UNDO)
        XCTAssertEqual(text(v), "a\r\nb\r\nc\r\nd", "one undo step")
    }

    func testRemoveBookmarkedAndNonBookmarkedLines() {
        let v = makeEditor("a\nb\nc\n")
        Marker(editor: v).setBookmarks([0, 2])
        Marker(editor: v).removeUnbookmarkedLines()
        XCTAssertEqual(text(v), "a\nc\n", "the empty last line is not bookmarked either")
        let w = makeEditor("a\nb\nc")
        Marker(editor: w).setBookmarks([1])
        Marker(editor: w).removeBookmarkedLines()
        XCTAssertEqual(text(w), "a\nc")
    }

    func testPasteReplacesEachBookmarkedLineKeepingItsLineEnding() {
        let v = makeEditor("a\nb\nc")
        let marker = Marker(editor: v)
        marker.setBookmarks([0, 2])
        marker.replaceBookmarkedLines(with: "X")
        XCTAssertEqual(text(v), "X\nb\nX")
        v.send(SCI_UNDO)
        XCTAssertEqual(text(v), "a\nb\nc")
    }

    func testInverse() {
        let v = makeEditor("a\nb\nc")
        let marker = Marker(editor: v)
        marker.setBookmarks([1])
        marker.inverseBookmarks()
        XCTAssertEqual(marker.bookmarkedLines, [0, 2])
    }

    func testSetBookmarksIgnoresLinesPastTheEnd() {
        let v = makeEditor("a\nb")
        Marker(editor: v).setBookmarks([1, 7, -1])
        XCTAssertEqual(Marker(editor: v).bookmarkedLines, [1])
    }

    func testTheBookmarkMarginShowsTheBookmarkImage() {
        let v = makeEditor("a")
        XCTAssertEqual(v.send(SCI_GETMARGINMASKN, Margin.symbol) & (1 << MarkIndicator.bookmark), 1 << MarkIndicator.bookmark)
        XCTAssertEqual(v.send(SCI_MARKERSYMBOLDEFINED, MarkIndicator.bookmark), Int(SC_MARK_RGBAIMAGE))
        XCTAssertEqual(v.send(SCI_GETMARGINSENSITIVEN, Margin.symbol), 1)
    }

    func testBookmarkImageIsAnOpaqueBlueBallWithTransparentCorners() {
        let size = 28
        let pixels = EditorStyler.bookmarkImage(points: 14, scale: 2)
        XCTAssertEqual(pixels.count, size * size * 4)
        XCTAssertEqual(pixels[3], 0, "transparent corner")
        let centre = (size / 2 * size + size / 2) * 4
        XCTAssertEqual(pixels[centre + 3], 255)
        XCTAssertGreaterThan(pixels[centre + 2], pixels[centre], "blue")
    }

    func testBookmarksSurviveInTheSessionAndOldSessionsStillLoad() throws {
        let doc = SessionState.Document(path: "/tmp/x.txt", bookmarks: [2, 5])
        let data = try JSONEncoder().encode(SessionState(documents: [doc]))
        XCTAssertEqual(try JSONDecoder().decode(SessionState.self, from: data).documents.first?.bookmarks, [2, 5])
        let old = #"{"version":1,"activeIndex":0,"documents":[{"path":"/tmp/x.txt","caretPosition":0,"firstVisibleLine":0}]}"#
        XCTAssertEqual(try JSONDecoder().decode(SessionState.self, from: Data(old.utf8)).documents.first?.bookmarks, [])
    }

    func testEditorTabExposesBookmarks() {
        let tab = EditorTab(untitledNumber: 1)
        tab.editor.setUTF8Bytes(Data("a\nb\nc".utf8))
        tab.bookmarks = [0, 2]
        XCTAssertEqual(tab.bookmarks, [0, 2])
        tab.detach()
    }
}

final class MarkTabTests: XCTestCase {
    private let suite = "app.inkpad.Inkpad.tests.mark"

    override func tearDown() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testMarkTabFromTheDialog() {
        let v = makeEditor("err ok err")
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let c = FindReplaceController(defaults: defaults) { v }
        c.setTab(.mark)
        XCTAssertFalse(c.markAllButton.isHidden)
        XCTAssertTrue(c.findNextButton.isHidden)
        XCTAssertFalse(c.bookmarkLineBox.isHidden)
        c.findField.stringValue = "err"
        c.bookmarkLineBox.performClick(nil)
        c.markAll()
        XCTAssertEqual(c.status, SearchMessages.marked(2, scope: .entireFile))
        XCTAssertEqual(c.status?.text, "Mark: 2 matches in entire file")
        XCTAssertEqual(Marker(editor: v).bookmarkedLines, [0])
        c.copyMarkedText()
        XCTAssertEqual(AppEnvironment.pasteboard.string(forType: .string), "err\r\nerr\r\n")
        XCTAssertNotEqual(AppEnvironment.pasteboard, NSPasteboard.general, "the tests leave the user's clipboard alone")
        c.clearMarks()
        XCTAssertEqual(Marker(editor: v).ranges(of: MarkIndicator.findMark), [])
        XCTAssertEqual(Marker(editor: v).bookmarkedLines, [], "Bookmark line is ticked, so they go too")
        XCTAssertNil(c.status)
        c.setTab(.find)
        XCTAssertTrue(c.markAllButton.isHidden)
        XCTAssertTrue(c.bookmarkLineBox.isHidden)
    }

    func testEveryTabFitsItsControlsInsideTheMargins() throws {
        let defaults = UserDefaults(suiteName: suite)!
        let c = FindReplaceController(defaults: defaults) { makeEditor("") }
        let content = try XCTUnwrap(c.window?.contentView)
        for tab in [FindReplaceController.Tab.find, .replace, .mark] {
            c.setTab(tab)
            content.layoutSubtreeIfNeeded()
            for button in [c.findNextButton, c.countButton, c.findAllCurrentButton, c.findAllOpenedButton, c.replaceButton,
                           c.replaceAllButton, c.replaceAllOpenedButton, c.markAllButton, c.clearMarksButton,
                           c.copyMarkedButton] where !button.isHidden {
                let frame = button.convert(button.bounds, to: content)
                XCTAssertLessThanOrEqual(frame.maxX, content.bounds.width - 12, "\(button.title) on \(tab)")
            }
            let field = c.findField.convert(c.findField.bounds, to: content)
            XCTAssertGreaterThanOrEqual(field.minX, 12)
        }
    }
}

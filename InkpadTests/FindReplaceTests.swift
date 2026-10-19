import XCTest
@testable import Inkpad

// MAC-30: upstream's Find / Replace — the model, the engine on a real Scintilla view, and the dialog.

private func makeEditor(_ text: String) -> ScintillaView {
    let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    v.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
    v.setUTF8Bytes(Data(text.utf8))
    v.send(SCI_EMPTYUNDOBUFFER)
    v.send(SCI_GOTOPOS, 0)
    return v
}

private func text(_ v: ScintillaView) -> String { String(decoding: v.utf8Bytes(), as: UTF8.self) }
private func selection(_ v: ScintillaView) -> SearchEngine.Match {
    SearchEngine.Match(start: v.send(SCI_GETSELECTIONSTART), end: v.send(SCI_GETSELECTIONEND))
}

final class ExtendedEscapesTests: XCTestCase {
    func testSimpleEscapes() {
        XCTAssertEqual(ExtendedEscapes.convert("a\\nb\\rc\\td\\\\e"), "a\nb\rc\td\\e")
        XCTAssertEqual(ExtendedEscapes.convert("x\\0y"), "x\u{0}y")
    }

    func testNumericEscapesNeedTheExactDigitCount() {
        XCTAssertEqual(ExtendedEscapes.convert("\\x41\\d066\\o103\\b01000100\\u05D0"), "ABCDא")
        XCTAssertEqual(ExtendedEscapes.convert("\\x6a"), "j", "hex letters in either case")
        XCTAssertEqual(ExtendedEscapes.convert("\\x4"), "\\x4", "too few characters left")
        XCTAssertEqual(ExtendedEscapes.convert("\\xZZ"), "\\xZZ", "not hex digits")
        XCTAssertEqual(ExtendedEscapes.convert("\\d09a"), "\\d09a")
        XCTAssertEqual(ExtendedEscapes.convert("\\o8"), "\\o8")
        XCTAssertEqual(ExtendedEscapes.convert("\\b0102"), "\\b0102")
    }

    func testUnknownEscapesAndATrailingBackslashStayAsWritten() {
        XCTAssertEqual(ExtendedEscapes.convert("\\q\\"), "\\q\\")
        XCTAssertEqual(ExtendedEscapes.convert("plain"), "plain")
    }
}

final class SearchOptionsTests: XCTestCase {
    func testUpstreamDefaults() {
        let o = SearchOptions()
        XCTAssertEqual(o.mode, .normal)
        XCTAssertFalse(o.matchCase)
        XCTAssertFalse(o.wholeWord)
        XCTAssertTrue(o.wrapAround)
        XCTAssertFalse(o.backward)
        XCTAssertFalse(o.inSelection)
        XCTAssertFalse(o.dotMatchesNewline)
    }

    func testSearchFlags() {
        var o = SearchOptions()
        XCTAssertEqual(o.searchFlags, 0)
        o.matchCase = true
        o.wholeWord = true
        XCTAssertEqual(o.searchFlags, Int(SCFIND_MATCHCASE) | Int(SCFIND_WHOLEWORD))
        o.mode = .regex
        o.dotMatchesNewline = true
        XCTAssertEqual(o.searchFlags, Int(SCFIND_MATCHCASE) | Int(SCFIND_REGEXP) | Int(SCFIND_POSIX) | Int(SCFIND_REGEXP_DOTMATCHESNL),
                       "whole word is off in Regex mode")
        o.mode = .extended
        XCTAssertEqual(o.searchFlags & Int(SCFIND_REGEXP_DOTMATCHESNL), 0, ". matches newline is Regex only")
    }

    func testRegexDisablesBackwardAndWholeWord() {
        var o = SearchOptions(mode: .regex, wholeWord: true, backward: true)
        XCTAssertFalse(o.effectiveBackward)
        XCTAssertFalse(o.effectiveWholeWord)
        o.mode = .normal
        XCTAssertTrue(o.effectiveBackward)
        XCTAssertTrue(o.effectiveWholeWord)
    }

    func testExtendedModePreparesTheText() {
        XCTAssertEqual(SearchOptions(mode: .extended).prepared("a\\tb"), "a\tb")
        XCTAssertEqual(SearchOptions(mode: .normal).prepared("a\\tb"), "a\\tb")
        XCTAssertEqual(SearchOptions(mode: .regex).prepared("a\\tb"), "a\\tb", "Boost reads its own escapes")
    }
}

final class FindHistoryTests: XCTestCase {
    func testMostRecentFirstWithoutDuplicatesIgnoringCase() {
        var h = FindHistory()
        h.add("alpha")
        h.add("beta")
        h.add("")
        h.add("ALPHA")
        XCTAssertEqual(h.items, ["ALPHA", "beta"])
    }

    func testOnlyTenShortEntriesAreSaved() {
        var h = FindHistory()
        (1...12).forEach { h.add("item \($0)") }
        h.add(String(repeating: "x", count: FindHistory.savedLengthLimit))
        XCTAssertEqual(h.items.count, 13, "unlimited during the session")
        XCTAssertEqual(h.saved, (3...12).reversed().map { "item \($0)" })
    }
}

final class SearchMessagesTests: XCTestCase {
    func testUpstreamWording() {
        XCTAssertEqual(SearchMessages.cantFind("foo", scope: .entireFile).text, "Find: Can't find the text \"foo\" in entire file")
        XCTAssertEqual(SearchMessages.cantFind("foo", scope: .caretToEnd).kind, .notFound)
        XCTAssertEqual(SearchMessages.count(1, scope: .selection).text, "Count: 1 match in selected text")
        XCTAssertEqual(SearchMessages.replacedAll(1, scope: .entireFile).text, "Replace All: 1 occurrence was replaced in entire file")
        XCTAssertEqual(SearchMessages.replacedAll(1234, scope: .startToCaret).text,
                       "Replace All: 1234 occurrences were replaced from start-of-file to caret")
        XCTAssertEqual(SearchMessages.endReached.kind, .wrapped)
        XCTAssertEqual(SearchMessages.replacedNextFound.kind, .message)
    }

    func testCountGroupsThousands() {
        let text = SearchMessages.count(12345, scope: .entireFile).text
        XCTAssertTrue(text.hasPrefix("Count: 12"), text)
        XCTAssertTrue(text.hasSuffix("345 matches in entire file"), text)
        XCTAssertFalse(text.contains("12345"), "grouped like upstream's count")
    }

    func testLongTextIsAbbreviated() {
        XCTAssertEqual(SearchMessages.abbreviated(String(repeating: "a", count: 32)), String(repeating: "a", count: 32))
        XCTAssertEqual(SearchMessages.abbreviated(String(repeating: "a", count: 33)), String(repeating: "a", count: 28) + "...")
    }

    func testHintOnlyWhenTheOptionsWereNotTheWidest() {
        XCTAssertNil(SearchMessages.hint(for: SearchOptions()))
        XCTAssertNotNil(SearchMessages.hint(for: SearchOptions(matchCase: true)))
        XCTAssertNotNil(SearchMessages.hint(for: SearchOptions(wrapAround: false)))
        XCTAssertNil(SearchMessages.hint(for: SearchOptions(mode: .regex, wholeWord: true)), "whole word does not apply to regex")
    }
}

final class SearchEngineTests: XCTestCase {
    // MARK: Find Next

    func testFindNextSelectsTheNextMatchWithTheCaretAtItsEnd() {
        let v = makeEditor("one two one two")
        let engine = SearchEngine(editor: v)
        XCTAssertEqual(engine.findNext("two", options: SearchOptions()), .found(.init(start: 4, end: 7), wrapped: false))
        XCTAssertEqual(selection(v), .init(start: 4, end: 7))
        XCTAssertEqual(v.send(SCI_GETCURRENTPOS), 7)
        XCTAssertEqual(engine.findNext("two", options: SearchOptions()), .found(.init(start: 12, end: 15), wrapped: false))
    }

    func testFindNextWrapsToTheTop() {
        let v = makeEditor("two one")
        v.send(SCI_GOTOPOS, 5)
        XCTAssertEqual(SearchEngine(editor: v).findNext("two", options: SearchOptions()), .found(.init(start: 0, end: 3), wrapped: true))
    }

    func testWithoutWrapTheSelectionStays() {
        let v = makeEditor("two one")
        v.send(SCI_SETSEL, 4, 7)
        XCTAssertEqual(SearchEngine(editor: v).findNext("two", options: SearchOptions(wrapAround: false)), .notFound)
        XCTAssertEqual(selection(v), .init(start: 4, end: 7))
    }

    func testBackwardFindsThePreviousMatchAndWrapsToTheBottom() {
        let v = makeEditor("ab ab ab")
        v.send(SCI_SETSEL, 3, 5)  // the middle "ab", as the last search left it
        let up = SearchOptions(backward: true)
        let engine = SearchEngine(editor: v)
        XCTAssertEqual(engine.findNext("ab", options: up), .found(.init(start: 0, end: 2), wrapped: false))
        XCTAssertEqual(v.send(SCI_GETCURRENTPOS), 2, "the caret goes to the end even searching up")
        XCTAssertEqual(engine.findNext("ab", options: up), .found(.init(start: 6, end: 8), wrapped: true))
    }

    func testMatchCaseAndWholeWord() {
        let v = makeEditor("Cat category cat")
        let engine = SearchEngine(editor: v)
        XCTAssertEqual(engine.findNext("cat", options: SearchOptions(matchCase: true, wholeWord: true)),
                       .found(.init(start: 13, end: 16), wrapped: false))
        v.send(SCI_GOTOPOS, 0)
        XCTAssertEqual(engine.findNext("cat", options: SearchOptions()), .found(.init(start: 0, end: 3), wrapped: false))
    }

    func testExtendedModeFindsALineBreak() {
        let v = makeEditor("a\r\nb")
        XCTAssertEqual(SearchEngine(editor: v).findNext("a\\r\\nb", options: SearchOptions(mode: .extended)),
                       .found(.init(start: 0, end: 4), wrapped: false))
    }

    func testRegexAndInvalidRegex() {
        let v = makeEditor("id=42;")
        let engine = SearchEngine(editor: v)
        XCTAssertEqual(engine.findNext("\\d+", options: SearchOptions(mode: .regex)), .found(.init(start: 3, end: 5), wrapped: false))
        XCTAssertEqual(engine.findNext("(", options: SearchOptions(mode: .regex)), .invalidRegex)
    }

    func testNonASCIIPositionsAreBytes() {
        let v = makeEditor("שלום world")
        XCTAssertEqual(SearchEngine(editor: v).findNext("world", options: SearchOptions()), .found(.init(start: 9, end: 14), wrapped: false))
    }

    func testEmptyFindTextFindsNothing() {
        XCTAssertEqual(SearchEngine(editor: makeEditor("abc")).findNext("", options: SearchOptions()), .notFound)
    }

    // MARK: Replace

    func testReplaceWhenTheSelectionIsNotAMatchOnlyFinds() {
        let v = makeEditor("foo bar foo")
        XCTAssertEqual(SearchEngine(editor: v).replace("foo", with: "X", options: SearchOptions()), .foundOnly(.init(start: 0, end: 3)))
        XCTAssertEqual(text(v), "foo bar foo")
        XCTAssertEqual(selection(v), .init(start: 0, end: 3))
    }

    func testReplaceReplacesTheSelectedMatchThenFindsTheNext() {
        let v = makeEditor("foo bar foo")
        v.send(SCI_SETSEL, 0, 3)
        let engine = SearchEngine(editor: v)
        XCTAssertEqual(engine.replace("foo", with: "X", options: SearchOptions()),
                       .replaced(next: .found(.init(start: 6, end: 9), wrapped: false)))
        XCTAssertEqual(text(v), "X bar foo")
        XCTAssertEqual(engine.replace("foo", with: "X", options: SearchOptions(wrapAround: false)), .replaced(next: .notFound))
        XCTAssertEqual(text(v), "X bar X")
    }

    func testReplaceWithRegexGroups() {
        let v = makeEditor("2026-10-14")
        v.send(SCI_SETSEL, 0, 10)
        _ = SearchEngine(editor: v).replace("(\\d+)-(\\d+)-(\\d+)", with: "$3/$2/$1", options: SearchOptions(mode: .regex))
        XCTAssertEqual(text(v), "14/10/2026")
    }

    func testReplaceInAReadOnlyDocumentIsRefused() {
        let v = makeEditor("foo")
        v.send(SCI_SETSEL, 0, 3)
        v.send(SCI_SETREADONLY, 1)
        XCTAssertEqual(SearchEngine(editor: v).replace("foo", with: "x", options: SearchOptions()), .readOnly)
        XCTAssertEqual(SearchEngine(editor: v).replaceAll("foo", with: "x", options: SearchOptions()), .readOnly)
        XCTAssertEqual(text(v), "foo")
    }

    // MARK: Replace All, Count

    func testReplaceAllIsOneUndoStep() {
        let v = makeEditor("a-b-c")
        XCTAssertEqual(SearchEngine(editor: v).replaceAll("-", with: "+", options: SearchOptions()), .done(2, scope: .entireFile))
        XCTAssertEqual(text(v), "a+b+c")
        v.send(SCI_UNDO)
        XCTAssertEqual(text(v), "a-b-c")
    }

    func testReplaceAllWithoutWrapGoesFromTheCaret() {
        let v = makeEditor("x x x")
        v.send(SCI_GOTOPOS, 1)
        XCTAssertEqual(SearchEngine(editor: v).replaceAll("x", with: "y", options: SearchOptions(wrapAround: false)), .done(2, scope: .caretToEnd))
        XCTAssertEqual(text(v), "x y y")
    }

    func testReplaceAllInSelectionKeepsTheEditedRangeSelected() {
        let v = makeEditor("aa aa aa")
        v.send(SCI_SETSEL, 3, 8)
        XCTAssertEqual(SearchEngine(editor: v).replaceAll("a", with: "bbb", options: SearchOptions(inSelection: true)),
                       .done(4, scope: .selection))
        XCTAssertEqual(text(v), "aa bbbbbb bbbbbb")
        XCTAssertEqual(selection(v), .init(start: 3, end: 16))
    }

    func testReplaceAllWithEmptyRegexMatches() {
        let v = makeEditor("ab\ncd")
        _ = SearchEngine(editor: v).replaceAll("^", with: "> ", options: SearchOptions(mode: .regex))
        XCTAssertEqual(text(v), "> ab\n> cd")
        let w = makeEditor("ab\ncd")
        _ = SearchEngine(editor: w).replaceAll("$", with: ";", options: SearchOptions(mode: .regex))
        XCTAssertEqual(text(w), "ab;\ncd;", "the end-of-range match ends the loop")
    }

    func testReplaceAllWithExtendedEscapesInTheReplacement() {
        let v = makeEditor("a,b")
        _ = SearchEngine(editor: v).replaceAll(",", with: "\\n", options: SearchOptions(mode: .extended))
        XCTAssertEqual(text(v), "a\nb")
    }

    func testReplaceAllWithEmptyReplacementDeletes() {
        let v = makeEditor("a1b22c")
        XCTAssertEqual(SearchEngine(editor: v).replaceAll("\\d", with: "", options: SearchOptions(mode: .regex)), .done(3, scope: .entireFile))
        XCTAssertEqual(text(v), "abc")
    }

    func testCountSkipsEmptyMatchesAndLeavesTheDocument() {
        let v = makeEditor("ab\ncd\n")
        let engine = SearchEngine(editor: v)
        XCTAssertEqual(engine.count("^", options: SearchOptions(mode: .regex)), .done(0, scope: .entireFile))
        XCTAssertEqual(engine.count("[a-z]", options: SearchOptions(mode: .regex)), .done(4, scope: .entireFile))
        XCTAssertEqual(engine.count("(", options: SearchOptions(mode: .regex)), .invalidRegex)
        XCTAssertEqual(text(v), "ab\ncd\n")
    }

    func testInSelectionNeedsANonEmptySelection() {
        let v = makeEditor("aaa")
        let engine = SearchEngine(editor: v)
        XCTAssertFalse(engine.hasUsableSelection)
        XCTAssertEqual(engine.count("a", options: SearchOptions(inSelection: true)), .done(3, scope: .entireFile))
        v.send(SCI_SETSEL, 0, 2)
        XCTAssertTrue(engine.hasUsableSelection)
        XCTAssertEqual(engine.count("a", options: SearchOptions(inSelection: true)), .done(2, scope: .selection))
    }
}

final class FindReplaceControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "app.inkpad.Inkpad.tests.find"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func controller(for editor: ScintillaView) -> FindReplaceController {
        FindReplaceController(defaults: defaults) { editor }
    }

    func testFindNextFromTheDialog() {
        let v = makeEditor("alpha beta alpha")
        let c = controller(for: v)
        c.findField.stringValue = "alpha"
        c.findNext()
        XCTAssertEqual(selection(v), .init(start: 0, end: 5))
        XCTAssertNil(c.status)
        c.findNext()
        c.findNext()
        XCTAssertEqual(c.status, SearchMessages.endReached)
        XCTAssertEqual(c.statusLabel.stringValue, SearchMessages.endReached.text)
        XCTAssertEqual(c.findHistory.items, ["alpha"])
    }

    func testNotFoundIsReportedInRed() {
        let c = controller(for: makeEditor("abc"))
        c.findField.stringValue = "zzz"
        c.findNext()
        XCTAssertEqual(c.status, SearchMessages.cantFind("zzz", scope: .entireFile))
        XCTAssertEqual(c.statusLabel.textColor, NSColor.systemRed)
    }

    func testFindPreviousIsRefusedInRegexMode() {
        let v = makeEditor("abc abc")
        let c = controller(for: v)
        c.regexRadio.performClick(nil)
        XCTAssertEqual(c.options.mode, .regex)
        XCTAssertFalse(c.backwardBox.isEnabled)
        XCTAssertFalse(c.wholeWordBox.isEnabled)
        XCTAssertTrue(c.dotNewlineBox.isEnabled)
        c.findField.stringValue = "abc"
        c.findNext(reversed: true)
        XCTAssertEqual(c.status, SearchMessages.regexBackward)
    }

    func testReplaceAndReplaceAllFromTheDialog() {
        let v = makeEditor("cat cat cat")
        let c = controller(for: v)
        c.show(.replace)
        XCTAssertFalse(c.replaceField.isHidden)
        XCTAssertTrue(c.countButton.isHidden)
        XCTAssertEqual(c.findField.stringValue, "cat", "seeded from the word at the caret, now selected")
        c.replaceField.stringValue = "dog"
        c.replace()
        XCTAssertEqual(text(v), "dog cat cat", "the selected match is replaced")
        XCTAssertEqual(c.status, SearchMessages.replacedNextFound)
        XCTAssertEqual(selection(v), .init(start: 4, end: 7))
        v.send(SCI_GOTOPOS, 0)
        c.replace()
        XCTAssertEqual(text(v), "dog cat cat", "the selection was not a match: only found")
        XCTAssertNil(c.status)
        c.replaceAll()
        XCTAssertEqual(text(v), "dog dog dog")
        XCTAssertEqual(c.status, SearchMessages.replacedAll(2, scope: .entireFile))
        XCTAssertEqual(c.replaceHistory.items, ["dog"])
        c.close()
    }

    func testCountFromTheDialog() {
        let c = controller(for: makeEditor("a a a"))
        c.findField.stringValue = "a"
        c.count()
        XCTAssertEqual(c.status, SearchMessages.count(3, scope: .entireFile))
    }

    func testOptionsAndHistorySurviveARestart() {
        let v = makeEditor("x")
        let first = controller(for: v)
        first.matchCaseBox.performClick(nil)
        first.extendedRadio.performClick(nil)
        first.findField.stringValue = "x"
        first.findNext()
        let second = controller(for: v)
        XCTAssertTrue(second.options.matchCase)
        XCTAssertEqual(second.options.mode, .extended)
        XCTAssertEqual(second.matchCaseBox.state, .on)
        XCTAssertEqual(second.findHistory.items, ["x"])
        XCTAssertEqual(second.findField.objectValues as? [String], ["x"])
    }

    func testOpeningSeedsFindWhatFromTheSelectionOrTheWordAtTheCaret() {
        let v = makeEditor("hello brave world")
        v.send(SCI_GOTOPOS, 8)
        let c = controller(for: v)
        c.show(.find)
        XCTAssertEqual(c.findField.stringValue, "brave")
        XCTAssertEqual(selection(v), .init(start: 6, end: 11), "upstream selects the word it used")
        v.send(SCI_SETSEL, 0, 11)
        c.show(.find)
        XCTAssertEqual(c.findField.stringValue, "hello brave")
        XCTAssertEqual(c.inSelectionBox.state, .off, "short selections do not tick In selection")
        XCTAssertTrue(c.inSelectionBox.isEnabled)
        c.close()
    }

    func testALongSelectionTicksInSelection() {
        let v = makeEditor(String(repeating: "word ", count: 300))
        v.send(SCI_SETSEL, 0, 1200)
        let c = controller(for: v)
        c.show(.find)
        XCTAssertEqual(c.options.inSelection, true)
        XCTAssertEqual(c.findField.stringValue, "", "over 1024 characters is not used as Find what")
        c.close()
    }

    func testSelectAndFindNextUsesNormalModeWithoutChangingTheDialogsMode() {
        let v = makeEditor("a.c abc a.c")
        let c = controller(for: v)
        c.regexRadio.performClick(nil)
        v.send(SCI_SETSEL, 0, 3)
        c.selectAndFindNext(reversed: false)
        XCTAssertEqual(selection(v), .init(start: 8, end: 11), "\".\" is literal: abc is skipped")
        XCTAssertEqual(c.findField.stringValue, "a.c")
        XCTAssertEqual(c.options.mode, .regex)
    }

    func testUseSelectionForFind() {
        let v = makeEditor("foo bar")
        v.send(SCI_SETSEL, 4, 7)
        let c = controller(for: v)
        c.useSelectionForFind()
        XCTAssertEqual(c.findField.stringValue, "bar")
    }

    func testAnInvalidRegexExplainsItself() {
        let c = FindReplaceController(defaults: UserDefaults(suiteName: "app.inkpad.Inkpad.tests.regexerror")!) { makeEditor("abc") }
        c.regexRadio.performClick(nil)
        c.findField.stringValue = "a(b"
        c.findNext()
        XCTAssertEqual(c.status, SearchMessages.invalidRegex)
        XCTAssertNotNil(c.statusLabel.toolTip, "Boost's reason, as upstream's tooltip")
        XCTAssertTrue(c.statusLabel.toolTip?.lowercased().contains("parenthes") == true, c.statusLabel.toolTip ?? "")
    }
}

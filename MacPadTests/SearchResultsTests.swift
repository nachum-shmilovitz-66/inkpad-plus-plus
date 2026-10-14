import XCTest
@testable import MacPad

// MAC-32: Notepad++'s Search results — the text format, Find All, the pane and navigation.

private func makeEditor(_ text: String) -> ScintillaView {
    let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    v.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
    v.setUTF8Bytes(Data(text.utf8))
    v.send(SCI_GOTOPOS, 0)
    return v
}

private func paneText(_ panel: SearchResultsPanel) -> String { String(decoding: panel.pane.utf8Bytes(), as: UTF8.self) }

private func isolatedDefaults(_ name: String) -> UserDefaults {
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

final class SearchResultsFormatTests: XCTestCase {
    func testSearchHeader() {
        XCTAssertEqual(SearchResultsFormat.searchHeader(term: "foo", hits: 3, files: 2, searched: 5, inSelection: false, options: SearchOptions()),
                       "Search \"foo\" (3 hits in 2 files of 5 searched) [Normal]")
        XCTAssertEqual(SearchResultsFormat.searchHeader(term: "a\r\nb", hits: 1, files: 1, searched: 1, inSelection: false, options: SearchOptions()),
                       "Search \"ab\" (1 hit in 1 file of 1 searched) [Normal]")
        XCTAssertEqual(SearchResultsFormat.searchHeader(term: "x", hits: 0, files: 0, searched: 1, inSelection: true, options: SearchOptions()),
                       "Search \"x\" (0 hits in 0 selections of 1 searched) [Normal]")
        XCTAssertEqual(SearchResultsFormat.searchHeader(term: "x", hits: 12345, files: 1, searched: 1, inSelection: true, options: SearchOptions()),
                       "Search \"x\" (12,345 hits in 1 selection of 1 searched) [Normal]")
    }

    func testModeLabels() {
        XCTAssertEqual(SearchResultsFormat.modeLabel(SearchOptions(mode: .extended, matchCase: true)), "[Extended: Case]")
        XCTAssertEqual(SearchResultsFormat.modeLabel(SearchOptions(matchCase: true, wholeWord: true)), "[Normal: Case/Word]")
        XCTAssertEqual(SearchResultsFormat.modeLabel(SearchOptions(mode: .regex, wholeWord: true, dotMatchesNewline: true)), "[RegEx.]")
        XCTAssertEqual(SearchResultsFormat.modeLabel(SearchOptions(mode: .regex, matchCase: true)), "[RegEx: Case]")
    }

    func testFileHeaderAndHitPrefix() {
        XCTAssertEqual(SearchResultsFormat.fileHeader(path: "/tmp/a.txt", hits: 1), "  /tmp/a.txt (1 hit)")
        XCTAssertEqual(SearchResultsFormat.fileHeader(path: "new 1", hits: 2), "  new 1 (2 hits)")
        XCTAssertEqual(SearchResultsFormat.hitPrefix(line: 11, lineCount: 1234), "\tLine   12: ")
        XCTAssertEqual(SearchResultsFormat.hitPrefix(line: 1233, lineCount: 1234), "\tLine 1234: ")
        XCTAssertEqual(SearchResultsFormat.hitPrefix(line: 0, lineCount: 9), "\tLine 1: ")
    }

    func testLongLinesAreCutOnACharacterBoundary() {
        let prefix = "\tLine 1: "
        let short = SearchResultsFormat.hitText(prefix: prefix, lineText: Data("  keep  leading space".utf8))
        XCTAssertEqual(short, "\tLine 1:   keep  leading space")
        let long = SearchResultsFormat.hitText(prefix: prefix, lineText: Data(String(repeating: "ש", count: 1500).utf8))
        XCTAssertTrue(long.hasSuffix(" ..."))
        XCTAssertLessThanOrEqual(long.utf8.count, SearchResultsFormat.cutBytes + 4)
        XCTAssertFalse(long.contains("\u{FFFD}"), "never cut inside a UTF-8 sequence")
    }
}

final class FindAllTests: XCTestCase {
    func testHitsOnOneLineShareAnEntryWithASegmentEach() {
        let v = makeEditor("cat cat\ndog\n  cat")
        guard case .found(let hits) = SearchEngine(editor: v).findAll("cat", options: SearchOptions(), path: "/x") else { return XCTFail() }
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].text, "\tLine 1: cat cat")
        XCTAssertEqual(hits[0].ranges, [0..<3, 4..<7])
        XCTAssertEqual(hits[0].segments, [9..<12, 13..<16], "byte offsets in the pane line, prefix included")
        XCTAssertEqual(hits[1].line, 2)
        XCTAssertEqual(hits[1].text, "\tLine 3:   cat")
        XCTAssertEqual(hits[1].segments, [11..<14])
    }

    func testFindAllCoversTheWholeDocumentWhateverTheDirectionAndWrap() {
        let v = makeEditor("a a a")
        v.send(SCI_GOTOPOS, 4)
        guard case .found(let hits) = SearchEngine(editor: v).findAll("a", options: SearchOptions(wrapAround: false, backward: true), path: "/x")
        else { return XCTFail() }
        XCTAssertEqual(hits.first?.ranges.count, 3)
    }

    func testInSelectionLimitsFindAll() {
        let v = makeEditor("a a a")
        v.send(SCI_SETSEL, 2, 5)
        guard case .found(let hits) = SearchEngine(editor: v).findAll("a", options: SearchOptions(inSelection: true), path: "/x")
        else { return XCTFail() }
        XCTAssertEqual(hits.first?.ranges, [2..<3, 4..<5])
    }

    func testEmptyRegexMatchesAreListed() {
        let v = makeEditor("ab\ncd")
        guard case .found(let hits) = SearchEngine(editor: v).findAll("^", options: SearchOptions(mode: .regex), path: "/x")
        else { return XCTFail() }
        XCTAssertEqual(hits.map(\.line), [0, 1])
        XCTAssertEqual(hits[1].ranges, [3..<3])
    }

    func testInvalidRegex() {
        XCTAssertEqual(SearchEngine(editor: makeEditor("x")).findAll("(", options: SearchOptions(mode: .regex), path: "/x"), .invalidRegex)
    }

    func testHebrewLineSegmentsAreBytes() {
        let v = makeEditor("שלום world")
        guard case .found(let hits) = SearchEngine(editor: v).findAll("world", options: SearchOptions(), path: "/x") else { return XCTFail() }
        let prefix = "\tLine 1: ".utf8.count
        XCTAssertEqual(hits[0].segments, [(prefix + 9)..<(prefix + 14)])
    }
}

final class SearchResultsModelTests: XCTestCase {
    private func block(_ term: String, path: String = "/a.txt") -> SearchResultsBlock {
        let hit = SearchResultHit(path: path, line: 0, ranges: [0..<1], text: "\tLine 1: \(term) here", segments: [9..<10])
        return SearchResultsBlock(header: "Search \"\(term)\"", files: [SearchResultsFile(path: path, header: "  \(path) (1 hit)", hits: [hit])], hitCount: 1)
    }

    func testNewestSearchFirstUnlessPurged() {
        var model = SearchResultsModel()
        model.add(block("one"), purge: false)
        model.add(block("two"), purge: false)
        let (text, lines) = model.render()
        XCTAssertEqual(text, "Search \"two\"\r\n  /a.txt (1 hit)\r\n\tLine 1: two here\r\nSearch \"one\"\r\n  /a.txt (1 hit)\r\n\tLine 1: one here\r\n")
        XCTAssertEqual(lines, [.searchHeader(block: 0), .fileHeader(block: 0, file: 0), .hit(block: 0, file: 0, hit: 0),
                               .searchHeader(block: 1), .fileHeader(block: 1, file: 0), .hit(block: 1, file: 0, hit: 0), .end])
        model.add(block("three"), purge: true)
        XCTAssertEqual(model.blocks.count, 1)
    }

    func testRemovingAHitLineFileOrSearch() {
        var model = SearchResultsModel()
        model.add(block("one"), purge: false)
        model.add(block("two"), purge: false)
        model.remove(.hit(block: 0, file: 0, hit: 0))
        XCTAssertEqual(model.blocks[0].files.count, 0, "a file without hits goes too")
        model.remove(.searchHeader(block: 0))
        XCTAssertEqual(model.blocks.map(\.header), ["Search \"one\""])
    }

    func testCopyLinesAndPaths() {
        var model = SearchResultsModel()
        let hits = [
            SearchResultHit(path: "/a", line: 0, ranges: [0..<1], text: "\tLine 1: same", segments: []),
            SearchResultHit(path: "/a", line: 1, ranges: [5..<6], text: "\tLine 2: same", segments: []),
            SearchResultHit(path: "/a", line: 2, ranges: [9..<10], text: "\tLine 3: other: x", segments: []),
        ]
        model.add(SearchResultsBlock(header: "S", files: [
            SearchResultsFile(path: "/a", header: "  /a", hits: hits),
            SearchResultsFile(path: "/b", header: "  /b", hits: [SearchResultHit(path: "/b", line: 0, ranges: [0..<1], text: "\tLine 1: b", segments: [])]),
        ], hitCount: 4), purge: false)
        XCTAssertEqual(model.copiedLines([.fileHeader(block: 0, file: 0)]), "same\r\nother: x", "consecutive duplicates dropped")
        XCTAssertEqual(model.copiedLines([.hit(block: 0, file: 1, hit: 0)]), "b")
        XCTAssertEqual(model.paths([.searchHeader(block: 0)]), ["/a", "/b"])
        XCTAssertEqual(model.paths([.hit(block: 0, file: 0, hit: 0), .hit(block: 0, file: 0, hit: 1)]), ["/a"])
    }
}

final class SearchResultsPanelTests: XCTestCase {
    private func search(_ panel: SearchResultsPanel, _ text: String, in editor: ScintillaView, path: String = "/doc.txt") {
        guard case .found(let hits) = SearchEngine(editor: editor).findAll(text, options: SearchOptions(), path: path) else { return }
        let count = hits.reduce(0) { $0 + $1.ranges.count }
        let file = SearchResultsFile(path: path, header: SearchResultsFormat.fileHeader(path: path, hits: count), hits: hits)
        panel.show(SearchResultsBlock(header: SearchResultsFormat.searchHeader(term: text, hits: count, files: 1, searched: 1,
                                                                              inSelection: false, options: SearchOptions()),
                                      files: [file], hitCount: count))
    }

    func testShowWritesNotepadPlusPlusTextStylesAndFolds() {
        let panel = SearchResultsPanel(defaults: isolatedDefaults("app.macpad.MacPad.tests.results1"))
        let doc = makeEditor("foo bar\nbar foo foo")
        search(panel, "foo", in: doc)
        XCTAssertEqual(paneText(panel), "Search \"foo\" (3 hits in 1 file of 1 searched) [Normal]\r\n  /doc.txt (3 hits)\r\n"
                       + "\tLine 1: foo bar\r\n\tLine 2: bar foo foo\r\n")
        XCTAssertEqual(panel.title, "Search results - (3 hits)")
        let p = panel.pane
        XCTAssertEqual(p.send(SCI_GETSTYLEAT, 0), SearchResultsPanel.searchHeaderStyle)
        let fileLine = p.send(SCI_POSITIONFROMLINE, 1)
        XCTAssertEqual(p.send(SCI_GETSTYLEAT, fileLine + 2), SearchResultsPanel.fileHeaderStyle)
        let hitLine = p.send(SCI_POSITIONFROMLINE, 2)
        XCTAssertEqual(p.send(SCI_GETSTYLEAT, hitLine + 1), SearchResultsPanel.defaultStyle, "\"Line\"")
        XCTAssertEqual(p.send(SCI_GETSTYLEAT, hitLine + 6), SearchResultsPanel.lineNumberStyle, "the number")
        XCTAssertEqual(p.send(SCI_GETSTYLEAT, hitLine + 9), SearchResultsPanel.hitStyle, "the hit")
        XCTAssertEqual(p.send(SCI_GETSTYLEAT, hitLine + 13), SearchResultsPanel.defaultStyle, "the rest")
        XCTAssertNotEqual(p.send(SCI_GETFOLDLEVEL, 0) & Int(SC_FOLDLEVELHEADERFLAG), 0)
        XCTAssertEqual(p.send(SCI_GETFOLDLEVEL, 2) & Int(SC_FOLDLEVELNUMBERMASK), Int(SC_FOLDLEVELBASE) + 2)
        XCTAssertEqual(p.send(SCI_GETREADONLY), 1)

        search(panel, "bar", in: doc)
        XCTAssertTrue(paneText(panel).hasPrefix("Search \"bar\""), "newest on top")
        let olderHeader = panel.lines.firstIndex(of: .searchHeader(block: 1))!
        XCTAssertEqual(p.send(SCI_GETFOLDEXPANDED, olderHeader), 0, "older searches folded")
        XCTAssertEqual(p.send(SCI_GETFOLDEXPANDED, 0), 1)
    }

    func testActivateOpensTheHitUnderTheClick() {
        let panel = SearchResultsPanel(defaults: isolatedDefaults("app.macpad.MacPad.tests.results2"))
        var opened: [(Int, Int)] = []
        panel.onOpen = { hit, index in opened.append((hit.line, index)) }
        search(panel, "foo", in: makeEditor("x\nfoo foo"))
        let lineStart = panel.pane.send(SCI_POSITIONFROMLINE, 2)
        panel.activate(line: 2, position: lineStart + 14)  // inside the second "foo"
        panel.activate(line: 2, position: lineStart)        // on "Line": the first hit
        XCTAssertEqual(opened.map(\.0), [1, 1])
        XCTAssertEqual(opened.map(\.1), [1, 0])
        XCTAssertEqual(panel.pane.send(SCI_GETSELECTIONSTART), lineStart + 9, "the segment is selected in the pane")
    }

    func testF4StepsThroughTheLatestSearchAndWraps() {
        let panel = SearchResultsPanel(defaults: isolatedDefaults("app.macpad.MacPad.tests.results3"))
        var opened: [Int] = []
        panel.onOpen = { hit, index in opened.append(hit.ranges[index].lowerBound) }
        let doc = makeEditor("a a\nb a")
        search(panel, "b", in: doc)
        search(panel, "a", in: doc)
        for _ in 0..<4 { panel.step(forward: true) }
        XCTAssertEqual(opened, [0, 2, 6, 0], "three hits of the newest search, then wrapped; the older search is not entered")
        panel.step(forward: false)
        XCTAssertEqual(opened.last, 6, "backwards wraps to the last")
    }

    func testDeleteAndClear() {
        let panel = SearchResultsPanel(defaults: isolatedDefaults("app.macpad.MacPad.tests.results4"))
        search(panel, "x", in: makeEditor("x\ny\nx"))
        panel.pane.send(SCI_GOTOLINE, 2)
        panel.removeCurrent()
        XCTAssertEqual(paneText(panel), "Search \"x\" (2 hits in 1 file of 1 searched) [Normal]\r\n  /doc.txt (2 hits)\r\n\tLine 3: x\r\n",
                       "counts stay as found, as in Notepad++")
        panel.clearAll()
        XCTAssertEqual(paneText(panel), "")
        XCTAssertEqual(panel.title, "Search results")
    }

    func testPurgeAndWrapSettingsPersist() {
        let defaults = isolatedDefaults("app.macpad.MacPad.tests.results5")
        let panel = SearchResultsPanel(defaults: defaults)
        XCTAssertFalse(panel.purgeForEverySearch)
        XCTAssertFalse(panel.wrapLongLines)
        panel.togglePurge(nil)
        panel.toggleWrap(nil)
        XCTAssertEqual(panel.pane.send(SCI_GETWRAPMODE), Int(SC_WRAP_WORD))
        let again = SearchResultsPanel(defaults: defaults)
        XCTAssertTrue(again.purgeForEverySearch)
        XCTAssertTrue(again.wrapLongLines)
        search(again, "a", in: makeEditor("a"))
        search(again, "a", in: makeEditor("a"))
        XCTAssertEqual(again.model.blocks.count, 1, "purged")
        let titles = again.contextMenu().items.map(\.title)
        XCTAssertEqual(titles.filter { !$0.isEmpty }, ["Fold all", "Unfold all", "Copy", "Copy Selected Line(s)", "Copy Selected Pathname(s)",
                                                       "Select all", "Clear all", "Open Selected Pathname(s)", "Word wrap long lines",
                                                       "Purge for every search"])
    }

    func testCopySelectedLinesUsesThePrivateClipboard() {
        let panel = SearchResultsPanel(defaults: isolatedDefaults("app.macpad.MacPad.tests.results6"))
        search(panel, "x", in: makeEditor("1 x\n2 x"))
        panel.pane.send(SCI_GOTOLINE, 1)  // the file header: all its hits
        panel.copySelectedLines(nil)
        XCTAssertEqual(AppEnvironment.pasteboard.string(forType: .string), "1 x\r\n2 x")
        panel.copySelectedPathnames(nil)
        XCTAssertEqual(AppEnvironment.pasteboard.string(forType: .string), "/doc.txt")
    }
}

final class FindAllDialogTests: XCTestCase {
    func testFindAllInCurrentAndOpenedDocuments() {
        let a = makeEditor("red green red"), b = makeEditor("blue"), c = makeEditor("red")
        let docs = [SearchDocument(editor: a, path: "/a.txt"), SearchDocument(editor: b, path: "new 1"), SearchDocument(editor: c, path: "/c.txt")]
        let controller = FindReplaceController(defaults: isolatedDefaults("app.macpad.MacPad.tests.findall")) { a }
        controller.documentsProvider = { (docs[0], docs) }
        var blocks: [SearchResultsBlock] = []
        controller.resultsSink = { blocks.append($0) }
        controller.findField.stringValue = "red"
        controller.findAll(inOpenedDocuments: false)
        XCTAssertEqual(blocks.last?.header, "Search \"red\" (2 hits in 1 file of 1 searched) [Normal]")
        controller.findAll(inOpenedDocuments: true)
        XCTAssertEqual(blocks.last?.header, "Search \"red\" (3 hits in 2 files of 3 searched) [Normal]")
        XCTAssertEqual(blocks.last?.files.map(\.header), ["  /a.txt (2 hits)", "  /c.txt (1 hit)"])
        controller.findField.stringValue = "zzz"
        controller.findAll(inOpenedDocuments: true)
        XCTAssertEqual(blocks.last?.header, "Search \"zzz\" (0 hits in 0 files of 3 searched) [Normal]", "an empty search is still listed")
    }

    func testReplaceAllInOpenedDocumentsAsksAndSkipsReadOnly() {
        let a = makeEditor("x x"), b = makeEditor("x"), locked = makeEditor("x")
        locked.send(SCI_SETREADONLY, 1)
        let docs = [a, b, locked].enumerated().map { SearchDocument(editor: $0.element, path: "/\($0.offset)") }
        let controller = FindReplaceController(defaults: isolatedDefaults("app.macpad.MacPad.tests.replaceopened")) { a }
        controller.documentsProvider = { (docs[0], docs) }
        var answer = false
        controller.confirmReplaceInOpenedFiles = { answer }
        controller.findField.stringValue = "x"
        controller.replaceField.stringValue = "y"
        controller.replaceAllInOpenedDocuments()
        XCTAssertEqual(String(decoding: a.utf8Bytes(), as: UTF8.self), "x x", "declined: nothing changes")
        answer = true
        controller.replaceAllInOpenedDocuments()
        XCTAssertEqual(String(decoding: a.utf8Bytes(), as: UTF8.self), "y y")
        XCTAssertEqual(String(decoding: b.utf8Bytes(), as: UTF8.self), "y")
        XCTAssertEqual(String(decoding: locked.utf8Bytes(), as: UTF8.self), "x")
        XCTAssertEqual(controller.status?.text, "Replace in Opened Files: 3 occurrences were replaced.")
    }
}

final class SearchResultsWindowTests: XCTestCase {
    func testOpeningAHitSelectsItInItsTab() {
        let window = MainWindowController()
        let first = window.newTab()
        first.editor.setUTF8Bytes(Data("alpha beta".utf8))
        let second = window.newTab()
        second.editor.setUTF8Bytes(Data("gamma".utf8))
        XCTAssertTrue(window.activeTab === second)
        let hit = SearchResultHit(path: first.displayName, line: 0, ranges: [6..<10], text: "\tLine 1: alpha beta", segments: [15..<19])
        window.openSearchHit(hit, rangeIndex: 0)
        XCTAssertTrue(window.activeTab === first)
        XCTAssertEqual(first.editor.send(SCI_GETSELECTIONSTART), 6)
        XCTAssertEqual(first.editor.send(SCI_GETCURRENTPOS), 10)
        XCTAssertEqual(window.searchDocuments.map(\.path), [first.displayName, second.displayName])
        window.openTabs.forEach { $0.detach() }
    }

    func testTheResultsPanelShowsAndHides() {
        let window = MainWindowController()
        window.newTab()
        XCTAssertFalse(window.isSearchResultsVisible)
        window.showSearchResults(SearchResultsBlock(header: "Search \"q\" (0 hits in 0 files of 1 searched) [Normal]", files: [], hitCount: 0))
        XCTAssertTrue(window.isSearchResultsVisible)
        window.setSearchResultsVisible(false)
        XCTAssertFalse(window.isSearchResultsVisible)
        window.openTabs.forEach { $0.detach() }
    }
}

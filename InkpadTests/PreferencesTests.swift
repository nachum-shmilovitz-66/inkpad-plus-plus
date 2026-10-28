import XCTest
@testable import Inkpad

/// MAC-38 (and MAC-12): Preferences — the model, how editors apply it, and the window.
final class PreferencesTests: XCTestCase {
    override func tearDown() {
        Preferences.update { $0 = Preferences() }
        super.tearDown()
    }

    private func editor(_ language: String = "normal", _ text: String = "") -> ScintillaView {
        let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        EditorStyler.configureEditor(v)
        v.setUTF8Bytes(Data(text.utf8))
        EditorStyler.apply(language: LanguageCatalog.shared.language(named: language)!, theme: StyleTheme.default, to: v)
        return v
    }

    // MARK: Model

    func testUpstreamDefaultsWithAMacLineEnding() {
        let p = Preferences()
        XCTAssertEqual(p.newDocLineEnding, .lf, "MAC-12: Unix on a Mac")
        XCTAssertEqual(p.newDocEncoding, .utf8)
        XCTAssertEqual(p.currentLineIndicator, .highlight)
        XCTAssertEqual(p.caretWidth, 1)
        XCTAssertEqual(p.caretBlinkRate, 600)
        XCTAssertEqual(p.lineWrap, .aligned)
        XCTAssertTrue(p.scrollBeyondLastLine)
        XCTAssertEqual(p.foldMarkStyle, .arrow, "triangles, as on the Mac (MAC-80)")
        XCTAssertEqual(p.defaultTabs, Preferences.TabSetting(size: 4, useSpaces: false, backspaceUnindent: false))
        XCTAssertEqual(p.inSelectionThreshold, 1024)
        XCTAssertTrue(p.confirmReplaceInAllOpened)
        XCTAssertEqual(p.maxRecentFiles, 10)
        XCTAssertTrue(p.scaleWindowsFontSizes)
    }

    func testAnOlderSaveKeepsItsValuesAndDefaultsTheRest() throws {
        let p = try JSONDecoder().decode(Preferences.self, from: Data(#"{"caretWidth":4,"maxRecentFiles":20}"#.utf8))
        XCTAssertEqual(p.caretWidth, 4)
        XCTAssertEqual(p.maxRecentFiles, 20)
        XCTAssertEqual(p.foldMarkStyle, .arrow)
    }

    func testTabSettingsByLanguage() {
        var p = Preferences()
        XCTAssertEqual(p.tabs(for: "python"), Preferences.TabSetting(size: 4, useSpaces: true, backspaceUnindent: false),
                       "langs.model.xml tabSettings=132")
        XCTAssertEqual(p.tabs(for: "sql"), p.defaultTabs)
        p.languageTabs["sql"] = Preferences.TabSetting(size: 2, useSpaces: true, backspaceUnindent: true)
        XCTAssertEqual(p.tabs(for: "sql").size, 2)
        p.defaultTabs.size = 8
        XCTAssertEqual(p.tabs(for: "c").size, 8)
    }

    func testEdgeColumnParsing() {
        XCTAssertEqual(PreferencesController.parseColumns("80 120  9999 x 0"), [80, 120])
    }

    // MARK: Applying

    func testNewDocumentsUseTheNewDocumentSettings() {
        Preferences.update {
            $0.newDocLineEnding = .crlf
            $0.newDocEncoding = .utf16LE
            $0.newDocLanguage = "python"
        }
        let tab = EditorTab(untitledNumber: 1)
        XCTAssertEqual(tab.lineEnding, .crlf)
        XCTAssertEqual(tab.encoding, .utf16LE)
        XCTAssertEqual(tab.language.name, "python")
        tab.detach()
    }

    func testEditingAndMarginSettingsReachTheEditor() {
        Preferences.update {
            $0.caretWidth = 4
            $0.caretBlinkRate = 0
            $0.currentLineIndicator = .frame
            $0.currentLineFrameWidth = 3
            $0.scrollBeyondLastLine = false
            $0.lineWrap = .indent
            $0.showLineNumbers = false
            $0.showBookmarkMargin = false
            $0.edgeColumns = [80, 120]
            $0.paddingLeft = 7
        }
        let v = editor("cpp")
        XCTAssertEqual(v.send(SCI_GETCARETSTYLE) & Int(CARETSTYLE_BLOCK), Int(CARETSTYLE_BLOCK))
        XCTAssertEqual(v.send(SCI_GETCARETPERIOD), 0)
        XCTAssertEqual(v.send(SCI_GETCARETLINEFRAME), 3)
        XCTAssertEqual(v.send(SCI_GETENDATLASTLINE), 1)
        XCTAssertEqual(v.send(SCI_GETWRAPINDENTMODE), Int(SC_WRAPINDENT_INDENT))
        XCTAssertEqual(v.send(SCI_GETMARGINWIDTHN, Margin.lineNumber), 0)
        XCTAssertEqual(v.send(SCI_GETMARGINWIDTHN, Margin.symbol), 0)
        XCTAssertEqual(v.send(SCI_GETEDGEMODE), Int(EDGE_MULTILINE))
        XCTAssertEqual(v.send(SCI_GETMARGINLEFT), 7)
    }

    func testFoldStylesAndNone() {
        Preferences.update { $0.foldMarkStyle = .arrow }
        let v = editor("cpp")
        for num in [SC_MARKNUM_FOLDER, SC_MARKNUM_FOLDEROPEN, SC_MARKNUM_FOLDEREND, SC_MARKNUM_FOLDEROPENMID,
                    SC_MARKNUM_FOLDERTAIL, SC_MARKNUM_FOLDERMIDTAIL] {
            XCTAssertEqual(v.send(SCI_MARKERSYMBOLDEFINED, Int(num)), Int(SC_MARK_RGBAIMAGE), "small drawn marks (MAC-82)")
        }
        XCTAssertEqual(v.send(SCI_MARKERSYMBOLDEFINED, Int(SC_MARKNUM_FOLDERSUB)), Int(SC_MARK_EMPTY))
        Preferences.update { $0.foldMarkStyle = .box }
        XCTAssertEqual(editor("cpp").send(SCI_MARKERSYMBOLDEFINED, Int(SC_MARKNUM_FOLDERTAIL)), Int(SC_MARK_LCORNER),
                       "another style replaces the images")
        Preferences.update { $0.foldMarkStyle = .none }
        XCTAssertEqual(editor("cpp").send(SCI_GETMARGINWIDTHN, Margin.fold), 0)
    }

    // MAC-82: BBEdit-sized fold marks. Pixel rows run top to bottom.
    private func filled(_ pixels: [UInt8], size: Int, rows: Range<Int>, columns: Range<Int>) -> Int {
        var n = 0
        for y in rows { for x in columns where pixels[(y * size + x) * 4 + 3] > 128 { n += 1 } }
        return n
    }

    func testOpenFoldMarkIsASmallTrianglePointingDown() {
        let size = EditorStyler.foldMarkPoints * 2
        let pixels = EditorStyler.foldMarkImage(.open, points: EditorStyler.foldMarkPoints, scale: 2, colour: 0x8E8E8E)
        XCTAssertEqual(pixels.count, size * size * 4)
        let top = filled(pixels, size: size, rows: 0..<size / 2, columns: 0..<size)
        let bottom = filled(pixels, size: size, rows: size / 2..<size, columns: 0..<size)
        XCTAssertGreaterThan(top, bottom * 2, "wide at the top, a point at the bottom")
        let total = top + bottom
        XCTAssertLessThan(total, size * size / 6, "small: about 8 x 4.5 points in a 12-point box")
        XCTAssertGreaterThan(total, 0)
        XCTAssertEqual(filled(pixels, size: size, rows: 0..<4, columns: 0..<size), 0, "room above")
    }

    func testFoldedMarkIsATrianglePointingRight() {
        let size = EditorStyler.foldMarkPoints * 2
        let pixels = EditorStyler.foldMarkImage(.closed, points: EditorStyler.foldMarkPoints, scale: 2, colour: 0x8E8E8E)
        let left = filled(pixels, size: size, rows: 0..<size, columns: 0..<size / 2)
        let right = filled(pixels, size: size, rows: 0..<size, columns: size / 2..<size)
        XCTAssertGreaterThan(left, right * 2)
    }

    func testEndMarkIsACornerAtTheBottomLeft() {
        let size = EditorStyler.foldMarkPoints * 2
        let pixels = EditorStyler.foldMarkImage(.end, points: EditorStyler.foldMarkPoints, scale: 2, colour: 0x8E8E8E)
        let m = size / 2
        // The foot: a bar along the bottom; the stem: up the left side only.
        XCTAssertGreaterThan(filled(pixels, size: size, rows: m + 2..<m + 4, columns: m..<m + 5), 0, "foot to the right")
        XCTAssertGreaterThan(filled(pixels, size: size, rows: m - 4..<m - 1, columns: m - 6..<m - 2), 0, "stem on the left")
        XCTAssertEqual(filled(pixels, size: size, rows: m - 4..<m - 1, columns: m..<size), 0, "nothing above the foot")
    }

    func testFoldMarksUseTheThemeColour() {
        let size = EditorStyler.foldMarkPoints * 2
        // Scintilla colours are BGR: 0x0000FF is red.
        let pixels = EditorStyler.foldMarkImage(.open, points: EditorStyler.foldMarkPoints, scale: 2, colour: 0x0000FF)
        let centre = ((size / 2 - 2) * size + size / 2) * 4
        XCTAssertEqual(pixels[centre + 3], 255)
        XCTAssertGreaterThan(pixels[centre], 240)
        XCTAssertLessThan(pixels[centre + 2], 15)
    }

    func testOneEdgeColumnInBackgroundMode() {
        Preferences.update {
            $0.edgeColumns = [100]
            $0.edgeBackgroundMode = true
        }
        let v = editor()
        XCTAssertEqual(v.send(SCI_GETEDGEMODE), Int(EDGE_BACKGROUND))
        XCTAssertEqual(v.send(SCI_GETEDGECOLUMN), 100)
    }

    func testIndentationAndSQLSettings() {
        Preferences.update {
            $0.languageTabs["sql"] = Preferences.TabSetting(size: 2, useSpaces: true, backspaceUnindent: true)
            $0.sqlBackslashEscapes = false
        }
        let v = editor("sql")
        XCTAssertEqual(v.send(SCI_GETTABWIDTH), 2)
        XCTAssertEqual(v.send(SCI_GETUSETABS), 0)
        XCTAssertEqual(v.send(SCI_GETBACKSPACEUNINDENTS), 1)
        let value = "sql.backslash.escapes".withCString { k -> String in
            var buffer = [CChar](repeating: 0, count: 8)
            buffer.withUnsafeMutableBytes { _ = v.send(SCI_GETPROPERTY, Int(bitPattern: k), Int(bitPattern: $0.baseAddress)) }
            return String(cString: buffer)
        }
        XCTAssertEqual(value, "0")
    }

    func testFontScalingCanBeTurnedOff() throws {
        let size = try XCTUnwrap(StyleTheme.default.global("Default Style")?.fontSize)
        XCTAssertEqual(editor().send(SCI_STYLEGETSIZE, Int(STYLE_DEFAULT)), Int((Double(size) * 4 / 3).rounded()))
        Preferences.update { $0.scaleWindowsFontSizes = false }
        XCTAssertEqual(editor().send(SCI_STYLEGETSIZE, Int(STYLE_DEFAULT)), size, "MAC-12: upstream sizes as they are")
    }

    func testChangesApplyLiveToOpenTabs() {
        let window = MainWindowController()
        let tab = window.newTab()
        XCTAssertEqual(tab.editor.send(SCI_GETCARETSTYLE), Int(CARETSTYLE_LINE))
        Preferences.update { $0.caretWidth = 4 }
        XCTAssertEqual(tab.editor.send(SCI_GETCARETSTYLE) & Int(CARETSTYLE_BLOCK), Int(CARETSTYLE_BLOCK))
        window.openTabs.forEach { $0.detach() }
    }

    func testRecentFilesFollowTheLimit() {
        Preferences.update { $0.maxRecentFiles = 3 }
        var recent = RecentFiles()
        (1...5).forEach { recent.record("/f\($0)") }
        XCTAssertEqual(recent.paths, ["/f5", "/f4", "/f3"])
    }

    // MARK: Searching

    func testFindFieldFilling() {
        let v = makeEditor("hello world")
        v.send(SCI_GOTOPOS, 2)
        Preferences.update { $0.selectWordUnderCaret = false }
        let c = FindReplaceController(defaults: isolated("fill")) { v }
        c.findField.stringValue = ""
        c.show(.find)
        XCTAssertEqual(c.findField.stringValue, "", "no word taken from the caret")
        v.send(SCI_SETSEL, 0, 11)
        Preferences.update { $0.fillFindMaxCharacters = 5 }
        c.show(.find)
        XCTAssertEqual(c.findField.stringValue, "", "over the limit")
        Preferences.update { $0.fillFindWithSelection = false; $0.fillFindMaxCharacters = 100 }
        c.show(.find)
        XCTAssertEqual(c.findField.stringValue, "")
        c.close()
    }

    func testReplaceCanStopAfterReplacing() {
        Preferences.update { $0.replaceStopsWithoutFindingNext = true }
        let v = makeEditor("cat cat")
        v.send(SCI_SETSEL, 0, 3)
        let c = FindReplaceController(defaults: isolated("stop")) { v }
        c.findField.stringValue = "cat"
        c.replaceField.stringValue = "dog"
        c.replace()
        XCTAssertEqual(c.status, SearchMessages.replacedOnly)
        XCTAssertEqual(String(decoding: v.utf8Bytes(), as: UTF8.self), "dog cat")
        XCTAssertEqual(v.send(SCI_GETSELECTIONSTART), v.send(SCI_GETSELECTIONEND), "nothing else selected")
    }

    func testNoConfirmationWhenTurnedOff() {
        Preferences.update { $0.confirmReplaceInAllOpened = false }
        let v = makeEditor("x")
        let c = FindReplaceController(defaults: isolated("confirm")) { v }
        c.documentsProvider = { (nil, [SearchDocument(editor: v, path: "/x")]) }
        var asked = false
        c.confirmReplaceInOpenedFiles = { asked = true; return true }
        c.findField.stringValue = "x"
        c.replaceField.stringValue = "y"
        c.replaceAllInOpenedDocuments()
        XCTAssertFalse(asked)
        XCTAssertEqual(String(decoding: v.utf8Bytes(), as: UTF8.self), "y")
    }

    func testInSelectionThresholdZeroNeverTicks() {
        Preferences.update { $0.inSelectionThreshold = 0 }
        let v = makeEditor(String(repeating: "x ", count: 1000))
        v.send(SCI_SETSEL, 0, 1500)
        let c = FindReplaceController(defaults: isolated("threshold")) { v }
        c.show(.find)
        XCTAssertFalse(c.options.inSelection)
        c.close()
    }

    // MARK: Window

    func testTheWindowSavesWhatTheControlsSay() {
        let c = PreferencesController()
        c.caretWidthPopup.selectItem(at: 5)
        c.foldStylePopup.selectItem(at: 2)
        c.edgeField.stringValue = "72"
        c.lineEndingPopup.selectItem(at: 0)
        c.controlChanged(nil)
        let p = Preferences.current
        XCTAssertEqual(p.caretWidth, 5)
        XCTAssertEqual(p.foldMarkStyle, .circle)
        XCTAssertEqual(p.edgeColumns, [72])
        XCTAssertEqual(p.newDocLineEnding, .crlf)
        XCTAssertTrue(c.edgeBackgroundBox.isEnabled, "background mode needs exactly one column")
        XCTAssertEqual(c.tabView.tabViewItems.map(\.label), ["Toolbar", "New Document", "Editing", "Margins", "Indentation", "Searching", "File Association", "Misc."])
    }

    func testTheIndentationPageEditsOneLanguage() throws {
        let c = PreferencesController()
        let index = try XCTUnwrap(c.indentLanguagePopup.itemTitles.firstIndex(of: "SQL"))
        c.indentLanguagePopup.selectItem(at: index)
        c.indentLanguageChosen(nil)
        XCTAssertEqual(c.indentLanguage, "sql")
        XCTAssertEqual(c.useDefaultBox.state, .on)
        c.useDefaultBox.state = .off
        c.indentSizeField.integerValue = 3
        c.spacesRadio.state = .on
        c.indentationChanged(c.spacesRadio)
        XCTAssertEqual(Preferences.current.languageTabs["sql"], Preferences.TabSetting(size: 3, useSpaces: true, backspaceUnindent: false))
        c.useDefaultBox.state = .on
        c.indentationChanged(c.useDefaultBox)
        XCTAssertNil(Preferences.current.languageTabs["sql"])
        c.indentLanguagePopup.selectItem(at: 0)
        c.indentLanguageChosen(nil)
        XCTAssertNil(c.indentLanguage)
        XCTAssertTrue(c.useDefaultBox.isHidden)
    }

    private func makeEditor(_ text: String) -> ScintillaView {
        let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
        v.setUTF8Bytes(Data(text.utf8))
        return v
    }

    private func isolated(_ name: String) -> UserDefaults {
        let suite = "app.inkpad.Inkpad.tests.prefs.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }
}

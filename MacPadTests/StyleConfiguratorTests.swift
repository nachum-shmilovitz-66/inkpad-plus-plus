import XCTest
@testable import MacPad

// MAC-37: the Style Configurator — the editable theme document, Global override, the dialog.

private func modelDocument() throws -> StyleDocument {
    try StyleDocument(url: XCTUnwrap(NppData.url("stylers.model.xml")))
}

final class StyleDocumentTests: XCTestCase {
    func testLanguagesAreSortedWithSearchResultLast() throws {
        let doc = try modelDocument()
        let descriptions = doc.languages.map(\.description)
        XCTAssertEqual(doc.languages.last?.name, "searchResult")
        let sorted = descriptions.dropLast().sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        XCTAssertEqual(Array(descriptions.dropLast()), sorted)
        XCTAssertTrue(doc.styleNames(language: nil).contains("Default Style"))
        XCTAssertTrue(doc.styleNames(language: nil).contains("Global override"))
        XCTAssertEqual(doc.styleNames(language: "cpp").first, "PREPROCESSOR")
    }

    func testEditsPatchOnlyAttributesTheFileHas() throws {
        let doc = try modelDocument()
        let word = StyleDocument.Ref(language: "cpp", name: "INSTRUCTION WORD")
        XCTAssertFalse(doc.isDirty)
        doc.setForeground(word, scintillaColour(fromHex: "123456")!)
        XCTAssertEqual(doc.attribute(word, "fgColor"), "123456")
        XCTAssertTrue(doc.isDirty)
        doc.setFontStyle(word, bit: 2, on: true)
        XCTAssertEqual(doc.fontStyle(word) & 2, 2)
        doc.setFontStyle(word, bit: 2, on: false)
        XCTAssertEqual(doc.fontStyle(word) & 2, 0)

        let caret = StyleDocument.Ref(language: nil, name: "Caret colour")
        XCTAssertNil(doc.attribute(caret, "bgColor"), "the model's caret style has no background")
        doc.setBackground(caret, 0xFFFFFF)
        XCTAssertNil(doc.attribute(caret, "bgColor"), "a missing colour is not added (the swatch is disabled)")
    }

    func testFontSizeEmptyMeansInherit() throws {
        let doc = try modelDocument()
        let word = StyleDocument.Ref(language: "cpp", name: "INSTRUCTION WORD")
        doc.setFontSize(word, 14)
        XCTAssertEqual(doc.attribute(word, "fontSize"), "14")
        doc.setFontSize(word, nil)
        XCTAssertEqual(doc.attribute(word, "fontSize"), "")
    }

    func testUserKeywordsOnlyOnKeywordStylesAndUserExtensions() throws {
        let doc = try modelDocument()
        let word = StyleDocument.Ref(language: "cpp", name: "INSTRUCTION WORD")
        doc.setUserKeywords(word, "foo bar")
        XCTAssertEqual(doc.userKeywords(word), "foo bar")
        let comment = StyleDocument.Ref(language: "cpp", name: "COMMENT")
        doc.setUserKeywords(comment, "nope")
        XCTAssertEqual(doc.userKeywords(comment), "", "COMMENT has no keywordClass")
        doc.setUserExtensions("python", "pyw2 sage")
        XCTAssertEqual(doc.theme.userExtensions["python"], ["pyw2", "sage"])
        XCTAssertEqual(doc.theme.lexerStyles["cpp"]?.first { $0.name == "INSTRUCTION WORD" }?.userWords, "foo bar")
    }

    func testSaveKeepsTheRestOfTheFile() throws {
        let doc = try modelDocument()
        let before = doc.theme
        doc.setForeground(StyleDocument.Ref(language: "python", name: "COMMENT LINE"), 0x00FF00)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacPadStyles-\(UUID().uuidString)/stylers.xml")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try doc.save(to: url)
        XCTAssertFalse(doc.isDirty)
        let saved = StyleTheme(url: url)
        XCTAssertEqual(saved.lexerStyles.count, before.lexerStyles.count)
        XCTAssertEqual(saved.globalStyles.count, before.globalStyles.count)
        XCTAssertEqual(saved.lexerStyles["python"]?.first { $0.name == "COMMENT LINE" }?.foreground, 0x00FF00)
        XCTAssertEqual(saved.lexerStyles["cpp"]?.count, before.lexerStyles["cpp"]?.count)
    }

    func testHexIsNotepadPlusPlusRRGGBB() {
        XCTAssertEqual(StyleDocument.hex(scintillaColour(fromHex: "FF8000")!), "FF8000")
        XCTAssertEqual(StyleConfiguratorController.bgr(StyleConfiguratorController.color(0x123456)), 0x123456)
    }
}

final class GlobalOverrideTests: XCTestCase {
    private func style(_ fg: Int?, _ bg: Int?, font: String? = "Courier New", size: Int? = 10, fontStyle: Int? = 0) throws -> StyleEntry {
        let e = XMLElement(name: "WordsStyle")
        e.addAttribute(XMLNode.attribute(withName: "name", stringValue: "X") as! XMLNode)
        if let fg { e.addAttribute(XMLNode.attribute(withName: "fgColor", stringValue: StyleDocument.hex(fg)) as! XMLNode) }
        if let bg { e.addAttribute(XMLNode.attribute(withName: "bgColor", stringValue: StyleDocument.hex(bg)) as! XMLNode) }
        if let font { e.addAttribute(XMLNode.attribute(withName: "fontName", stringValue: font) as! XMLNode) }
        if let size { e.addAttribute(XMLNode.attribute(withName: "fontSize", stringValue: String(size)) as! XMLNode) }
        if let fontStyle { e.addAttribute(XMLNode.attribute(withName: "fontStyle", stringValue: String(fontStyle)) as! XMLNode) }
        return StyleEntry(e)
    }

    func testNothingForcedLeavesStylesAlone() throws {
        let s = try style(0x111111, 0x222222)
        XCTAssertEqual(GlobalOverride().apply(to: s, styleID: 5, override: try style(0xAAAAAA, 0xBBBBBB)).foreground, 0x111111)
    }

    func testForcedColoursFontsAndStyles() throws {
        let override = try style(0xAAAAAA, nil, font: "Menlo", size: 14, fontStyle: 1)
        var flags = GlobalOverride()
        flags.foreground = true
        flags.background = true
        flags.font = true
        flags.fontSize = true
        flags.bold = true
        let s = flags.apply(to: try style(0x111111, 0x222222, fontStyle: 2), styleID: 5, override: override)
        XCTAssertEqual(s.foreground, 0xAAAAAA)
        XCTAssertNil(s.background, "the override has no background: the style inherits the default's")
        XCTAssertEqual(s.fontName, "Menlo")
        XCTAssertEqual(s.fontSize, 14)
        XCTAssertEqual(s.fontStyle, 3, "bold forced on, italic kept")
        let def = flags.apply(to: try style(0x111111, 0x222222), styleID: 32, override: override)
        XCTAssertEqual(def.background, 0x222222, "the Default Style keeps its own background")
    }

    func testTheEditorAppliesTheOverride() throws {
        defer { GlobalOverride().save() }
        var flags = GlobalOverride()
        flags.foreground = true
        flags.save()
        let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        EditorStyler.configureEditor(v)
        let theme = StyleTheme.default
        EditorStyler.apply(language: LanguageCatalog.shared.language(named: "cpp")!, theme: theme, to: v)
        let forced = try XCTUnwrap(theme.global("Global override")?.foreground)
        XCTAssertEqual(v.send(SCI_STYLEGETFORE, Int(SCE_C_WORD)), forced)
    }
}

final class StyleConfiguratorDialogTests: XCTestCase {
    private var root: URL!
    private var themes: ThemeManager!
    private var defaults: UserDefaults!
    private let suite = "app.macpad.MacPad.tests.styleconfig"

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacPadStyleCfg-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        themes = ThemeManager(defaults: defaults, supportDirectory: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testControlsFollowTheStyleAttributes() {
        let c = StyleConfiguratorController(themes: themes, defaults: defaults)
        c.open()
        XCTAssertEqual(c.language, nil)
        XCTAssertEqual(c.languagePopup.titleOfSelectedItem, "Global Styles")
        c.selectStyle("Caret colour")
        XCTAssertTrue(c.foregroundWell.isEnabled)
        XCTAssertFalse(c.backgroundWell.isEnabled)
        XCTAssertFalse(c.fontCombo.isEnabled)
        c.selectStyle("Global override")
        XCTAssertFalse(c.overrideBoxes[0].superview!.isHidden)
        c.selectLanguage("cpp")
        XCTAssertEqual(c.descriptionLabel.stringValue, "C++: PREPROCESSOR")
        c.selectStyle("INSTRUCTION WORD")
        XCTAssertTrue(c.fontCombo.isEnabled)
        XCTAssertFalse(c.defaultKeywords.string.isEmpty, "the keyword boxes show for a keyword style")
        XCTAssertTrue(c.defaultExtField.stringValue.contains("cpp"))
        c.cancel()
    }

    func testEditsPreviewAndCancelRestores() {
        let c = StyleConfiguratorController(themes: themes, defaults: defaults)
        c.open()
        c.selectLanguage("cpp")
        c.selectStyle("INSTRUCTION WORD")
        c.setForeground(StyleConfiguratorController.color(0x0000FF))
        XCTAssertEqual(themes.current.lexerStyles["cpp"]?.first { $0.name == "INSTRUCTION WORD" }?.foreground, 0x0000FF,
                       "the edit is live everywhere")
        c.cancel()
        XCTAssertNil(themes.previewTheme)
        XCTAssertNotEqual(themes.current.lexerStyles["cpp"]?.first { $0.name == "INSTRUCTION WORD" }?.foreground, 0x0000FF)
        XCTAssertFalse(FileManager.default.fileExists(atPath: themes.savePath(for: ThemeManager.defaultName).path))
    }

    func testSavingDefaultWritesTheUsersStylersAndABundledThemeIsCopied() throws {
        let c = StyleConfiguratorController(themes: themes, defaults: defaults)
        c.open()
        c.selectLanguage("python")
        c.selectStyle("COMMENT LINE")
        c.setForeground(StyleConfiguratorController.color(0x00AA00))
        c.saveAndClose()
        let stylers = themes.savePath(for: ThemeManager.defaultName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stylers.path))
        XCTAssertEqual(themes.available.first?.url, stylers, "Default now reads the user's stylers.xml")
        XCTAssertEqual(themes.current.lexerStyles["python"]?.first { $0.name == "COMMENT LINE" }?.foreground, 0x00AA00)

        c.open()
        c.switchTheme(to: "Monokai")
        XCTAssertEqual(themes.current.global("Default Style")?.background, themes.theme(named: "Monokai").global("Default Style")?.background,
                       "a theme switch previews at once")
        c.selectLanguage("python")
        c.selectStyle("COMMENT LINE")
        c.setForeground(StyleConfiguratorController.color(0x0000AA))
        c.saveAndClose()
        XCTAssertEqual(themes.selectedName, "Monokai")
        XCTAssertEqual(themes.url(of: "Monokai")?.resolvingSymlinksInPath(),
                       themes.userDirectory.appendingPathComponent("Monokai.xml").resolvingSymlinksInPath(),
                       "the bundled theme was copied to the user's folder, not edited in place")
    }

    func testSwitchingWithUnsavedEditsAsks() {
        let c = StyleConfiguratorController(themes: themes, defaults: defaults)
        var asked: String?
        c.askToSaveBeforeSwitching = { asked = $0; return false }
        c.open()
        c.selectLanguage("cpp")
        c.selectStyle("COMMENT")
        c.setForeground(StyleConfiguratorController.color(0x0000FF))
        c.switchTheme(to: "Zenburn")
        XCTAssertEqual(asked, ThemeManager.defaultName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: themes.savePath(for: ThemeManager.defaultName).path), "declined: not saved")
        c.cancel()
        XCTAssertEqual(themes.selectedName, ThemeManager.defaultName, "Cancel reverts the theme switch")
    }

    func testUserExtensionsChooseTheLanguage() throws {
        let doc = try modelDocument()
        doc.setUserExtensions("python", "sage")
        ThemeManager.shared.preview(doc.theme)
        defer { ThemeManager.shared.preview(nil) }
        XCTAssertEqual(LanguageCatalog.shared.language(for: URL(fileURLWithPath: "/x/a.sage")).name, "python")
    }
}

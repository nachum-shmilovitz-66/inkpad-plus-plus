import AppKit

/// Inkpad++ › Settings… (⌘,): upstream's Preferences pages that apply on a Mac (MAC-38). Like
/// upstream there is no OK button: every change is saved and applied to open editors at once.
final class PreferencesController: NSWindowController {
    let tabView = NSTabView()

    // New Document
    let lineEndingPopup = NSPopUpButton()
    let encodingPopup = NSPopUpButton()
    let languagePopup = NSPopUpButton()
    // Editing
    let currentLinePopup = NSPopUpButton()
    let frameWidthField = NSTextField()
    let caretWidthPopup = NSPopUpButton()
    let blinkSlider = NSSlider(value: 600, minValue: 0, maxValue: 2500, target: nil, action: nil)
    let wrapPopup = NSPopUpButton()
    let virtualSpaceBox = NSButton(checkboxWithTitle: "Enable virtual space", target: nil, action: nil)
    let scrollBeyondBox = NSButton(checkboxWithTitle: "Enable scrolling beyond last line", target: nil, action: nil)
    let dragDropBox = NSButton(checkboxWithTitle: "Enable selected text drag-and-drop", target: nil, action: nil)
    let multiEditBox = NSButton(checkboxWithTitle: "Enable Multi-Editing (⌘+Mouse click/selection)", target: nil, action: nil)
    let eolRoundedBox = NSButton(checkboxWithTitle: "Show line endings as rounded boxes (else plain text)", target: nil, action: nil)
    /// MAC-80: extra pixels between lines.
    let lineSpacingPopup = NSPopUpButton()
    // Toolbar (MAC-69)
    let toolbarIconsPopup = NSPopUpButton()
    // Margins / Border / Edge
    let foldStylePopup = NSPopUpButton()
    let lineNumbersBox = NSButton(checkboxWithTitle: "Display line numbers", target: nil, action: nil)
    let dynamicWidthBox = NSButton(checkboxWithTitle: "Dynamic width (else constant)", target: nil, action: nil)
    let bookmarkMarginBox = NSButton(checkboxWithTitle: "Display bookmark margin", target: nil, action: nil)
    let edgeField = NSTextField()
    let edgeBackgroundBox = NSButton(checkboxWithTitle: "Background mode (one column only)", target: nil, action: nil)
    let paddingLeftField = NSTextField()
    let paddingRightField = NSTextField()
    // Indentation
    let indentLanguagePopup = NSPopUpButton()
    let useDefaultBox = NSButton(checkboxWithTitle: "Use default value", target: nil, action: nil)
    let indentSizeField = NSTextField()
    let tabsRadio = NSButton(radioButtonWithTitle: "Tab character", target: nil, action: nil)
    let spacesRadio = NSButton(radioButtonWithTitle: "Space character(s)", target: nil, action: nil)
    let backspaceUnindentBox = NSButton(checkboxWithTitle: "Backspace key unindents instead of removing single space", target: nil, action: nil)
    // Searching
    let inSelectionField = NSTextField()
    let fillFindBox = NSButton(checkboxWithTitle: "Fill Find Field with Selected Text", target: nil, action: nil)
    let fillMaxField = NSTextField()
    let selectWordBox = NSButton(checkboxWithTitle: "Select Word Under Caret when Nothing Selected", target: nil, action: nil)
    let staysOpenBox = NSButton(checkboxWithTitle: "Find dialog remains open after search that outputs to results window", target: nil, action: nil)
    let confirmReplaceBox = NSButton(checkboxWithTitle: "Confirm Replace All in All Opened Documents", target: nil, action: nil)
    let replaceStopsBox = NSButton(checkboxWithTitle: "Replace: Don't move to the following occurrence", target: nil, action: nil)
    // Misc
    let recentFilesField = NSTextField()
    let sqlBackslashBox = NSButton(checkboxWithTitle: "Treat backslash as escape character for SQL", target: nil, action: nil)
    let scaleFontsBox = NSButton(checkboxWithTitle: "Scale Windows font sizes for macOS (× 4/3)", target: nil, action: nil)
    /// MAC-81.
    let fullPathBox = NSButton(checkboxWithTitle: "Show the full file path in the title bar", target: nil, action: nil)
    let autoUpdateBox = NSButton(checkboxWithTitle: "Check for updates automatically (once a day)", target: nil, action: nil)
    // File Association (MAC-51)
    private(set) lazy var fileAssociationPane: FileAssociationPane = {
        let pane = FileAssociationPane()
        pane.onError = { [weak self] error in
            let alert = NSAlert(error: error)
            if let window = self?.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
        return pane
    }()

    static let lineEndings: [(String, LineEnding)] = [("Windows (CR LF)", .crlf), ("Unix (LF)", .lf), ("Macintosh (CR)", .cr)]
    static let encodings: [(String, Preferences.NewDocEncoding)] = [
        ("ANSI", .ansi), ("UTF-8", .utf8), ("UTF-8 with BOM", .utf8BOM),
        ("UTF-16 Big Endian with BOM", .utf16BE), ("UTF-16 Little Endian with BOM", .utf16LE),
    ]
    static let caretWidths = ["0", "1", "2", "3", "Block", "Block After"]
    static let defaultIndentTitle = "[Default]"
    /// Languages as the Language menu names them, Normal Text first.
    private let languages: [(title: String, name: String)]

    init() {
        var list: [(String, String)] = []
        for entry in languageMenuEntries {
            switch entry {
            case .item(let title, let language): list.append((title, language))
            case .submenu(_, let items): list.append(contentsOf: items.map { ($0.title, $0.language) })
            case .separator: break
            }
        }
        languages = [list[0]] + list.dropFirst().sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        load()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        load()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
    }

    // MARK: - Model ⇄ controls

    /// Puts the saved settings into the controls.
    func load() {
        let p = Preferences.current
        lineEndingPopup.selectItem(at: Self.lineEndings.firstIndex { $0.1 == p.newDocLineEnding } ?? 1)
        encodingPopup.selectItem(at: Self.encodings.firstIndex { $0.1 == p.newDocEncoding } ?? 1)
        languagePopup.selectItem(at: languages.firstIndex { $0.name == p.newDocLanguage } ?? 0)
        currentLinePopup.selectItem(at: p.currentLineIndicator.rawValue)
        frameWidthField.integerValue = p.currentLineFrameWidth
        frameWidthField.isEnabled = p.currentLineIndicator == .frame
        caretWidthPopup.selectItem(at: min(max(p.caretWidth, 0), 5))
        blinkSlider.integerValue = p.caretBlinkRate == 0 ? 2500 : p.caretBlinkRate
        wrapPopup.selectItem(at: Preferences.LineWrap.allCases.firstIndex(of: p.lineWrap) ?? 1)
        virtualSpaceBox.state = p.virtualSpace ? .on : .off
        scrollBeyondBox.state = p.scrollBeyondLastLine ? .on : .off
        dragDropBox.state = p.dragAndDrop ? .on : .off
        multiEditBox.state = p.multiEditing ? .on : .off
        eolRoundedBox.state = p.eolRounded ? .on : .off
        lineSpacingPopup.selectItem(at: Preferences.lineSpacingChoices.firstIndex(of: p.lineSpacing) ?? 2)
        toolbarIconsPopup.selectItem(at: Preferences.ToolbarIconSet.allCases.firstIndex(of: p.toolbarIconSet) ?? 0)
        foldStylePopup.selectItem(at: Preferences.FoldMarkStyle.allCases.firstIndex(of: p.foldMarkStyle) ?? 3)
        lineNumbersBox.state = p.showLineNumbers ? .on : .off
        dynamicWidthBox.state = p.lineNumberDynamicWidth ? .on : .off
        dynamicWidthBox.isEnabled = p.showLineNumbers
        bookmarkMarginBox.state = p.showBookmarkMargin ? .on : .off
        edgeField.stringValue = p.edgeColumns.map(String.init).joined(separator: " ")
        edgeBackgroundBox.state = p.edgeBackgroundMode ? .on : .off
        edgeBackgroundBox.isEnabled = p.edgeColumns.count == 1
        paddingLeftField.integerValue = p.paddingLeft
        paddingRightField.integerValue = p.paddingRight
        loadIndentation()
        inSelectionField.integerValue = p.inSelectionThreshold
        fillFindBox.state = p.fillFindWithSelection ? .on : .off
        fillMaxField.integerValue = p.fillFindMaxCharacters
        selectWordBox.state = p.selectWordUnderCaret ? .on : .off
        fillMaxField.isEnabled = p.fillFindWithSelection
        selectWordBox.isEnabled = p.fillFindWithSelection
        staysOpenBox.state = p.findDialogStaysOpen ? .on : .off
        confirmReplaceBox.state = p.confirmReplaceInAllOpened ? .on : .off
        replaceStopsBox.state = p.replaceStopsWithoutFindingNext ? .on : .off
        recentFilesField.integerValue = p.maxRecentFiles
        sqlBackslashBox.state = p.sqlBackslashEscapes ? .on : .off
        scaleFontsBox.state = p.scaleWindowsFontSizes ? .on : .off
        fullPathBox.state = p.showFullPathInTitle ? .on : .off
        autoUpdateBox.state = p.checkForUpdatesAutomatically ? .on : .off
    }

    /// The language chosen on the Indentation page (nil = [Default]).
    var indentLanguage: String? {
        let index = indentLanguagePopup.indexOfSelectedItem
        return index <= 0 ? nil : languages[index].name  // the list is [Default] + languages without Normal Text
    }

    private func loadIndentation() {
        let p = Preferences.current
        let language = indentLanguage
        let setting = language.map { p.tabs(for: $0) } ?? p.defaultTabs
        let usesDefault = language.map { p.languageTabs[$0] == nil } ?? false
        useDefaultBox.isHidden = language == nil
        useDefaultBox.state = usesDefault ? .on : .off
        indentSizeField.integerValue = setting.size
        tabsRadio.state = setting.useSpaces ? .off : .on
        spacesRadio.state = setting.useSpaces ? .on : .off
        backspaceUnindentBox.state = setting.backspaceUnindent ? .on : .off
        for control in [indentSizeField, tabsRadio, spacesRadio, backspaceUnindentBox] as [NSControl] { control.isEnabled = !usesDefault }
    }

    /// Reads every control into the settings, saves and applies them.
    @objc func controlChanged(_ sender: Any?) {
        Preferences.update { p in
            p.newDocLineEnding = Self.lineEndings[max(lineEndingPopup.indexOfSelectedItem, 0)].1
            p.newDocEncoding = Self.encodings[max(encodingPopup.indexOfSelectedItem, 0)].1
            p.newDocLanguage = languages[max(languagePopup.indexOfSelectedItem, 0)].name
            p.currentLineIndicator = Preferences.CurrentLineIndicator(rawValue: currentLinePopup.indexOfSelectedItem) ?? .highlight
            p.currentLineFrameWidth = min(max(frameWidthField.integerValue, 1), 6)
            p.caretWidth = max(caretWidthPopup.indexOfSelectedItem, 0)
            p.caretBlinkRate = blinkSlider.integerValue >= 2500 ? 0 : max(50, (blinkSlider.integerValue / 50) * 50)
            p.lineWrap = Preferences.LineWrap.allCases[max(wrapPopup.indexOfSelectedItem, 0)]
            p.virtualSpace = virtualSpaceBox.state == .on
            p.scrollBeyondLastLine = scrollBeyondBox.state == .on
            p.dragAndDrop = dragDropBox.state == .on
            p.multiEditing = multiEditBox.state == .on
            p.eolRounded = eolRoundedBox.state == .on
            p.lineSpacing = Preferences.lineSpacingChoices[max(lineSpacingPopup.indexOfSelectedItem, 0)]
            p.toolbarIconSet = Preferences.ToolbarIconSet.allCases[max(toolbarIconsPopup.indexOfSelectedItem, 0)]
            p.foldMarkStyle = Preferences.FoldMarkStyle.allCases[max(foldStylePopup.indexOfSelectedItem, 0)]
            p.showLineNumbers = lineNumbersBox.state == .on
            p.lineNumberDynamicWidth = dynamicWidthBox.state == .on
            p.showBookmarkMargin = bookmarkMarginBox.state == .on
            p.edgeColumns = Self.parseColumns(edgeField.stringValue)
            p.edgeBackgroundMode = edgeBackgroundBox.state == .on && p.edgeColumns.count == 1
            p.paddingLeft = min(max(paddingLeftField.integerValue, 0), 30)
            p.paddingRight = min(max(paddingRightField.integerValue, 0), 30)
            p.inSelectionThreshold = min(max(inSelectionField.integerValue, 0), 1024)
            p.fillFindWithSelection = fillFindBox.state == .on
            p.fillFindMaxCharacters = min(max(fillMaxField.integerValue, 1), 16383)
            p.selectWordUnderCaret = selectWordBox.state == .on && p.fillFindWithSelection
            p.findDialogStaysOpen = staysOpenBox.state == .on
            p.confirmReplaceInAllOpened = confirmReplaceBox.state == .on
            p.replaceStopsWithoutFindingNext = replaceStopsBox.state == .on
            p.maxRecentFiles = min(max(recentFilesField.integerValue, 0), 30)
            p.sqlBackslashEscapes = sqlBackslashBox.state == .on
            p.scaleWindowsFontSizes = scaleFontsBox.state == .on
            p.showFullPathInTitle = fullPathBox.state == .on
            p.checkForUpdatesAutomatically = autoUpdateBox.state == .on
        }
        load()
    }

    /// The Indentation page's own controls (they edit one language, or the default).
    @objc func indentationChanged(_ sender: Any?) {
        if sender as? NSButton === tabsRadio { spacesRadio.state = .off }
        if sender as? NSButton === spacesRadio { tabsRadio.state = .off }
        let language = indentLanguage
        let setting = Preferences.TabSetting(size: min(max(indentSizeField.integerValue, 1), 127),
                                             useSpaces: spacesRadio.state == .on,
                                             backspaceUnindent: backspaceUnindentBox.state == .on)
        Preferences.update { p in
            if let language {
                p.languageTabs[language] = useDefaultBox.state == .on ? nil : setting
            } else {
                p.defaultTabs = setting
            }
        }
        loadIndentation()
    }

    @objc func indentLanguageChosen(_ sender: Any?) { loadIndentation() }

    /// "Add your column marker by indicating its position with a decimal number": digits and spaces.
    static func parseColumns(_ text: String) -> [Int] {
        text.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1...8192).contains($0) }
    }

    /// Preferences.ToolbarIconSet's cases, in order; the Fluent names are upstream's.
    static let toolbarIconTitles = ["SF Symbols (macOS)", "Fluent UI", "Filled Fluent UI"]

    // MARK: - Layout

    private func build() {
        guard let content = window?.contentView else { return }
        func popup(_ p: NSPopUpButton, _ titles: [String]) {
            p.addItems(withTitles: titles)
            p.target = self
            p.action = #selector(controlChanged(_:))
        }
        popup(lineEndingPopup, Self.lineEndings.map(\.0))
        popup(encodingPopup, Self.encodings.map(\.0))
        popup(languagePopup, languages.map(\.title))
        popup(currentLinePopup, ["None", "Highlight Background", "Frame"])
        popup(caretWidthPopup, Self.caretWidths)
        popup(wrapPopup, ["Default", "Aligned", "Indent"])
        popup(lineSpacingPopup, Preferences.lineSpacingChoices.map { $0 == 0 ? "None" : "+\($0) px" })
        popup(toolbarIconsPopup, Self.toolbarIconTitles)
        popup(foldStylePopup, ["Simple", "Arrow", "Circle tree", "Box tree", "None"])
        indentLanguagePopup.addItems(withTitles: [Self.defaultIndentTitle] + languages.dropFirst().map(\.title))
        indentLanguagePopup.target = self
        indentLanguagePopup.action = #selector(indentLanguageChosen(_:))
        for control in [virtualSpaceBox, scrollBeyondBox, dragDropBox, multiEditBox, eolRoundedBox, lineNumbersBox, dynamicWidthBox,
                        bookmarkMarginBox, edgeBackgroundBox, fillFindBox, selectWordBox, staysOpenBox, confirmReplaceBox,
                        replaceStopsBox, sqlBackslashBox, scaleFontsBox, fullPathBox, autoUpdateBox, blinkSlider] as [NSControl] {
            control.target = self
            control.action = #selector(controlChanged(_:))
        }
        for field in [frameWidthField, edgeField, paddingLeftField, paddingRightField, inSelectionField, fillMaxField, recentFilesField] {
            field.target = self
            field.action = #selector(controlChanged(_:))
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: field === edgeField ? 220 : 60).isActive = true
        }
        edgeField.placeholderString = "e.g. 80 120"
        for control in [useDefaultBox, tabsRadio, spacesRadio, backspaceUnindentBox, indentSizeField] as [NSControl] {
            control.target = self
            control.action = #selector(indentationChanged(_:))
        }
        indentSizeField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        blinkSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        blinkSlider.numberOfTickMarks = 0

        func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }
        func grid(_ rows: [[NSView]]) -> NSGridView {
            let g = NSGridView(views: rows)
            g.column(at: 0).xPlacement = .trailing
            g.rowAlignment = .firstBaseline
            g.rowSpacing = 10
            return g
        }
        func page(_ title: String, _ views: [NSView]) {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
            let item = NSTabViewItem(identifier: title)
            item.label = title
            item.view = stack
            tabView.addTabViewItem(item)
        }

        // upstream puts Toolbar right after General; showing and customizing it are in the View menu, as on the Mac.
        page("Toolbar", [grid([[label("Icons:"), toolbarIconsPopup]]),
                         label("Show, hide or rearrange the toolbar from the View menu.")])
        page("New Document", [grid([[label("Format (Line ending):"), lineEndingPopup], [label("Encoding:"), encodingPopup],
                                    [label("Default language:"), languagePopup]])])
        page("Editing", [grid([[label("Current Line Indicator:"), currentLinePopup], [label("Frame width:"), frameWidthField],
                               [label("Caret width:"), caretWidthPopup],
                               [label("Caret blink rate:"), NSStackView(views: [label("Fast"), blinkSlider, label("Slow (no blink)")])],
                               [label("Line Wrap:"), wrapPopup], [label("Line spacing:"), lineSpacingPopup]]),
                         virtualSpaceBox, scrollBeyondBox, dragDropBox, multiEditBox, eolRoundedBox])
        page("Margins", [grid([[label("Fold Margin Style:"), foldStylePopup]]), lineNumbersBox, dynamicWidthBox, bookmarkMarginBox,
                         grid([[label("Vertical edge columns:"), edgeField]]), edgeBackgroundBox,
                         grid([[label("Padding left:"), paddingLeftField], [label("Padding right:"), paddingRightField]])])
        page("Indentation", [indentLanguagePopup, useDefaultBox, grid([[label("Indent size:"), indentSizeField]]),
                             NSStackView(views: [label("Indent using:"), tabsRadio, spacesRadio]), backspaceUnindentBox])
        page("Searching", [grid([[label("Minimum Size for Auto-Checking \"In selection\":"), inSelectionField]]),
                           fillFindBox, grid([[label("Max Characters to Auto-Fill Find Field from Selection:"), fillMaxField]]),
                           selectWordBox, staysOpenBox, confirmReplaceBox, replaceStopsBox])
        page("File Association", [fileAssociationPane])
        page("Misc.", [grid([[label("Recent Files: max. number of entries:"), recentFilesField]]), sqlBackslashBox, scaleFontsBox, fullPathBox, autoUpdateBox])

        tabView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            tabView.widthAnchor.constraint(greaterThanOrEqualToConstant: 600),
            tabView.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
        ])
    }
}

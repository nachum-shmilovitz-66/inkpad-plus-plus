import AppKit

/// Notepad++'s Style Configurator (WordStyleDlg, MAC-37): pick a theme, a language ("Global
/// Styles" first) and a style; change its colours, font, size, bold / italic / underline, user
/// extensions and user keywords. Every change shows at once in all editors; Save & Close writes the
/// theme (Default → the user's stylers.xml, others → the user's themes folder), Cancel undoes it all.
final class StyleConfiguratorController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate,
                                         NSTextViewDelegate, NSComboBoxDelegate {
    static let globalStylesTitle = "Global Styles"
    static let fontSizes = ["", "5", "6", "7", "8", "9", "10", "11", "12", "14", "16", "18", "20", "22", "24", "26", "28"]

    private let themes: ThemeManager
    private let defaults: UserDefaults
    /// Asked before switching themes with unsaved edits; true saves them first.
    var askToSaveBeforeSwitching: (String) -> Bool = { themeName in
        let alert = NSAlert()
        alert.messageText = themeName
        alert.informativeText = "Unsaved changes are about to be discarded!\nDo you want to save your changes before switching themes?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private(set) var editing: StyleDocument?
    private(set) var themeName = ThemeManager.defaultName
    /// nil = Global Styles.
    private(set) var language: String?
    private(set) var styleName: String?
    private var languages: [(name: String, description: String)] = []
    private var styles: [String] = []
    private var overrideAtOpen = GlobalOverride()
    private var themeSwitched = false

    let themePopup = NSPopUpButton()
    let languagePopup = NSPopUpButton()
    let styleTable = NSTableView()
    let descriptionLabel = NSTextField(labelWithString: "")
    let foregroundWell = NSColorWell()
    let backgroundWell = NSColorWell()
    let foregroundLabel = NSTextField(labelWithString: "Foreground colour")
    let backgroundLabel = NSTextField(labelWithString: "Background colour")
    let fontCombo = NSComboBox()
    let sizeCombo = NSComboBox()
    let boldBox = NSButton(checkboxWithTitle: "Bold", target: nil, action: nil)
    let italicBox = NSButton(checkboxWithTitle: "Italic", target: nil, action: nil)
    let underlineBox = NSButton(checkboxWithTitle: "Underline", target: nil, action: nil)
    let defaultExtField = NSTextField()
    let userExtField = NSTextField()
    private let extRow = NSStackView()
    let defaultKeywords = NSTextView()
    let userKeywords = NSTextView()
    private let keywordsRow = NSStackView()
    let overrideBoxes: [NSButton] = [
        "Force foreground color for all styles", "Force background color for all styles", "Force font choice for all styles",
        "Force font size choice for all styles", "Force bold choice for all styles", "Force italic choice for all styles",
        "Force underline choice for all styles",
    ].map { NSButton(checkboxWithTitle: $0, target: nil, action: nil) }
    private let overrideStack = NSStackView()
    let saveButton = NSButton(title: "Save & Close", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    init(themes: ThemeManager = .shared, defaults: UserDefaults = AppEnvironment.defaults) {
        self.themes = themes
        self.defaults = defaults
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        panel.title = "Style Configurator"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Opening

    /// Opens on the selected theme, Global Styles, its first style.
    func open() {
        overrideAtOpen = GlobalOverride.load(defaults)
        themeSwitched = false
        load(theme: themes.selectedName)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
    }

    private func load(theme name: String) {
        themeName = name
        editing = themes.url(of: name).flatMap { try? StyleDocument(url: $0) }
        themePopup.removeAllItems()
        themePopup.addItems(withTitles: themes.available.map(\.name))
        themePopup.selectItem(withTitle: name)
        languages = editing?.languages ?? []
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles: [Self.globalStylesTitle] + languages.map(\.description))
        selectLanguage(nil)
    }

    // MARK: - Selection

    func selectLanguage(_ name: String?) {
        language = name
        if let name, let index = languages.firstIndex(where: { $0.name == name }) {
            languagePopup.selectItem(at: index + 1)
        } else {
            languagePopup.selectItem(at: 0)
        }
        styles = editing?.styleNames(language: name) ?? []
        styleTable.reloadData()
        selectStyle(styles.first)
    }

    func selectStyle(_ name: String?) {
        styleName = name
        if let name, let row = styles.firstIndex(of: name) {
            styleTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        refreshControls()
    }

    private var ref: StyleDocument.Ref? { styleName.map { StyleDocument.Ref(language: language, name: $0) } }

    /// Notepad++'s setVisualFromStyleList: a control is live only where the file has the attribute.
    func refreshControls() {
        guard let editing, let ref else { return }
        let languageTitle = language.flatMap { l in languages.first { $0.name == l }?.description } ?? Self.globalStylesTitle
        descriptionLabel.stringValue = "\(languageTitle): \(ref.name)"

        let fg = editing.foreground(ref), bg = editing.background(ref)
        foregroundWell.isEnabled = fg != nil
        backgroundWell.isEnabled = bg != nil
        foregroundLabel.textColor = fg != nil ? .labelColor : .disabledControlTextColor
        backgroundLabel.textColor = bg != nil ? .labelColor : .disabledControlTextColor
        foregroundWell.color = fg.map(Self.color) ?? .windowBackgroundColor
        backgroundWell.color = bg.map(Self.color) ?? .windowBackgroundColor

        let fontEnabled = editing.has(ref, "fontName")
        for control in [fontCombo, sizeCombo, boldBox, italicBox, underlineBox] as [NSControl] { control.isEnabled = fontEnabled }
        fontCombo.stringValue = editing.attribute(ref, "fontName") ?? ""
        sizeCombo.stringValue = editing.attribute(ref, "fontSize") ?? ""
        let style = editing.fontStyle(ref)
        boldBox.state = style & 1 != 0 ? .on : .off
        italicBox.state = style & 2 != 0 ? .on : .off
        underlineBox.state = style & 4 != 0 ? .on : .off

        extRow.isHidden = language == nil
        if let language {
            defaultExtField.stringValue = LanguageCatalog.shared.languages[language]?.extensions.joined(separator: " ") ?? ""
            userExtField.stringValue = editing.userExtensions(language)
        }

        let keywordClass = editing.attribute(ref, "keywordClass")
        keywordsRow.isHidden = keywordClass == nil
        if let keywordClass, let index = keywordClassIndex(keywordClass) {
            defaultKeywords.string = language.flatMap { LanguageCatalog.shared.languages[$0]?.keywords[index] } ?? ""
            userKeywords.string = editing.userKeywords(ref)
        }

        overrideStack.isHidden = !(language == nil && ref.name == "Global override")
        let o = GlobalOverride.load(defaults)
        for (box, on) in zip(overrideBoxes, [o.foreground, o.background, o.font, o.fontSize, o.bold, o.italic, o.underline]) {
            box.state = on ? .on : .off
        }
    }

    // MARK: - Editing

    /// Shows the edited theme everywhere at once.
    private func changed() {
        guard let editing else { return }
        themes.preview(editing.theme)
    }

    func setForeground(_ colour: NSColor) {
        guard let ref else { return }
        editing?.setForeground(ref, Self.bgr(colour))
        changed()
    }

    func setBackground(_ colour: NSColor) {
        guard let ref else { return }
        editing?.setBackground(ref, Self.bgr(colour))
        changed()
    }

    func setFontName(_ name: String) {
        guard let ref else { return }
        editing?.setFontName(ref, name)
        changed()
    }

    func setFontSize(_ text: String) {
        guard let ref else { return }
        editing?.setFontSize(ref, Int(text))
        changed()
    }

    func setFontStyle(bit: Int, on: Bool) {
        guard let ref else { return }
        editing?.setFontStyle(ref, bit: bit, on: on)
        changed()
    }

    func setUserKeywords(_ words: String) {
        guard let ref else { return }
        editing?.setUserKeywords(ref, words)
        changed()
    }

    func setUserExtensions(_ text: String) {
        guard let language else { return }
        editing?.setUserExtensions(language, text)
        changed()
    }

    func setOverride(_ index: Int, _ on: Bool) {
        var o = GlobalOverride.load(defaults)
        switch index {
        case 0: o.foreground = on
        case 1: o.background = on
        case 2: o.font = on
        case 3: o.fontSize = on
        case 4: o.bold = on
        case 5: o.italic = on
        default: o.underline = on
        }
        o.save(defaults)
        changed()
    }

    /// Select theme: unsaved edits are offered for saving first; the new theme previews at once.
    func switchTheme(to name: String) {
        guard name != themeName else { return }
        if let editing, editing.isDirty, askToSaveBeforeSwitching(themeName) {
            try? editing.save(to: themes.savePath(for: themeName))
        }
        themeSwitched = true
        load(theme: name)
        changed()
    }

    // MARK: - Save & Close / Cancel

    func saveAndClose() {
        if let editing { try? editing.save(to: themes.savePath(for: themeName)) }
        themes.preview(nil)
        themes.select(themeName)
        themes.reload()
        overrideAtOpen = GlobalOverride.load(defaults)
        window?.orderOut(nil)
    }

    func cancel() {
        overrideAtOpen.save(defaults)
        editing = nil
        themes.preview(nil)
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }

    // MARK: - Colours

    static func color(_ bgr: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(bgr & 0xFF) / 255, green: CGFloat((bgr >> 8) & 0xFF) / 255,
                blue: CGFloat((bgr >> 16) & 0xFF) / 255, alpha: 1)
    }

    static func bgr(_ color: NSColor) -> Int {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded())
        return r | (g << 8) | (b << 16)
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { styles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: styles[row])
        cell.lineBreakMode = .byTruncatingTail
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = styleTable.selectedRow
        guard styles.indices.contains(row), styles[row] != styleName else { return }
        styleName = styles[row]
        refreshControls()
    }

    // MARK: - Actions

    @objc private func themeChosen(_ sender: NSPopUpButton) { sender.titleOfSelectedItem.map(switchTheme) }
    @objc private func languageChosen(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        selectLanguage(index <= 0 ? nil : languages[index - 1].name)
    }
    @objc private func foregroundChosen(_ sender: NSColorWell) { setForeground(sender.color) }
    @objc private func backgroundChosen(_ sender: NSColorWell) { setBackground(sender.color) }
    @objc private func fontChosen(_ sender: NSComboBox) { setFontName(sender.stringValue) }
    @objc private func sizeChosen(_ sender: NSComboBox) { setFontSize(sender.stringValue) }
    @objc private func styleBoxChanged(_ sender: NSButton) {
        let bit = sender === boldBox ? 1 : sender === italicBox ? 2 : 4
        setFontStyle(bit: bit, on: sender.state == .on)
    }
    @objc private func userExtChanged(_ sender: NSTextField) { setUserExtensions(sender.stringValue) }
    @objc private func overrideChanged(_ sender: NSButton) {
        if let index = overrideBoxes.firstIndex(of: sender) { setOverride(index, sender.state == .on) }
    }
    @objc private func saveClicked(_ sender: Any?) { saveAndClose() }
    @objc private func cancelClicked(_ sender: Any?) { cancel() }

    func textDidChange(_ notification: Notification) {
        if notification.object as? NSTextView === userKeywords { setUserKeywords(userKeywords.string) }
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard let combo = notification.object as? NSComboBox, combo.indexOfSelectedItem >= 0 else { return }
        let value = combo.itemObjectValue(at: combo.indexOfSelectedItem) as? String ?? ""
        combo === fontCombo ? setFontName(value) : setFontSize(value)
    }

    // MARK: - Layout

    private func build() {
        guard let content = window?.contentView else { return }
        themePopup.target = self
        themePopup.action = #selector(themeChosen(_:))
        languagePopup.target = self
        languagePopup.action = #selector(languageChosen(_:))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("style"))
        column.title = "Style"
        styleTable.addTableColumn(column)
        styleTable.headerView = nil
        styleTable.dataSource = self
        styleTable.delegate = self
        let tableScroll = NSScrollView()
        tableScroll.documentView = styleTable
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.widthAnchor.constraint(equalToConstant: 230).isActive = true
        tableScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true

        foregroundWell.target = self
        foregroundWell.action = #selector(foregroundChosen(_:))
        backgroundWell.target = self
        backgroundWell.action = #selector(backgroundChosen(_:))
        fontCombo.addItems(withObjectValues: [""] + NSFontManager.shared.availableFontFamilies.sorted())
        sizeCombo.addItems(withObjectValues: Self.fontSizes)
        for combo in [fontCombo, sizeCombo] {
            combo.delegate = self
            combo.target = self
            combo.completes = true
        }
        fontCombo.action = #selector(fontChosen(_:))
        sizeCombo.action = #selector(sizeChosen(_:))
        fontCombo.widthAnchor.constraint(equalToConstant: 200).isActive = true
        sizeCombo.widthAnchor.constraint(equalToConstant: 70).isActive = true
        for box in [boldBox, italicBox, underlineBox] {
            box.target = self
            box.action = #selector(styleBoxChanged(_:))
        }
        defaultExtField.isEditable = false
        defaultExtField.isSelectable = true
        userExtField.target = self
        userExtField.action = #selector(userExtChanged(_:))
        userExtField.placeholderString = "e.g. foo bar"
        for field in [defaultExtField, userExtField] { field.widthAnchor.constraint(equalToConstant: 200).isActive = true }
        for box in overrideBoxes {
            box.target = self
            box.action = #selector(overrideChanged(_:))
        }
        saveButton.target = self
        saveButton.action = #selector(saveClicked(_:))
        saveButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.keyEquivalent = "\u{1b}"

        func scroll(_ text: NSTextView, editable: Bool) -> NSScrollView {
            text.isEditable = editable
            text.isRichText = false
            text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            text.delegate = self
            text.isVerticallyResizable = true
            text.autoresizingMask = [.width]
            let s = NSScrollView()
            s.documentView = text
            s.hasVerticalScroller = true
            s.borderType = .bezelBorder
            s.heightAnchor.constraint(equalToConstant: 110).isActive = true
            s.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            return s
        }

        let themeRow = NSStackView(views: [NSTextField(labelWithString: "Select theme:"), themePopup])
        extRow.setViews([NSTextField(labelWithString: "Default ext.:"), defaultExtField, NSTextField(labelWithString: "+"),
                         NSTextField(labelWithString: "User ext.:"), userExtField], in: .leading)
        let left = NSStackView(views: [NSTextField(labelWithString: "Language:"), languagePopup,
                                       NSTextField(labelWithString: "Style:"), tableScroll, extRow])
        left.orientation = .vertical
        left.alignment = .leading
        extRow.orientation = .vertical
        extRow.alignment = .leading

        let colours = NSGridView(views: [[foregroundLabel, foregroundWell], [backgroundLabel, backgroundWell]])
        for well in [foregroundWell, backgroundWell] {
            well.widthAnchor.constraint(equalToConstant: 44).isActive = true
            well.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        let fonts = NSGridView(views: [[NSTextField(labelWithString: "Font name:"), fontCombo],
                                       [NSTextField(labelWithString: "Font size:"), sizeCombo]])
        let styleBoxes = NSStackView(views: [boldBox, italicBox, underlineBox])
        keywordsRow.setViews([
            stack([NSTextField(labelWithString: "Default keywords"), scroll(defaultKeywords, editable: false)]),
            NSTextField(labelWithString: "+"),
            stack([NSTextField(labelWithString: "User-defined keywords"), scroll(userKeywords, editable: true)]),
        ], in: .leading)
        overrideStack.setViews(overrideBoxes, in: .top)
        overrideStack.orientation = .vertical
        overrideStack.alignment = .leading
        let colourGroup = box("Colour Style", colours)
        let fontGroup = box("Font Style", stack([fonts, styleBoxes]))
        let right = NSStackView(views: [descriptionLabel, NSStackView(views: [colourGroup, fontGroup]), keywordsRow, overrideStack])
        right.orientation = .vertical
        right.alignment = .leading
        descriptionLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        let body = NSStackView(views: [left, right])
        body.alignment = .top
        body.spacing = 20
        let buttons = NSStackView(views: [cancelButton, saveButton])
        let root = NSStackView(views: [themeRow, body, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        window?.setContentSize(content.fittingSize)
    }

    private func stack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        return s
    }

    private func box(_ title: String, _ content: NSView) -> NSBox {
        let b = NSBox()
        b.title = title
        b.contentView = content
        b.contentViewMargins = NSSize(width: 10, height: 8)
        return b
    }
}

import AppKit

/// upstream's Column Editor (MAC-41): insert a text, or a number sequence, in every line of a
/// column selection (or every selection), or from the caret's line to the end at the caret's column.
struct ColumnEditorSettings: Codable, Equatable {
    enum Mode: String, Codable { case text, number }
    enum Format: String, Codable, CaseIterable { case dec, hex, hexUppercase, oct, bin }
    enum Leading: String, Codable, CaseIterable { case none, zeros, spaces }

    var mode = Mode.number
    var text = ""
    var initial = 0
    var increase = 0
    var repeatCount = 0
    var format = Format.dec
    var leading = Leading.none

    var base: Int {
        switch format {
        case .dec: return 10
        case .hex, .hexUppercase: return 16
        case .oct: return 8
        case .bin: return 2
        }
    }

    private static let key = "ColumnEditor"

    static func load(_ defaults: UserDefaults = AppEnvironment.defaults) -> ColumnEditorSettings {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ColumnEditorSettings.self, from: $0) } ?? ColumnEditorSettings()
    }

    func save(_ defaults: UserDefaults = AppEnvironment.defaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

enum ColumnEditor {
    /// Each value `repeat` times (0 counts as 1), stepping by `increase`, until `count` values.
    static func numbers(count: Int, initial: Int, increase: Int, repeat repeatCount: Int) -> [Int] {
        var values: [Int] = []
        var current = initial
        let times = max(repeatCount, 1)
        while values.count < count {
            for _ in 0..<times where values.count < count { values.append(current) }
            current += increase
        }
        return values
    }

    static func format(_ n: Int, _ format: ColumnEditorSettings.Format) -> String {
        switch format {
        case .dec: return String(n)
        case .hex: return String(n, radix: 16)
        case .hexUppercase: return String(n, radix: 16, uppercase: true)
        case .oct: return String(n, radix: 8)
        case .bin: return String(n, radix: 2)
        }
    }

    /// The strings to insert: every number as wide as the wider of the first and last, padded with
    /// leading zeros or spaces — or, with Leading None, left-aligned with trailing spaces.
    static func numberStrings(count: Int, settings s: ColumnEditorSettings) -> [String] {
        let values = numbers(count: count, initial: s.initial, increase: s.increase, repeat: s.repeatCount)
        guard let last = values.last else { return [] }
        let width = max(format(s.initial, s.format).count, format(last, s.format).count)
        return values.map { value in
            let digits = format(value, s.format)
            let pad = max(width - digits.count, 0)
            switch s.leading {
            case .zeros: return String(repeating: "0", count: pad) + digits
            case .spaces: return String(repeating: " ", count: pad) + digits
            case .none: return digits + String(repeating: " ", count: pad)
            }
        }
    }

    /// The Number fields, read in the chosen base; nil when not a number of that base (an empty
    /// field is 0, as upstream reads it on OK).
    static func parse(_ text: String, base: Int) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return 0 }
        guard let value = Int(trimmed, radix: base), value >= 0 else { return nil }
        return value
    }

    static func invalidMessage(_ text: String, base: Int) -> String {
        let rule: String
        switch base {
        case 16: rule = "Hex numbers use 0-9, A-F!"
        case 8: rule = "Oct numbers only use 0-7!"
        case 2: rule = "Bin numbers only use 0-1!"
        default: rule = "Decimal numbers only use 0-9!"
        }
        return "Entered string \"\(text)\":\n\(rule)"
    }

    /// Runs the editor on `editor` as one undo step.
    static func apply(_ settings: ColumnEditorSettings, to editor: ScintillaView) {
        let rectangular = editor.send(SCI_SELECTIONISRECTANGLE) != 0
        let selections = editor.send(SCI_GETSELECTIONS)
        editor.send(SCI_BEGINUNDOACTION)
        defer { editor.send(SCI_ENDUNDOACTION) }
        if rectangular || selections > 1 {
            replaceSelections(settings, editor: editor)
        } else {
            insertDownwards(settings, editor: editor)
        }
    }

    /// Every selection (each line of a rectangle) is replaced by its string, padding lines that
    /// end before the column; afterwards each selection spans what was inserted.
    private static func replaceSelections(_ settings: ColumnEditorSettings, editor: ScintillaView) {
        let count = editor.send(SCI_GETSELECTIONS)
        guard count > 1 else { return }  // a one-line rectangle: upstream does nothing either
        struct Piece { var index, left, right, anchorV, caretV: Int; var caretFirst: Bool }
        var pieces = (0..<count).map { i -> Piece in
            let anchor = editor.send(SCI_GETSELECTIONNANCHOR, i), caret = editor.send(SCI_GETSELECTIONNCARET, i)
            let av = editor.send(SCI_GETSELECTIONNANCHORVIRTUALSPACE, i), cv = editor.send(SCI_GETSELECTIONNCARETVIRTUALSPACE, i)
            let caretFirst = anchor == caret ? cv < av : caret < anchor
            return Piece(index: i, left: min(anchor, caret), right: max(anchor, caret), anchorV: av, caretV: cv, caretFirst: caretFirst)
        }.sorted { $0.left < $1.left }
        let strings = settings.mode == .text ? Array(repeating: settings.text, count: count)
            : numberStrings(count: count, settings: settings)
        var offset = 0
        var results = [(index: Int, start: Int, end: Int, caretFirst: Bool)]()
        for (n, piece) in pieces.enumerated() {
            var left = piece.left + offset, right = piece.right + offset
            let va = min(piece.anchorV, piece.caretV), vc = max(piece.anchorV, piece.caretV)
            if va > 0 {
                editor.send(SCI_INSERTTEXT, left, string: String(repeating: " ", count: vc))
                left += va
                right += vc
                offset += vc
            }
            let bytes = Array(strings[n].utf8)
            editor.send(SCI_SETTARGETRANGE, left, right)
            editor.replaceTarget(bytes)
            offset += bytes.count - (right - left)
            results.append((piece.index, left, left + bytes.count, piece.caretFirst))
        }
        pieces.removeAll()
        results.sort { $0.index < $1.index }
        editor.send(SCI_SETSELECTIONMODE, Int(SC_SEL_STREAM))
        for (i, r) in results.enumerated() {
            let (caret, anchor) = r.caretFirst ? (r.start, r.end) : (r.end, r.start)
            if i == 0 { editor.send(SCI_SETSELECTION, caret, anchor) } else { editor.send(SCI_ADDSELECTION, caret, anchor) }
        }
    }

    /// From the caret's line to the last, the string goes in at the caret's column; a shorter line
    /// is padded with spaces up to it.
    private static func insertDownwards(_ settings: ColumnEditorSettings, editor: ScintillaView) {
        let caret = editor.send(SCI_GETCURRENTPOS)
        let column = editor.send(SCI_GETCOLUMN, caret)
        let firstLine = editor.send(SCI_LINEFROMPOSITION, caret)
        let lastLine = editor.send(SCI_GETLINECOUNT) - 1
        let count = lastLine - firstLine + 1
        let strings = settings.mode == .text ? Array(repeating: settings.text, count: count)
            : numberStrings(count: count, settings: settings)
        for (n, line) in (firstLine...lastLine).enumerated() {
            let lineStart = editor.send(SCI_POSITIONFROMLINE, line)
            let lineEnd = editor.send(SCI_GETLINEENDPOSITION, line)
            let endColumn = editor.send(SCI_GETCOLUMN, lineEnd)
            if endColumn < column {
                editor.send(SCI_INSERTTEXT, lineEnd, string: String(repeating: " ", count: column - endColumn) + strings[n])
            } else {
                editor.send(SCI_INSERTTEXT, min(max(editor.send(SCI_FINDCOLUMN, line, column), lineStart), lineEnd), string: strings[n])
            }
        }
    }

    static let columnModeTip = """
        There are 3 ways to switch to column-select mode:

        1. (Keyboard and Mouse)  Hold Option while left-click dragging

        2. (Keyboard only)  Hold Option+Shift while using arrow keys

        3. (Keyboard or Mouse)
              Put caret at desired start of column block position, then
               execute "Begin/End Select in Column Mode" command;
              Move caret to desired end of column block position, then
               execute "Begin/End Select in Column Mode" command again
        """
}

/// The Column Editor dialog.
final class ColumnEditorController: NSWindowController, NSTextFieldDelegate {
    var editorProvider: () -> ScintillaView?
    private let defaults: UserDefaults
    private(set) var settings: ColumnEditorSettings

    let textRadio = NSButton(radioButtonWithTitle: "Text to Insert", target: nil, action: nil)
    let numberRadio = NSButton(radioButtonWithTitle: "Number to Insert", target: nil, action: nil)
    let textField = NSTextField()
    let initialField = NSTextField()
    let increaseField = NSTextField()
    let repeatField = NSTextField()
    let leadingPopup = NSPopUpButton()
    let formatRadios = ["Dec", "Hex", "Oct", "Bin"].map { NSButton(radioButtonWithTitle: $0, target: nil, action: nil) }
    let hexCasePopup = NSPopUpButton()
    let okButton = NSButton(title: "OK", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let errorLabel = NSTextField(labelWithString: "")

    init(defaults: UserDefaults = AppEnvironment.defaults, editorProvider: @escaping () -> ScintillaView?) {
        self.defaults = defaults
        self.editorProvider = editorProvider
        settings = ColumnEditorSettings.load(defaults)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = "Column Editor"
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        build()
        load()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        load()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeFirstResponder(settings.mode == .text ? textField : initialField)
    }

    private func load() {
        textRadio.state = settings.mode == .text ? .on : .off
        numberRadio.state = settings.mode == .number ? .on : .off
        textField.stringValue = settings.text
        let base = settings.base
        initialField.stringValue = String(settings.initial, radix: base, uppercase: settings.format == .hexUppercase)
        increaseField.stringValue = String(settings.increase, radix: base, uppercase: settings.format == .hexUppercase)
        repeatField.stringValue = String(settings.repeatCount, radix: base, uppercase: settings.format == .hexUppercase)
        leadingPopup.selectItem(at: ColumnEditorSettings.Leading.allCases.firstIndex(of: settings.leading) ?? 0)
        let formatIndex: Int
        switch settings.format {
        case .dec: formatIndex = 0
        case .hex, .hexUppercase: formatIndex = 1
        case .oct: formatIndex = 2
        case .bin: formatIndex = 3
        }
        for (i, radio) in formatRadios.enumerated() { radio.state = i == formatIndex ? .on : .off }
        hexCasePopup.selectItem(at: settings.format == .hexUppercase ? 1 : 0)
        updateEnabling()
    }

    private func updateEnabling() {
        let number = settings.mode == .number
        textField.isEnabled = !number
        for control in [initialField, increaseField, repeatField, leadingPopup] as [NSControl] { control.isEnabled = number }
        formatRadios.forEach { $0.isEnabled = number }
        hexCasePopup.isEnabled = number && (settings.format == .hex || settings.format == .hexUppercase)
        okButton.isEnabled = number || !textField.stringValue.isEmpty
    }

    /// Reads the controls; false (with upstream's message) when a number field is not valid.
    @discardableResult
    func readControls() -> Bool {
        settings.mode = textRadio.state == .on ? .text : .number
        settings.text = textField.stringValue
        settings.leading = ColumnEditorSettings.Leading.allCases[max(leadingPopup.indexOfSelectedItem, 0)]
        let base = settings.base
        var values: [Int] = []
        for field in [initialField, increaseField, repeatField] {
            guard let value = ColumnEditor.parse(field.stringValue, base: base) else {
                errorLabel.stringValue = ColumnEditor.invalidMessage(field.stringValue, base: base)
                errorLabel.isHidden = false
                return false
            }
            values.append(value)
        }
        (settings.initial, settings.increase, settings.repeatCount) = (values[0], values[1], values[2])
        errorLabel.isHidden = true
        settings.save(defaults)
        updateEnabling()
        return true
    }

    /// OK: the editor is applied to the current document, the dialog goes away.
    func confirm() {
        guard readControls(), let editor = editorProvider() else { return }
        if settings.mode == .text && settings.text.isEmpty { return }
        window?.orderOut(nil)
        ColumnEditor.apply(settings, to: editor)
        editor.window?.makeFirstResponder(editor)
    }

    @objc private func modeChanged(_ sender: NSButton) {
        textRadio.state = sender === textRadio ? .on : .off
        numberRadio.state = sender === numberRadio ? .on : .off
        readControls()
    }

    /// A new format rewrites the three numbers in the new base.
    @objc private func formatChanged(_ sender: Any?) {
        guard readControls() else { return }
        let index = formatRadios.firstIndex { $0.state == .on || $0 === sender as AnyObject } ?? 0
        formatRadios.enumerated().forEach { $0.element.state = $0.offset == index ? .on : .off }
        let formats: [ColumnEditorSettings.Format] = [.dec, hexCasePopup.indexOfSelectedItem == 1 ? .hexUppercase : .hex, .oct, .bin]
        settings.format = formats[index]
        settings.save(defaults)
        load()
    }

    @objc private func controlChanged(_ sender: Any?) { readControls() }
    @objc private func okClicked(_ sender: Any?) { confirm() }
    @objc private func cancelClicked(_ sender: Any?) { window?.orderOut(nil) }

    func controlTextDidChange(_ obj: Notification) { updateEnablingFromText() }
    private func updateEnablingFromText() {
        okButton.isEnabled = numberRadio.state == .on || !textField.stringValue.isEmpty
    }

    private func build() {
        guard let content = window?.contentView else { return }
        for radio in [textRadio, numberRadio] { radio.target = self; radio.action = #selector(modeChanged(_:)) }
        for radio in formatRadios { radio.target = self; radio.action = #selector(formatChanged(_:)) }
        hexCasePopup.addItems(withTitles: ["a-f", "A-F"])
        hexCasePopup.target = self
        hexCasePopup.action = #selector(formatChanged(_:))
        leadingPopup.addItems(withTitles: ["None", "Zeros", "Spaces"])
        leadingPopup.target = self
        leadingPopup.action = #selector(controlChanged(_:))
        textField.delegate = self
        for field in [textField, initialField, increaseField, repeatField] {
            field.target = self
            field.action = #selector(controlChanged(_:))
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        }
        okButton.target = self
        okButton.action = #selector(okClicked(_:))
        okButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.maximumNumberOfLines = 2

        let numbers = NSGridView(views: [
            [NSTextField(labelWithString: "Initial number:"), initialField],
            [NSTextField(labelWithString: "Increase by:"), increaseField],
            [NSTextField(labelWithString: "Repeat:"), repeatField],
            [NSTextField(labelWithString: "Leading:"), leadingPopup],
        ])
        numbers.column(at: 0).xPlacement = .trailing
        numbers.rowAlignment = .firstBaseline
        let formats = NSStackView(views: formatRadios + [hexCasePopup])
        formats.spacing = 10
        let formatBox = NSBox()
        formatBox.title = "Format"
        formatBox.contentView = formats
        let buttons = NSStackView(views: [cancelButton, okButton])
        let root = NSStackView(views: [textRadio, textField, numberRadio, numbers, formatBox, errorLabel, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
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
}

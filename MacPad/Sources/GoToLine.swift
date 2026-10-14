import AppKit

/// Notepad++'s Go To dialog (GoToLineDlg, MAC-34): to a line (1-based) or to a byte offset
/// (0-based), clamped by Scintilla, unfolding the target.
enum GoTo {
    enum Mode: Equatable { case line, offset }

    /// "You are here:" — the caret's line (1-based) or byte position.
    static func current(_ editor: ScintillaView, mode: Mode) -> Int {
        let pos = editor.send(SCI_GETCURRENTPOS)
        return mode == .line ? editor.send(SCI_LINEFROMPOSITION, pos) + 1 : pos
    }

    /// "You can't go further than:" — the line count, or the last byte offset.
    static func maximum(_ editor: ScintillaView, mode: Mode) -> Int {
        mode == .line ? editor.send(SCI_GETLINECOUNT) : max(editor.send(SCI_GETLENGTH) - 1, 0)
    }

    /// The number typed: nil when empty (nothing happens); other text reads as Notepad++'s
    /// strtoll does — the leading digits, else 0.
    static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed.prefix { $0.isASCII && $0.isNumber }) ?? 0
    }

    /// Line: the caret goes to column 0 of that line. Offset: to that byte, moved out of a
    /// multi-byte character or a CR/LF pair; past the end means the end.
    static func go(_ editor: ScintillaView, mode: Mode, to value: Int) {
        switch mode {
        case .line:
            let line = max(value - 1, 0)
            editor.send(SCI_ENSUREVISIBLE, line)
            editor.send(SCI_GOTOLINE, line)
        case .offset:
            let pos = value > 0 ? editor.send(SCI_POSITIONAFTER, editor.send(SCI_POSITIONBEFORE, value)) : 0
            editor.send(SCI_ENSUREVISIBLE, editor.send(SCI_LINEFROMPOSITION, pos))
            editor.send(SCI_GOTOPOS, pos)
        }
    }
}

final class GoToLineController: NSWindowController, NSWindowDelegate {
    var editorProvider: () -> ScintillaView?
    /// Kept for the session, as Notepad++ keeps its dialog's mode.
    private(set) var mode: GoTo.Mode = .line

    let lineRadio = NSButton(radioButtonWithTitle: "Line", target: nil, action: nil)
    let offsetRadio = NSButton(radioButtonWithTitle: "Offset", target: nil, action: nil)
    let currentLabel = NSTextField(labelWithString: "")
    let targetField = NSTextField()
    let maximumLabel = NSTextField(labelWithString: "")
    let goButton = NSButton(title: "Go", target: nil, action: nil)
    let cancelButton = NSButton(title: "I'm going nowhere", target: nil, action: nil)

    init(editorProvider: @escaping () -> ScintillaView?) {
        self.editorProvider = editorProvider
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = "Go To..."
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        build()
        setMode(.line)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        refresh()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeFirstResponder(targetField)
    }

    func setMode(_ newMode: GoTo.Mode) {
        mode = newMode
        lineRadio.state = newMode == .line ? .on : .off
        offsetRadio.state = newMode == .offset ? .on : .off
        refresh()
    }

    /// The caret's place and the limit, for the current mode.
    func refresh() {
        guard let editor = editorProvider() else { return }
        currentLabel.stringValue = String(GoTo.current(editor, mode: mode))
        maximumLabel.stringValue = String(GoTo.maximum(editor, mode: mode))
    }

    /// Go: an empty field moves nothing but hands the editor its focus back; otherwise the dialog
    /// hides (clearing the field) and the caret moves.
    func go() {
        guard let editor = editorProvider() else { return }
        guard let value = GoTo.parse(targetField.stringValue) else {
            editor.window?.makeFirstResponder(editor)
            return
        }
        dismiss()
        GoTo.go(editor, mode: mode, to: value)
        editor.window?.makeKeyAndOrderFront(nil)
        editor.window?.makeFirstResponder(editor)
    }

    func dismiss() {
        targetField.stringValue = ""
        window?.orderOut(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }
    func windowWillClose(_ notification: Notification) { targetField.stringValue = "" }

    @objc private func modeChanged(_ sender: NSButton) { setMode(sender === offsetRadio ? .offset : .line) }
    @objc private func goClicked(_ sender: Any?) { go() }
    @objc private func cancelClicked(_ sender: Any?) { dismiss() }

    private func build() {
        guard let content = window?.contentView else { return }
        for radio in [lineRadio, offsetRadio] {
            radio.target = self
            radio.action = #selector(modeChanged(_:))
        }
        goButton.target = self
        goButton.action = #selector(goClicked(_:))
        goButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        let digits = NumberFormatter()
        digits.allowsFloats = false
        digits.minimum = 0
        digits.usesGroupingSeparator = false
        targetField.formatter = digits  // Notepad++'s ES_NUMBER: digits only
        targetField.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let radios = NSStackView(views: [lineRadio, offsetRadio])
        radios.spacing = 16
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "You are here:"), currentLabel],
            [NSTextField(labelWithString: "You want to go to:"), targetField],
            [NSTextField(labelWithString: "You can't go further than:"), maximumLabel],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        let buttons = NSStackView(views: [cancelButton, goButton])
        buttons.spacing = 8
        let root = NSStackView(views: [radios, grid, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        window?.setContentSize(content.fittingSize)
    }
}

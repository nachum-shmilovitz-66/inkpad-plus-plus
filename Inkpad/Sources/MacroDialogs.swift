import AppKit

/// Shortcuts as upstream's Shortcut dialog edits them (MAC-42/43): a key plus modifiers.
enum ShortcutRules {
    /// upstream's isValid: a letter, digit, space or Return needs ⌘ or ⌃ (Ctrl / Alt there);
    /// otherwise typing it would run the command.
    static func isValid(key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let ch = key.lowercased().first else { return true }  // no key: the shortcut is off
        let needsModifier = ch.isLetter || ch.isNumber || ch == " " || ch == "\r"
        return !needsModifier || modifiers.contains(.command) || modifiers.contains(.control)
    }

    static func describe(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        guard !key.isEmpty else { return "" }
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let names: [String: String] = ["\r": "↩", " ": "Space", "\t": "⇥", "\u{1b}": "⎋"]
        if let scalar = key.unicodeScalars.first, (0xF700...0xF8FF).contains(scalar.value) {
            let f = Int(scalar.value) - NSF1FunctionKey + 1
            if (1...35).contains(f) { return s + "F\(f)" }
            let arrows: [Int: String] = [NSUpArrowFunctionKey: "↑", NSDownArrowFunctionKey: "↓",
                                         NSLeftArrowFunctionKey: "←", NSRightArrowFunctionKey: "→"]
            return s + (arrows[Int(scalar.value)] ?? "?")
        }
        return s + (names[key] ?? key.uppercased())
    }

    /// The menu item (title path) already using a shortcut, for upstream's "CONFLICT FOUND!".
    static func conflict(key: String, modifiers: NSEvent.ModifierFlags, in menu: NSMenu?, ignoring: NSMenuItem? = nil) -> String? {
        guard !key.isEmpty, let menu else { return nil }
        let mask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        for item in menu.items {
            if let sub = item.submenu, let found = conflict(key: key, modifiers: modifiers, in: sub, ignoring: ignoring) {
                return "\(item.title) › \(found)"
            }
            if item !== ignoring, item.keyEquivalent.lowercased() == key.lowercased(),
               item.keyEquivalentModifierMask.intersection(mask) == modifiers.intersection(mask) {
                return item.title
            }
        }
        return nil
    }
}

/// upstream's "Shortcut" dialog, used to save a macro: a name and an optional shortcut.
final class ShortcutDialog: NSWindowController {
    let nameField = NSTextField()
    let commandBox = NSButton(checkboxWithTitle: "⌘", target: nil, action: nil)
    let controlBox = NSButton(checkboxWithTitle: "⌃", target: nil, action: nil)
    let optionBox = NSButton(checkboxWithTitle: "⌥", target: nil, action: nil)
    let shiftBox = NSButton(checkboxWithTitle: "⇧", target: nil, action: nil)
    let keyField = NSTextField()
    let warningLabel = NSTextField(labelWithString: "")
    let okButton = NSButton(title: "OK", target: nil, action: nil)
    private var completion: ((String, String, NSEvent.ModifierFlags)?) -> Void = { _ in }

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160), styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = "Shortcut"
        super.init(window: panel)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var modifiers: NSEvent.ModifierFlags {
        var m: NSEvent.ModifierFlags = []
        if commandBox.state == .on { m.insert(.command) }
        if controlBox.state == .on { m.insert(.control) }
        if optionBox.state == .on { m.insert(.option) }
        if shiftBox.state == .on { m.insert(.shift) }
        return m
    }

    var key: String { String(keyField.stringValue.lowercased().prefix(1)) }

    /// OK needs a name and a valid shortcut; a conflict is only a warning, as in upstream.
    func validate() {
        let valid = ShortcutRules.isValid(key: key, modifiers: modifiers)
        okButton.isEnabled = valid && !nameField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        if key.isEmpty {
            warningLabel.stringValue = "No shortcut"
        } else if let other = ShortcutRules.conflict(key: key, modifiers: modifiers, in: NSApp.mainMenu) {
            warningLabel.stringValue = "CONFLICT FOUND! (\(other))"
        } else {
            warningLabel.stringValue = valid ? "" : "Add ⌘ or ⌃ to a letter, digit or space"
        }
    }

    func run(in window: NSWindow?, completion: @escaping ((String, String, NSEvent.ModifierFlags)?) -> Void) {
        self.completion = completion
        nameField.stringValue = ""
        keyField.stringValue = ""
        [commandBox, controlBox, optionBox, shiftBox].forEach { $0.state = .off }
        commandBox.state = .on
        validate()
        if let window, let sheet = self.window { window.beginSheet(sheet) } else { showWindow(nil) }
    }

    func finish(ok: Bool) {
        if let sheet = window, let parent = sheet.sheetParent { parent.endSheet(sheet) } else { window?.orderOut(nil) }
        completion(ok ? (nameField.stringValue.trimmingCharacters(in: .whitespaces), key, key.isEmpty ? [] : modifiers) : nil)
    }

    @objc private func changed(_ sender: Any?) { validate() }
    @objc private func okClicked(_ sender: Any?) { finish(ok: true) }
    @objc private func cancelClicked(_ sender: Any?) { finish(ok: false) }

    private func build() {
        guard let content = window?.contentView else { return }
        for box in [commandBox, controlBox, optionBox, shiftBox] { box.target = self; box.action = #selector(changed(_:)) }
        for field in [nameField, keyField] { field.target = self; field.action = #selector(changed(_:)) }
        NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, note.object as? NSTextField === self.nameField || note.object as? NSTextField === self.keyField else { return }
            self.validate()
        }
        keyField.placeholderString = "key"
        keyField.widthAnchor.constraint(equalToConstant: 50).isActive = true
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        warningLabel.textColor = .systemOrange
        okButton.target = self
        okButton.action = #selector(okClicked(_:))
        okButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let keys = NSStackView(views: [commandBox, controlBox, optionBox, shiftBox, NSTextField(labelWithString: "+"), keyField])
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Name:"), nameField], [NSTextField(labelWithString: "Shortcut:"), keys]])
        grid.rowAlignment = .firstBaseline
        let root = NSStackView(views: [grid, warningLabel, NSStackView(views: [cancel, okButton])])
        root.orientation = .vertical
        root.alignment = .trailing
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window?.setContentSize(content.fittingSize)
    }
}

/// upstream's "Run a Macro Multiple Times" dialog.
final class RunMacroController: NSWindowController {
    static let currentRecordedTitle = "Current recorded macro"
    let macroPopup = NSPopUpButton()
    let timesRadio = NSButton(radioButtonWithTitle: "Run", target: nil, action: nil)
    let timesField = NSTextField()
    let untilEndRadio = NSButton(radioButtonWithTitle: "Run until the end of file", target: nil, action: nil)
    let runButton = NSButton(title: "Run", target: nil, action: nil)
    /// Runs: the macro's steps (nil = the current recording) and the count (nil = until the end).
    var onRun: (_ savedIndex: Int?, _ times: Int?) -> Void = { _, _ in }

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 180), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        panel.title = "Run a Macro Multiple Times"
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// "Current recorded macro" first when there is a finished recording, then the saved macros.
    func reload(hasRecording: Bool, saved: [String]) {
        macroPopup.removeAllItems()
        if hasRecording { macroPopup.addItem(withTitle: Self.currentRecordedTitle) }
        macroPopup.addItems(withTitles: saved)
        runButton.isEnabled = macroPopup.numberOfItems > 0
    }

    func show() {
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
    }

    func run() {
        guard macroPopup.numberOfItems > 0 else { return }
        var index = macroPopup.indexOfSelectedItem
        let savedIndex: Int?
        if macroPopup.itemTitle(at: 0) == Self.currentRecordedTitle {
            savedIndex = index == 0 ? nil : index - 1
        } else {
            savedIndex = index
        }
        index = max(timesField.integerValue, 1)
        timesField.integerValue = index
        onRun(savedIndex, untilEndRadio.state == .on ? nil : index)
    }

    @objc private func modeChanged(_ sender: NSButton) {
        timesRadio.state = sender === timesRadio ? .on : .off
        untilEndRadio.state = sender === untilEndRadio ? .on : .off
        timesField.isEnabled = timesRadio.state == .on
    }
    @objc private func runClicked(_ sender: Any?) { run() }
    @objc private func cancelClicked(_ sender: Any?) { window?.orderOut(nil) }

    private func build() {
        guard let content = window?.contentView else { return }
        timesRadio.state = .on
        for radio in [timesRadio, untilEndRadio] { radio.target = self; radio.action = #selector(modeChanged(_:)) }
        timesField.integerValue = 1
        timesField.formatter = { let f = NumberFormatter(); f.minimum = 1; f.maximum = 9999; f.allowsFloats = false; return f }()
        timesField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        runButton.target = self
        runButton.action = #selector(runClicked(_:))
        runButton.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let box = NSBox()
        box.title = "Macro to run"
        box.contentView = macroPopup
        let timesRow = NSStackView(views: [timesRadio, timesField, NSTextField(labelWithString: "times")])
        let root = NSStackView(views: [box, timesRow, untilEndRadio, NSStackView(views: [cancel, runButton])])
        root.orientation = .vertical
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            box.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
        window?.setContentSize(content.fittingSize)
    }
}

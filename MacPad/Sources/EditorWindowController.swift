import AppKit

/// One editor window holding one document. Milestone 2 replaces this with Notepad++'s
/// single window + tab bar; the buffer/file logic here carries over.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation,
    ScintillaNotificationProtocol {
    let editor: ScintillaView
    private let statusBar = StatusBar()

    private(set) var fileURL: URL?
    private var untitledNumber: Int
    private(set) var encoding: TextEncoding = .utf8
    private(set) var language: LanguageInfo = LanguageCatalog.shared.plainText

    var isModified: Bool { editor.send(SCI_GETMODIFY) != 0 }
    /// An untouched "new N" window, which Notepad++ reuses when a file is opened.
    var isPristineUntitled: Bool { fileURL == nil && !isModified && editor.send(SCI_GETLENGTH) == 0 }
    var displayName: String { fileURL?.lastPathComponent ?? "new \(untitledNumber)" }

    init(untitledNumber: Int) {
        self.untitledNumber = untitledNumber
        editor = ScintillaView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 662),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.setFrameAutosaveName("MacPad++ Editor")
        window.tabbingMode = .disallowed  // Notepad++-style tabs come with milestone 2
        super.init(window: window)

        let content = NSView()
        editor.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(editor)
        content.addSubview(statusBar)
        NSLayoutConstraint.activate([
            editor.topAnchor.constraint(equalTo: content.topAnchor),
            editor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.delegate = self
        window.initialFirstResponder = editor.content()

        editor.delegate = self
        EditorStyler.configureEditor(editor)
        editor.send(SCI_SETEOLMODE, LineEnding.lf.rawValue)  // new documents: Unix line endings on macOS
        applyLanguage(LanguageCatalog.shared.plainText)
        updateTitle()
        updateStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Loading and saving

    func load(_ url: URL) throws {
        let loaded = TextFile.decode(try Data(contentsOf: url))
        editor.setUTF8Bytes(loaded.utf8)
        if let eol = loaded.lineEnding { editor.send(SCI_SETEOLMODE, eol.rawValue) }
        editor.send(SCI_EMPTYUNDOBUFFER)
        editor.send(SCI_SETSAVEPOINT)
        editor.send(SCI_GOTOPOS, 0)
        fileURL = url
        encoding = loaded.encoding
        applyLanguage(LanguageCatalog.shared.language(for: url))
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        updateTitle()
        updateStatus()
    }

    private func write(to url: URL) -> Bool {
        do {
            try TextFile.encode(editor.utf8Bytes(), as: encoding).write(to: url, options: .atomic)
        } catch {
            presentError(error, modalFor: window!, delegate: nil, didPresent: nil, contextInfo: nil)
            return false
        }
        let languageChanged = fileURL?.pathExtension != url.pathExtension
        fileURL = url
        editor.send(SCI_SETSAVEPOINT)
        if languageChanged { applyLanguage(LanguageCatalog.shared.language(for: url)) }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        updateTitle()
        updateStatus()
        return true
    }

    /// Saves, asking for a location if the document is untitled. Calls back with success.
    func save(completion: ((Bool) -> Void)? = nil) {
        if let url = fileURL {
            completion?(write(to: url))
        } else {
            saveAs(completion: completion)
        }
    }

    func saveAs(completion: ((Bool) -> Void)? = nil) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? displayName
        if let dir = fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { completion?(false); return }
            completion?(self.write(to: url))
        }
    }

    @IBAction func saveDocument(_ sender: Any?) { save() }
    @IBAction func saveDocumentAs(_ sender: Any?) { saveAs() }

    // MARK: - View menu

    @IBAction func toggleWordWrap(_ sender: Any?) {
        editor.send(SCI_SETWRAPMODE, editor.send(SCI_GETWRAPMODE) == Int(SC_WRAP_NONE) ? Int(SC_WRAP_WORD) : Int(SC_WRAP_NONE))
    }

    @IBAction func toggleShowAllCharacters(_ sender: Any?) {
        let on = editor.send(SCI_GETVIEWWS) == Int(SCWS_INVISIBLE)
        editor.send(SCI_SETVIEWWS, on ? Int(SCWS_VISIBLEALWAYS) : Int(SCWS_INVISIBLE))
        editor.send(SCI_SETVIEWEOL, on ? 1 : 0)
    }

    @IBAction func zoomInText(_ sender: Any?) { editor.send(SCI_ZOOMIN) }
    @IBAction func zoomOutText(_ sender: Any?) { editor.send(SCI_ZOOMOUT) }
    @IBAction func restoreTextZoom(_ sender: Any?) { editor.send(SCI_SETZOOM, 0) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleWordWrap(_:)):
            item.state = editor.send(SCI_GETWRAPMODE) != Int(SC_WRAP_NONE) ? .on : .off
        case #selector(toggleShowAllCharacters(_:)):
            item.state = editor.send(SCI_GETVIEWWS) != Int(SCWS_INVISIBLE) ? .on : .off
        default:
            break
        }
        return true
    }

    // MARK: - Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isModified else { return true }
        confirmDiscard { [weak self] ok in if ok { self?.window?.close() } }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        editor.delegate = nil
        AppDelegate.shared.editorDidClose(self)
    }

    /// Notepad++'s "Save file?" prompt. Calls back with true when it is safe to discard the window.
    func confirmDiscard(completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Save file \"\(displayName)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.beginSheetModal(for: window!) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.save(completion: completion)
            case .alertThirdButtonReturn: completion(true)
            default: completion(false)
            }
        }
    }

    // MARK: - Scintilla notifications

    func notification(_ notification: UnsafeMutablePointer<SCNotification>!) {
        let n = notification.pointee
        switch Int32(n.nmhdr.code) {
        case SCN_SAVEPOINTLEFT, SCN_SAVEPOINTREACHED:
            updateTitle()
        case SCN_UPDATEUI:
            EditorStyler.updateBraceMatch(editor)
            updateStatus()
        case SCN_MODIFIED:
            if n.linesAdded != 0 { EditorStyler.updateLineNumberWidth(editor) }
        default:
            break
        }
    }

    // MARK: - Presentation

    private func applyLanguage(_ info: LanguageInfo) {
        language = info
        EditorStyler.apply(language: info, theme: StyleTheme.default, to: editor)
    }

    private func updateTitle() {
        guard let window else { return }
        window.title = displayName
        window.representedURL = fileURL
        window.isDocumentEdited = isModified
    }

    private func updateStatus() {
        let pos = editor.send(SCI_GETCURRENTPOS)
        let line = editor.send(SCI_LINEFROMPOSITION, pos)
        let eol = LineEnding(rawValue: editor.send(SCI_GETEOLMODE)) ?? .lf
        statusBar.update(
            language: language.longName,
            length: editor.send(SCI_GETLENGTH), lines: editor.send(SCI_GETLINECOUNT),
            line: line + 1, column: editor.send(SCI_GETCOLUMN, pos) + 1, position: pos + 1,
            lineEnding: eol.statusName, encoding: encoding.statusName,
            overtype: editor.send(SCI_GETOVERTYPE) != 0)
    }
}

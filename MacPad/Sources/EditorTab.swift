import AppKit

/// One open document: its Scintilla view, its file, and the encoding/language chosen for it.
/// The window that hosts it owns the tab bar and the status bar; this type owns the buffer.
final class EditorTab: NSObject, ScintillaNotificationProtocol {
    let editor: ScintillaView

    private(set) var fileURL: URL?
    private let untitledNumber: Int
    private(set) var encoding: TextEncoding = .utf8
    private(set) var language: LanguageInfo = LanguageCatalog.shared.plainText

    /// Called when the title, the dirty state or the caret changes, so the host can refresh the
    /// tab bar, the window title and the status bar.
    var onChange: (() -> Void)?
    /// The window to present sheets in. Set by the host controller.
    weak var hostWindow: NSWindow?

    var isModified: Bool { editor.send(SCI_GETMODIFY) != 0 }
    /// An untouched "new N" document, which Notepad++ reuses when a file is opened.
    var isPristineUntitled: Bool { fileURL == nil && !isModified && editor.send(SCI_GETLENGTH) == 0 }
    var displayName: String { TabTitle.displayName(url: fileURL, untitledNumber: untitledNumber) }
    var tabLabel: String { TabTitle.tabLabel(displayName: displayName, isModified: isModified) }

    init(untitledNumber: Int) {
        self.untitledNumber = untitledNumber
        editor = ScintillaView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        super.init()
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.delegate = self
        EditorStyler.configureEditor(editor)
        editor.send(SCI_SETEOLMODE, LineEnding.lf.rawValue)  // new documents: Unix line endings on macOS
        applyLanguage(LanguageCatalog.shared.plainText)
    }

    func detach() {
        editor.delegate = nil
        onChange = nil
        hostWindow = nil
    }

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
        RecentFilesStore.shared.record(url)
        onChange?()
    }

    private func write(to url: URL) -> Bool {
        do {
            try TextFile.encode(editor.utf8Bytes(), as: encoding).write(to: url, options: .atomic)
        } catch {
            if let hostWindow {
                NSApp.presentError(error, modalFor: hostWindow, delegate: nil, didPresent: nil, contextInfo: nil)
            } else {
                NSApp.presentError(error)
            }
            return false
        }
        let languageChanged = fileURL?.pathExtension != url.pathExtension
        fileURL = url
        editor.send(SCI_SETSAVEPOINT)
        if languageChanged { applyLanguage(LanguageCatalog.shared.language(for: url)) }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        RecentFilesStore.shared.record(url)
        onChange?()
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
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { completion?(false); return }
            completion?(self.write(to: url))
        }
        if let hostWindow {
            panel.beginSheetModal(for: hostWindow, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// Notepad++'s "Save file?" prompt. Calls back with true when it is safe to discard the tab.
    func confirmDiscard(completion: @escaping (Bool) -> Void) {
        guard isModified else { completion(true); return }
        let alert = NSAlert()
        alert.messageText = "Save file \"\(displayName)\"?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.save(completion: completion)
            case .alertThirdButtonReturn: completion(true)
            default: completion(false)
            }
        }
        if let hostWindow {
            alert.beginSheetModal(for: hostWindow, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    // MARK: - Editor state

    /// Where the caret and the viewport are, for session restore.
    var caretPosition: Int { editor.send(SCI_GETCURRENTPOS) }
    var firstVisibleLine: Int { editor.send(SCI_GETFIRSTVISIBLELINE) }

    /// Puts the caret and scroll position back. Both are clamped: the file may have been edited
    /// elsewhere since the session was written, and Scintilla would otherwise be asked for a
    /// position the document no longer has.
    func restoreViewport(caretPosition: Int, firstVisibleLine: Int) {
        editor.send(SCI_GOTOPOS, min(max(caretPosition, 0), editor.send(SCI_GETLENGTH)))
        editor.send(SCI_SETFIRSTVISIBLELINE, min(max(firstVisibleLine, 0), max(editor.send(SCI_GETLINECOUNT) - 1, 0)))
    }

    func status() -> StatusBarState {
        let pos = editor.send(SCI_GETCURRENTPOS)
        return StatusBarState(
            language: language.longName,
            length: editor.send(SCI_GETLENGTH),
            lines: editor.send(SCI_GETLINECOUNT),
            line: editor.send(SCI_LINEFROMPOSITION, pos) + 1,
            column: editor.send(SCI_GETCOLUMN, pos) + 1,
            position: pos + 1,
            lineEnding: (LineEnding(rawValue: editor.send(SCI_GETEOLMODE)) ?? .lf).statusName,
            encoding: encoding.statusName,
            overtype: editor.send(SCI_GETOVERTYPE) != 0)
    }

    private func applyLanguage(_ info: LanguageInfo) {
        language = info
        EditorStyler.apply(language: info, theme: StyleTheme.default, to: editor)
    }

    // MARK: - Scintilla notifications

    func notification(_ notification: UnsafeMutablePointer<SCNotification>!) {
        let n = notification.pointee
        switch Int32(n.nmhdr.code) {
        case SCN_SAVEPOINTLEFT, SCN_SAVEPOINTREACHED:
            onChange?()
        case SCN_UPDATEUI:
            EditorStyler.updateBraceMatch(editor)
            onChange?()
        case SCN_MODIFIED:
            if n.linesAdded != 0 { EditorStyler.updateLineNumberWidth(editor) }
        default:
            break
        }
    }
}

/// What the status bar shows for the active document.
struct StatusBarState {
    let language: String
    let length: Int
    let lines: Int
    let line: Int
    let column: Int
    let position: Int
    let lineEnding: String
    let encoding: String
    let overtype: Bool
}

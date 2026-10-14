import AppKit

/// One open document: its Scintilla view, its file, and the encoding/language chosen for it.
/// The window that hosts it owns the tab bar and the status bar; this type owns the buffer.
final class EditorTab: NSObject, ScintillaNotificationProtocol {
    let editor: ScintillaView

    private(set) var fileURL: URL?
    private let untitledNumber: Int
    /// Target encoding vs. the one on disk; see FileFormat.
    private(set) var format = FileFormat(encoding: .utf8)
    var encoding: TextEncoding { format.encoding }
    /// Scintilla's EOL mode: what Enter inserts, and what the status bar shows.
    var lineEnding: LineEnding { LineEnding(rawValue: editor.send(SCI_GETEOLMODE)) ?? .lf }
    private(set) var language: LanguageInfo = LanguageCatalog.shared.plainText
    /// Chosen from the Language menu (or the session): saving under a new name keeps it.
    private(set) var isLanguageChosenByUser = false

    /// Called when the title, the dirty state or the caret changes, so the host can refresh the
    /// tab bar, the window title and the status bar.
    var onChange: (() -> Void)?
    /// The window to present sheets in. Set by the host controller.
    weak var hostWindow: NSWindow?

    /// Edited since the last save, or converted to another encoding (which leaves the buffer as is).
    var isModified: Bool { editor.send(SCI_GETMODIFY) != 0 || format.isEncodingChanged || isMissingOnDisk }
    /// An untouched "new N" document, which Notepad++ reuses when a file is opened.
    var isPristineUntitled: Bool { fileURL == nil && !isModified && editor.send(SCI_GETLENGTH) == 0 }
    var displayName: String { TabTitle.displayName(url: fileURL, untitledNumber: untitledNumber) }
    var tabLabel: String {
        TabTitle.tabLabel(displayName: displayName, isModified: isModified, isMonitoring: isMonitoring,
                          isReadOnly: isUserReadOnly || isFileLocked)
    }

    /// Edit › Read-Only in MacPad++ › Read-Only on Current Document (Notepad++'s user read-only).
    var isUserReadOnly = false {
        didSet { if oldValue != isUserReadOnly { applyReadOnly(); changed() } }
    }
    /// The file is locked on disk (Finder's "Locked", the Mac's counterpart of Windows' read-only attribute).
    private(set) var isFileLocked = false
    /// Notepad++'s isReadOnly(): the user's flag, the file's, or monitoring.
    var isReadOnly: Bool { isMonitoring || isUserReadOnly || isFileLocked }

    private func applyReadOnly() { editor.send(SCI_SETREADONLY, isReadOnly ? 1 : 0) }

    /// Edit › Read-Only Attribute: locks or unlocks the file itself.
    func setFileLocked(_ locked: Bool) throws {
        guard var url = fileURL else { return }
        var values = URLResourceValues()
        values.isUserImmutable = locked
        try url.setResourceValues(values)
        isFileLocked = locked
        applyReadOnly()
        changed()
    }

    private func refreshFileLock() {
        isFileLocked = (try? fileURL?.resourceValues(forKeys: [.isUserImmutableKey]).isUserImmutable) == true
        applyReadOnly()
    }

    /// Monitoring (tail -f): read-only, follows the file as it grows. See startMonitoring().
    private(set) var isMonitoring = false
    private var watcher: FileWatcher?
    private var snapshot: FileSnapshot?
    private var decoder: IncrementalDecoder?

    /// File Status Auto-Detection (MAC-20): a change made by another program, waiting for the
    /// host to ask about it (it asks only for the visible tab, with the app in front).
    private(set) var pendingExternalChange: FileChange?
    var onExternalChange: ((EditorTab) -> Void)?
    /// Text was inserted or deleted (incremental search's count goes stale).
    var onTextModified: (() -> Void)?
    private var diskWatcher: FileWatcher?
    private var diskSnapshot: FileSnapshot?
    /// Deleted on disk and kept in the editor: unsaved until written back.
    private var isMissingOnDisk = false

    // MARK: - Split view (MAC-47)

    /// The same document in the other view. Scintilla's document holds the text, the undo history,
    /// the dirty state, the line endings and the read-only flag, so those are shared; the file's
    /// bookkeeping (path, encoding, language, lock) is copied across on every change. Only the tab
    /// that owns the document watches the file and writes it.
    weak var twin: EditorTab?
    /// A clone made with Clone to Other View, while the tab it was cloned from is open.
    private(set) var isClone = false
    /// The tab that saves and watches the file: the clone's original, or the tab itself.
    var documentOwner: EditorTab { isClone ? (twin ?? self) : self }
    /// Focus came to this tab's editor.
    var onFocus: (() -> Void)?
    /// The editor scrolled (Synchronize Vertical / Horizontal Scrolling).
    var onScroll: (() -> Void)?
    private var isAdopting = false

    /// Notepad++'s Clone to Other View: a second view of `source`'s document.
    convenience init(cloneOf source: EditorTab) {
        self.init(untitledNumber: source.untitledNumber)
        editor.send(SCI_SETDOCPOINTER, 0, source.editor.send(SCI_GETDOCPOINTER))
        isClone = true
        twin = source
        source.twin = self
        adoptDocumentState(from: source)
        applyLanguage(source.language)
        EditorStyler.updateLineNumberWidth(editor)
    }

    /// The original closed: this tab now owns the document, and watches its file.
    func becomeOwner() {
        twin = nil
        guard isClone else { return }
        isClone = false
        startDiskWatch()
    }

    /// Takes the file's bookkeeping from the twin; the text itself is already shared.
    func adoptDocumentState(from other: EditorTab) {
        // Caret moves call this too: nothing to copy, nothing to redraw.
        guard fileURL != other.fileURL || format != other.format || isMissingOnDisk != other.isMissingOnDisk
                || isFileLocked != other.isFileLocked || isLanguageChosenByUser != other.isLanguageChosenByUser
                || isUserReadOnly != other.isUserReadOnly || language.name != other.language.name else { return }
        isAdopting = true
        defer { isAdopting = false }
        fileURL = other.fileURL
        format = other.format
        isMissingOnDisk = other.isMissingOnDisk
        isFileLocked = other.isFileLocked
        isLanguageChosenByUser = other.isLanguageChosenByUser
        if isUserReadOnly != other.isUserReadOnly { isUserReadOnly = other.isUserReadOnly }
        if language.name != other.language.name { applyLanguage(other.language) }
        onChange?()
    }

    /// Something the host shows changed; the twin follows.
    private func changed() {
        if !isAdopting { twin?.adoptDocumentState(from: self) }
        onChange?()
    }

    init(untitledNumber: Int) {
        self.untitledNumber = untitledNumber
        editor = ScintillaView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
        super.init()
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.delegate = self
        EditorStyler.configureEditor(editor)
        // New Document preferences: line ending (Unix by default on a Mac), encoding, language.
        let prefs = Preferences.current
        editor.send(SCI_SETEOLMODE, prefs.newDocLineEnding.rawValue)
        format = FileFormat(encoding: prefs.newDocEncoding.encoding)
        applyLanguage(LanguageCatalog.shared.language(named: prefs.newDocLanguage) ?? LanguageCatalog.shared.plainText)
    }

    func detach() {
        twin = nil
        onFocus = nil
        onScroll = nil
        stopMonitoring()
        stopDiskWatch()
        onExternalChange = nil
        onTextModified = nil
        editor.delegate = nil
        onChange = nil
        hostWindow = nil
    }

    // MARK: - Loading and saving

    func load(_ url: URL) throws {
        let data = try TextFile.read(url)
        let loaded = TextFile.decode(data)
        editor.setUTF8Bytes(loaded.utf8)
        if let eol = loaded.lineEnding { editor.send(SCI_SETEOLMODE, eol.rawValue) }
        editor.send(SCI_EMPTYUNDOBUFFER)
        editor.send(SCI_SETSAVEPOINT)
        // MAC-49: not SCI_GOTOPOS. A tab is loaded before it is laid out, when Scintilla sees no
        // line on screen and scrolls the caret's line out of the top to "show" it.
        editor.send(SCI_SETEMPTYSELECTION, 0)
        editor.send(SCI_SETFIRSTVISIBLELINE, 0)
        fileURL = url
        format = FileFormat(encoding: loaded.encoding)
        isMissingOnDisk = false
        pendingExternalChange = nil
        startDiskWatch()
        isLanguageChosenByUser = false
        refreshFileLock()
        applyLanguage(Self.language(for: url, content: data))
        AppEnvironment.noteRecentDocument(url)
        RecentFilesStore.shared.record(url)
        changed()
    }

    /// The extension or file name first; for a plain-text result, the first line (MAC-11:
    /// "#!/bin/bash", "<?xml" …), as Notepad++'s detectLanguageFromTextBeginning.
    static func language(for url: URL, content: Data) -> LanguageInfo {
        let byName = LanguageCatalog.shared.language(for: url)
        guard byName.name == LanguageCatalog.shared.plainText.name,
              let detected = LanguageDetector.language(fromTextBeginning: content),
              let info = LanguageCatalog.shared.language(named: detected) else { return byName }
        return info
    }

    /// Asks whether to save as administrator; the host's answer arrives through the callback.
    /// Nil means the standard alert; tests set it to answer without UI.
    var adminSaveConfirmation: ((URL, @escaping (Bool) -> Void) -> Void)?

    private func write(to url: URL, completion: @escaping (Bool) -> Void) {
        let data: Data
        do {
            data = try TextFile.encode(editor.utf8Bytes(), as: encoding)
            try FileWriter.write(data, to: url)  // through links, keeping the mode (MAC-62)
        } catch {
            if PrivilegedSave.isPermissionDenied(error),
               let bytes = try? TextFile.encode(editor.utf8Bytes(), as: encoding) {
                offerAdminSave(bytes, to: url, completion: completion)
            } else {
                presentSaveError(error)
                completion(false)
            }
            return
        }
        didWrite(to: url)
        completion(true)
    }

    /// MAC-22 / MAC-27: a permission error goes straight to the administrator save (one popup).
    private func offerAdminSave(_ data: Data, to url: URL, completion: @escaping (Bool) -> Void) {
        let proceed: (Bool) -> Void = { [weak self] yes in
            guard let self else { return }
            guard yes else { completion(false); return }
            self.adminSave(data, to: url, completion: completion)
        }
        // One popup per save, as with Installer (MAC-27): macOS's own prompt already names the file
        // ("MacPad++ needs administrator rights to save …") and has Cancel, so MacPad++ does not ask
        // first. Tests may still intercept the step.
        if let adminSaveConfirmation { adminSaveConfirmation(url, proceed); return }
        proceed(true)
    }

    /// MAC-24 / MAC-28 / MAC-55: the helper the installer set up, which asks macOS for an
    /// administrator (Touch ID or password) naming the file; otherwise MAC-22's password prompt.
    /// Either way, one popup. System startup and security files are refused on both routes.
    private func adminSave(_ data: Data, to url: URL, completion: @escaping (Bool) -> Void) {
        guard !FileInstaller.isProtected(url.path) else {
            presentSaveError(FileInstaller.Failure.protectedPath(url.path))
            completion(false)
            return
        }
        let helper = AdminHelperSupport.helper
        helper.checkAvailable { [weak self] available in
            guard let self else { return }
            switch AdminSaveRoute.decide(helperAvailable: available) {
            case .helper:
                helper.install(data, atPath: url.path) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .saved:
                        self.didWrite(to: url)
                        completion(true)
                    case .cancelled:
                        completion(false)  // stay dirty, say nothing
                    case .refused(let why):
                        self.presentSaveError(FileInstaller.Failure.io(why))
                        completion(false)
                    case .failed(let why):
                        AppEnvironment.log.notice("helper could not save \(url.path, privacy: .private) (\(why, privacy: .public)); using the password prompt")
                        self.passwordSave(data, to: url, completion: completion)
                    }
                }
            case .password:
                self.passwordSave(data, to: url, completion: completion)
            }
        }
    }

    /// MAC-22: macOS's administrator password prompt runs the install script as root.
    private func passwordSave(_ data: Data, to url: URL, completion: @escaping (Bool) -> Void) {
        do {
            try PrivilegedSave.save(data, to: url)
        } catch PrivilegedSaveError.cancelled {
            completion(false)  // the user dismissed the password prompt: stay dirty, say nothing
            return
        } catch {
            presentSaveError(error)
            completion(false)
            return
        }
        didWrite(to: url)
        completion(true)
    }

    /// Tests catch save errors here instead of a modal alert.
    var onSaveError: ((Error) -> Void)?

    private func presentSaveError(_ error: Error) {
        if let onSaveError { onSaveError(error); return }
        if let hostWindow {
            NSApp.presentError(error, modalFor: hostWindow, delegate: nil, didPresent: nil, contextInfo: nil)
        } else {
            NSApp.presentError(error)
        }
    }

    /// Bookkeeping after the file is on disk, however it got there.
    private func didWrite(to url: URL) {
        let languageChanged = fileURL?.pathExtension != url.pathExtension
        fileURL = url
        format.markSaved()
        isMissingOnDisk = false
        pendingExternalChange = nil
        startDiskWatch()  // our own write is the new baseline, never a prompt
        editor.send(SCI_SETSAVEPOINT)
        // A new extension, or a still-plain document, picks its language again — unless the user
        // chose one from the Language menu.
        if !isLanguageChosenByUser && (languageChanged || language.name == LanguageCatalog.shared.plainText.name) {
            let candidate = Self.language(for: url, content: editor.utf8Bytes().prefix(4096))
            if candidate.name != language.name { applyLanguage(candidate) }
        }
        AppEnvironment.noteRecentDocument(url)
        RecentFilesStore.shared.record(url)
        changed()
    }

    /// Saves, asking for a location if the document is untitled. Calls back with success.
    func save(completion: ((Bool) -> Void)? = nil) {
        // A monitored file belongs to the program writing it: never write over it (nor its
        // freshly appended lines). The buffer is read-only and always matches the disk anyway.
        if isClone, let twin { twin.save(completion: completion); return }  // the owner writes
        if isMonitoring { completion?(true); return }
        if let url = fileURL {
            // Always write, whether or not anyone wants the result (MAC-18).
            write(to: url) { completion?($0) }
        } else {
            saveAs(completion: completion)
        }
    }

    /// Writes to `url` without the save panel (scripted saves, tests).
    func saveAs(to url: URL, completion: ((Bool) -> Void)? = nil) {
        if isClone, let twin { twin.saveAs(to: url, completion: completion); return }
        if isMonitoring { completion?(false); return }
        write(to: url) { completion?($0) }
    }

    func saveAs(completion: ((Bool) -> Void)? = nil) {
        if isClone, let twin { twin.saveAs(completion: completion); return }
        if isMonitoring { completion?(false); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? displayName
        if let dir = fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { completion?(false); return }
            self.write(to: url) { completion?($0) }
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

    // MARK: - Encoding and line endings (status bar pickers)

    /// Notepad++'s "Convert to …": the text stays, the file will be written in `target`.
    /// Throws `TextFile.SaveError.unrepresentable` — and changes nothing — if the text cannot be
    /// represented in `target`.
    func convertEncoding(to target: TextEncoding) throws {
        guard target != encoding, !isMonitoring else { return }
        try format.convert(editor.utf8Bytes(), to: target)
        changed()
    }

    /// Notepad++'s EOL Conversion: rewrites every line ending as one undoable edit and makes
    /// `target` what Enter inserts from now on. The caret keeps its line and column.
    func convertLineEndings(to target: LineEnding) {
        guard !isMonitoring else { return }
        editor.send(SCI_SETEOLMODE, target.rawValue)
        let old = editor.utf8Bytes()
        let new = LineEnding.convert(old, to: target)
        guard new != old else { changed(); return }

        let pos = editor.send(SCI_GETCURRENTPOS)
        let line = editor.send(SCI_LINEFROMPOSITION, pos)
        let column = editor.send(SCI_GETCOLUMN, pos)
        let firstVisible = editor.send(SCI_GETFIRSTVISIBLELINE)

        editor.send(SCI_BEGINUNDOACTION)
        editor.send(SCI_SETTARGETRANGE, 0, old.count)
        new.withUnsafeBytes { raw in
            _ = editor.send(SCI_REPLACETARGET, raw.count, pointer: raw.baseAddress)
        }
        editor.send(SCI_ENDUNDOACTION)

        editor.send(SCI_GOTOPOS, editor.send(SCI_FINDCOLUMN, line, column))
        editor.send(SCI_SETFIRSTVISIBLELINE, firstVisible)
        changed()
    }

    // MARK: - Monitoring (tail -f)

    /// Notepad++'s View › Monitoring (tail -f): reloads the file from disk, makes the tab
    /// read-only, and from then on appends whatever the file gains — following the end while the
    /// caret is at the end. A replaced or truncated file (log rotation) is read again from the
    /// start. The caller saves unsaved edits first; this refuses to discard them.
    func startMonitoring(pollInterval: TimeInterval = 1.0) throws {
        guard !isMonitoring, let url = fileURL else { return }
        guard !isModified else { throw MonitoringError.unsavedChanges }
        stopDiskWatch()  // monitoring follows changes itself
        pendingExternalChange = nil
        isMonitoring = true
        do {
            try reloadForMonitoring(url)
        } catch {
            isMonitoring = false
            throw error
        }
        let watcher = FileWatcher(path: url.path, pollInterval: pollInterval) { [weak self] in self?.checkMonitoredFile() }
        watcher.start()
        self.watcher = watcher
        changed()
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        watcher?.stop()
        watcher = nil
        snapshot = nil
        decoder = nil
        isMonitoring = false
        applyReadOnly()
        startDiskWatch()
        changed()
    }

    enum MonitoringError: LocalizedError {
        case unsavedChanges
        var errorDescription: String? { "Save the document before monitoring it." }
    }

    /// Looks at the file now (the watcher calls this; tests call it directly).
    func checkMonitoredFile() {
        guard isMonitoring, let url = fileURL else { return }
        switch FileChange.classify(previous: snapshot, current: FileSnapshot.of(path: url.path)) {
        case .unchanged:
            break
        case .appended(let from):
            appendFromDisk(url, from: from)
        case .replaced:
            try? reloadForMonitoring(url)
        case .missing:
            snapshot = nil  // keep the text; pick the file up again when it reappears
        }
    }

    /// Reads the whole file, as on load, and positions at the end.
    private func reloadForMonitoring(_ url: URL) throws {
        let data = try TextFile.read(url)
        let loaded = TextFile.decode(data)
        replaceReadOnlyText { editor.setUTF8Bytes(loaded.utf8) }
        if let eol = loaded.lineEnding { editor.send(SCI_SETEOLMODE, eol.rawValue) }
        format = FileFormat(encoding: loaded.encoding)
        decoder = IncrementalDecoder(encoding: loaded.encoding)
        snapshot = FileSnapshot.of(path: url.path).map { FileSnapshot(inode: $0.inode, size: UInt64(data.count), modified: $0.modified) }
        editor.send(SCI_DOCUMENTEND)
        changed()
    }

    /// Appends the bytes the file gained since `offset`, keeping the view on the end only if the
    /// caret was already there (scrolling up to read earlier lines pauses following).
    private func appendFromDisk(_ url: URL, from offset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil, let bytes = try? handle.read(upToCount: Self.maximumAppend), !bytes.isEmpty,
              var decoder else { return }
        let text = decoder.feed(bytes)
        self.decoder = decoder
        if let current = FileSnapshot.of(path: url.path) {
            snapshot = FileSnapshot(inode: current.inode, size: offset + UInt64(bytes.count), modified: current.modified)
        }
        guard !text.isEmpty else { return }
        let following = editor.send(SCI_GETCURRENTPOS) == editor.send(SCI_GETLENGTH)
        replaceReadOnlyText {
            text.withUnsafeBytes { raw in
                _ = editor.send(SCI_APPENDTEXT, raw.count, pointer: raw.baseAddress)
            }
        }
        if following { editor.send(SCI_DOCUMENTEND) }
        changed()
    }

    /// MAC-63: at most this much is appended per check; the rest follows on the next one.
    static let maximumAppend = 64 * 1024 * 1024

    /// Changes the text of the read-only monitored buffer without it counting as an edit:
    /// no undo history, no dirty state.
    private func replaceReadOnlyText(_ change: () -> Void) {
        editor.send(SCI_SETREADONLY, 0)
        change()
        editor.send(SCI_EMPTYUNDOBUFFER)
        editor.send(SCI_SETSAVEPOINT)
        applyReadOnly()
    }

    // MARK: - File Status Auto-Detection (changes made by other programs)

    private func startDiskWatch(pollInterval: TimeInterval = 2.0) {
        stopDiskWatch()
        guard let url = fileURL, !isMonitoring, !isClone else { return }
        diskSnapshot = FileSnapshot.of(path: url.path)
        let watcher = FileWatcher(path: url.path, pollInterval: pollInterval) { [weak self] in self?.checkDiskState() }
        watcher.start()
        diskWatcher = watcher
    }

    private func stopDiskWatch() {
        diskWatcher?.stop()
        diskWatcher = nil
    }

    /// Compares the file with what was last loaded or saved (the watcher calls this; tests call
    /// it directly). A change is recorded once and reported to the host; nothing more is noted
    /// until the host resolves it.
    func checkDiskState() {
        guard !isMonitoring, pendingExternalChange == nil, FileStatusPreferences.isEnabled,
              let url = fileURL else { return }
        let current = FileSnapshot.of(path: url.path)
        let change = FileChange.classify(previous: diskSnapshot, current: current)
        guard change != .unchanged else { return }
        // Being kept after deletion and still gone: nothing new to say.
        if change == .missing && isMissingOnDisk { diskSnapshot = nil; return }
        diskSnapshot = current
        pendingExternalChange = change
        onExternalChange?(self)
    }

    /// The host's answer. `accept` is "Reload" for a modified file and "Keep" for a deleted one;
    /// declining a reload keeps the buffer as it is (until the file changes again). The host
    /// closes the tab itself when the user declines keeping a deleted file.
    func resolveExternalChange(accept: Bool) {
        guard let change = pendingExternalChange else { return }
        pendingExternalChange = nil
        switch change {
        case .missing:
            if accept { isMissingOnDisk = true }
        case .appended, .replaced:
            if accept { try? reloadFromDisk() }
        case .unchanged:
            break
        }
        diskSnapshot = fileURL.flatMap { FileSnapshot.of(path: $0.path) }
        changed()
    }

    /// Reads the file again, keeping the caret's line and column and the scroll position.
    func reloadFromDisk() throws {
        guard let url = fileURL else { return }
        let loaded = TextFile.decode(try TextFile.read(url))
        let pos = editor.send(SCI_GETCURRENTPOS)
        let line = editor.send(SCI_LINEFROMPOSITION, pos)
        let column = editor.send(SCI_GETCOLUMN, pos)
        let firstVisible = editor.send(SCI_GETFIRSTVISIBLELINE)

        editor.send(SCI_SETREADONLY, 0)  // a read-only document still takes the disk's text
        editor.setUTF8Bytes(loaded.utf8)
        refreshFileLock()
        if let eol = loaded.lineEnding { editor.send(SCI_SETEOLMODE, eol.rawValue) }
        editor.send(SCI_EMPTYUNDOBUFFER)
        editor.send(SCI_SETSAVEPOINT)
        format = FileFormat(encoding: loaded.encoding)
        isMissingOnDisk = false

        let lastLine = max(editor.send(SCI_GETLINECOUNT) - 1, 0)
        editor.send(SCI_GOTOPOS, editor.send(SCI_FINDCOLUMN, min(line, lastLine), column))
        editor.send(SCI_SETFIRSTVISIBLELINE, firstVisible)
        diskSnapshot = FileSnapshot.of(path: url.path)
        changed()
    }

    // MARK: - Editor state

    /// Where the caret and the viewport are, for session restore.
    var caretPosition: Int { editor.send(SCI_GETCURRENTPOS) }
    /// Bookmarked lines (0-based), saved in the session as Notepad++ does.
    var bookmarks: [Int] {
        get { Marker(editor: editor).bookmarkedLines }
        set { Marker(editor: editor).setBookmarks(newValue) }
    }
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
            lineEnding: lineEnding.statusName,
            encoding: encoding.statusName,
            overtype: editor.send(SCI_GETOVERTYPE) != 0)
    }

    /// The theme changed (MAC-36): repaint with it, keeping the language.
    func reapplyTheme() { applyLanguage(language) }

    /// Language menu: re-lexes the document with `info`, whatever its extension says.
    func setLanguage(_ info: LanguageInfo) {
        isLanguageChosenByUser = true
        guard info.name != language.name else { return }
        applyLanguage(info)
        changed()
    }

    private func applyLanguage(_ info: LanguageInfo) {
        language = info
        EditorStyler.apply(language: info, theme: ThemeManager.shared.current, to: editor)
    }

    // MARK: - Scintilla notifications

    func notification(_ notification: UnsafeMutablePointer<SCNotification>!) {
        let n = notification.pointee
        switch Int32(n.nmhdr.code) {
        case SCN_SAVEPOINTLEFT, SCN_SAVEPOINTREACHED:
            changed()
        case SCN_UPDATEUI:
            EditorStyler.updateBraceMatch(editor)
            if Int(n.updated) & Int(SC_UPDATE_V_SCROLL) != 0 && Preferences.current.lineNumberDynamicWidth {
                EditorStyler.updateLineNumberWidth(editor)  // Dynamic width follows the last line on screen
            }
            if Int(n.updated) & Int(SC_UPDATE_V_SCROLL | SC_UPDATE_H_SCROLL) != 0 { onScroll?() }
            changed()
        case SCN_FOCUSIN:
            onFocus?()
        case SCN_MODIFIED:
            if n.linesAdded != 0 { EditorStyler.updateLineNumberWidth(editor) }
            if Int(n.modificationType) & Int(SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT) != 0 { onTextModified?() }
        case SCN_MARGINCLICK where Int(n.margin) == Margin.symbol && n.modifiers == 0:
            // A click in the bookmark margin toggles that line's bookmark.
            Marker(editor: editor).toggleBookmark(editor.send(SCI_LINEFROMPOSITION, Int(n.position)))
        case SCN_MACRORECORD:
            MacroRecorder.shared.scintillaMessage(Int(n.message), wParam: Int(n.wParam), lParam: Int(n.lParam),
                                                  eolMode: editor.send(SCI_GETEOLMODE))
        case SCN_MARGINRIGHTCLICK where Int(n.margin) == Margin.symbol:
            if let event = NSApp.currentEvent {
                NSMenu.popUpContextMenu(MainMenu.bookmarkMenu(), with: event, for: editor)
            }
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

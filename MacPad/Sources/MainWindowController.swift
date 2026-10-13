import AppKit

/// The single editor window: a tab bar, the active document's Scintilla view, and the status bar.
/// Notepad++ keeps every open file in one window, so this controller owns the tab list and the
/// documents in it.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private var tabs = TabList<EditorTab>()
    private var nextUntitledNumber = 1
    /// Suppresses session writes while the session itself is being reopened.
    private var isRestoring = false

    private let tabBar = TabBarView()
    private let editorContainer = NSView()
    private let statusBar = StatusBar()

    var activeTab: EditorTab? { tabs.active }
    var hasDirtyTabs: Bool { tabs.items.contains(where: \.isModified) }
    var openTabs: [EditorTab] { tabs.items }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 688),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.setFrameAutosaveName("MacPad++ Editor")
        window.tabbingMode = .disallowed  // the document tabs are MacPad++'s own, not macOS window tabs
        super.init(window: window)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        editorContainer.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(tabBar)
        content.addSubview(editorContainer)
        content.addSubview(statusBar)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: content.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editorContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            editorContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editorContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editorContainer.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.delegate = self

        tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        statusBar.onEncodingClick = { [weak self] label in self?.showEncodingMenu(at: label) }
        statusBar.onLineEndingClick = { [weak self] label in self?.showLineEndingMenu(at: label) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Opening documents

    @discardableResult
    func newTab() -> EditorTab {
        let tab = EditorTab(untitledNumber: nextUntitledNumber)
        nextUntitledNumber += 1
        add(tab)
        return tab
    }

    /// Opens a file, focusing the tab that already holds it, and reusing an untouched "new N"
    /// tab when there is one — both as Notepad++ does.
    func open(_ url: URL) {
        let standardized = url.standardizedFileURL
        if let existing = tabs.firstIndex(where: { $0.fileURL?.standardizedFileURL == standardized }) {
            selectTab(at: existing)
            return
        }
        let reusableIndex = tabs.firstIndex(where: \.isPristineUntitled)
        let tab = reusableIndex.map { tabs[$0] } ?? EditorTab(untitledNumber: nextUntitledNumber)
        if reusableIndex == nil { nextUntitledNumber += 1 }
        tab.hostWindow = window
        do {
            try tab.load(url)
        } catch {
            NSApp.presentError(error)
            return
        }
        if let reusableIndex {
            tabs.select(reusableIndex)
            refresh()
        } else {
            add(tab)
        }
    }

    // MARK: - Session

    /// The open documents, in tab order. Unsaved "new N" documents have no file to point at, so
    /// they are left out rather than restored empty.
    func captureSession() -> SessionState {
        var active = 0
        var documents: [SessionState.Document] = []
        for (index, tab) in tabs.items.enumerated() {
            guard let path = tab.fileURL?.standardizedFileURL.path else { continue }
            if index == tabs.activeIndex { active = documents.count }
            documents.append(SessionState.Document(
                path: path,
                caretPosition: tab.caretPosition,
                firstVisibleLine: tab.firstVisibleLine,
                isMonitoring: tab.isMonitoring))
        }
        return SessionState(documents: documents, activeIndex: active)
    }

    /// Reopens a stored session. Returns false when nothing could be reopened, so the caller can
    /// fall back to a fresh document.
    @discardableResult
    func restore(_ state: SessionState) -> Bool {
        let state = state.filtered { FileManager.default.fileExists(atPath: $0) }
        guard !state.isEmpty else { return false }
        isRestoring = true
        defer { isRestoring = false }
        for document in state.documents {
            let tab = EditorTab(untitledNumber: nextUntitledNumber)
            nextUntitledNumber += 1
            tab.hostWindow = window
            do {
                try tab.load(URL(fileURLWithPath: document.path))
            } catch {
                NSLog("MacPad++: skipping \(document.path) from the session: \(error.localizedDescription)")
                continue
            }
            add(tab)
            if document.isMonitoring {
                try? tab.startMonitoring()  // positions at the end, as monitoring does
            } else {
                tab.restoreViewport(caretPosition: document.caretPosition,
                                    firstVisibleLine: document.firstVisibleLine)
            }
        }
        guard !tabs.isEmpty else { return false }
        tabs.select(min(state.activeIndex, tabs.count - 1))
        refresh()
        return true
    }

    /// Written whenever the set of open documents changes, so a crash or a forced quit still
    /// leaves a usable session behind.
    func persistSession() {
        guard !isRestoring else { return }
        SessionStore.save(captureSession())
    }

    private func add(_ tab: EditorTab) {
        tab.hostWindow = window
        tab.onChange = { [weak self] in self?.refresh() }
        tab.onExternalChange = { [weak self] _ in self?.presentExternalChangeIfNeeded() }
        tab.editor.isHidden = true
        editorContainer.addSubview(tab.editor)
        NSLayoutConstraint.activate([
            tab.editor.topAnchor.constraint(equalTo: editorContainer.topAnchor),
            tab.editor.leadingAnchor.constraint(equalTo: editorContainer.leadingAnchor),
            tab.editor.trailingAnchor.constraint(equalTo: editorContainer.trailingAnchor),
            tab.editor.bottomAnchor.constraint(equalTo: editorContainer.bottomAnchor),
        ])
        tabs.append(tab)
        refresh()
        persistSession()
    }

    // MARK: - Tab commands

    func selectTab(at index: Int) {
        tabs.select(index)
        refresh()
        persistSession()
    }

    /// Closes a tab, asking about unsaved changes first. Closing the last tab leaves a fresh
    /// "new N" document behind rather than an empty window, as Notepad++ does.
    func closeTab(at index: Int) {
        guard tabs.items.indices.contains(index) else { return }
        let tab = tabs[index]
        tab.confirmDiscard { [weak self] discard in
            guard let self, discard else { return }
            guard let current = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.tabs.remove(at: current)
            tab.editor.removeFromSuperview()
            tab.detach()
            if self.tabs.isEmpty { self.newTab() } else { self.refresh() }
            self.persistSession()
        }
    }

    @IBAction func newDocument(_ sender: Any?) { newTab() }

    @IBAction func closeTab(_ sender: Any?) {
        guard let index = tabs.activeIndex else { return }
        closeTab(at: index)
    }

    @IBAction func selectNextTab(_ sender: Any?) {
        tabs.selectNext()
        refresh()
    }

    @IBAction func selectPreviousTab(_ sender: Any?) {
        tabs.selectPrevious()
        refresh()
    }

    @IBAction func saveDocument(_ sender: Any?) {
        activeTab?.save { [weak self] saved in if saved { self?.persistSession() } }
    }

    @IBAction func saveDocumentAs(_ sender: Any?) {
        activeTab?.saveAs { [weak self] saved in if saved { self?.persistSession() } }
    }

    // MARK: - Status bar pickers (encoding, line endings)

    private func showEncodingMenu(at label: NSView) {
        guard let tab = activeTab, !tab.isMonitoring else { NSSound.beep(); return }
        let menu = NSMenu()
        let entries = StatusBarMenu.encodingItems(current: tab.encoding)
        encodingMenuChoices = entries.map(\.value)
        for (index, entry) in entries.enumerated() {
            let item = NSMenuItem(title: entry.title, action: #selector(convertEncoding(_:)), keyEquivalent: "")
            item.tag = index
            item.state = entry.isCurrent ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: label.bounds.maxY + 4), in: label)
    }

    /// The encodings behind the open encoding menu, by item tag (code pages carry a value, so
    /// items cannot be matched back by name alone).
    private var encodingMenuChoices: [TextEncoding] = []

    private func showLineEndingMenu(at label: NSView) {
        guard let tab = activeTab, !tab.isMonitoring else { NSSound.beep(); return }
        let menu = NSMenu()
        for entry in StatusBarMenu.lineEndingItems(current: tab.lineEnding) {
            let item = NSMenuItem(title: entry.title, action: #selector(convertLineEndings(_:)), keyEquivalent: "")
            item.tag = entry.value.rawValue
            item.state = entry.isCurrent ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: label.bounds.maxY + 4), in: label)
    }

    @objc private func convertEncoding(_ sender: NSMenuItem) {
        guard let tab = activeTab, encodingMenuChoices.indices.contains(sender.tag) else { return }
        let target = encodingMenuChoices[sender.tag]
        do {
            try tab.convertEncoding(to: target)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Cannot convert \"\(tab.displayName)\" to \(target.statusName)"
            alert.informativeText = "The text contains characters that \(target.statusName) cannot represent. "
                + "The document was left unchanged."
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }

    @objc private func convertLineEndings(_ sender: NSMenuItem) {
        guard let tab = activeTab, let target = LineEnding(rawValue: sender.tag) else { return }
        tab.convertLineEndings(to: target)
    }

    // MARK: - View menu

    @IBAction func toggleWordWrap(_ sender: Any?) {
        guard let editor = activeTab?.editor else { return }
        editor.send(SCI_SETWRAPMODE, editor.send(SCI_GETWRAPMODE) == Int(SC_WRAP_NONE) ? Int(SC_WRAP_WORD) : Int(SC_WRAP_NONE))
    }

    @IBAction func toggleShowAllCharacters(_ sender: Any?) {
        guard let editor = activeTab?.editor else { return }
        let on = editor.send(SCI_GETVIEWWS) == Int(SCWS_INVISIBLE)
        editor.send(SCI_SETVIEWWS, on ? Int(SCWS_VISIBLEALWAYS) : Int(SCWS_INVISIBLE))
        editor.send(SCI_SETVIEWEOL, on ? 1 : 0)
    }

    /// View › Monitoring (tail -f). Unsaved edits are saved first (after asking), since the
    /// monitored tab shows the file exactly as it is on disk.
    @IBAction func toggleMonitoring(_ sender: Any?) {
        guard let tab = activeTab, tab.fileURL != nil else { return }
        if tab.isMonitoring {
            tab.stopMonitoring()
            persistSession()
            return
        }
        let start: () -> Void = { [weak self] in
            do {
                try tab.startMonitoring()
                self?.persistSession()
            } catch {
                if let window = self?.window { NSApp.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil) }
            }
        }
        guard tab.isModified else { start(); return }
        let alert = NSAlert()
        alert.messageText = "Save \"\(tab.displayName)\" before monitoring it?"
        alert.informativeText = "Monitoring shows the file as it is on disk and makes the tab read-only."
        alert.addButton(withTitle: "Save and Monitor")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            tab.save { saved in if saved { start() } }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    @IBAction func zoomInText(_ sender: Any?) { activeTab?.editor.send(SCI_ZOOMIN) }
    @IBAction func zoomOutText(_ sender: Any?) { activeTab?.editor.send(SCI_ZOOMOUT) }
    @IBAction func restoreTextZoom(_ sender: Any?) { activeTab?.editor.send(SCI_SETZOOM, 0) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let editor = activeTab?.editor else { return false }
        switch item.action {
        case #selector(toggleWordWrap(_:)):
            item.state = editor.send(SCI_GETWRAPMODE) != Int(SC_WRAP_NONE) ? .on : .off
        case #selector(toggleShowAllCharacters(_:)):
            item.state = editor.send(SCI_GETVIEWWS) != Int(SCWS_INVISIBLE) ? .on : .off
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return tabs.count > 1
        case #selector(toggleMonitoring(_:)):
            item.state = activeTab?.isMonitoring == true ? .on : .off
            return activeTab?.fileURL != nil
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)):
            return activeTab?.isMonitoring != true  // a monitored file belongs to its writer
        default:
            break
        }
        return true
    }

    // MARK: - Window

    /// Closing the window means closing every document, so each unsaved one gets its prompt.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasDirtyTabs else { return true }
        confirmDiscardAll { [weak self] ok in if ok { self?.window?.close() } }
        return false
    }

    /// Asks about each unsaved document in turn, as Notepad++ does on exit.
    func confirmDiscardAll(completion: @escaping (Bool) -> Void) {
        confirmDiscard(tabs.items.filter(\.isModified)[...], completion: completion)
    }

    private func confirmDiscard(_ remaining: ArraySlice<EditorTab>, completion: @escaping (Bool) -> Void) {
        guard let first = remaining.first else { completion(true); return }
        if let index = tabs.firstIndex(where: { $0 === first }) { selectTab(at: index) }
        first.confirmDiscard { [weak self] ok in
            guard ok else { completion(false); return }
            self?.confirmDiscard(remaining.dropFirst(), completion: completion)
        }
    }

    // MARK: - Presentation

    /// Pushes the tab list's state into the tab bar, the title bar and the status bar.
    private func refresh() {
        for (index, tab) in tabs.items.enumerated() {
            tab.editor.isHidden = index != tabs.activeIndex
        }
        tabBar.reload(
            tabs: tabs.items.map { ($0.tabLabel, $0.fileURL?.path) },
            activeIndex: tabs.activeIndex)

        guard let active = tabs.active else { return }
        window?.title = active.displayName
        window?.representedURL = active.fileURL
        window?.isDocumentEdited = active.isModified
        if window?.firstResponder !== active.editor.content() {
            window?.makeFirstResponder(active.editor.content())
        }
        let state = active.status()
        statusBar.update(
            language: state.language, length: state.length, lines: state.lines,
            line: state.line, column: state.column, position: state.position,
            lineEnding: state.lineEnding, encoding: state.encoding, overtype: state.overtype)
        presentExternalChangeIfNeeded()  // a tab just shown may have a change waiting
    }

    // MARK: - File Status Auto-Detection (MAC-20)

    private var isPromptingExternalChange = false
    private var activationObserver: NSObjectProtocol?

    func windowDidBecomeKey(_ notification: Notification) {
        presentExternalChangeIfNeeded()
    }

    /// Asks about a file another program changed or deleted — only for the visible tab, only with
    /// MacPad++ in front, one question at a time (as Notepad++ checks when it regains focus).
    /// Other tabs keep their pending change until they are shown.
    func presentExternalChangeIfNeeded() {
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.presentExternalChangeIfNeeded() }
        }
        guard !isPromptingExternalChange, NSApp.isActive, let window, window.isKeyWindow,
              window.attachedSheet == nil, let tab = activeTab, let change = tab.pendingExternalChange,
              let path = tab.fileURL?.path else { return }
        switch ExternalChangePolicy.action(for: change, isModified: tab.isModified,
                                           updateSilently: FileStatusPreferences.updateSilently) {
        case .none:
            tab.resolveExternalChange(accept: false)
        case .reloadSilently:
            tab.resolveExternalChange(accept: true)
        case .ask(let prompt):
            let texts = prompt.texts(path: path)
            let alert = NSAlert()
            alert.messageText = texts.title
            alert.informativeText = texts.message
            alert.addButton(withTitle: texts.yes)
            alert.addButton(withTitle: texts.no)
            isPromptingExternalChange = true
            alert.beginSheetModal(for: window) { [weak self, weak tab] response in
                guard let self, let tab else { return }
                self.isPromptingExternalChange = false
                let accepted = response == .alertFirstButtonReturn
                tab.resolveExternalChange(accept: accepted)
                if prompt == .keepDeleted && !accepted, let index = self.tabs.items.firstIndex(where: { $0 === tab }) {
                    self.closeTab(at: index)
                } else {
                    self.refresh()
                }
            }
        }
    }
}

import AppKit

/// The single editor window: a tab bar, the active document's Scintilla view, and the status bar.
/// Notepad++ keeps every open file in one window, so this controller owns the tab list and the
/// documents in it.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private var tabs = TabList<EditorTab>()
    private var nextUntitledNumber = 1

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

    private func add(_ tab: EditorTab) {
        tab.hostWindow = window
        tab.onChange = { [weak self] in self?.refresh() }
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
    }

    // MARK: - Tab commands

    func selectTab(at index: Int) {
        tabs.select(index)
        refresh()
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

    @IBAction func saveDocument(_ sender: Any?) { activeTab?.save() }
    @IBAction func saveDocumentAs(_ sender: Any?) { activeTab?.saveAs() }

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
    }
}

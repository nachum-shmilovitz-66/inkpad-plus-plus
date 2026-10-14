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
    /// The editor above, Notepad++'s "Search results" panel docked below (MAC-32).
    private let splitView = NSSplitView()
    /// Left dock | documents | right dock.
    private let dockSplit = NSSplitView()
    let leftDock = NSSplitView()
    let rightDock = NSSplitView()
    private var themeObserver: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?
    let searchResults = SearchResultsPanel()
    /// Notepad++'s incremental search bar, above the status bar (MAC-34).
    let incrementalBar = IncrementalSearchBar()

    var activeTab: EditorTab? { tabs.active }
    var hasDirtyTabs: Bool { tabs.items.contains(where: \.isModified) }
    var openTabs: [EditorTab] { tabs.items }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 688),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        // Centered on first launch, then wherever the user leaves it (MAC-26). The old autosave
        // name is dropped: frames saved under it came from the bottom-left default.
        WindowPlacement.place(window)
        window.tabbingMode = .disallowed  // the document tabs are MacPad++'s own, not macOS window tabs
        super.init(window: window)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        splitView.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(editorContainer)
        splitView.addArrangedSubview(searchResults)
        splitView.setHoldingPriority(.defaultLow - 1, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow + 1, forSubviewAt: 1)
        searchResults.isHidden = true
        incrementalBar.isHidden = true
        let column = NSStackView(views: [splitView, incrementalBar])  // a hidden bar takes no room
        column.orientation = .vertical
        column.spacing = 0
        column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        splitView.setContentHuggingPriority(.defaultLow, for: .vertical)
        incrementalBar.setContentHuggingPriority(.required, for: .vertical)

        // Docked panels beside the documents, as Notepad++ docks them (milestone 6): Folder as
        // Workspace on the left, Function List and Document Map on the right.
        let center = NSView()
        center.addSubview(tabBar)
        center.addSubview(column)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: center.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            column.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: center.bottomAnchor),
            splitView.widthAnchor.constraint(equalTo: column.widthAnchor),
            incrementalBar.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        dockSplit.isVertical = true
        dockSplit.dividerStyle = .thin
        dockSplit.translatesAutoresizingMaskIntoConstraints = false
        leftDock.isVertical = false
        rightDock.isVertical = false
        for dock in [leftDock, rightDock] {
            dock.dividerStyle = .thin
            dock.isHidden = true
            dock.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        }
        dockSplit.addArrangedSubview(leftDock)
        dockSplit.addArrangedSubview(center)
        dockSplit.addArrangedSubview(rightDock)
        dockSplit.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        dockSplit.setHoldingPriority(.defaultLow - 10, forSubviewAt: 1)
        dockSplit.setHoldingPriority(.defaultLow + 10, forSubviewAt: 2)

        let content = NSView()
        content.addSubview(dockSplit)
        content.addSubview(statusBar)
        NSLayoutConstraint.activate([
            dockSplit.topAnchor.constraint(equalTo: content.topAnchor),
            dockSplit.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            dockSplit.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            dockSplit.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.delegate = self

        incrementalBar.editorProvider = { [weak self] in self?.activeTab?.editor }
        searchResults.onOpen = { [weak self] hit, index in self?.openSearchHit(hit, rangeIndex: index) }
        searchResults.onOpenPath = { [weak self] path in self?.openSearchPath(path) }
        searchResults.onClose = { [weak self] in self?.setSearchResultsVisible(false) }
        themeObserver = NotificationCenter.default.addObserver(forName: ThemeManager.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyTheme()
        }
        // Preferences apply at once to every open editor (MAC-38), as Notepad++'s do.
        preferencesObserver = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyTheme()
        }
        tabBar.onSelect = { [weak self] index in self?.selectTab(at: index) }
        tabBar.onClose = { [weak self] index in self?.closeTab(at: index) }
        statusBar.onEncodingClick = { [weak self] label in self?.showEncodingMenu(at: label) }
        statusBar.onLanguageClick = { [weak self] label in self?.showLanguageMenu(at: label) }
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
                isMonitoring: tab.isMonitoring,
                bookmarks: tab.bookmarks,
                language: tab.language.name))
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
            tab.bookmarks = document.bookmarks
            if let name = document.language, let info = LanguageCatalog.shared.language(named: name) { tab.setLanguage(info) }
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
        MacroRecorder.shared.attach(tab.editor)
        tab.onChange = { [weak self] in self?.refresh() }
        tab.onExternalChange = { [weak self] _ in self?.presentExternalChangeIfNeeded() }
        tab.onTextModified = { [weak self, weak tab] in
            if let self, tab === self.activeTab { self.incrementalBar.resetCount() }
        }
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
        incrementalBar.resetCount()
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
        activeTab?.save { [weak self] saved in if saved { self?.persistSession(); self?.reloadFunctionList() } }
    }

    @IBAction func saveDocumentAs(_ sender: Any?) {
        activeTab?.saveAs { [weak self] saved in if saved { self?.persistSession(); self?.reloadFunctionList() } }
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

    // MARK: - Edit commands (MAC-40)

    private var beginSelectPosition: Int?
    private var beginSelectColumnMode = false

    @IBAction func convertCase(_ sender: Any?) {
        guard let editor = activeTab?.editor, let tag = (sender as? NSMenuItem)?.tag,
              let conversion = CaseConversion(rawValue: tag), activeTab?.isReadOnly == false else { return }
        EditCommands(editor: editor).convertCase(conversion)
    }

    @IBAction func changeIndent(_ sender: Any?) {
        guard let editor = activeTab?.editor, activeTab?.isReadOnly == false else { return }
        EditCommands(editor: editor).indent(increase: (sender as? NSMenuItem)?.tag == 1)
    }

    @IBAction func commentCommand(_ sender: Any?) {
        guard let tab = activeTab, !tab.isReadOnly, let tag = (sender as? NSMenuItem)?.tag else { return }
        let commands = EditCommands(editor: tab.editor)
        let tokens = EditCommands.tokens(for: tab.language)
        switch tag {
        case 0: commands.lineComment(.toggle, tokens: tokens, language: tab.language.name)
        case 1: commands.lineComment(.comment, tokens: tokens, language: tab.language.name)
        case 2: commands.lineComment(.uncomment, tokens: tokens, language: tab.language.name)
        case 3: commands.blockComment(tokens: tokens, language: tab.language.name)
        default: commands.blockUncomment(tokens: tokens, language: tab.language.name)
        }
    }

    /// Copy Current Full File path / Filename / Dir. Path, Copy All Filenames / File Paths. An
    /// untitled document is its tab name ("new 1") and has no directory.
    @IBAction func copyPathToClipboard(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, let text = clipboardText(for: tag) else { return }
        Self.copyToPasteboard(text)
    }

    func clipboardText(for tag: Int) -> String? {
        func path(_ tab: EditorTab) -> String { tab.fileURL?.path ?? tab.displayName }
        func name(_ tab: EditorTab) -> String { tab.fileURL?.lastPathComponent ?? tab.displayName }
        switch tag {
        case 0: return activeTab.map(path)
        case 1: return activeTab.map(name)
        case 2: return activeTab.map { $0.fileURL?.deletingLastPathComponent().path ?? "" }
        case 3: return tabs.items.map { name($0) + "\r\n" }.joined()
        case 4: return tabs.items.map { path($0) + "\r\n" }.joined()
        default: return nil
        }
    }

    @IBAction func readOnlyCommand(_ sender: Any?) {
        switch (sender as? NSMenuItem)?.tag {
        case 0: activeTab.map { $0.isUserReadOnly.toggle() }
        case 1: tabs.items.forEach { $0.isUserReadOnly = true }
        case 2: tabs.items.forEach { $0.isUserReadOnly = false }
        default: break
        }
        refresh()
    }

    @IBAction func toggleFileLocked(_ sender: Any?) {
        guard let tab = activeTab else { return }
        do {
            try tab.setFileLocked(!tab.isFileLocked)
        } catch {
            let alert = NSAlert(error: error)
            if let window { alert.beginSheetModal(for: window) }
        }
        refresh()
    }

    @IBAction func beginEndSelect(_ sender: Any?) { beginEndSelect(column: false) }
    @IBAction func beginEndSelectColumn(_ sender: Any?) { beginEndSelect(column: true) }

    private func beginEndSelect(column: Bool) {
        guard let editor = activeTab?.editor else { return }
        if beginSelectPosition != nil && beginSelectColumnMode != column { return }  // the other one is running
        beginSelectColumnMode = column
        EditCommands.beginOrEndSelect(editor, begin: &beginSelectPosition, columnMode: column)
    }

    // MARK: - Edit › Line / Blank Operations (MAC-39)

    @IBAction func lineOperation(_ sender: Any?) {
        guard let editor = activeTab?.editor, let tag = (sender as? NSMenuItem)?.tag else { return }
        let ops = LineOperations(editor: editor)
        switch tag {
        case 1: ops.duplicateLine()
        case 2: ops.removeDuplicateLines()
        case 3: ops.removeConsecutiveDuplicateLines()
        case 4: ops.splitLines()
        case 5: ops.joinLines()
        case 6: ops.moveLines(up: true)
        case 7: ops.moveLines(up: false)
        case 8: ops.removeEmptyLines(includingBlank: false)
        case 9: ops.removeEmptyLines(includingBlank: true)
        case 10: ops.insertBlankLine(above: true)
        case 11: ops.insertBlankLine(above: false)
        case 20: sort(ops, .reverse)
        case 21: sort(ops, .randomize)
        case 30...46:
            let kinds: [LineOperations.SortKind] = [.lexicographic, .ignoringCase, .locale, .integers, .decimalsComma, .decimalsDot, .length]
            sort(ops, kinds[(tag - 30) % 10], descending: tag >= 40)
        default: break
        }
    }

    private func sort(_ ops: LineOperations, _ kind: LineOperations.SortKind, descending: Bool = false) {
        do {
            try ops.sortLines(kind, descending: descending)
        } catch let error as LineOperations.SortError {
            let alert = NSAlert()
            alert.messageText = "Sort Error"
            alert.informativeText = error.message
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        } catch {}
    }

    @IBAction func blankOperation(_ sender: Any?) {
        guard let editor = activeTab?.editor, let tag = (sender as? NSMenuItem)?.tag else { return }
        let ops = LineOperations(editor: editor)
        switch tag {
        case 1: ops.trim(.trailing)
        case 2: ops.trim(.leading)
        case 3: ops.trim(.both)
        case 4: ops.eolToSpace()
        case 5: ops.trimAndEolToSpace()
        case 6: ops.convertTabs(.tabToSpace)
        case 7: ops.convertTabs(.spaceToTabAll)
        case 8: ops.convertTabs(.spaceToTabLeading)
        default: break
        }
    }

    // MARK: - Function List (MAC-44)

    let functionList = FunctionListPanel()
    private(set) lazy var functionListDock: DockPanel = {
        let dock = DockPanel(title: "Function List", content: functionList)
        dock.addTool(symbol: "arrow.up.arrow.down", tip: "Sort", target: functionList, action: #selector(FunctionListPanel.toggleSort(_:)))
        dock.addTool(symbol: "arrow.clockwise", tip: "Reload", target: self, action: #selector(reloadFunctionListClicked(_:)))
        dock.onClose = { [weak self] in self?.setFunctionListVisible(false) }
        functionList.onJump = { [weak self] editor, position in self?.jumpToFunction(editor, position) }
        return dock
    }()

    var isFunctionListVisible: Bool { isPanelVisible(functionListDock) }

    @IBAction func toggleFunctionList(_ sender: Any?) { setFunctionListVisible(!isFunctionListVisible) }

    func setFunctionListVisible(_ visible: Bool) {
        setPanel(functionListDock, visible: visible, in: rightDock)
        if visible { reloadFunctionList() }
    }

    @objc private func reloadFunctionListClicked(_ sender: Any?) { reloadFunctionList() }

    /// Parses the visible document again (Notepad++: activation, language change, save, Reload).
    func reloadFunctionList() {
        guard isFunctionListVisible, let tab = activeTab else { return }
        functionList.reload(editor: tab.editor, language: tab.language.name, fileName: tab.displayName)
        markFunction()
    }

    /// Another tab or language re-parses; the caret's function stays selected.
    private func refreshFunctionList() {
        guard isFunctionListVisible, let tab = activeTab else { return }
        if functionList.parsedEditor !== tab.editor || functionList.parsedLanguage != tab.language.name {
            reloadFunctionList()
        } else {
            markFunction()
        }
    }

    private func markFunction() {
        guard let editor = activeTab?.editor else { return }
        functionList.markEntry(caretLine: editor.send(SCI_LINEFROMPOSITION, editor.send(SCI_GETCURRENTPOS)))
    }

    /// The caret at the function's name, its line centred, the editor focused (scrollPosToCenter).
    private func jumpToFunction(_ editor: ScintillaView, _ position: Int) {
        let line = editor.send(SCI_LINEFROMPOSITION, position)
        editor.send(SCI_ENSUREVISIBLE, line)
        editor.send(SCI_GOTOPOS, position)
        editor.send(SCI_SETFIRSTVISIBLELINE, max(editor.send(SCI_VISIBLEFROMDOCLINE, line) - editor.send(SCI_LINESONSCREEN) / 2, 0))
        window?.makeFirstResponder(editor)
    }

    // MARK: - Folder as Workspace (MAC-46)

    let workspace = FolderWorkspacePanel()
    private(set) lazy var workspaceDock: DockPanel = {
        let dock = DockPanel(title: "Folder as Workspace", content: workspace)
        dock.addTool(symbol: "scope", tip: "Locate current file", target: workspace, action: #selector(FolderWorkspacePanel.locateCurrentFile(_:)))
        dock.addTool(symbol: "chevron.down.2", tip: "Expand all", target: workspace, action: #selector(FolderWorkspacePanel.expandAll(_:)))
        dock.addTool(symbol: "chevron.up.2", tip: "Collapse all", target: workspace, action: #selector(FolderWorkspacePanel.collapseAll(_:)))
        dock.onClose = { [weak self] in self?.setWorkspaceVisible(false) }
        workspace.onOpenFile = { [weak self] url in self?.open(url) }
        workspace.onFindInFiles = { folder in
            let dialog = AppDelegate.shared.findReplace
            dialog.show(.findInFiles)
            dialog.directoryField.stringValue = folder.path
        }
        workspace.currentFile = { [weak self] in self?.activeTab?.fileURL }
        return dock
    }()

    private static let workspaceVisibleKey = "WorkspaceVisible"
    var isWorkspaceVisible: Bool { isPanelVisible(workspaceDock) }

    @IBAction func toggleWorkspace(_ sender: Any?) { setWorkspaceVisible(!isWorkspaceVisible) }

    func setWorkspaceVisible(_ visible: Bool) {
        setPanel(workspaceDock, visible: visible, in: leftDock)
        AppEnvironment.defaults.set(visible, forKey: Self.workspaceVisibleKey)
    }

    /// File › Open Folder as Workspace…: one or more folders become roots of the panel.
    @IBAction func openFolderAsWorkspace(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.addWorkspaceFolders(panel.urls)
        }
    }

    func addWorkspaceFolders(_ folders: [URL]) {
        workspace.add(folders)
        setWorkspaceVisible(true)
    }

    /// At launch the panel comes back if it was open with folders in it.
    func restoreWorkspace() {
        if AppEnvironment.defaults.bool(forKey: Self.workspaceVisibleKey) && !workspace.roots.isEmpty {
            setWorkspaceVisible(true)
        }
    }

    // MARK: - Document Map (MAC-45)

    let documentMap = DocumentMapPanel()
    private(set) lazy var documentMapDock: DockPanel = {
        let dock = DockPanel(title: "Document Map", content: documentMap)
        dock.onClose = { [weak self] in self?.setDocumentMapVisible(false) }
        return dock
    }()

    var isDocumentMapVisible: Bool { isPanelVisible(documentMapDock) }

    @IBAction func toggleDocumentMap(_ sender: Any?) { setDocumentMapVisible(!isDocumentMapVisible) }

    func setDocumentMapVisible(_ visible: Bool) {
        setPanel(documentMapDock, visible: visible, in: rightDock, width: 200)
        if visible { refreshDocumentMap(reattach: true) } else { documentMap.attach(to: nil, language: nil) }
    }

    /// Follows the visible tab and its scrolling.
    private func refreshDocumentMap(reattach: Bool = false) {
        guard isDocumentMapVisible, let tab = activeTab else { return }
        if reattach || documentMap.editor !== tab.editor {
            documentMap.attach(to: tab.editor, language: tab.language)
        } else {
            documentMap.sync()
        }
    }

    // MARK: - Docked panels (milestone 6)

    /// Shows or hides a docked panel; a dock with nothing visible takes no room.
    func setPanel(_ panel: NSView, visible: Bool, in dock: NSSplitView, width: CGFloat = 260) {
        if visible && panel.superview !== dock { dock.addArrangedSubview(panel) }
        panel.isHidden = !visible
        let wasHidden = dock.isHidden
        dock.isHidden = !dock.arrangedSubviews.contains { !$0.isHidden }
        dock.adjustSubviews()
        dockSplit.adjustSubviews()
        if wasHidden && !dock.isHidden {
            window?.contentView?.layoutSubtreeIfNeeded()
            let total = dockSplit.bounds.width
            if dock === leftDock {
                dockSplit.setPosition(width, ofDividerAt: 0)
            } else {
                dockSplit.setPosition(total - width, ofDividerAt: 1)
            }
        }
    }

    func isPanelVisible(_ panel: NSView) -> Bool { panel.superview != nil && !panel.isHidden }

    // MARK: - Themes (MAC-36)

    /// Every editor and the Search results panel take the selected theme.
    func applyTheme() {
        tabs.items.forEach { $0.reapplyTheme() }
        refreshDocumentMap(reattach: true)
        searchResults.applyCurrentTheme()
        refresh()
    }

    // MARK: - Language menu (MAC-35)

    /// Language › <language>: the tab is re-lexed and keeps that language in the session.
    @IBAction func selectLanguage(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String,
              let info = LanguageCatalog.shared.language(named: name), let tab = activeTab else { return }
        tab.setLanguage(info)
        refresh()
        persistSession()
    }

    /// A click on the status bar's language opens the same menu there.
    private func showLanguageMenu(at label: NSView) {
        let menu = MainMenu.languageMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: label.bounds.height + 4), in: label)
    }

    // MARK: - Incremental search (MAC-34)

    @IBAction func showIncrementalSearch(_ sender: Any?) {
        if incrementalBar.hasFocus { incrementalBar.next() } else { incrementalBar.open() }
    }

    // MARK: - Search results (MAC-32)

    /// What Find All searches: every tab, named by its file path or, untitled, by its tab name.
    var searchDocuments: [SearchDocument] { tabs.items.map(Self.searchDocument) }
    var activeSearchDocument: SearchDocument? { activeTab.map(Self.searchDocument) }

    private static func searchDocument(_ tab: EditorTab) -> SearchDocument {
        SearchDocument(editor: tab.editor, path: tab.fileURL?.standardizedFileURL.path ?? tab.displayName,
                       save: { [weak tab] in tab?.save() })
    }

    var isSearchResultsVisible: Bool { !searchResults.isHidden }
    /// The editor area's height, for the split between it and the results panel.
    var editorAreaHeight: CGFloat { editorContainer.frame.height }

    func showSearchResults(_ block: SearchResultsBlock) {
        setSearchResultsVisible(true)
        searchResults.show(block)
        if block.hitCount > 0 { window?.makeFirstResponder(searchResults.pane) }
    }

    func setSearchResultsVisible(_ visible: Bool) {
        guard visible != isSearchResultsVisible else { return }
        searchResults.isHidden = !visible
        splitView.adjustSubviews()
        if visible {
            // The editor keeps about two thirds of the height, as Notepad++'s docked panel leaves it.
            window?.contentView?.layoutSubtreeIfNeeded()
            splitView.setPosition((splitView.bounds.height * 0.68).rounded(), ofDividerAt: 0)
            splitView.layoutSubtreeIfNeeded()
        } else {
            activeTab.map { window?.makeFirstResponder($0.editor) }
        }
    }

    /// Opens the hit's document (switching tab, or opening the file again) and selects the hit.
    func openSearchHit(_ hit: SearchResultHit, rangeIndex: Int) {
        guard let tab = tabFor(searchPath: hit.path) else { NSSound.beep(); return }
        let editor = tab.editor
        let length = editor.send(SCI_GETLENGTH)
        let range = hit.ranges[max(0, min(rangeIndex, hit.ranges.count - 1))]
        let start = min(range.lowerBound, length), end = min(range.upperBound, length)
        editor.send(SCI_ENSUREVISIBLE, editor.send(SCI_LINEFROMPOSITION, start))
        editor.send(SCI_GOTOPOS, end)
        editor.send(SCI_SETANCHOR, start)
        editor.send(SCI_SCROLLRANGE, start, end)
        window?.makeFirstResponder(editor)
    }

    func openSearchPath(_ path: String) { _ = tabFor(searchPath: path) }

    private func tabFor(searchPath path: String) -> EditorTab? {
        if let index = tabs.firstIndex(where: { Self.searchDocument($0).path == path }) {
            selectTab(at: index)
            return activeTab
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        open(URL(fileURLWithPath: path))
        return tabs.items.first { $0.fileURL?.standardizedFileURL.path == path }
    }

    @IBAction func toggleSearchResultsWindow(_ sender: Any?) {
        if isSearchResultsVisible && window?.firstResponder.map({ ($0 as? NSView)?.isDescendant(of: searchResults) == true }) == true {
            setSearchResultsVisible(false)
        } else {
            setSearchResultsVisible(true)
            window?.makeFirstResponder(searchResults.pane)
        }
    }
    @IBAction func nextSearchResult(_ sender: Any?) {
        setSearchResultsVisible(true)
        searchResults.step(forward: true)
    }
    @IBAction func previousSearchResult(_ sender: Any?) {
        setSearchResultsVisible(true)
        searchResults.step(forward: false)
    }

    // MARK: - Search › token styles and bookmarks (MAC-31)

    private var marker: Marker? { activeTab.map { Marker(editor: $0.editor) } }

    /// Menu tags 0–4 are the five styles; 5 is "all styles" or the Find Mark, 6 the Find Mark.
    private func styleIndicator(_ sender: Any?) -> Int? {
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        return tag < 5 ? MarkIndicator.styles[tag] : (tag == 5 ? MarkIndicator.findMark : nil)
    }

    @IBAction func styleAllOccurrences(_ sender: Any?) {
        marker?.styleAllOccurrences(style: min((sender as? NSMenuItem)?.tag ?? 0, 4))
    }
    @IBAction func styleOneToken(_ sender: Any?) { marker?.styleOneToken(style: min((sender as? NSMenuItem)?.tag ?? 0, 4)) }
    @IBAction func clearStyle(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        tag < 5 ? marker?.clearStyle(MarkIndicator.styles[tag]) : marker?.clearAllStyles()
    }
    @IBAction func jumpUp(_ sender: Any?) {
        if let indicator = styleIndicator(sender), marker?.jump(to: indicator, down: false) != true { NSSound.beep() }
    }
    @IBAction func jumpDown(_ sender: Any?) {
        if let indicator = styleIndicator(sender), marker?.jump(to: indicator, down: true) != true { NSSound.beep() }
    }
    @IBAction func copyStyledText(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        let indicators = tag < 5 ? [MarkIndicator.styles[tag]] : (tag == 5 ? MarkIndicator.styles : [MarkIndicator.findMark])
        if let text = marker?.markedText(indicators) { Self.copyToPasteboard(text) }
    }

    @IBAction func toggleBookmark(_ sender: Any?) { marker?.toggleBookmark() }
    @IBAction func nextBookmark(_ sender: Any?) { marker?.gotoBookmark(next: true) }
    @IBAction func previousBookmark(_ sender: Any?) { marker?.gotoBookmark(next: false) }
    @IBAction func clearAllBookmarks(_ sender: Any?) { marker?.clearAllBookmarks() }
    @IBAction func copyBookmarkedLines(_ sender: Any?) {
        if let text = marker?.bookmarkedLinesText() { Self.copyToPasteboard(text) }
    }
    @IBAction func cutBookmarkedLines(_ sender: Any?) {
        if let text = marker?.cutBookmarkedLines() { Self.copyToPasteboard(text) }
    }
    @IBAction func pasteToBookmarkedLines(_ sender: Any?) {
        guard let text = AppEnvironment.pasteboard.string(forType: .string) else { return }
        marker?.replaceBookmarkedLines(with: text)
    }
    @IBAction func removeBookmarkedLines(_ sender: Any?) { marker?.removeBookmarkedLines() }
    @IBAction func removeUnbookmarkedLines(_ sender: Any?) { marker?.removeUnbookmarkedLines() }
    @IBAction func inverseBookmarks(_ sender: Any?) { marker?.inverseBookmarks() }

    static func copyToPasteboard(_ text: String) {
        AppEnvironment.pasteboard.clearContents()
        AppEnvironment.pasteboard.setString(text, forType: .string)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let editor = activeTab?.editor else { return false }
        switch item.action {
        case #selector(toggleWordWrap(_:)):
            item.state = editor.send(SCI_GETWRAPMODE) != Int(SC_WRAP_NONE) ? .on : .off
        case #selector(toggleShowAllCharacters(_:)):
            item.state = editor.send(SCI_GETVIEWWS) != Int(SCWS_INVISIBLE) ? .on : .off
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)):
            return tabs.count > 1
        case #selector(convertCase(_:)):
            return editor.send(SCI_GETSELECTIONEMPTY) == 0 && activeTab?.isReadOnly == false
        case #selector(readOnlyCommand(_:)):
            if item.tag == 0 { item.state = activeTab?.isUserReadOnly == true ? .on : .off }
            return activeTab?.isMonitoring != true && (item.tag != 0 || activeTab?.isFileLocked != true)
        case #selector(toggleFileLocked(_:)):
            item.state = activeTab?.isFileLocked == true ? .on : .off
            return activeTab?.fileURL != nil
        case #selector(beginEndSelect(_:)), #selector(beginEndSelectColumn(_:)):
            let running = beginSelectPosition != nil
            let mine = item.action == #selector(beginEndSelectColumn(_:)) ? beginSelectColumnMode : !beginSelectColumnMode
            item.state = running && mine ? .on : .off
            return !running || mine
        case #selector(commentCommand(_:)), #selector(changeIndent(_:)), #selector(lineOperation(_:)), #selector(blankOperation(_:)):
            return activeTab?.isReadOnly == false
        case #selector(toggleWorkspace(_:)):
            item.state = isWorkspaceVisible ? .on : .off
        case #selector(toggleDocumentMap(_:)):
            item.state = isDocumentMapVisible ? .on : .off
        case #selector(toggleFunctionList(_:)):
            item.state = isFunctionListVisible ? .on : .off
        case #selector(selectLanguage(_:)):
            item.state = (item.representedObject as? String) == activeTab?.language.name ? .on : .off
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
        refreshFunctionList()
        refreshDocumentMap()
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
        if isWorkspaceVisible { workspace.refresh() }  // files may have changed while away
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

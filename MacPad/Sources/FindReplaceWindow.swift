import AppKit

/// Notepad++'s Find / Replace dialog (MAC-30, Mark tab MAC-31, Find in Files MAC-33): one
/// modeless panel with Find, Replace, Find in Files and Mark tabs,
/// the same options and search modes, and the status line under the buttons. The menu's Find
/// Next / Find Previous use the panel's text and options even while it is closed, as F3 does.
final class FindReplaceController: NSWindowController, NSWindowDelegate, NSComboBoxDelegate {
    enum Tab: Int { case find, replace, findInFiles, mark }

    /// The editor the dialog acts on: the main window's visible tab.
    var editorProvider: () -> ScintillaView?
    /// Find All's documents: the active one and every open one (MAC-32).
    var documentsProvider: () -> (current: SearchDocument?, all: [SearchDocument]) = { (nil, []) }
    /// Where Find All's results go: the main window's Search results panel.
    var resultsSink: (SearchResultsBlock) -> Void = { _ in }
    /// Notepad++ asks before replacing in every open document.
    /// Notepad++'s Replace in Files question; Cancel is the default answer.
    var confirmReplaceInFiles: (_ directory: String, _ filters: String) -> Bool = { directory, filters in
        let alert = NSAlert()
        alert.messageText = "Are you sure?"
        alert.informativeText = "Are you sure you want to replace all occurrences in:\n\n\(directory)\n\nFor file type:\n\n\(filters)"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Replace")
        return alert.runModal() == .alertSecondButtonReturn
    }
    /// Find in Files runs a few files per main-loop turn behind a progress window; the tests run
    /// it in one go.
    var runsFindInFilesSynchronously = false
    private var progress: FindInFilesProgress?
    private(set) var runningJob: FindInFilesJob?
    var confirmReplaceInOpenedFiles: () -> Bool = {
        let alert = NSAlert()
        alert.messageText = "Are you sure?"
        alert.informativeText = "Are you sure you want to replace all occurrences in all open documents?"
        alert.addButton(withTitle: "Replace All")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private let defaults: UserDefaults

    private(set) var options: SearchOptions { didSet { syncControls(); saveState() } }
    private(set) var findHistory: FindHistory
    private(set) var replaceHistory: FindHistory
    private(set) var filterHistory: FindHistory
    private(set) var directoryHistory: FindHistory
    private(set) var status: SearchStatus?
    private(set) var tab: Tab = .find

    // Controls (internal so the tests can drive the dialog the way a user does).
    let tabs = NSSegmentedControl(labels: ["Find", "Replace", "Find in Files", "Mark"], trackingMode: .selectOne, target: nil, action: nil)
    let findField = NSComboBox()
    let replaceField = NSComboBox()
    private let replaceLabel = NSTextField(labelWithString: "Replace with:")
    let filtersField = NSComboBox()
    let directoryField = NSComboBox()
    let browseButton = NSButton(title: "…", target: nil, action: nil)
    let fillDirectoryButton = NSButton(title: "<<", target: nil, action: nil)
    let subfoldersBox = NSButton(checkboxWithTitle: "In all sub-folders", target: nil, action: nil)
    let hiddenFoldersBox = NSButton(checkboxWithTitle: "In hidden folders", target: nil, action: nil)
    let findInFilesButton = NSButton(title: "Find All", target: nil, action: nil)
    let replaceInFilesButton = NSButton(title: "Replace in Files", target: nil, action: nil)
    private var fieldsGrid: NSGridView?
    let inSelectionBox = NSButton(checkboxWithTitle: "In selection", target: nil, action: nil)
    let backwardBox = NSButton(checkboxWithTitle: "Backward direction", target: nil, action: nil)
    let wholeWordBox = NSButton(checkboxWithTitle: "Match whole word only", target: nil, action: nil)
    let matchCaseBox = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    let wrapBox = NSButton(checkboxWithTitle: "Wrap around", target: nil, action: nil)
    let normalRadio = NSButton(radioButtonWithTitle: "Normal", target: nil, action: nil)
    let extendedRadio = NSButton(radioButtonWithTitle: "Extended (\\n, \\r, \\t, \\0, \\x…)", target: nil, action: nil)
    let regexRadio = NSButton(radioButtonWithTitle: "Regular expression", target: nil, action: nil)
    let dotNewlineBox = NSButton(checkboxWithTitle: ". matches newline", target: nil, action: nil)
    let bookmarkLineBox = NSButton(checkboxWithTitle: "Bookmark line", target: nil, action: nil)
    let purgeBox = NSButton(checkboxWithTitle: "Purge for each search", target: nil, action: nil)
    let markAllButton = NSButton(title: "Mark All", target: nil, action: nil)
    let clearMarksButton = NSButton(title: "Clear all marks", target: nil, action: nil)
    let copyMarkedButton = NSButton(title: "Copy Marked Text", target: nil, action: nil)
    let findNextButton = NSButton(title: "Find Next", target: nil, action: nil)
    let countButton = NSButton(title: "Count", target: nil, action: nil)
    let replaceButton = NSButton(title: "Replace", target: nil, action: nil)
    let replaceAllButton = NSButton(title: "Replace All", target: nil, action: nil)
    let findAllCurrentButton = NSButton(title: "Find All in Current Document", target: nil, action: nil)
    let findAllOpenedButton = NSButton(title: "Find All in All Opened Documents", target: nil, action: nil)
    let replaceAllOpenedButton = NSButton(title: "Replace All in All Opened Documents", target: nil, action: nil)
    let statusLabel = NSTextField(labelWithString: "")

    private static let optionsKey = "FindOptions"
    private static let findHistoryKey = "FindHistory"
    private static let replaceHistoryKey = "ReplaceHistory"
    private static let filterHistoryKey = "FindInFilesFilterHistory"
    private static let directoryHistoryKey = "FindInFilesDirectoryHistory"

    init(defaults: UserDefaults = AppEnvironment.defaults, editorProvider: @escaping () -> ScintillaView?) {
        self.defaults = defaults
        self.editorProvider = editorProvider
        options = (defaults.data(forKey: Self.optionsKey)).flatMap { try? JSONDecoder().decode(SearchOptions.self, from: $0) }
            ?? SearchOptions()
        options.inSelection = false  // Notepad++ decides In selection from the selection each time
        findHistory = FindHistory(defaults.stringArray(forKey: Self.findHistoryKey) ?? [])
        replaceHistory = FindHistory(defaults.stringArray(forKey: Self.replaceHistoryKey) ?? [])
        filterHistory = FindHistory(defaults.stringArray(forKey: Self.filterHistoryKey) ?? [])
        directoryHistory = FindHistory(defaults.stringArray(forKey: Self.directoryHistoryKey) ?? [])
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        buildLayout()
        reloadHistoryLists()
        syncControls()
        setTab(.find)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Opening

    /// Search › Find… / Replace…: seeds Find what from the selection (or the word at the caret),
    /// focuses it with its text selected.
    func show(_ tab: Tab) {
        seedFromSelection()
        setTab(tab)
        updateSelectionDependentControls(autoCheck: true)
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeFirstResponder(findField)
        findField.currentEditor()?.selectAll(nil)
    }

    /// Notepad++'s setSearchTextWithSettings: 1 to 1024 characters of selection; with no
    /// selection the word at the caret is selected and used.
    private func seedFromSelection() {
        guard let editor = editorProvider(), let text = Self.seedText(from: editor) else { return }
        findField.stringValue = text
    }

    static let seedLengthLimit = 1024

    static func seedText(from editor: ScintillaView) -> String? {
        var start = editor.send(SCI_GETSELECTIONSTART), end = editor.send(SCI_GETSELECTIONEND)
        if start == end {
            start = editor.send(SCI_WORDSTARTPOSITION, start, 1)
            end = editor.send(SCI_WORDENDPOSITION, end, 1)
            guard end > start else { return nil }
            editor.send(SCI_SETSEL, start, end)
        }
        let text = String(decoding: editor.utf8Bytes()[start..<end], as: UTF8.self)
        return (1...seedLengthLimit).contains(text.count) ? text : nil
    }

    // MARK: - Commands

    /// Find Next (Return, the button, ⌘G) or, reversed, Find Previous (Shift-Return, ⇧⌘G).
    func findNext(reversed: Bool = false) {
        guard let editor = editorProvider() else { return }
        let text = findField.stringValue
        guard !text.isEmpty else { show(.find); return }
        var opts = options
        if reversed {
            guard opts.mode != .regex else { report(SearchMessages.regexBackward); return }
            opts.backward.toggle()
        }
        let outcome = SearchEngine(editor: editor).findNext(text, options: opts)
        remember(find: text)
        switch outcome {
        case .found(_, let wrapped):
            report(wrapped ? (opts.effectiveBackward ? SearchMessages.topReached : SearchMessages.endReached) : nil)
        case .notFound:
            report(SearchMessages.cantFind(text, scope: findScope(opts)), hint: SearchMessages.hint(for: opts))
        case .invalidRegex:
            report(SearchMessages.invalidRegex)
        }
    }

    func replace() {
        guard let editor = editorProvider() else { return }
        let text = findField.stringValue, replacement = replaceField.stringValue
        guard !text.isEmpty else { return }
        remember(find: text, replace: replacement)
        switch SearchEngine(editor: editor).replace(text, with: replacement, options: options) {
        case .readOnly: report(SearchMessages.replaceReadOnly)
        case .invalidRegex: report(SearchMessages.invalidRegex)
        case .notFound: report(SearchMessages.replaceNotFound(scope: findScope(options)), hint: SearchMessages.hint(for: options))
        case .foundOnly: report(nil)
        case .replaced(let next):
            switch next {
            case .found(_, wrapped: true):
                report(options.effectiveBackward ? SearchMessages.replaceTopReached : SearchMessages.replaceEndReached)
            case .found: report(SearchMessages.replacedNextFound)
            case .notFound: report(SearchMessages.replacedNoMore)
            case .invalidRegex: report(SearchMessages.invalidRegex)
            }
        }
    }

    func replaceAll() {
        guard let editor = editorProvider() else { return }
        let text = findField.stringValue, replacement = replaceField.stringValue
        guard !text.isEmpty else { return }
        remember(find: text, replace: replacement)
        switch SearchEngine(editor: editor).replaceAll(text, with: replacement, options: options) {
        case .readOnly: report(SearchMessages.replaceAllReadOnly)
        case .invalidRegex: report(SearchMessages.invalidRegex)
        case .done(let n, let scope): report(SearchMessages.replacedAll(n, scope: scope))
        }
        updateSelectionDependentControls(autoCheck: false)
    }

    func count() {
        guard let editor = editorProvider() else { return }
        let text = findField.stringValue
        guard !text.isEmpty else { return }
        remember(find: text)
        switch SearchEngine(editor: editor).count(text, options: options) {
        case .invalidRegex: report(SearchMessages.invalidRegex)
        case .readOnly: break
        case .done(let n, let scope):
            report(SearchMessages.count(n, scope: scope), hint: n == 0 ? SearchMessages.hint(for: options) : nil)
        }
    }

    /// Find All in Current Document / in All Opened Documents: the hits go to the Search results
    /// panel, newest search on top. With hits the dialog steps aside, as Notepad++'s does.
    func findAll(inOpenedDocuments: Bool) {
        let text = findField.stringValue
        guard !text.isEmpty else { return }
        let (current, all) = documentsProvider()
        let documents = inOpenedDocuments ? all : current.map { [$0] } ?? []
        guard !documents.isEmpty else { return }
        remember(find: text)
        var opts = options
        if inOpenedDocuments { opts.inSelection = false }
        var files: [SearchResultsFile] = []
        var total = 0
        for document in documents {
            switch SearchEngine(editor: document.editor).findAll(text, options: opts, path: document.path) {
            case .invalidRegex:
                report(SearchMessages.invalidRegex)
                return
            case .found(let hits) where !hits.isEmpty:
                let count = hits.reduce(0) { $0 + $1.ranges.count }
                files.append(SearchResultsFile(path: document.path, header: SearchResultsFormat.fileHeader(path: document.path, hits: count), hits: hits))
                total += count
            case .found:
                break
            }
        }
        let header = SearchResultsFormat.searchHeader(term: text, hits: total, files: files.count, searched: documents.count,
                                                      inSelection: !inOpenedDocuments && isLimitedToSelection(documents[0].editor, opts),
                                                      options: opts)
        report(nil)
        resultsSink(SearchResultsBlock(header: header, files: files, hitCount: total))
        if total > 0 { close() }
    }

    /// In selection narrows Find All only when the selection is not the whole document.
    private func isLimitedToSelection(_ editor: ScintillaView, _ opts: SearchOptions) -> Bool {
        guard opts.inSelection, SearchEngine(editor: editor).hasUsableSelection else { return false }
        return !(editor.send(SCI_GETSELECTIONSTART) == 0 && editor.send(SCI_GETSELECTIONEND) == editor.send(SCI_GETLENGTH))
    }

    /// Replace All in All Opened Documents: every editable document, whole, one undo step each.
    func replaceAllInOpenedDocuments() {
        let text = findField.stringValue, replacement = replaceField.stringValue
        guard !text.isEmpty, confirmReplaceInOpenedFiles() else { return }
        remember(find: text, replace: replacement)
        var opts = options
        opts.inSelection = false
        opts.wrapAround = true
        var total = 0
        for document in documentsProvider().all where document.editor.send(SCI_GETREADONLY) == 0 {
            switch SearchEngine(editor: document.editor).replaceAll(text, with: replacement, options: opts) {
            case .invalidRegex:
                report(SearchMessages.invalidRegex)
                return
            case .done(let n, _): total += n
            case .readOnly: break
            }
        }
        report(SearchMessages.replacedInOpenedFiles(total))
    }

    // MARK: - Find in Files (MAC-33)

    /// The directory of the active document, when it has one ("<<").
    func fillDirectoryFromActiveDocument() {
        guard let path = documentsProvider().current?.path, path.hasPrefix("/") else { return }
        let directory = (path as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue {
            directoryField.stringValue = directory
        }
    }

    /// Find All / Replace in Files: every file under Directory matching Filters. Open documents
    /// are searched in their editor (unsaved edits included) and saved after a replace.
    func findInFiles(replacing: Bool) {
        guard runningJob == nil else { return }
        let text = findField.stringValue, replacement = replaceField.stringValue
        let directory = (directoryField.stringValue as NSString).expandingTildeInPath
            .trimmingCharacters(in: .whitespaces)
        var isDirectory: ObjCBool = false
        guard !directory.isEmpty, FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            NSSound.beep()
            window?.makeFirstResponder(directoryField)
            return
        }
        let filter = FileFilter(filtersField.stringValue)
        filtersField.stringValue = filter.text
        if replacing && !confirmReplaceInFiles(directoryField.stringValue, filter.text) { return }
        remember(find: text, replace: replacing ? replacement : nil)
        filterHistory.add(filter.text)
        directoryHistory.add(directoryField.stringValue)
        reloadHistoryLists()
        saveState()

        let opts = options
        let open = Dictionary(documentsProvider().all.compactMap { document -> (String, FindInFilesJob.OpenDocument)? in
            guard document.path.hasPrefix("/") else { return nil }
            let key = URL(fileURLWithPath: document.path).resolvingSymlinksInPath().path
            return (key, FindInFilesJob.OpenDocument(editor: document.editor, save: document.save ?? {}))
        }, uniquingKeysWith: { first, _ in first })
        let makeJob: ([URL]) -> FindInFilesJob = { files in
            FindInFilesJob(text: text, kind: replacing ? .replace(replacement) : .findAll, options: opts, files: files) {
                open[$0.resolvingSymlinksInPath().path]
            }
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)

        if runsFindInFilesSynchronously {
            let files = FileCollector.files(in: root, filter: filter, recursive: opts.inAllSubfolders,
                                            includeHiddenFolders: opts.inHiddenFolders) ?? []
            finish(makeJob(files).runToCompletion())
            return
        }

        let progress = FindInFilesProgress(title: replacing ? "Replace In Files progress..." : "Find In Files progress...")
        self.progress = progress
        let cancelled = CancelFlag()
        progress.onCancel = { [weak self] in
            cancelled.set()
            self?.runningJob?.cancel()
        }
        progress.showDiscovering(directory)
        progress.window?.center()
        progress.showWindow(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let files = FileCollector.files(in: root, filter: filter, recursive: opts.inAllSubfolders,
                                            includeHiddenFolders: opts.inHiddenFolders, isCancelled: { cancelled.isSet })
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let files, !cancelled.isSet else { self.endProgress(); return }
                let job = makeJob(files)
                self.runningJob = job
                if files.count <= 1 { progress.window?.orderOut(nil) }  // shown only for several files
                self.pump(job)
            }
        }
    }

    /// Runs the job a slice at a time so the progress window updates and Cancel is heard.
    private func pump(_ job: FindInFilesJob) {
        let more = job.step()
        progress?.update(file: job.currentFile?.path ?? "", hits: job.hits, done: job.index, total: job.files.count)
        if more {
            DispatchQueue.main.async { [weak self] in self?.pump(job) }
        } else {
            runningJob = nil
            endProgress()
            finish(job.outcome)
        }
    }

    private func endProgress() {
        progress?.close()
        progress = nil
    }

    private func finish(_ outcome: FindInFilesJob.Outcome) {
        switch outcome {
        case .invalidRegex:
            report(SearchMessages.invalidRegex)
        case .found(let block):
            report(nil)
            resultsSink(block)
            if block.hitCount > 0 { close() }
        case .replaced(let n, let failed):
            report(SearchMessages.replacedInFiles(n), hint: failed.isEmpty ? nil : "Could not write:\n" + failed.joined(separator: "\n"))
        case .cancelled:
            report(nil)
        }
    }

    @objc private func findInFilesClicked(_ sender: Any?) { findInFiles(replacing: false) }
    @objc private func replaceInFilesClicked(_ sender: Any?) { findInFiles(replacing: true) }
    @objc private func fillDirectoryClicked(_ sender: Any?) { fillDirectoryFromActiveDocument() }

    @objc private func browseClicked(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let current = (directoryField.stringValue as NSString).expandingTildeInPath
        if !current.isEmpty { panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true) }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.directoryField.stringValue = url.path }
        }
    }

    /// Mark All: the Find Mark indicator on every match (bookmarking their lines when asked).
    func markAll() {
        guard let editor = editorProvider() else { return }
        let text = findField.stringValue
        guard !text.isEmpty else { return }
        remember(find: text)
        switch Marker(editor: editor).markAll(text, options: options, bookmarkLine: options.bookmarkLine, purge: options.purge) {
        case .invalidRegex: report(SearchMessages.invalidRegex)
        case .readOnly: break
        case .done(let n, let scope):
            report(SearchMessages.marked(n, scope: scope), hint: n == 0 ? SearchMessages.hint(for: options) : nil)
        }
    }

    func clearMarks() {
        guard let editor = editorProvider() else { return }
        let marker = Marker(editor: editor)
        marker.clearMarks(inSelection: options.inSelection && SearchEngine(editor: editor).hasUsableSelection,
                          bookmarkLine: options.bookmarkLine)
        report(nil)
    }

    func copyMarkedText() {
        guard let editor = editorProvider(), let text = Marker(editor: editor).markedText([MarkIndicator.findMark]) else { return }
        MainWindowController.copyToPasteboard(text)
    }

    /// ⌘E (Use Selection for Find): the selection becomes Find what, without opening the panel.
    func useSelectionForFind() {
        guard let editor = editorProvider(), let text = Self.seedText(from: editor) else { NSSound.beep(); return }
        findField.stringValue = text
    }

    /// Select and Find Next / Previous (Notepad++'s Ctrl+F3): the selection or the word at the
    /// caret becomes Find what, searched in Normal mode with the dialog's case, word and wrap options.
    func selectAndFindNext(reversed: Bool) {
        guard let editor = editorProvider(), let text = Self.seedText(from: editor) else { NSSound.beep(); return }
        findField.stringValue = text
        var opts = options
        opts.mode = .normal
        opts.backward = reversed
        let outcome = SearchEngine(editor: editor).findNext(text, options: opts)
        remember(find: text)
        switch outcome {
        case .found(_, let wrapped):
            report(wrapped ? (reversed ? SearchMessages.topReached : SearchMessages.endReached) : nil)
        case .notFound, .invalidRegex:
            report(SearchMessages.cantFind(text, scope: findScope(opts)))
        }
    }

    // MARK: - State

    private func findScope(_ opts: SearchOptions) -> SearchScope {
        opts.wrapAround ? .entireFile : (opts.effectiveBackward ? .startToCaret : .caretToEnd)
    }

    private func report(_ newStatus: SearchStatus?, hint: String? = nil) {
        status = newStatus
        statusLabel.stringValue = newStatus?.text ?? ""
        statusLabel.textColor = newStatus?.kind.color ?? .secondaryLabelColor
        statusLabel.toolTip = hint
        if newStatus?.kind == .notFound { NSSound.beep() }
    }

    private func remember(find: String, replace: String? = nil) {
        findHistory.add(find)
        if let replace { replaceHistory.add(replace) }
        reloadHistoryLists()
        saveState()
    }

    private func reloadHistoryLists() {
        for (field, history) in [(findField, findHistory), (replaceField, replaceHistory),
                                 (filtersField, filterHistory), (directoryField, directoryHistory)] {
            let text = field.stringValue
            field.removeAllItems()
            field.addItems(withObjectValues: history.items)
            field.stringValue = text
        }
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: Self.optionsKey) }
        defaults.set(findHistory.saved, forKey: Self.findHistoryKey)
        defaults.set(replaceHistory.saved, forKey: Self.replaceHistoryKey)
        defaults.set(filterHistory.saved, forKey: Self.filterHistoryKey)
        defaults.set(directoryHistory.saved, forKey: Self.directoryHistoryKey)
    }

    func setTab(_ newTab: Tab) {
        tab = newTab
        tabs.selectedSegment = newTab.rawValue
        let replacing = newTab == .replace, marking = newTab == .mark, inFiles = newTab == .findInFiles
        window?.title = ["Find", "Replace", "Find in Files", "Mark"][newTab.rawValue]
        fieldsGrid?.row(at: 1).isHidden = !(replacing || inFiles)
        fieldsGrid?.row(at: 2).isHidden = !inFiles
        fieldsGrid?.row(at: 3).isHidden = !inFiles
        replaceButton.isHidden = !replacing
        replaceAllButton.isHidden = !replacing
        countButton.isHidden = newTab != .find
        findAllCurrentButton.isHidden = newTab != .find
        findAllOpenedButton.isHidden = newTab != .find
        replaceAllOpenedButton.isHidden = !replacing
        findNextButton.isHidden = marking || inFiles
        for view in [bookmarkLineBox, purgeBox, markAllButton, clearMarksButton, copyMarkedButton] as [NSView] {
            view.isHidden = !marking
        }
        for view in [subfoldersBox, hiddenFoldersBox, findInFilesButton, replaceInFilesButton] as [NSView] {
            view.isHidden = !inFiles
        }
        // Notepad++'s Find in Files tab has no direction, wrap or selection.
        for view in [backwardBox, wrapBox, inSelectionBox] as [NSView] { view.isHidden = inFiles }
        if inFiles && directoryField.stringValue.isEmpty { fillDirectoryFromActiveDocument() }
        fitWindowToContent()
    }

    /// The panel is as big as its content needs (the margins included), whatever the tab.
    func fitWindowToContent() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)  // keep the top edge
        window.setFrame(frame, display: true)
    }

    /// In selection needs a single, non-empty stream selection; Notepad++ ticks it by itself when
    /// the dialog opens on a selection of 1024 characters or more.
    func updateSelectionDependentControls(autoCheck: Bool) {
        guard let editor = editorProvider() else { return }
        let usable = SearchEngine(editor: editor).hasUsableSelection
        inSelectionBox.isEnabled = usable
        if !usable {
            options.inSelection = false
        } else if autoCheck {
            let length = editor.send(SCI_GETSELECTIONEND) - editor.send(SCI_GETSELECTIONSTART)
            if length >= Self.seedLengthLimit { options.inSelection = true }
        }
    }

    private func syncControls() {
        inSelectionBox.state = options.inSelection ? .on : .off
        backwardBox.state = options.effectiveBackward ? .on : .off
        backwardBox.isEnabled = options.mode != .regex
        wholeWordBox.state = options.effectiveWholeWord ? .on : .off
        wholeWordBox.isEnabled = options.mode != .regex
        matchCaseBox.state = options.matchCase ? .on : .off
        wrapBox.state = options.wrapAround ? .on : .off
        normalRadio.state = options.mode == .normal ? .on : .off
        extendedRadio.state = options.mode == .extended ? .on : .off
        regexRadio.state = options.mode == .regex ? .on : .off
        dotNewlineBox.state = options.effectiveDotMatchesNewline ? .on : .off
        dotNewlineBox.isEnabled = options.mode == .regex
        subfoldersBox.state = options.inAllSubfolders ? .on : .off
        hiddenFoldersBox.state = options.inHiddenFolders ? .on : .off
        bookmarkLineBox.state = options.bookmarkLine ? .on : .off
        purgeBox.state = options.purge ? .on : .off
    }

    @objc private func optionChanged(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender {
        case inSelectionBox: options.inSelection = on
        case backwardBox: options.backward = on
        case wholeWordBox: options.wholeWord = on
        case matchCaseBox: options.matchCase = on
        case wrapBox: options.wrapAround = on
        case dotNewlineBox: options.dotMatchesNewline = on
        case bookmarkLineBox: options.bookmarkLine = on
        case purgeBox: options.purge = on
        case subfoldersBox: options.inAllSubfolders = on
        case hiddenFoldersBox: options.inHiddenFolders = on
        case normalRadio: options.mode = .normal
        case extendedRadio: options.mode = .extended
        case regexRadio: options.mode = .regex
        default: break
        }
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        setTab(Tab(rawValue: sender.selectedSegment) ?? .find)
    }

    @objc private func findNextClicked(_ sender: Any?) {
        findNext(reversed: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
    }
    @objc private func countClicked(_ sender: Any?) { count() }
    @objc private func replaceClicked(_ sender: Any?) { replace() }
    @objc private func replaceAllClicked(_ sender: Any?) { replaceAll() }
    @objc private func markAllClicked(_ sender: Any?) { markAll() }
    @objc private func findAllCurrentClicked(_ sender: Any?) { findAll(inOpenedDocuments: false) }
    @objc private func findAllOpenedClicked(_ sender: Any?) { findAll(inOpenedDocuments: true) }
    @objc private func replaceAllOpenedClicked(_ sender: Any?) { replaceAllInOpenedDocuments() }
    @objc private func clearMarksClicked(_ sender: Any?) { clearMarks() }
    @objc private func copyMarkedClicked(_ sender: Any?) { copyMarkedText() }

    // Return in either field is Find Next; Shift-Return searches the other way once.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if tab == .findInFiles { findInFiles(replacing: false) } else if tab == .mark { markAll() } else { findNext(reversed: NSApp.currentEvent?.modifierFlags.contains(.shift) == true) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateSelectionDependentControls(autoCheck: false)
    }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        tabs.target = self
        tabs.action = #selector(tabChanged(_:))
        for box in [inSelectionBox, backwardBox, wholeWordBox, matchCaseBox, wrapBox, normalRadio, extendedRadio, regexRadio,
                    dotNewlineBox, bookmarkLineBox, purgeBox, subfoldersBox, hiddenFoldersBox] {
            box.target = self
            box.action = #selector(optionChanged(_:))
        }
        findNextButton.target = self
        findNextButton.action = #selector(findNextClicked(_:))
        findNextButton.keyEquivalent = "\r"
        countButton.target = self
        countButton.action = #selector(countClicked(_:))
        replaceButton.target = self
        replaceButton.action = #selector(replaceClicked(_:))
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllClicked(_:))
        findAllCurrentButton.target = self
        findAllCurrentButton.action = #selector(findAllCurrentClicked(_:))
        findAllOpenedButton.target = self
        findAllOpenedButton.action = #selector(findAllOpenedClicked(_:))
        replaceAllOpenedButton.target = self
        replaceAllOpenedButton.action = #selector(replaceAllOpenedClicked(_:))
        findInFilesButton.target = self
        findInFilesButton.action = #selector(findInFilesClicked(_:))
        replaceInFilesButton.target = self
        replaceInFilesButton.action = #selector(replaceInFilesClicked(_:))
        browseButton.target = self
        browseButton.action = #selector(browseClicked(_:))
        browseButton.toolTip = "Choose the directory"
        fillDirectoryButton.target = self
        fillDirectoryButton.action = #selector(fillDirectoryClicked(_:))
        fillDirectoryButton.toolTip = "Fill directory field based on active document"
        filtersField.toolTip = """
            Find in cpp, cxx, h, hxx & hpp:  *.cpp *.cxx *.h *.hxx *.hpp
            Find in all files except exe, obj & log:  *.* !*.exe !*.obj !*.log
            Find in all files but exclude folders tests, bin & bin64:  *.* !/tests !/bin*
            Find in all files but exclude all folders log or logs recursively:  *.* !+/log*
            """
        markAllButton.target = self
        markAllButton.action = #selector(markAllClicked(_:))
        clearMarksButton.target = self
        clearMarksButton.action = #selector(clearMarksClicked(_:))
        copyMarkedButton.target = self
        copyMarkedButton.action = #selector(copyMarkedClicked(_:))
        for field in [findField, replaceField] {
            field.completes = false
            field.numberOfVisibleItems = 12
            field.delegate = self
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 320).isActive = true
        }

        let findLabel = NSTextField(labelWithString: "Find what:")
        for field in [filtersField, directoryField] {
            field.completes = false
            field.numberOfVisibleItems = 12
        }
        let directoryRow = NSStackView(views: [directoryField, fillDirectoryButton, browseButton])
        directoryRow.spacing = 6
        let fields = NSGridView(views: [[findLabel, findField], [replaceLabel, replaceField],
                                        [NSTextField(labelWithString: "Filters:"), filtersField],
                                        [NSTextField(labelWithString: "Directory:"), directoryRow]])
        fieldsGrid = fields
        fields.column(at: 0).xPlacement = .trailing
        fields.rowAlignment = .firstBaseline
        fields.rowSpacing = 8

        let checks = NSStackView(views: [bookmarkLineBox, purgeBox, inSelectionBox, backwardBox, wholeWordBox, matchCaseBox, wrapBox,
                                         subfoldersBox, hiddenFoldersBox])
        checks.orientation = .vertical
        checks.alignment = .leading
        checks.spacing = 6

        let modeTitle = NSTextField(labelWithString: "Search Mode")
        modeTitle.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let regexRow = NSStackView(views: [regexRadio, dotNewlineBox])
        regexRow.spacing = 12
        let modes = NSStackView(views: [modeTitle, normalRadio, extendedRadio, regexRow])
        modes.orientation = .vertical
        modes.alignment = .leading
        modes.spacing = 6

        let options = NSStackView(views: [checks, modes])
        options.alignment = .top
        options.spacing = 24

        let left = NSStackView(views: [fields, options])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 16

        let buttons = NSStackView(views: [findNextButton, findInFilesButton, replaceInFilesButton, countButton, findAllCurrentButton, findAllOpenedButton,
                                          replaceButton, replaceAllButton, replaceAllOpenedButton,
                                          markAllButton, clearMarksButton, copyMarkedButton])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 8
        for button in [findNextButton, findInFilesButton, replaceInFilesButton, countButton, findAllCurrentButton, findAllOpenedButton, replaceButton, replaceAllButton,
                       replaceAllOpenedButton, markAllButton, clearMarksButton, copyMarkedButton] {
            button.widthAnchor.constraint(equalToConstant: 250).isActive = true
        }

        let body = NSStackView(views: [left, buttons])
        body.alignment = .top
        body.spacing = 16

        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let root = NSStackView(views: [tabs, body, statusLabel])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        // Explicit margins: a leading-aligned stack's own edgeInsets let the widest row reach
        // the window's right edge.
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            statusLabel.widthAnchor.constraint(equalTo: body.widthAnchor),
        ])
        fitWindowToContent()
    }
}

/// Cancel, as seen from the folder walk on a background queue.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

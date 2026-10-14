import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    /// Notepad++ is a single-window editor: every file is a tab in this window.
    private(set) lazy var mainWindow = MainWindowController()
    /// Notepad++'s Find / Replace dialog: one for the app, acting on the visible tab.
    private(set) lazy var findReplace: FindReplaceController = {
        let controller = FindReplaceController { [weak self] in self?.mainWindow.activeTab?.editor }
        controller.documentsProvider = { [weak self] in
            (self?.mainWindow.activeSearchDocument, self?.mainWindow.searchDocuments ?? [])
        }
        controller.resultsSink = { [weak self] block in self?.mainWindow.showSearchResults(block) }
        return controller
    }()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        ShortcutStore.shared.apply(to: NSApp.mainMenu!)  // the user's shortcuts (MAC-43)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Finder "Open With" delivers files before this point. With none, reopen the previous
        // session, and fall back to an empty "new 1" when there is nothing to reopen.
        if mainWindow.openTabs.isEmpty {
            let restored = SessionStore.load().map { mainWindow.restore($0) } ?? false
            if !restored { mainWindow.newTab() }
        }
        mainWindow.showWindow(nil)
        mainWindow.restoreWorkspace()
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { mainWindow.open($0) }
        mainWindow.showWindow(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindow.persistSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard mainWindow.hasDirtyTabs else { return .terminateNow }
        mainWindow.showWindow(nil)
        mainWindow.confirmDiscardAll { sender.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }

    // MARK: - Shortcut Mapper (MAC-43)

    private(set) lazy var shortcutMapper = ShortcutMapperController()

    @IBAction func showShortcutMapper(_ sender: Any?) { shortcutMapper.show(.mainMenu) }
    @IBAction func showShortcutMapperMacros(_ sender: Any?) { shortcutMapper.show(.macros) }

    // MARK: - Macro (MAC-42)

    private(set) lazy var shortcutDialog = ShortcutDialog()
    private(set) lazy var runMacroDialog: RunMacroController = {
        let dialog = RunMacroController()
        dialog.onRun = { [weak self] index, times in
            guard let self else { return }
            let steps = index.map { MacroStore.shared.macros[$0].steps } ?? MacroRecorder.shared.steps
            self.playMacro(steps, times: times)
        }
        return dialog
    }()

    private var recorder: MacroRecorder { .shared }
    private var openEditors: [ScintillaView] { mainWindow.openTabs.map(\.editor) }

    @IBAction func startRecording(_ sender: Any?) { recorder.start(editors: openEditors) }

    @IBAction func stopRecording(_ sender: Any?) {
        recorder.stop(editors: openEditors)
        reloadRunMacroDialog()
    }

    @IBAction func playbackMacro(_ sender: Any?) { playMacro(recorder.steps, times: 1) }

    /// Save Current Recorded Macro…: a name and an optional shortcut; it joins the Macro menu.
    @IBAction func saveCurrentMacro(_ sender: Any?) {
        let steps = recorder.steps
        guard !steps.isEmpty else { return }
        shortcutDialog.run(in: mainWindow.window) { [weak self] result in
            guard let (name, key, modifiers) = result else { return }
            MacroStore.shared.add(Macro(name: name, steps: steps, key: key, modifiers: modifiers.rawValue))
            MacroRecorder.shared.markSaved()
            self?.reloadRunMacroDialog()
        }
    }

    @IBAction func showRunMacroDialog(_ sender: Any?) {
        reloadRunMacroDialog()
        runMacroDialog.show()
    }

    @IBAction func runSavedMacro(_ sender: Any?) {
        guard let index = (sender as? NSMenuItem)?.tag, MacroStore.shared.macros.indices.contains(index) else { return }
        playMacro(MacroStore.shared.macros[index].steps, times: 1)
    }

    private func reloadRunMacroDialog() {
        runMacroDialog.reload(hasRecording: !recorder.steps.isEmpty && !recorder.isRecording,
                              saved: MacroStore.shared.macros.map(\.name))
    }

    /// Plays `steps` `times` times (nil: until the end of the file); each document touched is one
    /// undo step for the whole run, as in Notepad++.
    func playMacro(_ steps: [MacroStep], times: Int?) {
        guard !recorder.isRecording, !steps.isEmpty else { NSSound.beep(); return }
        var touched: [ScintillaView] = []
        let playOnce = {
            self.recorder.play(steps, editor: { [weak self] in self?.mainWindow.activeTab?.editor },
                               search: { [weak self] in self?.findReplace.perform($0) }, touched: &touched)
        }
        if let times {
            for _ in 0..<max(times, 1) { playOnce() }
        } else {
            let editor = { [weak self] in self?.mainWindow.activeTab?.editor }
            MacroRecorder.runUntilEndOfFile(
                lineCount: { editor()?.send(SCI_GETLINECOUNT) ?? 0 },
                caretLine: { editor().map { $0.send(SCI_LINEFROMPOSITION, $0.send(SCI_GETCURRENTPOS)) } ?? 0 },
                play: playOnce)
        }
        MacroRecorder.endUndoGroups(touched)
    }

    // MARK: - Settings › Theme (MAC-36)

    private(set) lazy var styleConfigurator = StyleConfiguratorController()
    private(set) lazy var preferences = PreferencesController()
    private(set) lazy var columnEditor = ColumnEditorController { [weak self] in self?.mainWindow.activeTab?.editor }

    @IBAction func showColumnEditor(_ sender: Any?) {
        guard mainWindow.activeTab?.isReadOnly == false else { NSSound.beep(); return }
        columnEditor.show()
    }

    @IBAction func showColumnModeTip(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Column Mode Tip"
        alert.informativeText = ColumnEditor.columnModeTip
        alert.runModal()
    }

    @IBAction func showPreferences(_ sender: Any?) { preferences.show() }

    @IBAction func showStyleConfigurator(_ sender: Any?) { styleConfigurator.open() }

    @IBAction func selectTheme(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String else { return }
        ThemeManager.shared.select(name)
    }

    /// Where the user's own Notepad++ themes go; created on first use and shown in Finder.
    @IBAction func openThemesFolder(_ sender: Any?) {
        let folder = ThemeManager.shared.userDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    // MARK: - Search menu

    @IBAction func showFindPanel(_ sender: Any?) { findReplace.show(.find) }
    @IBAction func showReplacePanel(_ sender: Any?) { findReplace.show(.replace) }
    @IBAction func showMarkPanel(_ sender: Any?) { findReplace.show(.mark) }
    @IBAction func showFindInFilesPanel(_ sender: Any?) { findReplace.show(.findInFiles) }
    /// Notepad++'s Go To dialog (MAC-34).
    private(set) lazy var goTo = GoToLineController { [weak self] in self?.mainWindow.activeTab?.editor }

    @IBAction func showGoTo(_ sender: Any?) { goTo.show() }
    /// ⌘G / ⇧⌘G (F3 / Shift-F3) step the incremental search while its field has focus.
    @IBAction func findNextMatch(_ sender: Any?) {
        mainWindow.incrementalBar.hasFocus ? mainWindow.incrementalBar.next() : findReplace.findNext()
    }
    @IBAction func findPreviousMatch(_ sender: Any?) {
        mainWindow.incrementalBar.hasFocus ? mainWindow.incrementalBar.previous() : findReplace.findNext(reversed: true)
    }
    @IBAction func selectAndFindNext(_ sender: Any?) { findReplace.selectAndFindNext(reversed: false) }
    @IBAction func selectAndFindPrevious(_ sender: Any?) { findReplace.selectAndFindNext(reversed: true) }
    @IBAction func useSelectionForFind(_ sender: Any?) { findReplace.useSelectionForFind() }

    // MARK: - File menu

    @IBAction func newDocument(_ sender: Any?) {
        mainWindow.newTab()
        mainWindow.showWindow(nil)
    }

    /// Rebuilt each time the menu opens, so it always matches the stored list.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Theme" {
            MainMenu.fillThemeMenu(menu)
            return
        }
        if menu.title == "Macro" {
            MainMenu.fillMacroMenu(menu)
            return
        }
        menu.removeAllItems()
        let recent = RecentFilesStore.shared.files
        guard !recent.isEmpty else {
            let empty = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for url in recent.urls {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(openRecentFile(_:)), keyEquivalent: "")
            item.target = self
            item.toolTip = url.path
            item.representedObject = url
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Recent Files",
                               action: #selector(clearRecentFiles(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    /// A file that has gone away since it was listed drops off the list instead of opening.
    @IBAction func openRecentFile(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            RecentFilesStore.shared.remove(url)
            NSSound.beep()
            return
        }
        mainWindow.open(url)
        mainWindow.showWindow(nil)
    }

    @IBAction func clearRecentFiles(_ sender: Any?) {
        RecentFilesStore.shared.clear()
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    @IBAction func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { mainWindow.open($0) }
        mainWindow.showWindow(nil)
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Notepad++'s checkMacroState: what the Macro menu allows while recording or not.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let recorder = MacroRecorder.shared
        switch item.action {
        case #selector(startRecording(_:)): return !recorder.isRecording
        case #selector(stopRecording(_:)): return recorder.isRecording
        case #selector(playbackMacro(_:)): return !recorder.steps.isEmpty && !recorder.isRecording
        case #selector(saveCurrentMacro(_:)): return !recorder.steps.isEmpty && !recorder.isRecording && !recorder.recordingSaved
        case #selector(showRunMacroDialog(_:)):
            return (!recorder.steps.isEmpty && !recorder.isRecording) || !MacroStore.shared.macros.isEmpty
        default: return true
        }
    }
}

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
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Finder "Open With" delivers files before this point. With none, reopen the previous
        // session, and fall back to an empty "new 1" when there is nothing to reopen.
        if mainWindow.openTabs.isEmpty {
            let restored = SessionStore.load().map { mainWindow.restore($0) } ?? false
            if !restored { mainWindow.newTab() }
        }
        mainWindow.showWindow(nil)
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

    // MARK: - Settings › Theme (MAC-36)

    private(set) lazy var styleConfigurator = StyleConfiguratorController()
    private(set) lazy var preferences = PreferencesController()

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

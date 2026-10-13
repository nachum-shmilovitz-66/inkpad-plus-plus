import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    /// Notepad++ is a single-window editor: every file is a tab in this window.
    private(set) lazy var mainWindow = MainWindowController()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Finder "Open With" delivers files before this point; only open "new 1" if none came.
        if mainWindow.openTabs.isEmpty { mainWindow.newTab() }
        mainWindow.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { mainWindow.open($0) }
        mainWindow.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard mainWindow.hasDirtyTabs else { return .terminateNow }
        mainWindow.showWindow(nil)
        mainWindow.confirmDiscardAll { sender.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }

    // MARK: - File menu

    @IBAction func newDocument(_ sender: Any?) {
        mainWindow.newTab()
        mainWindow.showWindow(nil)
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

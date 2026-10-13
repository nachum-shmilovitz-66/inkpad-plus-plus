import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    private var editors: [EditorWindowController] = []
    private var nextUntitledNumber = 1

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Finder "Open With" delivers files before this point; only open "new 1" if none came.
        if editors.isEmpty { newDocument(nil) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(open)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = editors.filter(\.isModified)
        guard !dirty.isEmpty else { return .terminateNow }
        confirmDiscard(dirty[...]) { ok in sender.reply(toApplicationShouldTerminate: ok) }
        return .terminateLater
    }

    /// Asks about each unsaved window in turn, as Notepad++ does on exit.
    private func confirmDiscard(_ remaining: ArraySlice<EditorWindowController>, completion: @escaping (Bool) -> Void) {
        guard let first = remaining.first else { completion(true); return }
        first.showWindow(nil)
        first.confirmDiscard { [weak self] ok in
            guard ok else { completion(false); return }
            self?.confirmDiscard(remaining.dropFirst(), completion: completion)
        }
    }

    // MARK: - File menu

    @IBAction func newDocument(_ sender: Any?) {
        let editor = EditorWindowController(untitledNumber: nextUntitledNumber)
        nextUntitledNumber += 1
        show(editor)
    }

    @IBAction func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(open)
    }

    func open(_ url: URL) {
        if let existing = editors.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            existing.showWindow(nil)
            return
        }
        // Reuse an untouched "new 1" window, as Notepad++ reuses its empty first tab.
        let reusable = editors.first(where: \.isPristineUntitled)
        let editor = reusable ?? EditorWindowController(untitledNumber: nextUntitledNumber)
        if reusable == nil { nextUntitledNumber += 1 }
        do {
            try editor.load(url)
        } catch {
            NSApp.presentError(error)
            return
        }
        show(editor)
    }

    private func show(_ editor: EditorWindowController) {
        if !editors.contains(where: { $0 === editor }) {
            if let front = editors.last?.window, let window = editor.window {
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: front.frame.minX, y: front.frame.maxY)))
            }
            editors.append(editor)
        }
        editor.showWindow(nil)
        editor.window?.makeFirstResponder(editor.editor.content())
    }

    func editorDidClose(_ editor: EditorWindowController) {
        editors.removeAll { $0 === editor }
    }
}

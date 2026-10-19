import XCTest
@testable import Inkpad

/// MAC-42: macros — recording, playback, run until the end of file, saved macros, shortcuts.
final class MacroTests: XCTestCase {
    private func editor(_ text: String = "") -> ScintillaView {
        let v = ScintillaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        v.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
        v.setUTF8Bytes(Data(text.utf8))
        v.send(SCI_EMPTYUNDOBUFFER)
        v.send(SCI_GOTOPOS, 0)
        return v
    }

    private func text(_ v: ScintillaView) -> String { String(decoding: v.utf8Bytes(), as: UTF8.self) }

    override func tearDown() {
        if MacroRecorder.shared.isRecording { MacroRecorder.shared.stop(editors: []) }
        super.tearDown()
    }

    func testRecordingAnEditorAndPlayingItBack() {
        let tab = EditorTab(untitledNumber: 1)
        let recorder = MacroRecorder.shared
        recorder.start(editors: [tab.editor])
        tab.editor.send(SCI_REPLACESEL, 0, string: "hello")
        tab.editor.send(SCI_NEWLINE)
        tab.editor.send(SCI_SETCARETLINEBACK, 0xFF)  // not macroable in Scintilla: never recorded
        recorder.stop(editors: [tab.editor])
        XCTAssertEqual(recorder.steps, [.text(SCI_REPLACESEL, "hello"), .scintilla(SCI_NEWLINE)])

        let other = editor("x")
        other.send(SCI_GOTOPOS, 1)
        var touched: [ScintillaView] = []
        recorder.play(recorder.steps, editor: { other }, search: { _ in }, touched: &touched)
        recorder.play(recorder.steps, editor: { other }, search: { _ in }, touched: &touched)
        MacroRecorder.endUndoGroups(touched)
        XCTAssertEqual(text(other), "xhello\nhello\n")
        other.send(SCI_UNDO)
        XCTAssertEqual(text(other), "x", "the whole playback is one undo step")
        tab.detach()
    }

    func testTypedLineBreaksBecomeNewLineOnceForCRLF() {
        let recorder = MacroRecorder.shared
        recorder.start(editors: [])
        for s in ["\r", "\n"] {
            s.withCString { recorder.scintillaMessage(Int(SCI_REPLACESEL), wParam: 0, lParam: Int(bitPattern: $0), eolMode: Int(SC_EOL_CRLF)) }
        }
        "a".withCString { recorder.scintillaMessage(Int(SCI_REPLACESEL), wParam: 0, lParam: Int(bitPattern: $0), eolMode: Int(SC_EOL_CRLF)) }
        recorder.stop(editors: [])
        XCTAssertEqual(recorder.steps, [.scintilla(SCI_NEWLINE), .text(SCI_REPLACESEL, "a")])
    }

    func testNonMacroableStepsAreSkippedAtPlayback() {
        let v = editor("abc")
        var touched: [ScintillaView] = []
        MacroRecorder.shared.play([.scintilla(SCI_SETREADONLY, 1), .text(SCI_SETTEXT, "zzz"), .scintilla(SCI_DOCUMENTEND),
                                   .text(SCI_REPLACESEL, "!")],
                                  editor: { v }, search: { _ in }, touched: &touched)
        MacroRecorder.endUndoGroups(touched)
        XCTAssertEqual(text(v), "abc!")
        XCTAssertEqual(v.send(SCI_GETREADONLY), 0)
    }

    func testMenuCommandsAreRecordedOnceWithoutTheirScintillaMessages() {
        let recorder = MacroRecorder.shared
        let v = editor("a")
        recorder.start(editors: [v])
        let item = NSMenuItem(title: "Duplicate Current Line", action: #selector(MainWindowController.lineOperation(_:)), keyEquivalent: "")
        item.tag = 1
        let menu = NSMenu()
        menu.addItem(item)
        NotificationCenter.default.post(name: NSMenu.willSendActionNotification, object: menu, userInfo: ["MenuItem": item])
        v.send(SCI_LINEDUPLICATE)  // what the command does inside: not recorded on its own
        NotificationCenter.default.post(name: NSMenu.didSendActionNotification, object: menu, userInfo: ["MenuItem": item])
        let ignored = NSMenuItem(title: "About", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        NotificationCenter.default.post(name: NSMenu.didSendActionNotification, object: menu, userInfo: ["MenuItem": ignored])
        recorder.stop(editors: [v])
        XCTAssertEqual(recorder.steps, [.command(#selector(MainWindowController.lineOperation(_:)), tag: 1)])
    }

    func testFindReplaceOperationsReplay() {
        let v = editor("cat cat cat")
        let defaults = UserDefaults(suiteName: "app.inkpad.Inkpad.tests.macrosearch")!
        defaults.removePersistentDomain(forName: "app.inkpad.Inkpad.tests.macrosearch")
        let dialog = FindReplaceController(defaults: defaults) { v }
        dialog.findField.stringValue = "cat"
        dialog.replaceField.stringValue = "dog"
        let step = dialog.currentSearchStep(.replaceAll)
        dialog.findField.stringValue = "other"
        dialog.perform(step)
        XCTAssertEqual(text(v), "dog dog dog")
        XCTAssertEqual(dialog.findField.stringValue, "other", "the dialog's own text is put back")
    }

    func testRunUntilTheEndOfTheFile() {
        let v = editor("a\nb\nc")
        let steps: [MacroStep] = [.scintilla(SCI_HOME), .text(SCI_REPLACESEL, "- "), .scintilla(SCI_LINEDOWN)]
        var touched: [ScintillaView] = []
        MacroRecorder.runUntilEndOfFile(
            lineCount: { v.send(SCI_GETLINECOUNT) },
            caretLine: { v.send(SCI_LINEFROMPOSITION, v.send(SCI_GETCURRENTPOS)) },
            play: { MacroRecorder.shared.play(steps, editor: { v }, search: { _ in }, touched: &touched) })
        MacroRecorder.endUndoGroups(touched)
        XCTAssertEqual(text(v), "- a\n- b\n- c", "every line once, then it stops")
    }

    func testTheAppPlaysOnTheActiveTab() {
        let window = AppDelegate.shared.mainWindow
        let tab = window.newTab()
        tab.editor.setUTF8Bytes(Data("x".utf8))
        tab.editor.send(SCI_DOCUMENTEND)
        AppDelegate.shared.playMacro([.text(SCI_REPLACESEL, "y")], times: 3)
        XCTAssertEqual(text(tab.editor), "xyyy")
        tab.editor.send(SCI_UNDO)
        XCTAssertEqual(text(tab.editor), "x")
        if let index = window.openTabs.firstIndex(where: { $0 === tab }) {
            tab.editor.send(SCI_SETSAVEPOINT)
            window.closeTab(at: index)
        }
    }

    func testSavedMacrosStartWithTrimTrailingSpaceAndSave() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("InkpadMacros-\(UUID().uuidString)/macros.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = MacroStore(url: url)
        XCTAssertEqual(store.macros.map(\.name), ["Trim Trailing Space and Save"])
        store.add(Macro(name: "Mine", steps: [.text(SCI_REPLACESEL, "z")], key: "9", modifiers: NSEvent.ModifierFlags.command.rawValue))
        let reloaded = MacroStore(url: url)
        XCTAssertEqual(reloaded.macros.map(\.name), ["Trim Trailing Space and Save", "Mine"])
        reloaded.remove(at: 0)
        XCTAssertEqual(MacroStore(url: url).macros.map(\.name), ["Mine"])
    }

    func testTheMacroMenuAndItsStates() {
        let menu = NSMenu(title: "Macro")
        MainMenu.fillMacroMenu(menu)
        XCTAssertEqual(Array(menu.items.prefix(5)).map(\.title),
                       ["Start Recording", "Stop Recording", "Playback", "Save Current Recorded Macro…", "Run a Macro Multiple Times…"])
        XCTAssertTrue(menu.items.contains { $0.title == "Trim Trailing Space and Save" })
        let app = AppDelegate.shared
        XCTAssertTrue(app.validateMenuItem(menu.items[0]))
        XCTAssertFalse(app.validateMenuItem(menu.items[1]), "Stop needs a recording in progress")
        MacroRecorder.shared.start(editors: [])
        XCTAssertFalse(app.validateMenuItem(menu.items[0]))
        XCTAssertTrue(app.validateMenuItem(menu.items[1]))
        XCTAssertFalse(app.validateMenuItem(menu.items[2]), "no playback while recording")
        MacroRecorder.shared.stop(editors: [])
    }

    func testShortcutRules() {
        XCTAssertFalse(ShortcutRules.isValid(key: "a", modifiers: [.shift]))
        XCTAssertTrue(ShortcutRules.isValid(key: "a", modifiers: [.command]))
        XCTAssertTrue(ShortcutRules.isValid(key: "", modifiers: []), "no shortcut is fine")
        XCTAssertEqual(ShortcutRules.describe(key: "s", modifiers: [.command, .option, .shift]), "⌥⇧⌘S")
        XCTAssertNotNil(ShortcutRules.conflict(key: "f", modifiers: [.command], in: NSApp.mainMenu), "⌘F is Find…")
    }
}

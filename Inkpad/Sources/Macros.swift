import AppKit

/// One step of a macro (MAC-42), upstream's MacroStep: a Scintilla message (with an integer or a
/// string parameter), a menu command, or a Find / Replace operation.
struct MacroStep: Codable, Equatable {
    enum Kind: Int, Codable { case scintilla = 0, scintillaString = 1, menuCommand = 2, search = 3 }

    var kind: Kind
    var message: Int = 0
    var wParam: Int = 0
    var lParam: Int = 0
    var string: String?
    /// Menu command: the action's selector name and the item's tag.
    var action: String?
    var tag: Int = 0
    /// Find / Replace operation.
    var search: SearchMacroStep?

    static func scintilla(_ message: Int32, _ wParam: Int = 0, _ lParam: Int = 0) -> MacroStep {
        MacroStep(kind: .scintilla, message: Int(message), wParam: wParam, lParam: lParam)
    }

    static func text(_ message: Int32, _ string: String, wParam: Int = 0) -> MacroStep {
        MacroStep(kind: .scintillaString, message: Int(message), wParam: wParam, string: string)
    }

    static func command(_ action: Selector, tag: Int = 0) -> MacroStep {
        MacroStep(kind: .menuCommand, action: NSStringFromSelector(action), tag: tag)
    }
}

/// A Find / Replace dialog operation as recorded (upstream records the dialog's state then the button).
struct SearchMacroStep: Codable, Equatable {
    enum Operation: String, Codable {
        case findNext, findPrevious, replace, replaceAll, count, markAll, clearMarks
        case findAllInCurrent, findAllInOpened, replaceAllInOpened, findInFiles, replaceInFiles
    }
    var operation: Operation
    var findText: String
    var replaceText: String = ""
    var options: SearchOptions
    var directory: String = ""
    var filters: String = ""
}

struct Macro: Codable, Equatable {
    var name: String
    var steps: [MacroStep]
    /// Key equivalent and modifiers (NSEvent.ModifierFlags raw value); empty key = none.
    var key: String = ""
    var modifiers: UInt = 0
}

/// upstream's macro machinery: recording from every editor's SCN_MACRORECORD and from menu
/// commands, playback as one undo step per document, and the saved macros.
final class MacroRecorder {
    static let shared = MacroRecorder()
    static let stateDidChange = Notification.Name("InkpadMacroStateDidChange")

    private(set) var isRecording = false
    private(set) var isPlayingBack = false
    private(set) var steps: [MacroStep] = []
    /// The current recording has been saved (Save is then disabled, as in upstream).
    private(set) var recordingSaved = false
    /// While a recordable menu command runs, the Scintilla messages it sends are not recorded too.
    private var suppressScintilla = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.willSendActionNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, self.isRecording, let item = note.userInfo?["MenuItem"] as? NSMenuItem,
                  let action = item.action, Self.isRecordable(action) else { return }
            self.suppressScintilla += 1
        })
        observers.append(center.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: nil) { [weak self] note in
            guard let self, self.isRecording, let item = note.userInfo?["MenuItem"] as? NSMenuItem,
                  let action = item.action, Self.isRecordable(action) else { return }
            self.suppressScintilla = max(self.suppressScintilla - 1, 0)
            self.steps.append(.command(action, tag: item.tag))
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    // MARK: - Recording

    /// Start Recording: a new, empty macro; every editor records.
    func start(editors: [ScintillaView]) {
        steps = []
        isRecording = true
        recordingSaved = false
        editors.forEach { $0.send(SCI_STARTRECORD) }
        announce()
    }

    func stop(editors: [ScintillaView]) {
        isRecording = false
        recordingSaved = false
        editors.forEach { $0.send(SCI_STOPRECORD) }
        announce()
    }

    /// A tab opened while recording records too.
    func attach(_ editor: ScintillaView) {
        if isRecording { editor.send(SCI_STARTRECORD) }
    }

    /// SCN_MACRORECORD: string messages keep a copy of their text; a typed line break becomes
    /// SCI_NEWLINE (a CR LF pair only once).
    func scintillaMessage(_ message: Int, wParam: Int, lParam: Int, eolMode: Int) {
        guard isRecording, suppressScintilla == 0, !isPlayingBack else { return }
        let stringMessages: Set<Int32> = [SCI_SETTEXT, SCI_REPLACESEL, SCI_REPLACETARGET, SCI_REPLACETARGETRE, SCI_SEARCHINTARGET,
                                          SCI_ADDTEXT, SCI_INSERTTEXT, SCI_APPENDTEXT, SCI_SEARCHNEXT, SCI_SEARCHPREV]
        guard stringMessages.contains(Int32(message)), lParam != 0,
              let pointer = UnsafePointer<CChar>(bitPattern: lParam) else {
            steps.append(MacroStep(kind: .scintilla, message: message, wParam: wParam, lParam: lParam))
            return
        }
        let text: String
        if message == Int(SCI_ADDTEXT) || message == Int(SCI_APPENDTEXT) {
            text = String(decoding: UnsafeRawBufferPointer(start: pointer, count: max(wParam, 0)), as: UTF8.self)
        } else {
            text = String(cString: pointer)
        }
        if message == Int(SCI_REPLACESEL) && (text == "\n" || text == "\r") {
            if eolMode == Int(SC_EOL_CRLF), text == "\n", steps.last == .scintilla(SCI_NEWLINE) { return }
            steps.append(.scintilla(SCI_NEWLINE))
            return
        }
        steps.append(MacroStep(kind: .scintillaString, message: message, wParam: wParam, string: text))
    }

    /// A Find / Replace operation from the dialog.
    func record(_ search: SearchMacroStep) {
        guard isRecording, !isPlayingBack else { return }
        steps.append(MacroStep(kind: .search, search: search))
    }

    /// Menu commands upstream records (NppCommands.cpp's list), by their Inkpad++ actions.
    static let recordableActions: Set<String> = [
        "lineOperation:", "blankOperation:", "convertCase:", "commentCommand:", "changeIndent:", "copyPathToClipboard:",
        "readOnlyCommand:", "beginEndSelect:", "beginEndSelectColumn:", "toggleBookmark:", "nextBookmark:", "previousBookmark:",
        "clearAllBookmarks:", "cutBookmarkedLines:", "copyBookmarkedLines:", "pasteToBookmarkedLines:", "removeBookmarkedLines:",
        "removeUnbookmarkedLines:", "inverseBookmarks:", "styleAllOccurrences:", "styleOneToken:", "clearStyle:", "jumpUp:",
        "jumpDown:", "copyStyledText:", "findNextMatch:", "findPreviousMatch:", "selectAndFindNext:", "selectAndFindPrevious:",
        "saveDocument:", "newDocument:", "closeTab:", "undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:", "clear:",
        "selectNextTab:", "selectPreviousTab:", "toggleWordWrap:",
    ]

    static func isRecordable(_ action: Selector) -> Bool { recordableActions.contains(NSStringFromSelector(action)) }

    // MARK: - Playback

    /// Scintilla messages that play back (upstream's isMacroable); others are skipped.
    static let playableStringMessages: Set<Int> = [SCI_REPLACESEL, SCI_ADDTEXT, SCI_INSERTTEXT, SCI_APPENDTEXT,
                                                    SCI_SEARCHNEXT, SCI_SEARCHPREV].map { Int($0) }.reduce(into: []) { $0.insert($1) }
    static let playableMessages: Set<Int> = {
        let list: [Int32] = [
            SCI_GOTOLINE, SCI_GOTOPOS, SCI_SETSELECTIONMODE, SCI_CUT, SCI_COPY, SCI_PASTE, SCI_CLEAR, SCI_CLEARALL, SCI_SELECTALL,
            SCI_SEARCHANCHOR, SCI_LINEDOWN, SCI_LINEDOWNEXTEND, SCI_PARADOWN, SCI_PARADOWNEXTEND, SCI_LINEUP, SCI_LINEUPEXTEND,
            SCI_PARAUP, SCI_PARAUPEXTEND, SCI_CHARLEFT, SCI_CHARLEFTEXTEND, SCI_CHARRIGHT, SCI_CHARRIGHTEXTEND, SCI_WORDLEFT,
            SCI_WORDLEFTEXTEND, SCI_WORDRIGHT, SCI_WORDRIGHTEXTEND, SCI_WORDPARTLEFT, SCI_WORDPARTLEFTEXTEND, SCI_WORDPARTRIGHT,
            SCI_WORDPARTRIGHTEXTEND, SCI_WORDLEFTEND, SCI_WORDLEFTENDEXTEND, SCI_WORDRIGHTEND, SCI_WORDRIGHTENDEXTEND, SCI_HOME,
            SCI_HOMEEXTEND, SCI_LINEEND, SCI_LINEENDEXTEND, SCI_HOMEWRAP, SCI_HOMEWRAPEXTEND, SCI_LINEENDWRAP,
            SCI_LINEENDWRAPEXTEND, SCI_DOCUMENTSTART, SCI_DOCUMENTSTARTEXTEND, SCI_DOCUMENTEND, SCI_DOCUMENTENDEXTEND,
            SCI_STUTTEREDPAGEUP, SCI_STUTTEREDPAGEUPEXTEND, SCI_STUTTEREDPAGEDOWN, SCI_STUTTEREDPAGEDOWNEXTEND, SCI_PAGEUP,
            SCI_PAGEUPEXTEND, SCI_PAGEDOWN, SCI_PAGEDOWNEXTEND, SCI_EDITTOGGLEOVERTYPE, SCI_CANCEL, SCI_DELETEBACK, SCI_TAB,
            SCI_BACKTAB, SCI_FORMFEED, SCI_VCHOME, SCI_VCHOMEEXTEND, SCI_VCHOMEWRAP, SCI_VCHOMEWRAPEXTEND, SCI_DELWORDLEFT,
            SCI_DELWORDRIGHT, SCI_DELWORDRIGHTEND, SCI_DELLINELEFT, SCI_DELLINERIGHT, SCI_LINECOPY, SCI_LINECUT,
            SCI_LINEDELETE, SCI_LINETRANSPOSE, SCI_LINEDUPLICATE, SCI_LOWERCASE, SCI_UPPERCASE, SCI_LINESCROLLDOWN,
            SCI_LINESCROLLUP, SCI_DELETEBACKNOTLINE, SCI_HOMEDISPLAY, SCI_HOMEDISPLAYEXTEND, SCI_LINEENDDISPLAY,
            SCI_LINEENDDISPLAYEXTEND, SCI_SETSELECTIONMODE, SCI_LINEDOWNRECTEXTEND, SCI_LINEUPRECTEXTEND,
            SCI_CHARLEFTRECTEXTEND, SCI_CHARRIGHTRECTEXTEND, SCI_HOMERECTEXTEND, SCI_VCHOMERECTEXTEND,
            SCI_LINEENDRECTEXTEND, SCI_PAGEUPRECTEXTEND, SCI_PAGEDOWNRECTEXTEND, SCI_SELECTIONDUPLICATE, SCI_COPYALLOWLINE,
            SCI_VERTICALCENTRECARET, SCI_MOVESELECTEDLINESUP, SCI_MOVESELECTEDLINESDOWN, SCI_SCROLLTOSTART, SCI_SCROLLTOEND,
            SCI_SETVIRTUALSPACEOPTIONS, SCI_NEWLINE,
        ]
        return Set(list.map { Int($0) })
    }()

    /// Playback: every step on the current editor; each document touched is one undo step.
    /// `editor` is asked again before each step (a step may switch tabs).
    func play(_ steps: [MacroStep], editor: () -> ScintillaView?, search: (SearchMacroStep) -> Void,
              touched: inout [ScintillaView]) {
        isPlayingBack = true
        defer { isPlayingBack = false }
        for step in steps {
            guard let view = editor() else { return }
            if !touched.contains(where: { $0 === view }) {
                view.send(SCI_BEGINUNDOACTION)
                touched.append(view)
            }
            switch step.kind {
            case .scintilla:
                if Self.playableMessages.contains(step.message) { view.send(Int32(step.message), step.wParam, step.lParam) }
            case .scintillaString:
                guard Self.playableStringMessages.contains(step.message), let text = step.string else { continue }
                let bytes = Array(text.utf8) + [0]
                let wParam = step.message == Int(SCI_ADDTEXT) || step.message == Int(SCI_APPENDTEXT) ? bytes.count - 1 : step.wParam
                bytes.withUnsafeBytes { _ = view.send(Int32(step.message), wParam, pointer: $0.baseAddress) }
            case .menuCommand:
                // MAC-63: only what can be recorded is played — a hand-edited macros.json cannot send
                // any other selector through the responder chain.
                guard let name = step.action, Self.isRecordable(NSSelectorFromString(name)) else { continue }
                let item = NSMenuItem(title: "", action: NSSelectorFromString(name), keyEquivalent: "")
                item.tag = step.tag
                NSApp.sendAction(NSSelectorFromString(name), to: nil, from: item)
            case .search:
                if let s = step.search { search(s) }
            }
        }
    }

    static func endUndoGroups(_ touched: [ScintillaView]) {
        touched.forEach { $0.send(SCI_ENDUNDOACTION) }
    }

    func markSaved() {
        recordingSaved = true
        announce()
    }

    private func announce() { NotificationCenter.default.post(name: Self.stateDidChange, object: self) }

    // MARK: - Run until the end of file

    /// upstream's "Run until the end of file": plays again while the caret keeps moving the same
    /// way through the lines and the end has not been reached (line based, as upstream does it).
    static func runUntilEndOfFile(lineCount: () -> Int, caretLine: () -> Int, play: () -> Void, limit: Int = 100_000) {
        var lastLine = lineCount() - 1
        var currentLine = caretLine()
        var counter = 0
        var cursorMovedUp = false
        var deltaLastLine = 0, deltaCurrentLine = 0
        while counter < limit {
            play()
            counter += 1
            if counter > 2 && cursorMovedUp != (deltaCurrentLine < 0) && deltaLastLine >= 0 { break }
            cursorMovedUp = deltaCurrentLine < 0
            deltaLastLine = lineCount() - 1 - lastLine
            deltaCurrentLine = caretLine() - currentLine
            if deltaCurrentLine == 0 && deltaLastLine >= 0 { break }
            if deltaLastLine < deltaCurrentLine { lastLine += deltaLastLine }
            currentLine += deltaCurrentLine
            if currentLine > lastLine || currentLine < 0
                || (deltaCurrentLine == 0 && currentLine == 0 && (deltaLastLine >= 0 || cursorMovedUp)) { break }
        }
    }
}

/// The saved macros, in Application Support (upstream keeps them in shortcuts.xml), with its
/// predefined "Trim Trailing Space and Save".
final class MacroStore {
    static let shared = MacroStore()
    static let didChange = Notification.Name("InkpadMacrosDidChange")

    let url: URL
    private(set) var macros: [Macro]

    static let defaultMacros = [
        Macro(name: "Trim Trailing Space and Save",
              steps: [.command(NSSelectorFromString("blankOperation:"), tag: 1), .command(NSSelectorFromString("saveDocument:"))],
              key: "s", modifiers: NSEvent.ModifierFlags([.command, .option, .shift]).rawValue),
    ]

    init(url: URL = AppEnvironment.supportDirectory.appendingPathComponent("macros.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Macro].self, from: data) {
            macros = saved
        } else {
            macros = Self.defaultMacros
        }
    }

    func add(_ macro: Macro) { macros.append(macro); save() }

    func replace(at index: Int, with macro: Macro) {
        guard macros.indices.contains(index) else { return }
        macros[index] = macro
        save()
    }

    func remove(at index: Int) {
        guard macros.indices.contains(index) else { return }
        macros.remove(at: index)
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(macros) { try? data.write(to: url, options: .atomic) }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

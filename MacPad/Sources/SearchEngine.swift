import AppKit

/// Notepad++'s Find/Replace operations (FindReplaceDlg::processFindNext, processReplace,
/// processAll/processRange) on one Scintilla view (MAC-30). Positions are Scintilla's byte offsets.
struct SearchEngine {
    let editor: ScintillaView

    struct Match: Equatable {
        var start: Int
        var end: Int
    }

    enum Outcome: Equatable {
        case found(Match, wrapped: Bool)
        case notFound
        case invalidRegex
    }

    /// Which of processFindNext's three callers is searching: each allows empty regex matches
    /// differently (Notepad++'s FINDNEXTTYPE_*).
    enum FindKind {
        case findNext, replaceNext, findForReplace

        var flags: Int {
            let skip = Int(SCFIND_REGEXP_SKIPCRLFASONE)
            switch self {
            case .findNext: return Int(SCFIND_REGEXP_EMPTYMATCH_ALL) | skip
            case .replaceNext: return Int(SCFIND_REGEXP_EMPTYMATCH_NOTAFTERMATCH) | skip
            case .findForReplace:
                return Int(SCFIND_REGEXP_EMPTYMATCH_ALL) | Int(SCFIND_REGEXP_EMPTYMATCH_ALLOWATSTART) | skip
            }
        }
    }

    // MARK: - Find Next

    /// processFindNext. `fromSelectionStart` is Notepad++'s FirstIncremental (used by Replace):
    /// the current selection may itself be the match. A match is selected with the caret at its end.
    func findNext(_ text: String, options: SearchOptions, kind: FindKind = .findNext,
                  fromSelectionStart: Bool = false) -> Outcome {
        guard !text.isEmpty else { return .notFound }
        let pattern = bytes(options.prepared(text))
        let length = editor.send(SCI_GETLENGTH)
        let selStart = editor.send(SCI_GETSELECTIONSTART), selEnd = editor.send(SCI_GETSELECTIONEND)
        let up = options.effectiveBackward

        var from: Int, to: Int
        switch (up, fromSelectionStart) {
        case (false, false): (from, to) = (selEnd, length)
        case (true, false): (from, to) = (selEnd - 1, 0)
        case (false, true): (from, to) = (selStart, length)
        case (true, true): (from, to) = (selEnd, 0)
        }

        var flags = options.searchFlags | kind.flags
        if editor.send(SCI_GETCHARAT, from - 1) == 0x0D && editor.send(SCI_GETCHARAT, from) == 0x0A {
            flags &= ~Int(SCFIND_REGEXP_EMPTYMATCH_MASK)  // between CR and LF: no empty match here
        }

        var wrapped = false
        var result = search(pattern, flags: flags, from: from, to: to)
        if case .notFound = result, options.wrapAround {
            wrapped = true
            result = up ? search(pattern, flags: flags, from: length, to: 0)
                        : search(pattern, flags: flags, from: 0, to: length)
        }
        guard case .found(let match, _) = result else { return result }
        select(match)
        return .found(match, wrapped: wrapped)
    }

    // MARK: - Replace

    enum ReplaceOutcome: Equatable {
        /// The selection was the match and was replaced; then the next match was looked for.
        case replaced(next: Outcome)
        /// The selection was not a match: Replace acted as Find Next and selected this one.
        case foundOnly(Match)
        case notFound
        case invalidRegex
        case readOnly
    }

    /// processReplace: replaces the selection if it is a match, then finds the next one.
    func replace(_ text: String, with replacement: String, options: SearchOptions) -> ReplaceOutcome {
        guard editor.send(SCI_GETREADONLY) == 0 else { return .readOnly }
        let selStart = editor.send(SCI_GETSELECTIONSTART), selEnd = editor.send(SCI_GETSELECTIONEND)
        switch findNext(text, options: options, kind: .findForReplace, fromSelectionStart: true) {
        case .invalidRegex: return .invalidRegex
        case .notFound: return .notFound
        case .found(let match, _) where match != Match(start: selStart, end: selEnd):
            return .foundOnly(match)
        case .found(let match, _):
            // findNext left the target on the match, as processReplace's replaceTarget expects.
            editor.send(SCI_SETTARGETRANGE, match.start, match.end)
            let replacedLength = replaceTarget(with: replacement, options: options)
            let caret = match.start + replacedLength
            editor.send(SCI_SETSEL, caret, caret)
            return .replaced(next: findNext(text, options: options, kind: .replaceNext, fromSelectionStart: true))
        }
    }

    // MARK: - Count, Replace All

    enum AllOperation { case count, replaceAll }

    enum AllOutcome: Equatable {
        case done(Int, scope: SearchScope)
        case invalidRegex
        case readOnly
    }

    /// The range an "all" operation covers (processAll): the selection with In selection, the
    /// whole file with Wrap around, otherwise from the caret onwards in the search direction.
    func scope(for operation: AllOperation, options: SearchOptions) -> (range: Range<Int>, scope: SearchScope) {
        let length = editor.send(SCI_GETLENGTH)
        let selStart = editor.send(SCI_GETSELECTIONSTART), selEnd = editor.send(SCI_GETSELECTIONEND)
        if options.inSelection && hasUsableSelection {
            return (selStart..<selEnd, .selection)
        }
        if options.wrapAround { return (0..<length, .entireFile) }
        return options.effectiveBackward ? (0..<selEnd, .startToCaret) : (selStart..<length, .caretToEnd)
    }

    /// Notepad++ enables In selection only for a non-empty, non-rectangular single selection.
    var hasUsableSelection: Bool {
        editor.send(SCI_GETSELECTIONS) == 1 && editor.send(SCI_GETSELECTIONMODE) == Int(SC_SEL_STREAM)
            && editor.send(SCI_GETSELECTIONEND) > editor.send(SCI_GETSELECTIONSTART)
    }

    func count(_ text: String, options: SearchOptions) -> AllOutcome {
        processAll(.count, text, replacement: "", options: options)
    }

    /// Replace All is one undo step; with In selection the selection then covers the edited range.
    func replaceAll(_ text: String, with replacement: String, options: SearchOptions) -> AllOutcome {
        guard editor.send(SCI_GETREADONLY) == 0 else { return .readOnly }
        return processAll(.replaceAll, text, replacement: replacement, options: options)
    }

    /// processRange. `onMatch` sees each match of a Count — Mark All and the token styles are
    /// counts that also paint what they find.
    func processAll(_ operation: AllOperation, _ text: String, replacement: String,
                    options: SearchOptions, onMatch: ((Match) -> Void)? = nil) -> AllOutcome {
        let (range, scope) = scope(for: operation, options: options)
        guard !text.isEmpty else { return .done(0, scope: scope) }
        let pattern = bytes(options.prepared(text))
        var flags = options.searchFlags | Int(SCFIND_REGEXP_SKIPCRLFASONE)
        if operation == .replaceAll { flags |= Int(SCFIND_REGEXP_EMPTYMATCH_NOTAFTERMATCH) }

        if operation == .replaceAll { editor.send(SCI_BEGINUNDOACTION) }
        defer { if operation == .replaceAll { editor.send(SCI_ENDUNDOACTION) } }

        var start = range.lowerBound, end = range.upperBound
        var count = 0
        loop: while true {
            switch search(pattern, flags: flags, from: start, to: end) {
            case .invalidRegex: return .invalidRegex
            case .notFound: break loop
            case .found(let match, _):
                guard match.end <= end else { break loop }
                var delta = 0
                onMatch?(match)
                if operation == .replaceAll {
                    delta = replaceTarget(with: replacement, options: options) - (match.end - match.start)
                }
                count += 1
                let reachedEnd = match.end == end  // stops an endless "$" replace
                start = match.end + delta
                end += delta
                if reachedEnd { break loop }
            }
        }
        if operation == .replaceAll && scope == .selection {
            editor.send(SCI_SETSEL, range.lowerBound, end)
        }
        return .done(count, scope: scope)
    }

    // MARK: - Scintilla

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    private func search(_ pattern: [UInt8], flags: Int, from: Int, to: Int) -> Outcome {
        guard !pattern.isEmpty else { return .notFound }
        editor.send(SCI_SETSEARCHFLAGS, flags)
        editor.send(SCI_SETTARGETRANGE, from, to)
        let position = pattern.withUnsafeBytes { editor.send(SCI_SEARCHINTARGET, pattern.count, pointer: $0.baseAddress) }
        if position == -2 { return .invalidRegex }
        guard position >= 0 else { return .notFound }
        return .found(Match(start: position, end: editor.send(SCI_GETTARGETEND)), wrapped: false)
    }

    /// Replaces the target: Boost's format string in Regex mode, the converted text in Extended
    /// mode, the literal text otherwise. Returns the inserted length.
    private func replaceTarget(with replacement: String, options: SearchOptions) -> Int {
        let text = bytes(options.prepared(replacement))
        let message = options.mode == .regex ? SCI_REPLACETARGETRE : SCI_REPLACETARGET
        return text.withUnsafeBytes { editor.send(message, text.count, pointer: $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1)) }
    }

    /// Searching::displaySectionCentered: unfold, scroll into view, select with the caret at the end.
    private func select(_ match: Match) {
        let firstLine = editor.send(SCI_LINEFROMPOSITION, match.start)
        let lastLine = editor.send(SCI_LINEFROMPOSITION, match.end)
        for line in firstLine...lastLine { editor.send(SCI_ENSUREVISIBLE, line) }
        editor.send(SCI_GOTOPOS, match.end)
        editor.send(SCI_SETANCHOR, match.start)
        editor.send(SCI_SCROLLRANGE, match.start, match.end)
    }
}

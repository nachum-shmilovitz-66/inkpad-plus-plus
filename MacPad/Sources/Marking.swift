import AppKit

/// Notepad++'s indicator and marker numbers (ScintillaEditView.h, SciLexer.h).
enum MarkIndicator {
    /// The Find dialog's Mark All ("Find Mark Style").
    static let findMark = 31
    /// "Mark Style 1" … "Mark Style 5" (SCE_UNIVERSAL_FOUND_STYLE_EXT1…5).
    static let styles = [25, 24, 23, 22, 21]
    /// Incremental search's "Highlight all" (SCE_UNIVERSAL_FOUND_STYLE_INC).
    static let incremental = 28
    /// MARK_BOOKMARK.
    static let bookmark = 20

    /// The stylers.model.xml entry for each indicator, and Notepad++'s fallback colour (RRGGBB).
    static let themeEntries: [(indicator: Int, name: String, fallback: String)] = [
        (findMark, "Find Mark Style", "FF0000"),
        (incremental, "Incremental highlight all", "0080FF"),
        (25, "Mark Style 1", "00FFFF"),
        (24, "Mark Style 2", "FF8000"),
        (23, "Mark Style 3", "FFFF00"),
        (22, "Mark Style 4", "8000FF"),
        (21, "Mark Style 5", "008000"),
    ]
}

/// Mark All, the five token styles and bookmarks (MAC-31), ported from Notepad++'s
/// FindReplaceDlg (Mark tab), NppCommands.cpp and Notepad_plus.cpp, on one Scintilla view.
struct Marker {
    let editor: ScintillaView

    // MARK: - Mark tab

    /// Mark All: every match in the scope gets the Find Mark indicator; with `bookmarkLine` the
    /// lines it spans are bookmarked too. Empty matches are skipped. `purge` clears earlier marks
    /// first — only when there is something to search.
    func markAll(_ text: String, options: SearchOptions, bookmarkLine: Bool, purge: Bool) -> SearchEngine.AllOutcome {
        let engine = SearchEngine(editor: editor)
        let (range, _) = engine.scope(for: .count, options: options)
        if purge && !text.isEmpty && !range.isEmpty {
            clearMarks(inSelection: options.inSelection && engine.hasUsableSelection, bookmarkLine: bookmarkLine)
        }
        return engine.processAll(.count, text, replacement: "", options: options) { match in
            guard match.end > match.start else { return }
            editor.send(SCI_SETINDICATORCURRENT, MarkIndicator.findMark)
            editor.send(SCI_INDICATORFILLRANGE, match.start, match.end - match.start)
            if bookmarkLine {
                let first = editor.send(SCI_LINEFROMPOSITION, match.start)
                let last = editor.send(SCI_LINEFROMPOSITION, match.end - 1)
                for line in first...last { addBookmark(line) }
            }
        }
    }

    /// Clear all marks: the Find Mark indicator (in the selection, or everywhere), and the
    /// bookmarks of the same lines only when Bookmark line is ticked.
    func clearMarks(inSelection: Bool, bookmarkLine: Bool) {
        if inSelection {
            let start = editor.send(SCI_GETSELECTIONSTART), end = editor.send(SCI_GETSELECTIONEND)
            clear(MarkIndicator.findMark, from: start, to: end)
            if bookmarkLine && end > start {
                let first = editor.send(SCI_LINEFROMPOSITION, start), last = editor.send(SCI_LINEFROMPOSITION, end - 1)
                for line in first...last { removeBookmark(line) }
            }
        } else {
            clear(MarkIndicator.findMark, from: 0, to: editor.send(SCI_GETLENGTH))
            if bookmarkLine { editor.send(SCI_MARKERDELETEALL, MarkIndicator.bookmark) }
        }
    }

    // MARK: - Token styles

    /// Style All Occurrences of Token: the selection, or the word at the caret (which becomes
    /// selected), marked everywhere as a whole word, ignoring case (Notepad++'s MarkAll defaults).
    @discardableResult
    func styleAllOccurrences(style: Int, matchCase: Bool = false, wholeWord: Bool = true) -> Int {
        guard let token = selectedTextOrWord(selectWord: true) else { return 0 }
        var options = SearchOptions(mode: .normal, matchCase: matchCase, wholeWord: wholeWord, wrapAround: true)
        options.inSelection = false
        let indicator = MarkIndicator.styles[style]
        let outcome = SearchEngine(editor: editor).processAll(.count, token, replacement: "", options: options) { match in
            guard match.end > match.start else { return }
            editor.send(SCI_SETINDICATORCURRENT, indicator)
            editor.send(SCI_INDICATORFILLRANGE, match.start, match.end - match.start)
        }
        if case .done(let n, _) = outcome { return n }
        return 0
    }

    /// Style One Token: just the selection, or the word at the caret.
    func styleOneToken(style: Int) {
        var start = editor.send(SCI_GETSELECTIONSTART), end = editor.send(SCI_GETSELECTIONEND)
        if start == end {
            start = editor.send(SCI_WORDSTARTPOSITION, start, 1)
            end = editor.send(SCI_WORDENDPOSITION, end, 1)
        }
        guard end > start else { return }
        editor.send(SCI_SETINDICATORCURRENT, MarkIndicator.styles[style])
        editor.send(SCI_INDICATORFILLRANGE, start, end - start)
    }

    func clearStyle(_ indicator: Int) { clear(indicator, from: 0, to: editor.send(SCI_GETLENGTH)) }

    /// "Clear all Styles": the five token styles, not the Find Mark.
    func clearAllStyles() { MarkIndicator.styles.forEach(clearStyle) }

    /// Jump Down / Up to the next range of one indicator, wrapping around. Down selects it with
    /// the caret at its end, Up with the caret at its start. False when there is no such range.
    @discardableResult
    func jump(to indicator: Int, down: Bool) -> Bool {
        let length = editor.send(SCI_GETLENGTH)
        guard length > 0 else { return false }
        let caret = editor.send(SCI_GETCURRENTPOS)
        let range: Range<Int>?
        if down {
            var pos = caret
            if isMarked(indicator, at: pos) { pos = editor.send(SCI_INDICATOREND, indicator, pos) }
            range = rangeStarting(atOrAfter: pos, indicator) ?? rangeStarting(atOrAfter: 0, indicator)
        } else {
            var pos = caret
            if pos > 0 && isMarked(indicator, at: pos - 1) { pos = editor.send(SCI_INDICATORSTART, indicator, pos - 1) }
            range = rangeEnding(atOrBefore: pos, indicator) ?? rangeEnding(atOrBefore: length, indicator)
        }
        guard let range else { return false }
        editor.send(SCI_ENSUREVISIBLE, editor.send(SCI_LINEFROMPOSITION, range.lowerBound))
        if down {
            editor.send(SCI_SETSEL, range.lowerBound, range.upperBound)
        } else {
            editor.send(SCI_SETSEL, range.upperBound, range.lowerBound)
        }
        editor.send(SCI_SCROLLCARET)
        return true
    }

    /// Copy Marked / Styled Text: the ranges of `indicators` in document order, joined by a
    /// CRLF — or by CRLF "----" CRLF when any of them spans lines — with a trailing CRLF when
    /// there are several. Nil when nothing is marked (Notepad++ leaves the clipboard alone).
    func markedText(_ indicators: [Int]) -> String? {
        let bytes = editor.utf8Bytes()
        let pieces = indicators.flatMap { ranges(of: $0) }.sorted { $0.lowerBound < $1.lowerBound }
            .map { String(decoding: bytes[$0], as: UTF8.self) }
        guard !pieces.isEmpty else { return nil }
        let multiLine = pieces.count > 1 && pieces.contains { $0.contains("\r") || $0.contains("\n") }
        var joined = pieces.joined(separator: multiLine ? "\r\n----\r\n" : "\r\n")
        if pieces.count > 1 { joined += "\r\n" }
        return joined
    }

    /// Every range of `indicator`, in order.
    func ranges(of indicator: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var pos = 0
        while let range = rangeStarting(atOrAfter: pos, indicator) {
            if let last = result.last, range.lowerBound <= last.lowerBound { break }
            result.append(range)
            pos = range.upperBound
        }
        return result
    }

    // MARK: - Bookmarks

    func hasBookmark(_ line: Int) -> Bool {
        editor.send(SCI_MARKERGET, line) & (1 << MarkIndicator.bookmark) != 0
    }

    func addBookmark(_ line: Int) {
        if !hasBookmark(line) { editor.send(SCI_MARKERADD, line, MarkIndicator.bookmark) }
    }

    func removeBookmark(_ line: Int) {
        while hasBookmark(line) { editor.send(SCI_MARKERDELETE, line, MarkIndicator.bookmark) }
    }

    /// Toggle Bookmark; the caret line when `line` is nil.
    func toggleBookmark(_ line: Int? = nil) {
        let line = line ?? editor.send(SCI_LINEFROMPOSITION, editor.send(SCI_GETCURRENTPOS))
        hasBookmark(line) ? removeBookmark(line) : addBookmark(line)
    }

    var bookmarkedLines: [Int] {
        var lines: [Int] = []
        var line = editor.send(SCI_MARKERNEXT, 0, 1 << MarkIndicator.bookmark)
        while line >= 0 {
            lines.append(line)
            line = editor.send(SCI_MARKERNEXT, line + 1, 1 << MarkIndicator.bookmark)
        }
        return lines
    }

    func setBookmarks(_ lines: [Int]) {
        editor.send(SCI_MARKERDELETEALL, MarkIndicator.bookmark)
        let count = editor.send(SCI_GETLINECOUNT)
        for line in lines where line >= 0 && line < count { addBookmark(line) }
    }

    func clearAllBookmarks() { editor.send(SCI_MARKERDELETEALL, MarkIndicator.bookmark) }

    /// Next / Previous Bookmark, wrapping around. False when there are none.
    @discardableResult
    func gotoBookmark(next: Bool) -> Bool {
        let current = editor.send(SCI_LINEFROMPOSITION, editor.send(SCI_GETCURRENTPOS))
        let mask = 1 << MarkIndicator.bookmark
        var line = next ? editor.send(SCI_MARKERNEXT, current + 1, mask) : editor.send(SCI_MARKERPREVIOUS, current - 1, mask)
        if line < 0 {
            line = next ? editor.send(SCI_MARKERNEXT, 0, mask)
                        : editor.send(SCI_MARKERPREVIOUS, editor.send(SCI_GETLINECOUNT), mask)
        }
        guard line >= 0 else { return false }
        editor.send(SCI_ENSUREVISIBLEENFORCEPOLICY, line)
        editor.send(SCI_GOTOLINE, line)
        editor.send(SCI_CHOOSECARETX)
        return true
    }

    /// Copy Bookmarked Lines: each line with its own line ending, in document order.
    func bookmarkedLinesText() -> String {
        let bytes = editor.utf8Bytes()
        var out = Data()
        for line in bookmarkedLines {
            let start = editor.send(SCI_POSITIONFROMLINE, line)
            out.append(bytes[start..<start + editor.send(SCI_LINELENGTH, line)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Cut Bookmarked Lines: their text (as Copy), then the lines removed, in one undo step.
    func cutBookmarkedLines() -> String {
        let text = bookmarkedLinesText()
        removeLines { hasBookmark($0) }
        return text
    }

    func removeBookmarkedLines() { removeLines { hasBookmark($0) } }
    func removeUnbookmarkedLines() { removeLines { !hasBookmark($0) } }

    /// Paste to (Replace) Bookmarked Lines: each bookmarked line's text (not its line ending)
    /// becomes `text`, as is.
    func replaceBookmarkedLines(with text: String) {
        let lines = bookmarkedLines
        guard !lines.isEmpty else { return }
        let bytes = Array(text.utf8)
        editor.send(SCI_BEGINUNDOACTION)
        for line in lines.reversed() {
            editor.send(SCI_SETTARGETRANGE, editor.send(SCI_POSITIONFROMLINE, line), editor.send(SCI_GETLINEENDPOSITION, line))
            editor.replaceTarget(bytes)
        }
        editor.send(SCI_ENDUNDOACTION)
    }

    /// Inverse Bookmark: every line flips.
    func inverseBookmarks() {
        for line in 0..<editor.send(SCI_GETLINECOUNT) { toggleBookmark(line) }
    }

    // MARK: - Helpers

    /// Deletes each matching line with its line ending, bottom-up, as one undo step.
    private func removeLines(where matches: (Int) -> Bool) {
        editor.send(SCI_BEGINUNDOACTION)
        for line in stride(from: editor.send(SCI_GETLINECOUNT) - 1, through: 0, by: -1) where matches(line) {
            removeBookmark(line)
            let start = editor.send(SCI_POSITIONFROMLINE, line)
            editor.send(SCI_DELETERANGE, start, editor.send(SCI_LINELENGTH, line))
        }
        editor.send(SCI_ENDUNDOACTION)
    }

    private func selectedTextOrWord(selectWord: Bool) -> String? {
        var start = editor.send(SCI_GETSELECTIONSTART), end = editor.send(SCI_GETSELECTIONEND)
        if start == end {
            start = editor.send(SCI_WORDSTARTPOSITION, start, 1)
            end = editor.send(SCI_WORDENDPOSITION, end, 1)
            guard end > start else { return nil }
            if selectWord { editor.send(SCI_SETSEL, start, end) }
        }
        return String(decoding: editor.utf8Bytes()[start..<end], as: UTF8.self)
    }

    private func clear(_ indicator: Int, from start: Int, to end: Int) {
        guard end > start else { return }
        editor.send(SCI_SETINDICATORCURRENT, indicator)
        editor.send(SCI_INDICATORCLEARRANGE, start, end - start)
    }

    private func isMarked(_ indicator: Int, at pos: Int) -> Bool {
        editor.send(SCI_INDICATORVALUEAT, indicator, pos) != 0
    }

    private func rangeStarting(atOrAfter pos: Int, _ indicator: Int) -> Range<Int>? {
        let length = editor.send(SCI_GETLENGTH)
        guard pos < length else { return nil }
        let start = isMarked(indicator, at: pos) ? pos : editor.send(SCI_INDICATOREND, indicator, pos)
        guard start < length, isMarked(indicator, at: start) else { return nil }
        return start..<editor.send(SCI_INDICATOREND, indicator, start)
    }

    private func rangeEnding(atOrBefore pos: Int, _ indicator: Int) -> Range<Int>? {
        guard pos > 0 else { return nil }
        var last = pos - 1
        if !isMarked(indicator, at: last) { last = editor.send(SCI_INDICATORSTART, indicator, last) - 1 }
        guard last >= 0, isMarked(indicator, at: last) else { return nil }
        return editor.send(SCI_INDICATORSTART, indicator, last)..<editor.send(SCI_INDICATOREND, indicator, last)
    }
}

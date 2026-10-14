import AppKit

/// Notepad++'s Convert Case to (MAC-40): ScintillaEditView::changeCase, per character, on the
/// selected text only (each piece of a multi-selection on its own).
enum CaseConversion: Int, CaseIterable {
    case upper, lower, proper, properBlend, sentence, sentenceBlend, invert, random

    var title: String {
        ["UPPERCASE", "lowercase", "Proper Case", "Proper Case (blend)", "Sentence case", "Sentence case (blend)",
         "iNVERT cASE", "ranDOm CasE"][rawValue]
    }

    func apply(_ text: String) -> String {
        var c = Array(text.unicodeScalars)
        let n = c.count
        func isAlpha(_ s: Unicode.Scalar) -> Bool { s.properties.isAlphabetic }
        func isAlnum(_ s: Unicode.Scalar) -> Bool { s.properties.isAlphabetic || s.properties.numericType != nil }
        func isQuote(_ s: Unicode.Scalar) -> Bool { s == "'" || s == "\u{2019}" || s == "\u{2018}" }
        func isSpace(_ s: Unicode.Scalar) -> Bool { s.properties.isWhitespace }
        switch self {
        case .upper: return String(String.UnicodeScalarView(c.map(Self.upper)))
        case .lower: return String(String.UnicodeScalarView(c.map(Self.lower)))
        case .invert:
            return String(String.UnicodeScalarView(c.map { $0.properties.isLowercase ? Self.upper($0) : Self.lower($0) }))
        case .random:
            return String(String.UnicodeScalarView(c.map { isAlpha($0) ? (Bool.random() ? Self.upper($0) : Self.lower($0)) : $0 }))
        case .proper, .properBlend:
            let force = self == .proper
            for i in 0..<n where isAlpha(c[i]) {
                if i >= 2 && isQuote(c[i - 1]) && isAlnum(c[i - 2]) {
                    if force { c[i] = Self.lower(c[i]) }  // don't, O'neil
                } else if i == 0 || !isAlnum(c[i - 1]) {
                    c[i] = Self.upper(c[i])
                } else if force {
                    c[i] = Self.lower(c[i])
                }
            }
        case .sentence, .sentenceBlend:
            let force = self == .sentence
            var newSentence = true, wasR = false, wasN = false
            for i in 0..<n {
                let s = c[i]
                if isAlpha(s) {
                    if newSentence {
                        c[i] = Self.upper(s)
                        newSentence = false
                    } else if force {
                        c[i] = Self.lower(s)
                    }
                    wasR = false
                    wasN = false
                    // The pronoun "i", standing alone.
                    if s == "i" && i >= 1 && (isSpace(c[i - 1]) || c[i - 1] == "(" || c[i - 1] == "\"")
                        && i + 1 < n && (isSpace(c[i + 1]) || c[i + 1] == "'") {
                        c[i] = "I"
                    }
                } else if s == "." || s == "!" || s == "?" {
                    newSentence = !(i + 1 == n || isAlnum(c[i + 1]))
                } else if s == "\r" {
                    if wasR { newSentence = true } else { wasR = true }
                } else if s == "\n" {
                    if wasN { newSentence = true } else { wasN = true }
                }
            }
        }
        return String(String.UnicodeScalarView(c))
    }

    /// One scalar to one scalar (CharUpperW maps a single code unit; ß stays ß).
    private static func upper(_ s: Unicode.Scalar) -> Unicode.Scalar {
        let mapped = s.properties.uppercaseMapping.unicodeScalars
        return mapped.count == 1 ? mapped.first! : s
    }

    private static func lower(_ s: Unicode.Scalar) -> Unicode.Scalar {
        let mapped = s.properties.lowercaseMapping.unicodeScalars
        return mapped.count == 1 ? mapped.first! : s
    }
}

/// Edit menu commands on one Scintilla view (MAC-40).
struct EditCommands {
    let editor: ScintillaView

    private func line(of pos: Int) -> Int { editor.send(SCI_LINEFROMPOSITION, pos) }
    private func lineStart(_ line: Int) -> Int { editor.send(SCI_POSITIONFROMLINE, line) }
    private func lineEnd(_ line: Int) -> Int { editor.send(SCI_GETLINEENDPOSITION, line) }
    private func text(_ range: Range<Int>) -> String { String(decoding: editor.utf8Bytes()[range], as: UTF8.self) }

    private func replace(_ range: Range<Int>, with text: String) {
        let bytes = Array(text.utf8)
        editor.send(SCI_SETTARGETRANGE, range.lowerBound, range.upperBound)
        bytes.withUnsafeBytes { editor.send(SCI_REPLACETARGET, bytes.count, pointer: $0.baseAddress ?? UnsafeRawPointer(bitPattern: 1)) }
    }

    private func insert(_ text: String, at position: Int) { editor.send(SCI_INSERTTEXT, position, string: text) }
    private func delete(_ start: Int, _ count: Int) { editor.send(SCI_DELETERANGE, start, count) }

    // MARK: - Convert Case

    /// The selection (every piece of it) converted; nothing happens without a selection.
    func convertCase(_ conversion: CaseConversion) {
        let count = editor.send(SCI_GETSELECTIONS)
        if count == 1 {
            let start = editor.send(SCI_GETSELECTIONSTART), end = editor.send(SCI_GETSELECTIONEND)
            guard end > start else { return }
            let converted = conversion.apply(text(start..<end))
            editor.send(SCI_BEGINUNDOACTION)
            replace(start..<end, with: converted)
            editor.send(SCI_ENDUNDOACTION)
            editor.send(SCI_SETSEL, start, start + converted.utf8.count)
            return
        }
        // Several pieces: each converted on its own, in document order, keeping the selections.
        let pieces = (0..<count).map { i -> (index: Int, start: Int, end: Int, caretFirst: Bool) in
            let anchor = editor.send(SCI_GETSELECTIONNANCHOR, i), caret = editor.send(SCI_GETSELECTIONNCARET, i)
            return (i, min(anchor, caret), max(anchor, caret), caret < anchor)
        }.sorted { $0.start < $1.start }
        var offset = 0
        var results: [(start: Int, end: Int, caretFirst: Bool)] = []
        editor.send(SCI_BEGINUNDOACTION)
        for piece in pieces {
            let start = piece.start + offset, end = piece.end + offset
            let converted = conversion.apply(text(start..<end))
            replace(start..<end, with: converted)
            let newEnd = start + converted.utf8.count
            offset += newEnd - end
            results.append((start, newEnd, piece.caretFirst))
        }
        editor.send(SCI_ENDUNDOACTION)
        let rectangular = editor.send(SCI_GETSELECTIONMODE) == Int(SC_SEL_RECTANGLE)
        if !rectangular {
            for (i, r) in results.enumerated() {
                if i == 0 {
                    editor.send(SCI_SETSELECTION, r.caretFirst ? r.start : r.end, r.caretFirst ? r.end : r.start)
                } else {
                    editor.send(SCI_ADDSELECTION, r.caretFirst ? r.start : r.end, r.caretFirst ? r.end : r.start)
                }
            }
        }
    }

    // MARK: - Indent

    /// Increase / Decrease Line Indent: SCI_TAB / SCI_BACKTAB over several lines or selections;
    /// one line moves by a tab width, keeping the caret where it was in the text.
    func indent(increase: Bool) {
        let start = editor.send(SCI_GETSELECTIONSTART), end = editor.send(SCI_GETSELECTIONEND)
        if editor.send(SCI_GETSELECTIONS) > 1 || line(of: start) != line(of: end) {
            editor.send(increase ? SCI_TAB : SCI_BACKTAB)
            return
        }
        let lineIndex = line(of: start)
        let oldIndentPos = editor.send(SCI_GETLINEINDENTPOSITION, lineIndex)
        let current = editor.send(SCI_GETLINEINDENTATION, lineIndex)
        let width = editor.send(SCI_GETTABWIDTH)
        editor.send(SCI_SETLINEINDENTATION, lineIndex, max(current + (increase ? width : -width), 0))
        let newIndentPos = editor.send(SCI_GETLINEINDENTPOSITION, lineIndex)
        let delta = newIndentPos - oldIndentPos
        func moved(_ p: Int) -> Int { p >= oldIndentPos ? p + delta : min(p, newIndentPos) }
        editor.send(SCI_SETSEL, moved(start), moved(end))
    }

    // MARK: - Comment / Uncomment

    enum CommentMode { case toggle, comment, uncomment }

    struct Tokens {
        var line: String?
        var start: String?
        var end: String?
    }

    static func tokens(for language: LanguageInfo) -> Tokens {
        let def = LanguageCatalog.shared.languages[language.name]
        func clean(_ s: String?) -> String? { s.flatMap { $0.isEmpty ? nil : $0 } }
        return Tokens(line: clean(def?.commentLine), start: clean(def?.commentStart), end: clean(def?.commentEnd))
    }

    /// Notepad++'s doBlockComment: the line token plus a space at each line's indentation (blank
    /// lines skipped); toggle works line by line. Without a line token, each line is wrapped in the
    /// block tokens.
    @discardableResult
    func lineComment(_ mode: CommentMode, tokens: Tokens, language: String = "") -> Bool {
        let advanced: Bool
        if tokens.line != nil {
            advanced = false
        } else if tokens.start != nil && tokens.end != nil {
            if mode == .uncomment { return blockUncomment(tokens: tokens) }
            advanced = true
        } else {
            return false
        }
        let symbol = advanced ? tokens.start! : tokens.line!
        let comment = language == "baanc" ? symbol : symbol + " "
        let endComment = advanced ? " " + tokens.end! : ""
        let caret = editor.send(SCI_GETCURRENTPOS), anchor = editor.send(SCI_GETANCHOR)
        var selStart = min(caret, anchor), selEnd = max(caret, anchor)
        let caretFirst = caret < anchor
        let firstLine = line(of: selStart)
        var lastLine = line(of: selEnd)
        if lastLine > firstLine && selEnd == lineStart(lastLine) { lastLine -= 1 }
        var uncommented = 0
        editor.send(SCI_BEGINUNDOACTION)
        for lineIndex in firstLine...lastLine {
            let indentPos = (language == "fortran77" || language == "baanc") ? lineStart(lineIndex)
                : editor.send(SCI_GETLINEINDENTPOSITION, lineIndex)
            let end = lineEnd(lineIndex)
            if indentPos == end && language != "baanc" { continue }  // blank line
            let lineText = text(indentPos..<end)
            if mode != .comment, lineText.lowercased().hasPrefix(symbol.lowercased()),
               !advanced || lineText.hasSuffix(tokens.end!) {
                var removeEnd = 0
                if advanced {
                    let endToken = tokens.end!
                    let hasSpace = lineText.dropLast(endToken.count).hasSuffix(" ")
                    removeEnd = endToken.utf8.count + (hasSpace ? 1 : 0)
                    delete(end - removeEnd, removeEnd)
                }
                let afterSymbol = lineText.dropFirst(symbol.count)
                let removeStart = symbol.utf8.count + (afterSymbol.hasPrefix(" ") ? 1 : 0)
                delete(indentPos, removeStart)
                func shift(_ p: Int) -> Int {
                    if p > end { return p - removeStart - removeEnd }
                    if p > indentPos + removeStart { return p - removeStart }
                    return p > indentPos ? indentPos : p
                }
                selStart = shift(selStart)
                selEnd = shift(selEnd)
                uncommented += 1
                continue
            }
            if mode == .uncomment { continue }
            if advanced { insert(endComment, at: end) }
            insert(comment, at: indentPos)
            let added = comment.utf8.count
            if selStart >= indentPos { selStart += added }
            if selEnd >= indentPos { selEnd += added }
            if advanced && selEnd > end + added { selEnd += endComment.utf8.count }
        }
        editor.send(SCI_ENDUNDOACTION)
        if caretFirst {
            editor.send(SCI_GOTOPOS, selEnd)
            editor.send(SCI_SETCURRENTPOS, selStart)
        } else {
            editor.send(SCI_SETSEL, selStart, selEnd)
        }
        if mode == .uncomment && uncommented == 0 && tokens.start != nil { return blockUncomment(tokens: tokens) }
        return true
    }

    /// Block Comment (doStreamComment): the block tokens around the selection, or around the
    /// current line's text; languages with only a line token comment the lines instead.
    func blockComment(tokens: Tokens, language: String = "") {
        guard let start = tokens.start, let end = tokens.end else {
            if tokens.line != nil { lineComment(.comment, tokens: tokens, language: language) }
            return
        }
        var selStart = editor.send(SCI_GETSELECTIONSTART), selEnd = editor.send(SCI_GETSELECTIONEND)
        let caretFirst = editor.send(SCI_GETCURRENTPOS) < editor.send(SCI_GETANCHOR)
        if selStart == selEnd {
            let l = line(of: selStart)
            selStart = editor.send(SCI_GETLINEINDENTPOSITION, l)
            selEnd = lineEnd(l)
        }
        let open = start + " ", close = " " + end
        editor.send(SCI_BEGINUNDOACTION)
        insert(close, at: selEnd)
        insert(open, at: selStart)
        editor.send(SCI_ENDUNDOACTION)
        let newStart = selStart + open.utf8.count, newEnd = selEnd + open.utf8.count
        if caretFirst {
            editor.send(SCI_GOTOPOS, newEnd)
            editor.send(SCI_SETCURRENTPOS, newStart)
        } else {
            editor.send(SCI_SETSEL, newStart, newEnd)
        }
    }

    /// Block Uncomment (undoStreamComment): removes every block comment the selection is in or
    /// covers, with one space inside each token when present.
    @discardableResult
    func blockUncomment(tokens: Tokens, language: String = "") -> Bool {
        guard let startToken = tokens.start, let endToken = tokens.end else {
            if tokens.line != nil { return lineComment(.uncomment, tokens: Tokens(line: tokens.line), language: language) }
            return false
        }
        var removedAny = false
        editor.send(SCI_BEGINUNDOACTION)
        defer { editor.send(SCI_ENDUNDOACTION) }
        for _ in 0..<1000 {
            let bytes = Array(editor.utf8Bytes())
            let selStart = editor.send(SCI_GETSELECTIONSTART), selEnd = editor.send(SCI_GETSELECTIONEND)
            let open = Array(startToken.utf8), close = Array(endToken.utf8)
            func last(_ needle: [UInt8], before p: Int) -> Int? {
                guard p > 0 else { return nil }
                return stride(from: min(p, bytes.count) - needle.count, through: 0, by: -1)
                    .first { Array(bytes[$0..<min($0 + needle.count, bytes.count)]) == needle }
            }
            func next(_ needle: [UInt8], from p: Int) -> Int? {
                guard needle.count <= bytes.count else { return nil }
                return stride(from: max(p, 0), through: bytes.count - needle.count, by: 1)
                    .first { Array(bytes[$0..<$0 + needle.count]) == needle }
            }
            func enclosing(_ p: Int) -> (Int, Int)? {
                guard let s = last(open, before: p), let e = next(close, from: max(p, s + open.count)) else { return nil }
                if let closeBefore = last(close, before: p), closeBefore > s { return nil }
                if let openAfter = next(open, from: p), openAfter < e { return nil }
                return (s, e)
            }
            var pair = enclosing(selStart) ?? enclosing(selEnd)
            if pair == nil, let s = next(open, from: selStart), s < selEnd, let e = next(close, from: s + open.count) {
                pair = (s, e)
            }
            guard let (s, e) = pair else { break }
            let spaceBefore = e > 0 && bytes[e - 1] == UInt8(ascii: " ") && e - 1 >= s + open.count
            delete(spaceBefore ? e - 1 : e, close.count + (spaceBefore ? 1 : 0))
            let spaceAfter = s + open.count < bytes.count && bytes[s + open.count] == UInt8(ascii: " ")
            delete(s, open.count + (spaceAfter ? 1 : 0))
            removedAny = true
        }
        return removedAny
    }

    // MARK: - Begin/End Select

    /// First call remembers the caret; the second selects from there (as a column in column mode).
    static func beginOrEndSelect(_ editor: ScintillaView, begin: inout Int?, columnMode: Bool) {
        let current = editor.send(SCI_GETCURRENTPOS)
        guard let start = begin else {
            begin = current
            return
        }
        editor.send(SCI_CHANGESELECTIONMODE, Int(columnMode ? SC_SEL_RECTANGLE : SC_SEL_STREAM))
        if columnMode {
            editor.send(SCI_SETANCHOR, start)
        } else {
            editor.send(SCI_SETSEL, start, current)
        }
        begin = nil
    }
}

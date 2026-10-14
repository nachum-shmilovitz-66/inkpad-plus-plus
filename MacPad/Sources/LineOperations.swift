import AppKit

/// Notepad++'s Edit › Line Operations and Edit › Blank Operations (MAC-39), on one Scintilla view.
/// Each command is one undo step; "blank" means space and tab only, as in Notepad++.
struct LineOperations {
    let editor: ScintillaView

    // MARK: - Helpers

    /// getSelectionLinesRange: the selection's lines, without the last one when the selection ends
    /// at its column 0; the caret line when nothing is selected.
    var selectionLines: ClosedRange<Int> {
        let start = editor.send(SCI_GETSELECTIONSTART), end = editor.send(SCI_GETSELECTIONEND)
        let first = line(of: start)
        var last = line(of: end)
        if last > first && end == lineStart(last) { last -= 1 }
        return first...last
    }

    private var hasSelection: Bool { editor.send(SCI_GETSELECTIONEND) > editor.send(SCI_GETSELECTIONSTART) }
    private var isRectangular: Bool {
        let mode = editor.send(SCI_GETSELECTIONMODE)
        return mode == Int(SC_SEL_RECTANGLE) || mode == Int(SC_SEL_THIN)
    }

    private func line(of position: Int) -> Int { editor.send(SCI_LINEFROMPOSITION, position) }
    private func lineStart(_ line: Int) -> Int { editor.send(SCI_POSITIONFROMLINE, line) }
    private func lineEnd(_ line: Int) -> Int { editor.send(SCI_GETLINEENDPOSITION, line) }
    private var lineCount: Int { editor.send(SCI_GETLINECOUNT) }
    private var length: Int { editor.send(SCI_GETLENGTH) }

    /// The document's line ending (getEOLString).
    var eol: String {
        switch editor.send(SCI_GETEOLMODE) {
        case Int(SC_EOL_CRLF): return "\r\n"
        case Int(SC_EOL_CR): return "\r"
        default: return "\n"
        }
    }

    private func text(_ range: Range<Int>) -> String {
        String(decoding: editor.utf8Bytes()[range], as: UTF8.self)
    }

    private func replace(_ range: Range<Int>, with text: String) {
        let bytes = Array(text.utf8)
        editor.send(SCI_SETTARGETRANGE, range.lowerBound, range.upperBound)
        editor.replaceTarget(bytes)
    }

    private func undoGroup<T>(_ body: () throws -> T) rethrows -> T {
        editor.send(SCI_BEGINUNDOACTION)
        defer { editor.send(SCI_ENDUNDOACTION) }
        return try body()
    }

    /// Replace-all of a Boost regex with nothing in `range`; returns the range's new end, or nil
    /// when nothing matched.
    @discardableResult
    private func deleteAll(_ pattern: String, in range: Range<Int>) -> Int? {
        let bytes = Array(pattern.utf8)
        var start = range.lowerBound, end = range.upperBound
        var changed = false
        editor.send(SCI_SETSEARCHFLAGS, Int(SCFIND_REGEXP | SCFIND_POSIX))
        while start <= end {
            editor.send(SCI_SETTARGETRANGE, start, end)
            let found = editor.searchInTarget(bytes)
            guard found >= 0 else { break }
            let matchEnd = editor.send(SCI_GETTARGETEND)
            if matchEnd == found { start = found + 1; continue }  // never loop on an empty match
            editor.replaceTarget([])
            end -= matchEnd - found
            start = found
            changed = true
        }
        return changed ? end : nil
    }

    // MARK: - Line Operations

    /// Duplicate Current Line (SCI_LINEDUPLICATE).
    func duplicateLine() { editor.send(SCI_LINEDUPLICATE) }

    /// Move Up / Move Down Current Line (SCI_MOVESELECTEDLINESUP/DOWN).
    func moveLines(up: Bool) {
        if isRectangular { editor.send(SCI_SETSELECTIONMODE, Int(SC_SEL_STREAM)) }
        editor.send(up ? SCI_MOVESELECTEDLINESUP : SCI_MOVESELECTEDLINESDOWN)
    }

    /// Join Lines: the selected lines become one, each line end replaced by a space unless the
    /// line already ends with one (SCI_LINESJOIN).
    func joinLines() {
        let lines = selectionLines
        guard lines.count > 1 else { return }
        undoGroup {
            editor.send(SCI_SETTARGETRANGE, lineStart(lines.lowerBound), lineEnd(lines.upperBound))
            editor.send(SCI_LINESJOIN)
        }
    }

    /// Split Lines: re-flow the selected lines at the edge column, or at the window width when
    /// there is no edge (SCI_LINESSPLIT).
    func splitLines() {
        guard editor.send(SCI_GETSELECTIONS) == 1 else { return }
        let lines = selectionLines
        let start = lineStart(lines.lowerBound), end = lineEnd(lines.upperBound)
        editor.send(SCI_SETSEL, start, end)
        var width = 0
        if editor.send(SCI_GETEDGEMODE) != Int(EDGE_NONE) {
            let column = Preferences.current.edgeColumns.last ?? editor.send(SCI_GETEDGECOLUMN)
            width = editor.send(SCI_TEXTWIDTH, Int(STYLE_DEFAULT), string: "P") * (column + 1)
        }
        undoGroup {
            editor.send(SCI_SETTARGETRANGE, start, end)
            editor.send(SCI_LINESSPLIT, width)
        }
    }

    /// Insert Blank Line Above / Below Current: the caret moves onto the new line.
    func insertBlankLine(above: Bool) {
        let current = line(of: editor.send(SCI_GETCURRENTPOS))
        let eolBytes = Array(eol.utf8)
        if above {
            let at = current == 0 ? 0 : lineStart(current) - eolBytes.count
            insert(eol, at: at)
            editor.send(SCI_SETEMPTYSELECTION, lineStart(current))
        } else {
            if current == lineCount - 1 {
                insert(eol, at: length)
            } else {
                insert(eol, at: lineEnd(current) + eolBytes.count)
            }
            editor.send(SCI_SETEMPTYSELECTION, lineStart(current + 1))
        }
    }

    private func insert(_ text: String, at position: Int) {
        editor.send(SCI_INSERTTEXT, position, string: text)
    }

    /// Remove Consecutive Duplicate Lines: each run of identical lines (line endings included)
    /// keeps its first line.
    func removeConsecutiveDuplicateLines() {
        let range: ClosedRange<Int> = hasSelection ? selectionLines : 0...(lineCount - 1)
        guard range.count > 1 else { return }
        undoGroup {
            var lineIndex = range.lowerBound
            var last = range.upperBound
            while lineIndex < last {
                let current = text(lineStart(lineIndex)..<lineStart(lineIndex + 1))
                var runEnd = lineIndex + 1
                while runEnd <= last && runEnd + 1 <= lineCount - 1 && text(lineStart(runEnd)..<lineStart(runEnd + 1)) == current {
                    runEnd += 1
                }
                if runEnd > lineIndex + 1 {
                    editor.send(SCI_DELETERANGE, lineStart(lineIndex + 1), lineStart(runEnd) - lineStart(lineIndex + 1))
                    last -= runEnd - lineIndex - 1
                }
                lineIndex += 1
            }
            // The last line has no line ending: compare it without the previous one's.
            if last == lineCount - 1, last > range.lowerBound {
                let lastText = text(lineStart(last)..<length)
                let previous = text(lineStart(last - 1)..<lineEnd(last - 1))
                if !lastText.isEmpty && lastText == previous {
                    editor.send(SCI_DELETERANGE, lineStart(last - 1), lineStart(last) - lineStart(last - 1))
                }
            }
        }
    }

    /// Remove Duplicate Lines: every repeat of an earlier line goes, order kept (Notepad++'s
    /// removeAnyDuplicateLines, including its handling of the final empty line).
    func removeDuplicateLines() {
        let range: ClosedRange<Int>
        if hasSelection {
            range = selectionLines
            guard range.count > 1 else { return }
        } else {
            range = 0...(lineCount - 1)
        }
        let isWholeDocumentEnd = range.upperBound == lineCount - 1
        let start = lineStart(range.lowerBound)
        let end = isWholeDocumentEnd ? length : lineStart(range.upperBound + 1)
        var lines = text(start..<end).components(separatedBy: eol)
        if !isWholeDocumentEnd, lines.last == "" { lines.removeLast() }
        var seen = Set<String>()
        let unique = lines.filter { seen.insert($0).inserted }
        var joined = unique.joined(separator: eol)
        if !isWholeDocumentEnd { joined += eol }
        guard joined != text(start..<end) else { return }
        undoGroup { replace(start..<end, with: joined) }
    }

    /// Remove Empty Lines (optionally those holding only blanks), over the selection or the whole
    /// document; like Notepad++, the document's final line ending goes too.
    func removeEmptyLines(includingBlank: Bool) {
        let selected = hasSelection
        var start = selected ? editor.send(SCI_GETSELECTIONSTART) : 0
        var end = selected ? editor.send(SCI_GETSELECTIONEND) : length
        let reachesEnd = end == length
        undoGroup {
            if let newEnd = deleteAll(includingBlank ? "^(?>[\\t ]*[\\r\\n]+)+" : "^[\\r\\n]+", in: start..<end) { end = newEnd }
            if reachesEnd {
                let from = max(start, lineStart(max(lineCount - 2, 0)))
                let pattern = includingBlank ? "[\\r\\n]+^[\\t ]*$|^[\\t ]+$" : "[\\r\\n]+^$"
                let bytes = Array(pattern.utf8)
                editor.send(SCI_SETSEARCHFLAGS, Int(SCFIND_REGEXP | SCFIND_POSIX))
                editor.send(SCI_SETTARGETRANGE, from, length)
                let found = editor.searchInTarget(bytes)
                if found >= 0 { editor.send(SCI_DELETERANGE, found, length - found) }
                end = length
            }
        }
        if selected {
            start = min(start, length)
            editor.send(SCI_SETSEL, start, min(end, length))
        }
    }

    // MARK: - Sorting

    enum SortKind: Equatable {
        case lexicographic, ignoringCase, locale, integers, decimalsComma, decimalsDot, length, reverse, randomize
    }

    struct SortError: Error, Equatable {
        /// 1-based line Notepad++ names in "Unable to perform numeric sorting due to line N."
        let line: Int
        var message: String { "Unable to perform numeric sorting due to line \(line)." }
    }

    /// Sort / Reverse / Randomize the selected lines (a single line does nothing), the lines of a
    /// column selection by the selected columns, or the whole document.
    func sortLines(_ kind: SortKind, descending: Bool = false) throws {
        var first = 0, last = lineCount - 1
        var columns: Range<Int>?
        if editor.send(SCI_GETSELECTIONS) > 1 {
            guard isRectangular else { return }
            let anchor = editor.send(SCI_GETRECTANGULARSELECTIONANCHOR), caret = editor.send(SCI_GETRECTANGULARSELECTIONCARET)
            first = min(line(of: anchor), line(of: caret))
            last = max(line(of: anchor), line(of: caret))
            let a = anchor - lineStart(line(of: anchor)) + editor.send(SCI_GETRECTANGULARSELECTIONANCHORVIRTUALSPACE)
            let c = caret - lineStart(line(of: caret)) + editor.send(SCI_GETRECTANGULARSELECTIONCARETVIRTUALSPACE)
            columns = min(a, c)..<max(a, c)
        } else if hasSelection {
            let lines = selectionLines
            guard lines.count > 1 else { return }
            (first, last) = (lines.lowerBound, lines.upperBound)
        }
        // Notepad++'s Locale sort leaves an empty last line where it is.
        if kind == .locale && !hasSelection && last > first && lineStart(last) == length { last -= 1 }

        let start = lineStart(first)
        let isDocumentEnd = last == lineCount - 1
        let end = isDocumentEnd ? length : lineStart(last + 1)
        let original = text(start..<end)
        var lines = original.components(separatedBy: eol)
        if !isDocumentEnd, lines.last == "" { lines.removeLast() }

        let sorted = try LineSorter.sort(lines, kind, descending: descending, columns: columns)
        var joined = sorted.joined(separator: eol)
        if !isDocumentEnd { joined += eol }
        guard joined != original else { return }
        undoGroup { replace(start..<end, with: joined) }
        if editor.send(SCI_GETSELECTIONS) == 1 && hasSelection {
            editor.send(SCI_SETSEL, lineStart(first), lineEnd(min(last, lineCount - 1)))
        }
    }

    // MARK: - Blank Operations

    enum Trim { case trailing, leading, both }

    /// Trim Trailing / Leading / Leading and Trailing Space, over the selected lines or everything.
    func trim(_ which: Trim) {
        guard !isRectangular else { return }
        let range = blankScope()
        let pattern: String
        switch which {
        case .trailing: pattern = "[\\t ]+$"
        case .leading: pattern = "^[\\t ]+"
        case .both: pattern = "^[\\t ]+|[\\t ]+$"
        }
        let newEnd = undoGroup { deleteAll(pattern, in: range) }
        if let newEnd, hasSelection || range != 0..<length { editor.send(SCI_SETSEL, range.lowerBound, newEnd) }
    }

    /// The selection expanded to whole lines (its end at a column 0 leaves that line out), or the
    /// whole document.
    private func blankScope() -> Range<Int> {
        guard hasSelection else { return 0..<length }
        let lines = selectionLines
        return lineStart(lines.lowerBound)..<lineEnd(lines.upperBound)
    }

    /// EOL to Space: the selection's (or the document's) line endings become spaces (SCI_LINESJOIN).
    func eolToSpace() {
        guard !isRectangular else { return }
        let start = hasSelection ? editor.send(SCI_GETSELECTIONSTART) : 0
        let end = hasSelection ? editor.send(SCI_GETSELECTIONEND) : length
        undoGroup {
            editor.send(SCI_SETTARGETRANGE, start, end)
            editor.send(SCI_LINESJOIN)
        }
    }

    /// Trim both and EOL to Space.
    func trimAndEolToSpace() {
        guard !isRectangular else { return }
        undoGroup {
            trim(.both)
            if !hasSelection {
                editor.send(SCI_SETTARGETRANGE, 0, length)
                editor.send(SCI_LINESJOIN)
            } else {
                editor.send(SCI_SETTARGETRANGE, editor.send(SCI_GETSELECTIONSTART), editor.send(SCI_GETSELECTIONEND))
                editor.send(SCI_LINESJOIN)
            }
        }
    }

    enum TabConversion { case tabToSpace, spaceToTabAll, spaceToTabLeading }

    /// TAB to Space / Space to TAB (All / Leading), column-aware with the document's tab width.
    func convertTabs(_ conversion: TabConversion) {
        guard !isRectangular else { return }
        let lines: ClosedRange<Int> = hasSelection ? selectionLines : 0...(lineCount - 1)
        let tabWidth = max(editor.send(SCI_GETTABWIDTH), 1)
        var changed = false
        undoGroup {
            for index in lines.reversed() {
                let range = lineStart(index)..<lineEnd(index)
                let original = text(range)
                let converted: String
                switch conversion {
                case .tabToSpace: converted = Self.tabsToSpaces(original, tabWidth: tabWidth)
                case .spaceToTabAll: converted = Self.spacesToTabs(original, tabWidth: tabWidth, leadingOnly: false)
                case .spaceToTabLeading: converted = Self.spacesToTabs(original, tabWidth: tabWidth, leadingOnly: true)
                }
                if converted != original {
                    replace(range, with: converted)
                    changed = true
                }
            }
        }
        if changed && hasSelection {
            editor.send(SCI_SETSEL, lineStart(lines.lowerBound), lineEnd(lines.upperBound))
        }
    }

    /// Each tab becomes the spaces up to the next tab stop (columns count characters).
    static func tabsToSpaces(_ line: String, tabWidth: Int) -> String {
        var out = ""
        var column = 0
        for ch in line {
            if ch == "\t" {
                let n = tabWidth - column % tabWidth
                out += String(repeating: " ", count: n)
                column += n
            } else {
                out.append(ch)
                column += 1
            }
        }
        return out
    }

    /// Notepad++'s wsTabConvert space-to-tab: a run of spaces reaching a tab stop becomes a tab
    /// (a lone space only if a space or tab follows); spaces just before a tab are absorbed into it.
    /// Leading only stops at the first character that is not part of such a run.
    static func spacesToTabs(_ line: String, tabWidth: Int, leadingOnly: Bool) -> String {
        let chars = Array(line)
        var out = ""
        var column = 0
        var pendingSpaces = 0
        var converting = true
        var i = 0
        func flushSpaces() {
            out += String(repeating: " ", count: pendingSpaces)
            pendingSpaces = 0
        }
        while i < chars.count {
            let ch = chars[i]
            if converting && ch == " " {
                pendingSpaces += 1
                column += 1
                if column % tabWidth == 0 {
                    let next = i + 1 < chars.count ? chars[i + 1] : nil
                    if pendingSpaces >= 2 || next == " " || next == "\t" {
                        out += "\t"
                        pendingSpaces = 0
                    } else {
                        flushSpaces()
                    }
                }
            } else if converting && ch == "\t" && pendingSpaces > 0 {
                pendingSpaces = 0  // the spaces before a tab are absorbed into it
                out += "\t"
                column += tabWidth - column % tabWidth
            } else {
                flushSpaces()
                if ch == "\t" {
                    out += "\t"
                    column += tabWidth - column % tabWidth
                    if leadingOnly { converting = false }
                } else {
                    out.append(ch)
                    column += 1
                    if leadingOnly { converting = false }
                }
            }
            i += 1
        }
        flushSpaces()
        return out
    }
}

/// Notepad++'s Sorters.h, on lines (UTF-16 order as the Windows wstring comparisons).
enum LineSorter {
    static func sort(_ lines: [String], _ kind: LineOperations.SortKind, descending: Bool,
                     columns: Range<Int>? = nil) throws -> [String] {
        func key(_ line: String) -> String {
            guard let columns else { return line }
            let bytes = Array(line.utf8)
            guard bytes.count >= columns.lowerBound else { return "" }
            let slice = columns.isEmpty ? bytes[columns.lowerBound...] : bytes[columns.lowerBound..<min(columns.upperBound, bytes.count)]
            return String(decoding: slice, as: UTF8.self)
        }
        func ordered(_ before: (String, String) -> Bool) -> [String] {
            let pairs = lines.enumerated().map { (offset: $0.offset, line: $0.element, key: key($0.element)) }
            return pairs.sorted { a, b in
                if before(a.key, b.key) { return !descending }
                if before(b.key, a.key) { return descending }
                return a.offset < b.offset  // stable
            }.map(\.line)
        }
        switch kind {
        case .reverse:
            return lines.reversed()
        case .randomize:
            return lines.shuffled()
        case .lexicographic:
            return ordered { $0.utf16.lexicographicallyPrecedes($1.utf16) }
        case .ignoringCase:
            return ordered { $0.lowercased().utf16.lexicographicallyPrecedes($1.lowercased().utf16) }
        case .locale:
            return ordered { $0.localizedStandardCompare($1) == .orderedAscending }
        case .length:
            return ordered { $0.utf16.count < $1.utf16.count }
        case .integers:
            return ordered { naturalCompare($0, $1) < 0 }
        case .decimalsComma, .decimalsDot:
            return try decimals(lines, keys: lines.map(key), comma: kind == .decimalsComma, descending: descending)
        }
    }

    /// NumericSorter<double>: the longest prefix of digits, sign, separator and blanks is parsed;
    /// lines with none keep their order, first when ascending and last when descending.
    private static func decimals(_ lines: [String], keys: [String], comma: Bool, descending: Bool) throws -> [String] {
        let allowed = Set(comma ? " \t\r\n0123456789,-" : " \t\r\n0123456789.-")
        var empties: [String] = []
        var numbers: [(value: Double, offset: Int, line: String)] = []
        for (offset, line) in lines.enumerated() {
            var prepared = String(keys[offset].prefix { allowed.contains($0) })
            if comma { prepared = prepared.replacingOccurrences(of: ",", with: ".") }
            if prepared.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }) {
                empties.append(line)
                continue
            }
            var parsedEnd: UnsafeMutablePointer<CChar>?
            let value = prepared.withCString { cString -> Double? in
                let v = strtod(cString, &parsedEnd)
                guard let parsedEnd, parsedEnd != UnsafeMutablePointer(mutating: cString), v.isFinite else { return nil }
                return v
            }
            guard let value else { throw LineOperations.SortError(line: offset + 1) }
            numbers.append((value, offset, line))
        }
        let sortedNumbers = numbers.sorted {
            if $0.value != $1.value { return descending ? $0.value > $1.value : $0.value < $1.value }
            return $0.offset < $1.offset
        }.map(\.line)
        return descending ? sortedNumbers + empties : empties + sortedNumbers
    }

    /// IntegerSorter: a natural order where numbers (digits, or "-" right before a digit) compare
    /// by value and other text by character.
    static func naturalCompare(_ a: String, _ b: String) -> Int {
        let x = Array(a.utf16), y = Array(b.utf16)
        func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        func numberStarts(_ s: [UInt16], _ i: Int) -> Bool {
            i < s.count && (isDigit(s[i]) || (s[i] == 45 && i + 1 < s.count && isDigit(s[i + 1])))
        }
        var i = 0, j = 0
        while i < x.count && j < y.count {
            let xn = numberStarts(x, i), yn = numberStarts(y, j)
            if xn != yn {
                if x[i] != y[j] { return Int(x[i]) - Int(y[j]) }
                i += 1; j += 1
                continue
            }
            if xn {
                let xNegative = x[i] == 45, yNegative = y[j] == 45
                if xNegative != yNegative { return xNegative ? -1 : 1 }
                if xNegative { i += 1; j += 1 }
                var xs = i, ys = j
                while i < x.count && isDigit(x[i]) { i += 1 }
                while j < y.count && isDigit(y[j]) { j += 1 }
                let xZeros = x[xs..<i].prefix { $0 == 48 }.count, yZeros = y[ys..<j].prefix { $0 == 48 }.count
                xs += xZeros; ys += yZeros
                let xDigits = Array(x[xs..<i]), yDigits = Array(y[ys..<j])
                var result = 0
                if xDigits.count != yDigits.count {
                    result = xDigits.count < yDigits.count ? -1 : 1
                } else if let k = xDigits.indices.first(where: { xDigits[$0] != yDigits[$0] }) {
                    result = xDigits[k] < yDigits[k] ? -1 : 1
                }
                if result != 0 { return xNegative ? -result : result }
                if xZeros != yZeros { return xZeros > yZeros ? -1 : 1 }  // "007" < "07" < "7"
            } else {
                let xs = i, ys = j
                if x[i] == 45 { i += 1 }
                if y[j] == 45 { j += 1 }
                while i < x.count && !numberStarts(x, i) && !(x[i] == 45) { i += 1 }
                while j < y.count && !numberStarts(y, j) && !(y[j] == 45) { j += 1 }
                let xText = x[xs..<i], yText = y[ys..<j]
                if xText != yText {
                    return xText.lexicographicallyPrecedes(yText) ? -1 : 1
                }
                if i == xs { i += 1 }
                if j == ys { j += 1 }
            }
        }
        return (x.count - i) - (y.count - j)
    }
}

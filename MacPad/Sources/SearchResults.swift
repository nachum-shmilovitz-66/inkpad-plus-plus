import Foundation

// Notepad++'s "Search results" (the Finder, MAC-32): what Find All collects, and the exact text
// the results pane shows. Pure model, tested headless; SearchResultsPanel draws it.

/// One results-pane line for a document line with at least one hit. Notepad++ shows one entry
/// per line however many hits it has; each hit is a segment of the pane line.
struct SearchResultHit: Equatable {
    /// The document: its file path, or its tab name ("new 1") when it has no file.
    var path: String
    /// 0-based line in the document.
    var line: Int
    /// The hits in the document (byte ranges), in order.
    var ranges: [Range<Int>]
    /// The pane line without its line ending: "\tLine 12: …".
    var text: String
    /// Where each hit sits in `text` (byte offsets), index-aligned with `ranges`.
    var segments: [Range<Int>]
}

struct SearchResultsFile: Equatable {
    var path: String
    /// "  /path/file.txt (2 hits)" — fixed when the search ran, as in Notepad++.
    var header: String
    var hits: [SearchResultHit]
}

/// One Find All: its header and the files it found something in.
struct SearchResultsBlock: Equatable {
    var header: String
    var files: [SearchResultsFile]
    var hitCount: Int
}

/// What a pane line is, so a click, Enter or Delete knows what it acts on.
enum SearchResultsLine: Equatable {
    case searchHeader(block: Int)
    case fileHeader(block: Int, file: Int)
    case hit(block: Int, file: Int, hit: Int)
    case end
}

enum SearchResultsFormat {
    /// Notepad++ cuts a long line: lines over 2044 characters, and pane text of 2048 bytes or more
    /// (to 2041 bytes on a UTF-8 boundary, then " ...").
    static let lineCharacterLimit = 2044
    static let byteLimit = 2048
    static let cutBytes = 2041

    /// `Search "foo" (3 hits in 2 files of 5 searched) [Normal: Case/Word]`
    static func searchHeader(term: String, hits: Int, files: Int, searched: Int, inSelection: Bool,
                             options: SearchOptions) -> String {
        let cleanTerm = term.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        let where_ = inSelection ? (files == 1 ? "selection" : "selections") : (files == 1 ? "file" : "files")
        let info = "(\(commafy(hits)) \(hits == 1 ? "hit" : "hits") in \(commafy(files)) \(where_) of \(commafy(searched)) searched)"
        return "Search \"\(cleanTerm)\" \(info) \(modeLabel(options))"
    }

    /// `[Normal]`, `[Extended: Case]`, `[RegEx.: Case/Word]` (the dot: ". matches newline").
    static func modeLabel(_ options: SearchOptions) -> String {
        var label: String
        switch options.mode {
        case .normal: label = "Normal"
        case .extended: label = "Extended"
        case .regex: label = options.effectiveDotMatchesNewline ? "RegEx." : "RegEx"
        }
        let flags = [options.matchCase ? "Case" : nil, options.effectiveWholeWord ? "Word" : nil].compactMap { $0 }
        if !flags.isEmpty { label += ": " + flags.joined(separator: "/") }
        return "[\(label)]"
    }

    static func fileHeader(path: String, hits: Int) -> String {
        "  \(path) (\(commafy(hits)) \(hits == 1 ? "hit" : "hits"))"
    }

    /// "\tLine 12: text": the number right-aligned to the document's widest line number.
    static func hitPrefix(line: Int, lineCount: Int) -> String {
        let number = String(line + 1)
        let pad = String(repeating: " ", count: max(0, String(lineCount).count - number.count))
        return "\tLine \(pad)\(number): "
    }

    /// The pane line for `lineText` (UTF-8, no line ending), with Notepad++'s length limits.
    static func hitText(prefix: String, lineText: Data) -> String {
        var text = String(decoding: lineText, as: UTF8.self)
        if text.count > lineCharacterLimit { text = String(text.prefix(lineCharacterLimit)) }
        var bytes = Array((prefix + text).utf8)
        if bytes.count >= byteLimit {
            var cut = cutBytes
            while cut > 0 && bytes[cut] & 0xC0 == 0x80 { cut -= 1 }  // not inside a UTF-8 sequence
            bytes = Array(bytes[..<cut]) + Array(" ...".utf8)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func commafy(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: n)) ?? String(n)
    }
}

/// Every search in the pane, newest first, as Notepad++ keeps them.
struct SearchResultsModel: Equatable {
    private(set) var blocks: [SearchResultsBlock] = []

    mutating func add(_ block: SearchResultsBlock, purge: Bool) {
        if purge { blocks.removeAll() }
        blocks.insert(block, at: 0)
    }

    mutating func clear() { blocks.removeAll() }

    /// The pane's text (CRLF line endings, a final empty line) and what each line is.
    func render() -> (text: String, lines: [SearchResultsLine]) {
        var text = ""
        var lines: [SearchResultsLine] = []
        for (b, block) in blocks.enumerated() {
            text += block.header + "\r\n"
            lines.append(.searchHeader(block: b))
            for (f, file) in block.files.enumerated() {
                text += file.header + "\r\n"
                lines.append(.fileHeader(block: b, file: f))
                for (h, hit) in file.hits.enumerated() {
                    text += hit.text + "\r\n"
                    lines.append(.hit(block: b, file: f, hit: h))
                }
            }
        }
        lines.append(.end)
        return (text, lines)
    }

    func hit(_ line: SearchResultsLine) -> SearchResultHit? {
        guard case .hit(let b, let f, let h) = line else { return nil }
        return blocks[b].files[f].hits[h]
    }

    /// Delete in the pane: a hit line, a whole file, or a whole search.
    mutating func remove(_ line: SearchResultsLine) {
        switch line {
        case .searchHeader(let b):
            blocks.remove(at: b)
        case .fileHeader(let b, let f):
            blocks[b].files.remove(at: f)
        case .hit(let b, let f, let h):
            blocks[b].files[f].hits.remove(at: h)
            if blocks[b].files[f].hits.isEmpty { blocks[b].files.remove(at: f) }
        case .end:
            break
        }
    }

    /// Copy Selected Line(s): the document text of the hit lines in `lines` (a header stands for
    /// all its hits), consecutive duplicates dropped, joined with CRLF.
    func copiedLines(_ lines: [SearchResultsLine]) -> String {
        var out: [String] = []
        for hit in hits(in: lines) {
            let text = hit.text.range(of: ": ").map { String(hit.text[$0.upperBound...]) } ?? hit.text
            if out.last != text { out.append(text) }
        }
        return out.joined(separator: "\r\n")
    }

    /// Copy / Open Selected Pathname(s): each document once, in pane order.
    func paths(_ lines: [SearchResultsLine]) -> [String] {
        var seen: [String] = []
        for line in lines {
            let candidates: [String]
            switch line {
            case .searchHeader(let b): candidates = blocks[b].files.map(\.path)
            case .fileHeader(let b, let f): candidates = [blocks[b].files[f].path]
            case .hit: candidates = hit(line).map { [$0.path] } ?? []
            case .end: candidates = []
            }
            for path in candidates where !seen.contains(path) { seen.append(path) }
        }
        return seen
    }

    private func hits(in lines: [SearchResultsLine]) -> [SearchResultHit] {
        var result: [SearchResultHit] = []
        var covered = Set<String>()
        func add(_ b: Int, _ f: Int, _ h: Int) {
            let key = "\(b)/\(f)/\(h)"
            if covered.insert(key).inserted { result.append(blocks[b].files[f].hits[h]) }
        }
        for line in lines {
            switch line {
            case .searchHeader(let b):
                for (f, file) in blocks[b].files.enumerated() { file.hits.indices.forEach { add(b, f, $0) } }
            case .fileHeader(let b, let f):
                blocks[b].files[f].hits.indices.forEach { add(b, f, $0) }
            case .hit(let b, let f, let h):
                add(b, f, h)
            case .end:
                break
            }
        }
        return result
    }
}

/// A document Find All can search: an open tab's editor and the name the pane shows.
struct SearchDocument {
    let editor: ScintillaView
    let path: String
}

extension SearchEngine {
    enum FindAllOutcome: Equatable {
        case found([SearchResultHit])
        case invalidRegex
    }

    /// Find All in one document: the whole document, or the selection with In selection (unless
    /// it covers everything). Hits on the same line share one entry.
    func findAll(_ text: String, options: SearchOptions, path: String) -> FindAllOutcome {
        var hits: [SearchResultHit] = []
        let lineCount = editor.send(SCI_GETLINECOUNT)
        let bytes = editor.utf8Bytes()  // Find All does not edit, so one copy serves every hit
        let outcome = processAll(.findAll, text, replacement: "", options: options) { match in
            let line = editor.send(SCI_LINEFROMPOSITION, match.start)
            let lineStart = editor.send(SCI_POSITIONFROMLINE, line)
            let lineEnd = editor.send(SCI_GETLINEENDPOSITION, line)
            if hits.last?.line == line && hits.last?.path == path {
                hits[hits.count - 1].ranges.append(match.start..<match.end)
            } else {
                let lineBytes = bytes[lineStart..<lineEnd]
                let prefix = SearchResultsFormat.hitPrefix(line: line, lineCount: lineCount)
                hits.append(SearchResultHit(path: path, line: line, ranges: [match.start..<match.end],
                                            text: SearchResultsFormat.hitText(prefix: prefix, lineText: Data(lineBytes)),
                                            segments: []))
            }
            let prefixLength = SearchResultsFormat.hitPrefix(line: line, lineCount: lineCount).utf8.count
            let limit = hits[hits.count - 1].text.utf8.count
            let start = min(prefixLength + match.start - lineStart, limit)
            let end = min(prefixLength + min(match.end, lineEnd) - lineStart, limit)
            hits[hits.count - 1].segments.append(start..<max(start, end))
        }
        if case .invalidRegex = outcome { return .invalidRegex }
        return .found(hits)
    }
}

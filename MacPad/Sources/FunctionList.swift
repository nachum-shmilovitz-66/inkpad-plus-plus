import AppKit

/// One parser from Notepad++'s functionList/*.xml (MAC-44): a Unit parser (functions), a Zone
/// parser (class ranges) or a Mix of both.
struct FunctionParserDefinition {
    struct Function {
        var mainExpr: String
        var nameExprs: [String]
        var classNameExprs: [String]
    }

    struct ClassRange {
        var mainExpr: String
        var openSymbol: String?
        var closeSymbol: String?
        var classNameExprs: [String]
        var function: Function
    }

    var id: String
    var commentExpr: String?
    var function: Function?
    var classRange: ClassRange?

    /// Parses a functionList XML; only its first <parser>, as Notepad++.
    init?(xml data: Data) {
        guard let doc = try? SafeXML.document(data: Self.keepingAttributeNewlines(data)),
              let parser = (try? doc.nodes(forXPath: "/NotepadPlus/functionList/parser"))?.first as? XMLElement,
              let id = parser.attribute(forName: "id")?.stringValue else { return nil }
        func attr(_ e: XMLElement?, _ name: String) -> String? {
            e?.attribute(forName: name)?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        }
        func exprs(_ e: XMLElement?, _ container: String, _ item: String) -> [String] {
            e?.elements(forName: container).first?.elements(forName: item).compactMap { attr($0, "expr") } ?? []
        }
        self.id = id
        commentExpr = attr(parser, "commentExpr")
        if let f = parser.elements(forName: "function").first, let main = attr(f, "mainExpr") {
            function = Function(mainExpr: main, nameExprs: exprs(f, "functionName", "nameExpr"),
                                classNameExprs: exprs(f, "className", "nameExpr"))
        }
        if let c = parser.elements(forName: "classRange").first, let main = attr(c, "mainExpr"),
           let f = c.elements(forName: "function").first, let fMain = attr(f, "mainExpr") {
            classRange = ClassRange(mainExpr: main, openSymbol: attr(c, "openSymbole"), closeSymbol: attr(c, "closeSymbole"),
                                    classNameExprs: exprs(c, "className", "nameExpr"),
                                    function: Function(mainExpr: fMain, nameExprs: exprs(f, "functionName", "funcNameExpr"),
                                                       classNameExprs: []))
        }
        guard function != nil || classRange != nil else { return nil }
    }

    /// XML turns line breaks inside attribute values into spaces, which would end a `(?x)` regex's
    /// `#` comment nowhere and swallow the rest of the expression (pugi, Notepad++'s parser, keeps
    /// them). Writing them as character references keeps them through Foundation's parser.
    static func keepingAttributeNewlines(_ data: Data) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: "=\\s*(\"[^\"]*\"|'[^']*')") else { return data }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let value = text[range].replacingOccurrences(of: "\r", with: "&#13;").replacingOccurrences(of: "\n", with: "&#10;")
            text.replaceSubrange(range, with: value)
        }
        return Data(text.utf8)
    }

    /// The parser for a langs.model.xml language: functionList/<name>.xml (embedded JS uses JavaScript's).
    static func forLanguage(_ name: String) -> FunctionParserDefinition? {
        let file = name == "javascript" ? "javascript.js" : name
        if let cached = cache[file] { return cached }
        let def = NppData.url("functionList/\(file).xml").flatMap { try? Data(contentsOf: $0) }.flatMap(Self.init(xml:))
        cache[file] = .some(def)
        return def
    }
    private static var cache: [String: FunctionParserDefinition?] = [:]
}

struct FunctionEntry: Equatable {
    var name: String
    /// The class it belongs to ("" for none).
    var className: String
    /// Where the name starts (-1 when only the class name was found).
    var position: Int
}

/// Notepad++'s FunctionParser algorithms on a Scintilla document, quirks included (matching ignores
/// case; a match ending exactly at its range's end is dropped; inverted comment zones lose a
/// character at each edge; class bodies are brace-matched to the end of the document).
struct FunctionListParser {
    let editor: ScintillaView
    let definition: FunctionParserDefinition
    private let bytes: [UInt8]

    init(editor: ScintillaView, definition: FunctionParserDefinition) {
        self.editor = editor
        self.definition = definition
        bytes = Array(editor.utf8Bytes())
    }

    private var length: Int { bytes.count }

    /// One regex search in [from, to): the match, or nil.
    private func search(_ pattern: String, _ from: Int, _ to: Int) -> Range<Int>? {
        guard from < to else { return nil }
        let p = Array(pattern.utf8)
        editor.send(SCI_SETSEARCHFLAGS, Int(SCFIND_REGEXP | SCFIND_POSIX) | Int(SCFIND_REGEXP_DOTMATCHESNL))
        editor.send(SCI_SETTARGETRANGE, from, to)
        let found = editor.searchInTarget(p)
        guard found >= 0 else { return nil }
        return found..<editor.send(SCI_GETTARGETEND)
    }

    private func text(_ range: Range<Int>) -> String {
        String(decoding: bytes[range].prefix(1023), as: UTF8.self)
    }

    /// parseSubLevel: each expression searched inside the previous match; the last match wins.
    private func subLevel(_ range: Range<Int>, _ exprs: [String]) -> (String, Int) {
        var current = range
        for expr in exprs {
            guard let found = search(expr, current.lowerBound, current.upperBound) else { return ("", -1) }
            current = found
        }
        return (text(current), current.lowerBound)
    }

    private func zones(_ expr: String?, _ begin: Int, _ end: Int) -> [Range<Int>] {
        guard let expr else { return [] }
        var result: [Range<Int>] = []
        var from = begin
        while let found = search(expr, from, end) {
            result.append(found)
            from = found.upperBound
            if found.isEmpty { from += 1 }
        }
        return result
    }

    /// getInvertZones, with Notepad++'s one-character trims.
    private func invert(_ zones: [Range<Int>], _ begin: Int, _ end: Int) -> [Range<Int>] {
        guard let first = zones.first, let last = zones.last else { return [begin..<end] }
        var result: [Range<Int>] = []
        if begin < first.lowerBound, begin < first.lowerBound - 1 { result.append(begin..<(first.lowerBound - 1)) }
        for i in 0..<(zones.count - 1) {
            let nb = zones[i].upperBound + 1, ne = zones[i + 1].lowerBound - 1
            if nb < ne { result.append(nb..<ne) }
        }
        let tail = last.upperBound + 1
        if tail < end { result.append(tail..<end) }
        return result
    }

    private func isInComment(_ pos: Int, _ comments: [Range<Int>]) -> Bool {
        pos >= 0 && comments.contains { $0.contains(pos) }
    }

    /// funcParse over [begin, end).
    private func functions(_ f: FunctionParserDefinition.Function, _ begin: Int, _ end: Int, className: String,
                           comments: [Range<Int>]?) -> [FunctionEntry] {
        var result: [FunctionEntry] = []
        var from = begin
        while let match = search(f.mainExpr, from, end) {
            if match.upperBound >= end { break }  // ending exactly at the range end: dropped, as Notepad++
            var entry: FunctionEntry
            if f.nameExprs.isEmpty && f.classNameExprs.isEmpty {
                entry = FunctionEntry(name: text(match), className: className, position: match.lowerBound)
            } else {
                let (name, pos) = subLevel(match, f.nameExprs)
                var cls = className, classPos = -1
                if className.isEmpty && !f.classNameExprs.isEmpty { (cls, classPos) = subLevel(match, f.classNameExprs) }
                guard pos != -1 || classPos != -1 else { from = max(match.upperBound, from + 1); continue }
                if let comments, isInComment(pos, comments) || isInComment(classPos, comments) {
                    from = max(match.upperBound, from + 1)
                    continue
                }
                entry = FunctionEntry(name: name, className: cls, position: pos)
            }
            result.append(entry)
            from = max(match.upperBound, from + 1)
        }
        return result
    }

    /// getBodyClosePos: open / close symbols counted (outside comments) to the end of the document.
    private func bodyEnd(from: Int, _ range: FunctionParserDefinition.ClassRange, comments: [Range<Int>]) -> Int {
        guard let open = range.openSymbol, let close = range.closeSymbol else { return from }
        let either = "(\(open)|\(close))"
        var count = 1
        var position = from
        var last = from
        while count > 0, let hit = search(either, position, length) {
            position = max(hit.upperBound, hit.lowerBound + 1)
            if isInComment(hit.lowerBound, comments) { continue }
            count += search(open, hit.lowerBound, hit.upperBound) != nil ? 1 : -1
            last = hit.upperBound
        }
        return count == 0 ? last : from
    }

    /// classParse over [begin, end); `scanned` collects the class ranges.
    private func classes(_ range: FunctionParserDefinition.ClassRange, _ begin: Int, _ end: Int,
                         comments: [Range<Int>], scanned: inout [Range<Int>]) -> [FunctionEntry] {
        var result: [FunctionEntry] = []
        var from = begin
        while let header = search(range.mainExpr, from, end) {
            let (className, _) = subLevel(header, range.classNameExprs)
            let rangeEnd = range.openSymbol != nil && range.closeSymbol != nil
                ? bodyEnd(from: header.upperBound, range, comments: comments) : header.upperBound
            if rangeEnd > end { break }
            scanned.append(header.lowerBound..<rangeEnd)
            if rangeEnd == end { break }
            if !isInComment(header.lowerBound, comments) {
                result += functions(range.function, header.lowerBound, rangeEnd, className: className, comments: comments)
            }
            from = max(rangeEnd, from + 1)
        }
        return result
    }

    /// The document's functions, Notepad++'s order: class methods first, then top-level functions.
    func parse() -> [FunctionEntry] {
        let comments = zones(definition.commentExpr, 0, length)
        if let classRange = definition.classRange {
            var scanned: [Range<Int>] = []
            var result = classes(classRange, 0, length, comments: comments, scanned: &scanned)
            if let f = definition.function {  // Mix: functions outside the classes
                for gap in invert(scanned, 0, length) {
                    result += functions(f, gap.lowerBound, gap.upperBound, className: "", comments: comments)
                }
            } else if result.isEmpty && scanned.isEmpty {
                return []
            }
            return result
        }
        guard let f = definition.function else { return [] }
        return invert(comments, 0, length).flatMap { functions(f, $0.lowerBound, $0.upperBound, className: "", comments: nil) }
    }
}

/// The Function List tree: root (the file name), class nodes, function leaves.
struct FunctionTree: Equatable {
    struct Node: Equatable {
        var name: String
        var position: Int
        var leaves: [FunctionEntry]
    }

    var root: String
    /// Root level, in insertion order: a class node or a function leaf.
    enum Item: Equatable {
        case node(Node)
        case leaf(FunctionEntry)
    }
    var items: [Item] = []

    /// addEntry: a function with a class goes under that class's node (made on first use).
    init(root: String, entries: [FunctionEntry]) {
        self.root = root
        for entry in entries {
            if entry.className.isEmpty {
                items.append(.leaf(entry))
            } else if let index = items.firstIndex(where: { if case .node(let n) = $0 { return n.name == entry.className }; return false }),
                      case .node(var node) = items[index] {
                node.leaves.append(entry)
                items[index] = .node(node)
            } else {
                items.append(.node(Node(name: entry.className, position: entry.position, leaves: [entry])))
            }
        }
    }

    var leaves: [FunctionEntry] {
        items.flatMap { item -> [FunctionEntry] in
            switch item {
            case .leaf(let e): return [e]
            case .node(let n): return n.leaves
            }
        }
    }

    /// Sort on: alphabetical ignoring case (nodes and leaves mixed); off: by position.
    func sorted(alphabetically: Bool) -> FunctionTree {
        var copy = self
        func key(_ item: Item) -> (String, Int) {
            switch item {
            case .leaf(let e): return (e.name, e.position)
            case .node(let n): return (n.name, n.leaves.first?.position ?? n.position)
            }
        }
        copy.items = items.map { item in
            guard case .node(var n) = item else { return item }
            n.leaves.sort { alphabetically ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : $0.position < $1.position }
            return .node(n)
        }
        copy.items.sort { a, b in
            alphabetically ? key(a).0.localizedCaseInsensitiveCompare(key(b).0) == .orderedAscending : key(a).1 < key(b).1
        }
        return copy
    }

    /// The search box: every function containing the text (ignoring case), flat under the root.
    func filtered(_ text: String) -> FunctionTree {
        var copy = self
        copy.items = leaves.filter { $0.name.localizedCaseInsensitiveContains(text) }.map { .leaf($0) }
        return copy
    }

    /// The export format of Notepad++'s function list tests.
    var json: [String: Any] {
        var result: [String: Any] = ["root": root]
        let rootLeaves = items.compactMap { if case .leaf(let e) = $0 { return e.name }; return nil }
        let nodes = items.compactMap { item -> [String: Any]? in
            guard case .node(let n) = item else { return nil }
            return ["name": n.name, "leaves": n.leaves.map(\.name)]
        }
        if !rootLeaves.isEmpty { result["leaves"] = rootLeaves }
        if !nodes.isEmpty { result["nodes"] = nodes }
        return result
    }
}

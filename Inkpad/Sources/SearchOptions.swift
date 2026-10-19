import AppKit

// The Find/Replace model (MAC-30), ported from upstream's FindReplaceDlg: options, Extended-mode
// escapes, the find history and the dialog's status messages. No AppKit views here, so all of it
// is tested headless; SearchEngine applies it to a Scintilla view.

enum SearchMode: String, Codable, CaseIterable {
    case normal, extended, regex
}

/// upstream's FindOption, with the defaults its FindHistory gives a new user.
struct SearchOptions: Codable, Equatable {
    var mode: SearchMode = .normal
    var matchCase = false
    var wholeWord = false
    var wrapAround = true
    var backward = false
    var inSelection = false
    var dotMatchesNewline = false
    /// Mark tab: bookmark the lines of the matches, and clear earlier marks first.
    var bookmarkLine = false
    var purge = false
    /// Find in Files tab.
    var inAllSubfolders = true
    var inHiddenFolders = false

    init(mode: SearchMode = .normal, matchCase: Bool = false, wholeWord: Bool = false, wrapAround: Bool = true,
         backward: Bool = false, inSelection: Bool = false, dotMatchesNewline: Bool = false) {
        self.mode = mode
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.wrapAround = wrapAround
        self.backward = backward
        self.inSelection = inSelection
        self.dotMatchesNewline = dotMatchesNewline
    }

    /// Options saved by an older version lack the newer keys: those keep their defaults instead
    /// of throwing every saved option away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SearchOptions()
        mode = try c.decodeIfPresent(SearchMode.self, forKey: .mode) ?? d.mode
        matchCase = try c.decodeIfPresent(Bool.self, forKey: .matchCase) ?? d.matchCase
        wholeWord = try c.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? d.wholeWord
        wrapAround = try c.decodeIfPresent(Bool.self, forKey: .wrapAround) ?? d.wrapAround
        backward = try c.decodeIfPresent(Bool.self, forKey: .backward) ?? d.backward
        inSelection = try c.decodeIfPresent(Bool.self, forKey: .inSelection) ?? d.inSelection
        dotMatchesNewline = try c.decodeIfPresent(Bool.self, forKey: .dotMatchesNewline) ?? d.dotMatchesNewline
        bookmarkLine = try c.decodeIfPresent(Bool.self, forKey: .bookmarkLine) ?? d.bookmarkLine
        purge = try c.decodeIfPresent(Bool.self, forKey: .purge) ?? d.purge
        inAllSubfolders = try c.decodeIfPresent(Bool.self, forKey: .inAllSubfolders) ?? d.inAllSubfolders
        inHiddenFolders = try c.decodeIfPresent(Bool.self, forKey: .inHiddenFolders) ?? d.inHiddenFolders
    }

    /// Whole word and backward direction are disabled in Regex mode, ". matches newline" is
    /// enabled only there (upstream's regexBackward4PowerUser is off by default).
    var effectiveWholeWord: Bool { wholeWord && mode != .regex }
    var effectiveBackward: Bool { backward && mode != .regex }
    var effectiveDotMatchesNewline: Bool { dotMatchesNewline && mode == .regex }

    /// Searching::buildSearchFlags.
    var searchFlags: Int {
        var flags = 0
        if effectiveWholeWord { flags |= Int(SCFIND_WHOLEWORD) }
        if matchCase { flags |= Int(SCFIND_MATCHCASE) }
        if mode == .regex { flags |= Int(SCFIND_REGEXP) | Int(SCFIND_POSIX) }
        if effectiveDotMatchesNewline { flags |= Int(SCFIND_REGEXP_DOTMATCHESNL) }
        return flags
    }

    /// The text Scintilla is given for the find or replace field (Extended mode resolves escapes).
    func prepared(_ text: String) -> String {
        mode == .extended ? ExtendedEscapes.convert(text) : text
    }
}

/// Searching::convertExtendedToString: \n \r \t \0 \\ and the fixed-width numeric escapes
/// \bNNNNNNNN (binary), \oNNN (octal), \dNNN (decimal), \xNN (hex) and \uNNNN (hex). An unknown or
/// malformed escape stays as written, backslash included.
enum ExtendedEscapes {
    static func convert(_ text: String) -> String {
        let units = Array(text.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(units.count)
        let backslash = ascii("\\")
        var i = 0
        while i < units.count {
            let unit = units[i]
            guard unit == backslash, i + 1 < units.count else {
                out.append(unit)
                i += 1
                continue
            }
            let code = units[i + 1]
            i += 2
            switch code {
            case ascii("r"): out.append(0x0D)
            case ascii("n"): out.append(0x0A)
            case ascii("t"): out.append(0x09)
            case ascii("0"): out.append(0)
            case backslash: out.append(backslash)
            case ascii("b"), ascii("o"), ascii("d"), ascii("x"), ascii("u"):
                let (base, size) = numeric[code]!
                if let value = readBase(units, from: i, count: size, base: base) {
                    out.append(UInt16(truncatingIfNeeded: value))
                    i += size
                } else {
                    out.append(contentsOf: [backslash, code])
                }
            default:
                out.append(contentsOf: [backslash, code])
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    private static func ascii(_ c: Unicode.Scalar) -> UInt16 { UInt16(c.value) }

    private static let numeric: [UInt16: (base: Int, size: Int)] = [
        ascii("b"): (2, 8), ascii("o"): (8, 3), ascii("d"): (10, 3),
        ascii("x"): (16, 2), ascii("u"): (16, 4),
    ]

    /// upstream's readBase: exactly `count` digits of `base`; letters count from A = 10.
    private static func readBase(_ units: [UInt16], from start: Int, count: Int, base: Int) -> Int? {
        guard start + count <= units.count else { return nil }
        var value = 0
        for unit in units[start..<start + count] {
            guard unit < 0x80, let scalar = Unicode.Scalar(unit), let digit = Character(scalar).hexDigitValue, digit < base else {
                return nil
            }
            value = value * base + digit
        }
        return value
    }
}

/// The Find what / Replace with drop-down lists: most recent first, no empty entries, no
/// duplicates (compared ignoring case, as upstream's CB_FINDSTRINGEXACT does).
struct FindHistory: Equatable {
    static let savedLimit = 10
    static let savedLengthLimit = 2048

    private(set) var items: [String]

    init(_ items: [String] = []) { self.items = items }

    mutating func add(_ text: String) {
        guard !text.isEmpty else { return }
        items.removeAll { $0.compare(text, options: .caseInsensitive) == .orderedSame }
        items.insert(text, at: 0)
    }

    /// What survives a restart: the 10 most recent entries shorter than 2048 characters.
    var saved: [String] { Array(items.filter { $0.count < Self.savedLengthLimit }.prefix(Self.savedLimit)) }
}

/// The colour classes of upstream's Find dialog status line.
enum SearchStatusKind: Equatable {
    case notFound      // red, with a beep
    case message       // blue
    case wrapped       // green
    case warning       // orange

    var color: NSColor {
        switch self {
        case .notFound: return .systemRed
        case .message: return .systemBlue
        case .wrapped: return .systemGreen
        case .warning: return .systemOrange
        }
    }
}

struct SearchStatus: Equatable {
    var kind: SearchStatusKind
    var text: String
}

/// Where a search or an "all" operation looked, appended to upstream's messages.
enum SearchScope: Equatable {
    case selection, entireFile, startToCaret, caretToEnd

    var text: String {
        switch self {
        case .selection: return "in selected text"
        case .entireFile: return "in entire file"
        case .startToCaret: return "from start-of-file to caret"
        case .caretToEnd: return "from caret to end-of-file"
        }
    }
}

/// upstream's english.xml find-status strings.
enum SearchMessages {
    static func cantFind(_ text: String, scope: SearchScope) -> SearchStatus {
        SearchStatus(kind: .notFound, text: "Find: Can't find the text \"\(abbreviated(text))\" \(scope.text)")
    }
    static let endReached = SearchStatus(kind: .wrapped, text: "Find: Reached document end, first occurrence from the top found.")
    static let topReached = SearchStatus(kind: .wrapped, text: "Find: Reached document beginning, first occurrence from the bottom found.")
    static let invalidRegex = SearchStatus(kind: .notFound, text: "Find: Invalid regular expression")
    static let regexBackward = SearchStatus(kind: .notFound, text: "Find: Regex backward search is disabled")

    static func count(_ n: Int, scope: SearchScope) -> SearchStatus {
        let number = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return SearchStatus(kind: .message, text: n == 1 ? "Count: 1 match \(scope.text)" : "Count: \(number) matches \(scope.text)")
    }
    static func marked(_ n: Int, scope: SearchScope) -> SearchStatus {
        let number = NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
        return SearchStatus(kind: .message, text: n == 1 ? "Mark: 1 match \(scope.text)" : "Mark: \(number) matches \(scope.text)")
    }
    static func replacedAll(_ n: Int, scope: SearchScope) -> SearchStatus {
        SearchStatus(kind: .message, text: n == 1 ? "Replace All: 1 occurrence was replaced \(scope.text)"
                                                  : "Replace All: \(n) occurrences were replaced \(scope.text)")
    }
    static func replacedInOpenedFiles(_ n: Int) -> SearchStatus {
        SearchStatus(kind: .message, text: n == 1 ? "Replace in Opened Files: 1 occurrence was replaced."
                                                  : "Replace in Opened Files: \(n) occurrences were replaced.")
    }
    static func replacedInFiles(_ n: Int) -> SearchStatus {
        SearchStatus(kind: .message, text: n == 1 ? "Replace in Files: 1 occurrence was replaced."
                                                  : "Replace in Files: \(n) occurrences were replaced.")
    }
    static let replaceEndReached = SearchStatus(kind: .wrapped, text: "Replace: Reached document end, started from top.")
    static let replaceTopReached = SearchStatus(kind: .wrapped, text: "Replace: Reached document beginning, started from bottom.")
    static let replacedNextFound = SearchStatus(kind: .message, text: "Replace: 1 occurrence was replaced. The next occurrence found.")
    static let replacedOnly = SearchStatus(kind: .message, text: "Replace: 1 occurrence was replaced.")
    static let replacedNoMore = SearchStatus(kind: .message, text: "Replace: 1 occurrence was replaced. No more occurrences were found.")
    static func replaceNotFound(scope: SearchScope) -> SearchStatus {
        SearchStatus(kind: .notFound, text: "Replace: no occurrence was found \(scope.text)")
    }
    static let replaceReadOnly = SearchStatus(kind: .notFound, text: "Replace: Cannot replace text. The current document is read only")
    static let replaceAllReadOnly = SearchStatus(kind: .notFound, text: "Replace All: Cannot replace text. The current document is read only")

    /// upstream shortens the quoted text beyond 32 characters to 28 plus "...".
    static func abbreviated(_ text: String) -> String {
        text.count > 32 ? String(text.prefix(28)) + "..." : text
    }

    /// The tooltip upstream adds to a failed search unless the options were already the widest.
    static func hint(for options: SearchOptions) -> String? {
        options.wrapAround && !options.matchCase && !options.effectiveWholeWord ? nil
            : "The given occurrence cannot be found. You may have forgotten to check \"Wrap around\" (to ON), \"Match case\" (to OFF), or \"Match whole word only\" (to OFF)."
    }
}

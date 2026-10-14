import Foundation

/// What Notepad++'s ScintillaEditView::defineDocType and its set*Lexer helpers do for one
/// language beyond creating the lexer (MAC-11): which keyword lists go into which Scintilla
/// keyword sets, the lexer properties, the substyles, the embedded languages whose styles are
/// painted too, and the styles filled to the end of the line.
struct LexerRecipe {
    /// Where a keyword set's words come from: a keyword class (instre1 = 0 … type7 = 8,
    /// substyle1 = 9 … substyle8 = 16) of a language (nil = the document's own).
    struct Words: Equatable {
        var language: String?
        var keywordClass: Int
    }

    /// One SCI_ALLOCATESUBSTYLES call: `count` substyles of `base`, whose identifiers are the
    /// words of consecutive keyword classes from `firstClass`.
    struct Substyles: Equatable {
        var base: Int
        var count: Int
        var language: String?
        var firstClass: Int
    }

    /// Overrides LanguageInfo.lexer (PHP is lexed as HTML, not "phpscript").
    var lexer: String?
    /// Keyword set index → words. Nil means every keyword class 0…8 into the same set.
    var keywordSets: [Int: Words]?
    var properties: [(String, String)] = []
    var substyles: [Substyles] = []
    /// Other stylers LexerTypes painted after the language's own (HTML's embedded languages).
    var embeddedStyles: [String] = []
    var eolFilled: [Int] = []
    /// fold=1, fold.compact=0, fold.comment=1 — what setLexer always sends (TCL sends nothing).
    var commonFolding = true

    static let common: [(String, String)] = [("fold", "1"), ("fold.compact", "0"), ("fold.comment", "1")]

    /// All the properties to send, common ones first.
    var allProperties: [(String, String)] { (commonFolding ? Self.common : []) + properties }

    // MARK: - The table

    static func recipe(for language: String) -> LexerRecipe {
        if let recipe = special[language] { return recipe }
        if let sets = generic[language] { return LexerRecipe(keywordSets: own(sets), properties: genericProperties[language] ?? []) }
        return LexerRecipe()
    }

    private static func own(_ sets: [Int]) -> [Int: Words] {
        Dictionary(uniqueKeysWithValues: sets.map { ($0, Words(language: nil, keywordClass: $0)) })
    }

    /// Notepad++'s plain setLexer(…, LIST_n | …) calls: the keyword sets each one fills.
    private static let generic: [String: [Int]] = [
        "css": [0, 1, 4, 6], "makefile": [], "ini": [], "props": [], "sql": [0, 1, 4], "mssql": Array(0...5),
        "vb": [0], "pascal": [0], "perl": [0], "batch": [0], "tex": [], "nsis": Array(0...3), "fortran": Array(0...2),
        "fortran77": Array(0...2), "lisp": [0, 1], "scheme": [0, 1], "asm": Array(0...7), "diff": [],
        "postscript": Array(0...3), "ruby": [0], "smalltalk": [0], "vhdl": Array(0...6), "kix": Array(0...2),
        "autoit": Array(0...6), "caml": Array(0...2), "ada": [0], "verilog": [0, 1], "matlab": [0], "haskell": [0],
        "inno": Array(0...5), "cmake": Array(0...2), "yaml": [0], "cobol": Array(0...2), "gui4cli": Array(0...4),
        "d": Array(0...6), "powershell": Array(0...5), "r": Array(0...2), "coffeescript": Array(0...3),
        "baanc": Array(0...8), "srec": [], "ihex": [], "tehex": [], "asn1": Array(0...3), "avs": Array(0...5),
        "blitzbasic": Array(0...3), "purebasic": Array(0...3), "freebasic": Array(0...3), "csound": Array(0...2),
        "erlang": Array(0...5), "escript": Array(0...2), "forth": Array(0...5), "latex": [], "mmixal": Array(0...2),
        "nim": [0], "nncrontab": Array(0...2), "oscript": Array(0...5), "rebol": Array(0...6), "registry": [],
        "rust": Array(0...6), "spice": Array(0...2), "txt2tags": [], "visualprolog": Array(0...3),
        "hollywood": Array(0...3), "raku": Array(0...6), "toml": [0], "sas": Array(0...3), "errorlist": [], "escseq": [],
    ]

    private static let genericProperties: [String: [(String, String)]] = [
        "sql": [("sql.backslash.escapes", "1")],
        "pascal": [("fold.preprocessor", "1")],
        "asm": [("fold.asm.syntax.based", "1"), ("fold.asm.comment.multiline", "1"), ("fold.asm.comment.explicit", "1")],
        "autoit": [("fold.preprocessor", "1")],
        "verilog": [("fold.preprocessor", "1")],
        "baanc": [("lexer.baan.styling.within.preprocessor", "1"), ("fold.preprocessor", "1"), ("fold.baan.syntax.based", "1"),
                  ("fold.baan.keywords.based", "1"), ("fold.baan.sections", "1"), ("fold.baan.inner.level", "1")],
        "raku": [("fold.raku.comment.multiline", "1"), ("fold.raku.comment.pod", "1")],
        "errorlist": [("lexer.errorlist.value.separate", "0"), ("lexer.errorlist.escape.sequences", "1")],
        "escseq": [("lexer.escseq.colour.text", "1")],
    ]

    // Lexilla style numbers used below (SciLexer.h).
    private static let cIdentifier = Int(SCE_C_IDENTIFIER), pIdentifier = Int(SCE_P_IDENTIFIER)
    private static let luaIdentifier = Int(SCE_LUA_IDENTIFIER), gdIdentifier = Int(SCE_GD_IDENTIFIER)
    private static let shIdentifier = Int(SCE_SH_IDENTIFIER), shScalar = Int(SCE_SH_SCALAR)
    private static let hTag = Int(SCE_H_TAG), hAttribute = Int(SCE_H_ATTRIBUTE), hjWord = Int(SCE_HJ_WORD)
    private static let hphpWord = Int(SCE_HPHP_WORD), hbWord = Int(SCE_HB_WORD)

    /// setCppLexer: instre1, type1, cpp's type2 (Doxygen) and instre2; identifiers as substyles.
    private static func cpp(doxygenFromCpp: Bool = true, extra: [(String, String)] = []) -> LexerRecipe {
        LexerRecipe(
            keywordSets: [0: Words(language: nil, keywordClass: 0), 1: Words(language: nil, keywordClass: 2),
                          2: Words(language: doxygenFromCpp ? "cpp" : nil, keywordClass: 3), 3: Words(language: nil, keywordClass: 1)],
            properties: [("fold.cpp.comment.explicit", "0"), ("fold.preprocessor", "1"), ("lexer.cpp.track.preprocessor", "0")] + extra,
            substyles: [Substyles(base: cIdentifier, count: 8, language: nil, firstClass: 9)])
    }

    /// setHTMLLexer + setEmbeddedJSLexer + setEmbeddedPhpLexer + setEmbeddedAspLexer, in that
    /// order (the order fixes the substyle numbers the stylers expect: 192… for HTML, 200… JS,
    /// 208… PHP, 216… VBScript).
    private static let html = LexerRecipe(
        lexer: "hypertext",
        keywordSets: [0: Words(language: "html", keywordClass: 0), 5: Words(language: "html", keywordClass: 1),
                      1: Words(language: "javascript", keywordClass: 0), 4: Words(language: "php", keywordClass: 0),
                      2: Words(language: "vb", keywordClass: 0)],
        properties: [("asp.default.language", "2"), ("fold.html", "1"), ("fold.hypertext.comment", "1")],
        substyles: [Substyles(base: hTag, count: 4, language: "html", firstClass: 9),
                    Substyles(base: hAttribute, count: 4, language: "html", firstClass: 13),
                    Substyles(base: hjWord, count: 8, language: "javascript", firstClass: 9),
                    Substyles(base: hphpWord, count: 8, language: "php", firstClass: 9),
                    Substyles(base: hbWord, count: 8, language: "asp", firstClass: 9)],
        embeddedStyles: ["html", "javascript", "php", "asp"],
        eolFilled: [SCE_HJ_DEFAULT, SCE_HJ_COMMENT, SCE_HJ_COMMENTDOC, SCE_HJ_TEMPLATELITERAL, SCE_HJA_TEMPLATELITERAL,
                    SCE_HPHP_DEFAULT, SCE_HPHP_COMMENT, SCE_HBA_DEFAULT].map { Int($0) })

    private static let special: [String: LexerRecipe] = [
        "c": cpp(), "cpp": cpp(), "java": cpp(), "cs": cpp(), "actionscript": cpp(), "swift": cpp(),
        "rc": cpp(doxygenFromCpp: false),
        "go": cpp(extra: [("lexer.cpp.backquoted.strings", "1")]),
        "javascript.js": cpp(extra: [("lexer.cpp.backquoted.strings", "2")]),
        "javascript": cpp(extra: [("lexer.cpp.backquoted.strings", "2")]),
        "typescript": {
            var r = cpp(extra: [("lexer.cpp.backquoted.strings", "1")])
            r.keywordSets?[3] = nil  // setTypeScriptLexer fills sets 0–2 only
            return r
        }(),
        "objc": LexerRecipe(
            keywordSets: [0: Words(language: nil, keywordClass: 0), 1: Words(language: nil, keywordClass: 2),
                          2: Words(language: "cpp", keywordClass: 3), 3: Words(language: nil, keywordClass: 1),
                          4: Words(language: nil, keywordClass: 3)],
            properties: [("fold.cpp.comment.explicit", "0"), ("fold.preprocessor", "1")]),
        "tcl": LexerRecipe(
            keywordSets: [0: Words(language: nil, keywordClass: 0), 1: Words(language: nil, keywordClass: 2),
                          2: Words(language: nil, keywordClass: 1), 3: Words(language: nil, keywordClass: 3),
                          4: Words(language: nil, keywordClass: 4), 5: Words(language: nil, keywordClass: 5),
                          6: Words(language: nil, keywordClass: 6), 7: Words(language: nil, keywordClass: 7),
                          8: Words(language: nil, keywordClass: 8)],
            commonFolding: false),
        "json": LexerRecipe(keywordSets: [0: Words(language: "json", keywordClass: 0), 1: Words(language: "json", keywordClass: 1)],
                            properties: [("lexer.json.escape.sequence", "1")]),
        "json5": LexerRecipe(keywordSets: [0: Words(language: "json", keywordClass: 0), 1: Words(language: "json", keywordClass: 1)],
                             properties: [("lexer.json.escape.sequence", "1"), ("lexer.json.allow.comments", "1")],
                             embeddedStyles: ["json"]),
        "xml": LexerRecipe(
            keywordSets: [5: Words(language: "xml", keywordClass: 0)],
            properties: [("lexer.xml.allow.scripts", "0"), ("fold.html", "1"), ("fold.hypertext.comment", "1")],
            substyles: [Substyles(base: hAttribute, count: 8, language: "xml", firstClass: 9)]),
        "html": html, "php": html, "asp": html, "jsp": html,
        "bash": LexerRecipe(
            keywordSets: [0: Words(language: nil, keywordClass: 0)],
            substyles: [Substyles(base: shIdentifier, count: 4, language: nil, firstClass: 9),
                        Substyles(base: shScalar, count: 4, language: nil, firstClass: 13)]),
        "python": LexerRecipe(
            keywordSets: own([0, 1]),
            properties: [("fold.quotes.python", "1"), ("lexer.python.decorator.attributes", "1"),
                         ("lexer.python.identifier.attributes", "1")],
            substyles: [Substyles(base: pIdentifier, count: 8, language: nil, firstClass: 9)]),
        "gdscript": LexerRecipe(
            keywordSets: own([0, 1]),
            properties: [("lexer.gdscript.keywords2.no.sub.identifiers", "1"), ("lexer.gdscript.whinge.level", "1")],
            substyles: [Substyles(base: gdIdentifier, count: 8, language: nil, firstClass: 9)]),
        "lua": LexerRecipe(keywordSets: own(Array(0...7)),
                           substyles: [Substyles(base: luaIdentifier, count: 4, language: nil, firstClass: 9)]),
        "ini": LexerRecipe(keywordSets: [:], eolFilled: [Int(SCE_PROPS_SECTION)]),
        "props": LexerRecipe(keywordSets: [:], eolFilled: [Int(SCE_PROPS_SECTION)]),
        "ruby": LexerRecipe(keywordSets: own([0]), eolFilled: [Int(SCE_RB_POD)]),
        "csound": LexerRecipe(keywordSets: own(Array(0...2)), eolFilled: [Int(SCE_CSOUND_STRINGEOL)]),
        "baanc": LexerRecipe(keywordSets: own(Array(0...8)), properties: genericProperties["baanc"] ?? [],
                             eolFilled: [Int(SCE_BAAN_STRINGEOL)]),
    ]

    // MARK: - Other per-language settings

    /// Indent guides look forward for these (Notepad++'s SC_IV_LOOKFORWARD list), both ways otherwise.
    static let lookForwardIndentGuides: Set<String> = [
        "python", "coffeescript", "haskell", "c", "cpp", "objc", "cs", "java", "php", "javascript", "javascript.js",
        "makefile", "asn1", "gdscript",
    ]

    /// Languages Notepad++ shows without the fold margin.
    static let noFoldMargin: Set<String> = ["nfo", "batch", "normal", "makefile", "haskell", "smalltalk", "kix", "ada"]
}

// MARK: - Content-based detection

enum LanguageDetector {
    /// Notepad++'s FileManager::detectLanguageFromTextBeginning: after a BOM and leading blank
    /// space, at most 40 bytes of the first line. "#!" lines are matched by substring in a fixed
    /// order ("sh" first, so any shell wins), others by prefix; all case-sensitive.
    static func language(fromTextBeginning data: Data) -> String? {
        var bytes = [UInt8](data.prefix(4096))
        guard bytes.count > 3 else { return nil }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) || bytes.starts(with: [0xFE, 0xFF, 0x00]) || bytes.starts(with: [0xFF, 0xFE, 0x00]) {
            bytes.removeFirst(3)
        }
        let blank: Set<UInt8> = [0x20, 0x09, 0x0D, 0x0A]
        let start = bytes.firstIndex { !blank.contains($0) } ?? bytes.count
        var line = Array(bytes[start...].prefix(40))
        if let eol = line.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) { line = Array(line[..<eol]) }
        let text = String(decoding: line, as: UTF8.self)
        if text.hasPrefix("#!") {
            let shebangs = [("sh", "bash"), ("python", "python"), ("perl", "perl"), ("php", "php"), ("ruby", "ruby"),
                            ("node", "javascript.js")]
            return shebangs.first { text.contains($0.0) }?.1
        }
        let prefixes = [("<?xml", "xml"), ("<?php", "php"), ("<html", "html"), ("<!DOCTYPE html", "html"), ("<?", "php")]
        return prefixes.first { text.hasPrefix($0.0) }?.1
    }

    /// File names Notepad++ recognises without an extension (Buffer.cpp), compared ignoring case.
    static let fileNames: [String: String] = [
        "makefile": "makefile", "gnumakefile": "makefile", "cmakelists.txt": "cmake",
        "sconstruct": "python", "sconscript": "python", "wscript": "python",
        "rakefile": "ruby", "vagrantfile": "ruby", "crontab": "bash", "pkgbuild": "bash", "apkbuild": "bash",
    ]
}

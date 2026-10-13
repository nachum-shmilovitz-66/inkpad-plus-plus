import AppKit

/// Margins, in Notepad++'s order: line numbers, bookmarks/symbols, folding.
enum Margin {
    static let lineNumber = 0
    static let symbol = 1
    static let fold = 2
}

/// Applies Notepad++ editor defaults, lexers and styler themes to a ScintillaView.
/// Mirrors the generic path of ScintillaEditView::defineDocType / setLexer; per-language special
/// cases beyond the cpp family (HTML-embedded scripts, etc.) arrive with milestone 4.
enum EditorStyler {
    /// Notepad++ sizes are Windows points (96 dpi); macOS draws a point as one logical pixel.
    /// Scale so "Courier New 10" looks the size it does on Windows.
    static func macFontSize(_ windowsPoints: Int) -> Int { Int((Double(windowsPoints) * 4 / 3).rounded()) }

    /// One-time setup that does not depend on the language.
    static func configureEditor(_ v: ScintillaView) {
        v.send(SCI_SETCODEPAGE, Int(SC_CP_UTF8))
        v.send(SCI_SETTABWIDTH, 4)
        v.send(SCI_SETUSETABS, 1)
        v.send(SCI_SETCARETLINEVISIBLE, 1)
        v.send(SCI_SETCARETLINEVISIBLEALWAYS, 1)
        v.send(SCI_SETINDENTATIONGUIDES, Int(SC_IV_LOOKBOTH))
        v.send(SCI_SETSCROLLWIDTH, 1)
        v.send(SCI_SETSCROLLWIDTHTRACKING, 1)
        v.send(SCI_SETENDATLASTLINE, 0)  // Notepad++ lets you scroll past the last line

        // Multi-caret and column (rectangular) selection, as in Notepad++ (Option-drag on macOS).
        v.send(SCI_SETMULTIPLESELECTION, 1)
        v.send(SCI_SETADDITIONALSELECTIONTYPING, 1)
        v.send(SCI_SETMULTIPASTE, Int(SC_MULTIPASTE_EACH))
        v.send(SCI_SETVIRTUALSPACEOPTIONS, Int(SCVS_RECTANGULARSELECTION))

        // Margins.
        v.send(SCI_SETMARGINTYPEN, Margin.lineNumber, Int(SC_MARGIN_NUMBER))
        v.send(SCI_SETMARGINTYPEN, Margin.symbol, Int(SC_MARGIN_COLOUR))
        v.send(SCI_SETMARGINWIDTHN, Margin.symbol, 16)
        v.send(SCI_SETMARGINSENSITIVEN, Margin.symbol, 1)
        v.send(SCI_SETMARGINTYPEN, Margin.fold, Int(SC_MARGIN_SYMBOL))
        v.send(SCI_SETMARGINMASKN, Margin.fold, Int(SC_MASK_FOLDERS))
        v.send(SCI_SETMARGINWIDTHN, Margin.fold, 14)
        v.send(SCI_SETMARGINSENSITIVEN, Margin.fold, 1)

        // Folding: Notepad++'s default "box tree" markers.
        let markers: [(Int32, Int32)] = [
            (SC_MARKNUM_FOLDEROPEN, SC_MARK_BOXMINUS),
            (SC_MARKNUM_FOLDER, SC_MARK_BOXPLUS),
            (SC_MARKNUM_FOLDERSUB, SC_MARK_VLINE),
            (SC_MARKNUM_FOLDERTAIL, SC_MARK_LCORNER),
            (SC_MARKNUM_FOLDEREND, SC_MARK_BOXPLUSCONNECTED),
            (SC_MARKNUM_FOLDEROPENMID, SC_MARK_BOXMINUSCONNECTED),
            (SC_MARKNUM_FOLDERMIDTAIL, SC_MARK_TCORNER),
        ]
        for (num, symbol) in markers { v.send(SCI_MARKERDEFINE, Int(num), Int(symbol)) }
        v.send(SCI_MARKERENABLEHIGHLIGHT, 1)
        v.send(SCI_SETAUTOMATICFOLD, Int(SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE))
        v.send(SCI_SETFOLDFLAGS, Int(SC_FOLDFLAG_LINEAFTER_CONTRACTED))
    }

    /// Selects the lexer for `language`, loads its keywords, and paints `theme`.
    static func apply(language: LanguageInfo, theme: StyleTheme, to v: ScintillaView) {
        let definition = LanguageCatalog.shared.languages[language.name]
        let lexerStyles = theme.lexerStyles[language.name] ?? []

        // 1. Lexer.
        if language.lexer == "null" {
            v.send(SCI_SETILEXER, 0, 0)
        } else if let lexer = CreateLexer(language.lexer) {
            v.send(SCI_SETILEXER, 0, Int(bitPattern: lexer))
        } else {
            NSLog("MacPad++: Lexilla has no lexer named \(language.lexer)")
            v.send(SCI_SETILEXER, 0, 0)
        }

        // 2. Keywords: langs.model.xml lists plus the user words stored on styles in the theme.
        var keywords = definition?.keywords ?? [:]
        for style in lexerStyles where !style.userWords.isEmpty {
            if let cls = style.keywordClass, let idx = keywordClassIndex(cls) {
                keywords[idx] = [keywords[idx], style.userWords].compactMap { $0 }.joined(separator: " ")
            }
        }
        for set in 0...8 { v.send(SCI_SETKEYWORDS, set, string: "") }
        if language.lexer == "cpp" {
            // ScintillaEditView::setCppLexer: instre1→0, type1→1, type2 (doc keywords)→2, instre2→3.
            let map = [0: 0, 2: 1, 3: 2, 1: 3]
            for (cls, set) in map { if let words = keywords[cls] { v.send(SCI_SETKEYWORDS, set, string: words) } }
        } else {
            for (cls, words) in keywords { v.send(SCI_SETKEYWORDS, cls, string: words) }
        }

        // 3. Lexer properties Notepad++ sets for folding.
        for (key, value) in [("fold", "1"), ("fold.compact", "0"), ("fold.comment", "1"),
                             ("fold.preprocessor", "1"), ("fold.html", "1"), ("fold.cpp.comment.explicit", "0")] {
            _ = key.withCString { k in value.withCString { val in
                v.send(SCI_SETPROPERTY, Int(bitPattern: k), Int(bitPattern: val))
            } }
        }

        // 4. Styles: default → clear all → globals → lexer styles.
        let defaultStyle = theme.global("Default Style")
        if let d = defaultStyle {
            setStyle(Int(STYLE_DEFAULT), d, on: v)
        } else {
            v.send(SCI_STYLESETFONT, Int(STYLE_DEFAULT), string: "Menlo")
            v.send(SCI_STYLESETSIZE, Int(STYLE_DEFAULT), 13)
        }
        v.send(SCI_STYLECLEARALL)

        for g in theme.globalStyles where g.styleID != 0 && g.styleID != Int(STYLE_DEFAULT) {
            // 33 line numbers, 34/35 braces, 37 indent guides …; 21–31 are indicator colours (milestone 3).
            if g.styleID >= 32 { setStyle(g.styleID, g, on: v) }
        }
        for s in lexerStyles { setStyle(s.styleID, s, on: v) }

        applyWidgetColours(theme, to: v)
        v.send(SCI_COLOURISE, 0, -1)
        updateLineNumberWidth(v)
    }

    private static func setStyle(_ id: Int, _ s: StyleEntry, on v: ScintillaView) {
        if let fg = s.foreground { v.send(SCI_STYLESETFORE, id, fg) }
        if let bg = s.background { v.send(SCI_STYLESETBACK, id, bg) }
        if let font = s.fontName { v.send(SCI_STYLESETFONT, id, string: font) }
        if let size = s.fontSize { v.send(SCI_STYLESETSIZE, id, macFontSize(size)) }
        if s.fontStyle != nil {
            v.send(SCI_STYLESETBOLD, id, s.isBold ? 1 : 0)
            v.send(SCI_STYLESETITALIC, id, s.isItalic ? 1 : 0)
            v.send(SCI_STYLESETUNDERLINE, id, s.isUnderline ? 1 : 0)
        }
    }

    /// Global "WidgetStyle" entries with styleID 0 are colours, not text styles.
    private static func applyWidgetColours(_ theme: StyleTheme, to v: ScintillaView) {
        let opaque = 0xFF00_0000
        if let c = theme.global("Current line background colour")?.background {
            v.send(SCI_SETELEMENTCOLOUR, Int(SC_ELEMENT_CARET_LINE_BACK), c | opaque)
        }
        if let c = theme.global("Selected text colour")?.background {
            v.send(SCI_SETELEMENTCOLOUR, Int(SC_ELEMENT_SELECTION_BACK), c | opaque)
            v.send(SCI_SETELEMENTCOLOUR, Int(SC_ELEMENT_SELECTION_INACTIVE_BACK), c | opaque)
        }
        if let c = theme.global("Multi-selected text color")?.background {
            v.send(SCI_SETELEMENTCOLOUR, Int(SC_ELEMENT_SELECTION_ADDITIONAL_BACK), c | opaque)
        }
        if let c = theme.global("Caret colour")?.foreground {
            v.send(SCI_SETELEMENTCOLOUR, Int(SC_ELEMENT_CARET), c | opaque)
        }
        if let c = theme.global("Multi-edit carets color")?.foreground {
            v.send(SCI_SETELEMENTCOLOUR, Int(SC_ELEMENT_CARET_ADDITIONAL), c | opaque)
        }
        if let c = theme.global("Edge colour")?.foreground { v.send(SCI_SETEDGECOLOUR, c) }
        if let c = theme.global("Bookmark margin")?.background { v.send(SCI_SETMARGINBACKN, Margin.symbol, c) }
        if let fold = theme.global("Fold") {
            for num in Int(SC_MARKNUM_FOLDEREND)...Int(SC_MARKNUM_FOLDEROPEN) {
                // ScintillaEditView::defineMarker: fore = fgColor, back = bgColor.
                if let fg = fold.foreground { v.send(SCI_MARKERSETFORE, num, fg) }
                if let bg = fold.background { v.send(SCI_MARKERSETBACK, num, bg) }
                if let active = theme.global("Fold active")?.foreground { v.send(SCI_MARKERSETBACKSELECTED, num, active) }
            }
        }
        if let margin = theme.global("Fold margin") {
            if let bg = margin.background { v.send(SCI_SETFOLDMARGINCOLOUR, 1, bg) }
            if let fg = margin.foreground { v.send(SCI_SETFOLDMARGINHICOLOUR, 1, fg) }
        }
    }

    /// Line-number margin wide enough for the current line count (Notepad++'s dynamic width).
    static func updateLineNumberWidth(_ v: ScintillaView) {
        let digits = max(3, String(v.send(SCI_GETLINECOUNT)).count)
        let width = v.send(SCI_TEXTWIDTH, Int(STYLE_LINENUMBER), string: String(repeating: "8", count: digits))
        v.send(SCI_SETMARGINWIDTHN, Margin.lineNumber, width + 8)
    }

    /// Notepad++ brace matching: highlight the pair around the caret, or mark an unmatched brace.
    static func updateBraceMatch(_ v: ScintillaView) {
        let caret = v.send(SCI_GETCURRENTPOS)
        func isBrace(_ pos: Int) -> Bool {
            guard pos >= 0, pos < v.send(SCI_GETLENGTH) else { return false }
            return "()[]{}".unicodeScalars.contains { Int($0.value) == v.send(SCI_GETCHARAT, pos) }
        }
        let pos = isBrace(caret - 1) ? caret - 1 : (isBrace(caret) ? caret : -1)
        if pos < 0 {
            v.send(SCI_BRACEHIGHLIGHT, -1, -1)
            return
        }
        let match = v.send(SCI_BRACEMATCH, pos, 0)
        if match < 0 { v.send(SCI_BRACEBADLIGHT, pos) } else { v.send(SCI_BRACEHIGHLIGHT, pos, match) }
    }
}

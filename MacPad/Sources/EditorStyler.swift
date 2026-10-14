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
        v.send(SCI_SETMARGINMASKN, Margin.symbol, (1 << MarkIndicator.bookmark) | (1 << 19) | (1 << 18))
        defineBookmarkMarker(v)
        configureIndicators(v)
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
        let recipe = LexerRecipe.recipe(for: language.name)
        let lexerName = recipe.lexer ?? language.lexer

        // 1. Lexer (substyles belong to the previous lexer and go with it).
        v.send(SCI_FREESUBSTYLES)
        if lexerName == "null" {
            v.send(SCI_SETILEXER, 0, 0)
        } else if let lexer = CreateLexer(lexerName) {
            v.send(SCI_SETILEXER, 0, Int(bitPattern: lexer))
        } else {
            NSLog("MacPad++: Lexilla has no lexer named \(lexerName)")
            v.send(SCI_SETILEXER, 0, 0)
        }

        // 2. Keywords, per defineDocType's set*Lexer: each set from a keyword class of this or another
        //    language, the stylers' user words first, then langs.model.xml's (ScintillaEditView::setKeywords).
        func words(_ source: LexerRecipe.Words) -> String {
            let name = source.language ?? language.name
            let user = (theme.lexerStyles[name] ?? [])
                .filter { $0.keywordClass.flatMap(keywordClassIndex) == source.keywordClass && !$0.userWords.isEmpty }
                .map(\.userWords)
            let model = LanguageCatalog.shared.languages[name]?.keywords[source.keywordClass]
            return (user + [model].compactMap { $0 }).joined(separator: " ")
        }
        for set in 0...8 { v.send(SCI_SETKEYWORDS, set, string: "") }
        let sets = recipe.keywordSets
            ?? Dictionary(uniqueKeysWithValues: (0...8).map { ($0, LexerRecipe.Words(language: nil, keywordClass: $0)) })
        for (set, source) in sets.sorted(by: { $0.key < $1.key }) {
            let list = words(source)
            if !list.isEmpty { v.send(SCI_SETKEYWORDS, set, string: list) }
        }

        // 3. Lexer properties, then substyles (identifiers listed by substyle1…8).
        for (key, value) in recipe.allProperties {
            _ = key.withCString { k in value.withCString { val in
                v.send(SCI_SETPROPERTY, Int(bitPattern: k), Int(bitPattern: val))
            } }
        }
        for sub in recipe.substyles {
            let first = v.send(SCI_ALLOCATESUBSTYLES, sub.base, sub.count)
            guard first >= 0 else { continue }
            for i in 0..<sub.count {
                v.send(SCI_SETIDENTIFIERS, first + i,
                       string: words(LexerRecipe.Words(language: sub.language, keywordClass: sub.firstClass + i)))
            }
        }

        // Per-language editor settings: tabs (langs.model.xml tabSettings), indent guides, fold margin.
        let definition = LanguageCatalog.shared.languages[language.name]
        if let tab = definition?.tabSettings, tab & 0x7F != 0 {
            v.send(SCI_SETTABWIDTH, tab & 0x7F)
            v.send(SCI_SETUSETABS, tab & 0x80 != 0 ? 0 : 1)
        } else {
            v.send(SCI_SETTABWIDTH, 4)
            v.send(SCI_SETUSETABS, 1)
        }
        v.send(SCI_SETBACKSPACEUNINDENTS, definition?.backspaceUnindent == true ? 1 : 0)
        let lookForward = LexerRecipe.lookForwardIndentGuides.contains(language.name)
        v.send(SCI_SETINDENTATIONGUIDES, Int(lookForward ? SC_IV_LOOKFORWARD : SC_IV_LOOKBOTH))
        v.send(SCI_SETMARGINWIDTHN, Margin.fold, LexerRecipe.noFoldMargin.contains(language.name) ? 0 : 14)

        // 4. Styles: default → clear all → globals → lexer styles, each through the Global override.
        let globalOverride = GlobalOverride.load()
        let overrideStyle = theme.global("Global override")
        func paint(_ id: Int, _ style: StyleEntry) {
            setStyle(id, globalOverride.apply(to: style, styleID: id, override: overrideStyle), on: v)
        }
        let defaultStyle = theme.global("Default Style")
        if let d = defaultStyle {
            paint(Int(STYLE_DEFAULT), d)
        } else {
            v.send(SCI_STYLESETFONT, Int(STYLE_DEFAULT), string: "Menlo")
            v.send(SCI_STYLESETSIZE, Int(STYLE_DEFAULT), 13)
        }
        v.send(SCI_STYLECLEARALL)

        for g in theme.globalStyles where g.styleID != 0 && g.styleID != Int(STYLE_DEFAULT) {
            // 33 line numbers, 34/35 braces, 37 indent guides …; 21–31 are indicator colours (milestone 3).
            if g.styleID >= 32 { paint(g.styleID, g) }
        }
        // HTML-family documents paint html, then the embedded javascript / php / asp styles.
        let painted = recipe.embeddedStyles.isEmpty ? [language.name] : recipe.embeddedStyles
        for name in painted {
            for s in theme.lexerStyles[name] ?? [] { paint(s.styleID, s) }
        }
        for style in recipe.eolFilled { v.send(SCI_STYLESETEOLFILLED, style, 1) }

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
        // ScintillaEditView::setSpecialIndicator: an indicator's colour is its styler's bgColor.
        for entry in MarkIndicator.themeEntries {
            if let c = theme.global(entry.name)?.background ?? scintillaColour(fromHex: entry.fallback) {
                v.send(SCI_INDICSETFORE, entry.indicator, c)
            }
        }
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

    /// Notepad++'s mark indicators: a translucent rounded box under the text.
    private static func configureIndicators(_ v: ScintillaView) {
        for entry in MarkIndicator.themeEntries {
            v.send(SCI_INDICSETSTYLE, entry.indicator, Int(INDIC_ROUNDBOX))
            v.send(SCI_INDICSETALPHA, entry.indicator, 100)
            v.send(SCI_INDICSETUNDER, entry.indicator, 1)
            if let c = scintillaColour(fromHex: entry.fallback) { v.send(SCI_INDICSETFORE, entry.indicator, c) }
        }
    }

    /// The bookmark: a blue ball like Notepad++'s bookmark14 image, drawn at 2x for Retina.
    private static func defineBookmarkMarker(_ v: ScintillaView) {
        let pixels = bookmarkImage(points: 14, scale: 2)
        v.send(SCI_RGBAIMAGESETWIDTH, 28)
        v.send(SCI_RGBAIMAGESETHEIGHT, 28)
        v.send(SCI_RGBAIMAGESETSCALE, 200)
        pixels.withUnsafeBytes { v.send(SCI_MARKERDEFINERGBAIMAGE, MarkIndicator.bookmark, pointer: $0.baseAddress) }
    }

    /// RGBA (not premultiplied) pixels of the bookmark ball, as SCI_MARKERDEFINERGBAIMAGE expects.
    static func bookmarkImage(points: Int, scale: Int) -> [UInt8] {
        let size = points * scale
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let s = CGFloat(scale)
            let ball = CGRect(x: 1.5 * s, y: 1.5 * s, width: (CGFloat(points) - 3) * s, height: (CGFloat(points) - 3) * s)
            context.addEllipse(in: ball)
            context.clip()
            let colours = [CGColor(srgbRed: 0.53, green: 0.60, blue: 0.89, alpha: 1), CGColor(srgbRed: 0.19, green: 0.33, blue: 0.80, alpha: 1)]
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colours as CFArray, locations: [0, 1]) {
                context.drawRadialGradient(gradient, startCenter: CGPoint(x: ball.midX - ball.width * 0.18, y: ball.midY + ball.height * 0.18),
                                           startRadius: 0, endCenter: CGPoint(x: ball.midX, y: ball.midY), endRadius: ball.width / 2,
                                           options: [.drawsAfterEndLocation])
            }
            context.resetClip()
            context.setStrokeColor(CGColor(srgbRed: 0.12, green: 0.22, blue: 0.62, alpha: 1))
            context.setLineWidth(s * 0.75)
            context.strokeEllipse(in: ball)
        }
        // A bitmap context's memory is already top row first; only the premultiplication goes.
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            for c in 0..<3 { pixels[i + c] = a == 0 ? 0 : UInt8(min(255, Int(pixels[i + c]) * 255 / a)) }
        }
        return pixels
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

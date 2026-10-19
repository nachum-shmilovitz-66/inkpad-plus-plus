import Foundation

/// One `<WordsStyle>` / `<WidgetStyle>` from a upstream styler/theme file.
/// Absent attributes are nil: they inherit from the default style, as in upstream.
struct StyleEntry {
    var name: String
    var styleID: Int
    var foreground: Int?      // Scintilla BGR
    var background: Int?      // Scintilla BGR
    var fontName: String?
    var fontStyle: Int?       // bit 1 = bold, 2 = italic, 4 = underline
    var fontSize: Int?        // Windows points
    var keywordClass: String?
    var userWords: String     // element text: extra keywords appended to keywordClass

    var isBold: Bool { (fontStyle ?? 0) & 1 != 0 }
    var isItalic: Bool { (fontStyle ?? 0) & 2 != 0 }
    var isUnderline: Bool { (fontStyle ?? 0) & 4 != 0 }

    init(_ e: XMLElement) {
        func attr(_ n: String) -> String? {
            guard let v = e.attribute(forName: n)?.stringValue, !v.isEmpty else { return nil }
            return v
        }
        name = attr("name") ?? ""
        styleID = attr("styleID").flatMap { Int($0) } ?? 0
        foreground = attr("fgColor").flatMap(scintillaColour(fromHex:))
        background = attr("bgColor").flatMap(scintillaColour(fromHex:))
        fontName = attr("fontName")
        fontStyle = attr("fontStyle").flatMap { Int($0) }.flatMap { $0 < 0 ? nil : $0 }
        fontSize = attr("fontSize").flatMap { Int($0) }.flatMap { $0 <= 0 ? nil : $0 }
        keywordClass = attr("keywordClass")
        userWords = (e.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A parsed stylers.model.xml or themes/*.xml (same schema), imported as-is.
final class StyleTheme {
    static let `default` = StyleTheme(url: UpstreamData.url("stylers.model.xml"))

    private(set) var globalStyles: [StyleEntry] = []
    private(set) var lexerStyles: [String: [StyleEntry]] = [:]
    /// The Style Configurator's "User ext." per language (LexerType ext=…), checked before
    /// langs.model.xml's extensions.
    private(set) var userExtensions: [String: [String]] = [:]
    /// LexerType desc=… (the Style Configurator's language list).
    private(set) var lexerDescriptions: [String: String] = [:]

    init(url: URL?) {
        guard let url, let doc = try? SafeXML.document(contentsOf: url) else {
            NSLog("Inkpad++: could not load theme \(url?.lastPathComponent ?? "nil")")
            return
        }
        parse(doc)
        isLoaded = true
    }

    /// A theme being edited in the Style Configurator, read from its live XML.
    init(document: XMLDocument) {
        parse(document)
        isLoaded = true
    }

    /// Read and parsed (MAC-60: a refused or broken file gives an empty theme, never remembered).
    private(set) var isLoaded = false

    private func parse(_ doc: XMLDocument) {
        let globals = (try? doc.nodes(forXPath: "/NotepadPlus/GlobalStyles/WidgetStyle")) as? [XMLElement] ?? []
        globalStyles = globals.map(StyleEntry.init)
        let lexers = (try? doc.nodes(forXPath: "/NotepadPlus/LexerStyles/LexerType")) as? [XMLElement] ?? []
        for lexer in lexers {
            guard let name = lexer.attribute(forName: "name")?.stringValue else { continue }
            lexerStyles[name] = lexer.elements(forName: "WordsStyle").map(StyleEntry.init)
            lexerDescriptions[name] = lexer.attribute(forName: "desc")?.stringValue ?? name
            let ext = (lexer.attribute(forName: "ext")?.stringValue ?? "").split(separator: " ").map { $0.lowercased() }
            if !ext.isEmpty { userExtensions[name] = ext }
        }
    }

    func global(_ name: String) -> StyleEntry? { globalStyles.first { $0.name == name } }
}

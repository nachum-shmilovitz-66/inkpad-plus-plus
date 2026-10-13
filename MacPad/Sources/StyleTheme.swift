import Foundation

/// One `<WordsStyle>` / `<WidgetStyle>` from a Notepad++ styler/theme file.
/// Absent attributes are nil: they inherit from the default style, as in Notepad++.
struct StyleEntry {
    let name: String
    let styleID: Int
    let foreground: Int?      // Scintilla BGR
    let background: Int?      // Scintilla BGR
    let fontName: String?
    let fontStyle: Int?       // bit 1 = bold, 2 = italic, 4 = underline
    let fontSize: Int?        // Windows points
    let keywordClass: String?
    let userWords: String     // element text: extra keywords appended to keywordClass

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
    static let `default` = StyleTheme(url: NppData.url("stylers.model.xml"))

    private(set) var globalStyles: [StyleEntry] = []
    private(set) var lexerStyles: [String: [StyleEntry]] = [:]

    init(url: URL?) {
        guard let url, let doc = try? XMLDocument(contentsOf: url, options: []) else {
            NSLog("MacPad++: could not load theme \(url?.path ?? "nil")")
            return
        }
        let globals = (try? doc.nodes(forXPath: "/NotepadPlus/GlobalStyles/WidgetStyle")) as? [XMLElement] ?? []
        globalStyles = globals.map(StyleEntry.init)
        let lexers = (try? doc.nodes(forXPath: "/NotepadPlus/LexerStyles/LexerType")) as? [XMLElement] ?? []
        for lexer in lexers {
            guard let name = lexer.attribute(forName: "name")?.stringValue else { continue }
            lexerStyles[name] = lexer.elements(forName: "WordsStyle").map(StyleEntry.init)
        }
    }

    func global(_ name: String) -> StyleEntry? { globalStyles.first { $0.name == name } }
}

import Foundation

/// A theme file open in the Style Configurator (MAC-37). Like upstream's writeStyles, edits patch
/// the XML in place — attributes the file never had are not added, everything else is kept — and
/// saving writes the whole document back.
final class StyleDocument {
    let document: XMLDocument
    private(set) var isDirty = false

    /// A style: a global WidgetStyle (`language` nil) or a lexer's WordsStyle.
    struct Ref: Hashable {
        var language: String?
        var name: String
    }

    init(url: URL) throws {
        document = try SafeXML.document(contentsOf: url, options: [.nodePreserveWhitespace])
    }

    init(data: Data) throws {
        document = try SafeXML.document(data: data, options: [.nodePreserveWhitespace])
    }

    var theme: StyleTheme { StyleTheme(document: document) }

    // MARK: - Listing

    /// "Global Styles" comes first in the dialog; then the lexers by description, "Search result" last.
    var languages: [(name: String, description: String)] {
        let lexers = elements("/NotepadPlus/LexerStyles/LexerType").compactMap { e -> (String, String)? in
            guard let name = e.attribute(forName: "name")?.stringValue else { return nil }
            return (name, e.attribute(forName: "desc")?.stringValue ?? name)
        }
        return lexers.sorted { a, b in
            if a.0 == "searchResult" { return false }
            if b.0 == "searchResult" { return true }
            return a.1.localizedCaseInsensitiveCompare(b.1) == .orderedAscending
        }
    }

    func styleNames(language: String?) -> [String] {
        styleElements(language).compactMap { $0.attribute(forName: "name")?.stringValue }
    }

    func element(_ ref: Ref) -> XMLElement? {
        styleElements(ref.language).first { $0.attribute(forName: "name")?.stringValue == ref.name }
    }

    private func styleElements(_ language: String?) -> [XMLElement] {
        guard let language else { return elements("/NotepadPlus/GlobalStyles/WidgetStyle") }
        return lexer(language)?.elements(forName: "WordsStyle") ?? []
    }

    private func lexer(_ language: String) -> XMLElement? {
        elements("/NotepadPlus/LexerStyles/LexerType").first { $0.attribute(forName: "name")?.stringValue == language }
    }

    private func elements(_ path: String) -> [XMLElement] {
        (try? document.nodes(forXPath: path)) as? [XMLElement] ?? []
    }

    // MARK: - Reading

    func attribute(_ ref: Ref, _ name: String) -> String? { element(ref)?.attribute(forName: name)?.stringValue }
    func has(_ ref: Ref, _ name: String) -> Bool { element(ref)?.attribute(forName: name) != nil }

    /// Scintilla BGR, nil when the file has no such colour (the swatch is disabled).
    func foreground(_ ref: Ref) -> Int? { attribute(ref, "fgColor").flatMap(scintillaColour(fromHex:)) }
    func background(_ ref: Ref) -> Int? { attribute(ref, "bgColor").flatMap(scintillaColour(fromHex:)) }
    func fontStyle(_ ref: Ref) -> Int { attribute(ref, "fontStyle").flatMap { Int($0) }.map { max($0, 0) } ?? 0 }

    func userKeywords(_ ref: Ref) -> String {
        (element(ref)?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func userExtensions(_ language: String) -> String { lexer(language)?.attribute(forName: "ext")?.stringValue ?? "" }

    // MARK: - Editing (each edit marks the document dirty)

    /// Colours are only changed where the file has them, as upstream's disabled swatches.
    func setForeground(_ ref: Ref, _ colour: Int) { setIfPresent(ref, "fgColor", Self.hex(colour)) }
    func setBackground(_ ref: Ref, _ colour: Int) { setIfPresent(ref, "bgColor", Self.hex(colour)) }

    /// Font name: only where the style has a fontName attribute; empty means "inherit".
    func setFontName(_ ref: Ref, _ name: String) { setIfPresent(ref, "fontName", name) }

    /// Font size in Windows points; 0 or nil writes "" (inherit).
    func setFontSize(_ ref: Ref, _ size: Int?) {
        guard has(ref, "fontName") || has(ref, "fontSize") else { return }
        set(ref, "fontSize", size.map { $0 > 0 ? String($0) : "" } ?? "")
    }

    /// Bold = 1, italic = 2, underline = 4; the first change of a style without fontStyle starts from 0.
    func setFontStyle(_ ref: Ref, bit: Int, on: Bool) {
        guard has(ref, "fontName") || has(ref, "fontStyle") else { return }
        let value = on ? fontStyle(ref) | bit : fontStyle(ref) & ~bit
        set(ref, "fontStyle", String(value))
    }

    func setUserKeywords(_ ref: Ref, _ words: String) {
        guard let element = element(ref), element.attribute(forName: "keywordClass") != nil else { return }
        element.stringValue = words
        isDirty = true
    }

    func setUserExtensions(_ language: String, _ extensions: String) {
        guard let lexer = lexer(language) else { return }
        lexer.addAttribute(XMLNode.attribute(withName: "ext", stringValue: extensions) as! XMLNode)
        isDirty = true
    }

    private func setIfPresent(_ ref: Ref, _ attribute: String, _ value: String) {
        guard has(ref, attribute) else { return }
        set(ref, attribute, value)
    }

    private func set(_ ref: Ref, _ attribute: String, _ value: String) {
        guard let element = element(ref) else { return }
        element.addAttribute(XMLNode.attribute(withName: attribute, stringValue: value) as! XMLNode)
        isDirty = true
    }

    /// Scintilla BGR → upstream's "RRGGBB".
    static func hex(_ bgr: Int) -> String {
        String(format: "%02X%02X%02X", bgr & 0xFF, (bgr >> 8) & 0xFF, (bgr >> 16) & 0xFF)
    }

    // MARK: - Saving

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try document.xmlData(options: [.nodePreserveWhitespace, .nodeCompactEmptyElement]).write(to: url, options: .atomic)
        isDirty = false
    }
}

/// upstream's Global override (config.xml globalOverride): forces the "Global override" style's
/// colours / font onto every style.
struct GlobalOverride: Codable, Equatable {
    var foreground = false
    var background = false
    var font = false
    var fontSize = false
    var bold = false
    var italic = false
    var underline = false

    var isActive: Bool { foreground || background || font || fontSize || bold || italic || underline }

    private static let key = "GlobalOverride"

    static func load(_ defaults: UserDefaults = AppEnvironment.defaults) -> GlobalOverride {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(GlobalOverride.self, from: $0) } ?? GlobalOverride()
    }

    func save(_ defaults: UserDefaults = AppEnvironment.defaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    /// ScintillaEditView::setStyle's override rules. A forced colour the override style lacks is
    /// dropped instead, so the style inherits the Default Style's (which keeps its own).
    func apply(to style: StyleEntry, styleID: Int, override: StyleEntry?) -> StyleEntry {
        guard isActive, let override else { return style }
        var s = style
        let isDefault = styleID == 32
        if foreground { s.foreground = override.foreground ?? (isDefault ? s.foreground : nil) }
        if background { s.background = override.background ?? (isDefault ? s.background : nil) }
        if font, let name = override.fontName, !name.isEmpty { s.fontName = name }
        if fontSize, let size = override.fontSize, size > 0 { s.fontSize = size }
        if let overrideStyle = override.fontStyle {
            var bits = s.fontStyle ?? 0
            for (enabled, bit) in [(bold, 1), (italic, 2), (underline, 4)] where enabled {
                bits = overrideStyle & bit != 0 ? bits | bit : bits & ~bit
            }
            if bold || italic || underline { s.fontStyle = bits }
        }
        return s
    }
}

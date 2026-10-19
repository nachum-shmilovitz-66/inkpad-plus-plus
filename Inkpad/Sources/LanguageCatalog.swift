import Foundation

/// One `<Language>` entry from upstream's langs.model.xml.
struct LanguageDefinition {
    let info: LanguageInfo
    let extensions: [String]
    /// Keyword lists keyed by upstream keyword class index (instre1 = 0 … type7 = 8).
    let keywords: [Int: String]
    let commentLine: String?
    let commentStart: String?
    let commentEnd: String?
    /// langs.model.xml tabSettings: low 7 bits the tab width, 0x80 "replace by spaces"; nil = global.
    var tabSettings: Int? = nil
    var backspaceUnindent = false
}

/// upstream's keyword class names → index (Parameters.cpp, getKwClassFromName).
func keywordClassIndex(_ name: String) -> Int? {
    let names = ["instre1", "instre2", "type1", "type2", "type3", "type4", "type5", "type6", "type7"]
    if let i = names.firstIndex(of: name) { return i }
    if name.count == 1, let d = Int(name), (0...8).contains(d) { return d }
    // substyle1…8 → 9…16: identifier lists for lexer substyles (populateSubStyleKeywords).
    if name.hasPrefix("substyle"), let n = Int(name.dropFirst("substyle".count)), (1...8).contains(n) { return 8 + n }
    return nil
}

/// Languages from langs.model.xml merged with the built-in upstream language table.
final class LanguageCatalog {
    static let shared = LanguageCatalog(url: UpstreamData.url("langs.model.xml"))

    private(set) var languages: [String: LanguageDefinition] = [:]
    private var byExtension: [String: String] = [:]

    var plainText: LanguageInfo { languageTable[0] }

    init(url: URL?) {
        let infos = Dictionary(languageTable.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        guard let url, let doc = try? SafeXML.document(contentsOf: url),
              let nodes = try? doc.nodes(forXPath: "/NotepadPlus/Languages/Language") as? [XMLElement]
        else {
            NSLog("Inkpad++: could not load langs.model.xml")
            return
        }
        for node in nodes {
            guard let name = node.attribute(forName: "name")?.stringValue, let info = infos[name] else { continue }
            let exts = (node.attribute(forName: "ext")?.stringValue ?? "")
                .split(separator: " ").map { $0.lowercased() }
            var keywords: [Int: String] = [:]
            for kw in node.elements(forName: "Keywords") {
                if let cls = kw.attribute(forName: "name")?.stringValue, let idx = keywordClassIndex(cls) {
                    keywords[idx] = kw.stringValue ?? ""
                }
            }
            languages[name] = LanguageDefinition(
                info: info, extensions: exts, keywords: keywords,
                commentLine: node.attribute(forName: "commentLine")?.stringValue,
                commentStart: node.attribute(forName: "commentStart")?.stringValue,
                commentEnd: node.attribute(forName: "commentEnd")?.stringValue,
                tabSettings: node.attribute(forName: "tabSettings")?.stringValue.flatMap { Int($0) }.flatMap { $0 < 0 ? nil : $0 },
                backspaceUnindent: node.attribute(forName: "backspaceUnindent")?.stringValue == "yes")
            // First language to claim an extension wins, as in upstream's ordered lookup.
            for ext in exts where byExtension[ext] == nil { byExtension[ext] = name }
        }
    }

    /// A language by its langs.model.xml name ("cpp", "python"…), as menus and sessions name it.
    func language(named name: String) -> LanguageInfo? {
        languages[name]?.info ?? languageTable.first { $0.name == name }
    }

    /// Language for a file, following upstream's getLangFromExt: special file names first,
    /// then the extension list from langs.model.xml.
    func language(for url: URL?) -> LanguageInfo {
        guard let url else { return plainText }
        let fileName = url.lastPathComponent.lowercased()
        if let name = LanguageDetector.fileNames[fileName], let def = languages[name] { return def.info }
        let ext = url.pathExtension.lowercased()
        // The Style Configurator's "User ext." come first, as in upstream's getLangFromExt.
        if !ext.isEmpty, let name = ThemeManager.shared.current.userExtensions.first(where: { $0.value.contains(ext) })?.key,
           let def = languages[name] { return def.info }
        if !ext.isEmpty, let name = byExtension[ext], let def = languages[name] { return def.info }
        return plainText
    }
}

/// Locates the upstream data files bundled under Resources/upstream.
enum UpstreamData {
    static func url(_ relativePath: String) -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("upstream").appendingPathComponent(relativePath)
    }
}

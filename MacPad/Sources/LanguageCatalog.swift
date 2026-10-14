import Foundation

/// One `<Language>` entry from Notepad++'s langs.model.xml.
struct LanguageDefinition {
    let info: LanguageInfo
    let extensions: [String]
    /// Keyword lists keyed by Notepad++ keyword class index (instre1 = 0 … type7 = 8).
    let keywords: [Int: String]
    let commentLine: String?
    let commentStart: String?
    let commentEnd: String?
}

/// Notepad++'s keyword class names → index (Parameters.cpp, getKwClassFromName).
func keywordClassIndex(_ name: String) -> Int? {
    let names = ["instre1", "instre2", "type1", "type2", "type3", "type4", "type5", "type6", "type7"]
    if let i = names.firstIndex(of: name) { return i }
    if name.count == 1, let d = Int(name), (0...8).contains(d) { return d }
    return nil  // substyle1…8 are handled by substyles, not keyword sets
}

/// Languages from langs.model.xml merged with the built-in Notepad++ language table.
final class LanguageCatalog {
    static let shared = LanguageCatalog(url: NppData.url("langs.model.xml"))

    private(set) var languages: [String: LanguageDefinition] = [:]
    private var byExtension: [String: String] = [:]

    var plainText: LanguageInfo { languageTable[0] }

    init(url: URL?) {
        let infos = Dictionary(languageTable.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        guard let url, let doc = try? XMLDocument(contentsOf: url, options: []),
              let nodes = try? doc.nodes(forXPath: "/NotepadPlus/Languages/Language") as? [XMLElement]
        else {
            NSLog("MacPad++: could not load langs.model.xml")
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
                commentEnd: node.attribute(forName: "commentEnd")?.stringValue)
            // First language to claim an extension wins, as in Notepad++'s ordered lookup.
            for ext in exts where byExtension[ext] == nil { byExtension[ext] = name }
        }
    }

    /// A language by its langs.model.xml name ("cpp", "python"…), as menus and sessions name it.
    func language(named name: String) -> LanguageInfo? {
        languages[name]?.info ?? languageTable.first { $0.name == name }
    }

    /// Language for a file, following Notepad++'s getLangFromExt: special file names first,
    /// then the extension list from langs.model.xml.
    func language(for url: URL?) -> LanguageInfo {
        guard let url else { return plainText }
        let fileName = url.lastPathComponent.lowercased()
        let special: [String: String] = [
            "makefile": "makefile", "gnumakefile": "makefile",
            "cmakelists.txt": "cmake",
        ]
        if let name = special[fileName], let def = languages[name] { return def.info }
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, let name = byExtension[ext], let def = languages[name] { return def.info }
        return plainText
    }
}

/// Locates the Notepad++ data files bundled under Resources/npp.
enum NppData {
    static func url(_ relativePath: String) -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("npp").appendingPathComponent(relativePath)
    }
}

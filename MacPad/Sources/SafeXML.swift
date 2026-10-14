import Foundation

/// Loads XML that may come from anywhere — Notepad++ themes downloaded from the internet, a user
/// stylers.xml (MAC-60). Notepad++'s data files never declare a DTD or entities, so any that do
/// are refused before libxml2 sees them: no local file pulled in by an external entity (and saved
/// back into a theme), no entity expansion bomb, no FIFO to block on. External entities are off
/// besides, and a file larger than any real theme is not read at all.
enum SafeXML {
    /// Notepad++'s largest data file (langs.model.xml) is well under 1 MB.
    static let maximumSize = 5 * 1024 * 1024

    enum Failure: LocalizedError, Equatable {
        case tooLarge(Int)
        case declaresEntities

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes): "The XML file is too large (\(bytes) bytes)."
            case .declaresEntities: "The XML file declares a DTD or entities, which Notepad++ files never do."
            }
        }
    }

    static func document(contentsOf url: URL, options: XMLNode.Options = []) throws -> XMLDocument {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumSize else { throw Failure.tooLarge(size) }
        return try document(data: Data(contentsOf: url), options: options)
    }

    static func document(data: Data, options: XMLNode.Options = []) throws -> XMLDocument {
        guard data.count <= maximumSize else { throw Failure.tooLarge(data.count) }
        try check(data)
        return try XMLDocument(data: data, options: options.union(.nodeLoadExternalEntitiesNever))
    }

    /// Refuses `<!DOCTYPE` and `<!ENTITY` in any case and in UTF-16 too.
    static func check(_ data: Data) throws {
        let ascii = String(decoding: data.filter { $0 != 0 }, as: UTF8.self).uppercased()
        if ascii.contains("<!DOCTYPE") || ascii.contains("<!ENTITY") { throw Failure.declaresEntities }
    }
}

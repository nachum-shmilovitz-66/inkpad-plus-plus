import Foundation

/// File encodings, named as in Notepad++'s Encoding menu and status bar.
/// Milestone 1 detects BOMs and valid UTF-8 only; Notepad++'s uchardet-based detection of
/// other code pages arrives with milestone 2.
enum TextEncoding: Equatable {
    case utf8, utf8BOM, utf16LE, utf16BE
    /// "ANSI": a single-byte code page. Windows-1252 until code-page detection lands.
    case ansi

    var statusName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8BOM: "UTF-8-BOM"
        case .utf16LE: "UTF-16 LE BOM"
        case .utf16BE: "UTF-16 BE BOM"
        case .ansi: "ANSI"
        }
    }
}

/// Line endings, as Scintilla's SC_EOL_* values.
enum LineEnding: Int {
    case crlf = 0, cr = 1, lf = 2

    var statusName: String {
        switch self {
        case .crlf: "Windows (CR LF)"
        case .cr: "Macintosh (CR)"
        case .lf: "Unix (LF)"
        }
    }

    /// The first line ending in the text decides, as in Notepad++.
    static func detect(utf8 data: Data) -> LineEnding? {
        var previousCR = false
        for byte in data {
            if previousCR { return byte == 0x0A ? .crlf : .cr }
            if byte == 0x0D { previousCR = true } else if byte == 0x0A { return .lf }
        }
        return previousCR ? .cr : nil
    }
}

/// Decodes file bytes into the UTF-8 buffer Scintilla edits, and encodes them back on save.
enum TextFile {
    struct Loaded {
        let utf8: Data
        let encoding: TextEncoding
        let lineEnding: LineEnding?
    }

    enum SaveError: LocalizedError {
        case unrepresentable(TextEncoding)
        var errorDescription: String? {
            switch self {
            case .unrepresentable(let e): "The text contains characters that cannot be saved as \(e.statusName)."
            }
        }
    }

    static func decode(_ data: Data) -> Loaded {
        let bytes = [UInt8](data.prefix(3))
        let utf8: Data
        let encoding: TextEncoding
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            utf8 = data.dropFirst(3)
            encoding = .utf8BOM
        } else if bytes.starts(with: [0xFF, 0xFE]) {
            utf8 = convert(data.dropFirst(2), from: .utf16LittleEndian)
            encoding = .utf16LE
        } else if bytes.starts(with: [0xFE, 0xFF]) {
            utf8 = convert(data.dropFirst(2), from: .utf16BigEndian)
            encoding = .utf16BE
        } else if String(data: data, encoding: .utf8) != nil {
            utf8 = data
            encoding = .utf8
        } else {
            utf8 = convert(data, from: .windowsCP1252)
            encoding = .ansi
        }
        return Loaded(utf8: Data(utf8), encoding: encoding, lineEnding: LineEnding.detect(utf8: utf8))
    }

    static func encode(_ utf8: Data, as encoding: TextEncoding) throws -> Data {
        switch encoding {
        case .utf8:
            return utf8
        case .utf8BOM:
            return Data([0xEF, 0xBB, 0xBF]) + utf8
        case .utf16LE, .utf16BE, .ansi:
            guard let text = String(data: utf8, encoding: .utf8) else { throw SaveError.unrepresentable(encoding) }
            let target: String.Encoding = encoding == .utf16LE ? .utf16LittleEndian
                : encoding == .utf16BE ? .utf16BigEndian : .windowsCP1252
            guard let body = text.data(using: target, allowLossyConversion: false) else {
                throw SaveError.unrepresentable(encoding)
            }
            let bom: [UInt8] = encoding == .utf16LE ? [0xFF, 0xFE] : encoding == .utf16BE ? [0xFE, 0xFF] : []
            return Data(bom) + body
        }
    }

    private static func convert(_ data: Data, from encoding: String.Encoding) -> Data {
        // Windows-1252 leaves five bytes undefined; fall back to Latin-1, which maps every byte.
        let text = String(data: data, encoding: encoding)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        return Data(text.utf8)
    }
}

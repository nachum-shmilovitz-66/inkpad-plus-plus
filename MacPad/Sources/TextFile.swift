import Foundation

/// File encodings, named as in Notepad++'s Encoding menu and status bar.
enum TextEncoding: Equatable {
    case utf8, utf8BOM, utf16LE, utf16BE
    /// "ANSI": Windows-1252 (Notepad++'s ANSI is the system code page; 1252 is the Western one).
    case ansi
    /// A legacy code page from Notepad++'s Character sets (e.g. 1255 Windows-1255 Hebrew),
    /// found by encoding detection (MAC-10). Always one listed in `codePageTable`.
    case codePage(Int)

    var statusName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8BOM: "UTF-8-BOM"
        case .utf16LE: "UTF-16 LE BOM"
        case .utf16BE: "UTF-16 BE BOM"
        case .ansi: "ANSI"
        case .codePage(let cp): codePageTable.first { $0.codePage == cp }?.name ?? "Code page \(cp)"
        }
    }

    /// Foundation's encoding for a Windows code page, if macOS can convert it.
    static func stringEncoding(forCodePage cp: Int) -> String.Encoding? {
        let cf = CFStringConvertWindowsCodepageToEncoding(UInt32(cp))
        guard cf != kCFStringEncodingInvalidId, CFStringIsEncodingAvailable(cf) else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
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

    /// MAC-63: Notepad++ refuses files over 2 GB ("File is too big to be opened"); so does MacPad++,
    /// before reading a byte (a whole-file read of more would exhaust memory).
    static var maximumOpenSize: Int64 = 2 * 1024 * 1024 * 1024

    struct TooLarge: LocalizedError, Equatable {
        let size: Int64
        var errorDescription: String? { "The file is too big to be opened by MacPad++ (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))." }
    }

    /// Reads a whole file, refusing one larger than `maximumOpenSize`.
    static func read(_ url: URL) throws -> Data {
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
           size.int64Value > maximumOpenSize {
            throw TooLarge(size: size.int64Value)
        }
        return try Data(contentsOf: url)
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
            // Valid UTF-8 first: multi-byte UTF-8 sequences almost never occur by chance in a
            // legacy code page, while uchardet can misread short UTF-8 text (Notepad++ itself
            // has to ignore its TIS-620 answers for that reason).
            utf8 = data
            encoding = .utf8
        } else if let cp = EncodingDetector.detectCodePage(data),
                  let decoded = decodeCodePage(data, cp) {
            utf8 = decoded.utf8
            encoding = decoded.encoding
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
        case .utf16LE, .utf16BE, .ansi, .codePage:
            guard let text = String(data: utf8, encoding: .utf8) else { throw SaveError.unrepresentable(encoding) }
            let target: String.Encoding
            switch encoding {
            case .utf16LE: target = .utf16LittleEndian
            case .utf16BE: target = .utf16BigEndian
            case .codePage(let cp):
                guard let e = TextEncoding.stringEncoding(forCodePage: cp) else { throw SaveError.unrepresentable(encoding) }
                target = e
            default: target = .windowsCP1252
            }
            guard let body = text.data(using: target, allowLossyConversion: false) else {
                throw SaveError.unrepresentable(encoding)
            }
            let bom: [UInt8] = encoding == .utf16LE ? [0xFF, 0xFE] : encoding == .utf16BE ? [0xFE, 0xFF] : []
            return Data(bom) + body
        }
    }

    /// Decodes with a detected code page. 1252 and ISO 8859-1 are reported as ANSI (that is what
    /// ANSI means here); a code page macOS cannot convert, or bytes it rejects, give nil.
    static func decodeCodePage(_ data: Data, _ cp: Int) -> (utf8: Data, encoding: TextEncoding)? {
        if cp == 1252 || cp == 28591 { return (convert(data, from: .windowsCP1252), .ansi) }
        guard codePageTable.contains(where: { $0.codePage == cp }),
              let e = TextEncoding.stringEncoding(forCodePage: cp),
              let text = String(data: data, encoding: e) else { return nil }
        return (Data(text.utf8), .codePage(cp))
    }

    private static func convert(_ data: Data, from encoding: String.Encoding) -> Data {
        // Windows-1252 leaves five bytes undefined; fall back to Latin-1, which maps every byte.
        let text = String(data: data, encoding: encoding)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
        return Data(text.utf8)
    }
}

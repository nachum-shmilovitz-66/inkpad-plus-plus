import Foundation

// Changing a document's encoding or line endings from the status bar (Notepad++'s
// "Convert to …" and "EOL Conversion"). Everything here is pure, so it is tested headless;
// EditorTab applies the results to Scintilla.

extension TextEncoding {
    /// Notepad++'s Encoding menu order.
    static let menuOrder: [TextEncoding] = [.ansi, .utf8, .utf8BOM, .utf16BE, .utf16LE]
}

extension LineEnding {
    /// Notepad++'s Edit › EOL Conversion order.
    static let menuOrder: [LineEnding] = [.crlf, .lf, .cr]

    var bytes: [UInt8] {
        switch self {
        case .crlf: [0x0D, 0x0A]
        case .cr: [0x0D]
        case .lf: [0x0A]
        }
    }

    /// Rewrites every line ending in UTF-8 text — CR LF, lone CR and lone LF alike — as `target`.
    /// The number of lines never changes, so line-based positions stay valid.
    static func convert(_ utf8: Data, to target: LineEnding) -> Data {
        var out = Data()
        out.reserveCapacity(utf8.count)
        let eol = target.bytes
        var index = utf8.startIndex
        while index < utf8.endIndex {
            let byte = utf8[index]
            if byte == 0x0D {
                out.append(contentsOf: eol)
                let next = utf8.index(after: index)
                index = next < utf8.endIndex && utf8[next] == 0x0A ? utf8.index(after: next) : next
            } else if byte == 0x0A {
                out.append(contentsOf: eol)
                index = utf8.index(after: index)
            } else {
                out.append(byte)
                index = utf8.index(after: index)
            }
        }
        return out
    }
}

/// The encoding a document will be saved in, and the one it was last loaded or saved in.
/// A conversion only changes the target; the buffer (UTF-8 in Scintilla) is untouched, so the
/// document is dirty exactly when the target differs from what is on disk.
struct FileFormat: Equatable {
    private(set) var encoding: TextEncoding
    private(set) var savedEncoding: TextEncoding

    init(encoding: TextEncoding) {
        self.encoding = encoding
        savedEncoding = encoding
    }

    var isEncodingChanged: Bool { encoding != savedEncoding }

    /// Notepad++'s "Convert to …". Refuses — leaving the format unchanged — when the text cannot be
    /// represented in `target`, using the same check the save path uses, so a conversion can never
    /// produce a document that then fails to save or silently loses characters.
    mutating func convert(_ utf8: Data, to target: TextEncoding) throws {
        _ = try TextFile.encode(utf8, as: target)
        encoding = target
    }

    /// The document was written to disk in `encoding`.
    mutating func markSaved() { savedEncoding = encoding }
}

/// The pop-up menus behind the status bar's encoding and line-ending labels.
enum StatusBarMenu {
    struct Item<Value: Equatable>: Equatable {
        let title: String
        let value: Value
        let isCurrent: Bool
    }

    static func encodingItems(current: TextEncoding) -> [Item<TextEncoding>] {
        TextEncoding.menuOrder.map { Item(title: $0.statusName, value: $0, isCurrent: $0 == current) }
    }

    static func lineEndingItems(current: LineEnding) -> [Item<LineEnding>] {
        LineEnding.menuOrder.map { Item(title: $0.statusName, value: $0, isCurrent: $0 == current) }
    }
}

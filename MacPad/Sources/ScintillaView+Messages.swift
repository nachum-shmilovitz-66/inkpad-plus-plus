import AppKit

/// Thin typed wrappers over Scintilla's message API (`SCI_*` constants import as `Int32`).
extension ScintillaView {
    @discardableResult
    func send(_ message: Int32, _ wParam: Int = 0, _ lParam: Int = 0) -> Int {
        Int(self.message(UInt32(message), wParam: UInt(bitPattern: wParam), lParam: lParam))
    }

    @discardableResult
    func send(_ message: Int32, _ wParam: Int = 0, string: String) -> Int {
        string.withCString { send(message, wParam, Int(bitPattern: $0)) }
    }

    @discardableResult
    func send(_ message: Int32, _ wParam: Int = 0, pointer: UnsafeRawPointer?) -> Int {
        send(message, wParam, Int(bitPattern: pointer))
    }

    /// Replaces the whole document with UTF-8 bytes. Byte-exact: NULs and invalid sequences survive.
    func setUTF8Bytes(_ data: Data) {
        send(SCI_CLEARALL)
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress, raw.count > 0 {
                send(SCI_APPENDTEXT, raw.count, pointer: base)
            }
        }
    }

    /// The whole document as the raw bytes Scintilla holds (UTF-8, since the code page is UTF-8).
    func utf8Bytes() -> Data {
        let length = send(SCI_GETLENGTH)
        guard length > 0, let p = UnsafeRawPointer(bitPattern: send(SCI_GETCHARACTERPOINTER)) else { return Data() }
        return Data(bytes: p, count: length)
    }
}

/// Scintilla colours are 0xBBGGRR; Notepad++ XML stores "RRGGBB".
func scintillaColour(fromHex hex: String) -> Int? {
    guard hex.count == 6, let rgb = Int(hex, radix: 16) else { return nil }
    let r = (rgb >> 16) & 0xFF, g = (rgb >> 8) & 0xFF, b = rgb & 0xFF
    return r | (g << 8) | (b << 16)
}

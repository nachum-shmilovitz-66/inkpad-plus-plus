import Foundation

/// Encoding detection for files without a BOM, as Notepad++ does it (FileManager::detectCodepage):
/// uchardet guesses a charset name from the start of the file, and EncodingMapper turns the name
/// into a code page (MAC-10).
enum EncodingDetector {
    /// Notepad++ runs uchardet on the first block it reads; the same amount is used here.
    static let sampleSize = 128 * 1024

    /// Notepad++'s "Autodetect character encoding" (on by default). Its UI is milestone 4 (MAC-5).
    static let autodetectKey = "AutoDetectEncoding"
    static var isEnabled: Bool { AppEnvironment.defaults.object(forKey: autodetectKey) as? Bool ?? true }

    /// uchardet's guess for `data` as a code page (65001 = UTF-8), or nil when it has none.
    static func detectCodePage(_ data: Data) -> Int? {
        guard isEnabled, !data.isEmpty else { return nil }
        guard let ud = uchardet_new() else { return nil }
        defer { uchardet_delete(ud) }
        let sample = data.prefix(sampleSize)
        let fed = sample.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return -1 }
            return uchardet_handle_data(ud, base, raw.count)
        }
        guard fed == 0 else { return nil }
        uchardet_data_end(ud)
        guard let name = uchardet_get_charset(ud) else { return nil }
        return codePage(forCharset: String(cString: name))
    }

    /// EncodingMapper::getEncodingFromString: case-insensitive match against each code page's
    /// aliases. TIS-620 is ignored, as in Notepad++ ("uchardet detects usually wrongly UTF-8 as
    /// TIS-620"). Two names uchardet reports that Notepad++'s table misses are added: KOI8-R
    /// (the table spells it koi8_r) and ISO-8859-8-I (logical-order Hebrew).
    static func codePage(forCharset name: String) -> Int? {
        let key = name.lowercased()
        if key.isEmpty || key == "tis-620" { return nil }
        if key == "utf-8" || key == "utf8" { return 65001 }
        if let extra = extraAliases[key] { return extra }
        return codePageTable.first { info in info.aliases.contains { $0.lowercased() == key } }?.codePage
    }

    private static let extraAliases: [String: Int] = ["koi8-r": 20866, "iso-8859-8-i": 28598]
}

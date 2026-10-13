import XCTest
@testable import MacPad

/// uchardet charset names → code pages (Notepad++'s EncodingMapper).
final class CharsetMappingTests: XCTestCase {
    private func cp(_ name: String) -> Int? { EncodingDetector.codePage(forCharset: name) }

    func testNamesUchardetReports() {
        XCTAssertEqual(cp("windows-1255"), 1255)
        XCTAssertEqual(cp("windows-1251"), 1251)
        XCTAssertEqual(cp("windows-1253"), 1253)
        XCTAssertEqual(cp("windows-1250"), 1250)
        XCTAssertEqual(cp("ISO-8859-8"), 28598)
        XCTAssertEqual(cp("ISO-8859-5"), 28595)
        XCTAssertEqual(cp("ISO-8859-7"), 28597)
        XCTAssertEqual(cp("IBM866"), 866)
        XCTAssertEqual(cp("IBM855"), 855)
        XCTAssertEqual(cp("x-mac-cyrillic"), 10007)
        XCTAssertEqual(cp("Shift_JIS"), 932)
        XCTAssertEqual(cp("gb18030"), 936)
        XCTAssertEqual(cp("Big5"), 950)
        XCTAssertEqual(cp("EUC-KR"), 51949)
        XCTAssertEqual(cp("UTF-8"), 65001)
    }

    func testMatchingIgnoresCase() {
        XCTAssertEqual(cp("WINDOWS-1255"), 1255)
        XCTAssertEqual(cp("shift_jis"), 932)
    }

    func testNamesNotepadPlusPlusMissesAreAdded() {
        XCTAssertEqual(cp("KOI8-R"), 20866)
        XCTAssertEqual(cp("ISO-8859-8-I"), 28598)
    }

    func testIgnoredAndUnknownNames() {
        XCTAssertNil(cp("TIS-620"), "Notepad++ ignores uchardet's TIS-620")
        XCTAssertNil(cp(""))
        XCTAssertNil(cp("x-euc-tw"))
        XCTAssertNil(cp("ASCII"))
    }

    func testEveryTableEntryHasANameAndAGroup() {
        XCTAssertEqual(codePageTable.count, 46)
        for info in codePageTable {
            XCTAssertFalse(info.name.isEmpty)
            XCTAssertFalse(info.group.isEmpty)
            XCTAssertFalse(info.aliases.isEmpty)
        }
    }

    func testStatusNames() {
        XCTAssertEqual(TextEncoding.codePage(1255).statusName, "Windows-1255")
        XCTAssertEqual(TextEncoding.codePage(28598).statusName, "ISO 8859-8")
        XCTAssertEqual(TextEncoding.codePage(932).statusName, "Shift-JIS")
        XCTAssertEqual(TextEncoding.codePage(950).statusName, "Big5 (Traditional)")
    }
}

/// Opening files without a BOM: the detected code page must decode the text exactly, and saving
/// must give back the original bytes.
final class EncodingDetectionTests: XCTestCase {
    override func tearDown() {
        AppEnvironment.defaults.removeObject(forKey: EncodingDetector.autodetectKey)
    }

    private let hebrew = """
        שלום לכולם. זהו קובץ טקסט שנכתב בעברית כדי לבדוק את זיהוי הקידוד של העורך.
        הקובץ נשמר בקידוד חלונות עברית, כפי שתוכנות ישנות רבות עדיין שומרות קבצים.
        אנחנו מצפים שהעורך יזהה את הקידוד בעצמו ויציג את האותיות כראוי, בלי סימנים משובשים.
        בסוף הבדיקה נשמור את הקובץ שוב ונוודא שהבתים זהים לחלוטין למקור.
        """
    private let russian = """
        Привет всем. Это текстовый файл, написанный по-русски, чтобы проверить определение кодировки.
        Файл сохранён в старой кодировке, как это до сих пор делают многие программы.
        Мы ожидаем, что редактор сам определит кодировку и правильно покажет все буквы.
        """
    private let greek = """
        Γεια σας σε όλους. Αυτό είναι ένα αρχείο κειμένου γραμμένο στα ελληνικά για να ελέγξουμε
        την αναγνώριση της κωδικοποίησης. Το αρχείο αποθηκεύτηκε σε παλιά κωδικοποίηση, όπως κάνουν
        ακόμη πολλά προγράμματα, και περιμένουμε ο επεξεργαστής να τη βρει μόνος του.
        """
    private let japanese = """
        こんにちは。これは文字コードの判定を確かめるために日本語で書いたテキストファイルです。
        このファイルは古い文字コードで保存されています。多くのプログラムが今でもそうしています。
        エディタが自分で文字コードを見つけて、すべての文字を正しく表示することを期待しています。
        """
    private let chineseSimplified = """
        大家好。这是一个用中文写的文本文件，用来检查编辑器的编码识别功能。
        这个文件使用旧的编码保存，很多程序到现在还是这样保存文件。
        我们希望编辑器能够自己找到编码，并且正确地显示所有的文字。
        """
    private let chineseTraditional = """
        大家好。這是一個用中文寫的文字檔案，用來檢查編輯器的編碼識別功能。
        這個檔案使用舊的編碼儲存，很多程式到現在還是這樣儲存檔案。
        我們希望編輯器能夠自己找到編碼，並且正確地顯示所有的文字。
        """
    private let korean = """
        안녕하세요. 이것은 문자 인코딩 판별을 확인하기 위해 한국어로 쓴 텍스트 파일입니다.
        이 파일은 오래된 인코딩으로 저장되었습니다. 많은 프로그램이 아직도 그렇게 저장합니다.
        편집기가 스스로 인코딩을 찾아서 모든 글자를 올바르게 보여 주기를 기대합니다.
        """

    private func bytes(_ text: String, codePage cp: Int) throws -> Data {
        let e = try XCTUnwrap(TextEncoding.stringEncoding(forCodePage: cp), "macOS cannot convert \(cp)")
        return try XCTUnwrap(text.data(using: e), "text not representable in \(cp)")
    }

    /// Detects, checks the text decodes exactly, and that a save gives back the same bytes.
    private func assertRoundTrip(_ text: String, codePage cp: Int, expect expected: Set<Int>,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let original = try bytes(text, codePage: cp)
        let loaded = TextFile.decode(original)
        guard case .codePage(let detected) = loaded.encoding else {
            return XCTFail("\(cp): detected \(loaded.encoding.statusName), not a code page", file: file, line: line)
        }
        XCTAssertTrue(expected.contains(detected), "\(cp): detected \(detected)", file: file, line: line)
        XCTAssertEqual(String(decoding: loaded.utf8, as: UTF8.self), text, "\(cp): text", file: file, line: line)
        XCTAssertEqual(try TextFile.encode(loaded.utf8, as: loaded.encoding), original, "\(cp): save", file: file, line: line)
    }

    // MARK: The reason for MAC-10

    func testHebrewWindows1255() throws {
        try assertRoundTrip(hebrew, codePage: 1255, expect: [1255])
        XCTAssertEqual(TextFile.decode(try bytes(hebrew, codePage: 1255)).encoding.statusName, "Windows-1255")
    }

    func testHebrewISO88598() throws {
        // ISO 8859-8 Hebrew text is also valid Windows-1255; either reading gives the same letters.
        try assertRoundTrip(hebrew, codePage: 28598, expect: [28598, 1255])
    }

    // MARK: Other scripts uchardet knows

    func testRussianWindows1251() throws { try assertRoundTrip(russian, codePage: 1251, expect: [1251]) }
    func testRussianKOI8R() throws { try assertRoundTrip(russian, codePage: 20866, expect: [20866]) }
    func testRussianDOS866() throws { try assertRoundTrip(russian, codePage: 866, expect: [866]) }
    func testGreekWindows1253() throws { try assertRoundTrip(greek, codePage: 1253, expect: [1253, 28597]) }
    func testJapaneseShiftJIS() throws { try assertRoundTrip(japanese, codePage: 932, expect: [932]) }
    func testChineseGBK() throws { try assertRoundTrip(chineseSimplified, codePage: 936, expect: [936]) }
    func testChineseBig5() throws { try assertRoundTrip(chineseTraditional, codePage: 950, expect: [950]) }
    func testKoreanEUCKR() throws { try assertRoundTrip(korean, codePage: 51949, expect: [51949, 949]) }

    // MARK: What must not change

    func testValidUTF8HebrewStaysUTF8() {
        let loaded = TextFile.decode(Data(hebrew.utf8))
        XCTAssertEqual(loaded.encoding, .utf8)
    }

    func testASCIIStaysUTF8() {
        XCTAssertEqual(TextFile.decode(Data("plain ascii\n".utf8)).encoding, .utf8)
    }

    func testWestern1252IsStillANSI() {
        let latin = "Café crème, naïve façade — déjà vu. Señor Muñoz’s piñata.\n".data(using: .windowsCP1252)!
        let loaded = TextFile.decode(latin)
        XCTAssertEqual(loaded.encoding, .ansi)
        XCTAssertEqual(try TextFile.encode(loaded.utf8, as: .ansi), latin)
    }

    func testBOMStillWinsOverDetection() {
        XCTAssertEqual(TextFile.decode(Data([0xEF, 0xBB, 0xBF]) + Data(hebrew.utf8)).encoding, .utf8BOM)
    }

    func testDetectionCanBeTurnedOff() throws {
        AppEnvironment.defaults.set(false, forKey: EncodingDetector.autodetectKey)
        XCTAssertEqual(TextFile.decode(try bytes(hebrew, codePage: 1255)).encoding, .ansi)
    }

    func testEmptyFile() {
        XCTAssertEqual(TextFile.decode(Data()).encoding, .utf8)
        XCTAssertNil(EncodingDetector.detectCodePage(Data()))
    }

    // MARK: Converting and saving a code-page document

    func testHebrewThatIsNotInWindows1252CannotBeConvertedToANSI() throws {
        let loaded = TextFile.decode(try bytes(hebrew, codePage: 1255))
        var format = FileFormat(encoding: loaded.encoding)
        XCTAssertThrowsError(try format.convert(loaded.utf8, to: .ansi))
        try format.convert(loaded.utf8, to: .utf8)
        XCTAssertEqual(format.encoding, .utf8)
        try format.convert(loaded.utf8, to: .codePage(1255))
        XCTAssertFalse(format.isEncodingChanged, "back to the code page it was loaded in")
    }

    func testEmojiCannotBeSavedAsACodePage() {
        XCTAssertThrowsError(try TextFile.encode(Data("שלום 🙂".utf8), as: .codePage(1255)))
    }

    func testPickerListsTheDetectedCodePageChecked() {
        let items = StatusBarMenu.encodingItems(current: .codePage(1255))
        XCTAssertEqual(items.map(\.title), ["ANSI", "UTF-8", "UTF-8-BOM", "UTF-16 BE BOM", "UTF-16 LE BOM", "Windows-1255"])
        XCTAssertEqual(items.filter(\.isCurrent).map(\.value), [.codePage(1255)])
    }

    // MARK: tail -f on a code-page file

    func testShiftJISCharacterSplitAcrossWrites() throws {
        var d = IncrementalDecoder(encoding: .codePage(932))
        let sjis = try bytes("日本", codePage: 932)  // two 2-byte characters
        XCTAssertEqual(String(decoding: d.feed(sjis.prefix(3)), as: UTF8.self), "日")
        XCTAssertEqual(String(decoding: d.feed(sjis.suffix(1)), as: UTF8.self), "本")
    }

    func testSingleByteCodePageFeedsWhole() throws {
        var d = IncrementalDecoder(encoding: .codePage(1255))
        XCTAssertEqual(String(decoding: d.feed(try bytes("שלום", codePage: 1255)), as: UTF8.self), "שלום")
    }
}

/// End to end: a Windows-1255 file opened in a real editor.
final class EditorTabCodePageTests: XCTestCase {
    func testOpeningAndSavingAWindows1255File() throws {
        let text = "שלום עולם. זהו קובץ בעברית שנשמר בקידוד חלונות עברית ונפתח בעורך כדי לבדוק את הזיהוי.\n"
            + "שורה שנייה עם עוד מילים בעברית כדי שלמזהה יהיה מספיק טקסט לעבוד איתו.\n"
        let original = try XCTUnwrap(text.data(using: try XCTUnwrap(TextEncoding.stringEncoding(forCodePage: 1255))))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("he-\(UUID().uuidString).txt")
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let tab = EditorTab(untitledNumber: 1)
        defer { tab.detach() }
        try tab.load(url)
        XCTAssertEqual(tab.status().encoding, "Windows-1255")
        XCTAssertEqual(String(decoding: tab.editor.utf8Bytes(), as: UTF8.self), text)

        tab.editor.send(SCI_DOCUMENTEND)
        tab.editor.send(SCI_APPENDTEXT, "סוף\n".utf8.count, string: "סוף\n")
        tab.save()
        let saved = try Data(contentsOf: url)
        XCTAssertEqual(saved, original + "סוף\n".data(using: TextEncoding.stringEncoding(forCodePage: 1255)!)!)
    }
}

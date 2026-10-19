import XCTest
@testable import Inkpad

/// MAC-60: theme and other XML from anywhere is read without DTDs, entities or unbounded size.
final class SafeXMLTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("safexml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private let theme = """
        <?xml version="1.0" encoding="UTF-8"?>
        <NotepadPlus><GlobalStyles><WidgetStyle name="Default Style" styleID="32" fgColor="000000" bgColor="FFFFFF" fontName="Courier" fontStyle="0" fontSize="10" /></GlobalStyles></NotepadPlus>
        """

    func testAnOrdinaryThemeLoads() throws {
        let doc = try SafeXML.document(data: Data(theme.utf8))
        XCTAssertEqual(try doc.nodes(forXPath: "//WidgetStyle").count, 1)
    }

    /// Regression: an external entity pulled /etc/hosts into the theme, which saving then kept.
    func testExternalEntitiesAreRefused() {
        let xxe = """
            <?xml version="1.0"?>
            <!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/hosts">]>
            <NotepadPlus><GlobalStyles><WidgetStyle name="&e;" /></GlobalStyles></NotepadPlus>
            """
        XCTAssertThrowsError(try SafeXML.document(data: Data(xxe.utf8))) {
            XCTAssertEqual($0 as? SafeXML.Failure, .declaresEntities)
        }
        XCTAssertThrowsError(try StyleDocument(data: Data(xxe.utf8)), "the Style Configurator never sees it")
    }

    /// Regression: 1 KB of nested entities expanded to 600 MB and hung every launch.
    func testEntityBombsAreRefusedAtOnce() {
        var bomb = "<?xml version=\"1.0\"?>\n<!DOCTYPE lolz [\n<!ENTITY lol \"lol\">\n"
        for level in 1...9 {
            bomb += "<!ENTITY lol\(level) \"" + String(repeating: "&lol\(level == 1 ? "" : String(level - 1));", count: 10) + "\">\n"
        }
        bomb += "]>\n<NotepadPlus>&lol9;</NotepadPlus>"
        let start = Date()
        XCTAssertThrowsError(try SafeXML.document(data: Data(bomb.utf8)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testDeclarationsAreFoundInAnyCaseAndInUTF16() {
        for text in ["<!doctype x><a/>", "<a/><!Entity x \"y\">"] {
            XCTAssertThrowsError(try SafeXML.document(data: Data(text.utf8)), text)
        }
        let utf16 = "<?xml version=\"1.0\" encoding=\"UTF-16\"?><!DOCTYPE x [<!ENTITY e SYSTEM \"file:///etc/hosts\">]><a>&e;</a>"
        XCTAssertThrowsError(try SafeXML.document(data: utf16.data(using: .utf16LittleEndian)!))
    }

    func testOversizedFilesAreNotRead() throws {
        let big = root.appendingPathComponent("big.xml")
        try Data(count: SafeXML.maximumSize + 1).write(to: big)
        XCTAssertThrowsError(try SafeXML.document(contentsOf: big)) {
            XCTAssertEqual($0 as? SafeXML.Failure, .tooLarge(SafeXML.maximumSize + 1))
        }
    }

    func testEveryBundledUpstreamFileStillLoads() throws {
        var files = [UpstreamData.url("langs.model.xml"), UpstreamData.url("stylers.model.xml")].compactMap { $0 }
        for folder in ["themes", "functionList"] {
            let dir = try XCTUnwrap(UpstreamData.url(folder))
            files += try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "xml" }
        }
        XCTAssertGreaterThan(files.count, 60)
        for file in files {
            XCTAssertNoThrow(try SafeXML.document(contentsOf: file), file.lastPathComponent)
        }
    }

    /// Regression: the bad theme was remembered before it was read, so every launch hung on it.
    func testABadThemeIsNeverRemembered() throws {
        let suite = "app.inkpad.Inkpad.tests.safexml-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let themes = root.appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        try Data("<!DOCTYPE x [<!ENTITY e \"e\">]><NotepadPlus/>".utf8).write(to: themes.appendingPathComponent("Evil.xml"))
        try Data(theme.utf8).write(to: themes.appendingPathComponent("Good.xml"))
        let manager = ThemeManager(defaults: defaults, bundledDirectory: nil, supportDirectory: root)
        manager.select("Good")
        XCTAssertEqual(manager.selectedName, "Good")
        manager.select("Evil")
        XCTAssertEqual(manager.selectedName, "Good", "refused, the previous theme stays")
        XCTAssertFalse(manager.theme(named: "Evil").isLoaded)
    }
}

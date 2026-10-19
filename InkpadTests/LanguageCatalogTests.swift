import XCTest
@testable import Inkpad

/// Language selection: langs.model.xml parsing plus upstream's getLangFromExt order
/// (special file names first, then the extension lists, first claim winning).
final class LanguageCatalogTests: XCTestCase {
    private var fixtureURL: URL!
    private var catalog: LanguageCatalog!

    /// Only languages that exist in upstream's own language table are accepted, so the fixture
    /// uses real names. "inc" is deliberately claimed twice, cpp first.
    private let fixture = """
    <?xml version="1.0" encoding="UTF-8" ?>
    <NotepadPlus>
      <Languages>
        <Language name="cpp" ext="cpp hpp inc" commentLine="//" commentStart="/*" commentEnd="*/">
          <Keywords name="instre1">if else while</Keywords>
          <Keywords name="type1">int char</Keywords>
          <Keywords name="substyle1">not a keyword set</Keywords>
        </Language>
        <Language name="php" ext="php inc" commentLine="//" />
        <Language name="python" ext="py" commentLine="#" />
        <Language name="makefile" ext="mk" />
        <Language name="cmake" ext="cmake" />
        <Language name="definitely-not-an-upstream-language" ext="zzz" />
      </Languages>
    </NotepadPlus>
    """

    override func setUpWithError() throws {
        fixtureURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("langs-fixture-\(UUID().uuidString).xml")
        try fixture.write(to: fixtureURL, atomically: true, encoding: .utf8)
        catalog = LanguageCatalog(url: fixtureURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureURL)
    }

    private func language(_ path: String) -> LanguageInfo {
        catalog.language(for: URL(fileURLWithPath: path))
    }

    // MARK: extension mapping

    func testExtensionPicksTheLanguageAndItsLexer() {
        XCTAssertEqual(language("/tmp/main.cpp").name, "cpp")
        XCTAssertEqual(language("/tmp/main.cpp").lexer, "cpp")
        XCTAssertEqual(language("/tmp/script.py").name, "python")
        XCTAssertEqual(language("/tmp/script.py").lexer, "python")
    }

    func testExtensionMatchIsCaseInsensitive() {
        XCTAssertEqual(language("/tmp/MAIN.CPP").name, "cpp")
        XCTAssertEqual(language("/tmp/Main.Hpp").name, "cpp")
    }

    func testFirstLanguageToClaimAnExtensionWins() {
        // Both cpp and php list "inc"; cpp appears first in the file.
        XCTAssertEqual(language("/tmp/shared.inc").name, "cpp")
    }

    func testUnknownAndMissingExtensionsFallBackToPlainText() {
        XCTAssertEqual(language("/tmp/notes.unheardof").name, catalog.plainText.name)
        XCTAssertEqual(language("/tmp/README").name, catalog.plainText.name)
        XCTAssertEqual(catalog.language(for: nil).name, catalog.plainText.name)
    }

    func testLanguagesMissingFromUpstreamTableAreIgnored() {
        XCTAssertNil(catalog.languages["definitely-not-an-upstream-language"])
        XCTAssertEqual(language("/tmp/thing.zzz").name, catalog.plainText.name)
    }

    // MARK: special file names

    func testSpecialFileNamesBeatTheExtensionList() {
        XCTAssertEqual(language("/tmp/Makefile").name, "makefile")
        XCTAssertEqual(language("/tmp/GNUmakefile").name, "makefile")
        XCTAssertEqual(language("/tmp/CMakeLists.txt").name, "cmake",
                       "CMakeLists.txt must not fall through to the .txt extension")
    }

    // MARK: parsed definition

    func testKeywordSetsAreKeyedByUpstreamClassIndex() throws {
        let cpp = try XCTUnwrap(catalog.languages["cpp"])
        XCTAssertEqual(cpp.keywords[0], "if else while", "instre1")
        XCTAssertEqual(cpp.keywords[2], "int char", "type1")
        XCTAssertEqual(cpp.keywords.count, 3, "instre1, type1 and substyle1 (class 9, for the identifier substyles)")
    }

    func testCommentTokensAreParsed() throws {
        let cpp = try XCTUnwrap(catalog.languages["cpp"])
        XCTAssertEqual(cpp.commentLine, "//")
        XCTAssertEqual(cpp.commentStart, "/*")
        XCTAssertEqual(cpp.commentEnd, "*/")
        XCTAssertNil(try XCTUnwrap(catalog.languages["python"]).commentStart)
    }

    func testMissingDataFileLeavesAnEmptyCatalogInsteadOfCrashing() {
        let missing = LanguageCatalog(url: URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).xml"))
        XCTAssertTrue(missing.languages.isEmpty)
        XCTAssertEqual(missing.language(for: URL(fileURLWithPath: "/tmp/main.cpp")).name,
                       missing.plainText.name)
        XCTAssertEqual(LanguageCatalog(url: nil).languages.count, 0)
    }

    // MARK: keyword class names

    func testKeywordClassIndex() {
        XCTAssertEqual(keywordClassIndex("instre1"), 0)
        XCTAssertEqual(keywordClassIndex("instre2"), 1)
        XCTAssertEqual(keywordClassIndex("type1"), 2)
        XCTAssertEqual(keywordClassIndex("type7"), 8)
        XCTAssertEqual(keywordClassIndex("0"), 0)
        XCTAssertEqual(keywordClassIndex("8"), 8)
        XCTAssertNil(keywordClassIndex("9"))
        XCTAssertEqual(keywordClassIndex("substyle1"), 9, "MAC-11: substyle classes feed SCI_SETIDENTIFIERS")
        XCTAssertNil(keywordClassIndex("nonsense"))
    }

    // MARK: generated table

    func testLanguageTableMatchesUpstreamLangTypeOrder() {
        XCTAssertEqual(languageTable.first?.name, "normal", "L_TEXT is index 0")
        XCTAssertEqual(languageTable.first?.lexer, "null")
        XCTAssertEqual(languageTable[2].name, "c", "L_C follows L_PHP")
        XCTAssertGreaterThan(languageTable.count, 80)
    }

    func testLanguageTableEntriesAreWellFormed() {
        XCTAssertEqual(Set(languageTable.map(\.name)).count, languageTable.count, "duplicate names")
        for info in languageTable {
            XCTAssertFalse(info.name.isEmpty)
            XCTAssertFalse(info.lexer.isEmpty, "\(info.name) has no lexer")
            XCTAssertTrue(info.langType.hasPrefix("L_"), "\(info.name): \(info.langType)")
        }
    }

    // MARK: the real data file

    /// Runs against upstream's own langs.model.xml when vendor/ is present (it is gitignored,
    /// so a fresh clone skips this).
    func testRealLangsModelXML() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(
            "vendor/upstream/PowerEditor/src/langs.model.xml")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "vendor/ not fetched; run scripts/fetch-vendor.sh")

        let real = LanguageCatalog(url: url)
        XCTAssertGreaterThan(real.languages.count, 50)
        XCTAssertEqual(real.language(for: URL(fileURLWithPath: "/tmp/a.py")).name, "python")
        XCTAssertEqual(real.language(for: URL(fileURLWithPath: "/tmp/a.cpp")).name, "cpp")
        XCTAssertEqual(real.language(for: URL(fileURLWithPath: "/tmp/a.xml")).lexer, "xml")
        XCTAssertEqual(real.language(for: URL(fileURLWithPath: "/tmp/Makefile")).name, "makefile")
        XCTAssertFalse(try XCTUnwrap(real.languages["cpp"]).keywords.isEmpty,
                       "cpp keyword sets should load from the real file")
    }
}

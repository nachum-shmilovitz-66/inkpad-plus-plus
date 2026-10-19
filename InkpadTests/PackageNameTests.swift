import XCTest
@testable import Inkpad

/// MAC-67: the installer's title and file name follow the app's visible name (MAC-66).
final class PackageNameTests: XCTestCase {
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("PackageNameTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    /// A fake app bundle whose en.lproj/InfoPlist.strings holds `strings` (none when nil).
    private func app(_ strings: String?) throws -> URL {
        let app = temp.appendingPathComponent("\(UUID().uuidString).app")
        let lproj = app.appendingPathComponent("Contents/Resources/en.lproj")
        try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
        if let strings {
            try strings.write(to: lproj.appendingPathComponent("InfoPlist.strings"), atomically: true, encoding: .utf8)
        }
        return app
    }

    private func displayName(_ app: URL) throws -> String {
        let p = Process()
        p.executableURL = repo.appendingPathComponent("scripts/display-name.sh")
        p.arguments = [app.path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }

    func testReadsTheLocalizedDisplayName() throws {
        XCTAssertEqual(try displayName(app("CFBundleDisplayName = \"upstream\";\nCFBundleName = \"upstream\";\n")), "upstream")
        XCTAssertEqual(try displayName(app("CFBundleDisplayName = \"Inkpad++\";\n")), "Inkpad++")
    }

    func testFallsBackToInkpad() throws {
        XCTAssertEqual(try displayName(app(nil)), "Inkpad++", "no InfoPlist.strings")
        XCTAssertEqual(try displayName(app("CFBundleName = \"Other\";\n")), "Inkpad++", "no display name")
        XCTAssertEqual(try displayName(app("CFBundleDisplayName = \"\";\n")), "Inkpad++", "empty")
        XCTAssertEqual(try displayName(app("CFBundleDisplayName = \"$(APP_DISPLAY_NAME)\";\n")), "Inkpad++", "unexpanded")
        XCTAssertEqual(try displayName(app("not a plist {{{")), "Inkpad++", "unreadable")
    }

    func testNameIsSafeInAFileName() throws {
        XCTAssertEqual(try displayName(app("CFBundleDisplayName = \"A/B:C\";\n")), "A-B-C")
        XCTAssertEqual(try displayName(app("CFBundleDisplayName = \"  Pad  \";\n")), "Pad")
    }

    func testTheBuiltAppsNameMatchesAppName() throws {
        XCTAssertEqual(try displayName(Bundle.main.bundleURL), AppName.display)
    }

    func testMakePkgUsesTheNameForFileTitleAndCleanup() throws {
        let script = try String(contentsOf: repo.appendingPathComponent("scripts/make-pkg.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("NAME=$(\"$ROOT/scripts/display-name.sh\" \"$APP\")"))
        XCTAssertTrue(script.contains("PKG=$DIST/$NAME-$VERSION.pkg"))
        XCTAssertTrue(script.contains("python3 -I - \"$DISTXML\" \"$NAME\""))
        XCTAssertTrue(script.contains("title.text = sys.argv[2]"))
        XCTAssertTrue(script.contains("olds=(\"$DIST\"/Inkpad++-*.pkg(N) \"$DIST\"/$PERSONAL_NAME-*.pkg(N))"))
        XCTAssertTrue(script.contains("(( ${BUILT[(Ie)$old]} )) || { rm -f \"$old\""), "both packages of this version stay")
        // Identifiers and the payload path stay Inkpad.
        XCTAssertTrue(script.contains("--identifier app.inkpad.Inkpad \\"))
        XCTAssertTrue(script.contains("\"$STAGE/Inkpad++.app\""))
    }

    /// MAC-75: a personal build also gets the public Inkpad++ package — the only one released.
    func testMakePkgBuildsThePublicPackageForAPersonalBuild() throws {
        let script = try String(contentsOf: repo.appendingPathComponent("scripts/make-pkg.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("-derivedDataPath \"$DD\" build ${override:+APP_DISPLAY_NAME=$override}"))
        XCTAssertTrue(script.contains("if [[ $NAME != Inkpad++ && ${PUBLIC_PKG:-1} != 0 ]]; then"))
        XCTAssertTrue(script.contains("build_package Inkpad++ \"$ROOT/build/dd-release-public\""))
        XCTAssertTrue(script.contains("[[ $NAME == Inkpad++ ]] || { echo \"the public package is named $NAME, not Inkpad++\""))
    }
}

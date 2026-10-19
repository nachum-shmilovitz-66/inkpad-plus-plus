import XCTest
@testable import Inkpad

/// MAC-53: the uninstaller — the root script against a fake system, and the app side with a fake
/// administrator prompt.
final class UninstallerTests: XCTestCase {
    private var root: URL!
    private var app: URL { root.appendingPathComponent("Applications/Inkpad++.app") }
    private var daemons: URL { root.appendingPathComponent("LaunchDaemons") }
    private var bin: URL { root.appendingPathComponent("bin") }
    private var log: URL { root.appendingPathComponent("calls.log") }
    private var tools: URL { root.appendingPathComponent("PrivilegedHelperTools") }
    private let label = "app.inkpad.Inkpad.helper"

    private var script: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Inkpad/Resources/uninstall.sh")
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data().write(to: app.appendingPathComponent("Contents/MacOS/inkpad"))
        try fm.createDirectory(at: daemons, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: daemons.appendingPathComponent("\(label).plist"))
        try Data("other".utf8).write(to: daemons.appendingPathComponent("com.example.other.plist"))
        try fm.createDirectory(at: tools, withIntermediateDirectories: true)
        try Data("helper".utf8).write(to: tools.appendingPathComponent(label))
        try Data("other".utf8).write(to: tools.appendingPathComponent("com.example.other"))
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: bin.appendingPathComponent("inkpad").path,
                                  withDestinationPath: app.appendingPathComponent("Contents/MacOS/inkpad").path)
        for stub in ["launchctl", "pkgutil", "security"] {
            let url = root.appendingPathComponent(stub)
            try Data("#!/bin/sh\necho \"\(stub) $*\" >> '\(log.path)'\nexit 0\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func run(_ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path] + args
        p.environment = ["INKPAD_LAUNCHD_DIR": daemons.path, "INKPAD_LAUNCHCTL": root.appendingPathComponent("launchctl").path,
                         "INKPAD_BIN_DIR": bin.path, "INKPAD_PKGUTIL": root.appendingPathComponent("pkgutil").path,
                         "INKPAD_SECURITY": root.appendingPathComponent("security").path,
                         "INKPAD_HELPER_TOOLS_DIR": tools.path,
                         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func calls() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil  // also a dangling link
    }

    func testTheScriptRemovesExactlyWhatThePackageInstalled() throws {
        XCTAssertEqual(try run([app.path]), 0)
        XCTAssertFalse(exists(app))
        XCTAssertFalse(exists(daemons.appendingPathComponent("\(label).plist")))
        XCTAssertTrue(exists(daemons.appendingPathComponent("com.example.other.plist")), "other daemons stay")
        XCTAssertFalse(exists(tools.appendingPathComponent(label)), "the helper copy goes (MAC-56)")
        XCTAssertTrue(exists(tools.appendingPathComponent("com.example.other")))
        XCTAssertFalse(exists(bin.appendingPathComponent("inkpad")))
        XCTAssertEqual(calls(), ["launchctl bootout system/\(label)", "security authorizationdb remove app.inkpad.Inkpad.save",
                                 "pkgutil --forget app.inkpad.Inkpad"], "the save right (MAC-55) goes too")
    }

    func testSomeoneElsesInkpadStays() throws {
        let link = bin.appendingPathComponent("inkpad")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/opt/other/inkpad")
        XCTAssertEqual(try run([app.path]), 0)
        XCTAssertTrue(exists(link))
        try FileManager.default.removeItem(at: link)
        try Data("mine".utf8).write(to: link)
        XCTAssertEqual(try run([app.path]), 0)
        XCTAssertTrue(exists(link))
    }

    func testTheScriptRefusesAnythingButInkpad() throws {
        let other = root.appendingPathComponent("Applications/Other.app")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertEqual(try run([other.path]), 2)
        XCTAssertTrue(exists(other))
        let fake = root.appendingPathComponent("Documents/Inkpad++.app")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        XCTAssertEqual(try run([fake.path]), 2, "a folder named like the app but not an app")
        XCTAssertTrue(exists(fake))
        XCTAssertEqual(calls(), [], "nothing stopped, nothing forgotten")
        XCTAssertTrue(exists(daemons.appendingPathComponent("\(label).plist")))
    }

    /// MAC-58: as root the scripts ignore every test override.
    func testRootScriptsIgnoreTheTestOverridesAsRoot() throws {
        let scripts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for path in ["scripts/pkg/preinstall", "scripts/pkg/postinstall", "Inkpad/Resources/uninstall.sh"] {
            let text = try String(contentsOf: scripts.appendingPathComponent(path), encoding: .utf8)
            let guardRange = try XCTUnwrap(text.range(of: "if [ \"$(/usr/bin/id -u)\" = \"0\" ]; then\n  unset "), path)
            for variable in ["INKPAD_LAUNCHD_DIR", "INKPAD_LAUNCHCTL", "INKPAD_BIN_DIR", "INKPAD_SECURITY", "INKPAD_HELPER_TOOLS_DIR", "INKPAD_PKGUTIL"] {
                if let use = text.range(of: "${\(variable)") {
                    XCTAssertLessThan(guardRange.lowerBound, use.lowerBound, "\(path): \(variable) used before the guard")
                }
            }
        }
    }

    func testRunningItTwiceIsHarmless() throws {
        XCTAssertEqual(try run([app.path]), 0)
        XCTAssertEqual(try run([app.path]), 0)
    }

    func testTheScriptShipsInTheApp() {
        let bundled = Bundle.main.url(forResource: "uninstall", withExtension: "sh")
        XCTAssertNotNil(bundled)
        XCTAssertEqual(bundled.flatMap { try? Data(contentsOf: $0) }, try? Data(contentsOf: script))
    }

    // MARK: - The app side

    final class FakeRunner: PrivilegedRunner {
        var scripts: [String] = []
        var error: Error?
        func run(shellScript: String, prompt: String) throws {
            if let error { throw error }
            scripts.append(shellScript)
        }
    }

    /// `preferencesDomain` is a throwaway suite: removePersistentDomain(forName:) deletes that
    /// domain for the whole user account, whichever UserDefaults instance is asked (2026-10-14:
    /// a test passing "app.inkpad.Inkpad" here wiped the installed app's preferences).
    private func uninstaller(_ runner: FakeRunner, id: String? = "app.inkpad.Inkpad", domain: String? = nil) -> Uninstaller {
        Uninstaller(bundleIdentifier: id, appURL: URL(fileURLWithPath: "/Applications/Inkpad++.app"),
                    scriptURL: URL(fileURLWithPath: "/Applications/Inkpad++.app/Contents/Resources/uninstall.sh"),
                    runner: runner, supportDirectory: root.appendingPathComponent("Support"), preferencesDomain: domain,
                    owner: { _ in 0 })
    }

    func testOnlyTheInstalledReleaseUninstalls() {
        let runner = FakeRunner()
        XCTAssertTrue(uninstaller(runner).isAvailable)
        XCTAssertFalse(uninstaller(runner, id: "app.inkpad.Inkpad.debug").isAvailable, "a Debug build never does")
        var moved = uninstaller(runner)
        moved.appURL = URL(fileURLWithPath: "/tmp/build/Release/Other.app")
        XCTAssertFalse(moved.isAvailable)
        // MAC-58: a copy outside /Applications, or one the user owns, never runs its script as root.
        var downloaded = uninstaller(runner)
        downloaded.appURL = URL(fileURLWithPath: "/Users/me/Downloads/Inkpad++.app")
        XCTAssertFalse(downloaded.isAvailable)
        var userOwned = uninstaller(runner)
        userOwned.owner = { _ in 501 }
        XCTAssertFalse(userOwned.isAvailable)
        XCTAssertThrowsError(try uninstaller(runner, id: "app.inkpad.Inkpad.debug").run(removeSettings: false))
        XCTAssertEqual(runner.scripts, [])
        XCTAssertFalse(Uninstaller().isAvailable, "the test host is a Debug build")
    }

    func testTheRootCommandIsQuoted() {
        XCTAssertEqual(uninstaller(FakeRunner()).command(),
                       "/bin/sh '/Applications/Inkpad++.app/Contents/Resources/uninstall.sh' '/Applications/Inkpad++.app'")
    }

    func testSettingsAreRemovedOnlyWhenAsked() throws {
        let suite = "app.inkpad.Inkpad.tests.uninstall-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("kept?", forKey: "probe")
        let support = root.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let runner = FakeRunner()
        let uninstaller = uninstaller(runner, domain: suite)
        try uninstaller.run(removeSettings: false)
        XCTAssertTrue(exists(support))
        XCTAssertEqual(UserDefaults.standard.persistentDomain(forName: suite)?["probe"] as? String, "kept?")
        XCTAssertEqual(runner.scripts.count, 1)
        try uninstaller.run(removeSettings: true)
        XCTAssertFalse(exists(support))
        XCTAssertNil(UserDefaults.standard.persistentDomain(forName: suite))
    }

    /// Regression (2026-10-14): under test the default domain is none, so nothing real is removed.
    func testTheTestHostNeverRemovesARealPreferencesDomain() {
        XCTAssertNil(Uninstaller().preferencesDomain)
    }

    func testACancelledPromptRemovesNothing() throws {
        let support = root.appendingPathComponent("Support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let runner = FakeRunner()
        runner.error = PrivilegedSaveError.cancelled
        XCTAssertThrowsError(try uninstaller(runner, domain: "app.inkpad.Inkpad.tests.uninstall-cancel").run(removeSettings: true))
        XCTAssertTrue(exists(support), "settings stay when the admin prompt is cancelled")
    }
}

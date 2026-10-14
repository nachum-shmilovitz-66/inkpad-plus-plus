import XCTest
@testable import MacPad

/// MAC-53: the uninstaller — the root script against a fake system, and the app side with a fake
/// administrator prompt.
final class UninstallerTests: XCTestCase {
    private var root: URL!
    private var app: URL { root.appendingPathComponent("Applications/MacPad++.app") }
    private var daemons: URL { root.appendingPathComponent("LaunchDaemons") }
    private var bin: URL { root.appendingPathComponent("bin") }
    private var log: URL { root.appendingPathComponent("calls.log") }
    private let label = "app.macpad.MacPad.helper"

    private var script: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MacPad/Resources/uninstall.sh")
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data().write(to: app.appendingPathComponent("Contents/MacOS/macpad"))
        try fm.createDirectory(at: daemons, withIntermediateDirectories: true)
        try Data("<plist/>".utf8).write(to: daemons.appendingPathComponent("\(label).plist"))
        try Data("other".utf8).write(to: daemons.appendingPathComponent("com.example.other.plist"))
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: bin.appendingPathComponent("macpad").path,
                                  withDestinationPath: app.appendingPathComponent("Contents/MacOS/macpad").path)
        for stub in ["launchctl", "pkgutil"] {
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
        p.environment = ["MACPAD_LAUNCHD_DIR": daemons.path, "MACPAD_LAUNCHCTL": root.appendingPathComponent("launchctl").path,
                         "MACPAD_BIN_DIR": bin.path, "MACPAD_PKGUTIL": root.appendingPathComponent("pkgutil").path,
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
        XCTAssertFalse(exists(bin.appendingPathComponent("macpad")))
        XCTAssertEqual(calls(), ["launchctl bootout system/\(label)", "pkgutil --forget app.macpad.MacPad"])
    }

    func testSomeoneElsesMacpadStays() throws {
        let link = bin.appendingPathComponent("macpad")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/opt/other/macpad")
        XCTAssertEqual(try run([app.path]), 0)
        XCTAssertTrue(exists(link))
        try FileManager.default.removeItem(at: link)
        try Data("mine".utf8).write(to: link)
        XCTAssertEqual(try run([app.path]), 0)
        XCTAssertTrue(exists(link))
    }

    func testTheScriptRefusesAnythingButMacPad() throws {
        let other = root.appendingPathComponent("Applications/Other.app")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertEqual(try run([other.path]), 2)
        XCTAssertTrue(exists(other))
        let fake = root.appendingPathComponent("Documents/MacPad++.app")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        XCTAssertEqual(try run([fake.path]), 2, "a folder named like the app but not an app")
        XCTAssertTrue(exists(fake))
        XCTAssertEqual(calls(), [], "nothing stopped, nothing forgotten")
        XCTAssertTrue(exists(daemons.appendingPathComponent("\(label).plist")))
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
    /// a test passing "app.macpad.MacPad" here wiped the installed app's preferences).
    private func uninstaller(_ runner: FakeRunner, id: String? = "app.macpad.MacPad", domain: String? = nil) -> Uninstaller {
        Uninstaller(bundleIdentifier: id, appURL: URL(fileURLWithPath: "/Applications/MacPad++.app"),
                    scriptURL: URL(fileURLWithPath: "/Applications/MacPad++.app/Contents/Resources/uninstall.sh"),
                    runner: runner, supportDirectory: root.appendingPathComponent("Support"), preferencesDomain: domain)
    }

    func testOnlyTheInstalledReleaseUninstalls() {
        let runner = FakeRunner()
        XCTAssertTrue(uninstaller(runner).isAvailable)
        XCTAssertFalse(uninstaller(runner, id: "app.macpad.MacPad.debug").isAvailable, "a Debug build never does")
        var moved = uninstaller(runner)
        moved.appURL = URL(fileURLWithPath: "/tmp/build/Release/Other.app")
        XCTAssertFalse(moved.isAvailable)
        XCTAssertThrowsError(try uninstaller(runner, id: "app.macpad.MacPad.debug").run(removeSettings: false))
        XCTAssertEqual(runner.scripts, [])
        XCTAssertFalse(Uninstaller().isAvailable, "the test host is a Debug build")
    }

    func testTheRootCommandIsQuoted() {
        XCTAssertEqual(uninstaller(FakeRunner()).command(),
                       "/bin/sh '/Applications/MacPad++.app/Contents/Resources/uninstall.sh' '/Applications/MacPad++.app'")
    }

    func testSettingsAreRemovedOnlyWhenAsked() throws {
        let suite = "app.macpad.MacPad.tests.uninstall-\(UUID().uuidString)"
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
        XCTAssertThrowsError(try uninstaller(runner, domain: "app.macpad.MacPad.tests.uninstall-cancel").run(removeSettings: true))
        XCTAssertTrue(exists(support), "settings stay when the admin prompt is cancelled")
    }
}

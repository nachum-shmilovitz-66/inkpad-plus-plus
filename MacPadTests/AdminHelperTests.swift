import Security
import XCTest
@testable import MacPad

/// The install routine the privileged helper runs as root, run here as the user on temp files.
final class FileInstallerTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func attrs(_ url: URL) throws -> [FileAttributeKey: Any] { try FileManager.default.attributesOfItem(atPath: url.path) }
    private func mode(_ url: URL) throws -> Int { (try attrs(url)[.posixPermissions] as! NSNumber).intValue }
    private func listing() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    // MARK: Validation

    func testRejectsBadPaths() {
        XCTAssertThrowsError(try FileInstaller.validate(path: "relative/file", size: 1))
        XCTAssertThrowsError(try FileInstaller.validate(path: "", size: 1))
        XCTAssertThrowsError(try FileInstaller.validate(path: "/etc/", size: 1))
        XCTAssertThrowsError(try FileInstaller.validate(path: "/tmp/a\0b", size: 1))
        XCTAssertThrowsError(try FileInstaller.validate(path: dir.path, size: 1), "a folder")
        XCTAssertNoThrow(try FileInstaller.validate(path: "/etc/hosts", size: 10))
    }

    func testRejectsOversizedDocuments() {
        XCTAssertThrowsError(try FileInstaller.validate(path: "/tmp/x", size: FileInstaller.maximumSize + 1)) {
            XCTAssertEqual($0 as? FileInstaller.Failure, .tooLarge(FileInstaller.maximumSize + 1))
        }
    }

    // MARK: Installing

    func testReplacingKeepsOwnerAndModeAndIsAtomic() throws {
        let target = dir.appendingPathComponent("hosts")
        try Data("old".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        let before = try attrs(target)

        try FileInstaller.install(Data("new\n".utf8), atPath: target.path)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new\n")
        let after = try attrs(target)
        XCTAssertEqual(try mode(target), 0o640)
        XCTAssertEqual(after[.ownerAccountID] as? NSNumber, before[.ownerAccountID] as? NSNumber)
        XCTAssertEqual(after[.groupOwnerAccountID] as? NSNumber, before[.groupOwnerAccountID] as? NSNumber)
        XCTAssertNotEqual(after[.systemFileNumber] as? NSNumber, before[.systemFileNumber] as? NSNumber, "renamed into place")
        XCTAssertEqual(try listing(), ["hosts"], "no temporary file left")
    }

    func testANewFileGets0644() throws {
        let target = dir.appendingPathComponent("new.conf")
        try FileInstaller.install(Data("x".utf8), atPath: target.path)
        XCTAssertEqual(try mode(target), 0o644)
    }

    func testSymlinkIsUpdatedThroughTheLink() throws {
        let real = dir.appendingPathComponent("real")
        let link = dir.appendingPathComponent("link")
        try Data("1".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        try FileInstaller.install(Data("2".utf8), atPath: link.path)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "2")
    }

    func testAnUnwritableFolderFailsCleanly() throws {
        let target = dir.appendingPathComponent("keep")
        try Data("original".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        XCTAssertThrowsError(try FileInstaller.install(Data("new".utf8), atPath: target.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        XCTAssertEqual(try listing(), ["keep"])
    }

    func testHebrewAndBinaryBytesArriveExactly() throws {
        let target = dir.appendingPathComponent("bytes")
        let payload = Data("שלום\r\n".utf8) + Data([0x00, 0xFF, 0x80])
        try FileInstaller.install(payload, atPath: target.path)
        XCTAssertEqual(try Data(contentsOf: target), payload)
    }
}

/// Who may talk to whom.
final class HelperIdentityTests: XCTestCase {
    func testCodeSigningRequirementsAreValid() {
        for text in [HelperIdentity.clientRequirement, HelperIdentity.helperRequirement] {
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess, text)
            XCTAssertTrue(text.contains("certificate leaf[subject.OU] = \"\(HelperIdentity.teamID)\""))
        }
        XCTAssertTrue(HelperIdentity.clientRequirement.contains("identifier \"app.macpad.MacPad\""))
        XCTAssertTrue(HelperIdentity.helperRequirement.contains("identifier \"app.macpad.MacPad.helper\""))
    }

    func testTheHelperIsInsideTheApp() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MacPadHelper")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
    }

    func testADevelopmentBuildNeverUsesTheHelper() {
        // The test host is ad-hoc signed: the helper is not even asked, the password prompt is used.
        XCTAssertNotEqual(AdminHelperSupport.signingTeam, HelperIdentity.teamID)
        var answer: Bool?
        XPCAdminHelper().checkAvailable { answer = $0 }
        let deadline = Date().addingTimeInterval(3)
        while answer == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(answer, false)
    }

    func testRouteFollowsAvailability() {
        XCTAssertEqual(AdminSaveRoute.decide(helperAvailable: true), .touchID)
        XCTAssertEqual(AdminSaveRoute.decide(helperAvailable: false), .password)
        XCTAssertEqual(AdminHelperSupport.reason(for: URL(fileURLWithPath: "/etc/hosts")),
                       "save \u{201C}hosts\u{201D} as administrator")
    }
}

/// MAC-28: the installer's scripts, run for real as the user against temp folders, with a stub
/// launchctl that records what it was asked to do.
final class PkgScriptTests: XCTestCase {
    private var root: URL!
    private var target: URL!     // stands in for /Applications
    private var daemons: URL!    // stands in for /Library/LaunchDaemons
    private var launchctlLog: URL!
    private var launchctlStub: URL!
    private let label = "app.macpad.MacPad.helper"

    private var scripts: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/pkg")
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pkgscripts-\(UUID().uuidString)")
        target = root.appendingPathComponent("Applications")
        daemons = root.appendingPathComponent("LaunchDaemons")
        launchctlLog = root.appendingPathComponent("launchctl.log")
        launchctlStub = root.appendingPathComponent("launchctl")
        let macOS = target.appendingPathComponent("MacPad++.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: macOS.appendingPathComponent("MacPadHelper"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS.appendingPathComponent("MacPadHelper").path)
        try Data("#!/bin/sh\necho \"$*\" >> '\(launchctlLog.path)'\nexit 0\n".utf8).write(to: launchctlStub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launchctlStub.path)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func run(_ script: String, args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scripts.appendingPathComponent(script).path] + args
        p.environment = ["MACPAD_LAUNCHD_DIR": daemons.path, "MACPAD_LAUNCHCTL": launchctlStub.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func calls() -> [String] {
        ((try? String(contentsOf: launchctlLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private var plist: URL { daemons.appendingPathComponent("\(label).plist") }

    func testPostinstallWritesTheDaemonAndStartsIt() throws {
        XCTAssertEqual(try run("postinstall", args: ["/tmp/MacPad++.pkg", target.path, "/"]), 0)

        let data = try Data(contentsOf: plist)
        let dict = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(dict["Label"] as? String, label)
        XCTAssertEqual(dict["Program"] as? String, target.appendingPathComponent("MacPad++.app/Contents/MacOS/MacPadHelper").path)
        XCTAssertEqual((dict["MachServices"] as? [String: Bool])?[label], true)
        XCTAssertEqual(dict["AssociatedBundleIdentifiers"] as? [String], ["app.macpad.MacPad"])
        XCTAssertEqual(dict[HelperIdentity.machService] == nil, true)
        let mode = (try FileManager.default.attributesOfItem(atPath: plist.path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertEqual(mode, 0o644)

        XCTAssertEqual(calls(), ["bootout system/\(label)", "bootstrap system \(plist.path)"], "old one stopped, new one started")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: daemons.path), ["\(label).plist"], "no temp file left")
    }

    func testTheDaemonLabelMatchesWhatTheAppConnectsTo() {
        XCTAssertEqual(label, HelperIdentity.machService)
        XCTAssertEqual(HelperIdentity.daemonPlistPath, "/Library/LaunchDaemons/\(label).plist")
    }

    func testReinstallingReplacesTheDaemonCleanly() throws {
        try run("postinstall", args: ["p", target.path, "/"])
        try run("postinstall", args: ["p", target.path, "/"])
        XCTAssertEqual(calls().filter { $0.hasPrefix("bootstrap") }.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: daemons.path), ["\(label).plist"])
    }

    func testAMissingHelperNeverFailsTheInstallation() throws {
        try FileManager.default.removeItem(at: target.appendingPathComponent("MacPad++.app/Contents/MacOS/MacPadHelper"))
        XCTAssertEqual(try run("postinstall", args: ["p", target.path, "/"]), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
        XCTAssertEqual(calls(), [])
    }

    func testAFailingLaunchctlNeverFailsTheInstallation() throws {
        try Data("#!/bin/sh\nexit 5\n".utf8).write(to: launchctlStub)
        XCTAssertEqual(try run("postinstall", args: ["p", target.path, "/"]), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
    }

    func testPreinstallStopsTheRunningHelper() throws {
        XCTAssertEqual(try run("preinstall", args: ["p", target.path, "/"]), 0)
        XCTAssertEqual(calls(), ["bootout system/\(label)"])
    }

    func testScriptsAreExecutable() {
        for name in ["preinstall", "postinstall"] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: scripts.appendingPathComponent(name).path), name)
        }
    }
}

// MARK: - The whole save path with stand-ins for the helper and Touch ID

private final class FakeHelper: AdminHelperService {
    var available: Bool
    var failInstall = false
    private(set) var installs = 0
    let unlockedDir: String

    init(available: Bool, unlockedDir: String) {
        self.available = available
        self.unlockedDir = unlockedDir
    }

    func checkAvailable(completion: @escaping (Bool) -> Void) { completion(available) }

    /// Plays root: briefly opens the read-only folder, then runs the real install routine.
    func install(_ data: Data, atPath path: String, completion: @escaping (Error?) -> Void) {
        installs += 1
        if failInstall { completion(FileInstaller.Failure.io("helper unreachable")); return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unlockedDir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: unlockedDir) }
        do { try FileInstaller.install(data, atPath: path); completion(nil) } catch { completion(error) }
    }
}

private struct FakePresence: UserPresenceCheck {
    let answer: Bool
    var asked: ((String) -> Void)?
    func confirm(reason: String, completion: @escaping (Bool) -> Void) { asked?(reason); completion(answer) }
}

/// Counts password-prompt uses; plays root like FakeHelper.
private final class CountingRunner: PrivilegedRunner {
    private(set) var runs = 0
    let unlockedDir: String
    init(unlockedDir: String) { self.unlockedDir = unlockedDir }

    func run(shellScript: String, prompt: String) throws {
        runs += 1
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unlockedDir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: unlockedDir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", shellScript]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw PrivilegedSaveError.failed("script failed") }
    }
}

/// MAC-28: one popup per admin save — Touch ID when the installed helper answers, otherwise the
/// password prompt; never a question from MacPad++.
final class EditorTabTouchIDSaveTests: XCTestCase {
    private var dir: URL!
    private var url: URL!
    private let savedHelper = AdminHelperSupport.helper
    private let savedPresence = AdminHelperSupport.presence
    private let savedRunner = PrivilegedSave.runner

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("touchid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("hosts")
        try Data("127.0.0.1 localhost\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    }

    override func tearDownWithError() throws {
        AdminHelperSupport.helper = savedHelper
        AdminHelperSupport.presence = savedPresence
        PrivilegedSave.runner = savedRunner
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    /// No adminSaveConfirmation: any extra MacPad++ dialog would block the test (no window for it).
    private func editedTab() throws -> EditorTab {
        let tab = EditorTab(untitledNumber: 1)
        try tab.load(url)
        addTeardownBlock { tab.detach() }
        tab.editor.send(SCI_DOCUMENTEND)
        tab.editor.send(SCI_APPENDTEXT, 5, string: "# new")
        return tab
    }

    private func onDisk() throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testInstalledHelperMeansOneTouchIDPopupAndNoPassword() throws {
        let helper = FakeHelper(available: true, unlockedDir: dir.path)
        let runner = CountingRunner(unlockedDir: dir.path)
        var touchID = 0
        AdminHelperSupport.helper = helper
        AdminHelperSupport.presence = FakePresence(answer: true, asked: { _ in touchID += 1 })
        PrivilegedSave.runner = runner
        let tab = try editedTab()
        var saved: Bool?
        tab.save { saved = $0 }

        XCTAssertEqual(saved, true)
        XCTAssertEqual(touchID, 1)
        XCTAssertEqual(runner.runs, 0, "no password prompt")
        XCTAssertEqual(helper.installs, 1)
        XCTAssertEqual(try onDisk(), "127.0.0.1 localhost\n# new")
        XCTAssertFalse(tab.isModified)
    }

    func testCancelledTouchIDSavesNothing() throws {
        let helper = FakeHelper(available: true, unlockedDir: dir.path)
        AdminHelperSupport.helper = helper
        AdminHelperSupport.presence = FakePresence(answer: false)
        let tab = try editedTab()
        var saved: Bool?
        tab.save { saved = $0 }
        XCTAssertEqual(saved, false)
        XCTAssertEqual(helper.installs, 0)
        XCTAssertEqual(try onDisk(), "127.0.0.1 localhost\n")
        XCTAssertTrue(tab.isModified)
    }

    func testAFailingHelperFallsBackToThePasswordPrompt() throws {
        let helper = FakeHelper(available: true, unlockedDir: dir.path)
        helper.failInstall = true
        let runner = CountingRunner(unlockedDir: dir.path)
        AdminHelperSupport.helper = helper
        AdminHelperSupport.presence = FakePresence(answer: true)
        PrivilegedSave.runner = runner
        let tab = try editedTab()
        var saved: Bool?
        tab.save { saved = $0 }
        XCTAssertEqual(saved, true)
        XCTAssertEqual(runner.runs, 1)
        XCTAssertEqual(try onDisk(), "127.0.0.1 localhost\n# new")
    }

    func testNoHelperMeansOnePasswordPopupAndNoQuestion() throws {
        AdminHelperSupport.helper = FakeHelper(available: false, unlockedDir: dir.path)
        var touchID = 0
        AdminHelperSupport.presence = FakePresence(answer: true, asked: { _ in touchID += 1 })
        let runner = CountingRunner(unlockedDir: dir.path)
        PrivilegedSave.runner = runner
        let tab = try editedTab()
        var saved: Bool?
        tab.save { saved = $0 }
        XCTAssertEqual(saved, true)
        XCTAssertEqual(runner.runs, 1)
        XCTAssertEqual(touchID, 0)
        XCTAssertFalse(tab.isModified)
    }
}

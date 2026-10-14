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

/// The helper as packaged inside the app, and who may talk to whom.
final class HelperPackagingTests: XCTestCase {
    private var daemonPlist: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/\(HelperIdentity.daemonPlist)")
    }

    func testTheDaemonPlistIsWhereSMAppServiceLooks() throws {
        let data = try Data(contentsOf: daemonPlist)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, HelperIdentity.machService)
        XCTAssertEqual((plist["MachServices"] as? [String: Bool])?[HelperIdentity.machService], true)
        XCTAssertEqual(plist["AssociatedBundleIdentifiers"] as? [String], [HelperIdentity.appIdentifier])
        let program = try XCTUnwrap(plist["BundleProgram"] as? String)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: Bundle.main.bundleURL.appendingPathComponent(program).path),
                      "BundleProgram \(program) must exist in the app")
    }

    func testCodeSigningRequirementsAreValid() {
        for text in [HelperIdentity.clientRequirement, HelperIdentity.helperRequirement] {
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(text as CFString, [], &requirement), errSecSuccess, text)
            XCTAssertTrue(text.contains("certificate leaf[subject.OU] = \"\(HelperIdentity.teamID)\""))
        }
        XCTAssertTrue(HelperIdentity.clientRequirement.contains("identifier \"app.macpad.MacPad\""))
        XCTAssertTrue(HelperIdentity.helperRequirement.contains("identifier \"app.macpad.MacPad.helper\""))
    }

    func testADevelopmentBuildCannotUseTheHelper() {
        // The test host is ad-hoc signed: no team, so the helper route is unavailable and the
        // password prompt is used.
        XCTAssertNotEqual(AdminHelperSupport.signingTeam, HelperIdentity.teamID)
        XCTAssertEqual(SMAdminHelper().status, .unavailable)
    }
}

/// Which way an admin save goes.
final class AdminSaveRouteTests: XCTestCase {
    func testDecisionTable() {
        XCTAssertEqual(AdminSaveRoute.decide(status: .enabled, setupDeclined: false), .touchID)
        XCTAssertEqual(AdminSaveRoute.decide(status: .enabled, setupDeclined: true), .touchID)
        XCTAssertEqual(AdminSaveRoute.decide(status: .notRegistered, setupDeclined: false), .offerSetup)
        XCTAssertEqual(AdminSaveRoute.decide(status: .requiresApproval, setupDeclined: false), .offerSetup)
        XCTAssertEqual(AdminSaveRoute.decide(status: .notRegistered, setupDeclined: true), .password)
        XCTAssertEqual(AdminSaveRoute.decide(status: .requiresApproval, setupDeclined: true), .password)
        XCTAssertEqual(AdminSaveRoute.decide(status: .unavailable, setupDeclined: false), .password)
    }

    func testTouchIDReasonNamesTheFile() {
        XCTAssertEqual(AdminHelperSupport.reason(for: URL(fileURLWithPath: "/etc/hosts")),
                       "save \u{201C}hosts\u{201D} as administrator")
    }
}

// MARK: - The whole save path with stand-ins for the helper and Touch ID

private final class FakeHelper: AdminHelperService {
    var status: AdminHelperStatus
    var failInstall = false
    private(set) var installs = 0
    private(set) var registered = false
    private(set) var openedSettings = false
    let unlockedDir: String

    init(status: AdminHelperStatus, unlockedDir: String) {
        self.status = status
        self.unlockedDir = unlockedDir
    }

    func register() throws { registered = true }
    func openApprovalSettings() { openedSettings = true }

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
        AdminHelperSupport.setupDeclined = false
    }

    override func tearDownWithError() throws {
        AdminHelperSupport.helper = savedHelper
        AdminHelperSupport.presence = savedPresence
        PrivilegedSave.runner = savedRunner
        AppEnvironment.defaults.removeObject(forKey: AdminHelperSupport.setupDeclinedKey)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func editedTab() throws -> EditorTab {
        let tab = EditorTab(untitledNumber: 1)
        try tab.load(url)
        addTeardownBlock { tab.detach() }
        tab.editor.send(SCI_DOCUMENTEND)
        tab.editor.send(SCI_APPENDTEXT, 5, string: "# new")
        tab.adminSaveConfirmation = { _, answer in answer(true) }
        return tab
    }

    private func onDisk() throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testApprovedHelperUsesTouchIDAndNoPassword() throws {
        let helper = FakeHelper(status: .enabled, unlockedDir: dir.path)
        let runner = CountingRunner(unlockedDir: dir.path)
        var reason: String?
        AdminHelperSupport.helper = helper
        AdminHelperSupport.presence = FakePresence(answer: true, asked: { reason = $0 })
        PrivilegedSave.runner = runner
        let tab = try editedTab()
        var saved: Bool?
        tab.save { saved = $0 }

        XCTAssertEqual(saved, true)
        XCTAssertEqual(reason, "save \u{201C}hosts\u{201D} as administrator")
        XCTAssertEqual(helper.installs, 1)
        XCTAssertEqual(runner.runs, 0, "no password prompt")
        XCTAssertEqual(try onDisk(), "127.0.0.1 localhost\n# new")
        XCTAssertFalse(tab.isModified)
    }

    func testCancelledTouchIDSavesNothing() throws {
        let helper = FakeHelper(status: .enabled, unlockedDir: dir.path)
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
        let helper = FakeHelper(status: .enabled, unlockedDir: dir.path)
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

    func testUnregisteredHelperIsOfferedAndThisSaveUsesThePassword() throws {
        let helper = FakeHelper(status: .notRegistered, unlockedDir: dir.path)
        let runner = CountingRunner(unlockedDir: dir.path)
        AdminHelperSupport.helper = helper
        PrivilegedSave.runner = runner
        let tab = try editedTab()
        var offered = 0
        tab.helperSetupChoice = { answer in offered += 1; answer(.setUp) }
        var saved: Bool?
        tab.save { saved = $0 }

        XCTAssertEqual(offered, 1)
        XCTAssertTrue(helper.registered)
        XCTAssertTrue(helper.openedSettings, "System Settings › Login Items opened for approval")
        XCTAssertEqual(runner.runs, 1)
        XCTAssertEqual(saved, true)
    }

    func testDontAskAgainIsRemembered() throws {
        let helper = FakeHelper(status: .notRegistered, unlockedDir: dir.path)
        let runner = CountingRunner(unlockedDir: dir.path)
        AdminHelperSupport.helper = helper
        PrivilegedSave.runner = runner
        var offered = 0
        let first = try editedTab()
        first.helperSetupChoice = { answer in offered += 1; answer(.dontAskAgain) }
        first.save()
        XCTAssertTrue(AdminHelperSupport.setupDeclined)
        XCTAssertFalse(helper.registered)

        let second = try editedTab()
        second.helperSetupChoice = { answer in offered += 1; answer(.setUp) }
        second.editor.send(SCI_APPENDTEXT, 1, string: "!")
        second.save()
        XCTAssertEqual(offered, 1, "not asked again")
        XCTAssertEqual(runner.runs, 2)
    }

    func testUnavailableHelperGoesStraightToThePassword() throws {
        AdminHelperSupport.helper = FakeHelper(status: .unavailable, unlockedDir: dir.path)
        let runner = CountingRunner(unlockedDir: dir.path)
        PrivilegedSave.runner = runner
        let tab = try editedTab()
        var offered = false
        tab.helperSetupChoice = { answer in offered = true; answer(.notNow) }
        tab.save()
        XCTAssertFalse(offered)
        XCTAssertEqual(runner.runs, 1)
        XCTAssertFalse(tab.isModified)
    }
}

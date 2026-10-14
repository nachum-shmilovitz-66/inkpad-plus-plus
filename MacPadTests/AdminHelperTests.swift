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
            // MAC-55: Developer ID only — not the team's Apple Development certificate.
            XCTAssertTrue(text.contains("certificate 1[field.1.2.840.113635.100.6.2.6] exists"), text)
            XCTAssertTrue(text.contains("certificate leaf[field.1.2.840.113635.100.6.1.13] exists"), text)
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
        XCTAssertEqual(AdminSaveRoute.decide(helperAvailable: true), .helper)
        XCTAssertEqual(AdminSaveRoute.decide(helperAvailable: false), .password)
        XCTAssertEqual(HelperIdentity.prompt(forPath: "/private/etc/hosts"),
                       "MacPad++ wants to save \u{201C}/private/etc/hosts\u{201D} as administrator.", "the full path, not just the name")
    }

    func testTheInstalledReleaseSatisfiesTheClientRequirement() throws {
        let app = URL(fileURLWithPath: "/Applications/MacPad++.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw XCTSkip("no installed MacPad++") }
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(app as CFURL, [], &code), errSecSuccess)
        var requirement: SecRequirement?
        XCTAssertEqual(SecRequirementCreateWithString(HelperIdentity.clientRequirement as CFString, [], &requirement), errSecSuccess)
        XCTAssertEqual(SecStaticCodeCheckValidity(code!, [], requirement), errSecSuccess,
                       "the Developer ID markers match a real release")
    }

    func testAnAuthorizationIsHandedOverAsItsExternalForm() throws {
        let authorization = try XCTUnwrap(AdminHelperSupport.makeAuthorization())
        defer { AuthorizationFree(authorization.reference, [.destroyRights]) }
        XCTAssertEqual(authorization.external.count, Int(kAuthorizationExternalFormLength))
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
        // Never the real `security`: it would change this Mac's authorization database (MAC-55).
        try Data("#!/bin/sh\necho \"$*\" >> '\(securityLog.path)'\ncat > '\(securityInput.path)'\nexit 0\n".utf8).write(to: securityStub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: securityStub.path)
    }

    private var securityStub: URL { root.appendingPathComponent("security") }
    private var tools: URL { root.appendingPathComponent("PrivilegedHelperTools") }
    private var installedHelper: URL { tools.appendingPathComponent(label) }
    private var securityLog: URL { root.appendingPathComponent("security.log") }
    private var securityInput: URL { root.appendingPathComponent("security.in") }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    private func run(_ script: String, args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scripts.appendingPathComponent(script).path] + args
        p.environment = ["MACPAD_LAUNCHD_DIR": daemons.path, "MACPAD_LAUNCHCTL": launchctlStub.path,
                         "MACPAD_BIN_DIR": root.appendingPathComponent("bin").path, "MACPAD_SECURITY": securityStub.path,
                         "MACPAD_HELPER_TOOLS_DIR": tools.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
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
        // MAC-56: a root-owned copy outside /Applications, constrained to the team's signed helper.
        XCTAssertEqual(dict["Program"] as? String, installedHelper.path)
        XCTAssertEqual(try Data(contentsOf: installedHelper), try Data(contentsOf: target.appendingPathComponent("MacPad++.app/Contents/MacOS/MacPadHelper")))
        let helperMode = (try FileManager.default.attributesOfItem(atPath: installedHelper.path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertEqual(helperMode, 0o544, "nobody but root may change what launchd runs")
        XCTAssertEqual(dict["SpawnConstraint"] as? [String: String],
                       ["team-identifier": HelperIdentity.teamID, "signing-identifier": label])
        XCTAssertEqual((dict["MachServices"] as? [String: Bool])?[label], true)
        XCTAssertEqual(dict["AssociatedBundleIdentifiers"] as? [String], ["app.macpad.MacPad"])
        XCTAssertEqual(dict[HelperIdentity.machService] == nil, true)
        let mode = (try FileManager.default.attributesOfItem(atPath: plist.path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertEqual(mode, 0o644)

        XCTAssertEqual(calls(), ["bootout system/\(label)", "bootstrap system \(plist.path)"], "old one stopped, new one started")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: daemons.path), ["\(label).plist"], "no temp file left")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tools.path), [label], "no temp copy left")
    }

    /// MAC-55: the right the helper asks for — an administrator, every time.
    func testPostinstallInstallsTheSaveRight() throws {
        XCTAssertEqual(try run("postinstall", args: ["p", target.path, "/"]), 0)
        XCTAssertEqual(try String(contentsOf: securityLog, encoding: .utf8), "authorizationdb write \(HelperIdentity.saveRight)\n")
        let right = try XCTUnwrap(try PropertyListSerialization.propertyList(from: Data(contentsOf: securityInput), format: nil) as? [String: Any])
        XCTAssertEqual(right["class"] as? String, "user")
        XCTAssertEqual(right["group"] as? String, "admin")
        XCTAssertEqual(right["shared"] as? Bool, false)
        XCTAssertEqual(right["timeout"] as? Int, 0, "never cached")
        XCTAssertEqual(right["allow-root"] as? Bool, false)
        XCTAssertEqual(right["session-owner"] as? Bool, false)
    }

    func testTheDaemonLabelMatchesWhatTheAppConnectsTo() {
        XCTAssertEqual(label, HelperIdentity.machService)
        XCTAssertEqual(HelperIdentity.daemonPlistPath, "/Library/LaunchDaemons/\(label).plist")
    }

    func testReinstallingReplacesTheDaemonCleanly() throws {
        try run("postinstall", args: ["p", target.path, "/"])
        try Data("#!/bin/sh\n# v2\n".utf8).write(to: target.appendingPathComponent("MacPad++.app/Contents/MacOS/MacPadHelper"))
        try run("postinstall", args: ["p", target.path, "/"])
        XCTAssertEqual(try String(contentsOf: installedHelper, encoding: .utf8), "#!/bin/sh\n# v2\n", "the new helper replaces the old copy")
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

    // MARK: MAC-52: /usr/local/bin/macpad

    private var binLink: URL { root.appendingPathComponent("bin/macpad") }
    private var tool: URL { target.appendingPathComponent("MacPad++.app/Contents/MacOS/macpad") }

    private func installTool() throws {
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
    }

    func testPostinstallLinksTheCommandLineTool() throws {
        try installTool()
        XCTAssertEqual(try run("postinstall", args: ["p", target.path, "/"]), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: binLink.path), tool.path)
        XCTAssertEqual(try run("postinstall", args: ["p", target.path, "/"]), 0, "reinstalling keeps it")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: binLink.path), tool.path)
    }

    func testPostinstallReplacesAnOlderMacPadLink() throws {
        try installTool()
        try FileManager.default.createDirectory(at: binLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: binLink.path, withDestinationPath: "/Volumes/Old/MacPad++.app/Contents/MacOS/macpad")
        XCTAssertEqual(try run("postinstall", args: ["p", target.path, "/"]), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: binLink.path), tool.path)
    }

    func testPostinstallLeavesSomeoneElsesMacpadAlone() throws {
        try installTool()
        try FileManager.default.createDirectory(at: binLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: binLink)
        XCTAssertEqual(try run("postinstall", args: ["p", target.path, "/"]), 0)
        XCTAssertEqual(try String(contentsOf: binLink, encoding: .utf8), "mine")
        try FileManager.default.removeItem(at: binLink)
        try FileManager.default.createSymbolicLink(atPath: binLink.path, withDestinationPath: "/opt/other/macpad")
        XCTAssertEqual(try run("postinstall", args: ["p", target.path, "/"]), 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: binLink.path), "/opt/other/macpad")
    }

    func testPostinstallWithoutTheToolLinksNothing() throws {
        XCTAssertEqual(try run("postinstall", args: ["p", target.path, "/"]), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: binLink.path))
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
    /// The administrator prompt's answer, as the real helper's authorizer would give it.
    var authorizer = FakeAuthorizer()

    func install(_ data: Data, atPath path: String, completion: @escaping (AdminHelperResult) -> Void) {
        installs += 1
        if failInstall { completion(.failed("helper unreachable")); return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unlockedDir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: unlockedDir) }
        let (reply, message) = HelperRequest.handle(data, path: path, authorization: Data(count: 32), authorizer: authorizer)
        completion(AdminHelperResult(reply, message))
    }
}

/// Stands in for Authorization Services: answers as the administrator would, and counts prompts.
final class FakeAuthorizer: RequestAuthorizer {
    var answer: RequestAuthorization? = nil  // nil = approved
    private(set) var prompts: [String] = []
    func authorize(_ externalForm: Data, path: String) throws {
        prompts.append(path)
        if let answer { throw answer }
    }
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

/// MAC-28 / MAC-55: one popup per admin save — the helper's administrator prompt when the
/// installed helper answers, otherwise the password prompt; never a question from MacPad++.
final class EditorTabHelperSaveTests: XCTestCase {
    private var dir: URL!
    private var url: URL!
    private let savedHelper = AdminHelperSupport.helper
    private let savedRunner = PrivilegedSave.runner

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("adminsave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("hosts")
        try Data("127.0.0.1 localhost\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    }

    override func tearDownWithError() throws {
        AdminHelperSupport.helper = savedHelper
        PrivilegedSave.runner = savedRunner
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    /// No adminSaveConfirmation: any extra MacPad++ dialog would block the test (no window for it).
    private func editedTab(_ fileURL: URL? = nil) throws -> EditorTab {
        let tab = EditorTab(untitledNumber: 1)
        try tab.load(fileURL ?? url)
        addTeardownBlock { tab.detach() }
        tab.editor.send(SCI_DOCUMENTEND)
        tab.editor.send(SCI_APPENDTEXT, 5, string: "# new")
        return tab
    }

    private func onDisk() throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testInstalledHelperMeansOneAdministratorPromptAndNoPassword() throws {
        let helper = FakeHelper(available: true, unlockedDir: dir.path)
        let runner = CountingRunner(unlockedDir: dir.path)
        AdminHelperSupport.helper = helper
        PrivilegedSave.runner = runner
        let tab = try editedTab()
        var saved: Bool?
        tab.save { saved = $0 }

        XCTAssertEqual(saved, true)
        XCTAssertEqual(helper.authorizer.prompts, [url.resolvingSymlinksInPath().path], "one prompt, naming the real file")
        XCTAssertEqual(runner.runs, 0, "no password prompt")
        XCTAssertEqual(try onDisk(), "127.0.0.1 localhost\n# new")
        XCTAssertFalse(tab.isModified)
    }

    func testACancelledPromptSavesNothingAndAsksNothingMore() throws {
        let helper = FakeHelper(available: true, unlockedDir: dir.path)
        helper.authorizer.answer = .cancelled
        let runner = CountingRunner(unlockedDir: dir.path)
        AdminHelperSupport.helper = helper
        PrivilegedSave.runner = runner
        let tab = try editedTab()
        var saved: Bool?
        tab.save { saved = $0 }
        XCTAssertEqual(saved, false)
        XCTAssertEqual(runner.runs, 0, "no second prompt after a cancel")
        XCTAssertEqual(try onDisk(), "127.0.0.1 localhost\n")
        XCTAssertTrue(tab.isModified)
    }

    /// Regression (MAC-55): the helper writes only what an administrator authorized.
    func testAnUnauthorizedRequestWritesNothing() throws {
        let helper = FakeHelper(available: true, unlockedDir: dir.path)
        helper.authorizer.answer = .denied("not an administrator")
        AdminHelperSupport.helper = helper
        PrivilegedSave.runner = CountingRunner(unlockedDir: dir.path)
        let tab = try editedTab()
        var saved: Bool?
        tab.save { saved = $0 }
        XCTAssertEqual(helper.installs, 1)
        XCTAssertEqual(saved, true, "the helper refused, so the password prompt (also an administrator) did it")
        XCTAssertEqual((PrivilegedSave.runner as? CountingRunner)?.runs, 1)
    }

    func testAFailingHelperFallsBackToThePasswordPrompt() throws {
        let helper = FakeHelper(available: true, unlockedDir: dir.path)
        helper.failInstall = true
        let runner = CountingRunner(unlockedDir: dir.path)
        AdminHelperSupport.helper = helper
        PrivilegedSave.runner = runner
        let tab = try editedTab()
        var saved: Bool?
        tab.save { saved = $0 }
        XCTAssertEqual(saved, true)
        XCTAssertEqual(runner.runs, 1)
        XCTAssertEqual(try onDisk(), "127.0.0.1 localhost\n# new")
    }

    func testNoHelperMeansOnePasswordPopupAndNoQuestion() throws {
        let helper = FakeHelper(available: false, unlockedDir: dir.path)
        AdminHelperSupport.helper = helper
        let runner = CountingRunner(unlockedDir: dir.path)
        PrivilegedSave.runner = runner
        let tab = try editedTab()
        var saved: Bool?
        tab.save { saved = $0 }
        XCTAssertEqual(saved, true)
        XCTAssertEqual(runner.runs, 1)
        XCTAssertEqual(helper.installs, 0)
        XCTAssertFalse(tab.isModified)
    }
}

/// MAC-55: what the helper does with a request, with Authorization Services faked.
final class HelperRequestTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("helperrequest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testAnAuthorizedRequestIsWritten() throws {
        let authorizer = FakeAuthorizer()
        let target = dir.appendingPathComponent("a.txt")
        let (reply, message) = HelperRequest.handle(Data("x".utf8), path: target.path, authorization: Data(count: 32), authorizer: authorizer)
        XCTAssertEqual(reply, .saved, message ?? "")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "x")
        XCTAssertEqual(authorizer.prompts.count, 1)
    }

    func testNothingIsWrittenWithoutTheAdministrator() throws {
        let target = dir.appendingPathComponent("a.txt")
        for answer in [RequestAuthorization.cancelled, .denied("no")] {
            let authorizer = FakeAuthorizer()
            authorizer.answer = answer
            let (reply, _) = HelperRequest.handle(Data("x".utf8), path: target.path, authorization: Data(count: 32), authorizer: authorizer)
            XCTAssertEqual(reply, answer == .cancelled ? .cancelled : .failed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testTheAdministratorSeesTheFileThatWillReallyBeWritten() throws {
        let real = dir.appendingPathComponent("real.txt")
        try Data().write(to: real)
        let link = dir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let authorizer = FakeAuthorizer()
        _ = HelperRequest.handle(Data("x".utf8), path: link.path, authorization: Data(count: 32), authorizer: authorizer)
        XCTAssertEqual(authorizer.prompts, [real.resolvingSymlinksInPath().path])
    }

    func testBadAndProtectedRequestsAreRefusedBeforeAnyPrompt() throws {
        let authorizer = FakeAuthorizer()
        for path in ["relative.txt", "/etc/sudoers", "/private/etc/sudoers.d/macpad", "/Library/LaunchDaemons/evil.plist",
                     "/Library/LaunchAgents/evil.plist", "/Library/PrivilegedHelperTools/x", "/System/Library/x",
                     "/etc/pam.d/sudo", "/private/var/root/.profile", "/etc/periodic/daily/x"] {
            let (reply, _) = HelperRequest.handle(Data("x".utf8), path: path, authorization: Data(count: 32), authorizer: authorizer)
            XCTAssertEqual(reply, .refused, path)
        }
        XCTAssertEqual(authorizer.prompts, [], "the administrator is never asked about a refused file")
    }

    func testProtectedPathsSeeThroughSymlinks() throws {
        let link = dir.appendingPathComponent("innocent.plist")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Library/LaunchDaemons/evil.plist")
        XCTAssertTrue(FileInstaller.isProtected(link.path))
        XCTAssertFalse(FileInstaller.isProtected("/etc/hosts"))
        XCTAssertFalse(FileInstaller.isProtected("/usr/local/etc/nginx.conf"))
        XCTAssertFalse(FileInstaller.isProtected(dir.appendingPathComponent("x").path))
    }

    func testAProtectedFileIsRefusedInTheAppToo() throws {
        let tab = EditorTab(untitledNumber: 1)
        defer { tab.detach() }
        var errors: [Error] = []
        tab.onSaveError = { errors.append($0) }
        let helper = FakeHelperForProtected()
        let saved = AdminHelperSupport.helper
        AdminHelperSupport.helper = helper
        defer { AdminHelperSupport.helper = saved }
        // The admin path is reached through a permission error; a protected target never gets there.
        let target = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = target.appendingPathComponent("daemon.plist")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/Library/LaunchDaemons/x.plist")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
        tab.editor.setUTF8Bytes(Data("<plist/>".utf8))
        var result: Bool?
        tab.adminSaveConfirmation = { _, proceed in proceed(true) }
        tab.saveAs(to: link) { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertEqual(helper.asked, 0)
        XCTAssertTrue(errors.contains { ($0 as? FileInstaller.Failure) == .protectedPath(link.path) }, "\(errors)")
    }
}

private final class FakeHelperForProtected: AdminHelperService {
    private(set) var asked = 0
    func checkAvailable(completion: @escaping (Bool) -> Void) { asked += 1; completion(true) }
    func install(_ data: Data, atPath path: String, completion: @escaping (AdminHelperResult) -> Void) { asked += 1; completion(.saved) }
}

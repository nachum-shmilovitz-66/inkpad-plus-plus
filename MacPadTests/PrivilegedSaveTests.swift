import XCTest
@testable import MacPad

/// Runs the install script with /bin/sh as the current user — the same script the admin prompt
/// runs as root. `beforeRun`/`afterRun` let a test briefly grant itself what root would have.
private struct ShellRunner: PrivilegedRunner {
    var beforeRun: () throws -> Void = {}
    var afterRun: () -> Void = {}
    var prompts: ((String) -> Void)?

    func run(shellScript: String, prompt: String) throws {
        prompts?(prompt)
        try beforeRun()
        defer { afterRun() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", shellScript]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw PrivilegedSaveError.failed(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
    }
}

private struct FailingRunner: PrivilegedRunner {
    let error: PrivilegedSaveError
    func run(shellScript: String, prompt: String) throws { throw error }
}

/// Which save failures administrator rights can fix.
final class PermissionDeniedTests: XCTestCase {
    func testCocoaNoPermission() {
        XCTAssertTrue(PrivilegedSave.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
    }

    func testPOSIXAccessAndPermission() {
        XCTAssertTrue(PrivilegedSave.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        XCTAssertTrue(PrivilegedSave.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
    }

    func testUnderlyingErrorIsFollowed() {
        let inner = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let outer = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: inner])
        XCTAssertTrue(PrivilegedSave.isPermissionDenied(outer))
    }

    func testOtherFailuresAreNot() {
        XCTAssertFalse(PrivilegedSave.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError)))
        XCTAssertFalse(PrivilegedSave.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        XCTAssertFalse(PrivilegedSave.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
    }

    func testARealWriteIntoAReadOnlyFolderIsPermissionDenied() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        XCTAssertThrowsError(try Data("x".utf8).write(to: dir.appendingPathComponent("f.txt"), options: .atomic)) {
            XCTAssertTrue(PrivilegedSave.isPermissionDenied($0), "\($0)")
        }
    }
}

/// The script and the AppleScript around it.
final class PrivilegedSaveScriptTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("admin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func attributes(_ url: URL) throws -> (mode: Int, owner: Int, inode: Int) {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        return ((a[.posixPermissions] as! NSNumber).intValue, (a[.ownerAccountID] as! NSNumber).intValue,
                (a[.systemFileNumber] as! NSNumber).intValue)
    }

    func testShellQuotingSurvivesHostileNames() throws {
        for name in ["plain", "with space", "it's", "a\"b", "$HOME", "`date`", "semi;colon", "back\\slash", "שלום"] {
            let p = Process()
            let out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "printf %s \(PrivilegedSave.shellQuote(name))"]
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), name)
        }
    }

    func testReplacingKeepsModeAndOwnerAndIsAtomic() throws {
        let target = dir.appendingPathComponent("config file's.conf")
        try Data("old".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        let before = try attributes(target)

        try PrivilegedSave.save(Data("new contents\n".utf8), to: target, runner: ShellRunner())

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new contents\n")
        let after = try attributes(target)
        XCTAssertEqual(after.mode, 0o640, "mode kept")
        XCTAssertEqual(after.owner, before.owner, "owner kept")
        XCTAssertNotEqual(after.inode, before.inode, "replaced by rename, never written in place")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["config file's.conf"], "no temp file left")
    }

    func testANewFileGets0644() throws {
        let target = dir.appendingPathComponent("new.txt")
        try PrivilegedSave.save(Data("hi".utf8), to: target, runner: ShellRunner())
        XCTAssertEqual(try attributes(target).mode, 0o644)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "hi")
    }

    func testASymlinkedFileIsUpdatedThroughTheLink() throws {
        let real = dir.appendingPathComponent("real.txt")
        let link = dir.appendingPathComponent("link.txt")
        try Data("v1".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try PrivilegedSave.save(Data("v2".utf8), to: link, runner: ShellRunner())

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path, "still a link")
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), "v2")
    }

    func testAFailingScriptLeavesTheTargetAndNoTempFile() throws {
        let target = dir.appendingPathComponent("keep.txt")
        try Data("original".utf8).write(to: target)
        let script = PrivilegedSave.installScript(source: dir.appendingPathComponent("missing").path, target: target.path)
        XCTAssertThrowsError(try ShellRunner().run(shellScript: script, prompt: ""))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["keep.txt"])
    }

    func testTheUsersTempCopyIsRemovedEvenWhenTheRunnerFails() throws {
        let tempDir = FileManager.default.temporaryDirectory.path
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: tempDir).filter { $0.hasPrefix("MacPad++-admin-save-") })
        XCTAssertThrowsError(try PrivilegedSave.save(Data("x".utf8), to: dir.appendingPathComponent("t"),
                                                     runner: FailingRunner(error: .cancelled))) {
            XCTAssertEqual($0 as? PrivilegedSaveError, .cancelled)
        }
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: tempDir).filter { $0.hasPrefix("MacPad++-admin-save-") })
        XCTAssertEqual(after, before)
    }

    func testThePromptNamesTheFile() throws {
        var seen: String?
        try PrivilegedSave.save(Data("x".utf8), to: dir.appendingPathComponent("hosts"), runner: ShellRunner(prompts: { seen = $0 }))
        let resolved = dir.appendingPathComponent("hosts").resolvingSymlinksInPath().path
        XCTAssertEqual(seen, "MacPad++ needs administrator rights to save \u{201C}\(resolved)\u{201D}.", "the full path (MAC-55)")
    }

    func testTheAppleScriptCompiles() {
        let shell = PrivilegedSave.installScript(source: "/tmp/a \"b\" \\c", target: "/etc/it's here")
        let source = PrivilegedSave.appleScript(shell: shell, prompt: "Save \u{201C}x\u{201D} \"now\"")
        XCTAssertTrue(source.hasSuffix("with administrator privileges"))
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        XCTAssertTrue(script?.compileAndReturnError(&error) ?? false, "\(String(describing: error))")
    }

    /// MAC-57: root runs the helper's descriptor-based code, not a shell copy with a guessable temp name.
    func testTheRootCommandIsTheHelperOnce() {
        let command = PrivilegedSave.installScript(source: "/tmp/a b", target: "/etc/it's", owner: 501, helper: "/A/MacPadHelper")
        XCTAssertEqual(command, "exec '/A/MacPadHelper' --install-file '/tmp/a b' '/etc/it'\\''s' 501")
        XCTAssertFalse(command.contains("$$"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: PrivilegedSave.helperPath))
    }

    func testAppleScriptStringEscaping() {
        XCTAssertEqual(PrivilegedSave.appleScriptString(#"a "q" \ b"#), #""a \"q\" \\ b""#)
    }
}

/// The whole save path: a document whose file sits in a folder the user cannot write.
final class EditorTabAdminSaveTests: XCTestCase {
    private var dir: URL!
    private var url: URL!
    private let savedRunner = PrivilegedSave.runner

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("protected-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("hosts")
        try Data("127.0.0.1 localhost\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
    }

    override func tearDownWithError() throws {
        PrivilegedSave.runner = savedRunner
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    /// Stands in for root: lets the script write into the read-only folder for the duration.
    private func rootLikeRunner() -> ShellRunner {
        let path = dir.path
        return ShellRunner(
            beforeRun: { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) },
            afterRun: { try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path) })
    }

    private func editedTab() throws -> EditorTab {
        let tab = EditorTab(untitledNumber: 1)
        try tab.load(url)
        addTeardownBlock { tab.detach() }
        tab.editor.send(SCI_DOCUMENTEND)
        tab.editor.send(SCI_APPENDTEXT, 22, string: "10.0.0.5 build-server\n")
        return tab
    }

    private func onDisk() throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testPermissionDeniedOffersAdminSaveAndSavesWhenAccepted() throws {
        PrivilegedSave.runner = rootLikeRunner()
        let tab = try editedTab()
        var asked: URL?
        tab.adminSaveConfirmation = { url, answer in asked = url; answer(true) }
        var result: Bool?
        tab.save { result = $0 }

        XCTAssertEqual(asked, url)
        XCTAssertEqual(result, true)
        XCTAssertEqual(try onDisk(), "127.0.0.1 localhost\n10.0.0.5 build-server\n")
        XCTAssertFalse(tab.isModified)
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        XCTAssertEqual(mode, 0o444, "the file keeps its permissions")
    }

    func testDecliningLeavesTheFileAndKeepsTheEdits() throws {
        PrivilegedSave.runner = rootLikeRunner()
        let tab = try editedTab()
        tab.adminSaveConfirmation = { _, answer in answer(false) }
        var result: Bool?
        tab.save { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertEqual(try onDisk(), "127.0.0.1 localhost\n")
        XCTAssertTrue(tab.isModified)
    }

    func testCancellingThePasswordPromptLeavesEverythingAsItWas() throws {
        PrivilegedSave.runner = FailingRunner(error: .cancelled)
        let tab = try editedTab()
        tab.adminSaveConfirmation = { _, answer in answer(true) }
        var result: Bool?
        tab.save { result = $0 }
        XCTAssertEqual(result, false)
        XCTAssertEqual(try onDisk(), "127.0.0.1 localhost\n")
        XCTAssertTrue(tab.isModified)
    }

    func testAnAdminSaveIsNotReportedAsAnExternalChange() throws {
        PrivilegedSave.runner = rootLikeRunner()
        let tab = try editedTab()
        tab.adminSaveConfirmation = { _, answer in answer(true) }
        tab.save()
        tab.checkDiskState()
        XCTAssertNil(tab.pendingExternalChange)
    }

    func testAWritableFileNeverAsks() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let tab = try editedTab()
        var asked = false
        tab.adminSaveConfirmation = { _, answer in asked = true; answer(false) }
        tab.save()
        XCTAssertFalse(asked)
        XCTAssertFalse(tab.isModified)
    }
}

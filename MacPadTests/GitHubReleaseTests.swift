import XCTest

/// MAC-68: deploy patch publishes the installer as GitHub release v<version> and keeps only that
/// release. Runs scripts/github-release.sh with stub `gh` and `git` — never the real ones.
final class GitHubReleaseTests: XCTestCase {
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private var temp: URL!
    private var log: URL { temp.appendingPathComponent("calls.log") }

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("GitHubReleaseTests-\(UUID().uuidString)")
        let bin = temp.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try stub(bin.appendingPathComponent("gh"), """
            #!/bin/sh
            echo "gh $*" >> "$STUB_LOG"
            case "$1 $2" in
              "repo view") echo "$STUB_PRIVATE" ;;
              "release view") [ "$STUB_EXISTS" = 1 ] || exit 1 ;;
              "release list") for t in $STUB_RELEASES; do echo "$t"; done ;;
            esac
            exit 0
            """)
        try stub(bin.appendingPathComponent("git"), """
            #!/bin/sh
            echo "git $*" >> "$STUB_LOG"
            case "$1" in
              rev-parse) if [ "$2" = "--abbrev-ref" ]; then echo main; else echo abc123; fi ;;
              merge-base) [ "$STUB_PUSHED" = 1 ] || exit 1 ;;
            esac
            exit 0
            """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func stub(_ url: URL, _ body: String) throws {
        try (body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func pkg(_ name: String) throws -> String {
        let url = temp.appendingPathComponent(name)
        try Data("pkg".utf8).write(to: url)
        return url.path
    }

    /// Runs the script; returns its exit status and the stub calls it made.
    private func release(_ pkg: String, _ version: String, isPrivate: Bool = true, pushed: Bool = true,
                         exists: Bool = false, releases: [String] = []) throws -> (status: Int32, calls: [String]) {
        let p = Process()
        p.executableURL = repo.appendingPathComponent("scripts/github-release.sh")
        p.arguments = [pkg, version]
        p.environment = [
            "PATH": temp.appendingPathComponent("bin").path + ":/usr/bin:/bin",
            "STUB_LOG": log.path, "STUB_PRIVATE": isPrivate ? "true" : "false", "STUB_PUSHED": pushed ? "1" : "0",
            "STUB_EXISTS": exists ? "1" : "0", "STUB_RELEASES": releases.joined(separator: " "),
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let calls = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        return (p.terminationStatus, calls)
    }

    func testCreatesTheReleaseAtHeadAndDeletesOlderOnes() throws {
        let path = try pkg("Notepad++-1.0.0.pkg")
        let r = try release(path, "1.0.0", releases: ["v0.1.15", "v1.0.0", "v0.1.14"])
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.calls.contains { $0.hasPrefix("gh release create v1.0.0 \(path) --target abc123 --title Notepad++ 1.0.0") }, "\(r.calls)")
        XCTAssertTrue(r.calls.contains("gh release delete v0.1.15 --yes"))
        XCTAssertTrue(r.calls.contains("gh release delete v0.1.14 --yes"))
        XCTAssertFalse(r.calls.contains { $0.hasPrefix("gh release delete v1.0.0") }, "the new release stays")
        XCTAssertFalse(r.calls.contains { $0.contains("--cleanup-tag") }, "older tags stay")
    }

    func testAnExistingReleaseGetsTheInstallerReplaced() throws {
        let path = try pkg("MacPad++-1.0.1.pkg")
        let r = try release(path, "1.0.1", exists: true, releases: ["v1.0.1"])
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.calls.contains("gh release upload v1.0.1 \(path) --clobber"))
        XCTAssertFalse(r.calls.contains { $0.hasPrefix("gh release create") })
        XCTAssertFalse(r.calls.contains { $0.hasPrefix("gh release delete") })
    }

    func testAPersonalBuildIsNeverPublishedToAPublicRepository() throws {
        let r = try release(try pkg("Notepad++-1.0.0.pkg"), "1.0.0", isPrivate: false)
        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(r.calls.contains { $0.hasPrefix("gh release") }, "\(r.calls)")
    }

    func testAMacPadBuildMayGoToAPublicRepository() throws {
        let r = try release(try pkg("MacPad++-1.0.0.pkg"), "1.0.0", isPrivate: false)
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.calls.contains { $0.hasPrefix("gh release create v1.0.0") })
    }

    func testAnUnpushedCommitIsNotReleased() throws {
        let r = try release(try pkg("MacPad++-1.0.0.pkg"), "1.0.0", pushed: false)
        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(r.calls.contains { $0.hasPrefix("gh release") })
    }

    func testRejectsAMissingOrMisnamedInstaller() throws {
        XCTAssertNotEqual(try release(temp.appendingPathComponent("none-1.0.0.pkg").path, "1.0.0").status, 0)
        let r = try release(try pkg("installer.pkg"), "1.0.0")
        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(r.calls.contains { $0.hasPrefix("gh release") })
    }
}

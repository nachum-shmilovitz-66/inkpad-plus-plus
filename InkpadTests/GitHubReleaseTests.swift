import XCTest

/// MAC-68: deploy patch publishes the installer as GitHub release v<version> and keeps only that
/// release. Runs scripts/github-release.sh with stub `gh`, `git`, `xar` and `pkgutil` — never the
/// real ones. MAC-75: only a signed Inkpad++ installer is ever published.
final class GitHubReleaseTests: XCTestCase {
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private var temp: URL!
    private var log: URL { temp.appendingPathComponent("calls.log") }
    private var notes: URL { temp.appendingPathComponent("notes.md") }

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
              "release list")
                case "$*" in
                  *"--limit 1 "*) for t in $STUB_RELEASES; do echo "$t"; break; done ;;
                  *) for t in $STUB_RELEASES; do echo "$t"; done ;;
                esac ;;
              "release create")
                while [ $# -gt 0 ]; do
                  [ "$1" = "--notes-file" ] && cat "$2" > "$STUB_NOTES"
                  shift
                done ;;
            esac
            exit 0
            """)
        try stub(bin.appendingPathComponent("xar"), """
            #!/bin/sh
            # xar -x -f <pkg> -C <dir> Distribution
            printf '<installer-gui-script><title>%s</title><pkg-ref id="app.inkpad.Inkpad" version="%s">#c.pkg</pkg-ref></installer-gui-script>' \
              "$STUB_TITLE" "$STUB_PKG_VERSION" > "$5/Distribution"
            """)
        try stub(bin.appendingPathComponent("pkgutil"), """
            #!/bin/sh
            echo "   Status: signed by a developer certificate issued by Apple for distribution"
            echo "    1. Developer ID Installer: Someone ($STUB_TEAM)"
            """)
        try stub(bin.appendingPathComponent("git"), """
            #!/bin/sh
            echo "git $*" >> "$STUB_LOG"
            case "$1" in
              rev-parse) if [ "$2" = "--abbrev-ref" ]; then echo main; else echo abc123; fi ;;
              merge-base) [ "$STUB_PUSHED" = 1 ] || exit 1 ;;
              log) printf -- '- MAC-2 — Second change\n- Release 0.9.9\n- MAC-1 — First change\n' ;;
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
                         exists: Bool = false, releases: [String] = [], title: String = "Inkpad++",
                         packageVersion: String? = nil, team: String = "96Y4LX7FVB") throws -> (status: Int32, calls: [String]) {
        let p = Process()
        p.executableURL = repo.appendingPathComponent("scripts/github-release.sh")
        p.arguments = [pkg, version]
        p.environment = [
            "PATH": temp.appendingPathComponent("bin").path + ":/usr/bin:/bin",
            "STUB_LOG": log.path, "STUB_PRIVATE": isPrivate ? "true" : "false", "STUB_PUSHED": pushed ? "1" : "0",
            "STUB_EXISTS": exists ? "1" : "0", "STUB_RELEASES": releases.joined(separator: " "),
            "STUB_NOTES": notes.path, "STUB_TITLE": title, "STUB_PKG_VERSION": packageVersion ?? version, "STUB_TEAM": team,
            "TMPDIR": temp.path + "/",
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let calls = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        return (p.terminationStatus, calls)
    }

    func testCreatesTheReleaseAtHeadAndDeletesOlderOnes() throws {
        let path = try pkg("Inkpad++-1.0.0.pkg")
        let r = try release(path, "1.0.0", releases: ["v0.1.15", "v1.0.0", "v0.1.14"])
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.calls.contains { $0.hasPrefix("gh release create v1.0.0 \(path) --target abc123 --title Inkpad++ 1.0.0 --notes-file") }, "\(r.calls)")
        XCTAssertTrue(r.calls.contains("gh release delete v0.1.15 --yes"))
        XCTAssertTrue(r.calls.contains("gh release delete v0.1.14 --yes"))
        XCTAssertFalse(r.calls.contains { $0.hasPrefix("gh release delete v1.0.0") }, "the new release stays")
        XCTAssertFalse(r.calls.contains { $0.contains("--cleanup-tag") }, "older tags stay")
    }

    /// MAC-75: the notes (shown by Check for Updates) list the commits since the previous release.
    func testNotesListTheCommitsSinceThePreviousRelease() throws {
        let r = try release(try pkg("Inkpad++-1.0.1.pkg"), "1.0.1", releases: ["v1.0.0"])
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.calls.contains("git log --no-merges --format=- %s refs/tags/v1.0.0..abc123"), "\(r.calls)")
        let text = try String(contentsOf: notes, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("Inkpad++ 1.0.1 — installer for macOS (Apple Silicon)."), text)
        XCTAssertTrue(text.contains("Changes since 1.0.0:\n- MAC-2 — Second change\n- MAC-1 — First change\n"), text)
        XCTAssertFalse(text.contains("Release 0.9.9"), "release commits are left out")
        XCTAssertTrue(text.contains("Commit abc123."))
    }

    func testFirstReleaseHasNotesWithoutChanges() throws {
        XCTAssertEqual(try release(try pkg("Inkpad++-1.0.0.pkg"), "1.0.0").status, 0)
        let text = try String(contentsOf: notes, encoding: .utf8)
        XCTAssertFalse(text.contains("Changes since"))
    }

    func testAnExistingReleaseGetsTheInstallerReplaced() throws {
        let path = try pkg("Inkpad++-1.0.1.pkg")
        let r = try release(path, "1.0.1", exists: true, releases: ["v1.0.1"])
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.calls.contains("gh release upload v1.0.1 \(path) --clobber"))
        XCTAssertFalse(r.calls.contains { $0.hasPrefix("gh release create") })
        XCTAssertFalse(r.calls.contains { $0.hasPrefix("gh release delete") })
    }

    /// MAC-75: the repository is public and Check for Updates installs only Inkpad++, so a personal
    /// build is never released — not even to a private repository.
    func testAPersonalBuildIsNeverPublished() throws {
        for isPrivate in [false, true] {
            let r = try release(try pkg("upstream-1.0.0.pkg"), "1.0.0", isPrivate: isPrivate)
            XCTAssertNotEqual(r.status, 0)
            XCTAssertFalse(r.calls.contains { $0.hasPrefix("gh release") }, "\(r.calls)")
        }
    }

    func testARenamedPersonalBuildIsRefusedByItsTitle() throws {
        let r = try release(try pkg("Inkpad++-1.0.0.pkg"), "1.0.0", title: "upstream")
        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(r.calls.contains { $0.hasPrefix("gh release") }, "\(r.calls)")
    }

    func testAPackageOfAnotherVersionIsRefused() throws {
        let r = try release(try pkg("Inkpad++-1.0.1.pkg"), "1.0.1", packageVersion: "1.0.0")
        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(r.calls.contains { $0.hasPrefix("gh release") })
    }

    func testAPackageSignedByAnotherTeamIsRefused() throws {
        let r = try release(try pkg("Inkpad++-1.0.0.pkg"), "1.0.0", team: "ABCDE12345")
        XCTAssertNotEqual(r.status, 0)
        XCTAssertFalse(r.calls.contains { $0.hasPrefix("gh release") })
    }

    func testAInkpadBuildMayGoToAPublicRepository() throws {
        let r = try release(try pkg("Inkpad++-1.0.0.pkg"), "1.0.0", isPrivate: false)
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.calls.contains { $0.hasPrefix("gh release create v1.0.0") })
    }

    func testAnUnpushedCommitIsNotReleased() throws {
        let r = try release(try pkg("Inkpad++-1.0.0.pkg"), "1.0.0", pushed: false)
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

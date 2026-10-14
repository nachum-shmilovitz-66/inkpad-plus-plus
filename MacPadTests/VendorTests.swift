import XCTest
@testable import MacPad

/// MAC-64: the third-party code is the reviewed commit, and what is not ported is not reachable.
final class VendorTests: XCTestCase {
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    private func fetchVendor(_ environment: [String: String] = [:]) throws -> (status: Int32, error: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [repo.appendingPathComponent("scripts/fetch-vendor.sh").path]
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(environment) { $1 }
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testTheVendorTreeIsThePinnedCommit() throws {
        let lock = try String(contentsOf: repo.appendingPathComponent("scripts/deps/vendor.lock"), encoding: .utf8)
        XCTAssertEqual(lock.trimmingCharacters(in: .whitespacesAndNewlines), "dd40fe45598791e9aa38f3aeb200e10fb3d6338a")
        let result = try fetchVendor()
        XCTAssertEqual(result.status, 0, "the checked-out vendor tree passes: \(result.error)")
    }

    func testAnyOtherCommitStopsTheBuild() throws {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("vendor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        for args in [["init", "-q"], ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "x"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", other.path] + args
            try p.run()
            p.waitUntilExit()
        }
        let result = try fetchVendor(["MACPAD_VENDOR_DIR": other.path])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.error.contains("expected dd40fe45"), result.error)
    }

    func testTheUserDefinedLanguageLexerIsNotOffered() throws {
        let udf = try XCTUnwrap(languageTable.first { $0.name == "udf" })
        XCTAssertEqual(udf.lexer, "user")
        XCTAssertEqual(EditorStyler.lexerName(for: udf), "null")
        let python = try XCTUnwrap(LanguageCatalog.shared.language(named: "python"))
        XCTAssertEqual(EditorStyler.lexerName(for: python), "python")
    }
}

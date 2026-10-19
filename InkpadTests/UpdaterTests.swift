import CryptoKit
import XCTest
@testable import Inkpad

/// MAC-75: Check for Updates — versions, GitHub's release JSON, the offer, the installer checks.
/// The network and pkgutil / xar are stubs: nothing here reaches GitHub or runs a real package.
final class UpdaterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var temp: URL!

    override func setUpWithError() throws {
        suite = "app.inkpad.Inkpad.tests.updater.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("UpdaterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)  // a throwaway suite, never the app's own
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - Fixtures

    private static let downloadBase = "https://github.com/nachum-shmilovitz-66/inkpad-plus-plus/releases/download"

    private static func asset(_ name: String, size: Int = 5, url: String? = nil, digest: String? = nil) -> GitHubRelease.Asset {
        GitHubRelease.Asset(name: name, size: size,
                            browserDownloadURL: URL(string: url ?? "\(downloadBase)/v1.2.0/\(name.replacingOccurrences(of: "+", with: "%2B"))")!,
                            digest: digest)
    }

    private static func release(_ tag: String, assets: [GitHubRelease.Asset]? = nil, body: String? = "Notes",
                                draft: Bool? = false, prerelease: Bool? = false, page: String? = nil) -> GitHubRelease {
        GitHubRelease(tagName: tag, name: "Inkpad++ \(tag)", body: body,
                      htmlURL: URL(string: page ?? "https://github.com/nachum-shmilovitz-66/inkpad-plus-plus/releases/tag/\(tag)"),
                      draft: draft, prerelease: prerelease,
                      assets: assets ?? [asset("Inkpad++-\(SemanticVersion(tag)!).pkg")])
    }

    private static func json(tag: String, assetName: String, size: Int, digest: String?) -> Data {
        let encodedName = assetName.replacingOccurrences(of: "+", with: "%2B")
        let digestField = digest.map { #", "digest": "\#($0)""# } ?? ""
        return Data("""
        {"tag_name": "\(tag)", "name": "Inkpad++ \(tag)", "body": "- MAC-75 — Check for Updates",
         "html_url": "https://github.com/nachum-shmilovitz-66/inkpad-plus-plus/releases/tag/\(tag)",
         "draft": false, "prerelease": false, "id": 1, "author": {"login": "x"},
         "assets": [{"name": "\(assetName)", "size": \(size), "content_type": "application/octet-stream",
                     "browser_download_url": "\(downloadBase)/\(tag)/\(encodedName)"\(digestField)}]}
        """.utf8)
    }

    static let trustedSignature = """
    Package "Inkpad++-1.2.0.pkg":
       Status: signed by a developer certificate issued by Apple for distribution
       Signed with a trusted timestamp on: 2026-10-19 08:44:39 +0000
       Certificate Chain:
        1. Developer ID Installer: Nachum Shmilovitz (96Y4LX7FVB)
           Expires: 2027-02-01 22:12:15 +0000
           SHA256 Fingerprint:
               25 FC 1E 5B 54 FE 1A A0 E3 B3 9E A8 D1 E1 82 55 F4 8D EC B3 CF BE
               32 F6 C0 DB AC 3E 30 7E 3D DE
           ------------------------------------------------------------------------
        2. Developer ID Certification Authority
           Expires: 2027-02-01 22:12:15 +0000
           SHA256 Fingerprint:
               7A FC 9D 01 A6 2F 03 A2 DE 96 37 93 6D 4A FE 68 09 0D 2D E1 8D 03
           ------------------------------------------------------------------------
        3. Apple Root CA
           Expires: 2035-02-09 21:40:36 +0000
           SHA256 Fingerprint:
               B0 B1 73 0E CB C7 FF 45 05 14 2C 49 F1 29 5E 6E DA 6B CA ED 7E 2C

    """

    static func distribution(title: String = "Inkpad++", version: String = "1.2.0", bundleVersion: String? = nil,
                             id: String = "app.inkpad.Inkpad", path: String = "Inkpad++.app") -> Data {
        Data("""
        <?xml version="1.0" encoding="utf-8" standalone="yes"?>
        <installer-gui-script minSpecVersion="1">
            <title>\(title)</title>
            <pkg-ref id="\(id)">
                <must-close><app id="app.inkpad.Inkpad"/></must-close>
                <bundle-version>
                    <bundle CFBundleShortVersionString="\(bundleVersion ?? version)" CFBundleVersion="1" id="\(id)" path="\(path)"/>
                    <bundle CFBundleShortVersionString="5.6.6" CFBundleVersion="5.6.6" id="org.scintilla.Scintilla" path="Inkpad++.app/Contents/Frameworks/Scintilla.framework"/>
                </bundle-version>
            </pkg-ref>
            <pkg-ref id="\(id)" version="\(version)" onConclusion="none" installKBytes="17506" updateKBytes="0">#Inkpad++-component.pkg</pkg-ref>
        </installer-gui-script>
        """.utf8)
    }

    final class StubNetwork: UpdateNetworking {
        var response: (Data, Int) = (Data(), 200)
        var error: Error?
        var payload = Data("hello".utf8)
        var downloadStatus = 200
        private(set) var requested: [URL] = []

        func data(from url: URL) async throws -> (Data, Int) {
            requested.append(url)
            if let error { throw error }
            return response
        }

        func download(from url: URL, to destination: URL) async throws -> Int {
            requested.append(url)
            if let error { throw error }
            try payload.write(to: destination)
            return downloadStatus
        }
    }

    final class StubRunner: CommandRunning {
        var signature: (Int32, String) = (0, UpdaterTests.trustedSignature)
        var distribution: Data? = UpdaterTests.distribution()
        private(set) var calls: [[String]] = []

        func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
            calls.append([executable] + arguments)
            if executable.hasSuffix("pkgutil") { return signature }
            if executable.hasSuffix("xar"), let index = arguments.firstIndex(of: "-C") {
                guard let distribution else { return (1, "no Distribution") }
                try distribution.write(to: URL(fileURLWithPath: arguments[index + 1]).appendingPathComponent("Distribution"))
                return (0, "")
            }
            return (127, "unexpected")
        }
    }

    private func updater(_ network: StubNetwork, _ runner: StubRunner = StubRunner(), version: String = "1.1.2") -> Updater {
        Updater(network: network, runner: runner, defaults: defaults, currentVersion: version, temporaryDirectory: temp)
    }

    private func update(size: Int = 5, digest: String? = nil, asset: GitHubRelease.Asset?? = .none) -> AvailableUpdate {
        AvailableUpdate(version: SemanticVersion(1, 2, 0), notes: "", pageURL: UpdateSource.releasesPage,
                        asset: asset ?? Self.asset("Inkpad++-1.2.0.pkg", size: size, digest: digest))
    }

    // MARK: - SemanticVersion

    func testParsesVersionsAndTags() {
        XCTAssertEqual(SemanticVersion("1.2.3"), SemanticVersion(1, 2, 3))
        XCTAssertEqual(SemanticVersion("v1.1.2"), SemanticVersion(1, 1, 2))
        XCTAssertEqual(SemanticVersion("V2.0.0"), SemanticVersion(2, 0, 0))
        XCTAssertEqual(SemanticVersion(" 1.1.0\n"), SemanticVersion(1, 1, 0))
        XCTAssertEqual(SemanticVersion("1"), SemanticVersion(1, 0, 0))
        XCTAssertEqual(SemanticVersion("1.2"), SemanticVersion(1, 2, 0))
        XCTAssertEqual(SemanticVersion("1.2.3-beta.1"), SemanticVersion(1, 2, 3, prerelease: ["beta", "1"]))
        XCTAssertEqual(SemanticVersion("1.2.3+build.7"), SemanticVersion(1, 2, 3), "build metadata is ignored")
        XCTAssertEqual(SemanticVersion("1.2.3-rc-1+sha"), SemanticVersion(1, 2, 3, prerelease: ["rc-1"]))
    }

    func testRejectsMalformedVersions() {
        for text in ["", "v", "1.", ".1", "1..2", "1.2.3.4", "a.b.c", "1.2.x", "1.2.3-", "1.2.3-a..b", "1.2.3-ä",
                     "-1.2.3", "1.-2.3", "١.٢.٣", "99999999999999999999.0.0", "vv1.0.0"] {
            XCTAssertNil(SemanticVersion(text), text)
        }
    }

    func testDescription() {
        XCTAssertEqual(SemanticVersion("v1.2")?.description, "1.2.0")
        XCTAssertEqual(SemanticVersion("1.2.3-beta.2+x")?.description, "1.2.3-beta.2")
    }

    func testOrdersByNumbersNotText() {
        XCTAssertLessThan(SemanticVersion("1.1.9")!, SemanticVersion("1.1.10")!)
        XCTAssertLessThan(SemanticVersion("1.9.0")!, SemanticVersion("1.10.0")!)
        XCTAssertLessThan(SemanticVersion("1.99.99")!, SemanticVersion("2.0.0")!)
        XCTAssertLessThan(SemanticVersion("0.1.14")!, SemanticVersion("1.0.0")!)
        XCTAssertFalse(SemanticVersion("1.1.2")! < SemanticVersion("v1.1.2")!)
        XCTAssertEqual(SemanticVersion("1.0")!, SemanticVersion("1.0.0")!)
    }

    func testPrereleasePrecedenceFollowsSemver() {
        // semver.org §11's own example chain.
        let chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                     "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"].map { SemanticVersion($0)! }
        for (a, b) in zip(chain, chain.dropFirst()) {
            XCTAssertLessThan(a, b, "\(a) < \(b)")
            XCTAssertFalse(b < a, "\(b) !< \(a)")
        }
        XCTAssertLessThan(SemanticVersion("1.0.0")!, SemanticVersion("1.0.1-alpha")!)
    }

    // MARK: - Release JSON

    func testDecodesGitHubsLatestReleaseResponse() throws {
        let release = try GitHubRelease.decode(Self.json(tag: "v1.2.0", assetName: "Inkpad++-1.2.0.pkg", size: 5571266,
                                                         digest: "sha256:042bb4a9"))
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.body, "- MAC-75 — Check for Updates")
        XCTAssertEqual(release.draft, false)
        XCTAssertEqual(release.htmlURL?.absoluteString, "https://github.com/nachum-shmilovitz-66/inkpad-plus-plus/releases/tag/v1.2.0")
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets[0].name, "Inkpad++-1.2.0.pkg")
        XCTAssertEqual(release.assets[0].size, 5571266)
        XCTAssertEqual(release.assets[0].digest, "sha256:042bb4a9")
        XCTAssertEqual(release.assets[0].browserDownloadURL.lastPathComponent, "Inkpad++-1.2.0.pkg")
    }

    func testDecodesMinimalRelease() throws {
        let release = try GitHubRelease.decode(Data(#"{"tag_name": "v2.0.0", "assets": []}"#.utf8))
        XCTAssertEqual(release.tagName, "v2.0.0")
        XCTAssertNil(release.body)
        XCTAssertNil(release.draft)
        XCTAssertTrue(release.assets.isEmpty)
    }

    func testRejectsMalformedJSON() {
        XCTAssertThrowsError(try GitHubRelease.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try GitHubRelease.decode(Data(#"{"message": "Not Found"}"#.utf8)))
        XCTAssertThrowsError(try GitHubRelease.decode(Data(#"{"tag_name": 3, "assets": []}"#.utf8)))
    }

    // MARK: - Evaluation

    func testNewerReleaseIsOffered() throws {
        let result = try UpdateEvaluator.evaluate(Self.release("v1.2.0"), currentVersion: "1.1.2", skippedVersion: nil)
        guard case .available(let update) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(update.versionString, "1.2.0")
        XCTAssertEqual(update.notes, "Notes")
        XCTAssertEqual(update.asset?.name, "Inkpad++-1.2.0.pkg")
        XCTAssertEqual(update.pageURL.absoluteString, "https://github.com/nachum-shmilovitz-66/inkpad-plus-plus/releases/tag/v1.2.0")
    }

    func testSameOrOlderReleaseIsUpToDate() throws {
        XCTAssertEqual(try UpdateEvaluator.evaluate(Self.release("v1.1.2"), currentVersion: "1.1.2", skippedVersion: nil),
                       .upToDate(current: "1.1.2"))
        XCTAssertEqual(try UpdateEvaluator.evaluate(Self.release("v1.1.1"), currentVersion: "1.1.2", skippedVersion: nil),
                       .upToDate(current: "1.1.2"))
        XCTAssertEqual(try UpdateEvaluator.evaluate(Self.release("v1.1.10"), currentVersion: "1.2.0", skippedVersion: nil),
                       .upToDate(current: "1.2.0"))
    }

    func testDraftsAndPrereleasesAreNeverOffered() throws {
        XCTAssertEqual(try UpdateEvaluator.evaluate(Self.release("v9.0.0", draft: true), currentVersion: "1.1.2", skippedVersion: nil),
                       .upToDate(current: "1.1.2"))
        XCTAssertEqual(try UpdateEvaluator.evaluate(Self.release("v9.0.0", prerelease: true), currentVersion: "1.1.2", skippedVersion: nil),
                       .upToDate(current: "1.1.2"))
        XCTAssertThrowsError(try UpdateEvaluator.evaluate(Self.release("v9.0.0-beta", assets: []), currentVersion: "1.1.2", skippedVersion: nil))
    }

    func testSkippedVersionIsReportedAsSkipped() throws {
        let result = try UpdateEvaluator.evaluate(Self.release("v1.2.0"), currentVersion: "1.1.2", skippedVersion: "1.2.0")
        guard case .skipped(let update) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(update.versionString, "1.2.0")
        // A newer release than the skipped one is offered again.
        let newer = try UpdateEvaluator.evaluate(Self.release("v1.3.0", assets: []), currentVersion: "1.1.2", skippedVersion: "1.2.0")
        guard case .available = newer else { return XCTFail("\(newer)") }
    }

    func testBadVersionsThrow() {
        XCTAssertThrowsError(try UpdateEvaluator.evaluate(Self.release("latest", assets: []), currentVersion: "1.1.2", skippedVersion: nil)) {
            XCTAssertEqual($0 as? UpdateError, .badReleaseVersion("latest"))
        }
        XCTAssertThrowsError(try UpdateEvaluator.evaluate(Self.release("v1.2.0"), currentVersion: "dev", skippedVersion: nil)) {
            XCTAssertEqual($0 as? UpdateError, .currentVersionUnknown("dev"))
        }
    }

    func testPageOutsideTheRepositoryFallsBackToReleasesPage() throws {
        let result = try UpdateEvaluator.evaluate(Self.release("v1.2.0", page: "https://evil.example/releases/x"),
                                                  currentVersion: "1.1.2", skippedVersion: nil)
        guard case .available(let update) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(update.pageURL, UpdateSource.releasesPage)
    }

    // MARK: - Asset selection

    func testPicksTheInkpadInstallerOnly() {
        let version = SemanticVersion(1, 2, 0)
        let release = Self.release("v1.2.0", assets: [Self.asset("upstream-1.2.0.pkg"), Self.asset("Inkpad++-1.2.0.dmg"),
                                                      Self.asset("Inkpad++-1.2.0.pkg"), Self.asset("Inkpad++-1.1.0.pkg")])
        XCTAssertEqual(UpdateEvaluator.installerAsset(in: release, version: version)?.name, "Inkpad++-1.2.0.pkg")
    }

    func testPersonalBuildAssetIsNeverPicked() {
        let release = Self.release("v1.2.0", assets: [Self.asset("upstream-1.2.0.pkg")])
        XCTAssertNil(UpdateEvaluator.installerAsset(in: release, version: SemanticVersion(1, 2, 0)))
    }

    func testAssetFromElsewhereIsRefused() {
        let version = SemanticVersion(1, 2, 0)
        for url in ["http://github.com/nachum-shmilovitz-66/inkpad-plus-plus/releases/download/v1.2.0/Inkpad%2B%2B-1.2.0.pkg",
                    "https://evil.example/nachum-shmilovitz-66/inkpad-plus-plus/releases/download/v1.2.0/Inkpad%2B%2B-1.2.0.pkg",
                    "https://github.com/someone-else/inkpad-plus-plus/releases/download/v1.2.0/Inkpad%2B%2B-1.2.0.pkg",
                    "https://github.com:8443/nachum-shmilovitz-66/inkpad-plus-plus/releases/download/v1.2.0/Inkpad%2B%2B-1.2.0.pkg",
                    "https://user@github.com/nachum-shmilovitz-66/inkpad-plus-plus/releases/download/v1.2.0/Inkpad%2B%2B-1.2.0.pkg",
                    "https://github.com/nachum-shmilovitz-66/inkpad-plus-plus/archive/Inkpad%2B%2B-1.2.0.pkg"] {
            let release = Self.release("v1.2.0", assets: [Self.asset("Inkpad++-1.2.0.pkg", url: url)])
            XCTAssertNil(UpdateEvaluator.installerAsset(in: release, version: version), url)
        }
    }

    func testAssetWithImplausibleSizeIsRefused() {
        let version = SemanticVersion(1, 2, 0)
        for size in [0, -1, UpdateSource.maximumInstallerSize + 1] {
            XCTAssertNil(UpdateEvaluator.installerAsset(in: Self.release("v1.2.0", assets: [Self.asset("Inkpad++-1.2.0.pkg", size: size)]),
                                                        version: version), "\(size)")
        }
    }

    func testReleaseWithoutInstallerIsStillOffered() throws {
        let result = try UpdateEvaluator.evaluate(Self.release("v1.2.0", assets: []), currentVersion: "1.1.2", skippedVersion: nil)
        guard case .available(let update) = result else { return XCTFail("\(result)") }
        XCTAssertNil(update.asset)
    }

    // MARK: - Schedule and policy

    func testScheduleIsDailyAndDueWithoutHistory() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: nil, now: now))
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-3600), now: now))
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-UpdateSchedule.interval + 1), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-UpdateSchedule.interval), now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now), "clock set back")
    }

    func testOnlyThePublicNameInstalls() {
        XCTAssertEqual(UpdateInstallPolicy.forApp(named: "Inkpad++"), .install)
        XCTAssertEqual(UpdateInstallPolicy.forApp(named: "upstream"), .notifyOnly)
        XCTAssertEqual(UpdateInstallPolicy.forApp(named: "Inkpad++ Debug"), .notifyOnly)
    }

    func testAutomaticChecksNeverRunInTests() {
        XCTAssertFalse(UpdateController.automaticChecksAllowed)
    }

    func testAutomaticCheckIsOnByDefaultAndSurvivesOldSettings() throws {
        XCTAssertTrue(Preferences().checkForUpdatesAutomatically)
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"maxRecentFiles": 5}"#.utf8))
        XCTAssertTrue(old.checkForUpdatesAutomatically)
        var off = Preferences()
        off.checkForUpdatesAutomatically = false
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(decoded.checkForUpdatesAutomatically)
    }

    // MARK: - Signature decision

    func testParsesPkgutilOutput() {
        let report = PackageVerifier.parseSignature(Self.trustedSignature)
        XCTAssertEqual(report.status, PackageVerifier.developerIDStatus)
        XCTAssertEqual(report.certificates, ["Developer ID Installer: Nachum Shmilovitz (96Y4LX7FVB)",
                                             "Developer ID Certification Authority", "Apple Root CA"])
    }

    func testTrustsTheTeamsDeveloperIDInstaller() {
        XCTAssertNoThrow(try PackageVerifier.checkSignature(output: Self.trustedSignature, exitStatus: 0))
        let notarized = Self.trustedSignature.replacingOccurrences(
            of: "   Signed with", with: "   Notarization: trusted by the Apple notary service\n   Signed with")
        XCTAssertNoThrow(try PackageVerifier.checkSignature(output: notarized, exitStatus: 0))
    }

    func testRefusesEveryOtherSignature() {
        let cases: [(String, Int32, String)] = [
            (Self.trustedSignature, 1, "pkgutil failed"),
            ("Package \"x.pkg\":\n   Status: no signature\n", 1, "unsigned"),
            ("Package \"x.pkg\":\n   Status: no signature\n", 0, "unsigned, exit 0"),
            (Self.trustedSignature.replacingOccurrences(of: "96Y4LX7FVB", with: "ABCDE12345"), 0, "another team"),
            (Self.trustedSignature.replacingOccurrences(of: "Developer ID Installer", with: "Developer ID Application"), 0, "application certificate"),
            (Self.trustedSignature.replacingOccurrences(of: "Developer ID Installer:", with: "3rd Party Mac Developer Installer:"), 0, "Mac App Store certificate"),
            (Self.trustedSignature.replacingOccurrences(of: "issued by Apple for distribution", with: "issued by Apple (Development)"), 0, "development"),
            (Self.trustedSignature.replacingOccurrences(of: "Status: signed by a developer certificate issued by Apple for distribution",
                                                        with: "Status: signed by untrusted certificate"), 0, "untrusted"),
            (Self.trustedSignature.replacingOccurrences(of: "3. Apple Root CA", with: "3. Evil Root CA"), 0, "another root"),
            (Self.trustedSignature.replacingOccurrences(of: "2. Developer ID Certification Authority", with: "2. Some CA"), 0, "another intermediate"),
            (Self.trustedSignature + "    4. Extra Certificate\n", 0, "longer chain"),
            ("", 0, "no output"),
        ]
        for (output, status, label) in cases {
            XCTAssertThrowsError(try PackageVerifier.checkSignature(output: output, exitStatus: status), label) {
                guard case .untrustedSignature = $0 as? UpdateError else { return XCTFail("\(label): \($0)") }
            }
        }
    }

    func testSHA256KnownAnswer() throws {
        let url = temp.appendingPathComponent("hello")
        try Data("hello".utf8).write(to: url)
        XCTAssertEqual(try PackageVerifier.sha256Hex(of: url), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    // MARK: - Distribution check

    func testAcceptsTheMatchingPackage() {
        XCTAssertNoThrow(try PackageVerifier.checkDistribution(Self.distribution(), version: "1.2.0"))
    }

    func testRefusesAnyOtherPackage() {
        let cases: [(Data, String)] = [
            (Self.distribution(version: "1.1.9"), "older component version"),
            (Self.distribution(bundleVersion: "1.1.9"), "older app version"),
            (Self.distribution(title: "upstream"), "personal-build name"),
            (Self.distribution(id: "com.example.other"), "another package"),
            (Self.distribution(path: "Other.app"), "another app"),
            (Data("<installer-script/>".utf8), "not a distribution"),
            (Data("<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY a \"b\">]><installer-gui-script/>".utf8), "entities"),
            (Data("garbage".utf8), "not XML"),
        ]
        for (data, label) in cases {
            XCTAssertThrowsError(try PackageVerifier.checkDistribution(data, version: "1.2.0"), label) {
                guard case .packageMismatch = $0 as? UpdateError else { return XCTFail("\(label): \($0)") }
            }
        }
    }

    // MARK: - The updater with injected network and tools

    func testCheckReadsGitHubAndRecordsTheTime() async throws {
        let network = StubNetwork()
        network.response = (Self.json(tag: "v1.2.0", assetName: "Inkpad++-1.2.0.pkg", size: 5, digest: nil), 200)
        let updater = updater(network)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(updater.isAutomaticCheckDue(now: now))
        let result = try await updater.check(now: now)
        guard case .available(let update) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(update.asset?.name, "Inkpad++-1.2.0.pkg")
        XCTAssertEqual(network.requested, [UpdateSource.latestReleaseAPI])
        XCTAssertEqual(updater.lastCheck, now)
        XCTAssertFalse(updater.isAutomaticCheckDue(now: now.addingTimeInterval(60)))
    }

    func testTheEndpointIsThePublicRepositorysLatestRelease() {
        XCTAssertEqual(UpdateSource.latestReleaseAPI.absoluteString,
                       "https://api.github.com/repos/nachum-shmilovitz-66/inkpad-plus-plus/releases/latest")
    }

    func testSkipThisVersionIsRemembered() async throws {
        let network = StubNetwork()
        network.response = (Self.json(tag: "v1.2.0", assetName: "Inkpad++-1.2.0.pkg", size: 5, digest: nil), 200)
        let updater = updater(network)
        guard case .available(let update) = try await updater.check() else { return XCTFail() }
        updater.skip(update)
        XCTAssertEqual(defaults.string(forKey: Updater.skippedVersionKey), "1.2.0")
        guard case .skipped = try await updater.check() else { return XCTFail() }
    }

    func testCheckErrors() async {
        let network = StubNetwork()
        let updater = updater(network)
        for (response, expected) in [((Data(), 404), UpdateError.noPublishedRelease), ((Data(), 403), .http(403)),
                                     ((Data("{}".utf8), 200), .malformedRelease),
                                     ((Data(count: 2 * 1024 * 1024), 200), .malformedRelease)] {
            network.response = response
            do { _ = try await updater.check(); XCTFail("\(expected)") } catch { XCTAssertEqual(error as? UpdateError, expected) }
        }
        network.error = URLError(.notConnectedToInternet)
        do { _ = try await updater.check(); XCTFail() } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
    }

    func testDownloadsAndVerifiesIntoAPrivateFolder() async throws {
        let network = StubNetwork()
        let runner = StubRunner()
        let digest = "sha256:" + SHA256.hash(data: network.payload).map { String(format: "%02x", $0) }.joined()
        let package = try await updater(network, runner).downloadAndVerify(update(size: network.payload.count, digest: digest))
        XCTAssertEqual(package.lastPathComponent, "Inkpad++-1.2.0.pkg")
        XCTAssertEqual(try Data(contentsOf: package), network.payload)
        let folder = package.deletingLastPathComponent()
        XCTAssertTrue(folder.lastPathComponent.hasPrefix(Updater.downloadFolderPrefix))
        XCTAssertEqual(folder.deletingLastPathComponent().standardizedFileURL, temp.standardizedFileURL)
        let mode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
        XCTAssertEqual(runner.calls.map(\.first), ["/usr/sbin/pkgutil", "/usr/bin/xar"])
        XCTAssertEqual(runner.calls.first, ["/usr/sbin/pkgutil", "--check-signature", package.path])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Inkpad++-1.2.0.pkg"], "extracted files are removed")
        XCTAssertEqual(network.requested.last, update().asset?.browserDownloadURL)
    }

    private func assertRefused(_ network: StubNetwork, runner: StubRunner = StubRunner(), _ update: AvailableUpdate,
                               file: StaticString = #filePath, line: UInt = #line, _ check: (UpdateError) -> Bool) async {
        do {
            _ = try await updater(network, runner).downloadAndVerify(update)
            XCTFail("accepted", file: file, line: line)
        } catch {
            XCTAssertTrue((error as? UpdateError).map(check) ?? false, "\(error)", file: file, line: line)
        }
        // Nothing is left behind for Installer to open.
        let left = (try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? []
        XCTAssertEqual(left, [], file: file, line: line)
    }

    func testRefusesAWrongSize() async {
        await assertRefused(StubNetwork(), update(size: 6)) { if case .sizeMismatch(6, 5) = $0 { true } else { false } }
    }

    func testRefusesAWrongDigest() async {
        await assertRefused(StubNetwork(), update(digest: "sha256:" + String(repeating: "0", count: 64))) { $0 == .digestMismatch }
    }

    func testRefusesAnUntrustedSignature() async {
        let runner = StubRunner()
        runner.signature = (0, Self.trustedSignature.replacingOccurrences(of: "96Y4LX7FVB", with: "ABCDE12345"))
        await assertRefused(StubNetwork(), runner: runner, update()) { if case .untrustedSignature = $0 { true } else { false } }
        XCTAssertEqual(runner.calls.count, 1, "contents are never read from an untrusted package")
    }

    func testRefusesAPackageForAnotherVersion() async {
        let runner = StubRunner()
        runner.distribution = Self.distribution(version: "1.1.9")
        await assertRefused(StubNetwork(), runner: runner, update()) { if case .packageMismatch = $0 { true } else { false } }
    }

    func testRefusesUnreadableContents() async {
        let runner = StubRunner()
        runner.distribution = nil
        await assertRefused(StubNetwork(), runner: runner, update()) { if case .packageMismatch = $0 { true } else { false } }
    }

    func testDownloadFailures() async {
        let failing = StubNetwork()
        failing.downloadStatus = 404
        await assertRefused(failing, update()) { $0 == .http(404) }
        let offline = StubNetwork()
        offline.error = URLError(.timedOut)
        await assertRefused(offline, update()) { if case .download = $0 { true } else { false } }
        await assertRefused(StubNetwork(), update(asset: .some(nil))) { $0 == .noInstaller }
    }

    func testCleansUpOnlyOldDownloadFolders() throws {
        let updater = updater(StubNetwork())
        let old = try updater.makePrivateFolder()
        let fresh = try updater.makePrivateFolder()
        let unrelated = temp.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3 * UpdateSchedule.interval)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3 * UpdateSchedule.interval)], ofItemAtPath: unrelated.path)
        updater.cleanUpOldDownloads()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    // MARK: - Menu and Settings

    func testAppMenuHasCheckForUpdates() {
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        let item = appMenu?.items.first { $0.action == #selector(AppDelegate.checkForUpdates(_:)) }
        XCTAssertEqual(item?.title, "Check for Updates…")
        XCTAssertEqual(appMenu?.index(of: item!), 1, "right under About")
    }

    func testSettingsCheckboxEditsThePreference() {
        let saved = Preferences.current
        defer { Preferences.update { $0 = saved } }
        let controller = PreferencesController()
        controller.load()
        XCTAssertEqual(controller.autoUpdateBox.state, saved.checkForUpdatesAutomatically ? .on : .off)
        controller.autoUpdateBox.state = .off
        controller.controlChanged(controller.autoUpdateBox)
        XCTAssertFalse(Preferences.current.checkForUpdatesAutomatically)
        controller.autoUpdateBox.state = .on
        controller.controlChanged(controller.autoUpdateBox)
        XCTAssertTrue(Preferences.current.checkForUpdatesAutomatically)
    }

    func testNotesViewShowsTheNotes() {
        let view = UpdateController.notesView("- MAC-75") as? NSScrollView
        XCTAssertEqual((view?.documentView as? NSTextView)?.string, "- MAC-75")
        XCTAssertEqual((view?.documentView as? NSTextView)?.isEditable, false)
        XCTAssertEqual(((UpdateController.notesView("") as? NSScrollView)?.documentView as? NSTextView)?.string, "No release notes.")
    }
}

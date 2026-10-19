import CryptoKit
import Foundation

/// MAC-75: Check for Updates. The newest GitHub release of the public repository is compared with
/// the running version; a newer one is offered, its installer downloaded into a private folder,
/// and opened in Installer only once its signature (Developer ID Installer of the project's team)
/// and contents (package id, version, name) check out. Everything here is headless: the network
/// and the command-line tools are injected, so the tests never reach GitHub. `UpdateController`
/// is the AppKit side.
enum UpdateSource {
    static let owner = "nachum-shmilovitz-66"
    static let repository = "inkpad-plus-plus"
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/\(owner)/\(repository)/releases")!
    /// The name every published installer carries: Inkpad++-<version>.pkg, titled Inkpad++.
    /// ("upstream" is Don Ho's trademark; personal builds with that name are never published.)
    static let publicName = "Inkpad++"
    static let teamID = "96Y4LX7FVB"
    static let packageIdentifier = "app.inkpad.Inkpad"
    /// No real installer comes near this; anything larger is not ours.
    static let maximumInstallerSize = 200 * 1024 * 1024
}

// MARK: - Versions

/// A semantic version (semver.org): MAJOR.MINOR.PATCH, an optional pre-release, and build metadata
/// that never counts. A leading "v" (GitHub tags) is accepted, and missing MINOR / PATCH are 0.
struct SemanticVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: [String] = []) {
        (self.major, self.minor, self.patch, self.prerelease) = (major, minor, patch, prerelease)
    }

    init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.first == "v" || rest.first == "V" { rest = rest.dropFirst() }
        if let plus = rest.firstIndex(of: "+") { rest = rest[..<plus] }
        var prerelease: [String] = []
        if let dash = rest.firstIndex(of: "-") {
            prerelease = rest[rest.index(after: dash)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            let allowed = { (c: Character) in c.isASCII && (c.isLetter || c.isNumber || c == "-") }
            guard prerelease.allSatisfy({ !$0.isEmpty && $0.allSatisfy(allowed) }) else { return nil }
            rest = rest[..<dash]
        }
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(part) else { return nil }
            numbers.append(number)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(numbers[0], numbers[1], numbers[2], prerelease: prerelease)
    }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) {
            return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
        }
        // A release ranks above its pre-releases; pre-releases compare identifier by identifier.
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, _): return false
        case (false, true): return true
        default: break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (m?, n?): return m < n
            case (_?, nil): return true   // numeric identifiers rank below alphanumeric ones
            case (nil, _?): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

// MARK: - GitHub's release JSON

/// The parts of GitHub's "latest release" response that the update check reads.
struct GitHubRelease: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let size: Int
        let browserDownloadURL: URL
        /// "sha256:<hex>", which GitHub computes for every uploaded asset.
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL?
    let draft: Bool?
    let prerelease: Bool?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    static func decode(_ data: Data) throws -> GitHubRelease {
        try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}

// MARK: - The decision

struct AvailableUpdate: Equatable {
    let version: SemanticVersion
    let notes: String
    let pageURL: URL
    /// The installer to download; nil when the release has none that passes `UpdateEvaluator`'s
    /// rules — then the update can only be shown, with a link to its page.
    let asset: GitHubRelease.Asset?

    var versionString: String { version.description }
}

enum UpdateCheckResult: Equatable {
    case upToDate(current: String)
    case available(AvailableUpdate)
    /// Newer, but the user chose Skip This Version for it: automatic checks stay quiet.
    case skipped(AvailableUpdate)
}

enum UpdateError: LocalizedError, Equatable {
    case http(Int)
    case noPublishedRelease
    case malformedRelease
    case badReleaseVersion(String)
    case currentVersionUnknown(String)
    case noInstaller
    case download(String)
    case sizeMismatch(expected: Int, actual: Int)
    case digestMismatch
    case untrustedSignature(String)
    case packageMismatch(String)

    var errorDescription: String? {
        switch self {
        case .http(let code): "The update server answered with HTTP status \(code)."
        case .noPublishedRelease: "No published release was found."
        case .malformedRelease: "The release information could not be read."
        case .badReleaseVersion(let tag): "The latest release has an unrecognized version (\(tag))."
        case .currentVersionUnknown(let version): "This copy's version (\(version)) is not a valid version number."
        case .noInstaller: "The release has no installer for this Mac."
        case .download(let reason): "The installer could not be downloaded: \(reason)"
        case .sizeMismatch(let expected, let actual): "The downloaded installer has the wrong size (\(actual) bytes, expected \(expected))."
        case .digestMismatch: "The downloaded installer does not match its published checksum."
        case .untrustedSignature(let reason): "The downloaded installer was refused: \(reason)"
        case .packageMismatch(let reason): "The downloaded installer was refused: \(reason)"
        }
    }
}

enum UpdateEvaluator {
    static func evaluate(_ release: GitHubRelease, currentVersion: String, skippedVersion: String?) throws -> UpdateCheckResult {
        guard let current = SemanticVersion(currentVersion) else { throw UpdateError.currentVersionUnknown(currentVersion) }
        // /releases/latest never returns these, but a draft or a pre-release is never offered.
        if release.draft == true || release.prerelease == true { return .upToDate(current: currentVersion) }
        guard let latest = SemanticVersion(release.tagName), latest.prerelease.isEmpty else {
            throw UpdateError.badReleaseVersion(release.tagName)
        }
        guard latest > current else { return .upToDate(current: currentVersion) }
        let page = release.htmlURL.flatMap { isRepositoryURL($0, under: "/releases/") ? $0 : nil } ?? UpdateSource.releasesPage
        let update = AvailableUpdate(version: latest, notes: release.body ?? "", pageURL: page,
                                     asset: installerAsset(in: release, version: latest))
        return skippedVersion == update.versionString ? .skipped(update) : .available(update)
    }

    /// The release's installer: exactly Inkpad++-<version>.pkg, downloaded from this repository's
    /// releases over HTTPS, with a plausible size. A personal build's name (upstream-…) never matches.
    static func installerAsset(in release: GitHubRelease, version: SemanticVersion) -> GitHubRelease.Asset? {
        let expected = "\(UpdateSource.publicName)-\(version).pkg"
        return release.assets.first {
            $0.name == expected && (1...UpdateSource.maximumInstallerSize).contains($0.size)
                && isRepositoryURL($0.browserDownloadURL, under: "/releases/download/")
        }
    }

    static func isRepositoryURL(_ url: URL, under section: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.port == nil && url.user == nil
            && url.path.hasPrefix("/\(UpdateSource.owner)/\(UpdateSource.repository)\(section)")
    }
}

/// Automatic checks: at launch and while running, at most once a day.
enum UpdateSchedule {
    static let interval: TimeInterval = 24 * 60 * 60

    static func isDue(lastCheck: Date?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval || now < lastCheck  // a clock set back is due too
    }
}

/// What "Download and Install" may do in this copy. Published installers are always Inkpad++, so a
/// personal build with another name (Config/Local.xcconfig, MAC-66) would be replaced by a
/// Inkpad++-named app: such builds only show the update and its page.
enum UpdateInstallPolicy: Equatable {
    case install
    case notifyOnly

    static func forApp(named name: String) -> UpdateInstallPolicy {
        name == UpdateSource.publicName ? .install : .notifyOnly
    }
}

// MARK: - Checking the downloaded package

enum PackageVerifier {
    /// What `pkgutil --check-signature` printed: the Status line and the certificate chain's names, leaf first.
    struct SignatureReport: Equatable {
        var status: String?
        var certificates: [String] = []
    }

    static let developerIDStatus = "signed by a developer certificate issued by Apple for distribution"

    static func parseSignature(_ output: String) -> SignatureReport {
        var report = SignatureReport()
        for line in output.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Status:") {
                report.status = text.dropFirst("Status:".count).trimmingCharacters(in: .whitespaces)
            } else if let dot = text.firstIndex(of: "."), dot > text.startIndex,
                      text[..<dot].allSatisfy({ $0.isASCII && $0.isNumber }),
                      Int(text[..<dot]) == report.certificates.count + 1 {
                report.certificates.append(text[text.index(after: dot)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return report
    }

    /// Accepts only a package signed with a Developer ID Installer certificate of `teamID`, chained
    /// through Apple's Developer ID CA to Apple Root CA, that pkgutil itself trusts.
    static func checkSignature(output: String, exitStatus: Int32, teamID: String = UpdateSource.teamID) throws {
        guard exitStatus == 0 else { throw UpdateError.untrustedSignature("it is not signed, or its signature is not valid.") }
        let report = parseSignature(output)
        guard report.status == developerIDStatus else {
            throw UpdateError.untrustedSignature("it is not signed with a Developer ID certificate.")
        }
        guard report.certificates.count == 3,
              report.certificates[0].hasPrefix("Developer ID Installer: "),
              report.certificates[0].hasSuffix("(\(teamID))"),
              report.certificates[1] == "Developer ID Certification Authority",
              report.certificates[2] == "Apple Root CA" else {
            throw UpdateError.untrustedSignature("it is not signed by the \(UpdateSource.publicName) developer.")
        }
    }

    /// The package's Distribution file: titled `name`, installing app.inkpad.Inkpad `version` as Inkpad++.app.
    static func checkDistribution(_ data: Data, version: String, name: String = UpdateSource.publicName) throws {
        let id = UpdateSource.packageIdentifier
        let document: XMLDocument
        do { document = try SafeXML.document(data: data) } catch {
            throw UpdateError.packageMismatch("its contents could not be read.")
        }
        guard let root = document.rootElement(), root.name == "installer-gui-script" else {
            throw UpdateError.packageMismatch("it is not an installer package.")
        }
        let title = root.elements(forName: "title").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title == name else { throw UpdateError.packageMismatch("it installs \(title ?? "an unnamed app"), not \(name).") }
        let components = root.elements(forName: "pkg-ref").filter { $0.attribute(forName: "version") != nil }
        guard !components.isEmpty,
              components.allSatisfy({ $0.attribute(forName: "id")?.stringValue == id && $0.attribute(forName: "version")?.stringValue == version }) else {
            throw UpdateError.packageMismatch("it is not \(name) \(version).")
        }
        let bundles = ((try? root.nodes(forXPath: "pkg-ref/bundle-version/bundle")) ?? []).compactMap { $0 as? XMLElement }
        guard let app = bundles.first(where: { $0.attribute(forName: "id")?.stringValue == id }),
              app.attribute(forName: "CFBundleShortVersionString")?.stringValue == version,
              app.attribute(forName: "path")?.stringValue == "Inkpad++.app" else {
            throw UpdateError.packageMismatch("its app is not \(name) \(version).")
        }
    }

    static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Injected services

/// The network as the updater uses it: the tests pass a stub, the app `URLSessionUpdateNetwork`.
protocol UpdateNetworking {
    /// The body and HTTP status of a GET.
    func data(from url: URL) async throws -> (Data, Int)
    /// Downloads to `destination` (which must not exist yet); returns the HTTP status.
    func download(from url: URL, to destination: URL) async throws -> Int
}

/// Runs a command-line tool (pkgutil, xar); the tests pass a stub.
protocol CommandRunning {
    func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String)
}

struct ProcessRunner: CommandRunning {
    func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()  // before waiting: a full pipe would block the tool
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

final class URLSessionUpdateNetwork: NSObject, UpdateNetworking, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    private let userAgent: String

    init(version: String) {
        userAgent = "\(UpdateSource.publicName)/\(version) (macOS)"
    }

    private func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    func data(from url: URL) async throws -> (Data, Int) {
        var request = request(url, accept: "application/vnd.github+json")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    func download(from url: URL, to destination: URL) async throws -> Int {
        let (file, response) = try await session.download(for: request(url, accept: "application/octet-stream"))
        try FileManager.default.moveItem(at: file, to: destination)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// GitHub sends release downloads on to its storage host: follow HTTPS redirects only.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url?.scheme == "https" ? request : nil
    }
}

// MARK: - The updater

final class Updater {
    static let lastCheckKey = "UpdateLastCheck"
    static let skippedVersionKey = "UpdateSkippedVersion"
    static let downloadFolderPrefix = "Inkpad++ Update "

    let network: UpdateNetworking
    let runner: CommandRunning
    let defaults: UserDefaults
    let currentVersion: String
    /// Where download folders are made (each one private to the user).
    let temporaryDirectory: URL

    init(network: UpdateNetworking, runner: CommandRunning = ProcessRunner(), defaults: UserDefaults,
         currentVersion: String, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.network = network
        self.runner = runner
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.temporaryDirectory = temporaryDirectory
    }

    var lastCheck: Date? {
        get { defaults.object(forKey: Self.lastCheckKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastCheckKey) }
    }

    var skippedVersion: String? {
        get { defaults.string(forKey: Self.skippedVersionKey) }
        set { defaults.set(newValue, forKey: Self.skippedVersionKey) }
    }

    func isAutomaticCheckDue(now: Date = Date()) -> Bool { UpdateSchedule.isDue(lastCheck: lastCheck, now: now) }

    func skip(_ update: AvailableUpdate) { skippedVersion = update.versionString }

    /// Asks GitHub for the latest release. A completed check (any answer) counts for the schedule.
    func check(now: Date = Date()) async throws -> UpdateCheckResult {
        let (data, status) = try await network.data(from: UpdateSource.latestReleaseAPI)
        lastCheck = now
        switch status {
        case 200: break
        case 404: throw UpdateError.noPublishedRelease  // no release yet, or the repository is not public
        default: throw UpdateError.http(status)
        }
        guard data.count <= 1024 * 1024, let release = try? GitHubRelease.decode(data) else { throw UpdateError.malformedRelease }
        return try UpdateEvaluator.evaluate(release, currentVersion: currentVersion, skippedVersion: skippedVersion)
    }

    /// Downloads the update's installer into a new private folder and verifies it; returns the
    /// package only when every check passed (the folder is removed otherwise).
    func downloadAndVerify(_ update: AvailableUpdate) async throws -> URL {
        guard let asset = update.asset else { throw UpdateError.noInstaller }
        let folder = try makePrivateFolder()
        let package = folder.appendingPathComponent(asset.name)
        do {
            let status: Int
            do { status = try await network.download(from: asset.browserDownloadURL, to: package) } catch {
                throw UpdateError.download(error.localizedDescription)
            }
            guard status == 200 else { throw UpdateError.http(status) }
            try verify(package, asset: asset, version: update.versionString, workFolder: folder)
            return package
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func verify(_ package: URL, asset: GitHubRelease.Asset, version: String, workFolder: URL) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: package.path)[.size] as? Int) ?? -1
        guard size == asset.size else { throw UpdateError.sizeMismatch(expected: asset.size, actual: size) }
        if let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:") {
            guard try PackageVerifier.sha256Hex(of: package) == digest.dropFirst("sha256:".count) else { throw UpdateError.digestMismatch }
        }
        let signature = try runner.run("/usr/sbin/pkgutil", ["--check-signature", package.path])
        try PackageVerifier.checkSignature(output: signature.output, exitStatus: signature.status)
        // The signature covers the archive's table of contents, which xar checks each file against.
        let extracted = workFolder.appendingPathComponent("contents", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        let xar = try runner.run("/usr/bin/xar", ["-x", "-f", package.path, "-C", extracted.path, "Distribution"])
        guard xar.status == 0, let distribution = try? Data(contentsOf: extracted.appendingPathComponent("Distribution")) else {
            throw UpdateError.packageMismatch("its contents could not be read.")
        }
        try PackageVerifier.checkDistribution(distribution, version: version)
        try? FileManager.default.removeItem(at: extracted)
    }

    func makePrivateFolder() throws -> URL {
        let folder = temporaryDirectory.appendingPathComponent(Self.downloadFolderPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Removes download folders older than a day (Installer has long finished with them).
    func cleanUpOldDownloads(now: Date = Date()) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for item in items where item.lastPathComponent.hasPrefix(Self.downloadFolderPrefix) {
            let created = (try? item.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if now.timeIntervalSince(created) > UpdateSchedule.interval { try? fm.removeItem(at: item) }
        }
    }
}

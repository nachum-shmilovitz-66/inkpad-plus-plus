import AppKit
import LocalAuthentication
import Security
import ServiceManagement

// Touch ID for Save as Administrator (MAC-24): MacPad++'s privileged helper, as seen from the app.
// With the helper approved, an admin save asks for Touch ID and the helper writes the file; without
// it, MAC-22's password prompt is used.

enum AdminHelperStatus: Equatable {
    case enabled
    /// Registered; the user still has to switch it on in System Settings › Login Items.
    case requiresApproval
    case notRegistered
    /// This build cannot use it (not signed with the team's Developer ID, or no helper inside).
    case unavailable
}

extension AdminHelperStatus {
    /// Maps SMAppService's view to ours. Only builds signed with the team's Developer ID can use the
    /// helper (code-signing requirements on both ends). macOS reports a daemon that was never
    /// registered as `.notFound` (MAC-27), so for such a build that means "not registered yet":
    /// registering is offered, and a helper that is truly missing makes registration fail, after
    /// which the password prompt is used.
    static func from(_ service: SMAppService.Status, signedByTeam: Bool) -> AdminHelperStatus {
        guard signedByTeam else { return .unavailable }
        switch service {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .notRegistered
        @unknown default: return .unavailable
        }
    }
}

/// Which way an admin save goes.
enum AdminSaveRoute: Equatable {
    case touchID
    /// The helper could be set up: offer it, and use the password this time.
    case offerSetup
    case password

    static func decide(status: AdminHelperStatus, setupDeclined: Bool) -> AdminSaveRoute {
        switch status {
        case .enabled: return .touchID
        case .requiresApproval, .notRegistered: return setupDeclined ? .password : .offerSetup
        case .unavailable: return .password
        }
    }
}

/// The user's answer to "Use Touch ID for administrator saves?".
enum HelperSetupChoice: Equatable {
    case setUp, notNow, dontAskAgain
}

protocol AdminHelperService: AnyObject {
    var status: AdminHelperStatus { get }
    func register() throws
    func openApprovalSettings()
    func install(_ data: Data, atPath path: String, completion: @escaping (Error?) -> Void)
}

protocol UserPresenceCheck {
    /// Touch ID, or the login password when Touch ID is unavailable. Calls back on the main queue.
    func confirm(reason: String, completion: @escaping (Bool) -> Void)
}

enum AdminHelperSupport {
    static var helper: AdminHelperService = SMAdminHelper()
    static var presence: UserPresenceCheck = DeviceOwnerPresence()

    static let setupDeclinedKey = "AdminHelperSetupDeclined"
    static var setupDeclined: Bool {
        get { AppEnvironment.defaults.bool(forKey: setupDeclinedKey) }
        set { AppEnvironment.defaults.set(newValue, forKey: setupDeclinedKey) }
    }

    /// The team that signed this running app, if any (nil for ad-hoc and development builds).
    static var signingTeam: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static func reason(for url: URL) -> String {
        "save \u{201C}\(url.lastPathComponent)\u{201D} as administrator"
    }
}

/// LocalAuthentication's device-owner check: Touch ID, falling back to the password.
struct DeviceOwnerPresence: UserPresenceCheck {
    func confirm(reason: String, completion: @escaping (Bool) -> Void) {
        LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { completion(ok) }
        }
    }
}

/// The real helper: SMAppService for registration, XPC for requests.
final class SMAdminHelper: AdminHelperService {
    private let service = SMAppService.daemon(plistName: HelperIdentity.daemonPlist)

    var status: AdminHelperStatus {
        let status = AdminHelperStatus.from(service.status,
                                            signedByTeam: AdminHelperSupport.signingTeam == HelperIdentity.teamID)
        NSLog("MacPad++: privileged helper status \(service.status.rawValue) -> \(status)")
        return status
    }

    func register() throws { try service.register() }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    func install(_ data: Data, atPath path: String, completion: @escaping (Error?) -> Void) {
        let connection = NSXPCConnection(machServiceName: HelperIdentity.machService, options: .privileged)
        connection.setCodeSigningRequirement(HelperIdentity.helperRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: MacPadHelperProtocol.self)
        connection.resume()
        let once = Once()
        let finish: (Error?) -> Void = { error in
            guard once.claim() else { return }
            connection.invalidate()
            DispatchQueue.main.async { completion(error) }
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { finish($0) } as? MacPadHelperProtocol
        guard let proxy else { finish(FileInstaller.Failure.io("Could not reach MacPad++'s helper.")); return }
        proxy.install(data, atPath: path) { message in finish(message.map { FileInstaller.Failure.io($0) }) }
    }

    /// XPC may report both a reply and an interruption; only the first counts.
    private final class Once {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

import AppKit
import LocalAuthentication
import Security

// Touch ID for Save as Administrator (MAC-24, MAC-28): MacPad++'s privileged helper, as seen from
// the app. The .pkg installs the helper as a launchd daemon (scripts/pkg/postinstall) — the user
// approves that with the installation itself, so there is no further set-up and no question here.
// When the helper answers, an admin save is one Touch ID popup; when it does not (a copy installed
// without the .pkg, or the helper switched off in Login Items), it is one password popup (MAC-22).

/// Which way an admin save goes.
enum AdminSaveRoute: Equatable {
    case touchID
    case password

    static func decide(helperAvailable: Bool) -> AdminSaveRoute { helperAvailable ? .touchID : .password }
}

protocol AdminHelperService: AnyObject {
    /// Whether the installed helper answers (and is the version this app speaks). Main queue.
    func checkAvailable(completion: @escaping (Bool) -> Void)
    func install(_ data: Data, atPath path: String, completion: @escaping (Error?) -> Void)
}

protocol UserPresenceCheck {
    /// Touch ID, or the login password when Touch ID is unavailable. Calls back on the main queue.
    func confirm(reason: String, completion: @escaping (Bool) -> Void)
}

enum AdminHelperSupport {
    static var helper: AdminHelperService = XPCAdminHelper()
    static var presence: UserPresenceCheck = DeviceOwnerPresence()

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

/// The real helper, reached over XPC at its launchd Mach service.
final class XPCAdminHelper: AdminHelperService {
    /// How long to wait for the helper's answer before using the password prompt instead.
    static var availabilityTimeout: TimeInterval = 1.5

    func checkAvailable(completion: @escaping (Bool) -> Void) {
        // Code-signing requirements on both ends only match the team's Developer ID builds.
        guard AdminHelperSupport.signingTeam == HelperIdentity.teamID else { completion(false); return }
        let connection = makeConnection()
        let finish = Once.callback { (ok: Bool) in
            connection.invalidate()
            NSLog("MacPad++: privileged helper \(ok ? "available" : "not available")")
            DispatchQueue.main.async { completion(ok) }
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish(false) } as? MacPadHelperProtocol
        proxy?.version { finish($0 == HelperIdentity.helperVersion) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.availabilityTimeout) { finish(false) }
    }

    func install(_ data: Data, atPath path: String, completion: @escaping (Error?) -> Void) {
        let connection = makeConnection()
        let finish = Once.callback { (error: Error?) in
            connection.invalidate()
            DispatchQueue.main.async { completion(error) }
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { finish($0) } as? MacPadHelperProtocol
        guard let proxy else { finish(FileInstaller.Failure.io("Could not reach MacPad++'s helper.")); return }
        proxy.install(data, atPath: path) { message in finish(message.map { FileInstaller.Failure.io($0) }) }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: HelperIdentity.machService, options: .privileged)
        connection.setCodeSigningRequirement(HelperIdentity.helperRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: MacPadHelperProtocol.self)
        connection.resume()
        return connection
    }

    /// XPC may report a reply, an interruption and a timeout; only the first counts.
    private final class Once {
        private let lock = NSLock()
        private var done = false

        static func callback<T>(_ body: @escaping (T) -> Void) -> (T) -> Void {
            let once = Once()
            return { value in if once.claim() { body(value) } }
        }

        private func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }
}

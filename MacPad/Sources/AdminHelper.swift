import AppKit
import Security

// Save as Administrator through MacPad++'s privileged helper (MAC-24, MAC-28, MAC-55), as seen
// from the app. The .pkg installs the helper as a launchd daemon (scripts/pkg/postinstall). The app
// sends the bytes with an authorization reference; the helper asks macOS for an administrator
// (Touch ID or password, in the system's own dialog naming the file) and only then writes. When the
// helper does not answer (a copy installed without the .pkg, a Debug build) it is MAC-22's password
// prompt instead. Either way, one popup.

/// Which way an admin save goes.
enum AdminSaveRoute: Equatable {
    case helper
    case password

    static func decide(helperAvailable: Bool) -> AdminSaveRoute { helperAvailable ? .helper : .password }
}

/// What came of a helper save.
enum AdminHelperResult {
    case saved
    /// The administrator prompt was cancelled: stay unsaved, ask nothing more.
    case cancelled
    /// The helper refuses this file whoever authorizes it (MAC-55): say why, do not fall back.
    case refused(String)
    /// The helper could not do it: the password prompt may.
    case failed(String)

    init(_ reply: HelperReply, _ message: String?) {
        switch reply {
        case .saved: self = .saved
        case .cancelled: self = .cancelled
        case .refused: self = .refused(message ?? "refused")
        case .failed: self = .failed(message ?? "failed")
        }
    }
}

protocol AdminHelperService: AnyObject {
    /// Whether the installed helper answers (and is the version this app speaks). Main queue.
    func checkAvailable(completion: @escaping (Bool) -> Void)
    /// Main queue.
    func install(_ data: Data, atPath path: String, completion: @escaping (AdminHelperResult) -> Void)
}

enum AdminHelperSupport {
    static var helper: AdminHelperService = XPCAdminHelper()

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

    /// A fresh authorization reference for one save, as the bytes the helper gets. No rights are
    /// asked for here: the helper asks for the save right on it (MAC-55).
    static func makeAuthorization() -> (reference: AuthorizationRef, external: Data)? {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else { return nil }
        var external = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(reference, &external) == errAuthorizationSuccess else {
            AuthorizationFree(reference, [])
            return nil
        }
        let data = withUnsafeBytes(of: external.bytes) { Data($0) }
        return (reference, data)
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

    func install(_ data: Data, atPath path: String, completion: @escaping (AdminHelperResult) -> Void) {
        guard let authorization = AdminHelperSupport.makeAuthorization() else {
            completion(.failed("Could not create an authorization."))
            return
        }
        let connection = makeConnection()
        let finish = Once.callback { (result: AdminHelperResult) in
            connection.invalidate()
            AuthorizationFree(authorization.reference, [.destroyRights])
            DispatchQueue.main.async { completion(result) }
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { finish(.failed($0.localizedDescription)) } as? MacPadHelperProtocol
        guard let proxy else { finish(.failed("Could not reach \(AppName.display)'s helper.")); return }
        proxy.install(data, atPath: path, authorization: authorization.external) { reply, message in
            finish(AdminHelperResult(reply, message))
        }
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

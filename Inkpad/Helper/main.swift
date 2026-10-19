import Foundation
import Security
import os

// Inkpad++'s privileged helper (MAC-24). launchd runs it as root (scripts/pkg/postinstall). It
// does one thing — install bytes at a path — only for Inkpad++ signed with the team's Developer
// ID, and (MAC-55) only after an administrator authorizes that very write: the app sends an
// authorization reference and the helper asks for the save right itself, so neither a standard
// user nor code running inside Inkpad++ gets a root write without an administrator's consent.

private let log = Logger(subsystem: "app.inkpad.Inkpad.helper", category: "install")

/// Authorization Services: the save right (an administrator, every time — see postinstall) on the
/// app's authorization reference. SecurityAgent shows the prompt in the user's session.
struct SystemAuthorizer: RequestAuthorizer {
    func authorize(_ externalForm: Data, path: String) throws {
        // Without the right in the database Authorization Services would fall back to its shared,
        // cached default rule: refuse instead.
        guard AuthorizationRightGet(HelperIdentity.saveRight, nil) == errAuthorizationSuccess else {
            throw RequestAuthorization.denied("the \(HelperIdentity.saveRight) right is not installed")
        }
        guard externalForm.count == kAuthorizationExternalFormLength else {
            throw RequestAuthorization.denied("malformed authorization")
        }
        var external = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &external.bytes) { _ = externalForm.copyBytes(to: $0) }
        var reference: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&external, &reference) == errAuthorizationSuccess, let reference else {
            throw RequestAuthorization.denied("invalid authorization")
        }
        defer { AuthorizationFree(reference, []) }

        let status = HelperIdentity.saveRight.withCString { right in
            HelperIdentity.prompt(forPath: path).withCString { prompt in
                "prompt".withCString { promptKey in  // kAuthorizationEnvironmentPrompt
                    var rightItem = AuthorizationItem(name: right, valueLength: 0, value: nil, flags: 0)
                    var promptItem = AuthorizationItem(name: promptKey, valueLength: strlen(prompt),
                                                       value: UnsafeMutableRawPointer(mutating: prompt), flags: 0)
                    return withUnsafeMutablePointer(to: &rightItem) { rightPointer in
                        withUnsafeMutablePointer(to: &promptItem) { promptPointer in
                            var rights = AuthorizationRights(count: 1, items: rightPointer)
                            var environment = AuthorizationEnvironment(count: 1, items: promptPointer)
                            return AuthorizationCopyRights(reference, &rights, &environment,
                                                           [.interactionAllowed, .extendRights], nil)
                        }
                    }
                }
            }
        }
        switch status {
        case errAuthorizationSuccess: return
        case errAuthorizationCanceled: throw RequestAuthorization.cancelled
        default: throw RequestAuthorization.denied("Authorization Services status \(status)")
        }
    }
}

final class HelperService: NSObject, InkpadHelperProtocol {
    let client: String

    init(client: String) { self.client = client }

    func install(_ data: Data, atPath path: String, authorization: Data,
                 withReply reply: @escaping (HelperReply, String?) -> Void) {
        let (outcome, message) = HelperRequest.handle(data, path: path, authorization: authorization,
                                                      authorizer: SystemAuthorizer())
        log.notice("install \(path, privacy: .public) for \(self.client, privacy: .public): \(outcome.rawValue) \(message ?? "", privacy: .public)")
        reply(outcome, message)
    }

    func version(withReply reply: @escaping (String) -> Void) {
        reply(HelperIdentity.helperVersion)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The system enforces this on every message: a caller that is not the Developer ID-signed
        // Inkpad++ is disconnected before it can ask for anything.
        connection.setCodeSigningRequirement(HelperIdentity.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: InkpadHelperProtocol.self)
        connection.exportedObject = HelperService(client: "pid \(connection.processIdentifier) uid \(connection.effectiveUserIdentifier)")
        connection.resume()
        return true
    }
}

// MAC-57: the password route (MAC-22) runs this binary once as root, through macOS's
// administrator prompt: `InkpadHelper --install-file <source> <target> <uid>`.
let arguments = CommandLine.arguments
if arguments.count == 5, arguments[1] == "--install-file", let uid = uid_t(arguments[4]) {
    do {
        try FileInstaller.installFile(source: arguments[2], target: arguments[3], owner: uid)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperIdentity.machService)
listener.delegate = delegate
listener.resume()
dispatchMain()

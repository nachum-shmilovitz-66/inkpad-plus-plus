import Foundation

// MacPad++'s privileged helper (MAC-24). launchd runs it as root once the user has approved it in
// System Settings › Login Items (SMAppService.daemon). It does one thing — install bytes at a path
// — and only for MacPad++ signed by the same Developer ID team.

final class HelperService: NSObject, MacPadHelperProtocol {
    func install(_ data: Data, atPath path: String, withReply reply: @escaping (String?) -> Void) {
        do {
            try FileInstaller.install(data, atPath: path)
            reply(nil)
        } catch {
            reply(error.localizedDescription)
        }
    }

    func version(withReply reply: @escaping (String) -> Void) {
        reply(HelperIdentity.helperVersion)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The system enforces this on every message: a caller that is not the signed MacPad++
        // is disconnected before it can ask for anything.
        connection.setCodeSigningRequirement(HelperIdentity.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: MacPadHelperProtocol.self)
        connection.exportedObject = HelperService()
        connection.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperIdentity.machService)
listener.delegate = delegate
listener.resume()
dispatchMain()

import Foundation
import Security
import HostHelperProtocol

final class HostHelperService: NSObject, ParrotHostHelperProtocol {
    func perform(_ request: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let operation = object["operation"] as? String else {
            reply(nil, "Invalid helper request.")
            return
        }
        switch operation {
        case "cli": HostCLIService.shared.perform(request, reply: reply)
        case "mlx": HostMLXService.shared.perform(request, reply: reply)
        default: reply(nil, "Unknown helper operation.")
        }
    }

    func cancel(_ identifier: String) {
        HostCLIService.shared.cancel(identifier)
        HostMLXService.shared.cancel(identifier)
    }
}

final class HostHelperDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HostHelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { return false }
        var text: CFString?
        guard SecRequirementCopyString(requirement, SecCSFlags(), &text) == errSecSuccess,
              let text else { return false }
        connection.setCodeSigningRequirement(text as String)
        connection.exportedInterface = NSXPCInterface(with: ParrotHostHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

signal(SIGPIPE, SIG_IGN)
let delegate = HostHelperDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

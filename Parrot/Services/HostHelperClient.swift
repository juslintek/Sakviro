import Foundation
import HostHelperProtocol

final class HostHelperClient {
    static let shared = HostHelperClient()
    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var pending: [String: (Data?, String?) -> Void] = [:]

    private func activeConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let next = NSXPCConnection(serviceName: "\(Bundle.main.bundleIdentifier ?? "com.uygar.parrot").host-helper")
        next.remoteObjectInterface = NSXPCInterface(with: ParrotHostHelperProtocol.self)
        next.invalidationHandler = { [weak self, weak next] in
            guard let self, let next else { return }
            self.connectionFailed(next, message: "The helper disconnected.")
        }
        next.interruptionHandler = { [weak self, weak next] in
            guard let self, let next else { return }
            self.connectionFailed(next, message: "The helper was interrupted.")
            next.invalidate()
        }
        connection = next
        next.resume()
        return next
    }

    private func connectionFailed(_ failed: NSXPCConnection, message: String) {
        lock.lock()
        guard connection === failed else { lock.unlock(); return }
        connection = nil
        let callbacks = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        for callback in callbacks { callback(nil, message) }
    }

    private func finish(_ identifier: String, data: Data?, message: String?) {
        lock.lock()
        let callback = pending.removeValue(forKey: identifier)
        lock.unlock()
        callback?(data, message)
    }

    func perform(_ request: Data, identifier: String) async throws -> Data {
        let current = activeConnection()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard connection === current, pending[identifier] == nil else {
                    lock.unlock()
                    continuation.resume(throwing: NSError(domain: "ParrotHostHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: "The helper is unavailable or the request is already running."]))
                    return
                }
                pending[identifier] = { data, message in
                    if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: NSError(domain: "ParrotHostHelper", code: 1, userInfo: [NSLocalizedDescriptionKey: message ?? "The helper returned no result."])) }
                }
                lock.unlock()
                let proxy = current.remoteObjectProxyWithErrorHandler { [weak self] error in
                    self?.finish(identifier, data: nil, message: error.localizedDescription)
                } as? ParrotHostHelperProtocol
                guard let proxy else { finish(identifier, data: nil, message: "The helper is unavailable."); return }
                proxy.perform(request) { [weak self] data, message in
                    self?.finish(identifier, data: data, message: message)
                }
                if Task.isCancelled { proxy.cancel(identifier) }
            }
        } onCancel: {
            (current.remoteObjectProxy as? ParrotHostHelperProtocol)?.cancel(identifier)
        }
    }
}

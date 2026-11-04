import Foundation
import Darwin

func stopMLXProcess(_ worker: Process) {
    guard worker.isRunning else { return }
    let pid = worker.processIdentifier
    kill(pid, SIGTERM)
    DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
        if worker.isRunning { kill(pid, SIGKILL) }
    }
}

final class HostMLXService {
    static let shared = HostMLXService()
    private let queue = DispatchQueue(label: "parrot.mlx.worker")
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var python = ""
    private var pending: Set<String> = []
    private var cancelled: Set<String> = []
    private var active: String?

    func perform(_ requestData: Data, reply: @escaping (Data?, String?) -> Void) {
        guard requestData.count <= 3_000_000,
              let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
              request["operation"] as? String == "mlx",
              let identifier = request["id"] as? String, UUID(uuidString: identifier) != nil,
              let action = request["action"] as? String, ["load", "transcribe", "unload"].contains(action) else {
            reply(nil, "Invalid MLX request")
            return
        }
        lock.lock()
        guard pending.count < 4, !pending.contains(identifier) else {
            lock.unlock()
            reply(nil, "MLX worker is busy")
            return
        }
        pending.insert(identifier)
        lock.unlock()
        queue.async {
            defer {
                self.lock.lock()
                self.pending.remove(identifier)
                self.cancelled.remove(identifier)
                self.active = nil
                self.lock.unlock()
            }
            self.lock.lock()
            let wasCancelled = self.cancelled.contains(identifier)
            self.active = identifier
            self.lock.unlock()
            guard !wasCancelled else { reply(nil, "MLX request cancelled"); return }
            do {
                if action == "unload" {
                    self.stopWorker()
                    reply(Data("{\"ok\":true}".utf8), nil)
                    return
                }
                guard let executable = request["python"] as? String,
                      executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable),
                      let model = request["model"] as? String, model.hasPrefix("/"),
                      FileManager.default.fileExists(atPath: model) else {
                    throw Failure.message("Choose a Python executable and local MLX model folder")
                }
                try self.startWorker(executable)
                self.lock.lock()
                let cancelledBeforeStart = self.cancelled.contains(identifier)
                self.lock.unlock()
                guard !cancelledBeforeStart else { throw Failure.message("MLX request cancelled") }
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + 180)
                timer.setEventHandler { self.cancel(identifier) }
                timer.resume()
                defer { timer.cancel() }
                guard let input = self.input, let output = self.output else { throw Failure.message("MLX worker unavailable") }
                try input.write(contentsOf: requestData + Data([10]))
                var response = Data()
                while response.count < 1_000_000 {
                    guard let byte = try output.read(upToCount: 1), !byte.isEmpty else {
                        throw Failure.message("MLX worker stopped unexpectedly")
                    }
                    if byte[0] == 10 { break }
                    response.append(byte)
                }
                guard response.count < 1_000_000,
                      let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                      let ok = object["ok"] as? Bool else { throw Failure.message("Invalid MLX worker response") }
                if !ok { throw Failure.message(object["error"] as? String ?? "MLX transcription failed") }
                self.lock.lock()
                let wasCancelled = self.cancelled.contains(identifier)
                self.lock.unlock()
                guard !wasCancelled else { throw Failure.message("MLX request cancelled or timed out") }
                reply(response, nil)
            } catch {
                self.stopWorker()
                reply(nil, error.localizedDescription)
            }
        }
    }

    func cancel(_ identifier: String) {
        lock.lock()
        guard pending.contains(identifier) else { lock.unlock(); return }
        cancelled.insert(identifier)
        let running = active == identifier ? process : nil
        lock.unlock()
        if let running { stopMLXProcess(running) }
    }

    private func startWorker(_ executable: String) throws {
        if process?.isRunning == true, python == executable { return }
        stopWorker()
        guard let script = Bundle.main.url(forResource: "mlx_worker", withExtension: "py") else {
            throw Failure.message("MLX worker is missing from the helper")
        }
        let worker = Process()
        let stdin = Pipe(), stdout = Pipe()
        worker.executableURL = URL(fileURLWithPath: executable)
        worker.arguments = ["-u", script.path]
        worker.standardInput = stdin
        worker.standardOutput = stdout
        worker.standardError = FileHandle.nullDevice
        try worker.run()
        lock.lock()
        process = worker
        lock.unlock()
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        python = executable
    }

    private func stopWorker() {
        lock.lock()
        let worker = process
        process = nil
        lock.unlock()
        if let worker {
            stopMLXProcess(worker)
            worker.waitUntilExit()
        }
        try? input?.close()
        try? output?.close()
        input = nil
        output = nil
        python = ""
    }

    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
    }
}

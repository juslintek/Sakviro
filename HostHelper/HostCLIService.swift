import Foundation
import Darwin

final class HostCLIService {
    static let shared = HostCLIService()
    private let lock = NSLock()
    private var processes: [String: pid_t] = [:]
    private var cancelled: Set<String> = []
    private var pending: Set<String> = []

    func cancel(_ identifier: String) {
        lock.lock()
        if pending.contains(identifier) { cancelled.insert(identifier) }
        let pid = processes[identifier]
        lock.unlock()
        if let pid { kill(-pid, SIGKILL) }
    }

    func perform(_ request: Data, reply: @escaping (Data?, String?) -> Void) {
        guard let object = try? JSONSerialization.jsonObject(with: request) as? [String: Any],
              let identifier = object["id"] as? String, UUID(uuidString: identifier) != nil else {
            reply(nil, "Invalid CLI configuration or executable not found.")
            return
        }
        lock.lock()
        let registered = pending.insert(identifier).inserted
        lock.unlock()
        guard registered else { reply(nil, "CLI request is already running."); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try self.run(request) }
            self.lock.lock()
            self.pending.remove(identifier)
            self.processes.removeValue(forKey: identifier)
            self.cancelled.remove(identifier)
            self.lock.unlock()
            switch outcome {
            case .success(let response): reply(response, nil)
            case .failure(let error): reply(nil, error.localizedDescription)
            }
        }
    }

    private func run(_ request: Data) throws -> Data {
        guard let object = try JSONSerialization.jsonObject(with: request) as? [String: Any],
              let identifier = object["id"] as? String, UUID(uuidString: identifier) != nil,
              let requestedExecutable = object["executable"] as? String,
              let arguments = object["arguments"] as? [String], arguments.count < 100,
              let input = object["input"] as? String, input.utf8.count < 1_000_000,
              !requestedExecutable.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw failure("Invalid CLI configuration or executable not found.")
        }
        guard let account = getpwuid(getuid()), let homePointer = account.pointee.pw_dir else {
            throw failure("Could not determine the account home directory.")
        }
        let home = String(cString: homePointer)
        let executable: String
        if requestedExecutable.hasPrefix("@") {
            let name = String(requestedExecutable.dropFirst())
            guard ["claude", "codex", "gemini", "copilot"].contains(name),
                  let found = ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw failure("CLI executable not found. Set its absolute path in Settings.")
            }
            executable = found
        } else {
            guard requestedExecutable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: requestedExecutable) else {
                throw failure("Invalid CLI configuration or executable not found.")
            }
            executable = requestedExecutable
        }
        let timeout = min(max(object["timeout"] as? Double ?? 90, 1), 300)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parrot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var inputPipe: [Int32] = [0, 0], outputPipe: [Int32] = [0, 0], errorPipe: [Int32] = [0, 0]
        guard pipe(&inputPipe) == 0, pipe(&outputPipe) == 0, pipe(&errorPipe) == 0 else { throw failure("Could not create CLI pipes.") }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        var setup = [posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO),
                     posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO),
                     posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO)]
        for fd in inputPipe + outputPipe + errorPipe { setup.append(posix_spawn_file_actions_addclose(&actions, fd)) }
        setup.append(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        setup.append(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        setup.append(posix_spawnattr_setpgroup(&attributes, 0))
        guard setup.allSatisfy({ $0 == 0 }) else {
            for fd in inputPipe + outputPipe + errorPipe { close(fd) }
            throw failure("Could not prepare the CLI process.")
        }
        var processArguments = arguments
        if object["preset"] as? String == "gemini" {
            let isolatedConfig = directory.appendingPathComponent(".gemini")
            try FileManager.default.createDirectory(at: isolatedConfig, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let originalConfig = URL(fileURLWithPath: home).appendingPathComponent(".gemini")
            for name in ["oauth_creds.json", "google_accounts.json"] {
                let source = originalConfig.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.createSymbolicLink(at: isolatedConfig.appendingPathComponent(name), withDestinationURL: source)
                }
            }
            var auth: [String: Any] = [:]
            let originalSettings = originalConfig.appendingPathComponent("settings.json")
            if FileManager.default.fileExists(atPath: originalSettings.path) {
                let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: originalSettings)) as? [String: Any]
                let security = settings?["security"] as? [String: Any]
                let originalAuth = security?["auth"] as? [String: Any]
                if let type = originalAuth?["selectedType"] as? String { auth["selectedType"] = type }
            }
            let settings: [String: Any] = ["security": ["auth": auth], "admin": ["mcp": ["enabled": false],
                "extensions": ["enabled": false], "skills": ["enabled": false]], "hooksConfig": ["enabled": false],
                "skills": ["enabled": false], "tools": ["core": [String]()], "context": ["fileName": "PARROT_NO_INSTRUCTIONS"]]
            try JSONSerialization.data(withJSONObject: settings).write(to: isolatedConfig.appendingPathComponent("settings.json"), options: .atomic)
            let policy = directory.appendingPathComponent("deny-tools.toml")
            try "[[rule]]\ntoolName = \"*\"\ndecision = \"deny\"\npriority = 999\n".write(to: policy, atomically: true, encoding: .utf8)
            processArguments += ["--admin-policy", policy.path]
        }
        let strings = [executable] + processArguments
        var argv = strings.map { strdup($0) } + [nil]
        defer { for ptr in argv where ptr != nil { free(ptr) } }
        var environment = ["HOME=\(home)", "PATH=\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                           "TMPDIR=\(directory.path)", "LANG=en_US.UTF-8"]
        if object["preset"] as? String == "copilot" { environment.append("COPILOT_HOME=\(directory.path)") }
        if object["preset"] as? String == "gemini" { environment.append("GEMINI_CLI_HOME=\(directory.path)") }
        var envp = environment.map { strdup($0) } + [nil]
        defer { for ptr in envp where ptr != nil { free(ptr) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, &argv, &envp)
        close(inputPipe[0]); close(outputPipe[1]); close(errorPipe[1])
        guard status == 0 else {
            close(inputPipe[1]); close(outputPipe[0]); close(errorPipe[0])
            throw failure("Could not start CLI (error \(status)).")
        }
        lock.lock()
        let wasCancelled = cancelled.remove(identifier) != nil
        processes[identifier] = pid
        lock.unlock()
        if wasCancelled { kill(-pid, SIGKILL) }
        let group = DispatchGroup()
        let state = OutputState()
        for (fd, isError) in [(outputPipe[0], false), (errorPipe[0], true)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { close(fd); group.leave() }
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count <= 0 { break }
                    if !state.append(Data(buffer.prefix(count)), error: isError) { kill(-pid, SIGKILL) }
                }
            }
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { close(inputPipe[1]); group.leave() }
            let bytes = Array(input.utf8)
            bytes.withUnsafeBytes { ptr in
                var offset = 0
                while offset < ptr.count {
                    let written = write(inputPipe[1], ptr.baseAddress!.advanced(by: offset), ptr.count - offset)
                    if written <= 0 { break }
                    offset += written
                }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { state.timeOut(); kill(-pid, SIGKILL) }
        timer.resume()
        var exitStatus: Int32 = 0
        waitpid(pid, &exitStatus, 0)
        kill(-pid, SIGKILL)
        timer.cancel()
        group.wait()
        if state.timedOut { throw failure("CLI timed out.") }
        if state.overflow { throw failure("CLI output exceeded the limit.") }
        guard exitStatus == 0 else {
            if object["preset"] as? String == "gemini",
               let output = String(data: state.output + state.errors, encoding: .utf8),
               output.contains("UNSUPPORTED_CLIENT") {
                throw failure("Gemini CLI reported UNSUPPORTED_CLIENT. Google does not support this client for the current account.")
            }
            if object["preset"] as? String == "gemini",
               let output = String(data: state.output + state.errors, encoding: .utf8),
               output.contains("IneligibleTierError") {
                throw failure("Gemini CLI reported an ineligible account tier.")
            }
            if let output = String(data: state.output, encoding: .utf8), output.localizedCaseInsensitiveContains("not logged in") {
                throw failure("CLI is not signed in. Sign in through the CLI, then try again.")
            }
            throw failure("CLI failed. Check its sign-in and configuration.")
        }
        return state.output
    }

    private func failure(_ text: String) -> NSError {
        NSError(domain: "ParrotCLI", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

private final class OutputState {
    private let lock = NSLock()
    private var bytes = Data()
    private var errorData = Data()
    private(set) var overflow = false
    private(set) var timedOut = false
    var output: Data { lock.lock(); defer { lock.unlock() }; return bytes }
    var errors: Data { lock.lock(); defer { lock.unlock() }; return errorData }
    func timeOut() { lock.lock(); timedOut = true; lock.unlock() }
    func append(_ data: Data, error: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if error && errorData.count + data.count <= 1_000_000 { errorData.append(data) }
        else if error { overflow = true }
        else if bytes.count + data.count <= 1_000_000 { bytes.append(data) }
        else { overflow = true }
        return !overflow
    }
}

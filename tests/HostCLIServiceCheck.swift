import Foundation
import CoreGraphics
import ImageIO
import Darwin

@main struct HostCLIServiceCheck {
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        let service = HostCLIService.shared
        func request(_ path: String, _ arguments: [String], _ input: String, _ timeout: Double) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "executable": path,
                                                        "arguments": arguments, "input": input, "timeout": timeout])
        }
        func run(_ request: Data) -> (Data?, String?) {
            let done = DispatchSemaphore(value: 0)
            var answer: (Data?, String?) = (nil, nil)
            service.perform(request) { data, error in answer = (data, error); done.signal() }
            precondition(done.wait(timeout: .now() + 10) == .success)
            return answer
        }
        let echo = run(try request("/bin/cat", [], "synthetic-test", 3))
        precondition(echo.0.flatMap { String(data: $0, encoding: .utf8) } == "synthetic-test")
        setenv("PARROT_TEST_SECRET", "must-not-inherit", 1)
        let environment = run(try request("/usr/bin/env", [], "", 3))
        let variables = environment.0.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        precondition(variables.contains("HOME=\(String(cString: getpwuid(getuid()).pointee.pw_dir))\n"))
        precondition(!variables.contains("PARROT_TEST_SECRET"))
        let copilotEnvironment = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "executable": "/usr/bin/env",
                                                                              "arguments": [], "input": "", "timeout": 3,
                                                                              "preset": "copilot"])
        let isolated = run(copilotEnvironment).0.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        precondition(isolated.contains("COPILOT_HOME=") && !isolated.contains("COPILOT_HOME=\(NSHomeDirectory())/.copilot"))
        let geminiScript = "import os,json,sys; p=os.environ['GEMINI_CLI_HOME']; c=json.load(open(p+'/.gemini/settings.json')); assert not c['hooksConfig']['enabled'] and not c['admin']['mcp']['enabled'] and not c['admin']['extensions']['enabled'] and not c['admin']['skills']['enabled'] and c['tools']['core']==[]; assert sys.argv[1]=='--admin-policy' and 'decision = \"deny\"' in open(sys.argv[2]).read(); print('isolated')"
        let geminiEnvironment = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "executable": "/usr/bin/python3",
                                                                             "arguments": ["-c", geminiScript], "input": "", "timeout": 3,
                                                                             "preset": "gemini"])
        let geminiCheck = run(geminiEnvironment)
        precondition(geminiCheck.0.flatMap { String(data: $0, encoding: .utf8) } == "isolated\n")
        for (marker, expected) in [("UNSUPPORTED_CLIENT", "UNSUPPORTED_CLIENT"), ("IneligibleTierError", "ineligible account tier")] {
            let request = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "executable": "/usr/bin/python3",
                "arguments": ["-c", "import sys; print('\(marker) private-value', file=sys.stderr); sys.exit(1)"],
                "input": "", "timeout": 3, "preset": "gemini"])
            let message = run(request).1 ?? ""
            precondition(message.contains(expected) && !message.contains("private-value"))
        }
        let pixels = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        pixels.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        pixels.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let jpeg = NSMutableData()
        let destination = CGImageDestinationCreateWithData(jpeg, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, pixels.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination))
        let checkAttachment = "import sys,os,stat; p=sys.argv[-2]; assert sys.argv[-3]=='--image' and sys.argv[-1]=='-'; assert stat.S_IMODE(os.stat(p).st_mode)==0o600 and stat.S_IMODE(os.stat(os.path.dirname(p)).st_mode)==0o700; assert open(p,'rb').read(2)==b'\\xff\\xd8'; print(p)"
        let attachmentRequest = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "executable": "/usr/bin/python3",
            "arguments": ["-c", checkAttachment, "-"], "input": "", "timeout": 3, "preset": "codex", "jpeg": (jpeg as Data).base64EncodedString()])
        let attachmentResult = run(attachmentRequest)
        let attachmentPath = String(data: attachmentResult.0 ?? Data(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        precondition(!attachmentPath.isEmpty && !FileManager.default.fileExists(atPath: attachmentPath), attachmentResult.1 ?? "attachment failed")
        let claudeInput = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "executable": "/bin/cat",
            "arguments": [], "input": "synthetic prompt", "timeout": 3, "preset": "claudeCode", "jpeg": (jpeg as Data).base64EncodedString()])
        let claudeOutput = run(claudeInput)
        let envelope = try JSONSerialization.jsonObject(with: claudeOutput.0 ?? Data()) as? [String: Any]
        let message = envelope?["message"] as? [String: Any]
        let content = message?["content"] as? [[String: Any]]
        let image = content?.first?["source"] as? [String: Any]
        precondition(envelope?["type"] as? String == "user" && message?["role"] as? String == "user")
        precondition(image?["media_type"] as? String == "image/jpeg" && image?["data"] as? String == (jpeg as Data).base64EncodedString())
        precondition(content?.last?["text"] as? String == "synthetic prompt", claudeOutput.1 ?? "Claude input failed")
        let invalidJPEG = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "executable": "/bin/echo",
            "arguments": ["-"], "input": "", "timeout": 3, "preset": "codex", "jpeg": Data("not an image".utf8).base64EncodedString()])
        precondition(run(invalidJPEG).1 == "Invalid screen JPEG.")
        let invalidArgument = run(try request("/bin/echo", ["bad\0argument"], "", 3))
        precondition(invalidArgument.0 == nil)
        let timeout = run(try request("/bin/sleep", ["10"], "", 1))
        precondition(timeout.0 == nil && timeout.1 == "CLI timed out.")
        let failure = run(try request("/usr/bin/false", [], "", 3))
        precondition(failure.0 == nil && failure.1 != nil)
        let loginFailure = run(try request("/bin/sh", ["-c", "echo 'Not logged in'; exit 1"], "", 3))
        precondition(loginFailure.1 == "CLI is not signed in. Sign in through the CLI, then try again.")
        let identifier = UUID().uuidString
        service.cancel(identifier)
        let afterUnknownCancel = try JSONSerialization.data(withJSONObject: ["id": identifier, "executable": "/bin/echo",
                                                                            "arguments": ["ok"], "input": "", "timeout": 3])
        precondition(run(afterUnknownCancel).0.flatMap { String(data: $0, encoding: .utf8) } == "ok\n")
        let cancelled = try JSONSerialization.data(withJSONObject: ["id": identifier, "executable": "/bin/sleep",
                                                                    "arguments": ["10"], "input": "", "timeout": 30])
        let done = DispatchSemaphore(value: 0)
        var error: String?
        service.perform(cancelled) { _, message in error = message; done.signal() }
        service.cancel(identifier)
        precondition(done.wait(timeout: .now() + 5) == .success && error != nil)
        let worker = Process()
        let ready = Pipe()
        worker.executableURL = URL(fileURLWithPath: "/bin/sh")
        worker.arguments = ["-c", "trap '' TERM; echo ready; exec /bin/sleep 10"]
        worker.standardOutput = ready
        try worker.run()
        let readyMessage = try ready.fileHandleForReading.read(upToCount: 6)
        precondition(readyMessage == Data("ready\n".utf8))
        let started = Date()
        stopMLXProcess(worker)
        worker.waitUntilExit()
        precondition(Date().timeIntervalSince(started) < 5 && worker.terminationReason == .uncaughtSignal)
        print("Host CLI checks passed")
    }
}

#!/usr/bin/env python3
"""Run the host's memory-pressure cleanup against a real synthetic subprocess."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


worker = '''
import json
import os
import sys
import time

for line in sys.stdin:
    request = json.loads(line)
    if "started" in request:
        with open(request["started"], "w") as marker:
            marker.write(str(os.getpid()))
        time.sleep(0.3)
    print(json.dumps({"ok": True, "text": str(os.getpid())}), flush=True)
'''

check = r'''
import Foundation
import Darwin

@main struct MLXLifecycleCheck {
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        let service = HostMLXService()
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        let python = CommandLine.arguments[2]
        func request(_ action: String, started: URL? = nil) throws -> Data {
            var fields = ["operation": "mlx", "id": UUID().uuidString, "action": action,
                          "python": python, "model": folder.path]
            if let started { fields["started"] = started.path }
            return try JSONSerialization.data(withJSONObject: fields)
        }
        func pid(_ response: Data?, _ error: String?) -> pid_t {
            precondition(error == nil, error ?? "")
            let object = try! JSONSerialization.jsonObject(with: response!) as! [String: Any]
            return pid_t(object["text"] as! String)!
        }
        func run(_ action: String) throws -> pid_t {
            let completed = DispatchSemaphore(value: 0)
            var identifier: pid_t = 0
            service.perform(try request(action)) { response, error in
                identifier = pid(response, error)
                completed.signal()
            }
            precondition(completed.wait(timeout: .now() + 15) == .success, "MLX request stalled")
            return identifier
        }
        func waitUntil(_ reason: String, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition(), Date() < deadline { usleep(10_000) }
            precondition(condition(), reason)
        }

        let firstPID = try run("load")
        precondition(kill(firstPID, 0) == 0)
        let firstStarted = folder.appendingPathComponent("first-started")
        let secondStarted = folder.appendingPathComponent("second-started")
        let completed = DispatchSemaphore(value: 0)
        service.perform(try request("transcribe", started: firstStarted)) { response, error in
            precondition(pid(response, error) == firstPID, "Active request lost its worker")
            completed.signal()
        }
        waitUntil("First decode never started") { FileManager.default.fileExists(atPath: firstStarted.path) }
        service.releaseForMemoryPressure()
        service.perform(try request("transcribe", started: secondStarted)) { response, error in
            precondition(pid(response, error) == firstPID, "Queued request lost its worker")
            completed.signal()
        }
        precondition(completed.wait(timeout: .now() + 15) == .success)
        precondition(completed.wait(timeout: .now() + 15) == .success)
        waitUntil("Pressure cleanup was lost while requests were pending") { kill(firstPID, 0) != 0 }

        let nextPID = try run("transcribe")
        precondition(nextPID != firstPID && kill(nextPID, 0) == 0, "Next decode did not restart the worker")
        service.releaseForMemoryPressure()
        waitUntil("Idle worker retained after memory pressure") { kill(nextPID, 0) != 0 }
        print("MLX lifecycle passed: active and queued decodes finish, idle worker exits, next decode restarts")
    }
}
'''

source = Path(sys.argv[1]) if len(sys.argv) == 2 else (
    Path(__file__).resolve().parents[1] / "HostHelper/HostMLXService.swift"
)
with tempfile.TemporaryDirectory(prefix="sakviro-mlx-lifecycle-") as directory:
    folder = Path(directory)
    contents = folder / "MLXCheck.app/Contents"
    executable = contents / "MacOS/check"
    executable.parent.mkdir(parents=True)
    resources = contents / "Resources"
    resources.mkdir()
    (resources / "mlx_worker.py").write_text(worker)
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleExecutable": "check", "CFBundleIdentifier": "test.sakviro.mlx-lifecycle",
        "CFBundlePackageType": "APPL",
    }))
    harness = folder / "Check.swift"
    harness.write_text(check)
    subprocess.run(["swiftc", str(source), str(harness), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(folder), sys.executable], check=True, timeout=90)

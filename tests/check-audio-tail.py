#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys
import tempfile


if len(sys.argv) > 2:
    sys.exit("Run with python3 tests/check-audio-tail.py [AudioCaptureManager.swift]")
repo = Path(__file__).resolve().parents[1]
manager_path = Path(sys.argv[1]) if len(sys.argv) == 2 else repo / "Parrot/Services/AudioCaptureManager.swift"
manager = manager_path.read_text()
stop_start = manager.index("    func stopCapture() async {")
close_start = manager.index("        systemWriteQueue.sync {", stop_start)
manager = manager[:close_start] + "        tailCloseReached.signal()\n" + manager[close_start:]
if "private var filesClosed = true" in manager:
    prepare_flags = "capture.filesClosed = false"
else:
    prepare_flags = "capture.systemWriteQueue.sync { capture.systemFileClosed = false }\n        capture.micWriteQueue.sync { capture.micFileClosed = false }"

stubs = r'''
import Foundation
import AVFoundation
let tailCloseReached = DispatchSemaphore(value: 0)
enum AudioSource { case me, them }
enum MeetingActions { static let appName = "AudioTailCheck" }
enum PermissionFlow { static let tapProvenKey = "unused" }
final class EchoCanceller {
    struct Stats { let frames: Int; let removed: Float; let filterAlone: Float; let hears: Float }
    var onPairs: (([Int16], [Int16]) -> Void)?
    var referenceBacklog: Int { fatalError("unrelated AEC reached") }
    var starvedFrames: Int { fatalError("unrelated AEC reached") }
    init() { fatalError("unrelated AEC reached") }
    func process(mic: [Float]) -> [Float] { fatalError("unrelated AEC reached") }
    func pushReference(_ samples: [Float]) { fatalError("unrelated AEC reached") }
    func micRestarted() { fatalError("unrelated AEC reached") }
    func takeStats() -> Stats? { fatalError("unrelated AEC reached") }
}
'''

check = r'''
extension AudioCaptureManager {
    @MainActor static func checkPendingTail(folder: URL) async throws -> Bool {
        let capture = AudioCaptureManager()
        capture.systemAudioURL = folder.appendingPathComponent("system.caf")
        capture.micAudioURL = folder.appendingPathComponent("mic.caf")
        __PREPARE_FLAGS__
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        pcm.frameLength = 160
        for index in 0..<160 { pcm.floatChannelData![0][index] = 0.125 }
        capture.appendAudio(pcm, to: .system, ownsBuffer: true)
        capture.appendAudio(pcm, to: .mic, ownsBuffer: true)
        capture.systemWriteQueue.sync {}
        capture.micWriteQueue.sync {}
        let blocked = DispatchGroup()
        let releaseSystem = DispatchSemaphore(value: 0), releaseMic = DispatchSemaphore(value: 0)
        blocked.enter()
        capture.systemWriteQueue.async {
            blocked.leave()
            precondition(releaseSystem.wait(timeout: .now() + 10) == .success, "system writer release stalled")
        }
        blocked.enter()
        capture.micWriteQueue.async {
            blocked.leave()
            precondition(releaseMic.wait(timeout: .now() + 10) == .success, "mic writer release stalled")
        }
        func waitForWriters() {
            precondition(blocked.wait(timeout: .now() + 5) == .success, "writer blockers did not start")
        }
        waitForWriters()
        for _ in 0..<4 {
            capture.appendAudio(pcm, to: .system, ownsBuffer: true)
            capture.appendAudio(pcm, to: .mic, ownsBuffer: true)
        }
        DispatchQueue.global().async {
            precondition(tailCloseReached.wait(timeout: .now() + 5) == .success, "stop did not reach writer barriers")
            releaseSystem.signal()
            releaseMic.signal()
        }
        await capture.stopCapture()
        func lengths() throws -> (AVAudioFramePosition, AVAudioFramePosition) {
            let system = try AVAudioFile(forReading: capture.systemAudioURL!)
            let mic = try AVAudioFile(forReading: capture.micAudioURL!)
            return (system.length, mic.length)
        }
        let drained = try lengths()
        print("Expected 800 frames per track; actual system=\(drained.0), mic=\(drained.1)")
        guard drained.0 == 800, drained.1 == 800 else { return false }
        capture.appendAudio(pcm, to: .system, ownsBuffer: true)
        capture.appendAudio(pcm, to: .mic, ownsBuffer: true)
        capture.systemWriteQueue.sync {}
        capture.micWriteQueue.sync {}
        let closed = try lengths()
        guard closed.0 == 800, closed.1 == 800 else {
            print("Late writes changed finalized frames: system=\(closed.0), mic=\(closed.1)")
            return false
        }
        print("PASS pending tails drained and post-close writes preserved finalized files")
        return true
    }
}
@main enum AudioTailCheck {
    @MainActor static func main() async throws {
        let passed = try await AudioCaptureManager.checkPendingTail(folder: URL(fileURLWithPath: CommandLine.arguments[1]))
        exit(passed ? 0 : 1)
    }
}
'''

with tempfile.TemporaryDirectory(prefix="sakviro-audio-tail-check-") as directory:
    folder = Path(directory)
    swift = folder / "Check.swift"
    executable = folder / "check"
    tap = (repo / "Parrot/Services/SystemAudioTap.swift").read_text()
    swift.write_text(stubs + manager + tap + check.replace("__PREPARE_FLAGS__", prepare_flags))
    subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", str(swift), "-o", str(executable)], check=True, timeout=60)
    sys.exit(subprocess.run([str(executable), str(folder)], timeout=20).returncode)

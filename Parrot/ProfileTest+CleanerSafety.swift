import Foundation
import AVFoundation

extension ProfileTest {
    static func testCleanerSafety() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parrot-cleaner-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let system = directory.appendingPathComponent("system.caf")
            let mic = directory.appendingPathComponent(String(repeating: "m", count: 230) + ".caf")
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600) else {
                check("cleaner safety: allocate audio", false)
                return
            }
            buffer.frameLength = 1600
            for url in [system, mic] {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            let previous = try AudioQualityCleaner.cleanMeetingTracks(systemPath: system.path, micPath: nil)
            guard let previousPath = previous.cleanedSystemPath else {
                check("cleaner safety: previous audio exists", false)
                return
            }
            let previousBytes = try Data(contentsOf: URL(fileURLWithPath: previousPath))
            let meeting = Meeting(title: "Cleaner safety", systemAudioPath: system.path)
            meeting.cleanedSystemAudioPath = previousPath
            meeting.useCleanedAudio = true
            let before = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            var failed = false
            do {
                _ = try AudioQualityCleaner.cleanMeetingTracks(systemPath: system.path, micPath: mic.path)
            } catch {
                failed = true
            }
            let after = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            let currentBytes = try Data(contentsOf: URL(fileURLWithPath: previousPath))
            check("cleaner safety: second output failure preserves previous audio and reference", failed && before == after && previousBytes == currentBytes && meeting.effectiveSystemAudioPath == previousPath)
            var missingFailed = false
            do {
                _ = try AudioQualityCleaner.cleanMeetingTracks(systemPath: system.path, micPath: directory.appendingPathComponent("missing.caf").path)
            } catch {
                missingFailed = true
            }
            check("cleaner safety: missing expected input fails", missingFailed)
        } catch {
            check("cleaner safety: test setup and verification", false)
        }
    }
}

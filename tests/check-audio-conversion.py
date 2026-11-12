#!/usr/bin/env python3
"""Run with python3 tests/check-audio-conversion.py [AudioCaptureManager.swift]."""

from pathlib import Path
import re
import subprocess
import sys
import tempfile


if len(sys.argv) > 2:
    sys.exit(__doc__)
source = Path(sys.argv[1]) if len(sys.argv) == 2 else (
    Path(__file__).resolve().parents[1] / "Parrot/Services/AudioCaptureManager.swift"
)
expressions = re.findall(
    r"(?ms)^ {12}let frameCount = AVAudioFrameCount\(\n(.*?)^ {12}\)\n",
    source.read_text(),
)
if len(expressions) != 1:
    sys.exit("Mic converter capacity expression changed. Update this check before running it.")
capacity = expressions[0].strip().replace("self.sampleRate", "targetFormat.sampleRate")

fixture = r'''
import AVFoundation
import Foundation

var failures = 0
for sourceRate in [44100.0, 48000.0, 96000.0] {
    for blockFrames in [512, 1024, 2048] {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: sourceRate, channels: 1, interleaved: false)!
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 16000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)!
        let sourceFrames = blockFrames * Int(sourceRate * 60 / Double(blockFrames))
        var outputFrames = 0
        var lastSample: Float?
        var largestJump: Float = 0
        for start in stride(from: 0, to: sourceFrames, by: blockFrames) {
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                          frameCapacity: AVAudioFrameCount(blockFrames))!
            buffer.frameLength = buffer.frameCapacity
            for index in 0..<blockFrames {
                buffer.floatChannelData![0][index] = Float(
                    sin(2 * .pi * 997 * Double(start + index) / sourceRate)
                ) * 0.5
            }
            let frameCount = AVAudioFrameCount(__CAPACITY__)
            let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount)!
            var error: NSError?
            var consumed = false
            converter.convert(to: converted, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            if let error { fatalError("Conversion failed: \(error)") }
            for index in 0..<Int(converted.frameLength) {
                let sample = converted.floatChannelData![0][index]
                if let lastSample, outputFrames > 1000 {
                    largestJump = max(largestJump, abs(sample - lastSample))
                }
                lastSample = sample
                outputFrames += 1
            }
        }
        // The converter retains a few filter-delay samples until end-of-stream.
        let missing = Double(sourceFrames) * 16000 / sourceRate - Double(outputFrames)
        let passed = missing >= 0 && missing < 16 && largestJump < 0.21
        if !passed { failures += 1 }
        print(String(format: "%@ %.0f Hz, %d-frame buffers: missing %.2f frames, largest jump %.4f",
                     passed ? "PASS" : "FAIL", sourceRate, blockFrames, missing, largestJump))
    }
}
exit(failures == 0 ? 0 : 1)
'''

with tempfile.TemporaryDirectory(prefix="sakviro-audio-check-") as directory:
    swift = Path(directory) / "Check.swift"
    executable = Path(directory) / "check"
    swift.write_text(fixture.replace("__CAPACITY__", capacity))
    subprocess.run(["swiftc", "-O", str(swift), "-o", str(executable)], check=True)
    sys.exit(subprocess.run([str(executable)]).returncode)

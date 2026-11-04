import AVFoundation
import FluidAudio
import Foundation

@main struct Benchmark {
    static func main() async throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard ParakeetTranscriber.isDownloaded else { fatalError("FluidAudio v3 model cache is incomplete") }
        let start = Date()
        let engine = try await ParakeetTranscriber.load { _ in }
        print("LOAD_SECONDS \(Date().timeIntervalSince(start))")
        for name in ["lt1", "en", "lt2", "mixed", "lt1", "en", "lt2", "mixed", "timeline"] {
            let file = try AVAudioFile(forReading: folder.appendingPathComponent(name + ".wav"))
            guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { fatalError("Expected 16 kHz mono PCM") }
            try file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { fatalError("Expected Float32 PCM") }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let duration = Double(samples.count) / 16000
            let started = Date()
            let text = try await engine.transcribe(samples, language: nil)
            let seconds = Date().timeIntervalSince(started)
            let entry: [String: Any] = ["case": name, "duration": duration, "seconds": seconds, "rtf": seconds / duration, "text": text]
            let encoded = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            print(String(decoding: encoded, as: UTF8.self))
            fflush(stdout)
        }
    }
}

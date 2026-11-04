import Foundation
import CoreVideo
import ImageIO
import ScreenCaptureKit

enum AudioCaptureManager {
    static func storageDirectory() -> URL { FileManager.default.temporaryDirectory }
}

@main
struct ScreenSamplerCheck {
    static func frame(_ value: UInt8, mark: Bool = false) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 128, 128, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixelBuffer = buffer!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
        memset(base, Int32(value), CVPixelBufferGetDataSize(pixelBuffer))
        if mark {
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 40..<48 { for x in 40..<48 {
                for channel in 0..<3 { bytes[y * row + x * 4 + channel] = 255 }
            } }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    @MainActor static func main() async throws {
        var activity = ScreenSourceActivity()
        precondition(!activity.update(.idle))
        precondition(activity.update(.complete))
        precondition(activity.update(.idle))
        precondition(!activity.update(.blank) && !activity.update(.idle))
        precondition(activity.update(.complete))
        precondition(!activity.update(.suspended) && !activity.update(.idle))
        precondition(activity.update(.complete))
        precondition(!activity.update(.stopped) && !activity.update(.idle))

        let sampler = ScreenFrameSampler(interval: 0.25)
        var received: [ScreenContext] = []
        var errors: [String] = []
        sampler.onContext = { received.append($0) }
        sampler.onError = { errors.append($0) }
        sampler.setEnabled(true)
        for _ in 0..<20 { sampler.submit(frame(10)) }
        try await Task.sleep(for: .milliseconds(650))
        precondition(received.count == 1 && received[0].text.isEmpty)
        sampler.submit(frame(10, mark: true))
        try await Task.sleep(for: .milliseconds(350))
        precondition(received.count == 2 && received[0].jpeg != received[1].jpeg)
        sampler.submit(frame(30))
        try await Task.sleep(for: .milliseconds(40))
        sampler.submit(frame(80))
        sampler.submit(frame(120))
        try await Task.sleep(for: .milliseconds(650))
        let tail = received.last!.jpeg
        let count = received.count
        sampler.invalidate()
        sampler.submit(frame(120))
        try await Task.sleep(for: .milliseconds(350))
        precondition(received.count == count + 1 && received.last!.jpeg == tail)
        sampler.submit(frame(30))
        sampler.setEnabled(false)
        let pausedCount = received.count
        try await Task.sleep(for: .milliseconds(350))
        precondition(received.count == pausedCount && errors.isEmpty)
        let observed = Date()
        sampler.markObserved(at: observed)
        sampler.setEnabled(true)
        try await Task.sleep(for: .milliseconds(350))
        precondition(received.count == pausedCount + 1)
        precondition(received.last!.capturedAt <= observed.timeIntervalSince1970 && received.last!.observedAt == observed.timeIntervalSince1970)
        sampler.submit(frame(200))
        sampler.stop()
        try await Task.sleep(for: .milliseconds(350))
        precondition(received.count == pausedCount + 1 && errors.isEmpty)
        print("PASS screen sampler dedup, small change, pending tail, pause, resume, invalidation, stop, activity")
    }
}

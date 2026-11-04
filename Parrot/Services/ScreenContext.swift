import Foundation
import ImageIO

struct ScreenContext: Codable, Sendable {
    var jpeg: Data?
    var text: String
    var capturedAt: TimeInterval
    var sourceLabel: String
    var observedAt: TimeInterval

    init(jpeg: Data?, text: String, capturedAt: TimeInterval, sourceLabel: String, observedAt: TimeInterval? = nil) {
        self.jpeg = jpeg
        self.text = text
        self.capturedAt = capturedAt
        self.sourceLabel = sourceLabel
        self.observedAt = observedAt ?? capturedAt
    }

    static let maxJPEGBytes = 512_000

    static func validateJPEG(_ jpeg: Data) -> Bool {
        guard !jpeg.isEmpty, jpeg.count <= maxJPEGBytes,
              let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return false }
        return true
    }
}

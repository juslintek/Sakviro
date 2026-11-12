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
        !jpeg.isEmpty && jpeg.count <= maxJPEGBytes && jpeg.count >= 4
            && jpeg[jpeg.startIndex] == 0xFF && jpeg[jpeg.startIndex + 1] == 0xD8
    }
}

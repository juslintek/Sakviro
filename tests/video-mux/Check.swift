import AVFoundation
import Foundation

final class AudioCaptureManager {
    static func storageDirectory() -> URL { FileManager.default.temporaryDirectory }
}

@main
struct Check {
    static func main() async throws {
        let args = CommandLine.arguments
        let output = URL(fileURLWithPath: args[4])
        try await VideoCaptureService.mux(video: URL(fileURLWithPath: args[1]), offset: 0.2,
                                          audio: [URL(fileURLWithPath: args[2]), URL(fileURLWithPath: args[3])], destination: output)
        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        guard !video.isEmpty, !audio.isEmpty, duration > 1.0 else { fatalError("Missing video or audio, or duration too short") }
        let owned = VideoCaptureService.ownedURL(FileManager.default.temporaryDirectory.appendingPathComponent("video_test.mp4").path)
        guard owned != nil, VideoCaptureService.ownedURL("/tmp/external.mp4") == nil else { fatalError("Invalid owned file handling") }
        print("PASS video mux tracks, duration and owned paths")
    }
}

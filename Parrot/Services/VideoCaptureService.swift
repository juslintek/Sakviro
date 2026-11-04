import AVFoundation
import CoreMedia
import ScreenCaptureKit

final class VideoCaptureService: NSObject, SCContentSharingPickerObserver, SCStreamOutput, SCStreamDelegate {
    static let enabledKey = "recordVideo"
    private let queue = DispatchQueue(label: "parrot.video")
    private var selection: CheckedContinuation<SCContentFilter?, Error>?
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstTime: CMTime?
    private var failure: Error?
    private var outputURL: URL?
    private var audioOrigin: TimeInterval = 0
    var onError: ((String) -> Void)?

    @MainActor
    func chooseSource() async throws -> SCContentFilter? {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleDisplay]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        return try await withCheckedThrowingContinuation { continuation in
            selection = continuation
            picker.present()
        }
    }

    private func finishSelection(_ result: Result<SCContentFilter?, Error>) {
        DispatchQueue.main.async {
            let picker = SCContentSharingPicker.shared
            picker.remove(self)
            picker.isActive = false
            self.selection?.resume(with: result)
            self.selection = nil
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        finishSelection(.success(nil))
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        finishSelection(.success(filter))
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        finishSelection(.failure(error))
    }

    func start(filter: SCContentFilter, audioOrigin: TimeInterval) async throws {
        let scale = CGFloat(filter.pointPixelScale)
        let width = max(2, Int(filter.contentRect.width * scale) / 2 * 2)
        let height = max(2, Int(filter.contentRect.height * scale) / 2 * 2)
        let url = AudioCaptureManager.storageDirectory().appendingPathComponent("video_\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw VideoError.writer }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoError.writer }
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.capturesAudio = false
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.writer = writer
        self.input = input
        self.stream = stream
        self.outputURL = url
        self.audioOrigin = audioOrigin
        do { try await stream.startCapture() } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            self.stream = nil
            throw error
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: status) == .complete,
              let input, let writer, writer.status == .writing else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstTime == nil {
            firstTime = timestamp
            writer.startSession(atSourceTime: timestamp)
        }
        if input.isReadyForMoreMediaData, !input.append(sampleBuffer) {
            let error = writer.error ?? VideoError.writer
            failure = error
            onError?(error.localizedDescription)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            self.failure = error
            self.onError?(error.localizedDescription)
        }
    }

    func stop() async throws -> (URL, TimeInterval) {
        if let stream {
            do { try await stream.stopCapture() }
            catch { queue.async { self.failure = error } }
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let writer = self.writer, let input = self.input, let url = self.outputURL,
                      let first = self.firstTime else {
                    self.writer?.cancelWriting()
                    if let url = self.outputURL { try? FileManager.default.removeItem(at: url) }
                    continuation.resume(throwing: self.failure ?? VideoError.noFrames)
                    return
                }
                input.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        let offset = max(0, CMTimeGetSeconds(first) - self.audioOrigin)
                        if let failure = self.failure {
                            continuation.resume(throwing: VideoError.partial(url, offset, failure.localizedDescription))
                        } else {
                            continuation.resume(returning: (url, offset))
                        }
                    } else {
                        continuation.resume(throwing: writer.error ?? self.failure ?? VideoError.writer)
                    }
                }
            }
        }
    }

    static func mux(video: URL, offset: TimeInterval, audio: [URL], destination: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        guard let source = try await videoAsset.loadTracks(withMediaType: .video).first,
              let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw VideoError.noFrames }
        let duration = try await videoAsset.load(.duration)
        try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source,
                                   at: CMTime(seconds: offset, preferredTimescale: 600))
        for url in audio where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let length = try await asset.load(.duration)
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: .zero)
        }
        guard !composition.tracks(withMediaType: .audio).isEmpty,
              let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw VideoError.noAudio }
        let mix = AVMutableAudioMix()
        mix.inputParameters = composition.tracks(withMediaType: .audio).map { AVMutableAudioMixInputParameters(track: $0) }
        export.audioMix = mix
        export.outputURL = destination
        export.outputFileType = .mp4
        await export.export()
        guard export.status == .completed else { throw export.error ?? VideoError.writer }
    }

    static func ownedURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let directory = AudioCaptureManager.storageDirectory().standardizedFileURL
        guard url.deletingLastPathComponent() == directory, url.lastPathComponent.hasPrefix("video_") else { return nil }
        return url
    }

    enum VideoError: LocalizedError {
        case writer, noFrames, noAudio
        case partial(URL, TimeInterval, String)
        var errorDescription: String? {
            switch self {
            case .writer: return "Video could not be written."
            case .noFrames: return "Video capture produced no frames."
            case .noAudio: return "No audio tracks were available for the video."
            case .partial(_, _, let reason): return "Video capture stopped early: \(reason)"
            }
        }
    }
}

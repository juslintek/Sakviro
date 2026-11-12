import AVFoundation
import CoreMedia
import ScreenCaptureKit
import CoreImage
import CryptoKit
import VideoToolbox

enum VideoArchivePreset: String, CaseIterable, Identifiable {
    case compact720p10
    case efficient1080p15
    case sharp1440p24
    case native30

    static let defaultsKey = "videoArchivePreset"

    static var current: VideoArchivePreset {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let preset = VideoArchivePreset(rawValue: raw) else {
            return .efficient1080p15
        }
        return preset
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact720p10: "720p · 10 FPS (Minimal CPU)"
        case .efficient1080p15: "1080p · 15 FPS (Recommended, Default)"
        case .sharp1440p24: "1440p · 24 FPS"
        case .native30: "Native Retina · 30 FPS"
        }
    }

    var maxDimension: CGFloat {
        switch self {
        case .compact720p10: 1280
        case .efficient1080p15: 1920
        case .sharp1440p24: 2560
        case .native30: 3840
        }
    }

    var fps: Int {
        switch self {
        case .compact720p10: 10
        case .efficient1080p15: 15
        case .sharp1440p24: 24
        case .native30: 30
        }
    }

    var bitrate: Int {
        switch self {
        case .compact720p10: 800_000
        case .efficient1080p15: 1_500_000
        case .sharp1440p24: 3_000_000
        case .native30: 6_000_000
        }
    }
}

struct ScreenSourceActivity {
    private(set) var active = false

    mutating func update(_ status: SCFrameStatus) -> Bool {
        switch status {
        case .complete: active = true
        case .blank, .suspended, .stopped: active = false
        default: break
        }
        return active && (status == .complete || status == .idle)
    }
}

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
    var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    var onInactive: (() -> Void)?
    var onActivity: ((Date) -> Void)?
    private var sourceActivity = ScreenSourceActivity()
    private var acceptingFrames = true
    private var lastActivityReportedAt: Date = .distantPast

    @MainActor
    func chooseSource(windowOnly: Bool = false) async throws -> SCContentFilter? {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = windowOnly ? [.singleWindow] : [.singleWindow, .singleDisplay]
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

    func start(filter: SCContentFilter, audioOrigin: TimeInterval, archive: Bool = true) async throws {
        lastActivityReportedAt = .distantPast
        let preset = VideoArchivePreset.current
        let scale = CGFloat(filter.pointPixelScale)
        let sourceWidth = filter.contentRect.width * scale
        let sourceHeight = filter.contentRect.height * scale
        let maxDim = archive ? preset.maxDimension : 1280
        let reduction = min(1, maxDim / max(sourceWidth, sourceHeight))
        let width = max(2, Int(sourceWidth * reduction) & ~1)
        let height = max(2, Int(sourceHeight * reduction) & ~1)
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(archive ? preset.fps : 2))
        config.queueDepth = archive ? 3 : 2
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.capturesAudio = false
        if !archive {
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            self.stream = stream
            self.audioOrigin = audioOrigin
            do { try await stream.startCapture() } catch { self.stream = nil; throw error }
            return
        }
        let url = AudioCaptureManager.storageDirectory().appendingPathComponent("video_\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: preset.bitrate,
            AVVideoExpectedSourceFrameRateKey: preset.fps,
            AVVideoMaxKeyFrameIntervalKey: preset.fps * 4,
            kVTCompressionPropertyKey_RealTime as String: true
        ]
        var input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProps
        ])
        input.expectsMediaDataInRealTime = true
        if !writer.canAdd(input) {
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: compressionProps
            ])
            input.expectsMediaDataInRealTime = true
        }
        guard writer.canAdd(input) else { throw VideoError.writer }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoError.writer }
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
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        guard stream === self.stream, acceptingFrames else { return }
        if status == .blank || status == .suspended || status == .stopped {
            _ = sourceActivity.update(status)
            onInactive?()
            return
        }
        if status == .idle {
            if sourceActivity.update(status) {
                let now = Date()
                if now.timeIntervalSince(lastActivityReportedAt) >= 1.0 {
                    lastActivityReportedAt = now
                    onActivity?(now)
                }
            }
            return
        }
        guard status == .complete, CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        let now = Date()
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let age = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), presentation))
        if age.isFinite, age >= 0 {
            _ = sourceActivity.update(status)
            if now.timeIntervalSince(lastActivityReportedAt) >= 1.0 {
                lastActivityReportedAt = now
                onActivity?(now)
            }
            onFrame?(pixelBuffer, now.timeIntervalSince1970 - age)
        } else {
            _ = sourceActivity.update(.stopped)
            onInactive?()
        }
        guard let input, let writer, writer.status == .writing else { return }
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
            guard stream === self.stream, self.acceptingFrames else { return }
            _ = self.sourceActivity.update(.stopped)
            self.failure = error
            self.onInactive?()
            self.onError?(error.localizedDescription)
        }
    }

    func stop() async throws -> (URL, TimeInterval) {
        await deactivateSource()
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

    func stopWatching() async throws {
        await deactivateSource()
        if let stream { try await stream.stopCapture() }
        await withCheckedContinuation { continuation in
            queue.async {
                self.onFrame = nil
                continuation.resume()
            }
        }
        if let failure { throw failure }
    }

    private func deactivateSource() async {
        await withCheckedContinuation { continuation in
            queue.async {
                _ = self.sourceActivity.update(.stopped)
                self.acceptingFrames = false
                self.onInactive?()
                self.onFrame = nil
                self.onActivity = nil
                continuation.resume()
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
        let audioTracks = composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw VideoError.noAudio }
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.map { AVMutableAudioMixInputParameters(track: $0) }
        let formatHint = try? await source.load(.formatDescriptions).first
        if await fastMux(composition: composition, videoTrack: target, audioTracks: audioTracks, audioMix: mix, formatHint: formatHint, destination: destination) {
            return
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw VideoError.noAudio }
        export.audioMix = mix
        export.outputURL = destination
        export.outputFileType = .mp4
        await export.export()
        guard export.status == .completed else { throw export.error ?? VideoError.writer }
    }

    private static func fastMux(
        composition: AVMutableComposition,
        videoTrack: AVCompositionTrack,
        audioTracks: [AVCompositionTrack],
        audioMix: AVMutableAudioMix,
        formatHint: CMFormatDescription?,
        destination: URL
    ) async -> Bool {
        guard let formatHint else { return false }
        try? FileManager.default.removeItem(at: destination)
        guard let reader = try? AVAssetReader(asset: composition),
              let writer = try? AVAssetWriter(outputURL: destination, fileType: .mp4) else {
            return false
        }
        let videoOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOut.alwaysCopiesSampleData = false
        let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        audioOut.audioMix = audioMix
        audioOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut), reader.canAdd(audioOut) else { return false }
        reader.add(videoOut)
        reader.add(audioOut)

        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formatHint)
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96000
        ])
        guard writer.canAdd(videoIn), writer.canAdd(audioIn) else { return false }
        writer.add(videoIn)
        writer.add(audioIn)

        guard writer.startWriting(), reader.startReading() else {
            writer.cancelWriting()
            reader.cancelReading()
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await pump(output: videoOut, input: videoIn, queueLabel: "parrot.mux.video")
            }
            group.addTask {
                await pump(output: audioOut, input: audioIn, queueLabel: "parrot.mux.audio")
            }
        }

        guard reader.status == .completed else {
            writer.cancelWriting()
            reader.cancelReading()
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        await writer.finishWriting()
        if writer.status == .completed {
            return true
        } else {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
    }

    private static func pump(output: AVAssetReaderOutput, input: AVAssetWriterInput, queueLabel: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let q = DispatchQueue(label: queueLabel)
            var finished = false
            input.requestMediaDataWhenReady(on: q) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    if let sample = output.copyNextSampleBuffer() {
                        if !input.append(sample) {
                            finished = true
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }
                    } else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
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

final class ScreenFrameSampler {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "parrot.screen-sampler", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let interval: TimeInterval
    private var enabled = false
    private var stopped = false
    private var busy = false
    private var scheduled: DispatchWorkItem?
    private var current: (CVPixelBuffer, TimeInterval)?
    private var pending: (CVPixelBuffer, TimeInterval)?
    private var hasSeenFrame = false
    private var observedAt: TimeInterval?
    private var lastSample: TimeInterval = 0
    private var lastDigest: SHA256.Digest?
    private var generation = 0
    var onContext: ((ScreenContext) -> Void)?
    var onError: ((String) -> Void)?

    init(interval: TimeInterval = 5, onSample: ((ScreenContext) -> Void)? = nil, onError: ((String) -> Void)? = nil) {
        self.interval = interval
        self.onContext = onSample
        self.onError = onError
    }

    func submit(_ buffer: CVPixelBuffer, capturedAt: TimeInterval = Date.now.timeIntervalSince1970) {
        let now = Date.now.timeIntervalSince1970
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        hasSeenFrame = true
        observedAt = now
        guard enabled else { return }
        if lastSample > 0, now - lastSample < max(0, interval - 0.25) {
            return
        }
        current = (buffer, capturedAt)
        pending = (buffer, capturedAt)
        scheduleLocked()
    }

    func markObserved(at date: Date) {
        lock.lock()
        if !stopped, hasSeenFrame { observedAt = date.timeIntervalSince1970 }
        lock.unlock()
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, self.enabled != enabled else { return }
        self.enabled = enabled
        generation += 1
        scheduled?.cancel()
        scheduled = nil
        pending = enabled ? current : nil
        if !enabled { current = nil }
        lastDigest = nil
        lastSample = 0
        if enabled { scheduleLocked() }
    }

    func invalidate() {
        lock.lock()
        generation += 1
        scheduled?.cancel()
        scheduled = nil
        current = nil
        pending = nil
        hasSeenFrame = false
        observedAt = nil
        lastDigest = nil
        lastSample = 0
        lock.unlock()
    }

    func stop() {
        lock.lock()
        stopped = true
        enabled = false
        generation += 1
        scheduled?.cancel()
        scheduled = nil
        current = nil
        pending = nil
        hasSeenFrame = false
        observedAt = nil
        lastDigest = nil
        lock.unlock()
    }

    private func scheduleLocked() {
        guard enabled, !stopped, !busy, scheduled == nil, pending != nil else { return }
        let taskGeneration = generation
        let task = DispatchWorkItem { [weak self] in self?.processLatest(generation: taskGeneration) }
        scheduled = task
        queue.asyncAfter(deadline: .now() + max(0, interval - (Date.now.timeIntervalSince1970 - lastSample)), execute: task)
    }

    private func encodeJPEG(_ buffer: CVPixelBuffer) -> Data? {
        var image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        let scale = min(1.0, 1280.0 / max(extent.width, extent.height))
        if scale < 1.0 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        let colourSpace = CGColorSpaceCreateDeviceRGB()
        var jpeg = context.jpegRepresentation(
            of: image,
            colorSpace: colourSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.65]
        )
        if let current = jpeg, current.count > ScreenContext.maxJPEGBytes {
            jpeg = context.jpegRepresentation(
                of: image,
                colorSpace: colourSpace,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.40]
            )
        }
        return jpeg
    }

    private func processLatest(generation taskGeneration: Int) {
        lock.lock()
        guard !stopped, enabled, generation == taskGeneration else { lock.unlock(); return }
        scheduled = nil
        guard let (buffer, capturedAt) = pending else { lock.unlock(); return }
        pending = nil
        current = nil
        busy = true
        lastSample = Date.now.timeIntervalSince1970
        lock.unlock()

        let jpeg = encodeJPEG(buffer)
        let validJPEG = jpeg.flatMap { ScreenContext.validateJPEG($0) ? $0 : nil }
        let digest = validJPEG.map { SHA256.hash(data: $0) }
        lock.lock()
        let active = !stopped && enabled && generation == taskGeneration
        let changed = active && digest != nil && digest != lastDigest
        if changed { lastDigest = digest }
        let observation = observedAt ?? capturedAt
        busy = false
        scheduleLocked()
        lock.unlock()

        guard active else { return }
        let screen = validJPEG.map { ScreenContext(jpeg: $0, text: "", capturedAt: capturedAt, sourceLabel: "Selected screen", observedAt: observation) }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let active = !self.stopped && self.enabled && self.generation == taskGeneration
            let observation = self.observedAt
            self.lock.unlock()
            guard active else { return }
            if var screen, changed {
                screen.observedAt = observation ?? screen.observedAt
                self.onContext?(screen)
            }
            else if screen == nil { self.onError?("Could not prepare the selected screen frame.") }
        }
    }
}

import AVFoundation
import CoreMedia
import ScreenCaptureKit
import CoreImage
import CryptoKit
import VideoToolbox
import Vision

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

enum VideoCaptureTargetMode: String, CaseIterable, Identifiable, Sendable {
    case any
    case window
    case application
    case display

    var id: String { rawValue }
    static let defaultsKey = "videoCaptureTargetMode"

    static var current: VideoCaptureTargetMode {
        VideoCaptureTargetMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .any
    }

    var label: String {
        switch self {
        case .any: "Window, App or Screen"
        case .window: "Single Window"
        case .application: "Application"
        case .display: "Full Screen"
        }
    }

    var pickerModes: SCContentSharingPickerMode {
        switch self {
        case .any: [.singleWindow, .singleApplication, .singleDisplay]
        case .window: [.singleWindow]
        case .application: [.singleApplication]
        case .display: [.singleDisplay]
        }
    }

    var preferredPickerStyle: SCShareableContentStyle {
        switch self {
        case .window: .window
        case .application: .application
        case .display: .display
        case .any: .window
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
    static let showsCursorKey = "videoShowsCursor"
    static var showsCursor: Bool { UserDefaults.standard.object(forKey: showsCursorKey) as? Bool ?? true }

    private let queue = DispatchQueue(label: "parrot.video")
    private var selection: CheckedContinuation<SCContentFilter?, Error>?
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastWrittenPTS: CMTime?
    private var latestObservedPTS: CMTime?
    private var firstTime: CMTime?
    private var failure: Error?
    private var outputURL: URL?
    private var audioOrigin: TimeInterval = 0

    private(set) var targetSummary: String = "Selected screen"
    var onTargetChanged: ((String) -> Void)?
    private(set) var stoppedEarlyNote: String?

    var onError: ((String) -> Void)?
    var onFrame: ((CVPixelBuffer, TimeInterval) -> Void)?
    var onInactive: (() -> Void)?
    var onActivity: ((Date) -> Void)?
    private var sourceActivity = ScreenSourceActivity()
    private var acceptingFrames = true
    private var streamStopped = false
    private var lastActivityReportedAt: Date = .distantPast

    deinit {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
    }

    static func alignedDimension(_ raw: CGFloat, minimum: Int = 16) -> Int {
        let rounded = Int(raw.rounded())
        let aligned = (rounded + 8) & ~15
        return max(minimum, aligned)
    }

    static func describeFilter(_ filter: SCContentFilter) -> String {
        let scale = CGFloat(filter.pointPixelScale > 0 ? filter.pointPixelScale : 1)
        let w = Int((filter.contentRect.width * scale).rounded())
        let h = Int((filter.contentRect.height * scale).rounded())
        let dims = (w > 0 && h > 0) ? " · \(w)×\(h)" : ""
        if #available(macOS 14.0, *) {
            switch filter.style {
            case .window:
                return "Window\(dims)"
            case .application:
                return "Application\(dims)"
            case .display:
                return "Full Screen\(dims)"
            default:
                return "Selected screen\(dims)"
            }
        } else {
            return "Selected screen\(dims)"
        }
    }

    @MainActor
    func applySelectedTarget(summary: String, updateStreamWith filter: SCContentFilter? = nil) async {
        self.targetSummary = summary
        self.onTargetChanged?(summary)
        if let filter, let stream = self.stream {
            try? await stream.updateContentFilter(filter)
        }
    }

    @MainActor
    func presentSystemTargetPicker(mode: VideoCaptureTargetMode = .current) {
        let picker = SCContentSharingPicker.shared
        picker.isActive = true
        if let stream = self.stream {
            picker.present(for: stream, using: mode.preferredPickerStyle)
        } else {
            picker.present(using: mode.preferredPickerStyle)
        }
    }

    private func makePickerConfiguration(mode: VideoCaptureTargetMode = .current) -> SCContentSharingPickerConfiguration {
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = mode.pickerModes
        configuration.allowsChangingSelectedContent = true
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        return configuration
    }

    @MainActor
    func chooseWithSystemPicker(mode: VideoCaptureTargetMode) async throws -> SCContentFilter? {
        let picker = SCContentSharingPicker.shared
        picker.defaultConfiguration = makePickerConfiguration(mode: mode)
        picker.add(self)
        picker.isActive = true
        return try await withCheckedThrowingContinuation { continuation in
            selection = continuation
            picker.present(using: mode.preferredPickerStyle)
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        DispatchQueue.main.async {
            if let selection = self.selection {
                self.selection = nil
                picker.remove(self)
                picker.isActive = false
                selection.resume(returning: nil)
            }
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        DispatchQueue.main.async {
            let summary = Self.describeFilter(filter)
            self.targetSummary = summary
            self.onTargetChanged?(summary)
            if let selection = self.selection {
                self.selection = nil
                selection.resume(returning: filter)
            } else if let activeStream = self.stream {
                Task {
                    try? await activeStream.updateContentFilter(filter)
                }
            }
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        DispatchQueue.main.async {
            let picker = SCContentSharingPicker.shared
            if let selection = self.selection {
                self.selection = nil
                picker.remove(self)
                picker.isActive = false
                selection.resume(throwing: error)
            }
        }
    }

    func updateAudioOriginIfNeeded(_ firstSampleUptime: TimeInterval) {
        queue.sync {
            if firstSampleUptime > 0 {
                self.audioOrigin = firstSampleUptime
            }
        }
    }

    func start(filter: SCContentFilter, audioOrigin: TimeInterval, archive: Bool = true) async throws {
        lastActivityReportedAt = .distantPast
        if targetSummary.isEmpty || targetSummary == "Selected screen" {
            targetSummary = Self.describeFilter(filter)
        }
        onTargetChanged?(targetSummary)
        queue.sync {
            streamStopped = false
            acceptingFrames = true
            failure = nil
            stoppedEarlyNote = nil
            firstTime = nil
            lastPixelBuffer = nil
            lastWrittenPTS = nil
            latestObservedPTS = nil
        }
        let preset = VideoArchivePreset.current
        let scale = CGFloat(filter.pointPixelScale > 0 ? filter.pointPixelScale : 1)
        let sourceWidth = filter.contentRect.width * scale
        let sourceHeight = filter.contentRect.height * scale
        let maxDim = archive ? preset.maxDimension : 1280
        let reduction = min(1, maxDim / max(max(sourceWidth, sourceHeight), 1))
        let width = Self.alignedDimension(sourceWidth * reduction)
        let height = Self.alignedDimension(sourceHeight * reduction)
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.scalesToFit = true
        if #available(macOS 14.0, *) {
            config.preservesAspectRatio = true
        }
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = Self.showsCursor
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(archive ? preset.fps : 2))
        config.queueDepth = archive ? 3 : 2
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.capturesAudio = false
        if !archive {
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            SCContentSharingPicker.shared.setConfiguration(makePickerConfiguration(), for: stream)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            self.stream = stream
            self.audioOrigin = audioOrigin
            do {
                try await stream.startCapture()
            } catch {
                DispatchQueue.main.async {
                    let picker = SCContentSharingPicker.shared
                    picker.remove(self)
                    picker.isActive = false
                }
                self.stream = nil
                throw error
            }
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
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoError.writer }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        SCContentSharingPicker.shared.setConfiguration(makePickerConfiguration(), for: stream)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.stream = stream
        self.outputURL = url
        self.audioOrigin = audioOrigin
        do {
            try await stream.startCapture()
        } catch {
            DispatchQueue.main.async {
                let picker = SCContentSharingPicker.shared
                picker.remove(self)
                picker.isActive = false
            }
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            self.stream = nil
            self.writer = nil
            self.input = nil
            self.adaptor = nil
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
            let idlePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            latestObservedPTS = idlePTS
            if let input, let writer, writer.status == .writing, let adaptor,
               let pb = self.lastPixelBuffer, let lastPTS = self.lastWrittenPTS,
               CMTimeGetSeconds(idlePTS - lastPTS) >= 1.0 {
                if input.isReadyForMoreMediaData {
                    if adaptor.append(pb, withPresentationTime: idlePTS) {
                        self.lastWrittenPTS = idlePTS
                    }
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
        guard let input, let writer, writer.status == .writing, let adaptor else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstTime == nil {
            firstTime = pts
            writer.startSession(atSourceTime: pts)
        }
        if input.isReadyForMoreMediaData {
            if let lastPTS = lastWrittenPTS {
                guard pts > lastPTS else { return }
            }
            if adaptor.append(pixelBuffer, withPresentationTime: pts) {
                lastPixelBuffer = pixelBuffer
                lastWrittenPTS = pts
                latestObservedPTS = pts
            } else {
                let error = writer.error ?? VideoError.writer
                failure = error
                onError?(error.localizedDescription)
            }
        }
    }

    static func isBenignStreamStopError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.code == SCStreamError.attemptToStopStreamState.rawValue || ns.code == -3808 {
            if ns.domain == SCStreamErrorDomain || ns.domain == "com.apple.ScreenCaptureKit" {
                return true
            }
        }
        let desc = error.localizedDescription.lowercased()
        if desc.contains("already stopped or does not exist") {
            return true
        }
        return false
    }

    static func isTargetClosedStopError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.code == SCStreamError.userStopped.rawValue || ns.code == -3817 {
            return true
        }
        if #available(macOS 15.0, *) {
            if ns.code == SCStreamError.systemStoppedStream.rawValue {
                return true
            }
        }
        if ns.code == -3807 || ns.code == -3821 {
            return true
        }
        let desc = error.localizedDescription.lowercased()
        if desc.contains("user stopped") || desc.contains("system stopped") || desc.contains("no longer available") {
            return true
        }
        return false
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard stream === self.stream else { return }
            self.streamStopped = true
            guard self.acceptingFrames else { return }
            _ = self.sourceActivity.update(.stopped)
            if Self.isBenignStreamStopError(error) {
                return
            }
            if Self.isTargetClosedStopError(error) {
                self.stoppedEarlyNote = "Video ended early when the shared window or app closed."
                self.onInactive?()
                return
            }
            self.failure = error
            self.onInactive?()
            self.onError?(error.localizedDescription)
        }
    }

    func stop() async throws -> (URL, TimeInterval) {
        let shouldStopStream: Bool = await withCheckedContinuation { continuation in
            queue.async {
                _ = self.sourceActivity.update(.stopped)
                self.acceptingFrames = false
                self.onInactive?()
                self.onFrame = nil
                self.onActivity = nil
                let shouldStop = self.stream != nil && !self.streamStopped
                self.streamStopped = true
                continuation.resume(returning: shouldStop)
            }
        }
        DispatchQueue.main.async {
            let picker = SCContentSharingPicker.shared
            picker.remove(self)
            picker.isActive = false
        }
        if shouldStopStream, let stream {
            do {
                try await stream.stopCapture()
            } catch {
                if !Self.isBenignStreamStopError(error) && !Self.isTargetClosedStopError(error) {
                    queue.async {
                        if self.failure == nil { self.failure = error }
                    }
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let writer = self.writer, let input = self.input, let url = self.outputURL,
                      let first = self.firstTime else {
                    self.writer?.cancelWriting()
                    self.stream = nil
                    self.writer = nil
                    self.input = nil
                    self.adaptor = nil
                    self.lastPixelBuffer = nil
                    if let url = self.outputURL { try? FileManager.default.removeItem(at: url) }
                    continuation.resume(throwing: self.failure ?? VideoError.noFrames)
                    return
                }
                if let adaptor = self.adaptor, let pb = self.lastPixelBuffer, let lastPTS = self.lastWrittenPTS {
                    let endPTS = CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 600)
                    let totalSeconds = CMTimeGetSeconds(endPTS - first)
                    let deltaSeconds = CMTimeGetSeconds(endPTS - lastPTS)
                    let quarterSecond = CMTime(seconds: 0.25, preferredTimescale: 600)
                    if endPTS > (lastPTS + quarterSecond),
                       totalSeconds < 12 * 3600, totalSeconds >= 0,
                       deltaSeconds >= 0.5,
                       input.isReadyForMoreMediaData {
                        if adaptor.append(pb, withPresentationTime: endPTS) {
                            self.lastWrittenPTS = endPTS
                        }
                    }
                }
                input.markAsFinished()
                writer.finishWriting {
                    self.stream = nil
                    self.writer = nil
                    self.input = nil
                    self.adaptor = nil
                    self.lastPixelBuffer = nil
                    if writer.status == .completed {
                        let rawOffset = self.audioOrigin > 0 ? (CMTimeGetSeconds(first) - self.audioOrigin) : 0
                        let offset = rawOffset.isFinite ? rawOffset : 0
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
        let shouldStopStream: Bool = await withCheckedContinuation { continuation in
            queue.async {
                _ = self.sourceActivity.update(.stopped)
                self.acceptingFrames = false
                self.onInactive?()
                self.onFrame = nil
                self.onActivity = nil
                let shouldStop = self.stream != nil && !self.streamStopped
                self.streamStopped = true
                continuation.resume(returning: shouldStop)
            }
        }
        DispatchQueue.main.async {
            let picker = SCContentSharingPicker.shared
            picker.remove(self)
            picker.isActive = false
        }
        if shouldStopStream, let stream {
            do {
                try await stream.stopCapture()
            } catch {
                if !Self.isBenignStreamStopError(error) && !Self.isTargetClosedStopError(error) {
                    queue.async { if self.failure == nil { self.failure = error } }
                }
            }
        }
        queue.sync {
            self.stream = nil
            self.lastPixelBuffer = nil
        }
        if let failure, !Self.isBenignStreamStopError(failure) && !Self.isTargetClosedStopError(failure) {
            throw failure
        }
    }

    static func mux(video: URL, offset: TimeInterval, audio: [URL], destination: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        guard let source = try await videoAsset.loadTracks(withMediaType: .video).first,
              let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw VideoError.noFrames }
        let duration = try await videoAsset.load(.duration)
        let videoStartTime = offset >= 0 ? CMTime(seconds: offset, preferredTimescale: 600) : .zero
        let audioStartTime = offset < 0 ? CMTime(seconds: -offset, preferredTimescale: 600) : .zero

        try target.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: videoStartTime)
        for url in audio where FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let length = try await asset.load(.duration)
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: source, at: audioStartTime)
        }
        let audioTracks = composition.tracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw VideoError.noAudio }
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioTracks.map { track in
            let params = AVMutableAudioMixInputParameters(track: track)
            if audioTracks.count >= 2 {
                params.setVolume(0.80, at: .zero)
            }
            return params
        }
        let formatHint = try? await source.load(.formatDescriptions).first
        if await fastMux(composition: composition, videoTrack: target, audioTracks: audioTracks, audioMix: mix, formatHint: formatHint, destination: destination) {
            return
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw VideoError.noAudio }
        export.audioMix = mix
        export.outputURL = destination
        export.outputFileType = .mp4
        do {
            await export.export()
            guard export.status == .completed else {
                try? FileManager.default.removeItem(at: destination)
                throw export.error ?? VideoError.writer
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func remuxReplacingAudio(videoFile: URL, offset: TimeInterval, audio: [URL]) async throws {
        let dir = videoFile.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent("remux_\(UUID().uuidString).mp4")
        do {
            try await mux(video: videoFile, offset: offset, audio: audio, destination: tempURL)
            _ = try FileManager.default.replaceItemAt(videoFile, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
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

    static func recognizeScreenText(in image: CGImage, maxCharacters: Int = 3200) -> String {
        ScreenFrameSampler.recognizeScreenText(in: image, maxCharacters: maxCharacters)
    }
}

final class ScreenFrameSampler {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "parrot.screen-sampler", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let interval: TimeInterval
    var sourceLabel: String
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

    init(interval: TimeInterval = 5, sourceLabel: String = "Selected screen", onSample: ((ScreenContext) -> Void)? = nil, onError: ((String) -> Void)? = nil) {
        self.interval = interval
        self.sourceLabel = sourceLabel
        self.onContext = onSample
        self.onError = onError
    }

    private static func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let format = CVPixelBufferGetPixelFormatType(source)
        var destination: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height, format, nil, &destination)
        guard status == kCVReturnSuccess, let destination else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }

        if CVPixelBufferIsPlanar(source) {
            let count = CVPixelBufferGetPlaneCount(source)
            for plane in 0..<count {
                guard let srcAddr = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dstAddr = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { continue }
                let srcBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                let planeHeight = CVPixelBufferGetHeightOfPlane(source, plane)
                let bytesToCopy = min(srcBytesPerRow, dstBytesPerRow)
                for y in 0..<planeHeight {
                    memcpy(dstAddr.advanced(by: y * dstBytesPerRow), srcAddr.advanced(by: y * srcBytesPerRow), bytesToCopy)
                }
            }
        } else {
            guard let srcAddr = CVPixelBufferGetBaseAddress(source),
                  let dstAddr = CVPixelBufferGetBaseAddress(destination) else { return nil }
            let srcBytesPerRow = CVPixelBufferGetBytesPerRow(source)
            let dstBytesPerRow = CVPixelBufferGetBytesPerRow(destination)
            let bytesToCopy = min(srcBytesPerRow, dstBytesPerRow)
            for y in 0..<height {
                memcpy(dstAddr.advanced(by: y * dstBytesPerRow), srcAddr.advanced(by: y * srcBytesPerRow), bytesToCopy)
            }
        }

        return destination
    }

    func submit(_ buffer: CVPixelBuffer, capturedAt: TimeInterval = Date.now.timeIntervalSince1970, sourceLabel: String? = nil) {
        let now = Date.now.timeIntervalSince1970
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        hasSeenFrame = true
        observedAt = now
        if let sourceLabel { self.sourceLabel = sourceLabel }
        guard enabled else {
            let safeBuffer = Self.copyPixelBuffer(buffer) ?? buffer
            current = (safeBuffer, capturedAt)
            lock.unlock()
            return
        }
        if lastSample > 0, now - lastSample < max(0, interval - 0.25) {
            lock.unlock()
            return
        }
        let safeBuffer = Self.copyPixelBuffer(buffer) ?? buffer
        current = (safeBuffer, capturedAt)
        pending = (safeBuffer, capturedAt)
        scheduleLocked()
        lock.unlock()
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

    static func recognizeScreenText(in image: CGImage, maxCharacters: Int = 3200) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let observations = request.results else { return "" }
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if joined.count > maxCharacters {
                return String(joined.prefix(maxCharacters))
            }
            return joined
        } catch {
            return ""
        }
    }

    private func makeCGImage(_ buffer: CVPixelBuffer) -> CGImage? {
        var image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        let scale = min(1.0, 1280.0 / max(extent.width, extent.height))
        if scale < 1.0 {
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return context.createCGImage(image, from: image.extent)
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
        let label = sourceLabel
        busy = false
        scheduleLocked()
        lock.unlock()

        guard active else { return }

        var ocrText = ""
        if changed, let cgImage = makeCGImage(buffer) {
            ocrText = Self.recognizeScreenText(in: cgImage)
        }

        let screen = validJPEG.map { ScreenContext(jpeg: $0, text: ocrText, capturedAt: capturedAt, sourceLabel: label, observedAt: observation) }
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

import Foundation
import AppKit
import SwiftData
import AVFoundation
import CoreAudio
import CoreMedia
import ScreenCaptureKit

extension ProfileTest {
    @MainActor
    static func testStabilization() {
        // 1. TranscriptionJobProgress
        let now = Date(timeIntervalSince1970: 1000)
        let start = now.addingTimeInterval(-10)

        let clampLow = TranscriptionJobProgress(meetingID: UUID(), fraction: -0.2, stage: .diarizing, startedAt: start)
        check("progress: clamp below zero", clampLow.statusText == "Separating speakers… 0%")

        let clampHigh = TranscriptionJobProgress(meetingID: UUID(), fraction: 1.4, stage: .diarizing, startedAt: start)
        check("progress: clamp above one", clampHigh.statusText == "Separating speakers… 100%")

        let prep = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.5, stage: .preparingModel("Lithuanian Ąžuolas MLX"), startedAt: start)
        check("progress: preparingModel statusText", prep.statusText == "Loading Lithuanian Ąžuolas MLX… 50%")

        let trans = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.5, stage: .transcribing(trackLabel: "Mic", completedSeconds: 30, totalSeconds: 60), startedAt: start)
        check("progress: transcribing statusText", trans.statusText == "Transcribing Mic (30s / 60s) · 50%")

        let diar = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.5, stage: .diarizing, startedAt: start)
        check("progress: diarizing statusText", diar.statusText == "Separating speakers… 50%")

        let idx = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.5, stage: .indexingAndSaving, startedAt: start)
        check("progress: indexingAndSaving statusText", idx.statusText == "Indexing transcript… 50%")

        let upd = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.5, stage: .updatingReport, startedAt: start)
        check("progress: updatingReport statusText", upd.statusText == "Updating report… 50%")

        let lowFrac = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.04, stage: .diarizing, startedAt: start)
        check("progress: remaining nil when fraction < 0.05", lowFrac.estimatedRemaining(now: now) == nil)

        let recent = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.5, stage: .diarizing, startedAt: now.addingTimeInterval(-1.5))
        check("progress: remaining nil when elapsed < 2", recent.estimatedRemaining(now: now) == nil)

        let halfDone = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.5, stage: .diarizing, startedAt: start)
        let rem = halfDone.estimatedRemaining(now: now)
        check("progress: remaining 10s at fraction 0.5 after 10s", rem != nil && abs(rem! - 10.0) < 0.001)

        // 2. MLXTranscriber
        var loudSamples = [Float](repeating: 0.25, count: 560_000)
        let dipCenter = 25 * 16_000
        for i in (dipCenter - 3200)..<(dipCenter + 3200) {
            loudSamples[i] = 0.10
        }
        let boundary = try? MLXTranscriber.importBoundary(loudSamples, from: 0)
        check("mlx importBoundary: finds quiet boundary near dip", boundary != nil && abs(boundary! - dipCenter) <= 4800)

        let shortSamples = [Float](repeating: 0.25, count: 100_000)
        let shortBoundary = try? MLXTranscriber.importBoundary(shortSamples, from: 0)
        check("mlx importBoundary: short audio returns full count", shortBoundary == 100_000)

        check("mlx effectiveLanguage: azuolas auto is lt", MLXTranscriber.effectiveLanguage(for: "mlx-azuolas", selected: nil) == "lt"
              && MLXTranscriber.effectiveLanguage(for: "mlx-azuolas", selected: "auto") == "lt")
        check("mlx effectiveLanguage: paprika auto is lt", MLXTranscriber.effectiveLanguage(for: "mlx-paprika", selected: nil) == "lt"
              && MLXTranscriber.effectiveLanguage(for: "mlx-paprika", selected: "auto") == "lt")
        check("mlx effectiveLanguage: azuolas explicit en is en", MLXTranscriber.effectiveLanguage(for: "mlx-azuolas", selected: "en") == "en")
        check("mlx effectiveLanguage: parakeet auto is nil", MLXTranscriber.effectiveLanguage(for: "parakeet-v3", selected: "auto") == nil)

        // 3. CallDetector & BrowserCallInspector
        check("call detector: zoom is dedicated call app", CallDetector.isDedicatedCallApp("us.zoom.xos"))
        check("call detector: chrome is not dedicated call app", !CallDetector.isDedicatedCallApp("com.google.Chrome"))
        check("call detector: chrome is browser app", CallDetector.isBrowserApp("com.google.Chrome"))
        check("call detector: arc is browser app", CallDetector.isBrowserApp("company.thebrowser.Browser"))
        check("call detector: zoom is not browser app", !CallDetector.isBrowserApp("us.zoom.xos"))
        check("call detector: zoom is known meeting app", CallDetector.isKnownMeetingApp("us.zoom.xos"))
        check("call detector: chrome is known meeting app", CallDetector.isKnownMeetingApp("com.google.Chrome"))

        check("browser call inspector: google meet title", BrowserCallInspector.isMeetingWindowTitle("Meet - abc-defg-hij - Google Chrome"))
        check("browser call inspector: teams title", BrowserCallInspector.isMeetingWindowTitle("Weekly Sync | Microsoft Teams"))
        check("browser call inspector: zoom title", BrowserCallInspector.isMeetingWindowTitle("Zoom Meeting"))
        check("browser call inspector: slack huddle title", BrowserCallInspector.isMeetingWindowTitle("Slack - Huddle"))
        check("browser call inspector: gmail title is not meeting", !BrowserCallInspector.isMeetingWindowTitle("Gmail - Inbox"))
        check("browser call inspector: github title is not meeting", !BrowserCallInspector.isMeetingWindowTitle("GitHub Pull Requests"))
        check("browser call inspector: youtube title is not meeting", !BrowserCallInspector.isMeetingWindowTitle("YouTube"))

        // 4. CLIAnalysisProvider & AssistantRoutingSettings
        let agyRaw = "{\"event\":\"init\"}\n{\"event\":\"result\",\"result\":{\"status\":\"SUCCESS\",\"response\":\"Sveiki\",\"usage\":{\"input_tokens\":120,\"output_tokens\":15}}}"
        let agyParsed = try? CLIAnalysisProvider.parseCLIOutput(agyRaw, kind: .gemini, isAgy: true)
        check("cli parse: agy text response", agyParsed?.text == "Sveiki")
        check("cli parse: agy token usage", agyParsed?.inputTokens == 120 && agyParsed?.outputTokens == 15)

        let agyErrRaw = "{\"event\":\"result\",\"result\":{\"status\":\"ERROR\",\"error\":\"Service Unavailable\"}}"
        var agyThrew = false
        do {
            _ = try CLIAnalysisProvider.parseCLIOutput(agyErrRaw, kind: .gemini, isAgy: true)
        } catch {
            agyThrew = true
        }
        check("cli parse: agy error throws", agyThrew)

        let claudeRaw = "{\"type\":\"result\",\"result\":\"OK\",\"is_error\":false,\"usage\":{\"input_tokens\":50,\"output_tokens\":8}}"
        let claudeParsed = try? CLIAnalysisProvider.parseCLIOutput(claudeRaw, kind: .claudeCode)
        check("cli parse: claude text and tokens", claudeParsed?.text == "OK" && claudeParsed?.inputTokens == 50 && claudeParsed?.outputTokens == 8)

        let suite = "parrot-stabilization-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudGate.globalKey)
        defaults.set("", forKey: AssistantRoutingSettings.enabledKey)
        check("routing: fresh isolated defaults does not route locally", !AssistantRoutingSettings.routesLocally(in: defaults))
        AssistantRoutingSettings.setEnabled(true, kind: .ollama, defaults: defaults)
        check("routing: only ollama enabled routes locally", AssistantRoutingSettings.routesLocally(in: defaults))
        check("routing: availableKinds includes custom", AssistantRoutingSettings.availableKinds.contains(.custom))

        // 5. FloatingAssistantWidgetController
        let panel = KeyableFloatingPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: true)
        check("floating widget: panel canBecomeKey is true", panel.canBecomeKey == true)
        check("floating widget: panel canBecomeMain is false", panel.canBecomeMain == false)

        let prevAutoShow = UserDefaults.standard.object(forKey: "floatingWidgetAutoShow")
        UserDefaults.standard.set(false, forKey: "floatingWidgetAutoShow")
        defer {
            if let prevAutoShow {
                UserDefaults.standard.set(prevAutoShow, forKey: "floatingWidgetAutoShow")
            } else {
                UserDefaults.standard.removeObject(forKey: "floatingWidgetAutoShow")
            }
        }
        let widget = FloatingAssistantWidgetController.shared
        let manager = RecordingManager(memory: MeetingMemory(directory: nil), chats: AskChatStore(directory: nil))
        let meeting = Meeting(title: "Carryover Test")
        widget.draftNotes = "My draft notes"
        widget.onRecordingStarted(meeting: meeting, manager: manager)
        check("floating widget: draftNotes carries over into empty meeting notes", meeting.notes == "My draft notes")
        check("floating widget: draftNotes cleared after carryover", widget.draftNotes.isEmpty)

        meeting.notes = "Existing notes"
        widget.draftNotes = "Prepended draft"
        widget.onRecordingStarted(meeting: meeting, manager: manager)
        check("floating widget: draftNotes prepends when meeting notes exist", meeting.notes == "Prepended draft\n\nExisting notes")
        check("floating widget: draftNotes cleared after second carryover", widget.draftNotes.isEmpty)

        // 6. TranscriptionJobProgress & TranscriptionLogs
        check(
            "progress: displayModelName mlx-azuolas lt",
            TranscriptionJobProgress.displayModelName(modelID: "mlx-azuolas", backend: .local, language: "lt") == "Lithuanian Ąžuolas MLX (mlx-azuolas) · lt"
        )
        check(
            "progress: displayModelName parakeet-v3 nil",
            TranscriptionJobProgress.displayModelName(modelID: "parakeet-v3", backend: .local, language: nil) == "FluidAudio Parakeet v3"
        )
        check(
            "progress: displayModelName groq whisper lt",
            TranscriptionJobProgress.displayModelName(modelID: "whisper-large-v3-turbo", backend: .groq, language: "lt") == "Groq Whisper Large v3 Turbo · lt"
        )

        check("progress: formatTimestamp 134.2", TranscriptionJobProgress.formatTimestamp(134.2) == "02:14.2")
        check("progress: formatTimestamp 3725.4", TranscriptionJobProgress.formatTimestamp(3725.4) == "1:02:05.4")

        let intervalProg = TranscriptionJobProgress(
            meetingID: UUID(),
            fraction: 0.5,
            stage: .diarizing,
            startedAt: start,
            intervalStart: 134.2,
            intervalEnd: 161.8
        )
        check("progress: intervalText formatted", intervalProg.intervalText == "02:14.2 → 02:41.8")

        let intervalProgNil = TranscriptionJobProgress(
            meetingID: UUID(),
            fraction: 0.5,
            stage: .diarizing,
            startedAt: start,
            intervalStart: nil,
            intervalEnd: 161.8
        )
        check("progress: intervalText nil when start is nil", intervalProgNil.intervalText == nil)

        let logMid = UUID()
        let activeJob = TranscriptionJobProgress(
            meetingID: logMid,
            fraction: 0.1,
            stage: .transcribing(trackLabel: "System audio", completedSeconds: 0, totalSeconds: 100),
            startedAt: start,
            activeModel: "Initial",
            pipelineModels: ["Initial"]
        )
        manager.transcriptionJobs[logMid] = activeJob
        manager.appendTranscriptionLog(
            TranscriptionLogEntry(
                kind: .intervalSent,
                modelName: "Lithuanian Ąžuolas MLX (mlx-azuolas) · lt",
                trackLabel: "System audio",
                intervalStart: 12.5,
                intervalEnd: 34.0,
                sampleCount: 344_000,
                summary: "Sending"
            ),
            for: logMid
        )
        check(
            "manager: appendTranscriptionLog updates activeModel",
            manager.transcriptionJobs[logMid]?.activeModel == "Lithuanian Ąžuolas MLX (mlx-azuolas) · lt"
        )
        check(
            "manager: appendTranscriptionLog updates intervalText",
            manager.transcriptionJobs[logMid]?.intervalText == "00:12.5 → 00:34.0"
        )

        for i in 0..<505 {
            manager.appendTranscriptionLog(
                TranscriptionLogEntry(
                    kind: .lifecycle,
                    modelName: "Lithuanian Ąžuolas MLX (mlx-azuolas) · lt",
                    summary: "Entry \(i)"
                ),
                for: logMid
            )
        }
        check("manager: transcriptionLogs ring capped at 500", manager.transcriptionLogs[logMid]?.count == 500)

        manager.clearTranscriptionLog(for: logMid)
        check("manager: clearTranscriptionLog clears entries", manager.transcriptionLogs[logMid] == nil)

        // 7. Audio Cleanup & Video Capture Stabilization
        testAudioCleanupAndVideoCapture()
    }

    @MainActor
    static func testAudioCleanupAndVideoCapture() {
        // 1. AudioQualityCleaner.processBuffer Multi-Anomaly Detection & Cleanup
        let sampleRate: Double = 16000
        let sampleCount = 64_000
        var sig = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            var val: Double = 0.045 // DC offset
            val += 0.025 * sin(2.0 * Double.pi * 50.0 * t) // 50 Hz mains hum
            val += 0.035 * sin(2.0 * Double.pi * 35.0 * t) // 35 Hz rumble
            // Quiet voiced bursts: 0.5s..1.5s and 2.2s..3.5s (~ -31 dBFS speech)
            if (t >= 0.5 && t < 1.5) || (t >= 2.2 && t < 3.5) {
                val += 0.022 * sin(2.0 * Double.pi * 220.0 * t) + 0.012 * sin(2.0 * Double.pi * 440.0 * t)
            }
            sig[i] = Float(val)
        }
        // 3 sharp 1-sample click spikes
        sig[12_000] = 0.78
        sig[24_000] = 0.78
        sig[41_000] = 0.78

        // 1 clipped plateau (6 samples of 0.995 starting at index 16_500)
        for i in 16_500..<16_506 {
            sig[i] = 0.995
        }

        // Hard-zero dropout gap (200 exact zeros at 43_000..<43_200 bordered by 0.08 samples)
        sig[42_999] = 0.08
        for i in 43_000..<43_200 {
            sig[i] = 0.0
        }
        sig[43_200] = 0.08

        let out = AudioQualityCleaner.processBuffer(sig, sampleRate: sampleRate, trackLabel: "Microphone")
        check("audio quality: buffer length preserved and finite", out.cleaned.count == sig.count && out.cleaned.allSatisfy(\.isFinite))
        let kinds = Set(out.findings.map(\.kind))
        check("audio quality: detects dcOffset", kinds.contains(.dcOffset))
        check("audio quality: detects mainsHum at 50Hz", kinds.contains(.mainsHum) && out.metrics.humFrequencyHz == 50)
        check("audio quality: detects clicksAndPops", kinds.contains(.clicksAndPops) && out.metrics.clickCount >= 3)
        check("audio quality: detects clipping", kinds.contains(.clipping) && out.metrics.clippedSamples >= 5)
        check("audio quality: detects lowLoudness", kinds.contains(.lowLoudness))

        let residualDC = abs(out.cleaned.reduce(0, +) / Float(out.cleaned.count))
        check("audio quality: residual DC offset < 0.002", residualDC < 0.002)
        check("audio quality: speech loudness leveled up", out.metrics.speechRMSdBFSAfter > out.metrics.speechRMSdBFSBefore + 5.0)
        let peakAfter = out.cleaned.map(abs).max() ?? 0
        check("audio quality: limiter ceiling respected", out.metrics.peakdBFSAfter <= -0.8 && peakAfter <= 0.92)

        // 2. AudioQualityCleaner.cleanMeetingTracks + Meeting Effective Paths + AudioFileLoader 48kHz Stereo Support
        let audioTempDir = FileManager.default.temporaryDirectory.appendingPathComponent("parrot-audio-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: audioTempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: audioTempDir) }

        let stereoURL = audioTempDir.appendingPathComponent("stereo48k.caf")
        do {
            guard let format48kStereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false) else {
                fatalError("Failed to create 48k stereo format")
            }
            let file = try AVAudioFile(forWriting: stereoURL, settings: format48kStereo.settings)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format48kStereo, frameCapacity: 96_000) else {
                fatalError("Failed to allocate 48k stereo buffer")
            }
            buf.frameLength = 96_000
            for ch in 0..<2 {
                if let ptr = buf.floatChannelData?[ch] {
                    for i in 0..<96_000 {
                        let t = Double(i) / 48000.0
                        ptr[i] = Float(0.04 * sin(2.0 * Double.pi * (ch == 0 ? 440.0 : 880.0) * t))
                    }
                }
            }
            try file.write(from: buf)
        } catch {
            check("audio file write stereo: no throw", false)
        }

        let loadedSamples = try? AudioFileLoader.load16kMono(url: stereoURL)
        check("audio file loader: 48k stereo loaded as ~32k 16kHz mono", loadedSamples != nil && abs((loadedSamples?.count ?? 0) - 32_000) <= 200)

        let cleanResult = try? AudioQualityCleaner.cleanMeetingTracks(systemPath: stereoURL.path, micPath: nil)
        let cleanSysPath = cleanResult?.cleanedSystemPath
        let cleanExists = cleanSysPath != nil && FileManager.default.fileExists(atPath: cleanSysPath!)
        var cleanLength: AVAudioFramePosition = 0
        var cleanRate: Double = 0
        if let cleanSysPath, cleanExists, let cleanFile = try? AVAudioFile(forReading: URL(fileURLWithPath: cleanSysPath)) {
            cleanLength = cleanFile.length
            cleanRate = cleanFile.processingFormat.sampleRate
        }
        check("audio quality cleanMeetingTracks: .cleaned.caf exists with 96k frames at 48kHz", cleanExists && cleanLength == 96_000 && cleanRate == 48000.0)

        let testMeeting = Meeting(title: "Cleanup Track Test", systemAudioPath: stereoURL.path)
        testMeeting.cleanedSystemAudioPath = cleanSysPath
        testMeeting.useCleanedAudio = true
        check("meeting effectiveSystemAudioPath: cleaned audio used when enabled", testMeeting.effectiveSystemAudioPath == cleanSysPath)
        testMeeting.useCleanedAudio = false
        check("meeting effectiveSystemAudioPath: original audio used when disabled", testMeeting.effectiveSystemAudioPath == stereoURL.path)

        // 3. AudioCaptureManager.isHeadphoneOutput
        check("headphone output: AirPods Pro", AudioCaptureManager.isHeadphoneOutput(deviceName: "AirPods Pro"))
        check("headphone output: External Headphones", AudioCaptureManager.isHeadphoneOutput(deviceName: "External Headphones"))
        check("headphone output: Bluetooth transport", AudioCaptureManager.isHeadphoneOutput(deviceName: "Generic Bluetooth Device", transportType: kAudioDeviceTransportTypeBluetooth))
        check("headphone output: MacBook Pro Speakers is false", !AudioCaptureManager.isHeadphoneOutput(deviceName: "MacBook Pro Speakers"))
        check("headphone output: Studio Display Speakers is false", !AudioCaptureManager.isHeadphoneOutput(deviceName: "Studio Display Speakers"))

        // 4. VideoCaptureService Target Modes, 16px Alignment, Benign Stream Errors & remuxReplacingAudio
        check("video capture mode: any has 3 picker modes", VideoCaptureTargetMode.any.pickerModes == [.singleWindow, .singleApplication, .singleDisplay])
        check("video capture mode: application has 1 picker mode", VideoCaptureTargetMode.application.pickerModes == [.singleApplication])

        check("video dimension aligned: 1137 % 16 == 0", VideoCaptureService.alignedDimension(1137) % 16 == 0)
        check("video dimension aligned: 743 % 16 == 0", VideoCaptureService.alignedDimension(743) % 16 == 0)
        check("video dimension aligned: 4 clamped to 16", VideoCaptureService.alignedDimension(4) == 16)

        let benignErr = NSError(domain: "com.apple.ScreenCaptureKit", code: -3808, userInfo: [NSLocalizedDescriptionKey: "Failed to stop a stream that is already stopped or does not exist"])
        check("video stream error: isBenignStreamStopError for -3808", VideoCaptureService.isBenignStreamStopError(benignErr))
        let targetClosedErr1 = NSError(domain: "com.apple.ScreenCaptureKit", code: -3817, userInfo: nil)
        let targetClosedErr2 = NSError(domain: "com.apple.ScreenCaptureKit", code: -3807, userInfo: nil)
        check("video stream error: isTargetClosedStopError for -3817 and -3807", VideoCaptureService.isTargetClosedStopError(targetClosedErr1) && VideoCaptureService.isTargetClosedStopError(targetClosedErr2))

        // Video mux & remuxReplacingAudio test
        let videoTempDir = FileManager.default.temporaryDirectory.appendingPathComponent("parrot-video-mux-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: videoTempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: videoTempDir) }

        let rawMP4 = videoTempDir.appendingPathComponent("raw.mp4")
        let a1CAF = videoTempDir.appendingPathComponent("sys.caf")
        let a2CAF = videoTempDir.appendingPathComponent("mic.caf")
        let replCAF = videoTempDir.appendingPathComponent("repl.caf")
        let muxedMP4 = videoTempDir.appendingPathComponent("muxed.mp4")

        do {
            try writeSyntheticVideo(url: rawMP4, width: 160, height: 160, duration: 1.0)
            try writeSyntheticAudio(url: a1CAF, sampleRate: 48000, channels: 1, frames: 48000, freq: 440.0)
            try writeSyntheticAudio(url: a2CAF, sampleRate: 48000, channels: 1, frames: 48000, freq: 880.0)
            try writeSyntheticAudio(url: replCAF, sampleRate: 48000, channels: 1, frames: 48000, freq: 660.0)
        } catch {
            check("video synthetic assets: created without error", false)
        }

        let muxSem = DispatchSemaphore(value: 0)
        var remuxThrew = false
        var loadedVTracks = 0
        var loadedATracks = 0
        var fileSize: Int64 = 0

        Task {
            do {
                try await VideoCaptureService.mux(video: rawMP4, offset: 0, audio: [a1CAF, a2CAF], destination: muxedMP4)
                try await VideoCaptureService.remuxReplacingAudio(videoFile: muxedMP4, offset: 0, audio: [replCAF])
                let asset = AVURLAsset(url: muxedMP4)
                let v = try await asset.loadTracks(withMediaType: .video)
                let a = try await asset.loadTracks(withMediaType: .audio)
                loadedVTracks = v.count
                loadedATracks = a.count
                let attrs = try FileManager.default.attributesOfItem(atPath: muxedMP4.path)
                fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            } catch {
                remuxThrew = true
            }
            muxSem.signal()
        }
        while muxSem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: .now + 0.01) }

        check("video remux: executed without error", !remuxThrew)
        check("video remux: output file exists and is non-empty", FileManager.default.fileExists(atPath: muxedMP4.path) && fileSize > 0)
        check("video remux: loads both video and audio tracks", loadedVTracks >= 1 && loadedATracks >= 1)

        // 5. Cross-Track Speaker Bleed Suppression
        let bleedSR = 16000.0
        let bleedTotalSamples = Int(3.5 * bleedSR)
        var bleedSys = [Float](repeating: 0, count: bleedTotalSamples)
        for i in 0..<bleedTotalSamples {
            let t = Double(i) / bleedSR
            if (t >= 0.20 && t < 1.00) || (t >= 1.30 && t < 2.10) {
                bleedSys[i] = Float(0.26 * (0.6 * sin(2.0 * .pi * 420.0 * t) + 0.4 * sin(2.0 * .pi * 840.0 * t)))
            }
        }

        let delaySamples = 640
        var bleedMic = [Float](repeating: 0, count: bleedTotalSamples)
        for i in 0..<bleedTotalSamples {
            let t = Double(i) / bleedSR
            var m: Float = 0
            if i >= delaySamples {
                m += 0.18 * bleedSys[i - delaySamples]
            }
            if t >= 2.40 && t < 3.10 {
                m += Float(0.38 * sin(2.0 * .pi * 310.0 * t))
            }
            bleedMic[i] = m
        }

        let (cleanedBleedMic, attenuatedSec) = AudioQualityCleaner.suppressSpeakerBleed(mic: bleedMic, system: bleedSys, sampleRate: bleedSR)

        func bufferRMS(_ buf: [Float], startSec: Double, endSec: Double, sr: Double = 16000.0) -> Double {
            let sIdx = max(0, Int(startSec * sr))
            let eIdx = min(buf.count, Int(endSec * sr))
            guard eIdx > sIdx else { return 0.0 }
            var sumSq: Double = 0
            for k in sIdx..<eIdx {
                let v = Double(buf[k])
                sumSq += v * v
            }
            return sqrt(sumSq / Double(eIdx - sIdx))
        }

        let rawBleedOnlyRMS = bufferRMS(bleedMic, startSec: 0.30, endSec: 0.95, sr: bleedSR)
        let cleanedBleedOnlyRMS = bufferRMS(cleanedBleedMic, startSec: 0.30, endSec: 0.95, sr: bleedSR)
        let rawMeRMS = bufferRMS(bleedMic, startSec: 2.50, endSec: 3.05, sr: bleedSR)
        let cleanedMeRMS = bufferRMS(cleanedBleedMic, startSec: 2.50, endSec: 3.05, sr: bleedSR)

        check("speaker bleed: cleaned sample count preserved", cleanedBleedMic.count == bleedMic.count)
        check("speaker bleed: attenuated seconds >= 0.5s", attenuatedSec >= 0.5)
        check("speaker bleed: bleed suppressed > 9 dB", cleanedBleedOnlyRMS < 0.35 * rawBleedOnlyRMS)
        check("speaker bleed: near-end me burst preserved", cleanedMeRMS >= 0.85 * rawMeRMS)

        // Clean headphone mic
        var headphoneMic = [Float](repeating: 0, count: bleedTotalSamples)
        for i in 0..<bleedTotalSamples {
            let t = Double(i) / bleedSR
            var h: Float = 0
            if t < 2.20 {
                h = Float(0.0008 * sin(2.0 * .pi * 1234.0 * t))
            }
            if t >= 2.40 && t < 3.10 {
                h += Float(0.38 * sin(2.0 * .pi * 310.0 * t))
            }
            headphoneMic[i] = h
        }
        let (hpCleaned, hpBleedSec) = AudioQualityCleaner.suppressSpeakerBleed(mic: headphoneMic, system: bleedSys, sampleRate: bleedSR)
        check("speaker bleed: clean headphone mic has zero attenuation", hpBleedSec == 0 && hpCleaned == headphoneMic)

        // 6. Harsh Sibilance Tamer
        let sibSR = 16000.0
        let sibTotalSamples = Int(2.0 * sibSR)
        var sibSamples = [Float](repeating: 0, count: sibTotalSamples)
        for i in 0..<sibTotalSamples {
            let t = Double(i) / sibSR
            var v: Float = Float(0.0002 * sin(2.0 * .pi * 900.0 * t))
            if t >= 0.35 && t < 1.65 {
                v += Float(0.12 * sin(2.0 * .pi * 420.0 * t))
            }
            if t >= 0.55 && t < 1.05 {
                v += Float(0.22 * sin(2.0 * .pi * 5600.0 * t))
            }
            sibSamples[i] = v
        }

        let (sibCleaned, _, sibFindings) = AudioQualityCleaner.processBuffer(sibSamples, sampleRate: sibSR, trackLabel: "Mic")
        check("harsh sibilance: sample count preserved", sibCleaned.count == sibSamples.count)
        check("harsh sibilance: finding reported and fixed", sibFindings.contains { $0.kind == .harshSibilance && $0.fixed })

        var rawHigh = sibSamples
        var rawMid = sibSamples
        var cleanHigh = sibCleaned
        var cleanMid = sibCleaned

        var hpfRaw = AudioQualityCleaner.BiquadHPF(cutoff: 4800.0, sampleRate: sibSR)
        var hpfClean = AudioQualityCleaner.BiquadHPF(cutoff: 4800.0, sampleRate: sibSR)
        hpfRaw.processInPlace(&rawHigh)
        hpfClean.processInPlace(&cleanHigh)

        var midHPFRaw = AudioQualityCleaner.BiquadHPF(cutoff: 300.0, sampleRate: sibSR)
        var midLPFRaw = AudioQualityCleaner.BiquadLPF(cutoff: 3500.0, sampleRate: sibSR)
        midHPFRaw.processInPlace(&rawMid)
        midLPFRaw.processInPlace(&rawMid)

        var midHPFClean = AudioQualityCleaner.BiquadHPF(cutoff: 300.0, sampleRate: sibSR)
        var midLPFClean = AudioQualityCleaner.BiquadLPF(cutoff: 3500.0, sampleRate: sibSR)
        midHPFClean.processInPlace(&cleanMid)
        midLPFClean.processInPlace(&cleanMid)

        let rawRatio = bufferRMS(rawHigh, startSec: 0.60, endSec: 1.00, sr: sibSR) / max(1e-6, bufferRMS(rawMid, startSec: 0.60, endSec: 1.00, sr: sibSR))
        let cleanRatio = bufferRMS(cleanHigh, startSec: 0.60, endSec: 1.00, sr: sibSR) / max(1e-6, bufferRMS(cleanMid, startSec: 0.60, endSec: 1.00, sr: sibSR))
        check("harsh sibilance: high-to-mid ratio strictly reduced", cleanRatio < rawRatio)

        // 7. Vision Screen OCR
        let ocrWidth = 640
        let ocrHeight = 180
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        var recognizedText = ""
        if let cgCtx = CGContext(data: nil, width: ocrWidth, height: ocrHeight, bitsPerComponent: 8, bytesPerRow: ocrWidth * 4, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) {
            let nsCtx = NSGraphicsContext(cgContext: cgCtx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx
            cgCtx.setFillColor(NSColor.white.cgColor)
            cgCtx.fill(CGRect(x: 0, y: 0, width: ocrWidth, height: ocrHeight))
            let text = "SAKVIRO SPRINT 42"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: 44),
                .foregroundColor: NSColor.black
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            str.draw(at: CGPoint(x: 30, y: 60))
            NSGraphicsContext.restoreGraphicsState()
            if let img = cgCtx.makeImage() {
                recognizedText = ScreenFrameSampler.recognizeScreenText(in: img)
            }
        }
        let upperOCR = recognizedText.uppercased()
        check("vision screen ocr: recognizes SAKVIRO and 42", upperOCR.contains("SAKVIRO") && upperOCR.contains("42"))

        // 8. Target Picker Styles & Summary Preservation
        check("target picker styles: window application display mapping",
              VideoCaptureTargetMode.window.preferredPickerStyle == .window &&
              VideoCaptureTargetMode.application.preferredPickerStyle == .application &&
              VideoCaptureTargetMode.display.preferredPickerStyle == .display)
    }

    private static func writeSyntheticVideo(url: URL, width: Int = 160, height: Int = 160, duration: Double = 1.0) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else { throw NSError(domain: "VideoGen", code: -1) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "VideoGen", code: -2) }
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else {
            throw NSError(domain: "VideoGen", code: -3)
        }

        let fps = 10
        let totalFrames = Int(duration * Double(fps))
        for f in 0..<totalFrames {
            let pts = CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps))
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }
            adaptor.append(pb, withPresentationTime: pts)
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: .now + 0.01) }
    }

    private static func writeSyntheticAudio(url: URL, sampleRate: Double, channels: Int, frames: Int, freq: Double) throws {
        try? FileManager.default.removeItem(at: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false) else {
            throw NSError(domain: "AudioGen", code: -1)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw NSError(domain: "AudioGen", code: -2)
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels {
            if let ptr = buffer.floatChannelData?[c] {
                for i in 0..<frames {
                    let t = Double(i) / sampleRate
                    ptr[i] = Float(0.04 * sin(2.0 * Double.pi * freq * t))
                }
            }
        }
        try file.write(from: buffer)
    }
}


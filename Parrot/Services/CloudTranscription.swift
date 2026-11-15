import Foundation
import AVFoundation
import WhisperKit

struct TranscriptionLogEntry: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case lifecycle
        case intervalSent
        case modelResponse
        case intervalSkip
        case diarization
        case error
    }

    struct SegmentItem: Equatable, Sendable {
        let index: Int
        let relStart: Double
        let relEnd: Double
        let absStart: Double
        let absEnd: Double
        let rawText: String
        let cleanedText: String
    }

    let id: UUID
    let timestamp: Date
    let kind: Kind
    let modelName: String
    let trackLabel: String?
    let intervalStart: Double?
    let intervalEnd: Double?
    let sampleCount: Int?
    let elapsedMs: Int?
    let summary: String
    let rawText: String?
    let segments: [SegmentItem]
    let structuredJSON: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        kind: Kind,
        modelName: String,
        trackLabel: String? = nil,
        intervalStart: Double? = nil,
        intervalEnd: Double? = nil,
        sampleCount: Int? = nil,
        elapsedMs: Int? = nil,
        summary: String,
        rawText: String? = nil,
        segments: [SegmentItem] = [],
        structuredJSON: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.modelName = modelName
        self.trackLabel = trackLabel
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
        self.sampleCount = sampleCount
        self.elapsedMs = elapsedMs
        self.summary = summary
        self.rawText = rawText
        self.segments = segments
        self.structuredJSON = structuredJSON
    }
}

struct TranscriptionJobProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case preparingModel(String)
        case transcribing(trackLabel: String, completedSeconds: Double, totalSeconds: Double)
        case diarizing
        case indexingAndSaving
        case updatingReport
    }

    let meetingID: UUID
    let fraction: Double
    let stage: Stage
    let startedAt: Date
    let activeModel: String
    let pipelineModels: [String]
    let intervalStart: Double?
    let intervalEnd: Double?

    init(
        meetingID: UUID,
        fraction: Double,
        stage: Stage,
        startedAt: Date,
        activeModel: String = "",
        pipelineModels: [String] = [],
        intervalStart: Double? = nil,
        intervalEnd: Double? = nil
    ) {
        self.meetingID = meetingID
        self.fraction = fraction
        self.stage = stage
        self.startedAt = startedAt
        self.activeModel = activeModel
        self.pipelineModels = pipelineModels
        self.intervalStart = intervalStart
        self.intervalEnd = intervalEnd
    }

    var statusText: String {
        let pct = Int((min(max(fraction, 0), 1) * 100).rounded())
        switch stage {
        case .preparingModel(let name): return "Loading \(name)… \(pct)%"
        case .transcribing(let track, let done, let total):
            return "Transcribing \(track) (\(Int(done))s / \(Int(max(total, 1)))s) · \(pct)%"
        case .diarizing: return "Separating speakers… \(pct)%"
        case .indexingAndSaving: return "Indexing transcript… \(pct)%"
        case .updatingReport: return "Updating report… \(pct)%"
        }
    }

    var intervalText: String? {
        guard let s = intervalStart, let e = intervalEnd, e >= s else { return nil }
        return "\(Self.formatTimestamp(s)) → \(Self.formatTimestamp(e))"
    }

    static func formatTimestamp(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        let tenths = Int(((clamped - Double(whole)) * 10).rounded()) % 10
        let h = whole / 3600
        let m = (whole % 3600) / 60
        let s = whole % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d.%d", h, m, s, tenths)
        }
        return String(format: "%02d:%02d.%d", m, s, tenths)
    }

    static func displayModelName(modelID: String, backend: TranscriptionBackend = .local, language: String? = nil) -> String {
        let base: String
        switch backend {
        case .groq:
            base = "Groq Whisper Large v3 Turbo"
        case .deepgram:
            base = "Deepgram \(modelID.isEmpty ? "Nova-3" : modelID)"
        case .local:
            if let mlxMatch = MLXTranscriber.models.first(where: { $0.id == modelID }) {
                base = "\(mlxMatch.name) (\(modelID))"
            } else if modelID == "parakeet-v3" {
                base = "FluidAudio Parakeet v3"
            } else if modelID.isEmpty {
                base = "On-device Whisper"
            } else {
                base = modelID
            }
        }
        if let lang = language, !lang.isEmpty, lang != "auto" {
            return "\(base) · \(lang)"
        }
        return base
    }

    func estimatedRemaining(now: Date = .now) -> TimeInterval? {
        guard fraction >= 0.05, fraction < 0.99 else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= 2 else { return nil }
        return max(1, elapsed * (1.0 - fraction) / fraction)
    }
}

/// Cloud transcription backends (bring-your-own-key). On-device Whisper stays
/// the default and the always-available fallback; these exist for users who
/// trade "audio never leaves the Mac" for accuracy (Groq) or latency (Deepgram).
enum TranscriptionBackend: String, CaseIterable {
    /// On-device WhisperKit — private, free (default).
    case local
    /// Groq-hosted whisper-large-v3-turbo — same chunk cadence as local, big-model
    /// accuracy, ~$0.04 per audio hour.
    case groq
    /// Deepgram Nova-3 streaming — word-by-word, ~300 ms latency.
    case deepgram

    static let defaultsKey = "transcriptionBackend"

    static var selected: TranscriptionBackend {
        // On-device only: never a cloud engine, whatever Settings says.
        guard !CloudGate.forcesLocal, UserDefaults.standard.object(forKey: AssistantRoutingSettings.enabledKey) == nil else { return .local }
        return TranscriptionBackend(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .local
    }

    var label: String {
        switch self {
        case .local: "On-device"
        case .groq: "Groq cloud"
        case .deepgram: "Deepgram cloud"
        }
    }

    /// Keychain account holding this backend's API key (nil = no key needed).
    var keychainAccount: String? {
        switch self {
        case .local: nil
        case .groq: "groq-api-key"
        case .deepgram: "deepgram-api-key"
        }
    }
}

/// The languages the Settings picker offers, and the live mismatch check's
/// vocabulary: it only suggests a language the user could also pick by hand.
enum TranscriptionLanguage {
    static let defaultsKey = "transcriptionLanguage"

    static let options: [(code: String, name: String)] = [
        ("en", "English"), ("lt", "Lithuanian"), ("tr", "Turkish"), ("es", "Spanish"), ("de", "German"),
        ("fr", "French"), ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"),
        ("ru", "Russian"), ("ar", "Arabic"), ("zh", "Chinese"), ("ja", "Japanese"),
        ("ko", "Korean"), ("hi", "Hindi"),
    ]

    static func deepgramMulti(model: String) -> Set<String>? {
        switch model {
        case "nova-3", "nova-3-general":
            return Set("af ar be bn bs bg ca zh hr cs da nl en et fi fr gl de el gu he hi hu id it ja kn ko lv lt mk ms mr no fa pl pt ro ru sr sk sl es sv tl ta te th tr uk vi xh zu".split(separator: " ").map(String.init))
        case "nova-2", "nova-2-general": return ["en", "es"]
        default: return nil
        }
    }

    /// nil = auto-detect.
    static var selected: String? {
        let setting = UserDefaults.standard.string(forKey: defaultsKey)
        return (setting == nil || setting == "auto") ? nil : setting
    }

    static func name(_ code: String) -> String {
        options.first { $0.code == code }?.name ?? code
    }
}

enum CloudTranscriptionError: LocalizedError {
    case missingKey
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "No API key set for the selected transcription engine."
        case .badResponse(let message): message
        }
    }
}

// MARK: - Groq (OpenAI-compatible audio transcription)

enum GroqTranscriber {
    static let endpoint = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    static let model = "whisper-large-v3-turbo"

    /// Transcribe one PCM chunk (16 kHz mono floats). Same cadence as the local
    /// loop — only the decode moves to Groq.
    static func transcribe(samples: [Float], language: String?, apiKey: String,
                           prompt: String? = nil, model: String = model) async throws -> String {
        struct Response: Decodable { let text: String }
        let data = try await post(fileData: WAVEncoder.encode(samples: samples, sampleRate: 16000),
                                  fileName: "chunk.wav",
                                  fields: fields(language: language, responseFormat: "json", prompt: prompt, model: model),
                                  apiKey: apiKey)
        return try JSONDecoder().decode(Response.self, from: data).text
    }

    /// Transcribe a whole audio file (the post-call polish pass) with segment
    /// timestamps. Returns (text, start, end) tuples in file-relative seconds.
    static func transcribeFile(_ fileData: Data, fileName: String, language: String?,
                               apiKey: String, prompt: String? = nil) async throws -> [(text: String, start: Double, end: Double)] {
        struct Segment: Decodable { let text: String; let start: Double; let end: Double }
        struct Response: Decodable { let segments: [Segment]? }
        let data = try await post(fileData: fileData, fileName: fileName,
                                  fields: fields(language: language, responseFormat: "verbose_json", prompt: prompt),
                                  apiKey: apiKey)
        let segments = try JSONDecoder().decode(Response.self, from: data).segments ?? []
        return segments.map { ($0.text, $0.start, $0.end) }
    }

    static func fields(language: String?, responseFormat: String, prompt: String?, model: String = model) -> [(String, String)] {
        var fields = [("model", model), ("response_format", responseFormat)]
        if let language, language != "auto" { fields.append(("language", language)) }
        // The same glossary the on-device engine primes Whisper with.
        if let prompt, !prompt.isEmpty { fields.append(("prompt", prompt)) }
        return fields
    }

    private static func post(fileData: Data, fileName: String,
                             fields: [(String, String)], apiKey: String) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        let boundary = "parrot-\(UUID().uuidString)"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = Multipart.body(boundary: boundary, fields: fields,
                                          file: (name: "file", fileName: fileName,
                                                 mimeType: "audio/wav", data: fileData))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.badResponse("No HTTP response")
        }
        guard http.statusCode == 200 else {
            let detail = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw CloudTranscriptionError.badResponse("Groq HTTP \(http.statusCode): \(detail)")
        }
        return data
    }
}

// MARK: - Multipart form encoding

enum Multipart {
    static func body(boundary: String, fields: [(String, String)],
                     file: (name: String, fileName: String, mimeType: String, data: Data)) -> Data {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.fileName)\"\r\n")
        append("Content-Type: \(file.mimeType)\r\n\r\n")
        body.append(file.data)
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}

// MARK: - WAV encoding

enum WAVEncoder {
    /// Minimal 16-bit PCM mono WAV wrapper around float samples (-1…1).
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var out = Data(capacity: 44 + dataSize)

        func append(_ s: String) { out.append(Data(s.utf8)) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

        append("RIFF")
        append32(UInt32(36 + dataSize))
        append("WAVE")
        append("fmt ")
        append32(16)                              // PCM chunk size
        append16(1)                               // PCM format
        append16(1)                               // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))          // byte rate
        append16(2)                               // block align
        append16(16)                              // bits per sample
        append("data")
        append32(UInt32(dataSize))

        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            pcm[i] = Int16(max(-1, min(1, s)) * 32767)
        }
        pcm.withUnsafeBufferPointer { ptr in
            out.append(UnsafeBufferPointer(start: UnsafeRawPointer(ptr.baseAddress!)
                .assumingMemoryBound(to: UInt8.self), count: dataSize))
        }
        return out
    }
}

// MARK: - Deepgram streaming

/// One live websocket to Deepgram per audio source ("Me" mic / "Them" system).
/// Sends 16 kHz mono linear16 PCM continuously; receives interim transcripts
/// (word-by-word, ~300 ms) and finals with stream-relative timestamps — which
/// equal meeting-relative here, since streaming starts with the recording.
final class DeepgramStreamer {
    private var task: URLSessionWebSocketTask?

    /// Called off-main with the latest interim transcript for the live line.
    var onInterim: ((String) -> Void)?
    /// Called off-main with a finalized utterance (text, start, end seconds)
    /// and the span its words were spoken. start...end is Deepgram's window:
    /// all the audio since the previous final, silences included.
    var onFinal: ((String, Double, Double, ClosedRange<Double>) -> Void)?
    /// Called once on any socket/API failure; the engine falls back to local.
    var onError: ((String) -> Void)?

    static func url(language: String?, model: String) -> URL {
        var components = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: "1"),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            // "multi" = Nova-3 multilingual streaming; a specific code pins it.
            URLQueryItem(name: "language", value: (language == nil || language == "auto") ? "multi" : language!),
        ]
        return components.url!
    }

    func connect(apiKey: String, language: String?, model: String = "nova-3") {
        var request = URLRequest(url: Self.url(language: language, model: model))
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        task = URLSession.shared.webSocketTask(with: request)
        task?.resume()
        receiveLoop()
        // Deepgram closes a stream that carries no audio for about 10 s
        // (NET-0001). A quiet system-audio track hits that before the other
        // side speaks; a KeepAlive every 5 s is Deepgram's documented remedy.
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.task?.send(.string(#"{"type":"KeepAlive"}"#)) { _ in }
            }
        }
    }

    /// Push PCM floats (called from the audio callback thread; WebSocket send
    /// is thread-safe).
    func send(_ samples: [Float]) {
        guard let task else { return }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            pcm[i] = Int16(max(-1, min(1, s)) * 32767)
        }
        let data = pcm.withUnsafeBufferPointer { Data(buffer: $0) }
        task.send(.data(data)) { [weak self] error in
            if let error { self?.fail(error.localizedDescription) }
        }
    }

    /// Ask Deepgram to flush remaining finals; caller waits a short grace
    /// period before tearing down.
    func finish() {
        // Deepgram answers CloseStream with a normal close, which the receive
        // loop sees as a failure; that is our own teardown, not an error.
        closing = true
        task?.send(.string(#"{"type":"CloseStream"}"#)) { _ in }
    }

    func close() {
        closing = true
        keepAlive?.cancel()
        keepAlive = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private var closing = false

    private var keepAlive: Task<Void, Never>?
    private var failed = false
    private func fail(_ message: String) {
        guard !failed, !closing else { return }
        failed = true
        keepAlive?.cancel()
        // The close code and reason are where Deepgram puts the real cause
        // ("NET-0001" and friends); the URL error alone says nothing.
        let code = task?.closeCode.rawValue ?? 0
        let reason = task?.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        onError?("\(message) [close \(code) \(reason)]")
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.fail(error.localizedDescription)
            case .success(let message):
                if case .string(let text) = message { self.handle(text) }
                self.receiveLoop()
            }
        }
    }

    private struct Response: Decodable {
        struct Word: Decodable { let start: Double; let end: Double }
        struct Alternative: Decodable { let transcript: String; let words: [Word]? }
        struct Channel: Decodable { let alternatives: [Alternative] }
        let type: String?
        let channel: Channel?
        let isFinal: Bool?
        let start: Double?
        let duration: Double?
    }

    /// Internal, not private: `--profile-test` feeds it Deepgram messages.
    func handle(_ json: String) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let response = try? decoder.decode(Response.self, from: Data(json.utf8)),
              response.type == "Results",
              let alternative = response.channel?.alternatives.first,
              !alternative.transcript.isEmpty else { return }
        let transcript = alternative.transcript

        if response.isFinal == true {
            let start = response.start ?? 0, end = start + (response.duration ?? 0)
            let words = alternative.words ?? []
            let spoken = words.first.map { $0.start...max($0.start, words.last!.end) } ?? start...end
            onFinal?(transcript, start, end, spoken)
        } else {
            onInterim?(transcript)
        }
    }
}

// MARK: - Post-call polish (whole-file re-transcription)

import AVFoundation

/// Re-transcribes the saved call audio through Groq's large model after the
/// call ends — the live view stays instant (whatever engine ran), the stored
/// transcript gets big-model accuracy for ~$0.04 per audio hour.
enum TranscriptPolisher {
    /// Groq caps upload size, and an hour of 16-bit WAV is ~115 MB — split
    /// into 10-minute parts and shift timestamps. A word clipped at a part
    /// boundary is acceptable for a best-effort polish.
    static let partSeconds = 600

    struct PolishedSegment {
        let text: String
        let start: Double
        let end: Double
        let speaker: String
    }

    /// "Polish on this Mac" (#144): re-transcribe with the on-device engine
    /// instead of Groq. Off = Groq, the original polish.
    static let onDeviceKey = "polishOnDevice"

    /// One track's lines, file-relative seconds.
    typealias Line = (text: String, start: Double, end: Double)

    /// Groq: 10-minute parts, timestamps shifted back onto the track.
    static func polish(
        systemPath: String?,
        micPath: String?,
        language: String?,
        apiKey: String,
        strictTracks: Bool = false,
        timeline: ([Float]) async -> [Float]? = { _ in nil },
        onProgress: (@Sendable (_ trackLabel: String, _ completedSeconds: Double, _ totalSeconds: Double, _ overallFraction: Double) -> Void)? = nil,
        onTrace: (@Sendable (TranscriptionLogEntry) -> Void)? = nil
    ) async throws -> (segments: [PolishedSegment], micHearsSpeakers: Bool) {
        let modelLabel = TranscriptionJobProgress.displayModelName(modelID: GroqTranscriber.model, backend: .groq, language: language)
        return try await polish(
            systemPath: systemPath,
            micPath: micPath,
            strictTracks: strictTracks,
            timeline: timeline,
            onProgress: onProgress,
            onTrace: onTrace
        ) { samples, _, _, trackLabel, reportTrackProgress in
            var lines: [Line] = []
            let partLength = 16000 * partSeconds
            var offset = 0
            let trackTotalSeconds = max(Double(samples.count) / 16000.0, 0.001)
            reportTrackProgress?(0, trackTotalSeconds)
            while offset < samples.count {
                try Task.checkCancellation()
                let partEnd = min(offset + partLength, samples.count)
                let part = Array(samples[offset ..< partEnd])
                let shift = Double(offset) / 16000.0
                let from = shift
                let to = Double(partEnd) / 16000.0

                onTrace?(TranscriptionLogEntry(
                    kind: .intervalSent,
                    modelName: modelLabel,
                    trackLabel: trackLabel,
                    intervalStart: from,
                    intervalEnd: to,
                    sampleCount: part.count,
                    summary: "Sent \(TranscriptionJobProgress.formatTimestamp(from)) → \(TranscriptionJobProgress.formatTimestamp(to)) (\(String(format: "%.1f", to - from))s) to Groq"
                ))

                let t0 = Date()
                let segments = try await GroqTranscriber.transcribeFile(
                    WAVEncoder.encode(samples: part, sampleRate: 16000),
                    fileName: "part.wav", language: language, apiKey: apiKey)
                let elapsedMs = max(1, Int(Date().timeIntervalSince(t0) * 1000))

                var segItems: [TranscriptionLogEntry.SegmentItem] = []
                for (idx, seg) in segments.enumerated() {
                    let cleaned = TranscriptionEngine.cleaned(seg.text)
                    segItems.append(TranscriptionLogEntry.SegmentItem(
                        index: idx,
                        relStart: seg.start,
                        relEnd: seg.end,
                        absStart: seg.start + shift,
                        absEnd: seg.end + shift,
                        rawText: seg.text,
                        cleanedText: cleaned
                    ))
                }

                let responseObj: [String: Any] = [
                    "model": GroqTranscriber.model,
                    "track": trackLabel,
                    "interval": [from, to],
                    "elapsedMs": elapsedMs,
                    "segmentCount": segments.count,
                    "segments": segItems.map { [
                        "index": $0.index,
                        "relStart": $0.relStart,
                        "relEnd": $0.relEnd,
                        "absStart": $0.absStart,
                        "absEnd": $0.absEnd,
                        "text": $0.rawText
                    ] }
                ]
                let jsonStr: String?
                if let jsonData = try? JSONSerialization.data(withJSONObject: responseObj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                    jsonStr = String(data: jsonData, encoding: .utf8)
                } else {
                    jsonStr = nil
                }

                let fullRawText = segments.map(\.text).joined(separator: " ")
                let rtf = (to - from) / max(Double(elapsedMs) / 1000.0, 0.001)
                onTrace?(TranscriptionLogEntry(
                    kind: .modelResponse,
                    modelName: modelLabel,
                    trackLabel: trackLabel,
                    intervalStart: from,
                    intervalEnd: to,
                    sampleCount: part.count,
                    elapsedMs: elapsedMs,
                    summary: "\(segments.count) segment(s) in \(String(format: "%.2fs", Double(elapsedMs)/1000.0)) (\(String(format: "%.1fx", rtf)) realtime)",
                    rawText: fullRawText,
                    segments: segItems,
                    structuredJSON: jsonStr
                ))

                lines += segments.map { (TranscriptionEngine.cleaned($0.text), $0.start + shift, $0.end + shift) }
                offset += partLength
                reportTrackProgress?(min(Double(offset) / 16000.0, trackTotalSeconds), trackTotalSeconds)
            }
            return lines
        }
    }

    /// Both tracks (system = "Them", mic = "Me"), file-relative timestamps.
    /// `transcribe` turns one track (its samples and file) into lines.
    /// Throws on any failure — caller keeps the live transcript.
    /// `timeline` gives a track's speech probabilities (256 ms windows);
    /// lines over stretches with no voice are dropped, since the upload
    /// includes every idle minute and Whisper fills silence with invented
    /// text. nil timeline = keep everything.
    /// Me lines the live echo gate would skip are dropped too (#98: the
    /// re-decode brought back the echo the live call had removed);
    /// `micHearsSpeakers` says whether any was.
    static func polish(
        systemPath: String?,
        micPath: String?,
        timeline: ([Float]) async -> [Float]? = { _ in nil },
        transcribe: ([Float], URL) async throws -> [Line]
    ) async throws -> (segments: [PolishedSegment], micHearsSpeakers: Bool) {
        try await polish(
            systemPath: systemPath,
            micPath: micPath,
            timeline: timeline,
            onProgress: nil,
            transcribeWithProgress: { samples, url, _ in
                try await transcribe(samples, url)
            }
        )
    }

    static func polish(
        systemPath: String?,
        micPath: String?,
        timeline: ([Float]) async -> [Float]? = { _ in nil },
        onProgress: (@Sendable (_ trackLabel: String, _ completedSeconds: Double, _ totalSeconds: Double, _ overallFraction: Double) -> Void)?,
        transcribeWithProgress: ([Float], URL, (@Sendable (_ completedSeconds: Double, _ totalSeconds: Double) -> Void)?) async throws -> [Line]
    ) async throws -> (segments: [PolishedSegment], micHearsSpeakers: Bool) {
        try await polish(
            systemPath: systemPath,
            micPath: micPath,
            timeline: timeline,
            onProgress: onProgress,
            onTrace: nil
        ) { samples, url, _, _, trackProgress in
            try await transcribeWithProgress(samples, url, trackProgress)
        }
    }

    static func polish(
        systemPath: String?,
        micPath: String?,
        strictTracks: Bool = false,
        timeline: ([Float]) async -> [Float]? = { _ in nil },
        onProgress: (@Sendable (_ trackLabel: String, _ completedSeconds: Double, _ totalSeconds: Double, _ overallFraction: Double) -> Void)? = nil,
        onTrace: (@Sendable (TranscriptionLogEntry) -> Void)? = nil,
        transcribeTrack: (_ samples: [Float], _ url: URL, _ trackTimeline: [Float]?, _ trackLabel: String, _ onTrackProgress: (@Sendable (Double, Double) -> Void)?) async throws -> [Line]
    ) async throws -> (segments: [PolishedSegment], micHearsSpeakers: Bool) {
        struct TrackItem: Sendable {
            let path: String
            let speaker: String
            let label: String
            let url: URL
            let samples: [Float]
        }

        var loadedTracks: [TrackItem] = []
        for (path, speaker, label) in [
            (systemPath, "Them", "System audio"),
            (micPath, "Me", "Microphone")
        ] {
            guard let path else { continue }
            if !strictTracks && !FileManager.default.fileExists(atPath: path) { continue }
            let url = URL(fileURLWithPath: path)
            let samples: [Float]
            do {
                samples = try AudioFileLoader.load16kMono(url: url)
            } catch {
                if strictTracks {
                    throw NSError(domain: "Parrot", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot read \(label) at \(path): \(error.localizedDescription)", NSUnderlyingErrorKey: error])
                }
                NSLog("Parrot: polish skipped \(speaker) track — unsupported format")
                continue
            }
            loadedTracks.append(TrackItem(path: path, speaker: speaker, label: label, url: url, samples: samples))
        }

        let totalAudioDuration = max(loadedTracks.reduce(0.0) { $0 + max(Double($1.samples.count) / 16000.0, 0.001) }, 0.001)
        var completedAudioSeconds = 0.0

        var out: [PolishedSegment] = []
        var themLevels: [Float]?
        var micHearsSpeakers = false

        for track in loadedTracks {
            try Task.checkCancellation()
            let trackDuration = max(Double(track.samples.count) / 16000.0, 0.001)
            let baseCompleted = completedAudioSeconds
            let label = track.label

            let trackProgress: (@Sendable (Double, Double) -> Void)?
            if let onProgress {
                trackProgress = { (done: Double, _: Double) in
                    let trackDone = min(max(done, 0.0), trackDuration)
                    let currentTotal = baseCompleted + trackDone
                    let frac = min(max(currentTotal / totalAudioDuration, 0.0), 1.0)
                    onProgress(label, trackDone, trackDuration, frac)
                }
            } else {
                trackProgress = nil
            }

            trackProgress?(0, trackDuration)

            // The system track comes first; keep only its loudness for the Me pass.
            let levels = EchoGate.envelope(track.samples[...])
            if track.speaker == "Them" { themLevels = levels }

            let vadStart = Date()
            let trackTimeline = await timeline(track.samples)
            let vadMs = max(1, Int(Date().timeIntervalSince(vadStart) * 1000))

            if let trackTimeline {
                let voicedCount = trackTimeline.filter { $0 >= TranscriptionEngine.speechThreshold }.count
                let voicedPct = Int((Double(voicedCount) / Double(max(trackTimeline.count, 1)) * 100).rounded())
                onTrace?(TranscriptionLogEntry(
                    kind: .lifecycle,
                    modelName: "VAD",
                    trackLabel: track.label,
                    elapsedMs: vadMs,
                    summary: "Loaded \(track.label) (\(String(format: "%.1f", trackDuration))s) · VAD speech timeline ready in \(vadMs)ms (\(voicedPct)% voiced)"
                ))
            } else {
                onTrace?(TranscriptionLogEntry(
                    kind: .lifecycle,
                    modelName: "Audio",
                    trackLabel: track.label,
                    summary: "Loaded \(track.label) (\(String(format: "%.1f", trackDuration))s)"
                ))
            }

            let lines = try await transcribeTrack(track.samples, track.url, trackTimeline, track.label, trackProgress)

            for s in lines {
                guard !s.text.isEmpty else { continue }
                if let trackTimeline, !TranscriptionEngine.hasVoice(trackTimeline, from: s.start, to: s.end) {
                    continue
                }
                let line = PolishedSegment(text: s.text, start: s.start, end: s.end, speaker: track.speaker)
                if track.speaker == "Me", let themLevels,
                   isEcho(line, mic: track.samples, micLevels: levels, themLevels: themLevels) {
                    micHearsSpeakers = true
                    continue
                }
                out.append(line)
            }

            completedAudioSeconds += trackDuration
            let endFrac = min(max(completedAudioSeconds / totalAudioDuration, 0.0), 1.0)
            onProgress?(track.label, trackDuration, trackDuration, endFrac)
        }

        return (out.sorted { $0.start < $1.start }, micHearsSpeakers)
    }

    /// The live echo gate on one polished Me line. Both tracks start at the
    /// same instant (since 0.24.0), so file times line up, as `--echo-replay`
    /// assumes for new recordings.
    static func isEcho(_ line: PolishedSegment, mic: [Float], micLevels: [Float], themLevels: [Float]) -> Bool {
        let lo = max(0, Int(line.start * 16000)), hi = min(mic.count, Int(line.end * 16000))
        guard hi > lo else { return false }
        return EchoGate.check(clip: Array(mic[lo..<hi]), mic: micLevels, them: themLevels, at: lo / EchoGate.hop).isEcho
    }
}

/// Loads a recorded .caf as 16 kHz mono floats.
enum AudioFileLoader {
    enum LoadError: Error { case unsupportedFormat }

    static func load16kMono(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == 16000, format.channelCount == 1 else {
            return AudioProcessor.convertBufferToArray(buffer: try AudioProcessor.loadAudio(fromPath: url.path))
        }
        var samples: [Float] = []
        samples.reserveCapacity(Int(file.length))
        let block: AVAudioFrameCount = 1 << 18
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else {
            return AudioProcessor.convertBufferToArray(buffer: try AudioProcessor.loadAudio(fromPath: url.path))
        }
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: block)
            guard buffer.frameLength > 0, let ch = buffer.floatChannelData?[0] else { break }
            samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        }
        return samples
    }
}

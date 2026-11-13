import Foundation

enum MLXTranscriber {
    struct Segment: Decodable, Equatable, Sendable {
        let start: Double
        let end: Double
        let text: String
        let avg_logprob: Double?
        let no_speech_prob: Double?

        init(start: Double, end: Double, text: String, avg_logprob: Double? = nil, no_speech_prob: Double? = nil) {
            self.start = start
            self.end = end
            self.text = text
            self.avg_logprob = avg_logprob
            self.no_speech_prob = no_speech_prob
        }
    }

    struct Reply: Decodable, Sendable {
        let ok: Bool?
        let text: String?
        let segments: [Segment]?
        let error: String?
        let language: String?
        let elapsedMs: Int?
    }

    struct DetailedReply: Sendable {
        let rawText: String
        let segments: [Segment]
        let language: String?
        let elapsedMs: Int
        let rawResponseJSON: String
    }

    static let models: [(id: String, name: String)] = [
        ("mlx-azuolas", "Lithuanian Ąžuolas MLX"),
        ("mlx-paprika", "Lithuanian Paprika v3 MLX"),
        ("mlx-english", "English Whisper Large v3 MLX")
    ]
    static let pythonKey = "mlxPythonPath"

    static func isMLX(_ model: String) -> Bool { models.contains { $0.id == model } }
    static func modelKey(_ model: String) -> String { "mlxModelPath.\(model)" }

    static func effectiveLanguage(for model: String, selected: String?) -> String? {
        let trimmed = selected?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isAutoOrEmpty = (trimmed == nil || trimmed?.isEmpty == true || trimmed == "auto")
        if (model == "mlx-azuolas" || model == "mlx-paprika") && isAutoOrEmpty {
            return "lt"
        }
        return isAutoOrEmpty ? nil : trimmed
    }

    static func importBoundary(_ samples: [Float], from start: Int) throws -> Int {
        let maxChunk = 480_000
        if samples.count - start <= maxChunk { return samples.count }
        let maximum = min(start + maxChunk, samples.count)
        let frame = 3_200
        var best: (index: Int, energy: Float)?
        var maxEnergy: Float = 0
        for index in stride(from: start + 320_000, through: maximum - frame, by: frame) {
            let energy = samples[index..<(index + frame)].reduce(Float.zero) { $0 + abs($1) } / Float(frame)
            if energy > maxEnergy { maxEnergy = energy }
            if best == nil || energy < best!.energy { best = (index + frame / 2, energy) }
        }
        guard let best, (best.energy < 0.003 || best.energy < maxEnergy * 0.8) else {
            throw Failure.message("No quiet boundary found in this audio. Split it at a pause and try again.")
        }
        return best.index
    }

    static func perform(action: String, model: String, samples: [Float]? = nil, language: String? = nil) async throws -> String {
        let reply = try await execute(action: action, model: model, samples: samples, language: language)
        return reply.text ?? ""
    }

    static func performSegments(samples: [Float], model: String, directory: URL, python: URL, language: String?) async throws -> [Segment] {
        try await performSegments(samples: samples, model: model, directory: Optional(directory), python: Optional(python), language: language)
    }

    static func performSegments(samples: [Float], model: String, directory: URL? = nil, python: URL? = nil, language: String? = nil) async throws -> [Segment] {
        let detailed = try await performDetailed(samples: samples, model: model, directory: directory, python: python, language: language)
        return detailed.segments
    }

    static func performDetailed(samples: [Float], model: String, directory: URL? = nil, python: URL? = nil, language: String? = nil) async throws -> DetailedReply {
        let t0 = Date()
        let (reply, rawData) = try await executeWithRaw(action: "transcribe", model: model, samples: samples, directory: directory, python: python, language: language)
        let trimmedText = (reply.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmpties = (reply.segments ?? []).compactMap { seg -> Segment? in
            let trimmed = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Segment(start: seg.start, end: seg.end, text: trimmed, avg_logprob: seg.avg_logprob, no_speech_prob: seg.no_speech_prob)
        }
        let segments: [Segment]
        if nonEmpties.isEmpty {
            if !trimmedText.isEmpty {
                segments = [Segment(start: 0, end: Double(samples.count) / 16000.0, text: trimmedText)]
            } else {
                segments = []
            }
        } else {
            segments = nonEmpties
        }
        let elapsedMs = reply.elapsedMs ?? max(1, Int(Date().timeIntervalSince(t0) * 1000))
        let rawResponseJSON = String(data: rawData, encoding: .utf8) ?? "{}"
        return DetailedReply(
            rawText: trimmedText,
            segments: segments,
            language: reply.language,
            elapsedMs: elapsedMs,
            rawResponseJSON: rawResponseJSON
        )
    }

    private static func execute(action: String, model: String, samples: [Float]? = nil, directory: URL? = nil, python: URL? = nil, language: String? = nil) async throws -> Reply {
        let (reply, _) = try await executeWithRaw(action: action, model: model, samples: samples, directory: directory, python: python, language: language)
        return reply
    }

    private static func executeWithRaw(action: String, model: String, samples: [Float]? = nil, directory: URL? = nil, python: URL? = nil, language: String? = nil) async throws -> (Reply, Data) {
        let id = UUID().uuidString
        var request: [String: Any] = ["operation": "mlx", "id": id, "action": action]
        if action != "unload" {
            guard let pythonPath = python?.path ?? UserDefaults.standard.string(forKey: pythonKey), !pythonPath.isEmpty,
                  let modelPath = directory?.path ?? UserDefaults.standard.string(forKey: modelKey(model)), !modelPath.isEmpty else {
                throw Failure.message("Choose the MLX Python executable and model folder in Settings")
            }
            request["python"] = pythonPath
            request["model"] = modelPath
        }
        if let samples {
            guard !samples.isEmpty, samples.count <= 480_000 else { throw Failure.message("Invalid MLX audio length") }
            let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            request["pcm"] = pcm.base64EncodedString()
            request["sampleRate"] = 16000
            request["language"] = language
        }
        let data = try JSONSerialization.data(withJSONObject: request)
        let response = try await HostHelperClient.shared.perform(data, identifier: id)
        let reply = try JSONDecoder().decode(Reply.self, from: response)
        guard reply.ok == true else {
            throw Failure.message(reply.error ?? "Invalid MLX response")
        }
        return (reply, response)
    }

    static func available(python: String, modelPath: String) async throws -> Bool {
        let id = UUID().uuidString
        let request: [String: Any] = ["operation": "mlx", "id": id, "action": "probe", "python": python, "model": modelPath]
        let response = try await HostHelperClient.shared.perform(JSONSerialization.data(withJSONObject: request), identifier: id)
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              object["ok"] as? Bool == true, let available = object["available"] as? Bool else {
            throw Failure.message("Invalid MLX availability response")
        }
        return available
    }

    private enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
    }
}

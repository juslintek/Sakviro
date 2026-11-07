import Foundation

enum MLXTranscriber {
    static let models: [(id: String, name: String)] = [
        ("mlx-azuolas", "Lithuanian Ąžuolas MLX"),
        ("mlx-paprika", "Lithuanian Paprika v3 MLX"),
        ("mlx-english", "English Whisper Large v3 MLX")
    ]
    static let pythonKey = "mlxPythonPath"

    static func isMLX(_ model: String) -> Bool { models.contains { $0.id == model } }
    static func modelKey(_ model: String) -> String { "mlxModelPath.\(model)" }

    static func importBoundary(_ samples: [Float], from start: Int) throws -> Int {
        let maximum = min(start + 480_000, samples.count)
        if maximum == samples.count { return maximum }
        let frame = 3_200
        var best: (index: Int, energy: Float)?
        for index in stride(from: start + 320_000, through: maximum - frame, by: frame) {
            let energy = samples[index..<(index + frame)].reduce(Float.zero) { $0 + abs($1) } / Float(frame)
            if energy < 0.003, best == nil || energy < best!.energy { best = (index + frame / 2, energy) }
        }
        guard let best else { throw Failure.message("No quiet boundary found in this audio. Split it at a pause and try again.") }
        return best.index
    }

    static func perform(action: String, model: String, samples: [Float]? = nil, language: String? = nil) async throws -> String {
        let id = UUID().uuidString
        var request: [String: Any] = ["operation": "mlx", "id": id, "action": action]
        if action != "unload" {
            guard let python = UserDefaults.standard.string(forKey: pythonKey), !python.isEmpty,
                  let modelPath = UserDefaults.standard.string(forKey: modelKey(model)), !modelPath.isEmpty else {
                throw Failure.message("Choose the MLX Python executable and model folder in Settings")
            }
            request["python"] = python
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
        guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any], object["ok"] as? Bool == true else {
            throw Failure.message("Invalid MLX response")
        }
        return object["text"] as? String ?? ""
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

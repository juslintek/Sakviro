import Foundation

enum SpeechModels {
    static func autoKey(_ backend: TranscriptionBackend) -> String { "speechModelAuto.\(backend.rawValue)" }
    static func modelKey(_ backend: TranscriptionBackend) -> String { "speechModel.\(backend.rawValue)" }
    static let generic = ["mlx-english", "large-v3-turbo", "large-v3-v20240930_626MB", "small", "base", "tiny"]

    static func select(backend: TranscriptionBackend, automatic: Bool, manual: String,
                       language: String?, context: String, available: Set<String>) -> String? {
        guard automatic else { return manual }
        let words = Set(context.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        let lt = !words.isDisjoint(with: ["lithuanian", "lietuviškai", "lietuvių"])
        let en = !words.isDisjoint(with: ["english", "angliškai", "anglų"])
        let mixed = lt && en || !words.isDisjoint(with: ["bilingual", "multilingual", "mixed", "dvikalbis", "mišri"])
        let hint = mixed ? nil : (lt ? "lt" : (en ? "en" : nil))
        let chosenLanguage = language == nil || language == "auto" ? hint : ((hint == nil || hint == language) && !mixed ? language : nil)
        let quality = !words.isDisjoint(with: ["accuracy", "accurate", "quality", "tikslumas", "tiksliai"])
        let fast = !words.isDisjoint(with: ["fast", "speed", "quick", "greitai", "greitas"])
        switch backend {
        case .groq: return quality && !fast ? "whisper-large-v3" : "whisper-large-v3-turbo"
        case .deepgram: return "nova-3"
        case .local:
            let preferred = chosenLanguage == "lt" ? (fast && !quality ? ["mlx-paprika", "mlx-azuolas"] : ["mlx-azuolas", "mlx-paprika"]) : []
            return (preferred + generic).first { available.contains($0) }
        }
    }

    static func availableLocal() async throws -> Set<String> {
        var available = Set(generic.filter { !MLXTranscriber.isMLX($0) && TranscriptionEngine.localModelFolder(for: $0) != nil })
        let defaults = UserDefaults.standard
        if let python = defaults.string(forKey: MLXTranscriber.pythonKey), !python.isEmpty {
            for model in MLXTranscriber.models {
                guard let path = defaults.string(forKey: MLXTranscriber.modelKey(model.id)), !path.isEmpty else { continue }
                if try await MLXTranscriber.available(python: python, modelPath: path) { available.insert(model.id) }
            }
        }
        return available
    }

    static func choice(_ backend: TranscriptionBackend, context: String) async throws -> String? {
        let available = backend == .local && UserDefaults.standard.bool(forKey: autoKey(.local)) ? try await availableLocal() : []
        return choice(backend, context: context, available: available)
    }

    static func choice(_ backend: TranscriptionBackend, context: String, available: Set<String>) -> String? {
        let defaults = UserDefaults.standard
        let manual: String
        switch backend {
        case .local: manual = defaults.string(forKey: "whisperModel") ?? "base"
        case .groq: manual = defaults.string(forKey: modelKey(backend)) ?? "whisper-large-v3-turbo"
        case .deepgram: manual = defaults.string(forKey: modelKey(backend)) ?? "nova-3"
        }
        return select(backend: backend, automatic: defaults.bool(forKey: autoKey(backend)), manual: manual,
                      language: TranscriptionLanguage.selected, context: context, available: available)
    }
}

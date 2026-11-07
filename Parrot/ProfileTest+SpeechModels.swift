import Foundation

extension ProfileTest {
    static func testSpeechModels() {
        let generic: Set<String> = ["base", "mlx-azuolas", "mlx-paprika"]
        func choice(_ automatic: Bool = true, _ language: String? = nil, _ context: String = "", _ available: Set<String> = generic) -> String? {
            SpeechModels.select(backend: .local, automatic: automatic, manual: "small", language: language, context: context, available: available)
        }
        check("speech models: manual wins", choice(false, "lt") == "small")
        check("speech models: pinned Lithuanian", choice(true, "lt") == "mlx-azuolas")
        check("speech models: fast Lithuanian", choice(true, nil, "lietuviškai greitai") == "mlx-paprika")
        check("speech models: English generic", choice(true, "en") == "base")
        check("speech models: mixed generic", choice(true, nil, "Lithuanian and English") == "base")
        check("speech models: conflicting pin generic", choice(true, "lt", "English") == "base")
        check("speech models: technical terms are not language hints", choice(true, nil, "API endpointas backend") == "base")
        check("speech models: no uncached candidate", choice(true, nil, "", []) == nil)
        check("speech models: manual remains after auto", choice(false) == "small")
        check("speech models: Groq stays Groq", SpeechModels.select(backend: .groq, automatic: true, manual: "x", language: "lt", context: "quality", available: []) == "whisper-large-v3")
        check("speech models: recovery marks mixed model usage", TranscriptionEngine.usageModel("nova-3", recovered: true, localModel: "base") == "nova-3 + on-device base")
        check("speech models: no recovery keeps cloud model", TranscriptionEngine.usageModel("nova-3", recovered: false, localModel: "base") == "nova-3")
        let autoURL = URLComponents(url: DeepgramStreamer.url(language: nil, model: "nova-3"), resolvingAgainstBaseURL: false)!
        let pinnedURL = URLComponents(url: DeepgramStreamer.url(language: "lt", model: "nova-2"), resolvingAgainstBaseURL: false)!
        check("speech models: Nova-3 multi URL", autoURL.queryItems?.contains(URLQueryItem(name: "language", value: "multi")) == true && autoURL.queryItems?.contains(URLQueryItem(name: "model", value: "nova-3")) == true)
        check("speech models: Nova-2 Lithuanian URL", pinnedURL.queryItems?.contains(URLQueryItem(name: "language", value: "lt")) == true && pinnedURL.queryItems?.contains(URLQueryItem(name: "model", value: "nova-2")) == true)
        check("speech models: Nova-3 covers picker languages", Set(TranscriptionLanguage.options.map(\.code)).isSubset(of: TranscriptionLanguage.deepgramMulti(model: "nova-3")!))
        check("speech models: unknown Deepgram model has unknown capabilities", TranscriptionLanguage.deepgramMulti(model: "custom") == nil)
        check("speech models: Deepgram stays Deepgram", SpeechModels.select(backend: .deepgram, automatic: true, manual: "x", language: nil, context: "quality", available: []) == "nova-3")
    }
}

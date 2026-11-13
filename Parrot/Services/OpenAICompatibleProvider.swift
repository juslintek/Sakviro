import Foundation

// MARK: - Provider selection

/// Which backend powers the copilot. Persisted in UserDefaults ("copilotProvider");
/// Settings → Copilot writes it, SwitchingAnalysisProvider reads it per call.
enum CopilotProviderKind: String, CaseIterable, Identifiable {
    case claude
    case ollama
    case custom
    case claudeCode, codex, gemini, copilot, customCLI

    var isCLI: Bool {
        switch self {
        case .claudeCode, .codex, .gemini, .copilot, .customCLI: true
        default: false
        }
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: "Claude (cloud)"
        case .ollama: "Ollama (local)"
        case .custom: "Other AI service"
        case .claudeCode: "Claude Code CLI"
        case .codex: "Codex CLI"
        case .gemini: "Antigravity / Gemini CLI"
        case .copilot: "GitHub Copilot CLI"
        case .customCLI: "Custom CLI"
        }
    }

    /// The LIVE-cards provider ("copilotProvider" — pre-split installs carry
    /// their choice into the live role, which is the main experience).
    static var selected: CopilotProviderKind {
        CopilotProviderKind(rawValue: UserDefaults.standard.string(forKey: "copilotProvider") ?? "") ?? .claude
    }

    /// The post-call reports provider ("reportsProvider"); nil = same as live.
    static var reportsSelected: CopilotProviderKind? {
        let raw = UserDefaults.standard.string(forKey: "reportsProvider") ?? ""
        return raw.isEmpty ? nil : CopilotProviderKind(rawValue: raw)
    }

    /// Ask Parrot's provider ("askProvider"); nil = same as reports.
    static var askSelected: CopilotProviderKind? {
        let raw = UserDefaults.standard.string(forKey: "askProvider") ?? ""
        return raw.isEmpty ? nil : CopilotProviderKind(rawValue: raw)
    }

    static func modelName(for kind: CopilotProviderKind) -> String {
        switch kind {
        case .claude: ClaudeAnalysisProvider.model
        case .ollama: OpenAICompatibleProvider.ollamaModel
        case .custom: OpenAICompatibleProvider.customModel
        case .claudeCode, .codex, .gemini, .copilot, .customCLI:
            CLIAnalysisProvider.setting(kind, "model").isEmpty ? kind.label : CLIAnalysisProvider.setting(kind, "model")
        }
    }

    /// Model identifier the live backend will use — recorded per meeting for
    /// the cost row.
    static var activeModelName: String { modelName(for: selected) }
}

// MARK: - Ollama model catalog

/// Curated local models for the Settings dropdown — small, non-"thinking"
/// instruct models only (reasoning models like qwen3/deepseek-r1 spend minutes
/// on hidden chain-of-thought and time out the live loop; measured 2026-07-17).
enum OllamaCatalog {
    struct Model {
        let id: String
        let label: String
        let sizeLabel: String
    }

    static let models: [Model] = [
        Model(id: "llama3.2:3b", label: "llama3.2:3b — fastest, good default", sizeLabel: "2.0 GB"),
        Model(id: "gemma3:4b", label: "gemma3:4b — better writing & languages", sizeLabel: "3.3 GB"),
    ]

    static var ids: [String] { models.map(\.id) }

    static func sizeLabel(for id: String) -> String? {
        models.first { $0.id == id }?.sizeLabel
    }
}

/// The local Ollama server (loopback only): which models are installed, or
/// nil when it isn't running. Shared by Settings and Ask Parrot.
enum OllamaProbe {
    /// /api/tags lists "mistral" as "mistral:latest": an untagged name
    /// means its :latest tag.
    static func isInstalled(_ model: String, in installed: [String]) -> Bool {
        installed.contains(model) || (!model.contains(":") && installed.contains(model + ":latest"))
    }

    static func installedModels() async -> [String]? {
        struct Tags: Decodable {
            struct Entry: Decodable { let name: String }
            let models: [Entry]
        }
        var request = URLRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let tags = try? JSONDecoder().decode(Tags.self, from: data) else { return nil }
        return tags.models.map(\.name)
    }
}

// MARK: - OpenAI-compatible provider

/// Talks to any OpenAI-compatible chat-completions server: Ollama on this Mac
/// (free, fully private) or a custom endpoint (OpenAI, Gemini, Groq, OpenRouter,
/// LM Studio…). Prompts, schema, and validation are shared with
/// ClaudeAnalysisProvider so every backend gets identical instructions — only
/// the transport and response envelope differ.
final class OpenAICompatibleProvider: AnalysisProvider {

    static var ollamaModel: String {
        UserDefaults.standard.string(forKey: "copilotOllamaModel")?.nilIfEmpty ?? "llama3.2:3b"
    }
    static var customModel: String {
        UserDefaults.standard.string(forKey: "copilotCustomModel") ?? ""
    }
    static var customBaseURL: String {
        UserDefaults.standard.string(forKey: "copilotCustomBaseURL") ?? ""
    }

    /// Which kind this instance serves — a closure so the live/reports split can
    /// hand one instance per role and Settings changes apply on the next call.
    private let kindSource: () -> CopilotProviderKind

    init(kindSource: @escaping () -> CopilotProviderKind = { CopilotProviderKind.selected }) {
        self.kindSource = kindSource
    }

    private struct Config {
        let baseURL: URL
        let model: String
        let apiKey: String?
    }

    /// Resolved fresh on every call so Settings changes apply immediately.
    private func currentConfig(context: ModelTaskContext? = nil) -> Config? {
        let kind = kindSource()
        func selected(_ manual: String) -> String {
            context.map { ModelSelection.selected(kind: kind, manual: manual, context: $0) } ?? manual
        }
        switch kind {
        case .claude, .claudeCode, .codex, .gemini, .copilot, .customCLI:
            return nil
        case .ollama:
            return Config(baseURL: URL(string: "http://localhost:11434/v1")!,
                          model: selected(Self.ollamaModel), apiKey: nil)
        case .custom:
            let base = Self.customBaseURL.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: base), !base.isEmpty, !Self.customModel.isEmpty else { return nil }
            return Config(baseURL: url, model: selected(Self.customModel),
                          apiKey: APIKeyStore.load(account: "custom-llm-api-key"))
        }
    }

    var isConfigured: Bool { currentConfig() != nil }

    // MARK: - Usage metering (same pattern as ClaudeAnalysisProvider)

    private let usageLock = NSLock()
    private var meteredUsage = AITokenTotals()
    private var usedModels = Set<String>()

    var usageModel: String? {
        usageLock.lock(); defer { usageLock.unlock() }
        return usedModels.count > 1 ? "Multiple models" : usedModels.first
    }

    var usageTotals: AITokenTotals {
        usageLock.lock(); defer { usageLock.unlock() }
        return meteredUsage
    }

    func resetUsage() {
        usageLock.lock(); defer { usageLock.unlock() }
        meteredUsage = AITokenTotals()
        usedModels.removeAll()
    }

    private func recordUsage(_ usage: ChatResponse.Usage?, model: String) {
        recordNativeUsage(prompt: usage?.promptTokens, completion: usage?.completionTokens, model: model)
    }

    func recordNativeUsage(prompt: Int?, completion: Int?, model: String) {
        usageLock.lock(); defer { usageLock.unlock() }
        meteredUsage.inputTokens += prompt ?? 0
        meteredUsage.outputTokens += completion ?? 0
        meteredUsage.calls += 1
        usedModels.insert(model)
    }

    // MARK: - AnalysisProvider

    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult {
        guard let config = currentConfig(context: .live(request)) else {
            throw AnalysisError.badResponse("Assistant model not set up. Check Settings → Assistant.")
        }

        let sys = ClaudeAnalysisProvider.systemPrompt(
            persona: request.persona, kinds: request.kinds,
            gauges: request.gauges, counterpart: request.counterpart)
        let userContent = ClaudeAnalysisProvider.analysisUserContent(request)
        let schemaObj = ClaudeAnalysisProvider.schema(kinds: request.kinds, gauges: request.gauges)

        let text = try await structuredChat(system: sys, user: userContent,
                                            schema: schemaObj, maxTokens: 1024, config: config)
        let parsed = try ClaudeAnalysisProvider.parseAnalysisPayload(text)
        let sourceValidated = ClaudeAnalysisProvider.validatingSources(
            parsed.insights, knownDocuments: request.knownDocumentNames + ClaudeAnalysisProvider.screenSources(request))
        let kindValidated = ClaudeAnalysisProvider.validatingKinds(
            sourceValidated, allowed: Set(request.kinds.map(\.key)))
        return AnalysisResult(insights: kindValidated, sentiment: parsed.sentiment,
                              read: parsed.read, coach: parsed.coach, resolved: parsed.resolved)
    }

    func summarize(transcript: String, insightTitles: [String], bookmarks: [String] = [],
                   instructions: String,
                   counterpart: String = "the other person", template: ReportTemplate) async throws -> String {
        guard let config = currentConfig(context: .init(task: .report, contextLength: transcript.count)) else {
            throw AnalysisError.badResponse("Assistant model not set up. Check Settings → Assistant.")
        }
        return try await plainChat(
            system: ClaudeAnalysisProvider.summarySystemPrompt(counterpart: counterpart, template: template),
            user: ClaudeAnalysisProvider.summaryUserContent(
                transcript: transcript, insightTitles: insightTitles,
                bookmarks: bookmarks, instructions: instructions),
            maxTokens: 1700, config: config)
    }

    func coachingReport(transcript: String, talkPercentMe: Int, instructions: String,
                        counterpart: String = "the other person", template: ReportTemplate) async throws -> String {
        guard let config = currentConfig(context: .init(task: .report, contextLength: transcript.count)) else {
            throw AnalysisError.badResponse("Assistant model not set up. Check Settings → Assistant.")
        }
        return try await plainChat(
            system: ClaudeAnalysisProvider.coachingSystemPrompt(counterpart: counterpart, template: template),
            user: ClaudeAnalysisProvider.coachingUserContent(
                transcript: transcript, talkPercentMe: talkPercentMe,
                instructions: instructions, counterpart: counterpart),
            maxTokens: 1400, config: config)
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await complete(system: system, user: user, maxTokens: maxTokens, context: .init(task: .general))
    }

    func complete(system: String, user: String, maxTokens: Int, context: ModelTaskContext) async throws -> String {
        guard let config = currentConfig(context: context) else {
            throw AnalysisError.badResponse("Assistant model not set up. Check Settings → Assistant.")
        }
        return try await plainChat(system: system, user: user, maxTokens: maxTokens, config: config)
    }

    // MARK: - Chat plumbing

    /// Structured-output call — stays on the OpenAI-compat endpoint for EVERY
    /// kind, including Ollama: analysis prompts are small (rolling window,
    /// ~1-2k tokens — no truncation risk), and Ollama's native "format" param
    /// enforces the schema with grammar-constrained decoding that crawled at
    /// ~0.35 tok/s on gemma3:4b (measured 2026-07-17: 599s vs 28s for the same
    /// request). Loose schema + the validation layer is the right trade here.
    /// Tries strict `json_schema` first; falls back once to `json_object` with
    /// the schema inlined in the prompt.
    private func structuredChat(system: String, user: String, schema: [String: Any],
                                maxTokens: Int, config: Config) async throws -> String {
        let strictBody: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "analysis", "strict": true, "schema": schema],
            ],
        ]
        do {
            return try await send(body: strictBody, config: config)
        } catch let AnalysisError.badResponse(message) where message.contains("HTTP 4") || message.lowercased().contains("response_format") {
            // Server doesn't do strict schemas — inline it and ask for JSON mode.
            let schemaText = (try? JSONSerialization.data(withJSONObject: schema))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let fallbackBody: [String: Any] = [
                "model": config.model,
                "max_tokens": maxTokens,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user + "\n\n---\n\nRespond with ONLY a JSON object matching exactly this JSON Schema (no prose, no code fences):\n" + schemaText],
                ],
                "response_format": ["type": "json_object"],
            ]
            return try await send(body: fallbackBody, config: config)
        }
    }

    /// Thinking models (OpenRouter's reasoning models, qwen3 on Ollama) spend
    /// part of max_tokens on hidden reasoning and can stop before the answer.
    /// One retry with a much bigger budget instead of failing the report (#146).
    private func plainChat(system: String, user: String, maxTokens: Int,
                           config: Config) async throws -> String {
        do {
            return try await plainChatOnce(system: system, user: user,
                                           maxTokens: maxTokens, config: config)
        } catch let AnalysisError.badResponse(message) where message.contains("truncated") {
            return try await plainChatOnce(system: system, user: user,
                                           maxTokens: maxTokens * 4, config: config)
        }
    }

    private func plainChatOnce(system: String, user: String, maxTokens: Int,
                               config: Config) async throws -> String {
        if kindSource() == .ollama {
            return try await sendOllamaNative(system: system, user: user, schema: nil,
                                              maxTokens: maxTokens, config: config)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        return try await send(body: body, config: config)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Ollama native endpoint

    /// Ollama's OpenAI-compat endpoint silently TRUNCATES prompts to the model's
    /// default context (4096 tokens) and ignores num_ctx overrides — measured
    /// 2026-07-17: a 9k-token transcript came back as prompt_tokens: 2050. An
    /// hour-long call's report would quietly read only a slice of the call.
    /// The native /api/chat endpoint honors options.num_ctx, so REPORT calls
    /// (long transcript, plain text) go through it with the context sized to
    /// the prompt. Live analysis stays on the compat endpoint — see
    /// structuredChat for why (schema-grammar decoding is unusably slow).
    private func sendOllamaNative(system: String, user: String, schema: [String: Any]?,
                                  maxTokens: Int, config: Config) async throws -> String {
        // ~3 chars/token is conservative for mixed-language text; headroom for
        // the reply + template. Clamped: 32k ctx on a 3-4B model is ~2 GB of
        // KV cache — fine on Apple Silicon, and calls longer than that get the
        // most-recent-first truncation Ollama applies at the cap.
        // ROUNDED TO POWER-OF-TWO BUCKETS: Ollama reloads the whole model when
        // num_ctx changes between requests, and the summary + coaching calls
        // are seconds apart with slightly different prompt sizes — exact
        // sizing forced a ~30s reload in the middle of every report.
        let estimated = (system.count + user.count) / 3 + maxTokens + 512
        var numCtx = 4096
        while numCtx < estimated && numCtx < 32768 { numCtx *= 2 }

        var body: [String: Any] = [
            "model": config.model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            // Low temperature: reports and Ask answers are factual, and a
            // small model at Ollama's default of 0.8 drifts (miscounts, mixes
            // up speakers).
            "options": ["num_ctx": numCtx, "num_predict": maxTokens, "temperature": 0.2],
        ]
        if let schema { body["format"] = schema }

        // Native root = base URL without the /v1 suffix.
        var root = config.baseURL
        if root.lastPathComponent == "v1" { root.deleteLastPathComponent() }
        var request = URLRequest(url: root.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        // Prompt evaluation on a long transcript is minutes, not seconds, on
        // some machines — reports aren't latency-critical.
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        struct NativeResponse: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let promptEvalCount: Int?
            let evalCount: Int?
            let doneReason: String?
            enum CodingKeys: String, CodingKey {
                case message
                case promptEvalCount = "prompt_eval_count"
                case evalCount = "eval_count"
                case doneReason = "done_reason"
            }
        }

        for attempt in 0..<2 {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AnalysisError.badResponse("No HTTP response")
            }
            if attempt == 0, http.statusCode >= 500 {
                try await Task.sleep(for: .seconds(2))
                continue
            }
            guard http.statusCode == 200 else {
                throw AnalysisError.badResponse(Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)")
            }
            let decoded = try JSONDecoder().decode(NativeResponse.self, from: data)
            recordNativeUsage(prompt: decoded.promptEvalCount, completion: decoded.evalCount, model: config.model)
            guard decoded.doneReason != "length" else {
                throw AnalysisError.badResponse("Response truncated (hit max_tokens)")
            }
            guard let content = decoded.message.content?.nilIfEmpty else {
                throw AnalysisError.badResponse("Empty model response")
            }
            return Self.stripCodeFence(content)
        }
        throw AnalysisError.badResponse("Unreachable")
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
            let finishReason: String?
            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }
        }
        struct Usage: Decodable {
            let promptTokens: Int?
            let completionTokens: Int?
            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }
        let choices: [Choice]
        let usage: Usage?
    }

    private func send(body: [String: Any], config: Config) async throws -> String {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        // Local models can take a while on first token (model load); generous cap.
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.apiKey?.nilIfEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // ponytail: single retry with fixed backoff on transient failures,
        // mirroring ClaudeAnalysisProvider.
        for attempt in 0..<2 {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AnalysisError.badResponse("No HTTP response")
            }
            if attempt == 0, http.statusCode == 429 || http.statusCode >= 500 {
                try await Task.sleep(for: .seconds(2))
                continue
            }
            guard http.statusCode == 200 else {
                throw AnalysisError.badResponse(Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)")
            }
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            recordUsage(decoded.usage, model: config.model)
            guard decoded.choices.first?.finishReason != "length" else {
                throw AnalysisError.badResponse("Response truncated (hit max_tokens)")
            }
            guard let content = decoded.choices.first?.message.content?.nilIfEmpty else {
                throw AnalysisError.badResponse("Empty model response")
            }
            return Self.stripCodeFence(content)
        }
        throw AnalysisError.badResponse("Unreachable")
    }

    /// Small local models sometimes wrap JSON in ``` fences despite instructions.
    static func stripCodeFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        s = s.replacingOccurrences(of: "```json", with: "```")
        let parts = s.components(separatedBy: "```").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? s
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return object["error"] as? String
    }
}

// MARK: - Switching provider

/// Routes each call by JOB: live analysis passes go to the "Live cards"
/// provider, post-call summaries/coaching go to the "Post-call reports"
/// provider (Settings → Copilot). One compat instance per role keeps the token
/// meters separable so the cost row can price each bucket correctly. All
/// instances stay alive across settings changes; a mid-call switch mislabels
/// at most one meeting's rows (same accepted edge as the transcription-backend
/// note in RecordingManager.writeAIUsage).
final class SwitchingAnalysisProvider: AnalysisProvider {
    private let automatic = AssistantRoutingProvider()
    private let localCompat = OpenAICompatibleProvider { .ollama }

    static var liveKind: CopilotProviderKind {
        CloudGate.forcesLocal ? .ollama : (AssistantRoutingSettings.configuredKinds().first ?? .ollama)
    }
    static var reportsKind: CopilotProviderKind { liveKind }
    static var askKind: CopilotProviderKind { askPinnedKind ?? liveKind }

    static var askPinnedKind: CopilotProviderKind? {
        guard let raw = UserDefaults.standard.string(forKey: AssistantRoutingSettings.askPinnedKey), !raw.isEmpty,
              let kind = CopilotProviderKind(rawValue: raw),
              AssistantRoutingSettings.enabled(kind) else { return nil }
        return kind
    }

    static func askLabel(kind: CopilotProviderKind, model: String) -> String {
        switch kind {
        case .claude:
            let name = model.split(separator: "-").prefix(2).map { $0.capitalized }.joined(separator: " ")
            return "\(name) · cloud"
        case .ollama: return "\(model) · on this Mac"
        case .custom: return "\(model) · your server"
        case .claudeCode, .codex, .gemini, .copilot, .customCLI: return "\(model) · CLI account"
        }
    }

    var isConfigured: Bool { CloudGate.forcesLocal ? localCompat.isConfigured : automatic.isConfigured }

    static func canSendScreenImages(forceLocal: Bool = false) -> Bool {
        !forceLocal && !CloudGate.forcesLocal && !Redactor.isEnabled
            && AssistantRoutingSettings.configuredKinds().contains(where: AssistantRoutingSettings.supportsImages)
    }

    func analyze(_ original: AnalysisRequest) async throws -> AnalysisResult {
        var request = original
        if var screen = request.screenContext {
            screen.text = String(screen.text.prefix(4000))
            screen.sourceLabel = "Selected screen"
            if let jpeg = screen.jpeg, !ScreenContext.validateJPEG(jpeg) {
                throw AnalysisError.badResponse("Invalid screen JPEG.")
            }
            if !Self.canSendScreenImages(forceLocal: request.forceLocal) { screen.jpeg = nil }
            guard screen.jpeg != nil || !screen.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AnalysisError.badResponse("The enabled integrations cannot receive screen images and no screen text was available.")
            }
            request.screenContext = screen
        }
        if request.forceLocal || CloudGate.forcesLocal { return try await localCompat.analyze(request) }
        if AssistantRoutingSettings.routesLocally() { return try await automatic.analyze(request) }
        if request.previousCallIsPrivate { request.previousCallContext = "" }
        guard Redactor.isEnabled else { return try await automatic.analyze(request) }
        var redactor = Redactor()
        var redacted = redactor.redact(request)
        if var screen = request.screenContext {
            screen.jpeg = nil
            screen.text = redactor.redact(screen.text)
            redacted.screenContext = screen
        }
        return redactor.restore(try await automatic.analyze(redacted))
    }

    private var reportsProvider: AnalysisProvider { CloudGate.forcesLocal ? localCompat : automatic }
    private var reportsRedactor: Redactor? {
        (!reportsRunLocally && Redactor.isEnabled) ? Redactor() : nil
    }

    func summarize(transcript: String, insightTitles: [String], bookmarks: [String],
                   instructions: String, counterpart: String, template: ReportTemplate) async throws -> String {
        var redactor = reportsRedactor
        let answer = try await reportsProvider.summarize(
            transcript: redactor?.redact(transcript) ?? transcript,
            insightTitles: insightTitles.map { redactor?.redact($0) ?? $0 },
            bookmarks: bookmarks.map { redactor?.redact($0) ?? $0 },
            instructions: instructions, counterpart: counterpart, template: template)
        return redactor?.restore(answer) ?? answer
    }

    func coachingReport(transcript: String, talkPercentMe: Int, instructions: String,
                        counterpart: String, template: ReportTemplate) async throws -> String {
        var redactor = reportsRedactor
        let answer = try await reportsProvider.coachingReport(
            transcript: redactor?.redact(transcript) ?? transcript, talkPercentMe: talkPercentMe,
            instructions: instructions, counterpart: counterpart, template: template)
        return redactor?.restore(answer) ?? answer
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await complete(system: system, user: user, maxTokens: maxTokens, context: .init(task: .general))
    }

    func complete(system: String, user: String, maxTokens: Int, context: ModelTaskContext) async throws -> String {
        var redactor = reportsRedactor
        let answer = try await reportsProvider.complete(system: system, user: redactor?.redact(user) ?? user,
                                                        maxTokens: maxTokens, context: context)
        return redactor?.restore(answer) ?? answer
    }

    var reportsRunLocally: Bool { CloudGate.forcesLocal || AssistantRoutingSettings.routesLocally() }
    var reportsConfigured: Bool { isConfigured }
    func completeAsk(system: String, user: String, maxTokens: Int, context: ModelTaskContext) async throws -> String {
        if CloudGate.forcesLocal {
            return try await localCompat.complete(system: system, user: user, maxTokens: maxTokens, context: context)
        }
        var redactor = reportsRedactor
        let preferred = Self.askPinnedKind
        let answer = try await automatic.complete(system: system, user: redactor?.redact(user) ?? user,
                                                  maxTokens: maxTokens, context: context, preferredKind: preferred)
        return redactor?.restore(answer) ?? answer
    }
    var askRunsLocally: Bool { reportsRunLocally }
    var askUsesOllama: Bool { reportsRunLocally }
    var askConfigured: Bool { isConfigured }
    var askModelLabel: String {
        if CloudGate.forcesLocal { return Self.askLabel(kind: .ollama, model: localCompat.usageModel ?? CopilotProviderKind.modelName(for: .ollama)) }
        if let pinned = Self.askPinnedKind {
            let model = (automatic.provider(for: pinned) as? CLIAnalysisProvider)?.usageModel
                ?? (automatic.provider(for: pinned) as? OpenAICompatibleProvider)?.usageModel
                ?? CopilotProviderKind.modelName(for: pinned)
            return "\(model) · \(pinned.label)"
        }
        return automatic.usageModel.map { "\($0) · automatic routing" } ?? "Automatic · enabled integrations"
    }
    var liveUsage: (model: String, provider: String, totals: AITokenTotals) {
        if CloudGate.forcesLocal {
            return (localCompat.usageModel ?? CopilotProviderKind.modelName(for: .ollama), "ollama", localCompat.usageTotals)
        }
        return (automatic.usageModel ?? "Automatic", automatic.usageProvider, automatic.usageTotals)
    }
    var reportsUsage: (model: String, provider: String, totals: AITokenTotals)? { nil }
    var usageTotals: AITokenTotals {
        let automaticUsage = automatic.usageTotals
        let localUsage = localCompat.usageTotals
        return AITokenTotals(inputTokens: automaticUsage.inputTokens + localUsage.inputTokens,
                             outputTokens: automaticUsage.outputTokens + localUsage.outputTokens,
                             calls: automaticUsage.calls + localUsage.calls)
    }
    func resetUsage() { automatic.resetUsage(); localCompat.resetUsage() }
}

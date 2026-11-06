import Foundation

final class CLIAnalysisProvider: AnalysisProvider {
    private let kindSource: () -> CopilotProviderKind
    private let lock = NSLock()
    private var totals = AITokenTotals()
    private var usedModels = Set<String>()

    init(_ kindSource: @escaping () -> CopilotProviderKind) { self.kindSource = kindSource }

    static func setting(_ kind: CopilotProviderKind, _ suffix: String, defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: "cli_\(kind.rawValue)_\(suffix)") ?? ""
    }

    static func customArguments(_ arguments: [String], model: String) throws -> [String] {
        let selected = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty && !arguments.contains("{model}") {
            throw AnalysisError.badResponse("Add {model} as an argument in Settings to use the selected model.")
        }
        if selected.isEmpty && arguments.contains("{model}") {
            throw AnalysisError.badResponse("Enter a model ID in Settings or remove the {model} argument.")
        }
        let expanded = arguments.map { $0 == "{model}" ? selected : $0 }
        guard !expanded.contains("-c"), !expanded.contains("--command") else {
            throw AnalysisError.badResponse("Enter custom CLI arguments as a JSON array, without shell commands.")
        }
        return expanded
    }

    static func executable(_ kind: CopilotProviderKind) -> String {
        let path = setting(kind, "path").trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty { return path }
        switch kind {
        case .claudeCode: return "@claude"
        case .codex: return "@codex"
        case .gemini: return "@gemini"
        case .copilot: return "@copilot"
        default: return ""
        }
    }

    var isConfigured: Bool { !Self.executable(kindSource()).isEmpty }
    var usageTotals: AITokenTotals { lock.lock(); defer { lock.unlock() }; return totals }
    var usageModel: String? {
        lock.lock(); defer { lock.unlock() }
        return usedModels.count > 1 ? "Multiple models" : usedModels.first
    }
    func resetUsage() { lock.lock(); totals = AITokenTotals(); usedModels.removeAll(); lock.unlock() }
    func recordCall(kind: CopilotProviderKind, model: String) {
        lock.lock(); defer { lock.unlock() }
        usedModels.insert(model.isEmpty ? "\(kind.label) (default)" : model)
        totals.calls += 1
    }

    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult {
        let system = ClaudeAnalysisProvider.systemPrompt(persona: request.persona, kinds: request.kinds,
                                                         gauges: request.gauges, counterpart: request.counterpart)
        let schema = ClaudeAnalysisProvider.schema(kinds: request.kinds, gauges: request.gauges)
        let schemaData = try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])
        let schemaText = String(decoding: schemaData, as: UTF8.self)
        let text = try await call(system: system + "\nReturn only a JSON object matching this schema: " + schemaText,
                                  user: ClaudeAnalysisProvider.analysisUserContent(request), schema: schemaText, jpeg: request.screenContext?.jpeg)
        let parsed = try ClaudeAnalysisProvider.parseAnalysisPayload(text)
        let sources = ClaudeAnalysisProvider.validatingSources(parsed.insights, knownDocuments: request.knownDocumentNames + ClaudeAnalysisProvider.screenSources(request))
        let kinds = ClaudeAnalysisProvider.validatingKinds(sources, allowed: Set(request.kinds.map(\.key)))
        return AnalysisResult(insights: kinds, sentiment: parsed.sentiment, read: parsed.read,
                              coach: parsed.coach, resolved: parsed.resolved)
    }

    func summarize(transcript: String, insightTitles: [String], bookmarks: [String], instructions: String,
                   counterpart: String, template: ReportTemplate) async throws -> String {
        try await call(system: ClaudeAnalysisProvider.summarySystemPrompt(counterpart: counterpart, template: template),
                       user: ClaudeAnalysisProvider.summaryUserContent(transcript: transcript, insightTitles: insightTitles,
                                                                       bookmarks: bookmarks, instructions: instructions))
    }

    func coachingReport(transcript: String, talkPercentMe: Int, instructions: String,
                        counterpart: String, template: ReportTemplate) async throws -> String {
        try await call(system: ClaudeAnalysisProvider.coachingSystemPrompt(counterpart: counterpart, template: template),
                       user: ClaudeAnalysisProvider.coachingUserContent(transcript: transcript, talkPercentMe: talkPercentMe,
                                                                        instructions: instructions, counterpart: counterpart))
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await call(system: system, user: user)
    }

    private func call(system: String, user: String, schema: String? = nil, jpeg: Data? = nil) async throws -> String {
        let kind = kindSource()
        let executable = Self.executable(kind)
        let model = Self.setting(kind, "model").trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments: [String]
        switch kind {
        case .claudeCode:
            arguments = ["--print", "--output-format", jpeg == nil ? "json" : "stream-json", "--tools", "", "--safe-mode", "--strict-mcp-config",
                         "--disable-slash-commands", "--no-chrome", "--no-session-persistence", "--permission-prompts", "none"]
            if jpeg != nil { arguments += ["--input-format", "stream-json", "--verbose"] }
            if let schema { arguments += ["--json-schema", schema] }
            if !model.isEmpty { arguments += ["--model", model] }
        case .customCLI:
            guard let bytes = Self.setting(kind, "arguments").data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String].self, from: bytes),
                  !parsed.contains("-c"), !parsed.contains("--command"),
                  !["sh", "bash", "zsh", "fish", "dash"].contains(URL(fileURLWithPath: executable).lastPathComponent) else {
                throw AnalysisError.badResponse("Enter custom CLI arguments as a JSON array, without shell commands.")
            }
            arguments = try Self.customArguments(parsed, model: model)
        case .codex:
            arguments = ["exec", "--ignore-user-config", "--ephemeral", "--skip-git-repo-check", "--json",
                         "--sandbox", "read-only", "-c", "web_search=\"disabled\"", "-c", "project_doc_max_bytes=0", "--disable", "shell_tool",
                         "--disable", "unified_exec", "--disable", "hooks", "--disable", "plugins", "--disable", "apps",
                         "--disable", "browser_use", "--disable", "computer_use", "--disable", "view_image"]
            if !model.isEmpty { arguments += ["--model", model] }
            arguments += ["-"]
        case .copilot:
            arguments = ["--available-tools=parrot_no_tools", "--disable-builtin-mcps", "--no-custom-instructions",
                         "--no-auto-update", "--no-remote", "--no-remote-export", "--no-ask-user", "--no-bash-env",
                         "--log-level", "none", "--output-format", "json"]
            if !model.isEmpty { arguments += ["--model", model] }
        case .gemini:
            arguments = ["-p", "Answer the supplied text.", "-o", "json"]
            if !model.isEmpty { arguments += ["--model", model] }
        default:
            throw AnalysisError.badResponse("Invalid CLI provider.")
        }
        guard !executable.isEmpty else { throw AnalysisError.badResponse("Set the CLI executable path in Settings.") }
        let identifier = UUID().uuidString
        var payload: [String: Any] = ["operation": "cli", "id": identifier, "executable": executable,
                                      "arguments": arguments, "input": "\(system)\n\n\(user)", "timeout": 90.0,
                                      "preset": kind.rawValue]
        if let jpeg {
            guard [.claudeCode, .codex, .copilot].contains(kind), ScreenContext.validateJPEG(jpeg) else {
                throw AnalysisError.badResponse("This CLI cannot accept the selected screen image.")
            }
            payload["jpeg"] = jpeg.base64EncodedString()
        }
        let response = try await HostHelperClient.shared.perform(JSONSerialization.data(withJSONObject: payload), identifier: identifier)
        let text: String
        if kind == .claudeCode {
            text = try Self.claudeAnswer(response)
        } else {
            let format = kind == .codex ? "codex" : kind == .copilot ? "copilot" : kind == .gemini ? "gemini" : Self.setting(kind, "format")
            text = try Self.customAnswer(response, format: format)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AnalysisError.badResponse("CLI returned an empty answer.") }
        recordCall(kind: kind, model: model)
        return text
    }

    static func claudeAnswer(_ response: Data) throws -> String {
        let decoded = try? JSONSerialization.jsonObject(with: response)
        let events: [[String: Any]]
        if let array = decoded as? [[String: Any]] { events = array }
        else if let object = decoded as? [String: Any] { events = [object] }
        else if let text = String(data: response, encoding: .utf8) {
            events = try text.split(whereSeparator: \.isNewline).map { line in
                guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    throw AnalysisError.badResponse("Invalid Claude Code response.")
                }
                return object
            }
        } else { throw AnalysisError.badResponse("Invalid Claude Code response.") }
        guard let object = events.last(where: { ($0["type"] as? String) == "result" }) ?? (events.count == 1 ? events.first : nil),
              object["is_error"] as? Bool == false else {
                throw AnalysisError.badResponse("Claude Code returned an error. Check its sign-in and configuration.")
        }
        if let structured = object["structured_output"], JSONSerialization.isValidJSONObject(structured) {
            return String(decoding: try JSONSerialization.data(withJSONObject: structured), as: UTF8.self)
        }
        guard let result = object["result"] as? String else { throw AnalysisError.badResponse("Claude Code returned no answer.") }
        return result
    }

    static func customAnswer(_ response: Data, format: String) throws -> String {
        guard let text = String(data: response, encoding: .utf8) else { throw AnalysisError.badResponse("CLI returned invalid UTF-8.") }
        if format.isEmpty || format == "plain" { return text }
        if format == "claude" { return try claudeAnswer(response) }
        if format == "gemini" {
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  object["error"] == nil, let answer = object["response"] as? String else {
                throw AnalysisError.badResponse("Invalid Gemini CLI response.")
            }
            return answer
        }
        guard format == "codex" || format == "copilot" else { throw AnalysisError.badResponse("Invalid CLI output format.") }
        let events: [[String: Any]] = try text.split(whereSeparator: \.isNewline).map { line in
            guard let event = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                throw AnalysisError.badResponse("Invalid CLI event.")
            }
            return event
        }
        if format == "codex", events.last?["type"] as? String == "turn.completed",
           !events.contains(where: { $0["type"] as? String == "turn.failed" }), let event = events.last(where: { event in
            guard event["type"] as? String == "item.completed", let item = event["item"] as? [String: Any] else { return false }
            return item["type"] as? String == "agent_message"
        }),
           let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message", let answer = item["text"] as? String { return answer }
        if format == "copilot", !events.contains(where: { $0["type"] as? String == "session.error" }),
           let event = events.last(where: { $0["type"] as? String == "assistant.message" }),
           let message = event["data"] as? [String: Any], let answer = message["content"] as? String { return answer }
        throw AnalysisError.badResponse("CLI returned no final answer.")
    }
}

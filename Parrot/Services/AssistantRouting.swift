import Foundation

enum AssistantRoutingSettings {
    static let enabledKey = "assistantEnabledIntegrations"
    static let availableKinds: [CopilotProviderKind] = [.claudeCode, .codex, .gemini, .copilot, .customCLI, .ollama]

    static func configuredKinds(in defaults: UserDefaults = .standard) -> [CopilotProviderKind] {
        let saved = (defaults.string(forKey: enabledKey) ?? "").split(separator: ",").compactMap { CopilotProviderKind(rawValue: String($0)) }
        return availableKinds.filter { saved.contains($0) }
    }

    static func enabled(_ kind: CopilotProviderKind, defaults: UserDefaults = .standard) -> Bool {
        configuredKinds(in: defaults).contains(kind)
    }

    static func setEnabled(_ enabled: Bool, kind: CopilotProviderKind, defaults: UserDefaults = .standard) {
        var kinds = configuredKinds(in: defaults)
        kinds.removeAll { $0 == kind }
        if enabled && availableKinds.contains(kind) { kinds.append(kind) }
        defaults.set(kinds.map(\.rawValue).joined(separator: ","), forKey: enabledKey)
    }

    static func migrate(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: enabledKey) == nil else { return }
        let previous = ["copilotProvider", "reportsProvider", "askProvider"].compactMap { defaults.string(forKey: $0) }
        let kinds = availableKinds.filter { previous.contains($0.rawValue) }
        defaults.set(kinds.map(\.rawValue).joined(separator: ","), forKey: enabledKey)
        defaults.set(TranscriptionBackend.local.rawValue, forKey: TranscriptionBackend.defaultsKey)
        defaults.set(true, forKey: TranscriptPolisher.onDeviceKey)
    }

    static func routesLocally(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: CloudGate.globalKey) || configuredKinds(in: defaults).allSatisfy { $0 == .ollama }
    }

    static func supportsImages(_ kind: CopilotProviderKind) -> Bool {
        [.claudeCode, .codex, .copilot].contains(kind)
    }
}

/// Failure history contains provider identifiers and timestamps only.
final class AssistantRouteState {
    private let lock = NSLock()
    private var retryAfter: [CopilotProviderKind: Date] = [:]
    private var successful: CopilotProviderKind?

    func candidates(_ enabled: [CopilotProviderKind], images: Bool, now: Date = Date()) -> [CopilotProviderKind] {
        lock.lock(); defer { lock.unlock() }
        let eligible = enabled.filter {
            (!images || AssistantRoutingSettings.supportsImages($0)) && (retryAfter[$0] ?? .distantPast) <= now
        }
        guard let successful, eligible.contains(successful) else { return eligible }
        return [successful] + eligible.filter { $0 != successful }
    }

    func succeeded(_ kind: CopilotProviderKind) {
        lock.lock(); defer { lock.unlock() }
        successful = kind
        retryAfter.removeValue(forKey: kind)
    }

    func failed(_ kind: CopilotProviderKind, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        retryAfter[kind] = now.addingTimeInterval(60)
        if successful == kind { successful = nil }
    }
}

final class AssistantRoutingProvider: AnalysisProvider {
    private let state = AssistantRouteState()
    private let defaults: UserDefaults
    private let providers: [CopilotProviderKind: AnalysisProvider]
    private let lock = NSLock()
    private var lastKind: CopilotProviderKind?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        AssistantRoutingSettings.migrate(in: defaults)
        var providers: [CopilotProviderKind: AnalysisProvider] = [.ollama: OpenAICompatibleProvider { .ollama }]
        for kind in AssistantRoutingSettings.availableKinds where kind.isCLI {
            providers[kind] = CLIAnalysisProvider { kind }
        }
        self.providers = providers
    }

    var isConfigured: Bool { !AssistantRoutingSettings.configuredKinds(in: defaults).isEmpty }
    var usageTotals: AITokenTotals {
        providers.values.reduce(AITokenTotals()) { total, provider in
            let usage = provider.usageTotals
            return AITokenTotals(inputTokens: total.inputTokens + usage.inputTokens,
                                 outputTokens: total.outputTokens + usage.outputTokens, calls: total.calls + usage.calls)
        }
    }
    var usageModel: String? {
        if providers.values.filter({ $0.usageTotals.calls > 0 }).count > 1 { return "Multiple models" }
        lock.lock(); let kind = lastKind; lock.unlock()
        guard let kind else { return nil }
        return (providers[kind] as? CLIAnalysisProvider)?.usageModel
            ?? (providers[kind] as? OpenAICompatibleProvider)?.usageModel
            ?? CopilotProviderKind.modelName(for: kind)
    }
    var usageProvider: String {
        lock.lock(); defer { lock.unlock() }
        let used = providers.filter { $0.value.usageTotals.calls > 0 }.map(\.key)
        return used.count == 1 ? used[0].rawValue : "assistantIntegrations"
    }
    func resetUsage() { for provider in providers.values { provider.resetUsage() } }

    private func route<Answer>(images: Bool = false, operation: (AnalysisProvider) async throws -> Answer) async throws -> Answer {
        try Task.checkCancellation()
        let enabled = CloudGate.forcesLocal ? [.ollama] : AssistantRoutingSettings.configuredKinds(in: defaults)
        let candidates = state.candidates(enabled, images: images)
        var failures: [String] = []
        for kind in candidates {
            try Task.checkCancellation()
            guard let provider = providers[kind] else { continue }
            do {
                if kind.isCLI && kind != .customCLI { try await CLIAnalysisProvider.checkExecutable(kind) }
                try Task.checkCancellation()
                guard kind == .ollama || (!CloudGate.forcesLocal && AssistantRoutingSettings.enabled(kind, defaults: defaults)) else { continue }
                let answer = try await operation(provider)
                try Task.checkCancellation()
                state.succeeded(kind)
                remember(kind)
                return answer
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                state.failed(kind)
                failures.append("\(kind.label): \(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            throw AnalysisError.badResponse(enabled.isEmpty
                ? "Enable an assistant integration in Settings → Assistant."
                : "No enabled integration is ready for this request. Failed integrations retry after one minute. Check sign-in and screen support in Settings → Assistant.")
        }
        throw AnalysisError.badResponse(failures.joined(separator: "\n"))
    }

    private func remember(_ kind: CopilotProviderKind) {
        lock.lock(); lastKind = kind; lock.unlock()
    }

    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult {
        if request.forceLocal {
            return try await providers[.ollama]!.analyze(request)
        }
        return try await route(images: request.screenContext?.jpeg != nil) { try await $0.analyze(request) }
    }

    func summarize(transcript: String, insightTitles: [String], bookmarks: [String], instructions: String,
                   counterpart: String, template: ReportTemplate) async throws -> String {
        try await route { try await $0.summarize(transcript: transcript, insightTitles: insightTitles, bookmarks: bookmarks,
                                               instructions: instructions, counterpart: counterpart, template: template) }
    }

    func coachingReport(transcript: String, talkPercentMe: Int, instructions: String, counterpart: String,
                        template: ReportTemplate) async throws -> String {
        try await route { try await $0.coachingReport(transcript: transcript, talkPercentMe: talkPercentMe,
                                                     instructions: instructions, counterpart: counterpart, template: template) }
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> String {
        try await complete(system: system, user: user, maxTokens: maxTokens, context: .init(task: .general))
    }

    func complete(system: String, user: String, maxTokens: Int, context: ModelTaskContext) async throws -> String {
        try await route { try await $0.complete(system: system, user: user, maxTokens: maxTokens, context: context) }
    }
}

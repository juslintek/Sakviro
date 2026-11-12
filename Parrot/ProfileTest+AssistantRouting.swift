import Foundation

extension ProfileTest {
    static func testAssistantRouting() {
        let suite = "parrot-assistant-routing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("gemini", forKey: "copilotProvider")
        defaults.set("claude", forKey: "reportsProvider")
        defaults.set("codex", forKey: "askProvider")
        defaults.set("selected-model", forKey: "cli_gemini_model")
        defaults.set("deepgram", forKey: TranscriptionBackend.defaultsKey)
        defaults.set(false, forKey: TranscriptPolisher.onDeviceKey)
        AssistantRoutingSettings.migrate(in: defaults)
        check("assistant routing: keeps connected CLI choices", AssistantRoutingSettings.configuredKinds(in: defaults) == [.codex, .gemini])
        check("assistant routing: excludes app API providers", !AssistantRoutingSettings.enabled(.claude, defaults: defaults))
        check("assistant routing: retains manual models", defaults.string(forKey: "cli_gemini_model") == "selected-model")
        check("assistant routing: audio moves to local transcription", defaults.string(forKey: TranscriptionBackend.defaultsKey) == "local")
        check("assistant routing: polish moves on device", defaults.bool(forKey: TranscriptPolisher.onDeviceKey))
        AssistantRoutingSettings.setEnabled(false, kind: .gemini, defaults: defaults)
        AssistantRoutingSettings.setEnabled(true, kind: .ollama, defaults: defaults)
        AssistantRoutingSettings.migrate(in: defaults)
        check("assistant routing: migration preserves later consent", AssistantRoutingSettings.configuredKinds(in: defaults) == [.codex, .ollama])
        AssistantRoutingSettings.setEnabled(true, kind: .claude, defaults: defaults)
        check("assistant routing: API provider cannot be enabled", !AssistantRoutingSettings.enabled(.claude, defaults: defaults))
        check("assistant routing: mixed routes may leave Mac", !AssistantRoutingSettings.routesLocally(in: defaults))
        defaults.set(true, forKey: CloudGate.globalKey)
        check("assistant routing: privacy overrides connected resources", AssistantRoutingSettings.routesLocally(in: defaults))
        defaults.set(false, forKey: CloudGate.globalKey)
        defaults.set("", forKey: AssistantRoutingSettings.enabledKey)
        AssistantRoutingSettings.migrate(in: defaults)
        check("assistant routing: empty consent stays empty", AssistantRoutingSettings.configuredKinds(in: defaults).isEmpty)
        defaults.removeObject(forKey: AssistantRoutingSettings.enabledKey)
        defaults.set("claude", forKey: "copilotProvider")
        defaults.set("", forKey: "askProvider")
        AssistantRoutingSettings.migrate(in: defaults)
        check("assistant routing: old API choice needs fresh assistant consent", AssistantRoutingSettings.configuredKinds(in: defaults).isEmpty)

        let state = AssistantRouteState()
        let now = Date(timeIntervalSince1970: 100)
        let enabled: [CopilotProviderKind] = [.claudeCode, .codex, .gemini]
        check("assistant routing: deterministic initial order", state.candidates(enabled, images: false, now: now) == enabled)
        state.failed(.claudeCode, now: now)
        check("assistant routing: failed resource falls back", state.candidates(enabled, images: false, now: now) == [.codex, .gemini])
        state.succeeded(.gemini)
        check("assistant routing: recent working resource first", state.candidates(enabled, images: false, now: now) == [.gemini, .codex])
        check("assistant routing: screen requests filter incompatible resources", state.candidates(enabled, images: true, now: now) == [.codex])
        check("assistant routing: failed resource retries after backoff", state.candidates(enabled, images: false, now: now.addingTimeInterval(61)) == [.gemini, .claudeCode, .codex])
        check("assistant routing: disabled resource cannot receive fallback", state.candidates([.codex], images: false, now: now) == [.codex])
        check("assistant routing: private route excludes prior online success", state.candidates([.ollama], images: false, now: now) == [.ollama])
        state.failed(.codex, now: now)
        check("assistant routing: unavailable image routes fail closed", state.candidates(enabled, images: true, now: now).isEmpty)

        for provider in ["claudeCode", "codex", "gemini", "copilot", "customCLI", "assistantIntegrations"] {
            var usage = AIUsage()
            usage.copilotProvider = provider
            usage.copilot = AITokenTotals(calls: 1)
            let lines = PrivacyLedger.lines(onDeviceOnly: false, usage: usage)
            check("assistant routing: ledger identifies \(provider) text destination", lines.count == 1 && lines[0].hasPrefix("Transcript text →"))
            usage.copilot = AITokenTotals()
            usage.reportsProvider = provider
            usage.reports = AITokenTotals(calls: 1)
            check("assistant routing: ledger identifies \(provider) report destination",
                  PrivacyLedger.lines(onDeviceOnly: false, usage: usage).first?.hasSuffix("for the report") == true)
        }
    }
}

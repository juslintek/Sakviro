import SwiftUI

struct CopilotPathStep: View {
    @Environment(OnboardingModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: Theme.Metrics.pad) {
                StepHeader(title: "Connect your assistants",
                           subtitle: "Enable one or several. The Assistant chooses an available connection for each request.")
                Toggle("Enable the Assistant during recordings", isOn: $model.copilotOn)
                    .toggleStyle(.switch)
                AssistantIntegrationsView(enabledIntegrations: $model.enabledIntegrations)
                Text("You can continue without a connection and add one later in Settings → Assistant.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink2)
            }
            .padding(Theme.Metrics.pad)
        }
    }
}

struct AssistantIntegrationsView: View {
    @Binding var enabledIntegrations: String
    @AppStorage(CloudGate.globalKey) private var onDeviceOnly = false

    private func enabled(_ kind: CopilotProviderKind) -> Binding<Bool> {
        Binding(get: { enabledIntegrations.split(separator: ",").contains(Substring(kind.rawValue)) }, set: { enabled in
            var kinds = enabledIntegrations.split(separator: ",").map(String.init)
            kinds.removeAll { $0 == kind.rawValue }
            if enabled { kinds.append(kind.rawValue) }
            enabledIntegrations = kinds.joined(separator: ",")
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.pad) {
            Text("Audio and transcription stay on this Mac. Enabled account connections receive meeting text and, when supported and allowed, selected-window images.")
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
            if onDeviceOnly {
                Label("On-device only is on. Account connections stay selected but are held until you change Settings → Privacy. Ollama can still run locally.", systemImage: "lock.shield")
                    .font(Theme.Typography.secondary)
            }
            ForEach(AssistantRoutingSettings.availableKinds) { kind in
                VStack(alignment: .leading, spacing: Theme.Metrics.controlGap) {
                    Toggle(title(kind), isOn: enabled(kind))
                        .toggleStyle(.checkbox)
                        .font(Theme.Typography.cardTitle)
                    Text(detail(kind))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.ink2)
                    if let setupURL = setupURL(kind) {
                        Link("Install and sign in", destination: setupURL)
                            .font(Theme.Typography.caption)
                    }
                    if enabled(kind).wrappedValue {
                        if kind.isCLI {
                            DisclosureGroup("Connection and model settings") {
                                CLIProviderSettings(kind: kind)
                            }
                        } else if kind == .custom {
                            DisclosureGroup("Custom server settings") {
                                CustomProviderSettingsView()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            Text("Sign in through each CLI before using it. Check verifies installation. Sign-in and plan limits are confirmed when a request runs. If a connection fails, the Assistant tries another enabled connection that supports the request.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink2)
            Text("Claude Desktop and other desktop MCP connectors let you ask those apps about saved meetings. Background assistance uses the CLI connections above.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.ink2)
        }
    }

    private func setupURL(_ kind: CopilotProviderKind) -> URL? {
        switch kind {
        case .claudeCode: URL(string: "https://code.claude.com/docs/en/quickstart")
        case .codex: URL(string: "https://developers.openai.com/codex/auth/")
        case .gemini: URL(string: "https://geminicli.com/docs/get-started/authentication/")
        case .copilot: URL(string: "https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-cli")
        case .ollama: OllamaInstaller.websiteURL
        default: nil
        }
    }

    private func title(_ kind: CopilotProviderKind) -> String {
        switch kind {
        case .claudeCode: "Claude / Claude Code"
        case .codex: "ChatGPT / Codex"
        case .gemini: "Gemini CLI"
        default: kind.label
        }
    }

    private func detail(_ kind: CopilotProviderKind) -> String {
        switch kind {
        case .claudeCode: "Uses your signed-in Claude Code CLI. Supports meeting text and selected-window images."
        case .codex: "Uses Codex CLI with your ChatGPT account. Supports meeting text and selected-window images."
        case .gemini: "Uses your signed-in Gemini CLI for meeting text. Screen analysis is unavailable with this connection."
        case .copilot: "Uses your signed-in GitHub Copilot CLI. Supports meeting text and selected-window images."
        case .customCLI: "Use a trusted local CLI executable. This connection supports text only."
        case .custom: "Connects to any OpenAI-compatible API or Google AI Studio. Supports meeting text and selected-window images."
        case .ollama: "Runs on this Mac. Download and start a model in the next setup step or Settings."
        default: ""
        }
    }
}

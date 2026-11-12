import SwiftUI

/// What's set up, Copilot first. Reads real state, so a download still in
/// flight says so.
struct ReadyStep: View {
    @Environment(OnboardingModel.self) private var model
    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @AppStorage(CopilotPathSettings.enableWhenReadyKey) private var enableWhenReady = false
    @AppStorage("copilotOllamaModel") private var ollamaModel = "llama3.2:3b"
    @AppStorage(AssistantRoutingSettings.enabledKey) private var enabledIntegrations = ""
    @AppStorage(CloudGate.globalKey) private var onDeviceOnly = false
    @State private var celebrate = false

    var body: some View {
        let ollama = recordingManager.ollama
        let status = CopilotStatus.current(
            copilotEnabled: copilotEnabled, enabledKinds: enabledIntegrations.split(separator: ",").compactMap { CopilotProviderKind(rawValue: String($0)) }, onDeviceOnly: onDeviceOnly,
            enableWhenReady: enableWhenReady, ollamaPulling: ollama.isPulling, ollamaProgress: ollama.pullProgress)
        let copy = Self.copy(status, path: model.path, ollamaModel: ollamaModel)
        VStack(spacing: 16) {
            Text("🎉")
                .font(.system(size: 56))
                .scaleEffect(celebrate ? 1.0 : 0.4)
                .opacity(celebrate ? 1 : 0)
            StepHeader(title: Self.title(status, mode: model.mode),
                       subtitle: "Downloads keep going after you close this.")
            CopilotHeroCard(title: copy.title, subtitle: copy.detail, emphasized: status == .on) {
                if status == .on {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.appTitle2)
                        .foregroundStyle(Theme.Colors.good)
                }
            }
            if model.mode == .full {
                SpeechDownloadRow(backup: false)
            }
        }
        .frame(maxWidth: 480)
        .padding(Theme.Metrics.pad)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.55).delay(0.05)) { celebrate = true }
        }
    }

    /// The short tour claims "set up" only when Copilot is on or on its way.
    static func title(_ status: CopilotStatus, mode: OnboardingMode) -> String {
        guard mode == .copilot else { return "Ready to go" }
        switch status {
        case .on, .waitingForModel: return "The Assistant is set up"
        case .finishOllama, .needsIntegration, .heldOnDevice, .off: return "Almost there"
        }
    }

    static func copy(_ status: CopilotStatus, path: CopilotPath?, ollamaModel: String) -> (title: String, detail: String) {
        switch status {
        case .on where path == .private:
            ("The Assistant is on, running on this Mac", "Uses \(ollamaModel) on this Mac.")
        case .on:
            ("Automatic routing is enabled", "The Assistant will try your enabled connections. Sign-in is checked when a request runs.")
        case .waitingForModel(let progress):
            ("The Assistant turns on when \(ollamaModel) finishes",
             progress.map { "\(Int($0 * 100))% downloaded. Keep going." } ?? "Starting the download.")
        case .finishOllama:
            ("The Assistant is almost there", "Finish the Ollama setup from the card on Home.")
        case .needsIntegration:
            ("No assistant connection is enabled", "Add an account connection or Ollama in Settings → Assistant.")
        case .heldOnDevice:
            ("Account connections are held", "On-device only is on. Enable Ollama or change Settings → Privacy to use an account connection.")
        case .off:
            ("The Assistant is off for now", "Set it up any time from the card on Home.")
        }
    }
}

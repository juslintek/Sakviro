import SwiftUI

struct CLIProviderSettings: View {
    let kind: CopilotProviderKind
    @State private var path: String
    @State private var model: String
    @State private var arguments: String
    @State private var format: String
    @State private var checkMessage = ""
    @State private var checking = false

    init(kind: CopilotProviderKind) {
        self.kind = kind
        _path = State(initialValue: CLIAnalysisProvider.setting(kind, "path"))
        _model = State(initialValue: CLIAnalysisProvider.setting(kind, "model"))
        _arguments = State(initialValue: CLIAnalysisProvider.setting(kind, "arguments"))
        let savedFormat = CLIAnalysisProvider.setting(kind, "format")
        _format = State(initialValue: savedFormat.isEmpty ? "plain" : savedFormat)
    }

    private func save(_ suffix: String, _ value: String) {
        UserDefaults.standard.set(value, forKey: "cli_\(kind.rawValue)_\(suffix)")
        checkMessage = ""
    }

    var body: some View {
        SettingsLabeledRow(title: "Executable", detail: kind == .customCLI ? "Absolute path to a trusted executable." : "Leave blank to search common locations on this Mac.") {
            TextField("Absolute path", text: $path)
                .textFieldStyle(.roundedBorder).frame(width: 260)
                .onChange(of: path) { _, value in save("path", value) }
            Button(checking ? "Checking…" : "Check") { Task { await check() } }
                .disabled(checking)
        }
        if kind == .customCLI {
            SettingsLabeledRow(title: "Arguments", detail: "JSON array of fixed arguments. The prompt is sent through stdin.") {
                TextField("[]", text: $arguments).textFieldStyle(.roundedBorder).frame(width: 260)
                    .onChange(of: arguments) { _, value in save("arguments", value) }
            }
            SettingsLabeledRow(title: "Output format") {
                Picker("", selection: $format) {
                    Text("Plain text").tag("plain")
                    Text("Claude JSON").tag("claude")
                    Text("Gemini JSON").tag("gemini")
                    Text("Codex JSONL").tag("codex")
                    Text("Copilot JSONL").tag("copilot")
                }.labelsHidden().onChange(of: format) { _, value in save("format", value) }
            }
        } else {
            SettingsLabeledRow(title: "Model", detail: "Optional. Leave blank to use the CLI default.") {
                TextField("Default", text: $model).textFieldStyle(.roundedBorder).frame(width: 200)
                    .onChange(of: model) { _, value in save("model", value) }
            }
        }
        SettingsRow {
            Hint("Meeting text is sent to the CLI account's service. Check confirms the executable only, not sign-in.")
        }
        if !checkMessage.isEmpty { SettingsRow { Hint(checkMessage) } }
    }

    @MainActor private func check() async {
        checking = true
        defer { checking = false }
        let executable = CLIAnalysisProvider.executable(kind)
        guard !executable.isEmpty else { checkMessage = "Set an absolute executable path."; return }
        do {
            let identifier = UUID().uuidString
            let request: [String: Any] = ["operation": "cli", "id": identifier, "executable": executable,
                                          "arguments": ["--version"], "input": "", "timeout": 10.0]
            _ = try await HostHelperClient.shared.perform(JSONSerialization.data(withJSONObject: request), identifier: identifier)
            checkMessage = "Executable found. Sign-in has not been checked."
        } catch { checkMessage = error.localizedDescription }
    }
}

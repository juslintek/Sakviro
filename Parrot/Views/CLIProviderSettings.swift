import SwiftUI

struct CLIProviderSettings: View {
    let kind: CopilotProviderKind
    @AppStorage private var path: String
    @AppStorage private var model: String
    @AppStorage private var arguments: String
    @AppStorage private var format: String
    @State private var checkMessage = ""
    @State private var checking = false

    init(kind: CopilotProviderKind) {
        self.kind = kind
        _path = AppStorage(wrappedValue: "", "cli_\(kind.rawValue)_path")
        _model = AppStorage(wrappedValue: "", "cli_\(kind.rawValue)_model")
        _arguments = AppStorage(wrappedValue: "", "cli_\(kind.rawValue)_arguments")
        _format = AppStorage(wrappedValue: "plain", "cli_\(kind.rawValue)_format")
    }

    var body: some View {
        SettingsLabeledRow(title: "Executable", detail: kind == .customCLI ? "Absolute path to a trusted executable." : "Leave blank to search common locations on this Mac.") {
            TextField("Absolute path", text: $path)
                .textFieldStyle(.roundedBorder).frame(width: 260)
                .onChange(of: path) { _, _ in checkMessage = "" }
            Button(checking ? "Checking…" : "Check") { Task { await check() } }
                .disabled(checking)
        }
        if kind == .customCLI {
            SettingsLabeledRow(title: "Arguments", detail: "JSON array of arguments. Use {model} as an argument for the selected model. The prompt is sent through stdin.") {
                TextField("[]", text: $arguments).textFieldStyle(.roundedBorder).frame(width: 260)
                    .onChange(of: arguments) { _, _ in checkMessage = "" }
            }
            SettingsLabeledRow(title: "Output format") {
                Picker("", selection: Binding(get: { format.isEmpty ? "plain" : format }, set: { format = $0 })) {
                    Text("Plain text").tag("plain")
                    Text("Claude JSON").tag("claude")
                    Text("Gemini JSON").tag("gemini")
                    Text("Codex JSONL").tag("codex")
                    Text("Copilot JSONL").tag("copilot")
                }.labelsHidden().onChange(of: format) { _, _ in checkMessage = "" }
            }
        }
        ProviderModelSettings(model: $model, kind: kind)
            .onChange(of: model) { _, _ in checkMessage = "" }
        ProviderAutoModelSettings(kind: kind, manual: $model)
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

struct ProviderModelSettings: View {
    @Binding var model: String
    let kind: CopilotProviderKind
    @State private var editingCustom = false

    private var models: [String] {
        switch kind {
        case .claude: [ClaudeAnalysisProvider.defaultModel, "claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-1"]
        case .claudeCode: ["sonnet", "opus", "haiku", "fable", "best"]
        case .codex: ["gpt-6.1-sol", "gpt-6-sol", "gpt-6-astra", "gpt-6-luna"]
        case .gemini: ["auto", "pro", "flash", "flash-lite"]
        case .copilot: ["auto", "gpt-5.4"]
        default: []
        }
    }

    private var selection: Binding<String> {
        Binding(get: {
            if editingCustom { return "\u{0}custom" }
            if model.isEmpty { return "" }
            return models.contains(model) ? model : "\u{0}custom"
        }, set: { value in
            if value == "\u{0}custom" { editingCustom = true }
            else { editingCustom = false; model = value }
        })
    }

    var body: some View {
        SettingsLabeledRow(title: "Model", detail: kind == .claude ? "Default: \(ClaudeAnalysisProvider.defaultModel). Shared by roles using this integration." : "Provider default when blank. Shared by roles using this integration.") {
            Picker("", selection: selection) {
                Text("Provider default").tag("")
                ForEach(models, id: \.self) { Text($0).tag($0) }
                Text("Custom…").tag("\u{0}custom")
            }.labelsHidden().accessibilityLabel("\(kind.label) model").pickerStyle(.menu).fixedSize()
        }
        if editingCustom || (!model.isEmpty && !models.contains(model)) {
            SettingsLabeledRow(title: "Model ID") {
                TextField("Model ID", text: $model).textFieldStyle(.roundedBorder).frame(width: 220)
            }
        }
    }
}

struct ProviderAutoModelSettings: View {
    let kind: CopilotProviderKind
    @Binding var manual: String
    @AppStorage private var enabled: Bool
    @AppStorage private var fast: String
    @AppStorage private var context: String
    @AppStorage private var deep: String

    init(kind: CopilotProviderKind, manual: Binding<String>) {
        self.kind = kind
        _manual = manual
        let models = ModelSelection.defaults(kind)
        _enabled = AppStorage(wrappedValue: false, ModelSelection.key(kind, "enabled"))
        _fast = AppStorage(wrappedValue: models[0], ModelSelection.key(kind, "fast"))
        _context = AppStorage(wrappedValue: models[1], ModelSelection.key(kind, "context"))
        _deep = AppStorage(wrappedValue: models[2], ModelSelection.key(kind, "deep"))
    }

    var body: some View {
        SettingsLabeledRow(title: "Automatic model", detail: "Shared by roles using this integration. Uses the manual model when a field is blank. Availability depends on your account.") {
            Picker("Model selection", selection: $enabled) {
                Text("Manual").tag(false)
                Text("Auto").tag(true)
            }.labelsHidden().accessibilityLabel("\(kind.label) model selection").pickerStyle(.segmented).fixedSize()
        }
        SettingsLabeledRow(title: "Fast model", detail: "Live cards and short questions") {
            TextField("Use manual model", text: $fast).textFieldStyle(.roundedBorder).frame(width: 220)
        }
        SettingsLabeledRow(title: "Context model", detail: "Reports, screens and long context") {
            TextField("Use manual model", text: $context).textFieldStyle(.roundedBorder).frame(width: 220)
        }
        SettingsLabeledRow(title: "Deep model", detail: "Explicit requests for detailed analysis") {
            TextField("Use manual model", text: $deep).textFieldStyle(.roundedBorder).frame(width: 220)
        }
        .onChange(of: manual) { _, _ in enabled = false }
    }
}

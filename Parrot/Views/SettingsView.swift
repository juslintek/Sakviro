import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Settings pages, System Settings-style: topics on the left, ONE topic per
/// page on the right. Content rules: controls at body size, hints one line at
/// secondary size — long explanations live in the control's own label instead.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, recording, transcription, copilot, apiKeys, knowledge, profiles, connections, privacy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .recording: "Recording"
        case .transcription: "Transcription"
        case .copilot: "Assistant"
        case .apiKeys: "Assistant"
        case .knowledge: "Knowledge"
        case .profiles: "Profiles"
        case .connections: "Connections"
        case .privacy: "Privacy"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .recording: "mic"
        case .transcription: "text.quote"
        case .copilot: "sparkles"
        case .apiKeys: "key"
        case .knowledge: "books.vertical"
        case .profiles: "person.2"
        case .connections: "arrow.triangle.branch"
        case .privacy: "lock.shield"
        }
    }
}

struct SettingsView: View {
    /// True when rendered inside the main window's detail pane (wide, fills the
    /// space); false for the standalone Cmd-, Settings window, which needs a
    /// fixed sane size.
    var isEmbedded = false

    init(isEmbedded: Bool = false, initialSection: SettingsSection = .general) {
        self.isEmbedded = isEmbedded
        _section = State(initialValue: initialSection)
    }

    @Environment(RecordingManager.self) private var recordingManager
    @AppStorage("whisperModel") private var selectedModel = "base"
    @AppStorage("speechModelAuto.local") private var localSpeechAuto = false
    @AppStorage("appearance") private var appearance = Appearance.system
    @AppStorage(ParrotAppDelegate.hideDockKey) private var hideDock = false
    @AppStorage("copilotEnabled") private var copilotEnabled = false
    @AppStorage(LiveNudgeSession.defaultsKey) private var liveNudges = true
    @AppStorage(AssistantRoutingSettings.enabledKey) private var enabledIntegrations = ""
    @AppStorage("copilotPace") private var copilotPace = CopilotPace.fast.rawValue
    @AppStorage("copilotWindow") private var copilotWindow = CopilotWindow.standard.rawValue
    @AppStorage("copilotOllamaModel") private var copilotOllamaModel = "llama3.2:3b"
    /// True after picking "Custom…" in the Ollama model dropdown, so the free
    /// text field stays visible even while the typed name matches nothing.
    @State private var ollamaCustomModelEditing = false
    @AppStorage("transcriptionLanguage") private var transcriptionLanguage = "auto"
    @AppStorage("customVocabulary") private var customVocabulary = ""
    /// Parakeet knows 25 European languages; a pin outside them rules it out.
    private var parakeetFitsLanguage: Bool {
        transcriptionLanguage == "auto" || LanguageRouter.parakeetLanguages.contains(transcriptionLanguage)
    }
    @AppStorage(VideoCaptureService.enabledKey) private var recordVideo = false
    @AppStorage(VideoArchivePreset.defaultsKey) private var videoArchivePreset = VideoArchivePreset.efficient1080p15.rawValue
    @AppStorage(VideoCaptureTargetMode.defaultsKey) private var videoCaptureTarget = VideoCaptureTargetMode.any.rawValue
    @AppStorage(VideoCaptureService.showsCursorKey) private var videoShowsCursor = true
    @AppStorage(AudioQualityCleaner.autoCleanKey) private var autoCleanAudio = true
    @AppStorage("echoCancellationEnabled") private var echoCancellation = true
    @AppStorage("polishAfterCall") private var polishAfterCall = false
    @AppStorage("livePreview") private var livePreview = true
    @State private var section: SettingsSection = .general
    @State private var diarizerDownloading = false
    @State private var mlxPathsVersion = 0
    @AppStorage("rememberVoices") private var rememberVoices = false
    @AppStorage(RecordingManager.globalMarkHotKeyDefaultsKey) private var globalMarkHotKey = true
    @AppStorage("liveSpeakerLabels") private var liveSpeakerLabels = false
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SpeakerProfile.name) private var voiceProfiles: [SpeakerProfile]
    /// There's no Save button — @AppStorage persists on every change. This
    /// drives a small transient "Saved" chip so that's visible, debounced so
    /// typing in a field shows one toast when the user pauses, not per key.
    @State private var showSavedToast = false
    @State private var savedToastTask: Task<Void, Never>?
    @State private var batchCleanStatus: String? = nil
    /// Mirrors Sparkle's own setting so the toggle survives a relaunch without
    /// us storing a second copy of the truth.
    #if !PARROT_NO_UPDATER
    @State private var automaticUpdates = AppUpdater.shared.automaticallyUpdates
    #endif

    /// Opens the bundled Help Book at a specific page anchor (hiutil indexes
    /// anchors — the -a in assemble-help.sh). Dev binaries carry no book, so
    /// Help Viewer just no-ops there.
    static func openHelp(anchor: String) {
        let book = Bundle.main.object(forInfoDictionaryKey: "CFBundleHelpBookName") as? String
        NSHelpManager.shared.openHelpAnchor(anchor, inBook: book)
    }

    /// Deep-links into one section from anywhere (dashboard, live panel): the
    /// request is parked in defaults, the Settings window is opened or brought
    /// forward, and whichever SettingsView is showing picks it up in onAppear
    /// (fresh window) or via the notification (already open).
    static let requestedSectionKey = "settingsRequestedSection"
    static func open(_ target: SettingsSection, with openSettings: OpenSettingsAction) {
        UserDefaults.standard.set(target.rawValue, forKey: requestedSectionKey)
        openSettings()
        NotificationCenter.default.post(name: .parrotOpenSettingsSection, object: nil)
    }

    private func consumeRequestedSection() {
        guard let raw = UserDefaults.standard.string(forKey: Self.requestedSectionKey),
              let target = SettingsSection(rawValue: raw) else { return }
        UserDefaults.standard.removeObject(forKey: Self.requestedSectionKey)
        section = target
    }

    /// One Equatable snapshot of every auto-saved setting on this screen —
    /// a single onChange instead of one per field.
    private var settingsFingerprint: String {
        "\(selectedModel)|\(appearance)|\(copilotEnabled)|\(transcriptionLanguage)|"
            + "\(customVocabulary)|\(echoCancellation)|\(polishAfterCall)|"
            + "\(copilotPace)|\(copilotWindow)|\(livePreview)|\(enabledIntegrations)"
    }

    private func flashSavedToast() {
        savedToastTask?.cancel()
        savedToastTask = Task {
            // Debounce: wait for the user to pause before announcing the save.
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { showSavedToast = true }
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { showSavedToast = false }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // MARK: Section nav
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsSection.allCases.filter { $0 != .apiKeys }) { item in
                    SettingsNavRow(title: item.title, icon: item.icon, selected: section == item) {
                        section = item
                    }
                }
                Spacer()
                // Pinned at the bottom: a hello from the author (jumps to the
                // help book's "Hi from Uygar" page) and the standard macOS
                // help button for the guide itself.
                HStack(spacing: 6) {
                    SettingsNavRow(title: "About", icon: "hand.wave", selected: false) {
                        Self.openHelp(anchor: "hi-from-uygar")
                    }
                    HelpCircleButton { NSApp.showHelp(nil) }
                }
            }
            .padding(8)
            .frame(width: 168)
            .background(Theme.Colors.panel)

            Divider()

            // MARK: Page
            Group {
                switch section {
                case .general: generalPage
                case .recording: recordingPage
                case .transcription: transcriptionPage
                case .copilot: copilotPage
                case .apiKeys: copilotPage
                case .knowledge: KnowledgeSettingsView()
                case .profiles: ProfilesSettingsView()
                case .connections: ConnectionsSettingsPage()
                case .privacy: PrivacySettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .formStyle(.grouped)
        .onAppear {
            AssistantRoutingSettings.migrate()
            consumeRequestedSection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .parrotOpenSettingsSection)) { _ in
            consumeRequestedSection()
        }
        .onChange(of: settingsFingerprint) { flashSavedToast() }
        .overlay(alignment: .bottom) {
            if showSavedToast {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.Colors.line))
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: isEmbedded ? nil : 780, height: isEmbedded ? nil : 620)
        .frame(maxWidth: isEmbedded ? .infinity : nil,
               maxHeight: isEmbedded ? .infinity : nil)
    }

    // MARK: - General

    private var generalPage: some View {
        let path = AudioCaptureManager.storageDirectory().path
        return SettingsPage {
            SettingsCard(title: "Startup") {
                LoginItemRow(first: true)
                SettingsToggleRow(
                    title: "Hide from the Dock when the window is closed",
                    detail: "\(MeetingActions.appName) stays in the menu bar. Choose Open \(MeetingActions.appName) there, and the Dock icon is back while the window is open.",
                    isOn: $hideDock
                )
            }

            SettingsCard(title: "Appearance") {
                SettingsLabeledRow(title: "Appearance", first: true) {
                    Picker("", selection: $appearance) {
                        Text("System").tag(Appearance.system)
                        Text("Light").tag(Appearance.light)
                        Text("Dark").tag(Appearance.dark)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            SettingsCard(title: "Storage") {
                SettingsRow(first: true) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Audio files")
                                .font(Theme.Typography.body)
                            Text(path)
                                .font(Theme.Typography.secondary)
                                .foregroundStyle(Theme.Colors.ink2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 12)
                        Button("Show in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                        }
                    }
                }
            }

            SettingsCard(title: "About") {
                SettingsLabeledRow(title: "Version", first: true) {
                    Text("\(MeetingActions.appName) \(AppUpdater.currentVersion)")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                }
                #if !PARROT_NO_UPDATER
                if AppUpdater.shared.isAvailable {
                    SettingsToggleRow(
                        title: "Keep \(MeetingActions.appName) up to date",
                        detail: "Downloads new versions in the background and installs them when you quit. Never during a recording.",
                        isOn: $automaticUpdates
                    )
                    .onChange(of: automaticUpdates) {
                        AppUpdater.shared.automaticallyUpdates = automaticUpdates
                    }
                    SettingsLabeledRow(title: "Check for updates", detail: "Or look right now.") {
                        Button("Check Now") { AppUpdater.shared.checkForUpdates() }
                    }
                } else {
                    SettingsRow { Hint("Updates are disabled for this build.") }
                }
                #else
                SettingsRow { Hint("Updates are disabled for this build.") }
                #endif
                SettingsLabeledRow(title: "User guide", detail: "Every screen explained, with setup and troubleshooting.") {
                    Button("Open User Guide") { NSApp.showHelp(nil) }
                }
                SettingsLabeledRow(title: "Welcome tour", detail: "The first-run tour: permissions, the Assistant and speech model.") {
                    Button("Show Welcome Tour") {
                        MeetingActions.showWelcomeTour()
                        // The tour is a sheet on the main window; get out of its way.
                        if !isEmbedded { NSApp.keyWindow?.performClose(nil) }
                    }
                }
                if !MeetingActions.isFork {
                    SettingsLabeledRow(title: "Website", detail: "The landing page, with a demo you can scroll and the honest privacy list.") {
                        Button("Open openparrot.app") { MeetingActions.open(MeetingActions.websiteURL) }
                    }
                }
            }
        }
    }

    // MARK: - Recording

    private var recordingPage: some View {
        SettingsPage {
            SettingsCard(title: "Echo Cancellation") {
                SettingsToggleRow(
                    title: "Cancel speaker echo from the mic",
                    detail: "On speakers, this keeps the other person's voice out of your \"Me\" track. Turn off with headphones.",
                    first: true,
                    isOn: $echoCancellation
                )
            }

            SettingsCard(title: "Audio Quality") {
                SettingsToggleRow(
                    title: "Auto-clean audio after calls",
                    detail: "Scans and removes rumble, hum, clicks, hiss, and quiet-mic imbalance while keeping originals.",
                    first: true,
                    isOn: $autoCleanAudio
                )
                if let prog = recordingManager.batchAudioCleanProgress {
                    SettingsRow {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Cleaning \(prog.completed) / \(prog.total) meetings…")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.ink2)
                        }
                    }
                } else {
                    SettingsLabeledRow(
                        title: "Scan & Clean Existing Meetings",
                        detail: "Process existing recorded meetings that have uncleaned audio tracks."
                    ) {
                        HStack(spacing: 8) {
                            if let status = batchCleanStatus {
                                Text(status)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.ink2)
                            }
                            Menu {
                                Button("Clean Uncleaned Meetings") {
                                    Task {
                                        let count = await recordingManager.cleanAllMeetingsAudio(forceReclean: false)
                                        batchCleanStatus = count > 0 ? "Cleaned \(count) meeting\(count == 1 ? "" : "s")" : "All meetings already cleaned"
                                    }
                                }
                                Button("Re-clean All Meetings") {
                                    Task {
                                        let count = await recordingManager.cleanAllMeetingsAudio(forceReclean: true)
                                        batchCleanStatus = count > 0 ? "Re-cleaned \(count) meeting\(count == 1 ? "" : "s")" : "No meetings to clean"
                                    }
                                }
                            } label: {
                                Text("Clean Uncleaned Meetings")
                            } primaryAction: {
                                Task {
                                    let count = await recordingManager.cleanAllMeetingsAudio(forceReclean: false)
                                    batchCleanStatus = count > 0 ? "Cleaned \(count) meeting\(count == 1 ? "" : "s")" : "All meetings already cleaned"
                                }
                            }
                            .menuStyle(.borderedButton)
                            .fixedSize()
                        }
                    }
                }
            }

            SettingsCard(title: "Input") {
                SettingsRow(first: true) {
                    Hint("System audio comes from macOS; the microphone uses your default input device. Video is captured only when enabled and you choose a window or display.")
                }
            }

            SettingsCard(title: "Video") {
                SettingsToggleRow(
                    title: "Record video",
                    detail: "Choose a window or display each time a recording starts. Video is saved on this Mac with the microphone and system audio.",
                    first: true,
                    isOn: $recordVideo
                )
                if recordVideo {
                    SettingsLabeledRow(title: "Capture target", detail: "Window, application, or full display to record.") {
                        Picker("Capture target", selection: $videoCaptureTarget) {
                            ForEach(VideoCaptureTargetMode.allCases) { mode in
                                Text(mode.label).tag(mode.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    SettingsLabeledRow(title: "Video quality", detail: "Lower resolution and frame rate keep your Mac cool during long calls.") {
                        Picker("Video quality", selection: $videoArchivePreset) {
                            ForEach(VideoArchivePreset.allCases) { preset in
                                Text(preset.label).tag(preset.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    SettingsToggleRow(
                        title: "Show pointer in video",
                        detail: "Include the mouse pointer in captured recordings.",
                        isOn: $videoShowsCursor
                    )
                }
            }

            CallDetectionCard()

            CalendarCard()

            SettingsCard(title: "Bookmarks") {
                SettingsToggleRow(
                    title: "Mark moments from any app with \(GlobalHotKey.Combo.markMoment.display)",
                    detail: "While a call records, \(GlobalHotKey.Combo.markMoment.display) marks the moment even when Zoom or your browser is in front. \(MeetingActions.appName) only hears that one shortcut, never other keys, and only during a recording.",
                    first: true,
                    isOn: $globalMarkHotKey
                )
                .onChange(of: globalMarkHotKey) { recordingManager.refreshMarkHotKey() }
            }
        }
    }

    // MARK: - Transcription

    private var transcriptionPage: some View {
        SettingsPage {
            SettingsCard(title: "Engine") {
                SettingsBlockRow(title: "Engine", first: true) {
                    Text("On-device")
                    Hint("Every second of audio stays on this Mac.")
                }
                SettingsToggleRow(
                    title: "Polish transcript after each call",
                    detail: "Transcribes the saved audio again, all at once, for cleaner lines, then writes the report.",
                    isOn: $polishAfterCall
                )
                if polishAfterCall {
                    SettingsRow { Hint("Polish uses your on-device model below.") }
                }
                SettingsToggleRow(
                    title: "Show words as they're spoken",
                    detail: "Gray preview text while someone is mid-sentence, replaced by the final line. On-device engine only; turn off if calls make your Mac run hot. Applies to the next recording.",
                    isOn: $livePreview
                )
            }

            SettingsCard(title: "On-Device Model") {
                SettingsToggleRow(title: "Auto", detail: "Choose a downloaded model for the next recording or import using the language and call brief. Your manual choice is saved.", isOn: $localSpeechAuto)
                SettingsBlockRow(title: "Manual model") {
                    Picker("", selection: $selectedModel) {
                        Text("Parakeet v3 — 0.5 GB, fastest, 25 European languages (no Turkish)")
                            .tag(ParakeetTranscriber.modelID)
                            .selectionDisabled(!parakeetFitsLanguage)
                        Text("Tiny — 40 MB, fastest").tag("tiny")
                        Text("Base — 140 MB, good balance").tag("base")
                        Text("Small — 460 MB, better accuracy").tag("small")
                        Text("Large V3 Turbo Compressed — 626 MB, fast, low memory").tag("large-v3-v20240930_626MB")
                        Text("Large V3 Turbo — 1.6 GB, best accuracy").tag("large-v3-turbo")
                        ForEach(MLXTranscriber.models, id: \.id) { model in
                            Text(model.name).tag(model.id)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    .onChange(of: selectedModel) { _, _ in localSpeechAuto = false }

                    if selectedModel == ParakeetTranscriber.modelID {
                        Hint(parakeetFitsLanguage
                             ? "Calls in other languages, like Turkish, switch to Whisper Large V3 Turbo Compressed on their own."
                             : "Parakeet can't do \(TranscriptionLanguage.name(transcriptionLanguage)), so calls use Whisper.")
                    }
                    if MLXTranscriber.isMLX(selectedModel) {
                        Hint("Choose a Python environment with mlx-whisper installed and a local model folder. Model quality and speed depend on the model and Mac.")
                        HStack {
                            Text(UserDefaults.standard.string(forKey: MLXTranscriber.pythonKey) ?? "No Python executable selected")
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose Python…") { chooseMLXPath(key: MLXTranscriber.pythonKey, directory: false) }
                        }
                        HStack {
                            Text(UserDefaults.standard.string(forKey: MLXTranscriber.modelKey(selectedModel)) ?? "No model folder selected")
                                .lineLimit(1).truncationMode(.middle)
                            Button("Choose Model…") { chooseMLXPath(key: MLXTranscriber.modelKey(selectedModel), directory: true) }
                        }
                        .id(mlxPathsVersion)
                    }
                }
                SettingsRow {
                    HStack(spacing: 12) {
                        modelStatusView
                        Spacer(minLength: 12)
                        Button("Download / Reload Model") {
                            Task {
                                await recordingManager.transcriptionEngine.loadModel(selectedModel)
                            }
                        }
                        .disabled(recordingManager.isBusy || recordingManager.isRecording)
                    }
                }
            }

            SettingsCard(
                title: "Speaker Detection",
                blurb: "Tells apart the different people on a call, on this Mac. Downloads automatically after a call if missing. Uses pyannote models via FluidAudio (CC-BY-4.0)."
            ) {
                if DiarizationEngine.modelsInstalled {
                    SettingsLabeledRow(title: "Models", detail: "Downloaded (~13 MB)", first: true) {
                        Button("Remove Models") { DiarizationEngine.removeModels() }
                    }
                } else {
                    SettingsLabeledRow(title: "Models", detail: "Not downloaded", first: true) {
                        Button(diarizerDownloading ? "Downloading…" : "Download (~13 MB)") {
                            diarizerDownloading = true
                            Task {
                                try? await recordingManager.diarizationEngine.ensureModels()
                                diarizerDownloading = false
                            }
                        }
                        .disabled(diarizerDownloading)
                    }
                }
                SettingsToggleRow(
                    title: "Live speaker labels",
                    detail: "Experimental. During a call, tells the other people apart every 30 seconds instead of waiting for the end. The final pass when the call ends is still the accurate one.",
                    isOn: $liveSpeakerLabels
                )
                SettingsToggleRow(
                    title: "Remember voices",
                    detail: "When on, naming a speaker saves their voiceprint on this Mac so future calls can suggest who's talking. Never leaves your Mac; delete anytime.",
                    isOn: $rememberVoices
                )
                if rememberVoices {
                    ForEach(voiceProfiles) { profile in
                        SettingsLabeledRow(title: profile.name, detail: "heard \(profile.sampleCount)×") {
                            Button("Forget") {
                                SpeakerProfileStore.delete(profile, in: modelContext)
                            }
                        }
                    }
                    if !voiceProfiles.isEmpty {
                        SettingsRow {
                            Button("Forget All Voices") {
                                SpeakerProfileStore.deleteAll(in: modelContext)
                            }
                        }
                    }
                }
            }

            SettingsCard(title: "Language") {
                SettingsLabeledRow(
                    title: "Language",
                    detail: "Set this to the language your calls are in. \(MeetingActions.appName) warns you during a call if it hears a different one.",
                    first: true
                ) {
                    Picker("", selection: $transcriptionLanguage) {
                        Text("Auto-detect").tag("auto")
                        ForEach(TranscriptionLanguage.options, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }

            }

            SettingsCard(title: "Custom Vocabulary") {
                SettingsBlockRow(
                    title: "Names and jargon Whisper mis-hears",
                    detail: "Comma or line separated (e.g. LaunchEase, Uygar). Whisper only: Parakeet doesn't take a word list.",
                    first: true
                ) {
                    TextEditor(text: $customVocabulary)
                        .frame(height: 64)
                        .font(Theme.Typography.secondary)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.radius).strokeBorder(Theme.Colors.line))
                }
            }
        }
    }

    private func chooseMLXPath(key: String, directory: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directory
        panel.canChooseFiles = !directory
        if !directory { panel.resolvesAliases = false }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: "\(key).bookmark")
            UserDefaults.standard.set(url.path, forKey: key)
            mlxPathsVersion += 1
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @ViewBuilder
    private var modelStatusView: some View {
        switch recordingManager.transcriptionEngine.modelState {
        case .ready:
            Label("\(TranscriptionEngine.displayName(for: recordingManager.transcriptionEngine.currentModel)) loaded and ready", systemImage: "checkmark.circle")
                .foregroundStyle(Theme.Colors.good)
                .font(Theme.Typography.secondary)
        case .loading:
            HStack(alignment: .top) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preparing \(recordingManager.transcriptionEngine.loadingModelName ?? "model")…")
                    Text("The first load can take a few minutes.")
                        .font(Theme.Typography.caption)
                }
                .font(Theme.Typography.secondary)
                .foregroundStyle(Theme.Colors.ink2)
            }
        case .downloading(let progress):
            ModelDownloadProgressView(progress: progress,
                                      modelName: recordingManager.transcriptionEngine.loadingModelName)
        case .error(let msg):
            Label(msg, systemImage: "xmark.circle")
                .foregroundStyle(Theme.Colors.stop)
                .font(Theme.Typography.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: - Copilot

    private var copilotPage: some View {
        SettingsPage {
            SettingsCard(title: "Live Call Assistant") {
                SettingsToggleRow(
                    title: "Enable the Assistant during recordings",
                    detail: "Suggests answers, flags blockers, and captures action items live. No button needed.",
                    first: true,
                    isOn: $copilotEnabled
                )
                SettingsLabeledRow(title: "Guided setup", detail: "Enable account connections or run the Assistant on this Mac.") {
                    Button("Set up the Assistant") {
                        MeetingActions.showCopilotSetup()
                        if !isEmbedded { NSApp.keyWindow?.performClose(nil) }
                    }
                }
                SettingsLabeledRow(title: "Call profiles", detail: "What it says and watches for is set per call profile.") {
                    Button("Open Profiles") { section = .profiles }
                }
            }

            SettingsCard(title: "Connections", blurb: "Automatic routing is shared by live assistance, reports and Ask.") {
                SettingsRow(first: true) { AssistantIntegrationsView(enabledIntegrations: $enabledIntegrations) }
            }
            if enabledIntegrations.split(separator: ",").contains("ollama") {
                SettingsCard(title: "Ollama") { providerConfig(for: .ollama) }
            }

            SettingsCard(title: "Live Nudges") {
                SettingsToggleRow(
                    title: "Show live nudges",
                    detail: "Short tips during a call, like when they've gone quiet after something you said. Works without the Assistant too.",
                    first: true,
                    isOn: $liveNudges
                )
            }

            // What each call costs, in the user's hands: how often the model is
            // asked, and how much conversation each request carries. Both apply
            // live, mid-call. Fast + Standard = the original behavior.
            SettingsCard(title: "Pace") {
                SettingsBlockRow(
                    title: "How often the Assistant asks the model",
                    detail: (CopilotPace(rawValue: copilotPace) ?? .fast).caption,
                    first: true
                ) {
                    Picker("", selection: $copilotPace) {
                        ForEach(CopilotPace.allCases) { pace in
                            Text(pace.label).tag(pace.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                SettingsLabeledRow(
                    title: "Conversation sent per request",
                    detail: "Only recent talk is sent. Insight cards always go along, so the Assistant still remembers the whole call. Smaller is cheaper and faster, especially on free or local models."
                ) {
                    Picker("", selection: $copilotWindow) {
                        ForEach(CopilotWindow.allCases) { window in
                            Text(window.label).tag(window.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }


        }
    }

    /// Per-backend configuration rows, shared by the live and reports pickers.
    @ViewBuilder
    private func providerConfig(for kind: CopilotProviderKind) -> some View {
        switch kind {
        case .ollama:
            SettingsLabeledRow(
                title: "Ollama model",
                detail: "Runs entirely on this Mac: free, private, no key, works offline. Live cards arrive slower and read rougher than Claude's; reports are unaffected."
            ) {
                Picker("", selection: ollamaModelSelection) {
                    ForEach(OllamaCatalog.models, id: \.id) { entry in
                        Text(entry.label).tag(entry.id)
                    }
                    Divider()
                    Text("Custom…").tag("custom")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            if showsOllamaCustomField {
                SettingsLabeledRow(
                    title: "Model name",
                    detail: "Any model from ollama.com/library. Prefer small instruct models; \"thinking\" models (qwen3, deepseek-r1) are too slow for live cards."
                ) {
                    TextField("", text: $copilotOllamaModel, prompt: Text("model:tag"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }
            ProviderAutoModelSettings(kind: .ollama, manual: $copilotOllamaModel)
            SettingsRow {
                OllamaModelStatusView(model: copilotOllamaModel)
            }
        case .claude:
            EmptyView()
        case .custom:
            CustomProviderSettingsView()
        case .claudeCode, .codex, .gemini, .copilot, .customCLI:
            CLIProviderSettings(kind: kind).id(kind)
        }
    }

    /// Dropdown selection for the Ollama model: catalog id, or "custom" when the
    /// stored model isn't in the catalog (or the user picked Custom…).
    private var ollamaModelSelection: Binding<String> {
        Binding(
            get: {
                if ollamaCustomModelEditing { return "custom" }
                return OllamaCatalog.ids.contains(copilotOllamaModel) ? copilotOllamaModel : "custom"
            },
            set: { picked in
                if picked == "custom" {
                    ollamaCustomModelEditing = true
                } else {
                    ollamaCustomModelEditing = false
                    copilotOllamaModel = picked
                }
            }
        )
    }

    private var showsOllamaCustomField: Bool {
        ollamaCustomModelEditing || !OllamaCatalog.ids.contains(copilotOllamaModel)
    }

}

struct CustomProviderSettingsView: View {
    @AppStorage("copilotCustomBaseURL") private var customBaseURL = ""
    @AppStorage("copilotCustomModel") private var customModel = ""
    @State private var apiKeyDraft = APIKeyStore.load(account: "custom-llm-api-key") ?? ""
    @State private var keySaved = APIKeyStore.load(account: "custom-llm-api-key") != nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.controlGap) {
            SettingsLabeledRow(
                title: "Endpoint Base URL",
                detail: "Base URL of an OpenAI-compatible /v1 chat completions endpoint or Google AI Studio OpenAI endpoint."
            ) {
                TextField("", text: $customBaseURL, prompt: Text("https://api.openai.com/v1"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 260)
            }
            SettingsLabeledRow(
                title: "Model",
                detail: "Model name accepted by the endpoint (e.g. gpt-4o, gemini-2.5-flash-lite, deepseek-chat)."
            ) {
                TextField("", text: $customModel, prompt: Text("gemini-2.5-flash-lite"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            SettingsLabeledRow(
                title: "API Key",
                detail: "Stored securely in your macOS Keychain."
            ) {
                HStack(spacing: 8) {
                    SecureField("", text: $apiKeyDraft, prompt: Text("API key"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .onChange(of: apiKeyDraft) { _, newValue in
                            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty {
                                APIKeyStore.delete(account: "custom-llm-api-key")
                                keySaved = false
                            } else {
                                keySaved = APIKeyStore.save(trimmed, account: "custom-llm-api-key")
                            }
                        }
                    if keySaved {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Colors.good)
                    }
                }
            }
            SettingsRow {
                Button("Use Google AI Studio (Gemini 2.5 Flash-Lite)") {
                    customBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai/"
                    customModel = "gemini-2.5-flash-lite"
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

enum Appearance: String, CaseIterable {
    case system, light, dark
}

// MARK: - Settings nav row

/// The guide button. macOS's stock HelpLink is a hairline grey circle nobody
/// sees, so this is a filled accent disc with a white glyph that lifts on
/// hover — the one control in the sidebar that should catch a lost eye.
private struct HelpCircleButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.Colors.accent.opacity(hovering ? 1 : 0.9), in: Circle())
                .shadow(color: Theme.Colors.accent.opacity(hovering ? 0.45 : 0.25),
                        radius: hovering ? 5 : 3, y: 1)
                .scaleEffect(hovering ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .help("\(MeetingActions.appName) Help")
        .accessibilityLabel("\(MeetingActions.appName) Help")
    }
}

private struct SettingsNavRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Theme.Colors.accent : Theme.Colors.ink2)
                Text(title)
                    .font(Theme.Typography.sans(13, .medium))
                    .foregroundStyle(Theme.Colors.ink)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(selected ? Theme.Colors.selection : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Metrics.radius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - One-line hint

/// The ONE way explanatory text appears on a settings page: a single readable
/// line at secondary size. Anything longer belongs in the control's own label.
struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.Typography.secondary)
            .foregroundStyle(Theme.Colors.ink2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

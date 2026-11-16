import SwiftUI
import SwiftData
import CoreGraphics
import AVFoundation
import UserNotifications
import IOKit.ps
import ScreenCaptureKit
import Observation

/// Orchestrates audio capture, transcription, and storage for a recording session.
@MainActor
@Observable
final class RecordingManager {
    let audioCaptureManager = AudioCaptureManager()
    private var videoCapture: VideoCaptureService?
    let transcriptionEngine = TranscriptionEngine()
    let diarizationEngine = DiarizationEngine()
    /// Live-labels sweep (experimental, "liveSpeakerLabels" default): the
    /// repeating task and the previous run's label→embedding identities.
    private var liveSweepTask: Task<Void, Never>?
    private var liveAnchors: [String: [Float]] = [:]
    private var lastSweptThemSegmentCount: Int = 0
    /// Live voiceprint matches (label → remembered name), display-only —
    /// bubbles show "Gürkan?" while the stored label stays Speaker N until
    /// the user confirms post-call.
    private(set) var liveSpeakerSuggestions: [String: String] = [:]
    // Routes to Claude / Ollama / a custom server per Settings → Copilot.
    let callAnalysisEngine: CallAnalysisEngine
    /// This call's live nudges (the pill, the Copilot banner, the report timeline).
    let nudges = LiveNudgeSession()
    let knowledgeBase = KnowledgeBaseService()
    /// TypeSafe client for the copilot's "From your docs" excerpts; inert
    /// without a key (see CallAnalysisEngine.fastPathAvailable).
    let docMatcher = JevDocMatcher()
    let profileStore = ProfileStore()
    /// The Mac's calendars (opt-in): names meetings, lists who's on them.
    let calendar = CalendarService()
    /// Notices calls in other apps and offers to record them.
    let callWatcher = CallWatcher()
    /// Every finished meeting, searchable on the Mac (Ask Parrot).
    let memory: MeetingMemory
    /// Ask Parrot's saved chats.
    let chats: AskChatStore
    /// Next steps → Apple Reminders (asks for access on first use).
    let reminders = RemindersService()
    /// The local Ollama server and its one model pull, shared by onboarding,
    /// Settings and the Home card.
    let ollama = OllamaService()
    /// Installs the Ollama app from inside Parrot (onboarding, private path).
    let ollamaInstaller = OllamaInstaller()

    /// Optional one-line context for the next call, set from the dashboard.
    var nextCallBrief = ""

    private(set) var isRecording = false
    private(set) var recordingStartTime: Date?
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var currentMeeting: Meeting?
    /// The call that just stopped, by any path (Stop, menu bar, ⌘., auto
    /// stop): the window opens it and asks for a title and a note. The
    /// window clears it.
    var justFinished: Meeting?
    /// Meetings whose About was asked for this launch: one try each.
    private var aboutTried: Set<UUID> = []

    var audioCleaningMeetingIDs: Set<UUID> = []
    var batchAudioCleanProgress: (completed: Int, total: Int)? = nil
    var activeVideoTargetSummary: String? = nil

    var transcriptionJobs: [UUID: TranscriptionJobProgress] = [:]
    var completedRetranscribeIDs: Set<UUID> = []
    var transcriptionErrors: [UUID: String] = [:]
    var transcriptionLogs: [UUID: [TranscriptionLogEntry]] = [:]
    static let diarizerDisplayName = "FluidAudio Pyannote CoreML (Diarizer)"
    @ObservationIgnored private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]

    @MainActor
    func appendTranscriptionLog(_ entry: TranscriptionLogEntry, for meetingID: UUID) {
        var entries = transcriptionLogs[meetingID] ?? []
        entries.append(entry)
        if entries.count > 500 {
            entries.removeFirst(entries.count - 500)
        }
        transcriptionLogs[meetingID] = entries

        if entry.kind == .intervalSent, let current = transcriptionJobs[meetingID] {
            transcriptionJobs[meetingID] = TranscriptionJobProgress(
                meetingID: current.meetingID,
                fraction: current.fraction,
                stage: current.stage,
                startedAt: current.startedAt,
                activeModel: entry.modelName.isEmpty ? current.activeModel : entry.modelName,
                pipelineModels: current.pipelineModels,
                intervalStart: entry.intervalStart,
                intervalEnd: entry.intervalEnd
            )
        }
    }

    func clearTranscriptionLog(for meetingID: UUID) {
        transcriptionLogs.removeValue(forKey: meetingID)
    }

    func isBusy(_ meetingID: UUID) -> Bool {
        meetingWork.contains(meetingID)
    }

    /// Edits the brief of the call in progress: the copilot uses it from its
    /// next request and the meeting keeps the new text.
    func updateBrief(_ text: String) {
        callAnalysisEngine.updateBrief(text)
        currentMeeting?.brief = text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Guards against a second startRecording slipping in during the `await`s
    /// before isRecording is set — which would start a duplicate transcription
    /// loop and double every segment.
    private var isStarting = false
    private var screenSampler: ScreenFrameSampler?
    var isWatchingSelectedWindow: Bool { screenSampler != nil }
    private var screenSettingsObserver: NSObjectProtocol?
    private var screenSettingsSignature = ""
    private var screenArchive = false
    private var screenSession = UUID()

    private func screenSignature(forceLocal: Bool) -> String {
        let kind = SwitchingAnalysisProvider.liveKind
        let integrations = UserDefaults.standard.string(forKey: AssistantRoutingSettings.enabledKey) ?? ""
        return "\(integrations)|\(kind.rawValue)|\(CopilotProviderKind.modelName(for: kind))|\(forceLocal)|\(CloudGate.forcesLocal)|\(Redactor.isEnabled)|\(UserDefaults.standard.bool(forKey: Redactor.namesKey))"
    }
    private func updateScreenPolicy(meeting: Meeting, session: UUID) {
        guard screenSession == session, let sampler = screenSampler else { return }
        let signature = screenSignature(forceLocal: meeting.onDeviceOnly)
        guard signature != screenSettingsSignature else { return }
        screenSettingsSignature = signature
        let enabled = SwitchingAnalysisProvider.canSendScreenImages(forceLocal: meeting.onDeviceOnly)
        sampler.setEnabled(false)
        callAnalysisEngine.clearScreenContext(forceLocal: meeting.onDeviceOnly)
        meeting.videoWarning = enabled ? nil : "Screen analysis paused. Choose a vision-capable AI and review your privacy settings."
        sampler.setEnabled(enabled)
    }

    private func observeScreenPrivacy(meeting: Meeting, session: UUID) {
        guard screenSession == session, screenSampler != nil else { return }
        withObservationTracking {
            _ = meeting.onDeviceOnly
        } onChange: { [weak self, weak meeting] in
            Task { @MainActor in
                guard let self, let meeting, self.screenSession == session else { return }
                self.updateScreenPolicy(meeting: meeting, session: session)
                self.observeScreenPrivacy(meeting: meeting, session: session)
            }
        }
    }

    func observeScreenPrivacyForTest(meeting: Meeting, sampler: ScreenFrameSampler) {
        let session = UUID()
        screenSession = session
        screenSampler = sampler
        screenSettingsSignature = ""
        updateScreenPolicy(meeting: meeting, session: session)
        observeScreenPrivacy(meeting: meeting, session: session)
    }

    private func requireScreenAnalysis(profile: CallProfile?) throws {
        let local = UserDefaults.standard.bool(forKey: CloudGate.globalKey) || profile?.onDeviceOnly == true
        guard SwitchingAnalysisProvider.canSendScreenImages(forceLocal: local) else {
            throw RecordingError.screenAnalysisUnavailable
        }
    }

    /// Mirror of isStarting for the stop path: stop now drains the transcription
    /// backlog (seconds, not instant), so without this a double-stop would persist
    /// insights twice and run postProcess twice, and a start-during-stop would
    /// cancel the draining loop and share buffers with the old session. Readable
    /// so the live view can show a "Finalizing…" state.
    private(set) var isStopping = false
    /// Post-call chains still writing a report. Counted before their task
    /// starts, so the update notice can't slip in between stop and report.
    private var chainsInFlight = 0
    private let meetingWork = NSCountedSet()
    private var timer: Timer?
    private(set) var modelContext: ModelContext?

    /// "Still recording?" for the forgot-to-stop case (#50: a call left
    /// running for two idle hours). A transcript line is the voice signal;
    /// the voice gate keeps an idle room from producing any.
    private var lastVoiceAt: Date?
    private var lastIdleReminderAt: Date?
    /// PARROT_IDLE_REMINDER_SECONDS shortens it for testing.
    static let idleReminderAfter: TimeInterval = ProcessInfo.processInfo
        .environment["PARROT_IDLE_REMINDER_SECONDS"].flatMap(TimeInterval.init) ?? 15 * 60
    static let idleReminderID = "idle-reminder"

    /// Non-nil while a file import runs — drives the import banner in the UI.
    private(set) var importProgress: ImportProgress?
    /// Report rewrites running (or just failed), by meeting id. Here, not in
    /// the sheet, so "Keep working" can close the sheet; see startRewrite.
    var rewrites: [UUID: RewriteRun] = [:]

    struct ImportProgress: Equatable {
        var fileName: String
        var phase: Phase
        enum Phase {
            case transcribing, analyzing
            var label: String {
                switch self {
                case .transcribing: "Transcribing…"
                case .analyzing: "Analyzing…"
                }
            }
        }
    }

    /// `memory`/`chats` are overridable so the `--ask-chat-test` harness can
    /// point them at a scratch directory instead of the real Application
    /// Support store — normal app code keeps calling `RecordingManager()`.
    /// (nil defaults, not `= MeetingMemory()`: a default-argument expression
    /// isn't MainActor-isolated, so it can't call these actor-isolated inits.)
    /// `provider` too: the Ask routing test records every prompt with a stub.
    init(memory: MeetingMemory? = nil, chats: AskChatStore? = nil, provider: AnalysisProvider? = nil) {
        callAnalysisEngine = CallAnalysisEngine(provider: provider ?? SwitchingAnalysisProvider())
        self.memory = memory ?? MeetingMemory()
        self.chats = chats ?? AskChatStore()
        callAnalysisEngine.knowledgeBase = knowledgeBase
        callAnalysisEngine.docMatcher = docMatcher
    }

    /// Dev-harness only (--help-shots): seed a live-looking session so
    /// LiveRecordingView can render offscreen without recording anything.
    func seedForSnapshot(meeting: Meeting, elapsed: TimeInterval, modelContext: ModelContext) {
        self.modelContext = modelContext
        currentMeeting = meeting
        elapsedTime = elapsed
        recordingStartTime = Date().addingTimeInterval(-elapsed)
        isRecording = true
    }

    /// Dev-harness only (--ask-chat-test): a store to ask against, no recording.
    func attachForHarness(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Initialize and load the default WhisperKit model
    func prepare(modelContext: ModelContext) async {
        self.modelContext = modelContext
        recoverInterruptedRecordings(in: modelContext)
        profileStore.seedAndMigrateIfNeeded(context: modelContext, knowledgeBase: knowledgeBase)
        // Detection needs no model to watch the mic; it declines to offer a
        // recording until the model below is ready.
        callWatcher.recordingManager = self
        callWatcher.start()
        // Starts Sparkle at launch (not only when Settings opens) and keeps
        // Restart now away from a call, its report, and imports.
        AppUpdater.shared.isBusy = { [weak self] in
            guard let self else { return false }
            return isRecording || isBusy || chainsInFlight > 0
        }
        // Catch the memory up with meetings finished before it existed (or
        // changed since): background, low priority, local only.
        Task { await syncMemory() }
        // A private-path setup whose model download never finished.
        Task { await ollama.resumeIfNeeded() }
        await transcriptionEngine.loadModel(
            UserDefaults.standard.string(forKey: "whisperModel") ?? "base"
        )
    }

    /// A meeting left in `.recording` or `.processing` means the previous session was
    /// killed (crash or force-quit) before it could finish. The live transcript is
    /// already durable — `addSegment` saves every segment as it lands — so instead of
    /// discarding these, salvage the ones that captured any speech: re-run the normal
    /// post-call chain (diarization + report) on the surviving transcript and present
    /// them as recovered. Only truly empty orphans (killed before a word) stay failed.
    ///
    /// Runs at launch, off WhisperKit (transcript exists, diarization is energy-based,
    /// the report is a cloud call), so it needn't wait for the model.
    private func recoverInterruptedRecordings(in context: ModelContext) {
        guard let meetings = try? context.fetch(FetchDescriptor<Meeting>()) else { return }
        var changed = false
        for meeting in meetings where meeting.status == .recording || meeting.status == .processing {
            if meeting.segments.isEmpty {
                // Nothing was captured — the audio was never finalized and there's no
                // transcript to keep. Fail it, as before.
                meeting.status = .failed
                if meeting.errorMessage == nil {
                    meeting.errorMessage = "Recording was interrupted before it finished."
                }
            } else {
                // Salvageable: finish it in the background like a just-stopped call.
                meeting.wasRecovered = true
                meeting.status = .processing
                if meeting.duration == 0 {
                    meeting.duration = meeting.sortedSegments.last?.endTime ?? 0
                }
                let ref = meeting
                meetingWork.add(meeting.id)
                Task { await self.finishRecovery(meeting: ref) }
            }
            changed = true
        }
        if changed { try? context.save() }
    }

    private func finishRecovery(meeting: Meeting) async {
        let id = meeting.id
        defer { meetingWork.remove(id) }
        // A private call stays private through its salvaged report.
        await CloudGate.$scopeLocal.withValue(meeting.onDeviceOnly) {
            await self.finishRecoveryWork(meeting: meeting)
        }
    }

    private func finishRecoveryWork(meeting: Meeting) async {
        // Audio is best-effort: a crash leaves the .caf header unfinalized, so it may
        // not open. If it doesn't, drop the paths so no dead player shows and
        // diarization is skipped cleanly (segments keep their live "Me"/"Them" labels).
        if let path = meeting.systemAudioPath.nilIfEmpty,
           (try? AVAudioFile(forReading: URL(fileURLWithPath: path))) == nil {
            meeting.systemAudioPath = ""
            meeting.micAudioPath = nil
            try? modelContext?.save()
        }

        // Same chain a clean stop runs: diarization refines speakers and sets .done;
        // the report runs when the copilot is configured. Coaching stays on — a
        // crashed live call still has a real per-segment "Me"/"Them" split.
        await postProcess(meeting: meeting)
        if callAnalysisEngine.isEnabled, callAnalysisEngine.provider.isConfigured,
           meeting.summary == nil {
            callAnalysisEngine.provider.resetUsage()
            await generateSummary(meeting: meeting)
        }
        writeAIUsage(meeting: meeting, polishSeconds: 0)
        meeting.status = .done
        try? modelContext?.save()
        await meetingFinished(meeting)
    }

    // MARK: - Bookmarks

    /// Bumped on every successful mark so the live view can flash a
    /// confirmation, whichever path (button, menu, global hotkey) marked it.
    private(set) var lastMarked: Bookmark?

    /// Marks "now" in the call in progress. Returns nil when not recording,
    /// or when a mark already sits within `Bookmark.mergeWindow` (a double
    /// press is one moment).
    @discardableResult
    func markMoment(label: String = "") -> Bookmark? {
        guard isRecording, !isStopping, let meeting = currentMeeting,
              let start = recordingStartTime else { return nil }
        guard let mark = meeting.addBookmark(at: Date.now.timeIntervalSince(start), label: label) else {
            return nil
        }
        try? modelContext?.save()
        lastMarked = mark
        return mark
    }

    /// Labels a mark made during the call (the live view's quick field).
    func labelMoment(_ id: UUID, label: String) {
        currentMeeting?.renameBookmark(id, to: label)
        try? modelContext?.save()
    }

    /// ⌃⌥M marks a moment from any app — the user is in Zoom, not Parrot.
    /// Registered only while recording so the combo is never held otherwise.
    private let markHotKey = GlobalHotKey()
    static let globalMarkHotKeyDefaultsKey = "globalMarkHotKey"

    private func registerMarkHotKey() {
        let enabled = UserDefaults.standard.object(forKey: Self.globalMarkHotKeyDefaultsKey) as? Bool ?? true
        guard enabled else { return }
        markHotKey.register(.markMoment) { [weak self] in
            Task { @MainActor in self?.markMoment() }
        }
    }

    /// ⌃⌥⇧M mutes your side from any app (#96): Zoom's own mute never reaches
    /// Parrot. Held only while recording, like Mark's.
    private let muteHotKey = GlobalHotKey()
    private var lastMuteToggle = Date.distantPast

    var isMuted: Bool { audioCaptureManager.micMuted }

    func toggleMute() {
        // With Parrot in front, the global shortcut and the menu's own both fire.
        guard Date().timeIntervalSince(lastMuteToggle) > 0.3 else { return }
        lastMuteToggle = Date()
        audioCaptureManager.setMicMuted(!audioCaptureManager.micMuted)
    }

    /// Settings toggled mid-call: take effect now, not next recording.
    func refreshMarkHotKey() {
        markHotKey.unregister()
        if isRecording { registerMarkHotKey() }
    }

    // MARK: - Detected calls

    /// Starting, stopping or importing: not the moment to offer a recording.
    var isBusy: Bool { isStarting || isStopping || importProgress != nil }

    /// Starts recording a call noticed in another app (or from a calendar
    /// reminder). Same permission preflight as every Record button; the
    /// matched calendar event may pick the profile. Returns whether a
    /// recording is running afterwards.
    @discardableResult
    func startDetectedCall(appID: String?) async -> Bool {
        guard let modelContext, !isRecording, !isBusy else { return isRecording }
        var override: CallProfile?
        if calendar.isConnected, let event = calendar.currentEvent() {
            let profiles = profileStore.profiles(in: modelContext)
            if let id = CalendarService.matchProfile(title: event.title,
                                                     profiles: profiles.map { ($0.id, $0.name) }) {
                override = profiles.first { $0.id == id }
            }
        }
        do {
            try await preflightPermissionsAndStart(modelContext: modelContext,
                                                   profileOverride: override,
                                                   detectedCallAppID: appID)
        } catch {
            NSLog("Parrot: detected-call recording failed to start, \(error.localizedDescription)")
        }
        return isRecording
    }

    // MARK: - Recording Control

    /// The one shared entry point for every "start recording" button — checks
    /// permissions, then starts. Returns without starting (and without throwing)
    /// when a permission flow was triggered instead.
    func preflightPermissionsAndStart(modelContext: ModelContext,
                                      profileOverride: CallProfile? = nil,
                                      useScreen: Bool = false,
                                      detectedCallAppID: String? = nil) async throws {
        if useScreen { try requireScreenAnalysis(profile: profileOverride ?? profileStore.activeProfile) }
        // Check the system-audio permission BEFORE touching any capture API.
        // macOS 15+: the audio-only tap permission (optimistic after the one
        // official prompt — its grant can't be read back, see PermissionFlow).
        // macOS 14: Screen Recording, where querying SCShareableContent while
        // unauthorized pops the OS prompt AND throws. Either way PermissionFlow
        // posts a single prompt or deep-links to Settings — never both.
        if #available(macOS 15.0, *) {
            // .promptShown proceeds too: the recording starts while the one-time
            // OS prompt hovers, and the silent-tap rescue picks the grant up
            // within ~15 s of Allow. Blocking would ransom the meeting to a
            // dialog for a grant we can't even read back. Only .openSettings
            // (asked before, still never proven) pauses to point at the pane.
            guard PermissionFlow.requestSystemAudioCapture() != .openSettings else { return }
        } else {
            guard PermissionFlow.requestScreenCapture() == .granted else { return }
        }

        // Ensure the microphone is authorized so the user's own voice ("Me")
        // is captured. Without this the engine runs but feeds silence.
        // Non-fatal: system audio still records if denied.
        _ = await PermissionFlow.requestMicrophone()

        try await startRecording(modelContext: modelContext,
                                 profileOverride: profileOverride,
                                 useScreen: useScreen,
                                 detectedCallAppID: detectedCallAppID)
    }

    /// `profileOverride` records this one call under another profile (a
    /// detected call whose calendar title names one) without changing the
    /// user's active choice.
    func startRecording(modelContext: ModelContext,
                        profileOverride: CallProfile? = nil,
                        mode: SessionMode = .meeting,
                        useScreen: Bool = false,
                        detectedCallAppID: String? = nil) async throws {
        self.modelContext = modelContext
        // Reject re-entry up front (before any await) so a double-trigger can't
        // start two recordings / two transcription loops. Also blocked while a
        // file import is running — both drive the same shared WhisperKit.
        guard !isRecording, !isStarting, !isStopping, importProgress == nil else { return }
        isStarting = true
        defer { isStarting = false }

        let profile = profileOverride ?? profileStore.activeProfile
        if mode == .screenOnly || useScreen { try requireScreenAnalysis(profile: profile) }
        var requestedBackend = TranscriptionBackend.local
        if mode == .meeting {
            let forceLocal = UserDefaults.standard.bool(forKey: CloudGate.globalKey) || profile?.onDeviceOnly == true
            requestedBackend = forceLocal ? .local : TranscriptionBackend.selected
            var backend = requestedBackend
            if let account = backend.keychainAccount, APIKeyStore.load(account: account)?.isEmpty != false { backend = .local }
            let context = nextCallBrief + " " + (profile?.isUserModified == true ? (profile?.summary ?? "") + " " + (profile?.persona ?? "") : "")
            try await prepareSpeechModel(backend: backend, context: context)
            try Task.checkCancellation()
        }

        var videoFilter: SCContentFilter?
        var detectedVideoUnavailable = false
        if let detectedCallAppID {
            if UserDefaults.standard.bool(forKey: VideoCaptureService.enabledKey) {
                let capture = VideoCaptureService()
                if let filter = await capture.selectTargetForDetectedCall(appID: detectedCallAppID, mode: .current) {
                    videoFilter = filter
                    videoCapture = capture
                } else {
                    videoFilter = nil
                    videoCapture = nil
                    detectedVideoUnavailable = true
                }
            }
        } else if mode == .screenOnly || useScreen || UserDefaults.standard.bool(forKey: VideoCaptureService.enabledKey) {
            let capture = VideoCaptureService()
            if let filter = try await capture.chooseSource(mode: .current) {
                videoFilter = filter
                videoCapture = capture
            } else {
                if mode == .screenOnly || useScreen { return }
                videoFilter = nil
                videoCapture = nil
            }
        }

        if mode == .screenOnly || useScreen { try requireScreenAnalysis(profile: profile) }

        // Create meeting
        let meeting = Meeting()
        if detectedVideoUnavailable { meeting.videoWarning = "Could not find the call window. Audio will be recorded without video." }
        meeting.sessionMode = mode
        if mode == .screenOnly { meeting.title = "Screen session" }
        if let capture = videoCapture, videoFilter != nil {
            activeVideoTargetSummary = capture.targetSummary
            meeting.videoTargetSummary = capture.targetSummary
            capture.onTargetChanged = { [weak self, weak meeting] newSummary in
                Task { @MainActor in
                    self?.activeVideoTargetSummary = newSummary
                    meeting?.videoTargetSummary = newSummary
                }
            }
        }
        modelContext.insert(meeting)

        // Persist active profile/brief/snapshot onto the meeting
        meeting.profile = profile
        meeting.profileSnapshotData = profile.flatMap { try? JSONEncoder().encode($0.kinds) }

        // On-device only (globally, or for this profile): the live call
        // passes it to transcription and the copilot explicitly; the
        // post-call chain runs inside CloudGate's scope.
        meeting.onDeviceOnly = UserDefaults.standard.bool(forKey: CloudGate.globalKey)
            || profile?.onDeviceOnly == true

        // The calendar event this call belongs to names the meeting and
        // lists who's on it. The invite's text reaches the copilot only if
        // the user turned that on (it's someone else's writing, and the
        // copilot may be a cloud model), and never as the user's own brief.
        var calendarContext = ""
        var lastCall = ""
        var previousIsPrivate = false
        if mode == .meeting, calendar.isConnected, let event = calendar.currentEvent() {
            meeting.apply(event)
            if UserDefaults.standard.bool(forKey: CalendarService.useDetailsKey) {
                calendarContext = CalendarService.inviteContext(for: event)
            }
            // "From your last call": open items from the previous meeting
            // with these people. Parrot's own notes, read locally.
            if let previous = previousMeeting(for: meeting, in: modelContext) {
                previousIsPrivate = !CloudGate.mayLeaveMac(previous)
                meeting.previousMeetingID = previous.id
                lastCall = LastCallBrief.context(
                    title: previous.title, date: previous.date,
                    items: LastCallBrief.openItems(summary: previous.summary, coaching: previous.coaching,
                                                   template: previous.reportTemplate))
            }
        }
        meeting.brief = nextCallBrief.nilIfEmpty

        // Set up audio capture. On failure, remove the just-inserted meeting —
        // otherwise it lingers as a ghost .recording row until the next launch's
        // orphan reconciliation flags it "interrupted".
        if mode == .meeting {
            do {
                try await audioCaptureManager.startCapture()
            } catch {
                videoCapture = nil
                modelContext.delete(meeting)
                try? modelContext.save()
                throw error
            }
            meeting.systemAudioPath = audioCaptureManager.systemAudioURL?.path ?? ""
            meeting.micAudioPath = audioCaptureManager.micAudioURL?.path
        }
        if let videoFilter, let capture = videoCapture {
            screenArchive = UserDefaults.standard.bool(forKey: VideoCaptureService.enabledKey)
            if mode == .screenOnly || useScreen {
                let session = UUID()
                screenSession = session
                let sampler = ScreenFrameSampler(onSample: { [weak self] context in
                    Task { @MainActor in
                        guard let self, self.screenSession == session, self.screenSampler != nil else { return }
                        guard self.screenSignature(forceLocal: meeting.onDeviceOnly) == self.screenSettingsSignature else {
                            self.updateScreenPolicy(meeting: meeting, session: session)
                            return
                        }
                        guard SwitchingAnalysisProvider.canSendScreenImages(forceLocal: meeting.onDeviceOnly) else { return }
                        self.callAnalysisEngine.ingestScreenContext(context)
                    }
                }, onError: { [weak self, weak meeting] message in
                    Task { @MainActor in
                        guard let self, self.screenSession == session else { return }
                        meeting?.videoWarning = message
                    }
                })
                capture.onFrame = { [weak sampler] buffer, capturedAt in sampler?.submit(buffer, capturedAt: capturedAt) }
                capture.onActivity = { [weak self, weak sampler] date in
                    sampler?.markObserved(at: date)
                    Task { @MainActor in
                        guard let self, self.screenSession == session else { return }
                        self.callAnalysisEngine.refreshScreenActivity(date)
                    }
                }
                capture.onInactive = { [weak self, weak sampler] in
                    sampler?.invalidate()
                    Task { @MainActor in
                        guard let self, self.screenSession == session else { return }
                        self.callAnalysisEngine.clearScreenContext()
                    }
                }
                screenSampler = sampler
                screenSettingsSignature = ""
                screenSettingsObserver = NotificationCenter.default.addObserver(
                    forName: UserDefaults.didChangeNotification, object: nil, queue: .main
                ) { [weak self, weak meeting] _ in
                    Task { @MainActor in
                        guard let self, let meeting, self.screenSession == session else { return }
                        self.updateScreenPolicy(meeting: meeting, session: session)
                    }
                }
                updateScreenPolicy(meeting: meeting, session: session)

            }
            capture.onError = { [weak self, weak meeting, weak capture] message in
                Task { @MainActor in
                    guard let self, let capture, self.videoCapture === capture else { return }
                    meeting?.videoWarning = message
                    self.screenSampler?.stop()
                    self.screenSampler = nil
                    self.callAnalysisEngine.clearScreenContext()
                }
            }
            do {
                try await capture.start(filter: videoFilter,
                                        audioOrigin: mode == .meeting ? audioCaptureManager.captureOrigin : ProcessInfo.processInfo.systemUptime,
                                        archive: screenArchive)
            } catch {
                meeting.videoError = error.localizedDescription
                videoCapture = nil
                screenSampler?.stop()
                screenSampler = nil
                if let screenSettingsObserver { NotificationCenter.default.removeObserver(screenSettingsObserver) }
                screenSettingsObserver = nil
                if mode == .screenOnly {
                    modelContext.delete(meeting)
                    throw error
                }
            }
        }

        // Wire audio to transcription, tagged by stream (mic = Me, system = Them)
        audioCaptureManager.onAudioBuffer = { [weak self] buffer, source in
            self?.transcriptionEngine.appendAudio(buffer, source: source)
        }

        // Wire transcription output to storage and the live copilot
        transcriptionEngine.onSegment = { [weak self] result in
            Task { @MainActor in
                self?.lastVoiceAt = .now
                self?.addSegment(result)
                self?.nudges.add(line: NudgeDetector.Line(source: result.source, start: result.startTime,
                                                          end: result.endTime, text: result.text))
                self?.callAnalysisEngine.ingest(
                    text: result.text,
                    at: result.endTime,
                    source: result.source,
                    duration: result.endTime - result.startTime
                )
            }
        }

        // A Parakeet side that turned out to be another language mid-call:
        // its last stretch, re-done with Whisper, replaces what Parakeet wrote.
        transcriptionEngine.onReplace = { [weak self] source, range, results in
            Task { @MainActor in self?.replaceSegments(source: source, in: range, with: results) }
        }

        // Live speaker labels reach the copilot as names, not "Them".
        callAnalysisEngine.speakerNames = { [weak self] in
            guard let meeting = self?.currentMeeting else { return [:] }
            var names: [TimeInterval: String] = [:]
            for segment in meeting.segments {
                guard let label = segment.speakerLabel, label != "Me", label != "Them" else { continue }
                names[segment.endTime] = meeting.displayName(forSpeaker: label)
            }
            return names
        }

        // Start transcription and the copilot loop
        transcriptionEngine.forceLocal = meeting.onDeviceOnly
        if mode == .meeting { transcriptionEngine.startTranscribing(meetingStartTime: .now, backend: requestedBackend) }
        callAnalysisEngine.provider.resetUsage()  // this call's token meter starts at zero
        docMatcher.resetUsage()
        nudges.start(gauges: profile?.gauges ?? [])
        nudges.onShow = { [weak self] nudge in
            guard let self else { return }
            // The Copilot banner covers it when Parrot is in front and Copilot is showing.
            if !(NSApp.isActive && self.callAnalysisEngine.isActive) { NudgePillController.shared.show(nudge) }
        }
        NudgePillController.shared.onOpen = {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain && $0.isVisible }?.makeKeyAndOrderFront(nil)
        }
        callAnalysisEngine.onPassCompleted = { [weak self] pass in self?.nudges.add(pass: pass) }
        callAnalysisEngine.start(profile: profile, brief: nextCallBrief, calendarContext: calendarContext,
                                 previousCall: lastCall, previousCallIsPrivate: previousIsPrivate,
                                 forceLocal: meeting.onDeviceOnly)

        currentMeeting = meeting
        if screenSampler != nil {
            let session = screenSession
            callAnalysisEngine.screenDispatchAllowed = { [weak self, weak meeting] in
                guard let self, let meeting, self.screenSession == session else { return false }
                guard self.screenSignature(forceLocal: meeting.onDeviceOnly) == self.screenSettingsSignature,
                      SwitchingAnalysisProvider.canSendScreenImages(forceLocal: meeting.onDeviceOnly) else {
                    self.updateScreenPolicy(meeting: meeting, session: session)
                    return false
                }
                return true
            }
            updateScreenPolicy(meeting: meeting, session: session)
            observeScreenPrivacy(meeting: meeting, session: session)
        }
        recordingStartTime = .now
        isRecording = true
        FloatingAssistantWidgetController.shared.onRecordingStarted(meeting: meeting, manager: self)
        // The last call's "Call saved" sheet would cover this one; its
        // title and note can still be set on the meeting page.
        justFinished = nil
        lastVoiceAt = .now
        lastIdleReminderAt = nil
        lastMarked = nil
        registerMarkHotKey()
        muteHotKey.register(.muteMe) { [weak self] in
            Task { @MainActor in self?.toggleMute() }
        }

        // Experimental live speaker labels: re-diarize the call-so-far so
        // "Them" bubbles upgrade to stable Speaker N mid-call. Paced by
        // `liveSweepDelay`; the final post-call pass stays authoritative.
        liveAnchors = [:]
        lastSweptThemSegmentCount = 0
        liveSpeakerSuggestions = [:]
        if mode == .meeting && UserDefaults.standard.bool(forKey: "liveSpeakerLabels") {
            liveSweepTask = Task { [weak self] in
                while !Task.isCancelled {
                    let delay = Self.liveSweepDelay(power: .now)
                    try? await Task.sleep(for: .seconds(delay ?? 30))
                    // Re-check after the wait: the Mac may have heated up or
                    // gone to Low Power Mode meanwhile.
                    guard let self, Self.liveSweepDelay(power: .now) != nil else { continue }
                    await self.runLiveSweep()
                }
            }
        }

        // Start elapsed time timer
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recordingStartTime else { return }
                self.elapsedTime = Date.now.timeIntervalSince(start)
                guard mode == .meeting else { return }
                let clock = self.transcriptionEngine.speechClock()
                self.nudges.tick(now: clock.now, lastHeard: clock.lastHeard, paused: self.callAnalysisEngine.isPaused)
                if let voice = self.lastVoiceAt,
                   Self.idleReminderDue(now: .now, lastVoice: voice,
                                        lastReminder: self.lastIdleReminderAt, after: Self.idleReminderAfter) {
                    self.lastIdleReminderAt = .now
                    Self.postIdleReminder(silentFor: Date.now.timeIntervalSince(voice))
                }
            }
        }

        try modelContext.save()
    }

    func stopRecording() async {
        guard isRecording, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        activeVideoTargetSummary = nil

        timer?.invalidate()
        timer = nil
        NudgePillController.shared.hide()
        markHotKey.unregister()
        muteHotKey.unregister()
        // A "Still recording?" left in Notification Center is stale once stopped.
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.idleReminderID])
        liveSweepTask?.cancel()
        liveSweepTask = nil

        // Stop the copilot (its ingest no-ops once inactive), then capture — so
        // the transcription buffers stop growing and the drain below terminates.
        // Capture stops first also so both .caf files are finalized before the
        // diarization task can read them.
        callAnalysisEngine.stop()
        screenSession = UUID()
        screenSampler?.stop()
        screenSampler = nil
        if let screenSettingsObserver { NotificationCenter.default.removeObserver(screenSettingsObserver) }
        screenSettingsObserver = nil
        let screenOnly = currentMeeting?.sessionMode == .screenOnly
        let audioStop = Task { @MainActor in
            if !screenOnly { await audioCaptureManager.stopCapture() }
        }

        if let capture = videoCapture, let meeting = currentMeeting {
            if !screenOnly {
                capture.updateAudioOriginIfNeeded(audioCaptureManager.firstAudioSampleUptime)
            }
            let earlyNote = capture.stoppedEarlyNote
            do {
                if screenArchive {
                    let (url, offset) = try await capture.stop()
                    if screenOnly { meeting.videoPath = url.path }
                    else {
                        meeting.rawVideoPath = url.path
                        meeting.videoOffset = offset
                    }
                } else {
                    try await capture.stopWatching()
                }
            } catch VideoCaptureService.VideoError.partial(let url, let offset, let reason) {
                if screenOnly { meeting.videoPath = url.path }
                else {
                    meeting.rawVideoPath = url.path
                    meeting.videoOffset = offset
                }
                meeting.videoWarning = reason
            } catch {
                meeting.videoError = error.localizedDescription
            }
            if earlyNote != nil && meeting.videoError == nil {
                meeting.videoWarning = earlyNote
            }
            videoCapture = nil
        }
        await audioStop.value

        if let meeting = currentMeeting, !screenOnly {
            if AudioQualityCleaner.isAutoCleanEnabled {
                await cleanMeetingAudio(meeting, remuxVideoIfPresent: false)
            }
            if meeting.rawVideoPath != nil {
                let captureWarning = meeting.videoWarning
                await retryVideoMux(meeting)
                if let captureWarning, meeting.videoWarning == nil { meeting.videoWarning = captureWarning }
            }
        }

        // Drain the transcription backlog so the call's final words land before
        // the transcript is assembled for the summary/coaching reports.
        if !screenOnly { await transcriptionEngine.stopTranscribing() }
        // onSegment persists segments via Task { @MainActor } hops; yield once so
        // the last enqueued addSegment jobs run before we read segments back.
        await Task.yield()

        // Update meeting
        if let meeting = currentMeeting {
            meeting.duration = elapsedTime
            meeting.status = screenOnly ? .done : .processing
            let tone = nudges.stop()
            meeting.nudges = tone.nudges
            meeting.moodTimeline = tone.timeline

            // Persist the copilot's insights so they survive into the meeting report.
            // Same SwiftData rule as addSegment: insert before setting the relationship.
            // Excerpt cards are the fast path's bridge, not model insights;
            // the report keeps Haiku's cards only.
            for insight in callAnalysisEngine.insights where insight.kindKey != Insight.docExcerptKind {
                let stored = CallInsight(from: insight)
                modelContext?.insert(stored)
                stored.meeting = meeting
            }
            try? modelContext?.save()

            // Post-processing chain, strictly sequential: polish rebuilds the
            // transcript (optional, best-effort), diarization refines labels on
            // whatever transcript survived, and the report is generated from
            // the FINAL text — never from a transcript that's about to change.
            let meetingRef = meeting
            // This call's live identities go with it: the next recording may
            // start (and fill liveAnchors) before this chain reaches diarization.
            let anchors = liveAnchors
            liveAnchors = [:]
            // Read now: the next call resets it.
            let micHeardSpeakers = transcriptionEngine.micHearsSpeakers
            if !screenOnly {
                chainsInFlight += 1
                meetingWork.add(meeting.id)
                let postCallTask = Task {
                    // A private meeting's report and after-call actions stay on
                    // this Mac; a call recording meanwhile is unaffected.
                    await CloudGate.$scopeLocal.withValue(meetingRef.onDeviceOnly) {
                        await self.runPostCallChain(meetingRef, anchors: anchors, micHeardSpeakers: micHeardSpeakers)
                    }
                }
                transcriptionTasks[meeting.id] = postCallTask
            }
            justFinished = meeting
        }

        isRecording = false
        elapsedTime = 0
        recordingStartTime = nil
        AppUpdater.shared.becameIdle()
    }

    private func runPostCallChain(_ meetingRef: Meeting, anchors: [String: [Float]], micHeardSpeakers: Bool) async {
        let id = meetingRef.id
        defer {
            meetingWork.remove(id)
            transcriptionTasks.removeValue(forKey: id)
            transcriptionJobs.removeValue(forKey: id)
            chainsInFlight -= 1
            AppUpdater.shared.becameIdle()
        }
        let polishSeconds = await polishTranscript(meeting: meetingRef, micHeardSpeakers: micHeardSpeakers)
        await postProcess(meeting: meetingRef, anchors: anchors)
        if callAnalysisEngine.isEnabled, callAnalysisEngine.provider.isConfigured {
            await generateSummary(meeting: meetingRef)
            await writeAbout(meetingRef)
        }
        // Last in the chain so the meter has seen the summary/coaching/about calls too.
        writeAIUsage(meeting: meetingRef, polishSeconds: polishSeconds)
        meetingRef.status = .done
        try? modelContext?.save()
        await meetingFinished(meetingRef)
    }

    // MARK: - File Import

    /// Import an existing audio file as a new meeting: copy it into app storage,
    /// transcribe the whole file on-device, then run the same diarization + report
    /// chain a live recording gets. Returns the created meeting (already inserted,
    /// status `.processing`) so the caller can select it; nil if it couldn't start.
    @discardableResult
    func importAudioFile(from pickedURL: URL, modelContext: ModelContext) -> Meeting? {
        self.modelContext = modelContext
        // One owner of WhisperKit at a time: refuse while recording or importing.
        guard !isRecording, !isStarting, !isStopping, importProgress == nil else { return nil }

        // A user-picked file lives outside the sandbox — open the scope to copy it.
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }

        let name = pickedURL.deletingPathExtension().lastPathComponent
        let ext = pickedURL.pathExtension.isEmpty ? "m4a" : pickedURL.pathExtension
        // Copy in, so playback and diarization survive the original moving/deleting.
        let dest = AudioCaptureManager.storageDirectory()
            .appendingPathComponent("import_\(Int(Date().timeIntervalSince1970)).\(ext)")
        do {
            try FileManager.default.copyItem(at: pickedURL, to: dest)
        } catch {
            NSLog("Parrot: import copy failed — \(error.localizedDescription)")
            return nil
        }

        // Land under the file's own date, so a recording from last week reads as
        // last week rather than "now".
        let fileDate = (try? pickedURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .now

        let meeting = Meeting(title: name, date: fileDate, systemAudioPath: dest.path)
        meeting.importedAt = .now
        meeting.status = .processing
        let profile = profileStore.activeProfile
        meeting.profile = profile
        meeting.profileSnapshotData = profile.flatMap { try? JSONEncoder().encode($0.kinds) }
        meeting.onDeviceOnly = UserDefaults.standard.bool(forKey: CloudGate.globalKey)
            || profile?.onDeviceOnly == true
        modelContext.insert(meeting)
        try? modelContext.save()

        importProgress = ImportProgress(fileName: name, phase: .transcribing)
        let ref = meeting
        meetingWork.add(meeting.id)
        let importTask = Task { await runImport(meeting: ref, audioURL: dest) }
        transcriptionTasks[meeting.id] = importTask
        return meeting
    }

    private func prepareSpeechModel(backend: TranscriptionBackend, context: String) async throws {
        guard let model = try await SpeechModels.choice(backend, context: context), !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecordingError.noDownloadedSpeechModel }
        let localAuto = backend == .local && UserDefaults.standard.bool(forKey: SpeechModels.autoKey(.local))
        let local = localAuto ? model : (UserDefaults.standard.string(forKey: "whisperModel") ?? "base")
        if !transcriptionEngine.isReady || transcriptionEngine.currentModel != local {
            await transcriptionEngine.loadModel(local, allowDownload: !localAuto)
        }
        guard transcriptionEngine.isReady, transcriptionEngine.currentModel == local else { throw RecordingError.modelNotReady }
        transcriptionEngine.sessionModel = model
    }

    private func runImport(meeting: Meeting, audioURL: URL) async {
        let id = meeting.id
        defer {
            meetingWork.remove(id)
            transcriptionTasks.removeValue(forKey: id)
            transcriptionJobs.removeValue(forKey: id)
        }
        await CloudGate.$scopeLocal.withValue(meeting.onDeviceOnly) {
            await self.runImportWork(meeting: meeting, audioURL: audioURL)
        }
    }

    private func runImportWork(meeting: Meeting, audioURL: URL) async {
        let startedAt = Date()
        transcriptionLogs[meeting.id] = []

        if AudioQualityCleaner.isAutoCleanEnabled {
            await cleanMeetingAudio(meeting, remuxVideoIfPresent: false)
        }

        let modelName = transcriptionEngine.currentModel ?? UserDefaults.standard.string(forKey: "whisperModel") ?? "base"
        let effectiveLang = MLXTranscriber.isMLX(modelName)
            ? MLXTranscriber.effectiveLanguage(for: modelName, selected: TranscriptionLanguage.selected)
            : TranscriptionLanguage.selected
        let speechModelDisplay = TranscriptionJobProgress.displayModelName(modelID: modelName, backend: .local, language: effectiveLang)
        let pipelineModels = [speechModelDisplay, Self.diarizerDisplayName, "Report AI"]

        var succeeded = false
        defer {
            importProgress = nil
            transcriptionJobs.removeValue(forKey: meeting.id)
            AppUpdater.shared.becameIdle()
            if Task.isCancelled {
                if transcriptionLogs[meeting.id]?.last?.summary != "Cancelled by user" {
                    appendTranscriptionLog(
                        TranscriptionLogEntry(
                            kind: .lifecycle,
                            modelName: speechModelDisplay,
                            summary: "Cancelled by user"
                        ),
                        for: meeting.id
                    )
                }
            } else if succeeded {
                appendTranscriptionLog(
                    TranscriptionLogEntry(
                        kind: .lifecycle,
                        modelName: speechModelDisplay,
                        summary: "Transcription complete"
                    ),
                    for: meeting.id
                )
            }
        }

        transcriptionJobs[meeting.id] = TranscriptionJobProgress(
            meetingID: meeting.id,
            fraction: 0.03,
            stage: .preparingModel(speechModelDisplay),
            startedAt: startedAt,
            activeModel: speechModelDisplay,
            pipelineModels: pipelineModels
        )
        appendTranscriptionLog(
            TranscriptionLogEntry(
                kind: .lifecycle,
                modelName: speechModelDisplay,
                summary: "Preparing speech model \(speechModelDisplay)"
            ),
            for: meeting.id
        )

        do {
            try await prepareSpeechModel(backend: .local, context: meeting.brief ?? "")
            appendTranscriptionLog(
                TranscriptionLogEntry(
                    kind: .lifecycle,
                    modelName: speechModelDisplay,
                    summary: "Speech model \(speechModelDisplay) ready"
                ),
                for: meeting.id
            )
        } catch {
            appendTranscriptionLog(
                TranscriptionLogEntry(
                    kind: .error,
                    modelName: speechModelDisplay,
                    summary: "Model preparation failed: \(error.localizedDescription)"
                ),
                for: meeting.id
            )
            meeting.status = .failed
            meeting.errorMessage = error.localizedDescription
            try? modelContext?.save()
            return
        }

        guard !Task.isCancelled else {
            meeting.status = .failed
            meeting.errorMessage = "Import was cancelled."
            try? modelContext?.save()
            return
        }

        let traceCallback: @Sendable (TranscriptionLogEntry) -> Void = { [weak self] entry in
            Task { @MainActor [weak self] in
                self?.appendTranscriptionLog(entry, for: meeting.id)
            }
        }

        // 1. Whole-file, on-device transcription. Every segment is "Them" (one
        //    mixed track, no mic channel to tag "Me"); diarization splits it below.
        do {
            let onChunkProgress: @Sendable (Double, Double) -> Void = { [weak self] done, total in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let fraction = total > 0 ? (done / total) : 0
                    let existingJob = self.transcriptionJobs[meeting.id]
                    self.transcriptionJobs[meeting.id] = TranscriptionJobProgress(
                        meetingID: meeting.id,
                        fraction: 0.05 + 0.75 * fraction,
                        stage: .transcribing(trackLabel: "Audio", completedSeconds: done, totalSeconds: total),
                        startedAt: startedAt,
                        activeModel: existingJob?.activeModel ?? speechModelDisplay,
                        pipelineModels: pipelineModels,
                        intervalStart: existingJob?.intervalStart,
                        intervalEnd: existingJob?.intervalEnd
                    )
                }
            }
            appendTranscriptionLog(
                TranscriptionLogEntry(
                    kind: .lifecycle,
                    modelName: speechModelDisplay,
                    trackLabel: audioURL.lastPathComponent,
                    summary: "Transcribing audio track \(audioURL.lastPathComponent)"
                ),
                for: meeting.id
            )
            let transcribeURL = meeting.effectiveSystemAudioPath.map { URL(fileURLWithPath: $0) } ?? audioURL
            let results = try await transcriptionEngine.transcribeFile(
                url: transcribeURL,
                trackLabel: audioURL.lastPathComponent,
                onProgress: onChunkProgress,
                onTrace: traceCallback
            )
            guard !results.isEmpty else {
                appendTranscriptionLog(
                    TranscriptionLogEntry(
                        kind: .lifecycle,
                        modelName: speechModelDisplay,
                        summary: "No speech found in this file"
                    ),
                    for: meeting.id
                )
                meeting.status = .failed
                meeting.errorMessage = "No speech found in this file."
                try? modelContext?.save()
                return
            }
            for result in results {
                let segment = TranscriptSegment(
                    startTime: result.startTime, endTime: result.endTime,
                    text: result.text, speakerLabel: result.source.label,
                    confidence: result.confidence)
                modelContext?.insert(segment)
                segment.meeting = meeting
            }
            // Real audio length (trailing silence included) for stats/cost.
            if let file = try? AVAudioFile(forReading: audioURL) {
                meeting.duration = Double(file.length) / file.fileFormat.sampleRate
            } else {
                meeting.duration = results.last?.endTime ?? 0
            }
            try? modelContext?.save()
        } catch {
            if Task.isCancelled {
                meeting.status = .failed
                meeting.errorMessage = "Import was cancelled."
                try? modelContext?.save()
                return
            }
            appendTranscriptionLog(
                TranscriptionLogEntry(
                    kind: .error,
                    modelName: speechModelDisplay,
                    summary: "Import transcription failed: \(error.localizedDescription)"
                ),
                for: meeting.id
            )
            NSLog("Parrot: import transcription failed, \(error)")
            meeting.status = .failed
            // The raw error is a CoreAudio code ("ExtAudioFileRead -50"): no use
            // to the person looking at it. The log keeps it.
            meeting.errorMessage = "\(MeetingActions.appName) couldn't read this audio file. Check it plays in QuickTime, then save it again as M4A or WAV and import that."
            try? modelContext?.save()
            return
        }

        guard !Task.isCancelled else {
            meeting.status = .failed
            meeting.errorMessage = "Import was cancelled."
            try? modelContext?.save()
            return
        }

        // 2. Same post-call chain as a recording: diarization refines the speaker
        //    labels and flips status to .done; the summary runs when the copilot
        //    is configured. Coaching is skipped — no "Me" channel to measure.
        importProgress?.phase = .analyzing
        transcriptionJobs[meeting.id] = TranscriptionJobProgress(
            meetingID: meeting.id,
            fraction: 0.84,
            stage: .diarizing,
            startedAt: startedAt,
            activeModel: Self.diarizerDisplayName,
            pipelineModels: pipelineModels,
            intervalStart: nil,
            intervalEnd: nil
        )
        await postProcess(meeting: meeting)
        if callAnalysisEngine.isEnabled, callAnalysisEngine.provider.isConfigured {
            appendTranscriptionLog(
                TranscriptionLogEntry(
                    kind: .lifecycle,
                    modelName: "Report AI",
                    summary: "Generating meeting report and summary"
                ),
                for: meeting.id
            )
            transcriptionJobs[meeting.id] = TranscriptionJobProgress(
                meetingID: meeting.id,
                fraction: 0.94,
                stage: .updatingReport,
                startedAt: startedAt,
                activeModel: "Report AI",
                pipelineModels: pipelineModels,
                intervalStart: nil,
                intervalEnd: nil
            )
            callAnalysisEngine.provider.resetUsage()
            await generateSummary(meeting: meeting, includeCoaching: false)
            await writeAbout(meeting)  // the file's name stays its title
        }
        writeAIUsage(meeting: meeting, polishSeconds: 0, backendOverride: .local)
        succeeded = true
        meeting.status = .done
        try? modelContext?.save()
        await meetingFinished(meeting)
    }

    func retryVideoMux(_ meeting: Meeting) async {
        guard let modelContext else { return }
        if let raw = VideoCaptureService.ownedURL(meeting.rawVideoPath) {
            let destination = AudioCaptureManager.storageDirectory().appendingPathComponent("video_\(UUID().uuidString).mp4")
            let audio = meeting.effectiveAudioPaths.map { URL(fileURLWithPath: $0) }
            let previousVideoPath = meeting.videoPath
            do {
                try modelContext.save()
                try await VideoCaptureService.mux(video: raw, offset: meeting.videoOffset, audio: audio, destination: destination)
                meeting.videoPath = destination.path
                meeting.videoError = nil
                meeting.videoWarning = nil
                do {
                    try modelContext.save()
                } catch {
                    meeting.videoPath = previousVideoPath
                    throw error
                }
                meeting.rawVideoPath = nil
                do {
                    try modelContext.save()
                    try FileManager.default.removeItem(at: raw)
                } catch {
                    meeting.rawVideoPath = raw.path
                    meeting.videoWarning = "Video saved, but the original could not be removed: \(error.localizedDescription)"
                    try modelContext.save()
                }
                if let previous = VideoCaptureService.ownedURL(previousVideoPath), previous != raw {
                    try FileManager.default.removeItem(at: previous)
                }
            } catch {
                meeting.videoError = error.localizedDescription
            }
        } else if let vPath = meeting.videoPath?.nilIfEmpty,
                  let videoURL = VideoCaptureService.ownedURL(vPath),
                  FileManager.default.fileExists(atPath: videoURL.path) {
            let audio = meeting.effectiveAudioPaths.map { URL(fileURLWithPath: $0) }
            do {
                try await VideoCaptureService.remuxReplacingAudio(videoFile: videoURL, offset: meeting.videoOffset, audio: audio)
                meeting.videoError = nil
                meeting.videoWarning = nil
                try? modelContext.save()
            } catch {
                meeting.videoError = error.localizedDescription
            }
        }
    }

    @MainActor
    func changeVideoTarget() {
        videoCapture?.presentChangeTargetPicker()
    }

    @MainActor
    func cleanMeetingAudio(_ meeting: Meeting, remuxVideoIfPresent: Bool = true) async {
        guard !audioCleaningMeetingIDs.contains(meeting.id) else { return }
        audioCleaningMeetingIDs.insert(meeting.id)
        defer { audioCleaningMeetingIDs.remove(meeting.id) }

        let sys = meeting.systemAudioPath.nilIfEmpty
        let mic = meeting.micAudioPath?.nilIfEmpty
        guard sys != nil || mic != nil else { return }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try AudioQualityCleaner.cleanMeetingTracks(systemPath: sys, micPath: mic)
            }.value

            let previousSystemPath = meeting.cleanedSystemAudioPath
            let previousMicPath = meeting.cleanedMicAudioPath
            let previousReport = meeting.audioQualityReportData
            let previousUseCleanedAudio = meeting.useCleanedAudio
            meeting.cleanedSystemAudioPath = result.cleanedSystemPath
            meeting.cleanedMicAudioPath = result.cleanedMicPath
            meeting.audioQualityReport = result.report
            meeting.useCleanedAudio = true
            do {
                guard let modelContext else { throw CocoaError(.fileNoSuchFile) }
                try modelContext.save()
            } catch {
                meeting.cleanedSystemAudioPath = previousSystemPath
                meeting.cleanedMicAudioPath = previousMicPath
                meeting.audioQualityReportData = previousReport
                meeting.useCleanedAudio = previousUseCleanedAudio
                for path in [result.cleanedSystemPath, result.cleanedMicPath].compactMap({ $0 }) {
                    do { try FileManager.default.removeItem(atPath: path) }
                    catch { NSLog("Parrot: could not remove unsaved cleaned audio: \(error.localizedDescription)") }
                }
                throw error
            }

            if remuxVideoIfPresent,
               let vPath = meeting.videoPath?.nilIfEmpty,
               FileManager.default.fileExists(atPath: vPath) {
                let audio = meeting.effectiveAudioPaths.map { URL(fileURLWithPath: $0) }
                try? await VideoCaptureService.remuxReplacingAudio(videoFile: URL(fileURLWithPath: vPath), offset: meeting.videoOffset, audio: audio)
            }
        } catch {
            NSLog("Parrot: audio cleaning failed for meeting \(meeting.id): \(error.localizedDescription)")
        }
    }

    @MainActor
    func cleanAllMeetingsAudio(forceReclean: Bool = false) async -> Int {
        guard batchAudioCleanProgress == nil, let modelContext else { return 0 }
        guard let all = try? modelContext.fetch(FetchDescriptor<Meeting>()) else { return 0 }
        let targets = all.filter { m in
            m.status != .recording &&
            (m.systemAudioPath.nilIfEmpty != nil || m.micAudioPath?.nilIfEmpty != nil) &&
            (forceReclean || !m.hasCleanedAudio)
        }
        guard !targets.isEmpty else { return 0 }

        batchAudioCleanProgress = (0, targets.count)
        defer { batchAudioCleanProgress = nil }

        for (idx, meeting) in targets.enumerated() {
            await cleanMeetingAudio(meeting, remuxVideoIfPresent: true)
            batchAudioCleanProgress = (idx + 1, targets.count)
        }
        return targets.count
    }

    // MARK: - Deletion

    var deletionFailure: String?

    /// Deletes a meeting and its audio files. The only removal path in the app —
    /// without it storage grows forever. Refuses the active recording.
    @discardableResult
    func delete(_ meeting: Meeting) -> Bool {
        deletionFailure = nil
        guard !meeting.isDeleted, let context = meeting.modelContext else {
            deletionFailure = "This meeting is no longer available. Reopen the library and try again."
            return false
        }
        let id = meeting.id
        guard !(isRecording && id == currentMeeting?.id) else {
            deletionFailure = "Stop recording before deleting this meeting."
            return false
        }
        guard !meetingWork.contains(id) else {
            deletionFailure = "This meeting is still being processed. Try deleting it when processing finishes."
            return false
        }
        let audioPaths = [meeting.systemAudioPath.nilIfEmpty, meeting.micAudioPath?.nilIfEmpty, meeting.cleanedSystemAudioPath?.nilIfEmpty, meeting.cleanedMicAudioPath?.nilIfEmpty].compactMap { $0 }
        let videoURLs = [meeting.videoPath, meeting.rawVideoPath].compactMap(VideoCaptureService.ownedURL)
        do {
            // Keep pending edits if deletion fails and needs a rollback.
            try context.save()
        } catch {
            deletionFailure = "Couldn't delete the meeting. \(error.localizedDescription)"
            NSLog("Parrot: deletion save failed, \(error.localizedDescription)")
            return false
        }
        // Retention deletes without the UI asking: let it drop the selection
        // first, or the detail view would read a deleted model and crash.
        NotificationCenter.default.post(name: .parrotMeetingWillDelete, object: id)
        stopRewrite(meeting)
        if currentMeeting?.id == id { currentMeeting = nil }
        if justFinished?.id == id { justFinished = nil }
        context.delete(meeting)
        do {
            try context.save()
        } catch {
            context.rollback()
            context.processPendingChanges()
            deletionFailure = "Couldn't delete the meeting. \(error.localizedDescription)"
            NSLog("Parrot: deletion failed, \(error.localizedDescription)")
            return false
        }
        memory.remove(meetingID: id)
        for url in Set(audioPaths.map { URL(fileURLWithPath: $0) } + videoURLs) {
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
            catch {
                deletionFailure = "The meeting was deleted, but a recording file couldn't be removed. \(error.localizedDescription)"
                NSLog("Parrot: recording cleanup failed, \(error.localizedDescription)")
            }
        }
        return true
    }

    // MARK: - Segment Storage

    /// Due once `after` has passed since the last line AND since the last
    /// reminder: every 15 minutes of continued silence, never in a live call.
    nonisolated static func idleReminderDue(now: Date, lastVoice: Date, lastReminder: Date?,
                                            after: TimeInterval) -> Bool {
        now.timeIntervalSince(max(lastVoice, lastReminder ?? .distantPast)) >= after
    }

    nonisolated static func idleReminderBody(silentFor seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return "Nobody has spoken for \(minutes <= 1 ? "a minute" : "\(minutes) minutes"). \(MeetingActions.appName) is still recording."
    }

    /// A notification (it replaces the previous one, so they never pile up)
    /// plus one dock bounce. macOS asks for notification permission the first
    /// time this fires, not before; declining leaves just the bounce.
    private static func postIdleReminder(silentFor seconds: TimeInterval) {
        NSLog("Parrot: idle reminder, no speech for \(Int(seconds)) s")
        NSApp.requestUserAttention(.informationalRequest)
        let content = UNMutableNotificationContent()
        content.title = "Still recording?"
        content.body = idleReminderBody(silentFor: seconds)
        content.sound = .default
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    NSLog("Parrot: idle reminder shown as dock bounce only, notifications are off")
                    return
                }
                try await center.add(UNNotificationRequest(identifier: idleReminderID, content: content, trigger: nil))
            } catch {
                NSLog("Parrot: idle reminder notification failed, \(error.localizedDescription)")
            }
        }
    }

    /// A rewind: one side's lines in `range` came from the wrong model.
    private func replaceSegments(source: AudioSource, in range: ClosedRange<TimeInterval>,
                                 with results: [TranscriptionEngine.TranscriptionResult]) {
        guard let modelContext, let meeting = currentMeeting else { return }
        let ids = Set(meeting.segmentIDs(label: source.label, in: range))
        for segment in meeting.segments where ids.contains(segment.id) { modelContext.delete(segment) }
        results.forEach(addSegment)
        try? modelContext.save()
    }

    private func addSegment(_ result: TranscriptionEngine.TranscriptionResult) {
        // Use the live meeting object directly. The previous code looked the
        // meeting up via model(for: meetingID) where meetingID was captured before
        // the context was saved — i.e. a TEMPORARY identifier that goes stale after
        // save. Resolving that stale id returned a malformed object and assigning it
        // to segment.meeting tripped a SwiftData assertion (crash). currentMeeting
        // is the same registered instance in the same context, set before any
        // segment can arrive.
        guard let modelContext, let meeting = currentMeeting else { return }

        // Speaker bleed: without headphones the mic hears the speakers, the
        // AEC attenuates but can't always erase it, and the residual decodes —
        // the same sentence then lands twice, "Them" from system audio and
        // "Me" from the mic (and inflates diarization/talk-ratio). The system
        // copy is authoritative for anything both streams heard, so a Me
        // segment that near-duplicates an other-side segment close by is echo,
        // whichever order they decoded in. (Surfaced by the speakers-playback
        // live test 2026-08-01; previously masked by the glossary decode bug.)
        let incoming: BleedLine = (result.startTime, result.endTime, result.text)
        let hearsSpeakers = transcriptionEngine.micHearsSpeakers
        if result.source == .me,
           meeting.segments.contains(where: {
               Self.canOverlapForEcho(startA: result.startTime, endA: result.endTime,
                                      startB: $0.startTime, endB: $0.endTime)
                   && Self.isBleed(me: incoming, other: ($0.startTime, $0.endTime, $0.text), otherLabel: $0.speakerLabel,
                                   micHearsSpeakers: hearsSpeakers) }) {
            return
        }
        // Echo and my own words in one line: cut the echo (see strippingEcho).
        var text = result.text
        if result.source == .me, hearsSpeakers {
            let nearbyOthers: [(line: BleedLine, label: String?)] = meeting.segments.compactMap { seg in
                guard seg.speakerLabel != AudioSource.me.label,
                      Self.canOverlapForEcho(startA: result.startTime, endA: result.endTime,
                                             startB: seg.startTime, endB: seg.endTime) else { return nil }
                return ((seg.startTime, seg.endTime, seg.text), seg.speakerLabel)
            }
            if !nearbyOthers.isEmpty,
               let kept = Self.strippingEcho(me: incoming, others: nearbyOthers) {
                guard !kept.isEmpty else { return }
                text = kept
            }
        }
        if result.source == .them {
            for stored in meeting.segments where stored.speakerLabel == AudioSource.me.label
                && Self.canOverlapForEcho(startA: stored.startTime, endA: stored.endTime,
                                          startB: result.startTime, endB: result.endTime) {
                let me: BleedLine = (stored.startTime, stored.endTime, stored.text)
                if Self.isBleed(me: me, other: incoming, otherLabel: result.source.label,
                                micHearsSpeakers: hearsSpeakers) {
                    modelContext.delete(stored)
                } else if hearsSpeakers, let kept = Self.strippingEcho(me: me, others: [(incoming, result.source.label)]) {
                    if kept.isEmpty { modelContext.delete(stored) } else { stored.text = kept }
                }
            }
        }

        let segment = TranscriptSegment(
            startTime: result.startTime,
            endTime: result.endTime,
            text: text,
            speakerLabel: result.source.label,
            confidence: result.confidence
        )

        modelContext.insert(segment)
        segment.meeting = meeting
        try? modelContext.save()
    }

    typealias BleedLine = (start: TimeInterval, end: TimeInterval, text: String)

    /// Fast O(1) timestamp pre-filter covering both `isBleed` (starts within 2.5 s
    /// or sits inside ±0.5 s) and `strippingEcho` (overlaps within ±0.5 s), so
    /// `addSegment` skips historical segments before faulting/tokenizing their text.
    private nonisolated static func canOverlapForEcho(startA: TimeInterval, endA: TimeInterval,
                                                      startB: TimeInterval, endB: TimeInterval) -> Bool {
        abs(startA - startB) <= 3.0 || (startB <= endA + 1.0 && endB >= startA - 1.0)
    }

    /// A Me line that near-duplicates an other-side line close by is bleed.
    /// The other side is anything but Me: from 45 s in, live sweeps relabel
    /// "Them" to "Speaker N", so matching on "Them" let late echoes through.
    /// Close by: both start within 2.5 s, or the mic decoded only a piece of a
    /// longer line, so the Me line sits inside it. That needs 3+ words: short
    /// replies ("Okay", "Tabii") are what people say while the other side
    /// talks. A plain overlap test, without these limits, dropped real Me
    /// lines on the owner's store (a long Me line around a short "Okay. So").
    /// A 1-2 word line also needs `micHearsSpeakers` (this call's echo gate
    /// has skipped a Me clip): on headphones my "Okay." opens their "Okay,
    /// so..." all the time, and text alone can't tell it from echo. Replayed
    /// over the owner's store, that kept 74 real replies on headphone calls
    /// and still caught 44 of 47 echoes on speaker calls.
    /// ponytail: a short echo before the gate's first skip (10 s+ in) stays.
    nonisolated static func isBleed(me: BleedLine, other: BleedLine, otherLabel: String?, micHearsSpeakers: Bool) -> Bool {
        guard otherLabel != AudioSource.me.label else { return false }
        let startsTogether = abs(me.start - other.start) <= 2.5
        let inside = me.start >= other.start - 0.5 && me.end <= other.end + 0.5
        guard startsTogether || inside, isEchoDuplicate(other.text, me.text) else { return false }
        return echoTokens(me.text).count >= 3 || (startsTogether && micHearsSpeakers)
    }

    /// Near-verbatim match for the echo-dedup above: Whisper decodes the bleed
    /// with small variances ("I am" vs "I'm"), so exact equality is too strict.
    /// High token overlap + the tight time window keeps a human genuinely
    /// echoing the other side (rare inside 2.5s) from being eaten.
    /// Scored against the Me line's own words: echo must explain most of mine.
    /// Scoring against the shorter line let their "Evet." delete a whole Me
    /// line that contained "evet" (44 real lines on headphone calls in the
    /// owner's store). A Me line that's a piece of their longer line still drops.
    /// ponytail: a Me echo that spans two of their lines (the system side split
    /// the sentence) passes here; the echo gate drops those first (11 of 12
    /// on the owner's speaker calls).
    nonisolated static func isEchoDuplicate(_ other: String, _ me: String) -> Bool {
        let theirs = echoTokens(other), mine = echoTokens(me)
        guard !theirs.isEmpty, !mine.isEmpty else { return false }
        let exact = mine.intersection(theirs).count
        // Misheard words only help a long line that's already mostly the same
        // words. Short replies reuse the other side's words with a new ending
        // ("görüyor musun?" "Görüyorum."), and counting those deleted real
        // answers when replayed over the owner's store.
        let misheard = mine.count >= 4 && Double(exact) / Double(mine.count) >= 0.6
            ? mine.subtracting(theirs).filter { word in theirs.contains { isEchoWord(word, $0) } }.count
            : 0
        return Double(exact + misheard) / Double(mine.count) >= 0.8
    }

    /// Whether two words are the same word heard twice. The echo canceller
    /// leaves a muffled copy, so the decoder mishears letters, not meaning:
    /// "wörtlich" comes back as "wirklich", "ausdrucken" as "ausgucken".
    nonisolated static func isEchoWord(_ a: String, _ b: String) -> Bool {
        // Short words differ in meaning, not hearing: das/was, ist/isst, kann/dann.
        guard a.count >= 5, b.count >= 5 else { return false }
        // Letters added + removed (a swap counts 2), against both lengths:
        // wörtlich/wirklich 4 of 16, ausdrucken/ausgucken 3 of 19.
        return Double(Array(a).difference(from: Array(b)).count) <= Double(a.count + b.count) / 4
    }

    private nonisolated static func echoTokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 })
    }

    /// Words in a row a Me line must share with theirs to count as echo.
    nonisolated static let echoRunWords = 4

    /// One Me line can hold my words and an echo of theirs: I talk over the
    /// end of their sentence and the mic clip decodes as one line, which
    /// isBleed keeps whole. So cut the echoed part: 4+ words in a row that an
    /// overlapping other-side line also says, at about the same moment
    /// (placed by word position, 2 s apart at most). Returns the rest, ""
    /// when the whole line was echo, nil when nothing matched.
    /// Only on calls where the echo gate has fired: text alone can't tell an
    /// echo from two people saying the same thing. Ungated, replayed over the
    /// owner's store, it cut 7 real replies on headphone calls ("Thank you so
    /// much" from both at the end, a number repeated back); gated, 0 there and
    /// 15 echoes on speaker calls.
    /// ponytail: exact words only, so a misheard echo word ends the run and
    /// stays ("FBA rule" for "ACMI renewal"), as does a lone word between two
    /// cut runs.
    nonisolated static func strippingEcho(me: BleedLine, others: [(line: BleedLine, label: String?)]) -> String? {
        let words = me.text.split(whereSeparator: \.isWhitespace)
        let keys = words.map(echoKey)
        let real = keys.indices.filter { !keys[$0].isEmpty }  // skips "—" and the like
        let mine = real.map { keys[$0] }
        func at(_ line: BleedLine, word k: Int, of count: Int) -> TimeInterval {
            line.start + (Double(k) + 0.5) / Double(count) * (line.end - line.start)
        }
        var cut = Set<Int>()
        for (other, label) in others where label != AudioSource.me.label
            && other.start < me.end + 0.5 && other.end > me.start - 0.5 {
            let theirs = other.text.split(whereSeparator: \.isWhitespace).map(echoKey).filter { !$0.isEmpty }
            // run[i + 1][j + 1]: words in a row that end at my i-th and their j-th.
            var run = Array(repeating: Array(repeating: 0, count: theirs.count + 2), count: mine.count + 2)
            for i in mine.indices {
                for j in theirs.indices where mine[i] == theirs[j] { run[i + 1][j + 1] = run[i][j] + 1 }
            }
            for i in mine.indices {
                for j in theirs.indices {
                    let n = run[i + 1][j + 1]
                    // Judge each run once, where it ends.
                    guard n >= echoRunWords, run[i + 2][j + 2] == 0 else { continue }
                    let (a, b) = (i + 1 - n, j + 1 - n)
                    guard abs(at(me, word: a, of: mine.count) - at(other, word: b, of: theirs.count)) <= 2 else { continue }
                    cut.formUnion(real[a...i])
                }
            }
        }
        guard !cut.isEmpty else { return nil }
        let left = words.indices.filter { !cut.contains($0) }
        guard left.contains(where: { !keys[$0].isEmpty }) else { return "" }
        return left.map { String(words[$0]) }.joined(separator: " ")
    }

    /// The live dedupe over a whole transcript at once, for the post-call
    /// polish: drop Me lines that are bleed, cut echoed runs from the rest.
    /// Only called once the call's echo gate has fired, so short lines count.
    nonisolated static func dedupedEcho(_ lines: [TranscriptPolisher.PolishedSegment]) -> [TranscriptPolisher.PolishedSegment] {
        let others = lines.filter { $0.speaker != AudioSource.me.label }
            .map { (line: BleedLine(($0.start, $0.end, $0.text)), label: Optional($0.speaker)) }
        return lines.compactMap { s in
            guard s.speaker == AudioSource.me.label else { return s }
            let me: BleedLine = (s.start, s.end, s.text)
            if others.contains(where: { isBleed(me: me, other: $0.line, otherLabel: $0.label, micHearsSpeakers: true) }) {
                return nil
            }
            guard let kept = strippingEcho(me: me, others: others) else { return s }
            return kept.isEmpty ? nil : .init(text: kept, start: s.start, end: s.end, speaker: s.speaker)
        }
    }

    private nonisolated static func echoKey(_ word: Substring) -> String {
        String(String.UnicodeScalarView(word.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
    }

    // MARK: - Post-Call Summary

    /// The Report tab's Write report (#107): the report for a saved meeting
    /// that has none, because the Assistant was off or its AI failed then.
    /// Explicit, so it runs even with the Assistant off; private meetings stay
    /// on this Mac, as the follow-up email does.
    func writeReport(_ meeting: Meeting) async throws {
        guard !meeting.segments.isEmpty else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "This meeting has no transcript."])
        }
        guard callAnalysisEngine.provider.isConfigured else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Set up the Assistant's AI in Settings first."])
        }
        let id = meeting.id
        meetingWork.add(id)
        defer { meetingWork.remove(id) }
        // Restart now waits for it, like the report after a call.
        chainsInFlight += 1
        defer {
            chainsInFlight -= 1
            AppUpdater.shared.becameIdle()
        }
        let error = await CloudGate.$scopeLocal.withValue(!CloudGate.mayLeaveMac(meeting) || CloudGate.forcesLocal) {
            await generateSummary(meeting: meeting, includeCoaching: meeting.importedAt == nil)
        }
        if meeting.summary == nil, meeting.coaching == nil, let error { throw error }
    }

    /// `includeCoaching` is false for imported files: a single mixed track has no
    /// "Me" channel, so talk-ratio/coaching would be measured against 0% and read
    /// as broken. The summary itself works fine from any transcript.
    /// Best-effort; returns the first failure for Write report to show.
    @discardableResult
    private func generateSummary(meeting: Meeting, includeCoaching: Bool = true) async -> Error? {
        let segments = meeting.sortedSegments
        guard !segments.isEmpty else { return nil }
        var firstError: Error?

        let transcript = meeting.promptTranscript
        let insightTitles = meeting.sortedInsights.map { "\($0.style.label): \($0.title)" }
        let instructions = meeting.profile?.tone ?? (UserDefaults.standard.string(forKey: "copilotInstructions") ?? "")
        let counterpart = meeting.profile?.counterpart ?? "the other person"
        // Snapshot the template, so the report still renders (and its
        // commitments still count) after the profile changes.
        let template = meeting.profile?.reportTemplate ?? .standard
        meeting.reportTemplateData = template.isStandard ? nil : try? JSONEncoder().encode(template)

        do {
            let summary = try await callAnalysisEngine.provider.summarize(
                transcript: transcript,
                insightTitles: insightTitles,
                bookmarks: meeting.bookmarks.map(\.promptLine),
                instructions: instructions,
                counterpart: counterpart,
                template: template
            )
            meeting.summary = summary
            try? modelContext?.save()
        } catch {
            // Best-effort: the transcript and insights are already saved.
            firstError = error
        }

        // A template can turn coaching off: one call fewer, faster and cheaper.
        guard includeCoaching, template.coachingEnabled else { return firstError }

        // Coaching + follow-ups report, with the user's real talk balance
        // (seconds of speech, the same number the live gauge and timeline show).
        let talkPercentMe = meeting.talkPercentMe ?? 0
        do {
            let coaching = try await callAnalysisEngine.provider.coachingReport(
                transcript: transcript,
                talkPercentMe: talkPercentMe,
                instructions: instructions,
                counterpart: counterpart,
                template: template
            )
            meeting.coaching = coaching
            try? modelContext?.save()
        } catch {
            // Best-effort.
            firstError = firstError ?? error
        }
        return firstError
    }

    // MARK: - Title and About

    /// One small request to the reports brain, on whatever privacy path the
    /// caller set up: the call's title and "About this call". The title only
    /// replaces Parrot's "Meeting <date>" one (or a blank one): a title the
    /// user typed or the calendar gave stays. Best-effort; returns what the
    /// AI said (the --about-test harness prints a title it didn't apply).
    @discardableResult
    func writeAbout(_ meeting: Meeting) async -> (title: String, about: String)? {
        aboutTried.insert(meeting.id)
        let names = meeting.otherSpeakerLabels.compactMap { meeting.speakerNames[$0] }
            + meeting.attendees.map(\.displayName)
        let user = CallAbout.userContent(report: meeting.summary, transcript: meeting.promptTranscript,
                                         names: Array(Set(names)).sorted())
        do {
            let answer = try await callAnalysisEngine.provider.complete(
                system: CallAbout.systemPrompt, user: user, maxTokens: 300)
            guard !meeting.isDeleted, meeting.modelContext != nil,
                  let result = CallAbout.parse(answer) else { return nil }
            if !result.about.isEmpty { meeting.about = result.about }
            if !result.title.isEmpty, meeting.hasDefaultTitle { meeting.title = result.title }
            try? modelContext?.save()
            ExportFolder.refreshIfSaved(meeting)
            return result
        } catch {
            NSLog("Parrot: about skipped, \(error.localizedDescription)")
            return nil
        }
    }

    /// A finished meeting with a report but no About (recorded before it
    /// existed, or its first try failed) gets one when opened: once per
    /// launch, same rules as after a call (Assistant on and set up, private
    /// meetings on this Mac), never during a recording.
    // ponytail: these tokens aren't added to the meeting's cost row, same as
    // Write report and Rewrite.
    func writeAboutIfMissing(_ meeting: Meeting) async {
        guard meeting.status == .done, meeting.about.isEmpty, meeting.summary != nil,
              !isRecording, !aboutTried.contains(meeting.id),
              callAnalysisEngine.isEnabled, callAnalysisEngine.provider.isConfigured else { return }
        await CloudGate.$scopeLocal.withValue(!CloudGate.mayLeaveMac(meeting) || CloudGate.forcesLocal) {
            await writeAbout(meeting)
        }
    }

    // MARK: - Post-call polish

    /// Re-transcribe the saved audio through Groq's large model and replace the
    /// live transcript with the cleaner one. Opt-in, best-effort: any failure
    /// leaves the live transcript untouched.
    /// Returns the seconds of audio billed (all tracks summed) for cost tracking,
    /// 0 when polish didn't run.
    /// On speakers the re-decode hears the echo again, so it gets the live
    /// echo handling: the echo gate per Me line (inside `polish`), then the
    /// text dedupe. Only when the mic hears the speakers (`micHeardSpeakers`
    /// is the live call's echo gate): today's isBleed also matches real
    /// lines on headphone calls, and polish has been lossless there.
    /// Under half the live transcript's words: keep the live one.
    nonisolated static func polishLostWords(live: Int, polished: Int) -> Bool {
        polished * 2 < live
    }

    func cancelTranscriptionJob(for meetingID: UUID) {
        transcriptionTasks[meetingID]?.cancel()
        transcriptionTasks.removeValue(forKey: meetingID)
        transcriptionJobs.removeValue(forKey: meetingID)
    }

    func startRetranscribe(_ meeting: Meeting) {
        let id = meeting.id
        transcriptionErrors.removeValue(forKey: id)
        transcriptionTasks[id]?.cancel()
        transcriptionTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.retranscribe(meeting)
            } catch is CancellationError {
                // Cancelled by user
            } catch {
                self.transcriptionErrors[id] = error.localizedDescription
                self.appendTranscriptionLog(
                    TranscriptionLogEntry(
                        kind: .error,
                        modelName: self.transcriptionJobs[id]?.activeModel ?? "Transcription",
                        summary: "Retranscribe error: \(error.localizedDescription)"
                    ),
                    for: id
                )
            }
        }
    }

    /// Explicitly re-transcribe an existing meeting's saved audio files using
    /// the currently selected on-device or cloud transcription model and replace its segments.
    @discardableResult
    func retranscribe(_ meeting: Meeting) async throws -> Int {
        guard let modelContext else { throw CocoaError(.fileNoSuchFile) }
        guard !isRecording && !isStarting && !isStopping else {
            throw NSError(domain: "Parrot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stop the active recording before re-transcribing."])
        }
        guard !meetingWork.contains(meeting.id) else {
            throw NSError(domain: "Parrot", code: 2, userInfo: [NSLocalizedDescriptionKey: "This meeting is already being processed."])
        }
        let systemPath = meeting.systemAudioPath.nilIfEmpty
        let micPath = meeting.micAudioPath?.nilIfEmpty
        guard systemPath != nil || micPath != nil else {
            throw NSError(domain: "Parrot", code: 3, userInfo: [NSLocalizedDescriptionKey: "No saved audio files found for this meeting."])
        }

        meetingWork.add(meeting.id)
        let previousStatus = meeting.status
        meeting.status = .processing
        let startedAt = Date()
        transcriptionErrors.removeValue(forKey: meeting.id)
        completedRetranscribeIDs.remove(meeting.id)
        transcriptionLogs[meeting.id] = []

        let onDevice = meeting.onDeviceOnly
            || CloudGate.forcesLocal
            || UserDefaults.standard.object(forKey: AssistantRoutingSettings.enabledKey) != nil
            || UserDefaults.standard.bool(forKey: TranscriptPolisher.onDeviceKey)
        let groqKey = onDevice ? nil : (TranscriptionBackend.groq.keychainAccount.flatMap { APIKeyStore.load(account: $0) }?.nilIfEmpty)

        let modelName = (groqKey != nil) ? "whisper-large-v3-turbo" : (transcriptionEngine.currentModel ?? UserDefaults.standard.string(forKey: "whisperModel") ?? "base")
        let speechModelDisplay: String
        if groqKey != nil {
            let effectiveLang = TranscriptionLanguage.selected
            speechModelDisplay = TranscriptionJobProgress.displayModelName(modelID: "whisper-large-v3-turbo", backend: .groq, language: effectiveLang)
        } else {
            let effectiveLang = MLXTranscriber.isMLX(modelName)
                ? MLXTranscriber.effectiveLanguage(for: modelName, selected: TranscriptionLanguage.selected)
                : TranscriptionLanguage.selected
            speechModelDisplay = TranscriptionJobProgress.displayModelName(modelID: modelName, backend: .local, language: effectiveLang)
        }
        let hasSystemAudio = meeting.systemAudioPath.nilIfEmpty != nil
        let pipelineModels: [String] = hasSystemAudio ? [speechModelDisplay, Self.diarizerDisplayName] : [speechModelDisplay]

        var succeeded = false
        defer {
            meetingWork.remove(meeting.id)
            transcriptionJobs.removeValue(forKey: meeting.id)
            transcriptionTasks.removeValue(forKey: meeting.id)
            meeting.status = succeeded ? .done : previousStatus
            try? modelContext.save()
            if Task.isCancelled {
                if transcriptionLogs[meeting.id]?.last?.summary != "Cancelled by user" {
                    appendTranscriptionLog(
                        TranscriptionLogEntry(
                            kind: .lifecycle,
                            modelName: speechModelDisplay,
                            summary: "Cancelled by user"
                        ),
                        for: meeting.id
                    )
                }
            } else if succeeded {
                appendTranscriptionLog(
                    TranscriptionLogEntry(
                        kind: .lifecycle,
                        modelName: speechModelDisplay,
                        summary: "Transcription complete"
                    ),
                    for: meeting.id
                )
            }
        }

        // Stage 1: preparingModel (fraction 0.03)
        transcriptionJobs[meeting.id] = TranscriptionJobProgress(
            meetingID: meeting.id,
            fraction: 0.03,
            stage: .preparingModel(speechModelDisplay),
            startedAt: startedAt,
            activeModel: speechModelDisplay,
            pipelineModels: pipelineModels
        )
        appendTranscriptionLog(
            TranscriptionLogEntry(
                kind: .lifecycle,
                modelName: speechModelDisplay,
                summary: "Starting re-transcription with \(speechModelDisplay)"
            ),
            for: meeting.id
        )
        if groqKey == nil {
            if !transcriptionEngine.isReady || transcriptionEngine.currentModel != modelName {
                await transcriptionEngine.loadModel(modelName)
            }
        }
        try Task.checkCancellation()

        let traceCallback: @Sendable (TranscriptionLogEntry) -> Void = { [weak self] entry in
            Task { @MainActor [weak self] in
                self?.appendTranscriptionLog(entry, for: meeting.id)
            }
        }

        // Stage 2: transcribing (fraction 0.05 ... 0.80)
        let timeline: ([Float]) async -> [Float]? = { [transcriptionEngine] in
            await transcriptionEngine.speechTimeline(samples: $0)
        }
        let onProgress: @Sendable (String, Double, Double, Double) -> Void = { [weak self] trackLabel, completedSec, totalSec, overallFraction in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let existingJob = self.transcriptionJobs[meeting.id]
                self.transcriptionJobs[meeting.id] = TranscriptionJobProgress(
                    meetingID: meeting.id,
                    fraction: 0.05 + 0.75 * overallFraction,
                    stage: .transcribing(trackLabel: trackLabel, completedSeconds: completedSec, totalSeconds: totalSec),
                    startedAt: startedAt,
                    activeModel: existingJob?.activeModel ?? speechModelDisplay,
                    pipelineModels: pipelineModels,
                    intervalStart: existingJob?.intervalStart,
                    intervalEnd: existingJob?.intervalEnd
                )
            }
        }

        let polished: (segments: [TranscriptPolisher.PolishedSegment], micHearsSpeakers: Bool)
        if let groqKey {
            let setting = UserDefaults.standard.string(forKey: "transcriptionLanguage")
            let language = (setting == nil || setting == "auto") ? nil : setting
            polished = try await TranscriptPolisher.polish(
                systemPath: systemPath,
                micPath: micPath,
                language: language,
                apiKey: groqKey,
                strictTracks: true,
                timeline: timeline,
                onProgress: onProgress,
                onTrace: traceCallback
            )
        } else {
            polished = try await TranscriptPolisher.polish(
                systemPath: systemPath,
                micPath: micPath,
                strictTracks: true,
                timeline: timeline,
                onProgress: onProgress,
                onTrace: traceCallback,
                transcribeTrack: { [transcriptionEngine] samples, url, trackTimeline, trackLabel, onTrackProgress in
                    let results = try await transcriptionEngine.transcribeFile(
                        url: url,
                        samples: samples,
                        timeline: trackTimeline,
                        trackLabel: trackLabel,
                        onProgress: onTrackProgress,
                        onTrace: traceCallback
                    )
                    return results.map { ($0.text, $0.startTime, $0.endTime) }
                }
            )
        }
        try Task.checkCancellation()

        guard !polished.segments.isEmpty else {
            throw NSError(domain: "Parrot", code: 4, userInfo: [NSLocalizedDescriptionKey: "Transcription returned no speech segments."])
        }

        let rawLines = polished.micHearsSpeakers ? Self.dedupedEcho(polished.segments) : polished.segments
        var finalSegments: [(text: String, start: Double, end: Double, speaker: String)] = rawLines.map {
            ($0.text, $0.start, $0.end, $0.speaker)
        }

        var newEmbeddingsData = meeting.speakerEmbeddingsData

        // Stage 3: diarizing (fraction 0.84)
        transcriptionJobs[meeting.id] = TranscriptionJobProgress(
            meetingID: meeting.id,
            fraction: 0.84,
            stage: .diarizing,
            startedAt: startedAt,
            activeModel: Self.diarizerDisplayName,
            pipelineModels: pipelineModels,
            intervalStart: nil,
            intervalEnd: nil
        )
        if let sysPath = meeting.systemAudioPath.nilIfEmpty, FileManager.default.fileExists(atPath: sysPath) {
            appendTranscriptionLog(
                TranscriptionLogEntry(
                    kind: .diarization,
                    modelName: Self.diarizerDisplayName,
                    summary: "Separating remote speakers with \(Self.diarizerDisplayName)…"
                ),
                for: meeting.id
            )
            let diarStart = DispatchTime.now()
            let audioURL = URL(fileURLWithPath: sysPath)
            if let output = try? await diarizationEngine.diarize(audioURL: audioURL) {
                let diarEnd = DispatchTime.now()
                let diarMs = Int((diarEnd.uptimeNanoseconds - diarStart.uptimeNanoseconds) / 1_000_000)
                let mapping = Self.stableMapping(newEmbeddings: output.embeddings, anchors: [:])
                let turns = output.segments.map {
                    DiarizationEngine.SpeakerSegmentResult(
                        speakerLabel: mapping[$0.speakerLabel] ?? $0.speakerLabel,
                        startTime: $0.startTime, endTime: $0.endTime)
                }
                for i in 0..<finalSegments.count where finalSegments[i].speaker != "Me" {
                    if let label = Self.diarizedLabel(
                        for: (finalSegments[i].start, finalSegments[i].end),
                        turns: turns) {
                        finalSegments[i].speaker = label
                    }
                }
                let embeddings = Dictionary(uniqueKeysWithValues:
                    output.embeddings.map { (mapping[$0.key] ?? $0.key, $0.value) })
                newEmbeddingsData = try JSONEncoder().encode(embeddings)

                var speakerTurnCounts: [String: Int] = [:]
                for turn in turns {
                    speakerTurnCounts[turn.speakerLabel, default: 0] += 1
                }
                let speakerCount = speakerTurnCounts.keys.count
                let jsonSummary: [String: Any] = [
                    "model": Self.diarizerDisplayName,
                    "elapsedMs": diarMs,
                    "speakerCount": speakerCount,
                    "speakers": speakerTurnCounts
                ]
                let structuredJSON: String?
                if let data = try? JSONSerialization.data(withJSONObject: jsonSummary, options: [.prettyPrinted, .sortedKeys]) {
                    structuredJSON = String(data: data, encoding: .utf8)
                } else {
                    structuredJSON = nil
                }
                appendTranscriptionLog(
                    TranscriptionLogEntry(
                        kind: .diarization,
                        modelName: Self.diarizerDisplayName,
                        elapsedMs: diarMs,
                        summary: "Diarization complete: \(speakerCount) speakers identified in \(Double(diarMs) / 1000.0)s",
                        structuredJSON: structuredJSON
                    ),
                    for: meeting.id
                )
            }
        }
        try Task.checkCancellation()

        // Stage 4: indexingAndSaving (fraction 0.94)
        transcriptionJobs[meeting.id] = TranscriptionJobProgress(
            meetingID: meeting.id,
            fraction: 0.94,
            stage: .indexingAndSaving,
            startedAt: startedAt,
            activeModel: speechModelDisplay,
            pipelineModels: pipelineModels,
            intervalStart: nil,
            intervalEnd: nil
        )
        try Task.checkCancellation()

        let savedMeeting = try Self.saveRetranscription(
            meetingID: meeting.id, context: modelContext,
            segments: finalSegments, embeddingsData: newEmbeddingsData
        )
        await memory.index(savedMeeting)
        ExportFolder.refreshIfSaved(savedMeeting)
        completedRetranscribeIDs.insert(meeting.id)
        succeeded = true
        return finalSegments.count
    }

    static func saveRetranscription(
        meetingID: UUID, context: ModelContext,
        segments: [(text: String, start: Double, end: Double, speaker: String)], embeddingsData: Data?
    ) throws -> Meeting {
        try Task.checkCancellation()
        if context.hasChanges { try context.save() }
        guard let meeting = try context.fetch(FetchDescriptor<Meeting>(predicate: #Predicate { $0.id == meetingID })).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let oldSegments = meeting.segments
        do {
            meeting.segments.removeAll()
            for line in segments {
                let segment = TranscriptSegment(startTime: line.start, endTime: line.end, text: line.text, speakerLabel: line.speaker, confidence: nil)
                context.insert(segment)
                segment.meeting = meeting
            }
            let labels = Set(segments.map(\.speaker))
            meeting.speakerNames = meeting.speakerNames.filter { labels.contains($0.key) }
            meeting.speakerEmbeddingsData = embeddingsData
            meeting.mergeSameNamedSpeakers()
            try Task.checkCancellation()
            try context.save()
        } catch {
            context.rollback()
            meeting.segments = oldSegments
            throw error
        }
        for old in oldSegments { context.delete(old) }
        do {
            try context.save()
        } catch {
            context.rollback()
            NSLog("Parrot: old transcript cleanup failed, \(error.localizedDescription)")
        }
        return meeting
    }

    @discardableResult
    private func polishTranscript(meeting: Meeting, micHeardSpeakers: Bool) async -> Double {
        guard UserDefaults.standard.bool(forKey: "polishAfterCall"), let modelContext else { return 0 }
        let onDevice = UserDefaults.standard.object(forKey: AssistantRoutingSettings.enabledKey) != nil
            || UserDefaults.standard.bool(forKey: TranscriptPolisher.onDeviceKey)
        let groqKey = onDevice ? nil : (TranscriptionBackend.groq.keychainAccount.flatMap { APIKeyStore.load(account: $0) }?.nilIfEmpty)

        let modelName = (groqKey != nil) ? "whisper-large-v3-turbo" : (transcriptionEngine.currentModel ?? UserDefaults.standard.string(forKey: "whisperModel") ?? "base")
        let speechModelDisplay: String
        if groqKey != nil {
            let effectiveLang = TranscriptionLanguage.selected
            speechModelDisplay = TranscriptionJobProgress.displayModelName(modelID: "whisper-large-v3-turbo", backend: .groq, language: effectiveLang)
        } else {
            let effectiveLang = MLXTranscriber.isMLX(modelName)
                ? MLXTranscriber.effectiveLanguage(for: modelName, selected: TranscriptionLanguage.selected)
                : TranscriptionLanguage.selected
            speechModelDisplay = TranscriptionJobProgress.displayModelName(modelID: modelName, backend: .local, language: effectiveLang)
        }
        let hasSystemAudio = meeting.systemAudioPath.nilIfEmpty != nil
        let pipelineModels: [String] = hasSystemAudio ? [speechModelDisplay, Self.diarizerDisplayName] : [speechModelDisplay]

        let timeline: ([Float]) async -> [Float]? = { [transcriptionEngine] in
            await transcriptionEngine.speechTimeline(samples: $0)
        }

        transcriptionLogs[meeting.id] = []
        let startedAt = Date()
        var succeeded = false
        defer {
            transcriptionJobs.removeValue(forKey: meeting.id)
            if Task.isCancelled {
                if transcriptionLogs[meeting.id]?.last?.summary != "Cancelled by user" {
                    appendTranscriptionLog(
                        TranscriptionLogEntry(
                            kind: .lifecycle,
                            modelName: speechModelDisplay,
                            summary: "Cancelled by user"
                        ),
                        for: meeting.id
                    )
                }
            } else if succeeded {
                appendTranscriptionLog(
                    TranscriptionLogEntry(
                        kind: .lifecycle,
                        modelName: speechModelDisplay,
                        summary: "Transcription complete"
                    ),
                    for: meeting.id
                )
            }
        }

        let traceCallback: @Sendable (TranscriptionLogEntry) -> Void = { [weak self] entry in
            Task { @MainActor [weak self] in
                self?.appendTranscriptionLog(entry, for: meeting.id)
            }
        }

        let onProgress: @Sendable (String, Double, Double, Double) -> Void = { [weak self] trackLabel, completedSec, totalSec, overallFraction in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let existingJob = self.transcriptionJobs[meeting.id]
                self.transcriptionJobs[meeting.id] = TranscriptionJobProgress(
                    meetingID: meeting.id,
                    fraction: 0.05 + 0.75 * overallFraction,
                    stage: .transcribing(trackLabel: trackLabel, completedSeconds: completedSec, totalSeconds: totalSec),
                    startedAt: startedAt,
                    activeModel: existingJob?.activeModel ?? speechModelDisplay,
                    pipelineModels: pipelineModels,
                    intervalStart: existingJob?.intervalStart,
                    intervalEnd: existingJob?.intervalEnd
                )
            }
        }

        do {
            let polished: (segments: [TranscriptPolisher.PolishedSegment], micHearsSpeakers: Bool)
            if onDevice {
                transcriptionJobs[meeting.id] = TranscriptionJobProgress(
                    meetingID: meeting.id,
                    fraction: 0.03,
                    stage: .preparingModel(speechModelDisplay),
                    startedAt: startedAt,
                    activeModel: speechModelDisplay,
                    pipelineModels: pipelineModels
                )
                appendTranscriptionLog(
                    TranscriptionLogEntry(
                        kind: .lifecycle,
                        modelName: speechModelDisplay,
                        summary: "Starting transcript polish with \(speechModelDisplay)"
                    ),
                    for: meeting.id
                )
                // The import path: whole track, Whisper's own timestamps, nothing leaves the Mac.
                polished = try await TranscriptPolisher.polish(
                    systemPath: meeting.systemAudioPath.nilIfEmpty,
                    micPath: meeting.micAudioPath?.nilIfEmpty,
                    timeline: timeline,
                    onProgress: onProgress,
                    onTrace: traceCallback,
                    transcribeTrack: { [transcriptionEngine] samples, url, trackTimeline, trackLabel, onTrackProgress in
                        let results = try await transcriptionEngine.transcribeFile(
                            url: url,
                            samples: samples,
                            timeline: trackTimeline,
                            trackLabel: trackLabel,
                            onProgress: onTrackProgress,
                            onTrace: traceCallback
                        )
                        return results.map { ($0.text, $0.startTime, $0.endTime) }
                    }
                )
            } else {
                guard !meeting.onDeviceOnly, !CloudGate.forcesLocal,
                      let key = APIKeyStore.load(account: TranscriptionBackend.groq.keychainAccount!),
                      !key.isEmpty else { return 0 }
                transcriptionJobs[meeting.id] = TranscriptionJobProgress(
                    meetingID: meeting.id,
                    fraction: 0.03,
                    stage: .preparingModel(speechModelDisplay),
                    startedAt: startedAt,
                    activeModel: speechModelDisplay,
                    pipelineModels: pipelineModels
                )
                appendTranscriptionLog(
                    TranscriptionLogEntry(
                        kind: .lifecycle,
                        modelName: speechModelDisplay,
                        summary: "Starting transcript polish with \(speechModelDisplay)"
                    ),
                    for: meeting.id
                )
                let setting = UserDefaults.standard.string(forKey: "transcriptionLanguage")
                polished = try await TranscriptPolisher.polish(
                    systemPath: meeting.systemAudioPath.nilIfEmpty,
                    micPath: meeting.micAudioPath?.nilIfEmpty,
                    language: (setting == nil || setting == "auto") ? nil : setting,
                    apiKey: key,
                    timeline: timeline,
                    onProgress: onProgress,
                    onTrace: traceCallback
                )
            }
            guard !polished.segments.isEmpty else { return 0 }
            // A pass that lost most of the words (a tiny model, the wrong
            // language) must not replace a good live transcript.
            let words = { (texts: [String]) in texts.reduce(0) { $0 + $1.split(separator: " ").count } }
            let liveWords = words(meeting.segments.map(\.text))
            guard !Self.polishLostWords(live: liveWords, polished: words(polished.segments.map(\.text))) else {
                NSLog("Parrot: polish kept the live transcript, the new pass lost most of the words")
                return 0
            }
            let lines = micHeardSpeakers || polished.micHearsSpeakers
                ? Self.dedupedEcho(polished.segments) : polished.segments

            for old in meeting.segments {
                modelContext.delete(old)
            }
            for s in lines {
                let segment = TranscriptSegment(
                    startTime: s.start, endTime: s.end,
                    text: s.text, speakerLabel: s.speaker, confidence: nil)
                modelContext.insert(segment)
                segment.meeting = meeting
            }
            try? modelContext.save()
            NSLog("Parrot: transcript polished — \(lines.count) segments, \(polished.segments.count - lines.count) echo lines dropped by text")
            succeeded = true
            // Billed audio ≈ call duration per re-transcribed track; on this Mac it's free.
            guard !onDevice else { return 0 }
            let tracks = [meeting.systemAudioPath.nilIfEmpty, meeting.micAudioPath?.nilIfEmpty]
                .compactMap { $0 }.count
            return meeting.duration * Double(tracks)
        } catch {
            appendTranscriptionLog(
                TranscriptionLogEntry(
                    kind: .error,
                    modelName: speechModelDisplay,
                    summary: "Polish failed: \(error.localizedDescription)"
                ),
                for: meeting.id
            )
            NSLog("Parrot: polish failed, keeping live transcript — \(error.localizedDescription)")
            return 0
        }
    }

    // MARK: - AI usage snapshot

    /// Freezes this call's AI usage (copilot tokens + transcription/polish audio
    /// seconds) onto the meeting so the detail view can show what it cost.
    private func writeAIUsage(meeting: Meeting, polishSeconds: Double,
                              backendOverride: TranscriptionBackend? = nil) {
        var usage = AIUsage()
        // ponytail: reads the copilot provider/model at stop time, same accepted
        // mid-call-switch edge as the transcription backend below.
        if let switching = callAnalysisEngine.provider as? SwitchingAnalysisProvider {
            let live = switching.liveUsage
            usage.copilotModel = live.model
            usage.copilotProvider = live.provider
            usage.copilot = live.totals
            // Second bucket only when reports ran on a different backend.
            if let reports = switching.reportsUsage {
                usage.reportsModel = reports.model
                usage.reportsProvider = reports.provider
                usage.reports = reports.totals
            }
        } else {
            usage.copilotModel = CopilotProviderKind.activeModelName
            usage.copilotProvider = CopilotProviderKind.selected.rawValue
            usage.copilot = callAnalysisEngine.provider.usageTotals
        }
        let docTotals = docMatcher.usageTotals
        if docTotals.calls > 0 {
            usage.docAnswerModel = JevDocMatcher.model
            usage.docAnswers = docTotals
        }
        // ponytail: reads the backend setting at stop time; a mid-call engine
        // switch or cloud→local fallback mislabels one estimated row. Import
        // passes an override since it's always on-device regardless of the setting.
        let usedBackend = backendOverride ?? transcriptionEngine.sessionBackend
        usage.transcriptionBackend = usedBackend.rawValue
        usage.transcriptionModel = usedBackend == .local ? transcriptionEngine.sessionModel : transcriptionEngine.usageTranscriptionModel
        usage.transcriptionSeconds = meeting.duration
        usage.transcriptionTracks = meeting.micAudioPath?.nilIfEmpty != nil ? 2 : 1
        // Same stop-time read as the backend above: auto-detect = Deepgram "multi".
        let language = UserDefaults.standard.string(forKey: "transcriptionLanguage")
        usage.transcriptionMultilingual = language == nil || language == "auto"
        usage.polishSeconds = polishSeconds
        meeting.aiUsageData = try? JSONEncoder().encode(usage)
        try? modelContext?.save()
    }

    // MARK: - Post-Processing

    /// One live pass: re-diarize the call so far and relabel in place.
    /// Failures just wait for the next cycle (the .caf is mid-write).
    private func runLiveSweep() async {
        guard isRecording, elapsedTime >= 45, !diarizationEngine.isProcessing,
              let meeting = currentMeeting,
              let path = meeting.systemAudioPath.nilIfEmpty else { return }
        let themSegmentCount = meeting.segments.reduce(into: 0) { count, seg in
            if seg.speakerLabel != "Me" { count += 1 }
        }
        guard themSegmentCount > 0, themSegmentCount != lastSweptThemSegmentCount else { return }
        do {
            let url = URL(fileURLWithPath: path)
            // The first sweep reads the whole (still short) call to learn the
            // voices; after that only the last minute, matched against them.
            // A call that stays silent past two minutes goes to windows anyway.
            let windowed = !liveAnchors.isEmpty || elapsedTime > 120
            let output = windowed
                ? try await diarizationEngine.diarize(audioURL: url, lastSeconds: Self.liveWindow)
                : try await diarizationEngine.diarize(audioURL: url)
            // Stopped (or a new call started) while this ran: its labels and
            // identities belong to a meeting whose final pass now owns them.
            guard isRecording, currentMeeting === meeting else { return }
            let mapping: [String: String]
            if windowed {
                var speech: [String: TimeInterval] = [:]
                for turn in output.segments { speech[turn.speakerLabel, default: 0] += turn.endTime - turn.startTime }
                mapping = Self.windowMapping(newEmbeddings: output.embeddings, speech: speech, anchors: liveAnchors)
            } else {
                mapping = Self.stableMapping(newEmbeddings: output.embeddings, anchors: liveAnchors)
            }
            // Turns of clusters left out of the mapping don't label anything.
            let turns = output.segments.compactMap { turn in
                mapping[turn.speakerLabel].map {
                    DiarizationEngine.SpeakerSegmentResult(speakerLabel: $0, startTime: turn.startTime, endTime: turn.endTime)
                }
            }
            for segment in meeting.segments where segment.speakerLabel != "Me" {
                // A window only speaks for the lines inside it, and only where
                // a mapped turn actually overlaps the line.
                if windowed {
                    guard segment.startTime >= output.start,
                          turns.contains(where: { $0.startTime < segment.endTime && $0.endTime > segment.startTime })
                    else { continue }
                }
                if let label = Self.diarizedLabel(for: (segment.startTime, segment.endTime), turns: turns) {
                    segment.speakerLabel = label
                }
            }
            // Known voices keep their reference; a window only adds new ones.
            for (cluster, embedding) in output.embeddings {
                guard let label = mapping[cluster], !windowed || liveAnchors[label] == nil else { continue }
                liveAnchors[label] = embedding
            }

            // Name matching in live: consult remembered voices (opt-in) so the
            // bubbles can show "Gürkan?" instead of Speaker 2. Suggestion only.
            if UserDefaults.standard.bool(forKey: "rememberVoices"), let context = modelContext {
                var suggestions: [String: String] = [:]
                for (label, embedding) in liveAnchors {
                    if let match = SpeakerProfileStore.match(embedding, in: context,
                                                               invited: meeting.attendees.map(\.displayName)) {
                        suggestions[label] = match.name
                    }
                }
                liveSpeakerSuggestions = suggestions
            }
            lastSweptThemSegmentCount = themSegmentCount
            try? modelContext?.save()
        } catch {
            NSLog("Parrot: live speaker sweep skipped — \(error.localizedDescription)")
        }
    }

    /// Re-runs diarization on a finished meeting (audio is retained). Safe to
    /// call repeatedly; refuses the meeting currently being recorded. Throws
    /// when detection didn't run, so the labels are unchanged.
    func redetectSpeakers(meeting: Meeting) async throws {
        let id = meeting.id
        meetingWork.add(id)
        defer { meetingWork.remove(id) }
        guard !(isRecording && meeting.id == currentMeeting?.id), await postProcess(meeting: meeting)
        else { throw RecordingError.speakersNotDetected }
    }

    /// `anchors`: the live sweeps' identities for this meeting (empty for
    /// imports, recovery and re-detection), so the final labels keep the
    /// ones the user watched during the call.
    @discardableResult
    private func postProcess(meeting: Meeting, anchors: [String: [Float]] = [:]) async -> Bool {
        // Status stays .processing here — the calling chain flips .done after
        // the post-call REPORT finishes, so the UI can say "writing report…"
        // instead of the misleading "no report was generated".
        guard let audioPath = meeting.systemAudioPath.nilIfEmpty,
              FileManager.default.fileExists(atPath: audioPath) else { return false }

        appendTranscriptionLog(
            TranscriptionLogEntry(
                kind: .diarization,
                modelName: Self.diarizerDisplayName,
                summary: "Separating remote speakers with \(Self.diarizerDisplayName)…"
            ),
            for: meeting.id
        )
        let diarStart = DispatchTime.now()

        do {
            let audioURL = URL(fileURLWithPath: audioPath)
            let output = try await diarizationEngine.diarize(audioURL: audioURL)
            let diarEnd = DispatchTime.now()
            let diarMs = Int((diarEnd.uptimeNanoseconds - diarStart.uptimeNanoseconds) / 1_000_000)

            // Continuity with any live sweeps: keep the identities the user
            // watched during the call. Empty anchors → identity mapping, so
            // non-live meetings and redetect are untouched.
            let mapping = Self.stableMapping(newEmbeddings: output.embeddings, anchors: anchors)
            let turns = output.segments.map {
                DiarizationEngine.SpeakerSegmentResult(
                    speakerLabel: mapping[$0.speakerLabel] ?? $0.speakerLabel,
                    startTime: $0.startTime, endTime: $0.endTime)
            }
            let embeddings = Dictionary(uniqueKeysWithValues:
                output.embeddings.map { (mapping[$0.key] ?? $0.key, $0.value) })

            // Assign speaker labels to transcript segments by time overlap.
            // "Me" segments come from the mic stream and are already attributed;
            // diarization only refines who's who within the system audio ("Them").
            for transcriptSegment in meeting.segments where transcriptSegment.speakerLabel != "Me" {
                if let label = Self.diarizedLabel(
                    for: (transcriptSegment.startTime, transcriptSegment.endTime),
                    turns: turns) {
                    transcriptSegment.speakerLabel = label
                }
            }
            meeting.speakerEmbeddingsData = try? JSONEncoder().encode(embeddings)
            meeting.pruneSpeakerNames()
            // Names given during the call: one name, one person.
            meeting.mergeSameNamedSpeakers()
            try? modelContext?.save()

            var speakerTurnCounts: [String: Int] = [:]
            for turn in turns {
                speakerTurnCounts[turn.speakerLabel, default: 0] += 1
            }
            let speakerCount = speakerTurnCounts.keys.count
            let jsonSummary: [String: Any] = [
                "model": Self.diarizerDisplayName,
                "elapsedMs": diarMs,
                "speakerCount": speakerCount,
                "speakers": speakerTurnCounts
            ]
            let structuredJSON: String?
            if let data = try? JSONSerialization.data(withJSONObject: jsonSummary, options: [.prettyPrinted, .sortedKeys]) {
                structuredJSON = String(data: data, encoding: .utf8)
            } else {
                structuredJSON = nil
            }
            appendTranscriptionLog(
                TranscriptionLogEntry(
                    kind: .diarization,
                    modelName: Self.diarizerDisplayName,
                    elapsedMs: diarMs,
                    summary: "Diarization complete: \(speakerCount) speakers identified in \(Double(diarMs) / 1000.0)s",
                    structuredJSON: structuredJSON
                ),
                for: meeting.id
            )

            return true
        } catch {
            let diarEnd = DispatchTime.now()
            let diarMs = Int((diarEnd.uptimeNanoseconds - diarStart.uptimeNanoseconds) / 1_000_000)
            appendTranscriptionLog(
                TranscriptionLogEntry(
                    kind: .error,
                    modelName: Self.diarizerDisplayName,
                    elapsedMs: diarMs,
                    summary: "Diarization failed: \(error.localizedDescription)"
                ),
                for: meeting.id
            )
            // Diarization is a refinement pass; the audio and transcript are
            // already saved. Keep the generic "Them" labels rather than showing
            // a perfectly good meeting as failed.
            NSLog("Parrot: diarization failed — \(error.localizedDescription)")
            try? modelContext?.save()
            return false
        }
    }

    /// What the live sweeps may spend right now.
    struct PowerState: Equatable {
        var onBattery = false
        var lowPower = false
        var hot = false

        static var now: PowerState {
            let info = ProcessInfo.processInfo
            let source = IOPSGetProvidingPowerSourceType(IOPSCopyPowerSourcesInfo()?.takeRetainedValue())?
                .takeUnretainedValue() as String?
            return PowerState(onBattery: source == kIOPSBatteryPowerValue,
                              lowPower: info.isLowPowerModeEnabled,
                              hot: info.thermalState == .serious || info.thermalState == .critical)
        }
    }

    /// Seconds until the next live sweep, or nil to skip it. After the first
    /// one, sweeps read only the last `liveWindow` seconds, so their cost is
    /// flat (the whole-call version cost ~5 s CPU at 65 min, 2026-09-25) and
    /// they can run often: a new line gets its speaker in ~15 s. Battery
    /// doubles the wait; Low Power Mode or a hot Mac skips.
    nonisolated static func liveSweepDelay(power: PowerState) -> TimeInterval? {
        guard !power.lowPower, !power.hot else { return nil }
        return power.onBattery ? 30 : 15
    }

    /// How much audio a live window sweep reads.
    static let liveWindow: TimeInterval = 60

    /// Window sweeps: a minute of audio can split one voice into two clusters,
    /// so several clusters may map to the SAME known voice (unlike
    /// `stableMapping`, which is one-to-one). A cluster that matches no known
    /// voice becomes a new speaker only with `minFreshSpeech` seconds of
    /// speech; otherwise it's left out and its lines keep their label.
    // ponytail: one new person split into two big clusters gets two fresh
    // labels until the post-call pass merges them.
    nonisolated static func windowMapping(
        newEmbeddings: [String: [Float]],
        speech: [String: TimeInterval],
        anchors: [String: [Float]],
        minFreshSpeech: TimeInterval = 4
    ) -> [String: String] {
        var mapping: [String: String] = [:]
        let labels = newEmbeddings.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for label in labels {
            guard let embedding = newEmbeddings[label] else { continue }
            let best = anchors
                .map { (label: $0.key, similarity: SpeakerProfileStore.cosine(embedding, $0.value)) }
                .max { $0.similarity < $1.similarity }
            if let best, best.similarity >= 0.7 { mapping[label] = best.label }
        }
        var next = 1
        for label in labels where mapping[label] == nil && (speech[label] ?? 0) >= minFreshSpeech {
            while anchors[("Speaker \(next)")] != nil || mapping.values.contains("Speaker \(next)") { next += 1 }
            mapping[label] = "Speaker \(next)"
            next += 1
        }
        return mapping
    }

    /// Maps a diarization run's labels onto the previous run's identities, so
    /// live sweeps can't flip Speaker 1 and Speaker 2 mid-call when talk-time
    /// order changes. Greedy in label order: best unused anchor with cosine
    /// ≥ 0.7 (calibrated same-voice ≈ 0.96) wins that anchor's label;
    /// unmatched clusters take the next unused index. Empty anchors → identity.
    nonisolated static func stableMapping(
        newEmbeddings: [String: [Float]],
        anchors: [String: [Float]]
    ) -> [String: String] {
        var mapping: [String: String] = [:]
        var usedAnchors: Set<String> = []
        let newLabels = newEmbeddings.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for label in newLabels {
            guard let embedding = newEmbeddings[label] else { continue }
            let best = anchors
                .filter { !usedAnchors.contains($0.key) }
                .map { (label: $0.key, similarity: SpeakerProfileStore.cosine(embedding, $0.value)) }
                .max { $0.similarity < $1.similarity }
            if let best, best.similarity >= 0.7 {
                mapping[label] = best.label
                usedAnchors.insert(best.label)
            }
        }
        // Unmatched clusters get the smallest "Speaker N" nobody else holds.
        let reserved = Set(anchors.keys).union(mapping.values)
        var next = 1
        for label in newLabels where mapping[label] == nil {
            while reserved.contains("Speaker \(next)") || mapping.values.contains("Speaker \(next)") { next += 1 }
            mapping[label] = "Speaker \(next)"
            next += 1
        }
        return mapping
    }

    /// Best speaker turn for a transcript segment: max time overlap, else the
    /// nearest turn in time — so every non-Me segment gets a label instead of
    /// leaving stray "Them" holes where diarization saw no speech.
    nonisolated static func diarizedLabel(
        for segment: (start: TimeInterval, end: TimeInterval),
        turns: [DiarizationEngine.SpeakerSegmentResult]
    ) -> String? {
        var best: (label: String, overlap: TimeInterval)?
        var nearest: (label: String, gap: TimeInterval)?
        for turn in turns {
            let overlap = min(turn.endTime, segment.end) - max(turn.startTime, segment.start)
            if overlap > 0, overlap > (best?.overlap ?? 0) { best = (turn.speakerLabel, overlap) }
            let gap = max(turn.startTime - segment.end, segment.start - turn.endTime)
            if nearest == nil || gap < nearest!.gap { nearest = (turn.speakerLabel, gap) }
        }
        return best?.label ?? nearest?.label
    }

    var formattedElapsedTime: String {
        let hours = Int(elapsedTime) / 3600
        let minutes = (Int(elapsedTime) % 3600) / 60
        let seconds = Int(elapsedTime) % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

enum RecordingError: LocalizedError {
    case modelNotReady
    case noDownloadedSpeechModel
    case screenAnalysisUnavailable
    case speakersNotDetected

    var errorDescription: String? {
        switch self {
        case .modelNotReady: "The speech model could not be loaded. Check the model in Settings."
        case .noDownloadedSpeechModel: "Auto needs a downloaded compatible speech model. Download one or choose a model in Settings."
        case .screenAnalysisUnavailable: "Screen analysis is unavailable. Choose a vision-capable AI and review your privacy settings."
        case .speakersNotDetected: "Speaker detection didn't work this time. Try again."
        }
    }
}

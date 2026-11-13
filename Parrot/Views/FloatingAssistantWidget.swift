import AppKit
import SwiftUI

/// Always-on-top floating widget for live Questions, Notes, and AI Lookups.
/// Excluded from screen capture (`sharingType = .none`) so screen shares
/// in Zoom, Teams, or Google Meet never show it.
@MainActor
@Observable
final class FloatingAssistantWidgetController: NSObject, NSWindowDelegate {
    static let shared = FloatingAssistantWidgetController()

    enum Tab: String, CaseIterable, Identifiable {
        case questions = "Questions"
        case notes = "Notes"
        case lookup = "Lookup"
        var id: String { rawValue }
    }

    var isVisible = false
    var activeTab: Tab = .questions
    var preparedQuestions: [String] = []
    var isPreparingQuestions = false
    var questionsError: String?

    var lookupQuery = ""
    var lookupAnswer = ""
    var isLookingUp = false
    var lookupError: String?

    var draftNotes = ""

    private var panel: NSPanel?
    private weak var recordingManager: RecordingManager?

    func toggle(recordingManager: RecordingManager) {
        if isVisible {
            hide()
        } else {
            show(recordingManager: recordingManager)
        }
    }

    func show(recordingManager: RecordingManager) {
        self.recordingManager = recordingManager
        let panel = self.panel ?? makePanel(recordingManager: recordingManager)
        self.panel = panel
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }

    private func makePanel(recordingManager: RecordingManager) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Sakviro Assistant"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.sharingType = .none
        panel.minSize = NSSize(width: 320, height: 280)
        panel.delegate = self

        let root = FloatingAssistantWidgetView(controller: self)
            .environment(recordingManager)
        panel.contentView = NSHostingView(rootView: root)

        if !panel.setFrameAutosaveName("FloatingAssistantWidget"),
           let screen = NSScreen.main ?? NSScreen.screens.first {
            let vf = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vf.maxX - 400, y: vf.maxY - 460))
        }
        return panel
    }

    // MARK: - AI Actions

    func prepareQuestions(using manager: RecordingManager) async {
        guard !isPreparingQuestions else { return }
        isPreparingQuestions = true
        questionsError = nil
        defer { isPreparingQuestions = false }

        let transcript = recentTranscript(from: manager, limit: 4500)
        let notes = manager.currentMeeting?.notes ?? draftNotes
        let meetingTitle = manager.currentMeeting?.title ?? ""
        let query = [meetingTitle, String(transcript.suffix(600))].filter { !$0.isEmpty }.joined(separator: "\n")
        let refs = await manager.knowledgeBase.search(
            query: query.isEmpty ? "project questions context" : query,
            profileID: manager.callAnalysisEngine.activeProfile?.id,
            topK: 3
        )
        let kbContext = refs.map { "[\($0.documentName)] \($0.text)" }.joined(separator: "\n\n")

        let system = """
        You are a concise live meeting assistant. Prepare 3 sharp, practical questions the user can ask right now based on the conversation and project context. Return only the 3 questions, one per line, without numbering or preamble. Match the language of the conversation (e.g. Lithuanian or English).
        """
        var parts: [String] = []
        if !meetingTitle.isEmpty { parts.append("Meeting: \(meetingTitle)") }
        if !kbContext.isEmpty { parts.append("Project context:\n\(kbContext)") }
        if !notes.isEmpty { parts.append("User notes:\n\(notes)") }
        if !transcript.isEmpty { parts.append("Recent transcript:\n\(transcript)") }
        if parts.isEmpty { parts.append("No transcript yet. Suggest 3 strong opening/discovery questions.") }

        do {
            let reply = try await manager.callAnalysisEngine.provider.complete(
                system: system,
                user: parts.joined(separator: "\n\n"),
                maxTokens: 300
            )
            let lines = reply
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: #"^[\-\*\d\.\)\s]+"#, with: "", options: .regularExpression) }
                .filter { !$0.isEmpty }
            preparedQuestions = Array(lines.prefix(5))
        } catch {
            questionsError = error.localizedDescription
        }
    }

    func runLookup(using manager: RecordingManager) async {
        let query = lookupQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isLookingUp else { return }
        isLookingUp = true
        lookupError = nil
        defer { isLookingUp = false }

        let transcript = recentTranscript(from: manager, limit: 3500)
        let refs = await manager.knowledgeBase.search(
            query: query,
            profileID: manager.callAnalysisEngine.activeProfile?.id,
            topK: 4
        )
        let kbContext = refs.map { "[\($0.documentName)] \($0.text)" }.joined(separator: "\n\n")

        let system = """
        You are a fast on-screen meeting lookup assistant. Answer the user's query concisely in 2-5 sentences using the project documents and live call transcript. Match the language of the query.
        """
        var parts = ["Query: \(query)"]
        if !kbContext.isEmpty { parts.append("Project documents:\n\(kbContext)") }
        if !transcript.isEmpty { parts.append("Current conversation:\n\(transcript)") }

        do {
            lookupAnswer = try await manager.callAnalysisEngine.provider.complete(
                system: system,
                user: parts.joined(separator: "\n\n"),
                maxTokens: 400
            )
        } catch {
            lookupError = error.localizedDescription
        }
    }

    private func recentTranscript(from manager: RecordingManager, limit: Int) -> String {
        guard let meeting = manager.currentMeeting else { return "" }
        let names = meeting.speakerNames
        let text = meeting.sortedSegments
            .suffix(25)
            .map { "[\(meeting.displayName(forSpeaker: $0.speakerLabel, names: names))] \($0.text)" }
            .joined(separator: "\n")
        if text.count <= limit { return text }
        return String(text.suffix(limit))
    }
}

struct FloatingAssistantWidgetView: View {
    @Environment(RecordingManager.self) private var recordingManager
    @Bindable var controller: FloatingAssistantWidgetController

    private var liveQuestions: [Insight] {
        recordingManager.callAnalysisEngine.insights.filter {
            $0.kindKey.contains("question") || $0.kindKey == "suggestion" || $0.kindKey == "blocker"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Theme.Colors.accent)
                Text("Sakviro")
                    .font(.appHeadline)
                if recordingManager.isRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                }
                Spacer()
                Picker("", selection: $controller.activeTab) {
                    ForEach(FloatingAssistantWidgetController.Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 210)
            }
            .padding(.horizontal, 12)
            .padding(.top, 28)
            .padding(.bottom, 8)

            Divider()

            Group {
                switch controller.activeTab {
                case .questions: questionsTab
                case .notes: notesTab
                case .lookup: lookupTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.ultraThinMaterial)
    }

    private var questionsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Suggested Questions")
                    .font(.appCaption)
                    .foregroundStyle(Theme.Colors.ink2)
                Spacer()
                Button {
                    Task { await controller.prepareQuestions(using: recordingManager) }
                } label: {
                    if controller.isPreparingQuestions {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Prepare Questions", systemImage: "wand.and.stars")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(controller.isPreparingQuestions)
            }

            if let err = controller.questionsError {
                Text(err)
                    .font(.appCaption)
                    .foregroundStyle(.red)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.preparedQuestions, id: \.self) { question in
                        questionRow(question)
                    }
                    ForEach(liveQuestions.prefix(5)) { insight in
                        questionRow("\(insight.title): \(insight.detail)")
                    }
                    if controller.preparedQuestions.isEmpty && liveQuestions.isEmpty {
                        Text("Click “Prepare Questions” to generate questions from the live call and project context.")
                            .font(Theme.Typography.secondary)
                            .foregroundStyle(Theme.Colors.ink2)
                            .padding(.top, 12)
                    }
                }
            }
        }
        .padding(12)
    }

    private func questionRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.appBody)
                .foregroundStyle(Theme.Colors.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy question")
        }
        .padding(8)
        .background(Theme.Colors.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(recordingManager.currentMeeting != nil ? "Live meeting notes (auto-saved)" : "Scratch notes")
                .font(.appCaption)
                .foregroundStyle(Theme.Colors.ink2)
            TextEditor(text: notesBinding)
                .font(.appBody)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Theme.Colors.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(12)
    }

    private var notesBinding: Binding<String> {
        if let meeting = recordingManager.currentMeeting {
            return Binding(
                get: { meeting.notes },
                set: { meeting.notes = $0 }
            )
        }
        return $controller.draftNotes
    }

    private var lookupTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                TextField("Ask AI or search project context…", text: $controller.lookupQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await controller.runLookup(using: recordingManager) }
                    }
                Button {
                    Task { await controller.runLookup(using: recordingManager) }
                } label: {
                    if controller.isLookingUp {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Ask")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(controller.isLookingUp || controller.lookupQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let err = controller.lookupError {
                Text(err)
                    .font(.appCaption)
                    .foregroundStyle(.red)
            }

            ScrollView {
                if !controller.lookupAnswer.isEmpty {
                    Text(controller.lookupAnswer)
                        .font(.appBody)
                        .foregroundStyle(Theme.Colors.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Theme.Colors.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("Ask a quick question or look up details from your Knowledge Base and live call without leaving your meeting.")
                        .font(Theme.Typography.secondary)
                        .foregroundStyle(Theme.Colors.ink2)
                        .padding(.top, 8)
                }
            }
        }
        .padding(12)
    }
}

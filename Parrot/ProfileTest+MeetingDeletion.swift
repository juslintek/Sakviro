import Foundation
import SwiftData

extension ProfileTest {
    @MainActor
    static func testMeetingDeletion() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sakviro-delete-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                do { try FileManager.default.removeItem(at: directory) }
                catch { check("delete: scratch cleanup \(error)", false) }
            }
            let audio = directory.appendingPathComponent("recording.caf")
            try Data([1, 2, 3]).write(to: audio)
            let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
            let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("meetings.store"))
            let id: UUID
            do {
                let container = try ModelContainer(for: schema, configurations: [configuration])
                let context = ModelContext(container)
                let profile = CallProfile(name: "Deletion fixture", iconSystemName: "phone", summary: "",
                                          isBuiltIn: false, sortOrder: 0, persona: "", tone: "",
                                          allowGeneralKnowledge: false, kinds: [], gauges: [])
                context.insert(profile)
                let meeting = Meeting(title: "Delete me", systemAudioPath: audio.path)
                context.insert(meeting)
                meeting.status = .failed
                meeting.profile = profile
                id = meeting.id
                for index in 0..<3 {
                    let segment = TranscriptSegment(startTime: Double(index), endTime: Double(index + 1), text: "Fixture line")
                    context.insert(segment)
                    segment.meeting = meeting
                }
                let insight = CallInsight(from: Insight(kindKey: "suggestion", title: "Fixture", detail: "", callTime: 0, source: nil))
                context.insert(insight)
                insight.meeting = meeting
                let survivor = Meeting(title: "Keep me")
                context.insert(survivor)
                survivor.status = .done
                survivor.sessionMode = .screenOnly
                survivor.profile = profile
                try context.save()
            }
            let legacy = Process()
            legacy.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            legacy.arguments = [configuration.url.path, "UPDATE ZMEETING SET ZSESSIONMODE = NULL WHERE ZTITLE = 'Delete me';"]
            try legacy.run()
            legacy.waitUntilExit()
            guard legacy.terminationStatus == 0 else {
                check("delete: legacy fixture created", false)
                return
            }
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let meetings = try context.fetch(FetchDescriptor<Meeting>())
            guard let meeting = meetings.first(where: { $0.id == id }) else {
                check("delete: persisted fixture exists", false)
                return
            }
            let manager = RecordingManager(memory: MeetingMemory(directory: nil), chats: AskChatStore(directory: nil))
            manager.attachForHarness(modelContext: context)
            manager.justFinished = meeting
            check("delete: legacy session mode is absent", meeting.sessionMode == nil)
            check("delete: legacy meeting uses normal meeting behavior", meeting.sessionMode != .screenOnly)
            check("delete: legacy meeting removed successfully", manager.delete(meeting))
            check("delete: finished sheet released", manager.justFinished == nil)
            let reopened = ModelContext(container)
            let meetingCount = try reopened.fetchCount(FetchDescriptor<Meeting>())
            let transcriptCount = try reopened.fetchCount(FetchDescriptor<TranscriptSegment>())
            let insightCount = try reopened.fetchCount(FetchDescriptor<CallInsight>())
            let profileCount = try reopened.fetchCount(FetchDescriptor<CallProfile>())
            check("delete: persisted meeting removed", meetingCount == 1)
            check("delete: transcript children removed", transcriptCount == 0)
            check("delete: insight children removed", insightCount == 0)
            check("delete: shared profile retained", profileCount == 1)
            let survivor = try reopened.fetch(FetchDescriptor<Meeting>()).first!
            check("delete: screen-only meeting mode retained", survivor.sessionMode == .screenOnly)
            check("delete: audio removed", !FileManager.default.fileExists(atPath: audio.path))
            try Data([4, 5, 6]).write(to: audio)
            survivor.systemAudioPath = audio.path
            survivor.notes = "Keep these notes"
            let retainedLine = TranscriptSegment(startTime: 0, endTime: 1, text: "Keep this line")
            reopened.insert(retainedLine)
            retainedLine.meeting = survivor
            let retainedInsight = CallInsight(from: Insight(kindKey: "suggestion", title: "Keep this insight", detail: "", callTime: 0, source: nil))
            reopened.insert(retainedInsight)
            retainedInsight.meeting = survivor
            try reopened.save()
            let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: configuration.url, allowsSave: false)])
            let readOnlyContext = ModelContext(readOnly)
            let protected = try readOnlyContext.fetch(FetchDescriptor<Meeting>()).first!
            manager.attachForHarness(modelContext: readOnlyContext)
            var deletionNotifications = 0
            let observer = NotificationCenter.default.addObserver(forName: .parrotMeetingWillDelete, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { deletionNotifications += 1 }
            }
            protected.notes = "Unsaved edit"
            check("delete: failed pre-save preserves pending edit", !manager.delete(protected) && protected.notes == "Unsaved edit" && readOnlyContext.hasChanges)
            readOnlyContext.rollback()
            check("delete: failed save is reported", !manager.delete(protected) && manager.deletionFailure != nil)
            NotificationCenter.default.removeObserver(observer)
            check("delete: read-only refusal keeps selection", deletionNotifications == 0)
            let restoredMeetings = try readOnlyContext.fetch(FetchDescriptor<Meeting>())
            let persistedCount = try ModelContext(readOnly).fetchCount(FetchDescriptor<Meeting>())
            check("delete: failed save restores library query", restoredMeetings.count == 1)
            if let restored = restoredMeetings.first, !restored.isDeleted {
                check("delete: failed save preserves original meeting", restored === protected && restored.notes == "Keep these notes" && restored.profile?.id == survivor.profile?.id)
                check("delete: failed save preserves children", restored.segments.count == 1 && restored.segments.first?.text == "Keep this line" && restored.insights.count == 1 && restored.insights.first?.title == "Keep this insight")
            } else {
                check("delete: failed save preserves original meeting", false)
                check("delete: failed save preserves children", false)
            }
            check("delete: failed save retains persisted meeting", persistedCount == 1)
            check("delete: failed save retains recording", FileManager.default.fileExists(atPath: audio.path))
            guard let activeContext = phase4Context() else {
                check("delete: active-work store opens", false)
                return
            }
            let active = Meeting(title: "Writing report")
            activeContext.insert(active)
            active.status = .done
            let line = TranscriptSegment(startTime: 0, endTime: 1, text: "Fixture line")
            activeContext.insert(line)
            line.meeting = active
            let stuck = Meeting(title: "Interrupted processing")
            activeContext.insert(stuck)
            stuck.status = .processing
            try activeContext.save()
            let provider = DeletionReportProvider()
            let activeManager = RecordingManager(memory: MeetingMemory(directory: nil), chats: AskChatStore(directory: nil), provider: provider)
            activeManager.attachForHarness(modelContext: activeContext)
            provider.duringReport = {
                check("delete: active report prevents its own deletion", !activeManager.delete(active))
                check("delete: active report permits another stuck meeting deletion", activeManager.delete(stuck))
            }
            awaitMain {
                do { try await activeManager.writeReport(active) }
                catch { check("delete: report finishes \(error)", false) }
            }
            provider.duringReport = nil
            check("delete: completed report releases deletion guard", activeManager.delete(active))
        } catch {
            check("delete: fixture completes \(error)", false)
        }
    }
}

private final class DeletionReportProvider: AnalysisProvider {
    var isConfigured: Bool { true }
    var duringReport: (@MainActor () -> Void)?
    func analyze(_ request: AnalysisRequest) async throws -> AnalysisResult { throw CancellationError() }
    func summarize(transcript: String, insightTitles: [String], bookmarks: [String],
                   instructions: String, counterpart: String, template: ReportTemplate) async throws -> String {
        await duringReport?()
        return "Fixture report"
    }
    func coachingReport(transcript: String, talkPercentMe: Int, instructions: String,
                        counterpart: String, template: ReportTemplate) async throws -> String { "Fixture coaching" }
    func complete(system: String, user: String, maxTokens: Int) async throws -> String { "Fixture answer" }
}

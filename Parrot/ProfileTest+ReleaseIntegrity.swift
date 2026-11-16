import Foundation
import SwiftData

extension ProfileTest {
    @MainActor
    static func testReleaseIntegrity() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sakviro-integrity-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer {
                do { try FileManager.default.removeItem(at: directory) }
                catch { check("integrity: scratch cleanup \(error)", false) }
            }
            let schema = Schema([Meeting.self, TranscriptSegment.self, CallInsight.self, CallProfile.self, SpeakerProfile.self])
            let config = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("meetings.store"))
            let container = try ModelContainer(for: schema, configurations: [config])
            let uiContext = ModelContext(container)
            let meeting = Meeting(title: "Fixture")
            meeting.summary = "Original report"
            meeting.speakerNames = ["Them": "Alex"]
            meeting.speakerEmbeddingsData = Data([1, 2, 3])
            uiContext.insert(meeting)
            let old = TranscriptSegment(startTime: 0, endTime: 1, text: "Original", speakerLabel: "Them", confidence: nil)
            uiContext.insert(old)
            old.meeting = meeting
            try uiContext.save()
            let id = meeting.id
            let replacement = [(text: "Replacement", start: 0.0, end: 1.0, speaker: "Them")]
            let readOnly = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, url: config.url, allowsSave: false)])
            let failedContext = ModelContext(readOnly)
            failedContext.autosaveEnabled = false
            let openMeeting = try failedContext.fetch(FetchDescriptor<Meeting>()).first!
            let openSegment = openMeeting.segments.first!
            var failed = false
            do {
                _ = try RecordingManager.saveRetranscription(meetingID: id, context: failedContext, segments: replacement, embeddingsData: Data([9]))
            } catch { failed = true }
            check("integrity: read-only store rejects replacement", failed)
            let sameContext = try failedContext.fetch(FetchDescriptor<Meeting>()).first!
            check("integrity: failed save restores open meeting", sameContext.segments.map(\.text) == ["Original"] && sameContext.speakerNames == ["Them": "Alex"] && sameContext.speakerEmbeddingsData == Data([1, 2, 3]))
            check("integrity: original open segment remains readable", openMeeting.segments.first === openSegment && openSegment.text == "Original" && openSegment.startTime == 0 && openSegment.endTime == 1 && openSegment.speakerLabel == "Them" && openSegment.confidence == nil)
            for candidate in [[], replacement + replacement] {
                let candidateContext = ModelContext(readOnly)
                candidateContext.autosaveEnabled = false
                let candidateMeeting = try candidateContext.fetch(FetchDescriptor<Meeting>()).first!
                var rejected = false
                do {
                    _ = try RecordingManager.saveRetranscription(meetingID: id, context: candidateContext, segments: candidate, embeddingsData: Data([9]))
                } catch { rejected = true }
                check("integrity: failed replacement count \(candidate.count) restores open meeting", rejected && candidateMeeting.segments.map(\.text) == ["Original"] && candidateMeeting.speakerNames == ["Them": "Alex"] && candidateMeeting.speakerEmbeddingsData == Data([1, 2, 3]))
            }
            sameContext.title = "Pending title"
            do {
                _ = try RecordingManager.saveRetranscription(meetingID: id, context: failedContext, segments: replacement, embeddingsData: Data([9]))
                check("integrity: failed pending save throws", false)
            } catch {
                check("integrity: failed pending save keeps unrelated edit", sameContext.title == "Pending title" && failedContext.hasChanges)
            }
            let persisted = try ModelContext(readOnly).fetch(FetchDescriptor<Meeting>()).first!
            check("integrity: failed save retains transcript", persisted.segments.map(\.text) == ["Original"])
            check("integrity: failed save retains speaker data and report", persisted.speakerNames == ["Them": "Alex"] && persisted.speakerEmbeddingsData == Data([1, 2, 3]) && persisted.summary == "Original report")
            let sem = DispatchSemaphore(value: 0)
            let cancelled = Task { @MainActor in
                defer { sem.signal() }
                let context = ModelContext(container)
                context.autosaveEnabled = false
                do {
                    _ = try RecordingManager.saveRetranscription(meetingID: id, context: context, segments: replacement, embeddingsData: Data([9]))
                    check("integrity: cancelled replacement throws", false)
                } catch is CancellationError {
                    check("integrity: cancelled replacement throws", true)
                } catch {
                    check("integrity: cancelled replacement throws", false)
                }
            }
            cancelled.cancel()
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: .now + 0.01) }
            let afterCancel = try ModelContext(container).fetch(FetchDescriptor<Meeting>()).first!
            check("integrity: cancellation retains original", afterCancel.segments.map(\.text) == ["Original"] && afterCancel.speakerNames == ["Them": "Alex"] && afterCancel.speakerEmbeddingsData == Data([1, 2, 3]) && afterCancel.summary == "Original report")
            let validAudio = directory.appendingPathComponent("valid.wav")
            try WAVEncoder.encode(samples: [Float](repeating: 0, count: 1600), sampleRate: 16000).write(to: validAudio)
            let invalidAudio = directory.appendingPathComponent("invalid.wav")
            try Data([1, 2, 3]).write(to: invalidAudio)
            let trackSem = DispatchSemaphore(value: 0)
            Task { @MainActor in
                defer { trackSem.signal() }
                for path in [directory.appendingPathComponent("missing.wav").path, invalidAudio.path] {
                    var transcribed = false
                    do {
                        _ = try await TranscriptPolisher.polish(systemPath: validAudio.path, micPath: path, strictTracks: true) { _, _, _, _, _ in
                            transcribed = true
                            return []
                        }
                        check("integrity: invalid expected track throws", false)
                    } catch {
                        check("integrity: invalid expected track throws before transcription", !transcribed)
                    }
                }
            }
            while trackSem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: .now + 0.01) }
            let unrelated = Meeting(title: "Unsaved unrelated edit")
            uiContext.insert(unrelated)
            _ = try RecordingManager.saveRetranscription(meetingID: id, context: uiContext, segments: replacement, embeddingsData: Data([9]))
            let savedUnrelated = try ModelContext(container).fetch(FetchDescriptor<Meeting>()).contains { $0.title == "Unsaved unrelated edit" }
            check("integrity: pending unrelated edit preserved", savedUnrelated)
            let saved = try ModelContext(container).fetch(FetchDescriptor<Meeting>()).first { $0.id == id }!
            check("integrity: replacement persisted", saved.segments.map(\.text) == ["Replacement"] && saved.speakerEmbeddingsData == Data([9]))
            let segmentCount = try ModelContext(container).fetchCount(FetchDescriptor<TranscriptSegment>())
            check("integrity: old transcript rows removed", segmentCount == replacement.count)
            RunLoop.main.run(until: .now + 0.1)
            check("integrity: open meeting refreshes replacement", meeting.segments.map(\.text) == ["Replacement"] && meeting.speakerEmbeddingsData == Data([9]))
        } catch {
            check("integrity: fixture error \(error)", false)
        }
    }
}

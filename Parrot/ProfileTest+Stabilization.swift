import Foundation
import AppKit
import SwiftData

extension ProfileTest {
    @MainActor
    static func testStabilization() {
        // 1. TranscriptionJobProgress
        let now = Date(timeIntervalSince1970: 1000)
        let start = now.addingTimeInterval(-10)

        let clampLow = TranscriptionJobProgress(meetingID: UUID(), fraction: -0.2, stage: .diarizing, startedAt: start)
        check("progress: clamp below zero", clampLow.statusText == "Separating speakers… 0%")

        let clampHigh = TranscriptionJobProgress(meetingID: UUID(), fraction: 1.4, stage: .diarizing, startedAt: start)
        check("progress: clamp above one", clampHigh.statusText == "Separating speakers… 100%")

        let prep = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.5, stage: .preparingModel("Lithuanian Ąžuolas MLX"), startedAt: start)
        check("progress: preparingModel statusText", prep.statusText == "Loading Lithuanian Ąžuolas MLX… 50%")

        let trans = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.5, stage: .transcribing(trackLabel: "Mic", completedSeconds: 30, totalSeconds: 60), startedAt: start)
        check("progress: transcribing statusText", trans.statusText == "Transcribing Mic (30s / 60s) · 50%")

        let diar = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.5, stage: .diarizing, startedAt: start)
        check("progress: diarizing statusText", diar.statusText == "Separating speakers… 50%")

        let idx = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.5, stage: .indexingAndSaving, startedAt: start)
        check("progress: indexingAndSaving statusText", idx.statusText == "Indexing transcript… 50%")

        let upd = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.5, stage: .updatingReport, startedAt: start)
        check("progress: updatingReport statusText", upd.statusText == "Updating report… 50%")

        let lowFrac = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.04, stage: .diarizing, startedAt: start)
        check("progress: remaining nil when fraction < 0.05", lowFrac.estimatedRemaining(now: now) == nil)

        let recent = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.5, stage: .diarizing, startedAt: now.addingTimeInterval(-1.5))
        check("progress: remaining nil when elapsed < 2", recent.estimatedRemaining(now: now) == nil)

        let halfDone = TranscriptionJobProgress(meetingID: UUID(), fraction: 0.5, stage: .diarizing, startedAt: start)
        let rem = halfDone.estimatedRemaining(now: now)
        check("progress: remaining 10s at fraction 0.5 after 10s", rem != nil && abs(rem! - 10.0) < 0.001)

        // 2. MLXTranscriber
        var loudSamples = [Float](repeating: 0.25, count: 560_000)
        let dipCenter = 25 * 16_000
        for i in (dipCenter - 3200)..<(dipCenter + 3200) {
            loudSamples[i] = 0.10
        }
        let boundary = try? MLXTranscriber.importBoundary(loudSamples, from: 0)
        check("mlx importBoundary: finds quiet boundary near dip", boundary != nil && abs(boundary! - dipCenter) <= 4800)

        let shortSamples = [Float](repeating: 0.25, count: 100_000)
        let shortBoundary = try? MLXTranscriber.importBoundary(shortSamples, from: 0)
        check("mlx importBoundary: short audio returns full count", shortBoundary == 100_000)

        check("mlx effectiveLanguage: azuolas auto is lt", MLXTranscriber.effectiveLanguage(for: "mlx-azuolas", selected: nil) == "lt"
              && MLXTranscriber.effectiveLanguage(for: "mlx-azuolas", selected: "auto") == "lt")
        check("mlx effectiveLanguage: paprika auto is lt", MLXTranscriber.effectiveLanguage(for: "mlx-paprika", selected: nil) == "lt"
              && MLXTranscriber.effectiveLanguage(for: "mlx-paprika", selected: "auto") == "lt")
        check("mlx effectiveLanguage: azuolas explicit en is en", MLXTranscriber.effectiveLanguage(for: "mlx-azuolas", selected: "en") == "en")
        check("mlx effectiveLanguage: parakeet auto is nil", MLXTranscriber.effectiveLanguage(for: "parakeet-v3", selected: "auto") == nil)

        // 3. CallDetector & BrowserCallInspector
        check("call detector: zoom is dedicated call app", CallDetector.isDedicatedCallApp("us.zoom.xos"))
        check("call detector: chrome is not dedicated call app", !CallDetector.isDedicatedCallApp("com.google.Chrome"))
        check("call detector: chrome is browser app", CallDetector.isBrowserApp("com.google.Chrome"))
        check("call detector: arc is browser app", CallDetector.isBrowserApp("company.thebrowser.Browser"))
        check("call detector: zoom is not browser app", !CallDetector.isBrowserApp("us.zoom.xos"))
        check("call detector: zoom is known meeting app", CallDetector.isKnownMeetingApp("us.zoom.xos"))
        check("call detector: chrome is known meeting app", CallDetector.isKnownMeetingApp("com.google.Chrome"))

        check("browser call inspector: google meet title", BrowserCallInspector.isMeetingWindowTitle("Meet - abc-defg-hij - Google Chrome"))
        check("browser call inspector: teams title", BrowserCallInspector.isMeetingWindowTitle("Weekly Sync | Microsoft Teams"))
        check("browser call inspector: zoom title", BrowserCallInspector.isMeetingWindowTitle("Zoom Meeting"))
        check("browser call inspector: slack huddle title", BrowserCallInspector.isMeetingWindowTitle("Slack - Huddle"))
        check("browser call inspector: gmail title is not meeting", !BrowserCallInspector.isMeetingWindowTitle("Gmail - Inbox"))
        check("browser call inspector: github title is not meeting", !BrowserCallInspector.isMeetingWindowTitle("GitHub Pull Requests"))
        check("browser call inspector: youtube title is not meeting", !BrowserCallInspector.isMeetingWindowTitle("YouTube"))

        // 4. CLIAnalysisProvider & AssistantRoutingSettings
        let agyRaw = "{\"event\":\"init\"}\n{\"event\":\"result\",\"result\":{\"status\":\"SUCCESS\",\"response\":\"Sveiki\",\"usage\":{\"input_tokens\":120,\"output_tokens\":15}}}"
        let agyParsed = try? CLIAnalysisProvider.parseCLIOutput(agyRaw, kind: .gemini, isAgy: true)
        check("cli parse: agy text response", agyParsed?.text == "Sveiki")
        check("cli parse: agy token usage", agyParsed?.inputTokens == 120 && agyParsed?.outputTokens == 15)

        let agyErrRaw = "{\"event\":\"result\",\"result\":{\"status\":\"ERROR\",\"error\":\"Service Unavailable\"}}"
        var agyThrew = false
        do {
            _ = try CLIAnalysisProvider.parseCLIOutput(agyErrRaw, kind: .gemini, isAgy: true)
        } catch {
            agyThrew = true
        }
        check("cli parse: agy error throws", agyThrew)

        let claudeRaw = "{\"type\":\"result\",\"result\":\"OK\",\"is_error\":false,\"usage\":{\"input_tokens\":50,\"output_tokens\":8}}"
        let claudeParsed = try? CLIAnalysisProvider.parseCLIOutput(claudeRaw, kind: .claudeCode)
        check("cli parse: claude text and tokens", claudeParsed?.text == "OK" && claudeParsed?.inputTokens == 50 && claudeParsed?.outputTokens == 8)

        let suite = "parrot-stabilization-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudGate.globalKey)
        defaults.set("", forKey: AssistantRoutingSettings.enabledKey)
        check("routing: fresh isolated defaults does not route locally", !AssistantRoutingSettings.routesLocally(in: defaults))
        AssistantRoutingSettings.setEnabled(true, kind: .ollama, defaults: defaults)
        check("routing: only ollama enabled routes locally", AssistantRoutingSettings.routesLocally(in: defaults))
        check("routing: availableKinds includes custom", AssistantRoutingSettings.availableKinds.contains(.custom))

        // 5. FloatingAssistantWidgetController
        let panel = KeyableFloatingPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: true)
        check("floating widget: panel canBecomeKey is true", panel.canBecomeKey == true)
        check("floating widget: panel canBecomeMain is false", panel.canBecomeMain == false)

        let prevAutoShow = UserDefaults.standard.object(forKey: "floatingWidgetAutoShow")
        UserDefaults.standard.set(false, forKey: "floatingWidgetAutoShow")
        defer {
            if let prevAutoShow {
                UserDefaults.standard.set(prevAutoShow, forKey: "floatingWidgetAutoShow")
            } else {
                UserDefaults.standard.removeObject(forKey: "floatingWidgetAutoShow")
            }
        }
        let widget = FloatingAssistantWidgetController.shared
        let manager = RecordingManager(memory: MeetingMemory(directory: nil), chats: AskChatStore(directory: nil))
        let meeting = Meeting(title: "Carryover Test")
        widget.draftNotes = "My draft notes"
        widget.onRecordingStarted(meeting: meeting, manager: manager)
        check("floating widget: draftNotes carries over into empty meeting notes", meeting.notes == "My draft notes")
        check("floating widget: draftNotes cleared after carryover", widget.draftNotes.isEmpty)

        meeting.notes = "Existing notes"
        widget.draftNotes = "Prepended draft"
        widget.onRecordingStarted(meeting: meeting, manager: manager)
        check("floating widget: draftNotes prepends when meeting notes exist", meeting.notes == "Prepended draft\n\nExisting notes")
        check("floating widget: draftNotes cleared after second carryover", widget.draftNotes.isEmpty)
    }
}

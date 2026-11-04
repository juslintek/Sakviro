import AppKit
import ScreenCaptureKit

private final class VisionFixtureView: NSView {
    let color: NSColor
    let round: Bool
    init(color: NSColor, round: Bool, frame: NSRect) {
        self.color = color
        self.round = round
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        color.setFill()
        let rectangle = bounds.insetBy(dx: 90, dy: 30)
        (round ? NSBezierPath(ovalIn: rectangle) : NSBezierPath(rect: rectangle)).fill()
    }
}

@MainActor
enum VisionCaptureHarness {
    static func run(providerName: String) {
        Task { @MainActor in
            let provider: CopilotProviderKind
            switch providerName {
            case "codex": provider = .codex
            case "copilot": provider = .copilot
            case "claude": provider = .claudeCode
            default:
                print("FAIL owned-window vision: use codex, copilot or claude")
                exit(1)
            }
            let choices: [(String, NSColor)] = [("red", .red), ("blue", .blue), ("green", .green), ("yellow", .yellow)]
            let (expectedColor, color) = choices.randomElement()!
            let round = Bool.random()
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 360),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = UUID().uuidString
            window.contentView = VisionFixtureView(color: color, round: round, frame: NSRect(x: 0, y: 0, width: 480, height: 360))
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            let capture = VideoCaptureService()
            var sampled: ScreenContext?
            let sampler = ScreenFrameSampler(onSample: { context in
                Task { @MainActor in sampled = context }
            })
            do {
                try await Task.sleep(for: .seconds(1))
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let source = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    throw AnalysisError.badResponse("Own fixture window unavailable to ScreenCaptureKit")
                }
                capture.onFrame = { buffer, capturedAt in sampler.submit(buffer, capturedAt: capturedAt) }
                sampler.setEnabled(true)
                try await capture.start(filter: SCContentFilter(desktopIndependentWindow: source),
                                        audioOrigin: ProcessInfo.processInfo.systemUptime, archive: false)
                for _ in 0..<40 where sampled == nil { try await Task.sleep(for: .milliseconds(250)) }
                try await capture.stopWatching()
                sampler.stop()
                guard let context = sampled, let jpeg = context.jpeg, ScreenContext.validateJPEG(jpeg) else {
                    throw AnalysisError.badResponse("No valid sampled image")
                }
                let profile = ProfilePresets.makeDefault(persona: "Describe what appears in the image.", tone: "", allowGeneralKnowledge: false)
                let request = AnalysisRequest(transcript: "", knownInsightTitles: [], references: [],
                    instructions: "Describe the visible figure and its color in one insight. Set source to Selected screen.",
                    callBrief: "", allowGeneralKnowledge: false, knownDocumentNames: [], persona: profile.persona,
                    counterpart: profile.counterpart, kinds: profile.kinds, gauges: profile.gauges, screenContext: context)
                let started = Date()
                let result = try await CLIAnalysisProvider({ provider }).analyze(request)
                let descriptions = result.insights.map { "\($0.title) \($0.detail) \($0.reply ?? "")" }.joined(separator: " ").lowercased()
                let shapeMatches = round ? (descriptions.contains("circle") || descriptions.contains("round") || descriptions.contains("oval")) : (descriptions.contains("square") || descriptions.contains("rectangle"))
                guard descriptions.contains(expectedColor), shapeMatches,
                      result.insights.contains(where: { $0.source?.lowercased() == "selected screen" }) else {
                    throw AnalysisError.badResponse("Image description or source did not match: \(descriptions)")
                }
                window.close()
                print("PASS owned-window capture -> JPEG -> packaged XPC -> \(providerName); \(jpeg.count) bytes; \(Date().timeIntervalSince(started)) seconds; \(descriptions)")
                exit(0)
            } catch {
                sampler.stop()
                window.close()
                print("FAIL owned-window vision: \(error.localizedDescription)")
                exit(1)
            }
        }
        NSApplication.shared.run()
    }
}

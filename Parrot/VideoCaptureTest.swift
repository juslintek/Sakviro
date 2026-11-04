import AppKit
import AVFoundation
import ScreenCaptureKit

enum VideoCaptureTest {
    static func run() {
        Task { @MainActor in
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 480, height: 270),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Parrot synthetic capture test"
            let label = NSTextField(labelWithString: "Synthetic video capture test")
            label.frame = NSRect(x: 40, y: 110, width: 400, height: 40)
            window.contentView?.addSubview(label)
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            do {
                try await Task.sleep(for: .seconds(1))
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let source = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    throw NSError(domain: "VideoCaptureTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Own test window unavailable to ScreenCaptureKit"])
                }
                let capture = VideoCaptureService()
                try await capture.start(filter: SCContentFilter(desktopIndependentWindow: source), audioOrigin: ProcessInfo.processInfo.systemUptime)
                try await Task.sleep(for: .seconds(3))
                let (url, offset) = try await capture.stop()
                let asset = AVURLAsset(url: url)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                let duration = try await asset.load(.duration).seconds
                guard !tracks.isEmpty, duration > 0, offset >= 0 else {
                    throw NSError(domain: "VideoCaptureTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Captured video has no frames or invalid timing"])
                }
                try FileManager.default.removeItem(at: url)
                window.close()
                print("PASS owned-window ScreenCaptureKit video, duration \(duration), offset \(offset)")
                exit(0)
            } catch {
                window.close()
                print("FAIL owned-window ScreenCaptureKit video: \(error.localizedDescription)")
                exit(1)
            }
        }
        NSApplication.shared.run()
    }
}

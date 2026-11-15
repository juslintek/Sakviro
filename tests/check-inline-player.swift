// Run with a local video: swiftc Parrot/Views/InlineVideoPlayer.swift tests/check-inline-player.swift -o /tmp/inline-player-check && /tmp/inline-player-check /path/to/video.mp4
import AppKit
import AVKit
import SwiftUI

@MainActor
final class PlayerState: ObservableObject {
    @Published var player: AVPlayer?
}

struct PlayerHost: View {
    @ObservedObject var state: PlayerState

    var body: some View {
        if let player = state.player {
            InlineVideoPlayer(player: player)
        }
    }
}

@main
struct InlinePlayerCheck {
    @MainActor
    static func main() async {
        _ = NSApplication.shared
        precondition(CommandLine.arguments.count == 2, "Pass a video file path")
        let first = AVPlayer(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        first.isMuted = true
        let state = PlayerState()
        state.player = first
        let host = NSHostingView(rootView: PlayerHost(state: state))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        func settle() async {
            window.layoutIfNeeded()
            try! await Task.sleep(nanoseconds: 100_000_000)
        }
        func playerView(in view: NSView) -> AVPlayerView? {
            if let playerView = view as? AVPlayerView { return playerView }
            return view.subviews.lazy.compactMap { playerView(in: $0) }.first
        }
        await settle()
        guard let view = playerView(in: host) else { fatalError("Player view was not mounted") }
        precondition(view.player === first && view.player!.isMuted)
        precondition(view.controlsStyle == .inline && view.videoGravity == .resizeAspect)
        first.play()
        let deadline = Date(timeIntervalSinceNow: 5)
        while (first.currentTime().seconds < 0.2 || !view.isReadyForDisplay) && Date() < deadline { await settle() }
        precondition(first.currentTime().seconds >= 0.2, "Video did not advance")
        precondition(view.isReadyForDisplay, "Video was not ready for display")
        first.pause()
        let pauseDeadline = Date(timeIntervalSinceNow: 5)
        while (first.rate != 0 || first.timeControlStatus != .paused) && Date() < pauseDeadline { await settle() }
        precondition(first.rate == 0 && first.timeControlStatus == .paused, "Video did not pause")
        var seekFinished: Bool?
        first.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in seekFinished = finished }
        }
        let seekDeadline = Date(timeIntervalSinceNow: 5)
        while seekFinished == nil && Date() < seekDeadline { await settle() }
        precondition(seekFinished == true && abs(first.currentTime().seconds - 2) < 0.1, "Video seek failed: completion=\(String(describing: seekFinished)), time=\(first.currentTime().seconds), playerStatus=\(first.status.rawValue), itemStatus=\(first.currentItem?.status.rawValue ?? -1), timeControlStatus=\(first.timeControlStatus.rawValue), error=\(String(describing: first.error ?? first.currentItem?.error))")
        let second = AVPlayer()
        state.player = second
        await settle()
        precondition(playerView(in: host) === view && view.player === second, "Player replacement failed")
        state.player = nil
        await settle()
        precondition(playerView(in: host) == nil && view.player == nil, "Player was not detached")
        window.close()
        print("PASS inline player mount, playback, seek, replacement and detach")
    }
}

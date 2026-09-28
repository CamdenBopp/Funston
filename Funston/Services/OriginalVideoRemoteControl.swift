import MediaPlayer

/// Lock Screen, Control Center and headphone controls for the MKV player. AVKit
/// provides these for the film player; the sample-buffer engine does not.
///
/// PlaybackController removes its own targets in `acquireVideoPlayback` and adds
/// them back in `releaseVideoPlayback`. Call `deactivate` before releasing that
/// token, so the audio player's Now Playing update is the one left standing.
@MainActor
final class OriginalVideoRemoteControl {
    enum Command: Equatable {
        case play, pause, toggle
        case seek(to: Double)
        case skip(by: Double)
    }

    static let skipInterval: Double = 15
    private let handler: @MainActor (Command) -> Bool
    private var targets: [(MPRemoteCommand, Any)] = []

    /// `handler` returns false when there is no film to act on.
    init(handler: @escaping @MainActor (Command) -> Bool) { self.handler = handler }

    var isActive: Bool { !targets.isEmpty }

    func activate() {
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        add(center.playCommand) { _ in .play }
        add(center.pauseCommand) { _ in .pause }
        add(center.togglePlayPauseCommand) { _ in .toggle }
        add(center.skipForwardCommand) { _ in .skip(by: Self.skipInterval) }
        add(center.skipBackwardCommand) { _ in .skip(by: -Self.skipInterval) }
        add(center.changePlaybackPositionCommand) { event in
            (event as? MPChangePlaybackPositionCommandEvent).map { .seek(to: $0.positionTime) }
        }
    }

    /// Runs a command exactly as the system's remote target would.
    @discardableResult
    func perform(_ command: Command) -> MPRemoteCommandHandlerStatus {
        handler(command) ? .success : .noActionableNowPlayingItem
    }

    func publish(title: String, elapsed: Double, duration: Double?, rate: Float) {
        guard isActive else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed.isFinite ? max(0, elapsed) : 0,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if let duration = MediaDuration.validated(duration), duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func deactivate() {
        guard !targets.isEmpty else { return }
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        // Leave isEnabled alone. The audio player shares every one of these
        // commands, including toggle for a headset press, and sets its own skip
        // buttons when it republishes.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func add(_ command: MPRemoteCommand, _ map: @escaping @MainActor (MPRemoteCommandEvent) -> Command?) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let mapped = map(event) else { return .commandFailed }
                return self.perform(mapped)
            }
        }
        targets.append((command, target))
    }
}

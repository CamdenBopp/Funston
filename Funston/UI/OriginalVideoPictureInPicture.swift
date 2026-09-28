import AVKit

/// Picture in Picture for the MKV player's sample-buffer layer. AVKit provides
/// this for the film player; here the app answers the system's transport
/// questions itself.
@MainActor
final class OriginalVideoPictureInPicture {
    struct Transport {
        var isPaused: @MainActor () -> Bool
        var setPlaying: @MainActor (Bool) -> Void
        /// Seeks by the interval and calls back once the seek has landed or failed.
        var skip: @MainActor (Double, @escaping @MainActor () -> Void) -> Void
        var duration: @MainActor () -> Double?
        /// Picture in Picture closed while the app was in the background.
        var stoppedInBackground: @MainActor () -> Void
    }

    let controller: AVPictureInPictureController
    // The content source and controller hold their delegates weakly.
    private let bridge: Bridge

    /// Nil when this device can't show Picture in Picture; offer no button then.
    init?(layer: AVSampleBufferDisplayLayer, transport: Transport) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        bridge = Bridge(transport: transport)
        controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: bridge))
        controller.delegate = bridge
    }

    var isActive: Bool { controller.isPictureInPictureActive }

    /// The system asks again after play, pause, seek or a speed change.
    func invalidate() { controller.invalidatePlaybackState() }
    func start() { controller.startPictureInPicture() }
    func stop() { if controller.isPictureInPictureActive { controller.stopPictureInPicture() } }

    nonisolated private static let timescale: CMTimeScale = 600

    /// The scrubber range the system shows: the film's length, or open-ended when
    /// the length is unknown, rather than a wrong one.
    nonisolated static func timeRange(duration: Double?) -> CMTimeRange {
        guard let duration = MediaDuration.validated(duration), duration > 0 else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: timescale))
    }
}

/// The system calls both delegates on the main thread; @preconcurrency checks that at run time.
@MainActor
private final class Bridge: NSObject, @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate,
                            @preconcurrency AVPictureInPictureControllerDelegate {
    let transport: OriginalVideoPictureInPicture.Transport

    init(transport: OriginalVideoPictureInPicture.Transport) { self.transport = transport }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        transport.setPlaying(playing)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        OriginalVideoPictureInPicture.timeRange(duration: transport.duration())
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        transport.isPaused()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime,
                                    completion completionHandler: @escaping @Sendable () -> Void) {
        transport.skip(skipInterval.seconds) { completionHandler() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        if UIApplication.shared.applicationState != .active { transport.stoppedInBackground() }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping @Sendable (Bool) -> Void) {
        // The player stays presented under Picture in Picture; there is nothing to rebuild.
        completionHandler(true)
    }
}

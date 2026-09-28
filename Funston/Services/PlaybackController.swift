import AVFoundation
import Combine
import MediaPlayer
import UIKit

enum PlaybackPhase: Equatable, Sendable {
    case idle
    case preparing
    case playing
    case paused
    case buffering
    case ended
    case failed(String)

    var spokenValue: String {
        switch self {
        case .idle: "Idle"
        case .preparing: "Preparing"
        case .playing: "Playing"
        case .paused: "Paused"
        case .buffering: "Buffering"
        case .ended: "Finished"
        case .failed: "Playback failed"
        }
    }

    func showsPauseControl(wantsToPlay: Bool) -> Bool {
        switch self {
        case .playing, .buffering: true
        case .preparing: wantsToPlay
        default: false
        }
    }
}

struct PlaybackContext: Equatable, Sendable {
    let artifact: ArtifactSummary
    let tracks: [PlayableTrack]
    let trackIndex: Int
    let file: ArchiveFile

    var track: PlayableTrack { tracks[trackIndex] }
}

/// AVAudioSession activation performs synchronous interprocess work. A dedicated
/// serial queue keeps that work off both UIKit and Swift's cooperative executor.
private final class AudioSessionWorker: Sendable {
    static let shared = AudioSessionWorker()
    private let queue = DispatchQueue(label: "Funston audio session", qos: .userInitiated)

    func setActive(_ active: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    if active { try session.setCategory(.playback, mode: .default) }
                    try session.setActive(active, options: active ? [] : .notifyOthersOnDeactivation)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var context: PlaybackContext?
    @Published private(set) var phase: PlaybackPhase = .idle
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double?
    var loadGeneration: UInt64 { generation }

    private let player: AVPlayer
    private let audioSessionActivator: @MainActor () async throws -> Void
    private let audioSessionDeactivator: @MainActor () async -> Void
    private let artworkLoader: @MainActor (URL) async throws -> SendableImage
    private var artworkTask: Task<Void, Never>?
    private var artworkURL: URL?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var audioSessionTail: Task<Void, Never>?
    private var pendingActivationIntent: UInt64?
    private var pendingActivationGeneration: UInt64?
    private let store: SQLiteStore
    private let downloads: DownloadManager
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var persistenceObserver: Any?
    private var visibleProgressObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var remoteCommandTokens: [(MPRemoteCommand, Any)] = []
    private var progressConsumers = 0
    private var generation: UInt64 = 0
    private var intentRevision: UInt64 = 0
    private var positionRevision: UInt64 = 0
    private var persistenceTail: Task<Void, Never>?
    @Published private(set) var wantsToPlay = false
    private var restoringPosition = false
    private var readyGeneration: UInt64?
    private var attemptedFiles = Set<String>()
    private var localLease: URL?
    private var sessionNotifications: [NSObjectProtocol] = []
    private var interruptionGeneration: UInt64?
    private var interrupted = false
    private var videoOwnership: UInt64?

    init(store: SQLiteStore, downloads: DownloadManager, player: AVPlayer = AVPlayer(),
         audioSessionActivator: (@MainActor () async throws -> Void)? = nil,
         audioSessionDeactivator: (@MainActor () async -> Void)? = nil,
         artworkLoader: (@MainActor (URL) async throws -> SendableImage)? = nil) {
        self.store = store
        self.downloads = downloads
        self.player = player
        self.audioSessionActivator = audioSessionActivator ?? {
            try await AudioSessionWorker.shared.setActive(true)
        }
        self.audioSessionDeactivator = audioSessionDeactivator ?? { try? await AudioSessionWorker.shared.setActive(false) }
        self.artworkLoader = artworkLoader ?? { url in
            try await ArtworkPipeline.shared.image(url: url, pointSize: CGSize(width: 768, height: 768), scale: 1)
        }
        configureRemoteCommands()
        configureAudioNotifications()
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateTransportPhase() }
        }
        persistenceObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 15, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveCurrentPosition()
            }
        }
    }

    isolated deinit {
        artworkTask?.cancel()
        audioSessionTail?.cancel()
        if let persistenceObserver { player.removeTimeObserver(persistenceObserver) }
        if let visibleProgressObserver { player.removeTimeObserver(visibleProgressObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        sessionNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        player.replaceCurrentItem(with: nil)
        if let localLease { downloads.releaseLocalURL(localLease) }
        for (command, token) in remoteCommandTokens { command.removeTarget(token) }
    }

    func load(artifact: ArtifactSummary, tracks: [PlayableTrack], trackIndex: Int, autoplay: Bool = true) {
        guard videoOwnership == nil else { return }
        guard tracks.indices.contains(trackIndex) else {
            phase = .failed("No supported audio file is available.")
            return
        }
        attemptedFiles.removeAll()
        wantsToPlay = autoplay
        intentRevision &+= 1
        let selectedTrack = tracks[trackIndex]
        let localFile = selectedTrack.candidates.first {
            downloads.completedLocalURL(identifier: artifact.identifier, fileName: $0.name) != nil
        }
        guard let file = localFile ?? selectedTrack.preferredFile else {
            phase = .failed("No supported audio file is available.")
            return
        }
        saveCurrentPosition()
        install(artifact: artifact, tracks: tracks, trackIndex: trackIndex, file: file)
    }

    func playDownloaded(_ record: DownloadRecord, autoplay: Bool = true) {
        guard record.state == .completed,
              downloads.completedLocalURL(identifier: record.identifier, fileName: record.fileName)?.path == record.localPath,
              ["mp3", "m4a", "aac", "wav", "aiff", "aif"].contains((record.fileName as NSString).pathExtension.lowercased()) else {
            phase = .failed("This downloaded file is not available for audio playback.")
            return
        }
        let file = ArchiveFile(name: record.fileName, size: record.expectedBytes)
        let track = PlayableTrack(id: record.fileName, title: (record.fileName as NSString).lastPathComponent, candidates: [file])
        load(artifact: ArtifactSummary(identifier: record.identifier, title: record.title, mediaType: .audio), tracks: [track], trackIndex: 0, autoplay: autoplay)
    }

    private func install(artifact: ArtifactSummary, tracks: [PlayableTrack], trackIndex: Int, file: ArchiveFile, resumeOverride: Double? = nil) {
        generation &+= 1
        let currentGeneration = generation
        attemptedFiles.insert(file.name)
        readyGeneration = nil
        restoringPosition = true
        let nextContext = PlaybackContext(
            artifact: artifact,
            tracks: tracks,
            trackIndex: trackIndex,
            file: file
        )
        context = nextContext
        loadNowPlayingArtwork(for: artifact)
        elapsed = 0
        duration = MediaDuration.validated(tracks[trackIndex].duration ?? file.duration)
        phase = .preparing

        let oldLease = localLease
        localLease = downloads.acquireLocalURL(identifier: artifact.identifier, fileName: file.name)
        let url = localLease
            ?? ArchiveURLs.download(identifier: artifact.identifier, fileName: file.name)
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        player.pause()
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        // AVPlayer releases its old item before a removed file's lease is released.
        if let oldLease { downloads.releaseLocalURL(oldLease) }
        observe(item: item, generation: currentGeneration, resumeOverride: resumeOverride)
        updateNowPlaying()
    }

    func togglePlayback() {
        if phase.showsPauseControl(wantsToPlay: wantsToPlay) { pause() }
        else { play() }
    }

    func play() {
        guard videoOwnership == nil else { return }
        guard player.currentItem != nil else { return }
        if case .failed = phase, let context {
            load(artifact: context.artifact, tracks: context.tracks, trackIndex: context.trackIndex)
            return
        }
        wantsToPlay = true
        intentRevision &+= 1
        guard !interrupted, !restoringPosition else { return }
        if phase == .ended {
            let currentGeneration = generation
            let currentIntent = intentRevision
            let currentPositionRevision = positionRevision
            Task { @MainActor in
                let completed = await player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                guard completed, currentGeneration == generation, currentIntent == intentRevision,
                      currentPositionRevision == positionRevision, wantsToPlay else { return }
                elapsed = 0
                persist(seconds: 0)
                phase = .paused
                startPlaybackIfAllowed()
            }
        } else { startPlaybackIfAllowed() }
    }

    private func startPlaybackIfAllowed() {
        guard wantsToPlay, !interrupted, !restoringPosition,
              let item = player.currentItem, item.status == .readyToPlay,
              pendingActivationIntent != intentRevision || pendingActivationGeneration != generation else { return }
        let expectedGeneration = generation, expectedIntent = intentRevision
        pendingActivationIntent = expectedIntent
        pendingActivationGeneration = expectedGeneration
        phase = .preparing
        let previous = audioSessionTail
        audioSessionTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            defer {
                if self.pendingActivationIntent == expectedIntent && self.pendingActivationGeneration == expectedGeneration {
                    self.pendingActivationIntent = nil; self.pendingActivationGeneration = nil
                }
            }
            guard !Task.isCancelled, self.canStart(generation: expectedGeneration, intent: expectedIntent, item: item) else { return }
            do {
                try await self.audioSessionActivator()
                guard !Task.isCancelled, self.canStart(generation: expectedGeneration, intent: expectedIntent, item: item) else { return }
                self.player.play()
                self.updateTransportPhase()
                self.updateNowPlaying()
            } catch {
                guard !Task.isCancelled, self.canStart(generation: expectedGeneration, intent: expectedIntent, item: item) else { return }
                self.phase = .failed("Audio is unavailable right now.")
                self.wantsToPlay = false
                self.updateNowPlaying()
            }
        }
    }

    private func canStart(generation expectedGeneration: UInt64, intent expectedIntent: UInt64, item: AVPlayerItem) -> Bool {
        generation == expectedGeneration && intentRevision == expectedIntent && wantsToPlay &&
        !interrupted && !restoringPosition && player.currentItem === item && item.status == .readyToPlay
    }

    func pause() {
        guard videoOwnership == nil else { return }
        wantsToPlay = false
        intentRevision &+= 1
        player.pause()
        phase = .paused
        saveCurrentPosition()
        updateNowPlaying()
        deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        guard videoOwnership == nil else { return }
        let previous = audioSessionTail
        let deactivate = audioSessionDeactivator
        audioSessionTail = Task { @MainActor in
            await previous?.value
            await deactivate()
        }
    }

    /// Complete audio-session handoff before another media controller starts.
    func pauseAndDeactivate() async -> Bool {
        pause()
        let revision = intentRevision
        await audioSessionTail?.value
        return revision == intentRevision && !wantsToPlay
    }

    /// The fullscreen video viewer owns transport and the audio session until it
    /// releases this token. Audio notifications/remote callbacks must not fight AVKit.
    func acquireVideoPlayback() async throws -> UInt64? {
        guard videoOwnership == nil else { return nil }
        pause()
        let token = intentRevision
        videoOwnership = token
        for (command, target) in remoteCommandTokens { command.removeTarget(target) }
        remoteCommandTokens.removeAll()
        let previous = audioSessionTail
        var failure: (any Error)?
        audioSessionTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.videoOwnership == token else { return }
            do { try await self.audioSessionActivator() }
            catch { failure = error }
        }
        await audioSessionTail?.value
        guard videoOwnership == token else { return nil }
        if let failure { releaseVideoPlayback(token); throw failure }
        return token
    }

    func releaseVideoPlayback(_ token: UInt64) {
        guard videoOwnership == token else { return }
        videoOwnership = nil
        configureRemoteCommands()
        pause()
    }

    func seek(to seconds: Double) {
        guard videoOwnership == nil else { return }
        guard seconds.isFinite, let seconds = MediaDuration.validated(max(0, seconds)) else { return }
        positionRevision &+= 1
        let upperBound = duration ?? seconds
        let target = min(max(0, seconds), max(0, upperBound))
        if phase == .ended, duration.map({ target < $0 }) ?? true {
            phase = .paused
            wantsToPlay = false
        }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = target
        updateNowPlaying()
    }

    func skip(by seconds: Double) {
        seek(to: currentSeconds + seconds)
    }

    func nextTrack() {
        guard videoOwnership == nil else { return }
        guard let context else { return }
        let nextIndex = context.trackIndex + 1
        // A temporary zero player rate during preparation is not a Pause request.
        // Preserve explicit intent across every item replacement, including rapid skips.
        guard context.tracks.indices.contains(nextIndex) else { return }
        load(artifact: context.artifact, tracks: context.tracks, trackIndex: nextIndex, autoplay: wantsToPlay)
    }

    func previousTrack() {
        guard videoOwnership == nil else { return }
        guard let context else { return }
        if currentSeconds > 5 {
            seek(to: 0)
            return
        }
        let previousIndex = context.trackIndex - 1
        guard context.tracks.indices.contains(previousIndex) else {
            seek(to: 0)
            return
        }
        load(artifact: context.artifact, tracks: context.tracks, trackIndex: previousIndex, autoplay: wantsToPlay)
    }

    func beginVisibleProgress() {
        progressConsumers += 1
        guard progressConsumers == 1 else { return }
        visibleProgressObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 2),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.elapsed = self.currentSeconds
                let seconds = self.player.currentItem?.duration.seconds
                if let seconds = MediaDuration.validated(seconds), seconds > 0 { self.duration = seconds }
            }
        }
    }

    func endVisibleProgress() {
        progressConsumers = max(0, progressConsumers - 1)
        guard progressConsumers == 0, let visibleProgressObserver else { return }
        player.removeTimeObserver(visibleProgressObserver)
        self.visibleProgressObserver = nil
    }

    func appDidEnterBackground() {
        saveCurrentPosition()
    }

    func currentFileIsLocal(_ record: DownloadRecord) -> Bool {
        localLease?.path == record.localPath
    }

    private func observe(item: AVPlayerItem, generation expectedGeneration: UInt64, resumeOverride: Double?) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == expectedGeneration else { return }
                self.advanceAfterEnd()
            }
        }
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item, self.generation == expectedGeneration else { return }
                switch item.status {
                case .readyToPlay:
                    guard self.readyGeneration != expectedGeneration else { return }
                    self.readyGeneration = expectedGeneration
                    let revision = self.positionRevision
                    let identifier = self.context?.artifact.identifier ?? ""
                    let fileName = self.context?.file.name ?? ""
                    // Item replacement may become ready before older queued
                    // bookmark writes finish. Restore the latest committed intent.
                    await self.persistenceTail?.value
                    guard self.generation == expectedGeneration, self.player.currentItem === item else { return }
                    let saved = (try? await self.store.playbackPosition(
                        identifier: identifier,
                        fileName: fileName
                    )) ?? 0
                    guard self.generation == expectedGeneration, self.player.currentItem === item else { return }
                    let itemDuration = item.duration.seconds
                    let position = Self.restoredPosition(resumeOverride ?? saved, duration: itemDuration)
                    if position > 0, self.positionRevision == revision {
                        _ = await self.player.seek(
                            to: CMTime(seconds: position, preferredTimescale: 600),
                            toleranceBefore: .zero,
                            toleranceAfter: .zero
                        )
                        guard self.generation == expectedGeneration, self.player.currentItem === item else { return }
                        self.elapsed = self.currentSeconds
                    }
                    if let itemDuration = MediaDuration.validated(itemDuration), itemDuration > 0 { self.duration = itemDuration }
                    self.restoringPosition = false
                    if self.wantsToPlay { self.startPlaybackIfAllowed() } else { self.phase = .paused; self.updateNowPlaying() }
                case .failed:
                    self.handleItemFailure(item.error?.localizedDescription ?? "This track could not be played.")
                case .unknown:
                    self.phase = .preparing
                @unknown default:
                    self.phase = .failed("This track could not be played.")
                }
            }
        }
    }

    private func handleItemFailure(_ message: String) {
        guard let context else { return }
        let candidates = context.track.candidates.filter { !attemptedFiles.contains($0.name) }
        if attemptedFiles.count < 3,
           let next = candidates.first(where: { downloads.completedLocalURL(identifier: context.artifact.identifier, fileName: $0.name) != nil }) ?? candidates.first {
            let position = currentSeconds
            install(artifact: context.artifact, tracks: context.tracks, trackIndex: context.trackIndex, file: next, resumeOverride: position > 0 ? position : nil)
            return
        }
        restoringPosition = false
        wantsToPlay = false
        intentRevision &+= 1
        player.pause()
        phase = .failed(message)
        deactivateAudioSession()
        updateNowPlaying()
        UIAccessibility.post(notification: .announcement, argument: "Playback failed. The track remains selected.")
    }

    private var currentSeconds: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    nonisolated static func restoredPosition(_ seconds: Double, duration: Double) -> Double {
        guard let seconds = MediaDuration.validated(seconds), seconds > 0 else { return 0 }
        if duration.isFinite, duration > 0, seconds >= duration - 1 { return 0 }
        return seconds
    }

    private func updateTransportPhase() {
        guard videoOwnership == nil, context != nil, !restoringPosition else { return }
        if case .failed = phase { return }
        if phase == .ended { return }
        if interrupted || !wantsToPlay { phase = .paused }
        else {
            switch player.timeControlStatus {
            case .playing: phase = .playing
            case .waitingToPlayAtSpecifiedRate: phase = .buffering
            case .paused:
                phase = pendingActivationIntent == intentRevision && pendingActivationGeneration == generation ? .preparing : .paused
            @unknown default: phase = .paused
            }
        }
        updateNowPlaying()
    }

    private func configureAudioNotifications() {
        sessionNotifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            MainActor.assumeIsolated {
                guard let self, let type else { return }
                if self.videoOwnership != nil {
                    // Keep the shared interruption fact current, but let AVKit
                    // handle video transport. Otherwise an interruption ending
                    // during video can leave the audio player permanently blocked.
                    self.interrupted = type == AVAudioSession.InterruptionType.began.rawValue
                    self.interruptionGeneration = nil
                    return
                }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.interrupted = true
                    self.interruptionGeneration = self.wantsToPlay ? self.generation : nil
                    self.player.pause(); self.saveCurrentPosition(); self.updateTransportPhase()
                } else {
                    self.interrupted = false
                    let resume = self.interruptionGeneration == self.generation && self.wantsToPlay && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    self.interruptionGeneration = nil
                    if resume { self.startPlaybackIfAllowed() } else { self.pause() }
                }
            }
        })
        sessionNotifications.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            MainActor.assumeIsolated {
                if self?.videoOwnership == nil, reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
    }

    private func advanceAfterEnd() {
        guard videoOwnership == nil else { return }
        phase = .ended
        persist(seconds: 0)
        if let context, context.trackIndex + 1 < context.tracks.count {
            nextTrack()
        } else {
            player.pause()
            wantsToPlay = false
            intentRevision &+= 1
            deactivateAudioSession()
            updateNowPlaying()
        }
    }

    private func saveCurrentPosition() {
        guard !restoringPosition else { return }
        persist(seconds: player.currentTime().seconds)
    }

    private func persist(seconds: Double) {
        guard let context, seconds.isFinite else { return }
        let bookmark = PlaybackBookmark(
            identifier: context.artifact.identifier,
            fileName: context.file.name,
            seconds: phase == .ended ? 0 : max(0, seconds)
        )
        let previous = persistenceTail
        persistenceTail = Task {
            await previous?.value
            try? await store.setPlaybackPosition(
                identifier: bookmark.identifier,
                fileName: bookmark.fileName,
                seconds: bookmark.seconds
            )
            try? await store.setLastPlayback(bookmark)
        }
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        remoteCommandTokens.append((center.playCommand, center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }))
        remoteCommandTokens.append((center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }))
        remoteCommandTokens.append((center.nextTrackCommand, center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.nextTrack() }
            return .success
        }))
        remoteCommandTokens.append((center.previousTrackCommand, center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previousTrack() }
            return .success
        }))
        center.changePlaybackPositionCommand.isEnabled = true
        remoteCommandTokens.append((
            center.changePlaybackPositionCommand,
            center.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                Task { @MainActor in self?.seek(to: event.positionTime) }
                return .success
            }
        ))
    }

    private func loadNowPlayingArtwork(for artifact: ArtifactSummary) {
        let url = artifact.artworkURL
        // Tracks from one artifact share artwork; transport/progress updates do no image work.
        guard artworkURL != url else { return }
        artworkTask?.cancel()
        artworkURL = url
        nowPlayingArtwork = nil
        let loader = artworkLoader
        artworkTask = Task { [weak self] in
            guard let image = try? await loader(url), !Task.isCancelled,
                  let self, self.artworkURL == url else { return }
            // The pipeline decodes off-main and caps resolution. The system's callback
            // only returns that immutable image: no I/O, decoding, or resizing per request.
            // MediaPlayer calls this on its own access queue. Explicit @Sendable
            // prevents the closure from inheriting this task's MainActor isolation.
            let requestHandler: @Sendable (CGSize) -> UIImage = { _ in image.value }
            self.nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.value.size, requestHandler: requestHandler)
            self.artworkTask = nil
            self.updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard videoOwnership == nil else { return }
        guard let context else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: context.track.title,
            MPMediaItemPropertyAlbumTitle: context.artifact.title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate
        ]
        if let creator = context.artifact.creators.first {
            info[MPMediaItemPropertyArtist] = creator
        }
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = nowPlayingArtwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

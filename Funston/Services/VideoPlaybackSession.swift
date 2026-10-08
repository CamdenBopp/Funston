import AVFoundation
import Combine
import UIKit

/// AVKit owns transport. This session owns only source lifetime, preparation,
/// bookmarks, and the exclusive handoff from the app's audio player.
@MainActor
final class VideoPlaybackSession: ObservableObject {
    enum State: Equatable {
        case idle, loading, ready
        case failed(String)
    }
    enum Source { case archive, downloadedOnly }

    @Published private(set) var state: State = .idle
    let player: AVPlayer
    let summary: ArtifactSummary
    let file: ArchiveFile
    private let source: Source
    private let store: SQLiteStore
    private let downloads: DownloadManager
    private let acquireAudio: @MainActor () async throws -> UInt64?
    private let releaseAudio: @MainActor (UInt64) -> Void
    private var ownership: UInt64?
    private var lease: URL?
    private var generation: UInt64 = 0
    private var preparation: Task<Void, Never>?
    private var restoration: Task<Void, Never>?
    private var persistence: Task<Void, Never>?
    private var observation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var progressObserver: Any?
    private var notifications: [NSObjectProtocol] = []
    private var restoring = true
    private var ended = false

    init(summary: ArtifactSummary, file: ArchiveFile, source: Source = .archive,
         store: SQLiteStore, downloads: DownloadManager, player: AVPlayer = AVPlayer(),
         acquireAudio: @escaping @MainActor () async throws -> UInt64?,
         releaseAudio: @escaping @MainActor (UInt64) -> Void) {
        self.summary = summary; self.file = file; self.source = source
        self.store = store; self.downloads = downloads; self.player = player
        self.acquireAudio = acquireAudio; self.releaseAudio = releaseAudio
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                if self.player.rate == 0 { self.savePosition() }
                else { self.ended = false }
            }
        }
        progressObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 15, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        }
        notifications.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePosition() }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            let item = note.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.ended = true; self.savePosition()
            }
        })
    }

    isolated deinit {
        preparation?.cancel(); restoration?.cancel()
        if let progressObserver { player.removeTimeObserver(progressObserver) }
        notifications.forEach(NotificationCenter.default.removeObserver)
        player.pause(); player.replaceCurrentItem(with: nil)
        if let lease { downloads.releaseLocalURL(lease) }
        if let ownership { releaseAudio(ownership) }
    }

    func start() {
        stop()
        guard !summary.isAccessRestricted else { state = .failed("This item is unavailable."); return }
        let expected = generation
        state = .loading
        restoring = true; ended = false
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                guard let token = try await acquireAudio() else {
                    guard generation == expected, !Task.isCancelled else { return }
                    state = .failed("Another player is using audio. Close it and try again.")
                    return
                }
                guard generation == expected, !Task.isCancelled else { releaseAudio(token); return }
                ownership = token
                await downloads.waitUntilReady()
                guard generation == expected, !Task.isCancelled else { return }
                lease = downloads.acquireLocalURL(identifier: summary.identifier, fileName: file.name)
                if source == .downloadedOnly && lease == nil {
                    fail("This download is no longer available. Download the film again from its artifact page.")
                    return
                }
                let url = lease ?? ArchiveURLs.download(identifier: summary.identifier, fileName: file.name)
                let item = AVPlayerItem(url: url)
                let title = AVMutableMetadataItem()
                title.identifier = .commonIdentifierTitle; title.value = ArchiveMediaTitle.readable(file.name) as NSString
                title.extendedLanguageTag = "und"
                item.externalMetadata = [title]
                Task { [weak self, weak item] in
                    guard let self, let image = try? await ArtworkPipeline.shared.image(url: summary.artworkURL, pointSize: CGSize(width: 512, height: 512), scale: 1),
                          let item, player.currentItem === item, let data = image.value.jpegData(compressionQuality: 0.85) else { return }
                    let artwork = AVMutableMetadataItem()
                    artwork.identifier = .commonIdentifierArtwork
                    artwork.value = data as NSData
                    item.externalMetadata = [title, artwork]
                }
                observation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    Task { @MainActor in self?.receive(item, generation: expected) }
                }
                player.replaceCurrentItem(with: item)
                receive(item, generation: expected)
            } catch {
                guard generation == expected, !Task.isCancelled else { return }
                fail("Audio could not be started. Try again. Your saved position is unchanged.")
            }
        }
    }

    private func receive(_ item: AVPlayerItem, generation expected: UInt64) {
        guard generation == expected, player.currentItem === item else { return }
        switch item.status {
        case .readyToPlay:
            guard restoration == nil else { return }
            restoration = Task { [weak self] in
                guard let self else { return }
                await persistence?.value
                let saved = (try? await store.playbackPosition(identifier: summary.identifier, fileName: file.name)) ?? 0
                guard generation == expected, !Task.isCancelled, player.currentItem === item else { return }
                let position = PlaybackController.restoredPosition(saved, duration: item.duration.seconds)
                if position > 0 {
                    _ = await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
                guard generation == expected, !Task.isCancelled, player.currentItem === item else { return }
                restoring = false
                state = .ready
                player.play()
            }
        case .failed:
            fail("This film could not be played. Check your connection or choose another file. Your saved position is kept.")
        default: break
        }
    }

    private func fail(_ message: String) {
        stop()
        state = .failed(message)
    }

    func savePosition() {
        guard !restoring, let seconds = MediaDuration.validated(player.currentTime().seconds) else { return }
        let position = ended ? 0 : seconds
        let previous = persistence
        let store = store, identifier = summary.identifier, fileName = file.name
        persistence = Task {
            await previous?.value
            try? await store.setPlaybackPosition(identifier: identifier, fileName: fileName, seconds: position)
        }
    }

    func stop() {
        savePosition()
        generation &+= 1
        preparation?.cancel(); preparation = nil
        restoration?.cancel(); restoration = nil
        observation = nil
        restoring = true
        // State subscribers detach AVKit synchronously before releasing its item/lease.
        state = .idle
        player.pause(); player.replaceCurrentItem(with: nil)
        if let lease { downloads.releaseLocalURL(lease); self.lease = nil }
        if let ownership { releaseAudio(ownership); self.ownership = nil }
    }
}

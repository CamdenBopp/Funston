import UIKit
import AVFoundation
import AVKit
import ArchivePlayerCore

/// Keeps timed text beside the demux clock without treating subtitles as audio/video samples.
private actor OriginalCaptionDemuxer: Demuxer {
    private let base: MatroskaDemuxer
    private var mediaTracks: [MediaTrack] = []
    private var captions = CaptionPipeline()
    private var captionFailures = Set<UInt32>()
    init(source: any ByteSource) { base = MatroskaDemuxer(source: source) }
    func tracks() async throws -> [MediaTrack] {
        if mediaTracks.isEmpty { mediaTracks = try await base.tracks() }
        return mediaTracks
    }
    func nextPacket() async throws -> DemuxedPacket? {
        guard let packet = try await base.nextPacket() else { return nil }
        if let track = mediaTracks.first(where: { $0.id == packet.trackID && $0.kind == .subtitle }),
           CaptionPipeline.supportedCodecs.contains(track.codec) {
            do { try captions.ingest(packet, track: track) }
            catch { captionFailures.insert(track.id) }
        }
        return packet
    }
    func seek(to time: CMTime) async throws {
        try await base.seek(to: time)
        captions.reset(); captionFailures.removeAll()
    }
    func text(at time: CMTime, trackID: UInt32?) -> (String, Bool) {
        captions.prune(endingBefore: time)
        guard let trackID else { return ("", false) }
        return (captions.activeCues(at: time, trackID: trackID).map(\.text).joined(separator: "\n"), captionFailures.contains(trackID))
    }
}

/// MKV originals use the custom sample-buffer path. MP4/MOV remain in AVKit.
@MainActor
final class ArtifactOriginalVideoController: UIViewController {
    private let summary: ArtifactSummary
    private let file: ArchiveFile
    private let environment: AppEnvironment
    private let downloadedOnly: Bool
    private let bookmark: OriginalVideoBookmark
    private let trackMemory: OriginalVideoTrackMemory
    private static let seekTimescale: CMTimeScale = 1_000
    private var engine: SampleBufferPlaybackEngine?
    private var remote: OriginalVideoRemoteControl?
    private var pictureInPicture: OriginalVideoPictureInPicture?
    private var captionDemuxer: OriginalCaptionDemuxer?
    private var lease: URL?
    private var audioOwnership: UInt64?
    private var preparation: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var notifications: [NSObjectProtocol] = []
    private var closing = false
    private var busy = false
    private var interruptionPauseRequested = false
    private var rate: Float = 1
    private var selectedCaption: UInt32?
    private var lastInteraction = Date()
    private let canvas = UIView()
    private let chrome = OriginalVideoControlsView()
    private let captionLabel = UILabel()
    private var captionsAboveControls: NSLayoutConstraint?
    private var captionsAtBottom: NSLayoutConstraint?
    private var audioMenu: UIMenu?
    private var subtitlesMenu: UIMenu?
    private var speedMenu: UIMenu?
    private static let controlsFadeDelay: TimeInterval = 5
    private static let controlsFadeDuration: TimeInterval = 0.25
    private static let captionBottomMargin: CGFloat = 24
    private static let captionBackgroundOpacity: CGFloat = 0.75
    private static let captionCornerRadius: CGFloat = 4

    init(summary: ArtifactSummary, file: ArchiveFile, environment: AppEnvironment, downloadedOnly: Bool) {
        self.summary = summary; self.file = file; self.environment = environment; self.downloadedOnly = downloadedOnly
        bookmark = OriginalVideoBookmark(store: environment.store, identifier: summary.identifier, fileName: file.name) {
            try? await environment.downloads.removePlayedDownload(identifier: summary.identifier, fileName: file.name)
        }
        let speedPreference = PlaybackSpeedPreference()
        let collection = summary.collections.first
        rate = Float(collection.map { speedPreference.hasOverride(collection: $0) } == true ? speedPreference.rate(collection: collection) : environment.settings.defaultPlaybackSpeed)
        trackMemory = OriginalVideoTrackMemory(store: environment.store, identifier: summary.identifier, fileName: file.name)
        super.init(nibName: nil, bundle: nil)
        title = summary.title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Read-only view of the engine for tests.
    var playbackEngine: SampleBufferPlaybackEngine? { engine }
    /// Lock Screen and headphone controls; nil until the view loads.
    var remoteControl: OriginalVideoRemoteControl? { remote }
    var selectedCaptionTrackID: UInt32? { selectedCaption }
    /// Nil until the film is ready, and always nil where Picture in Picture isn't supported.
    var pictureInPictureSupport: OriginalVideoPictureInPicture? { pictureInPicture }
    var videoSurface: UIView { canvas }
    var controlsShown: Bool { chrome.alpha == 1 && !chrome.accessibilityElementsHidden }
    var trackMenus: (audio: UIMenu?, captions: UIMenu?, speed: UIMenu?) { (audioMenu, subtitlesMenu, speedMenu) }
    var controls: OriginalVideoControlsView { chrome }
    /// True until the film has handed audio back to the audio player.
    var holdsPlayback: Bool { audioOwnership != nil }

    isolated deinit {
        preparation?.cancel(); operation?.cancel(); ticker?.cancel()
        notifications.forEach(NotificationCenter.default.removeObserver)
        remote?.deactivate()
        let engine = engine, lease = lease, token = audioOwnership, environment = environment
        Task { @MainActor in
            await engine?.stop()
            if let lease { environment.downloads.releaseLocalURL(lease) }
            if let token { environment.playback.releaseVideoPlayback(token) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.accessibilityIdentifier = "original.video.viewer"
        remote = OriginalVideoRemoteControl(skipBack: Double(environment.settings.skipBackSeconds), skipForward: Double(environment.settings.skipForwardSeconds)) { [weak self] command in self?.handleRemote(command) ?? false }
        chrome.configureSkipIntervals(back: environment.settings.skipBackSeconds, forward: environment.settings.skipForwardSeconds)
        navigationItem.largeTitleDisplayMode = .never
        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        canvas.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(canvasTapped)))
        // The controls fade while the film plays. From the film itself, VoiceOver
        // can bring them back and land on Play without hunting for them.
        canvas.isAccessibilityElement = true
        canvas.accessibilityLabel = "Video"
        canvas.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Show playback controls") { [weak self] _ in
            guard let self else { return false }
            self.showControls()
            UIAccessibility.post(notification: .layoutChanged, argument: self.chrome.playButton)
            return true
        }]
        captionLabel.font = .preferredFont(forTextStyle: .title3)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.numberOfLines = 0; captionLabel.textAlignment = .center
        captionLabel.textColor = .white
        captionLabel.backgroundColor = UIColor.black.withAlphaComponent(Self.captionBackgroundOpacity)
        captionLabel.layer.cornerRadius = Self.captionCornerRadius
        captionLabel.clipsToBounds = true
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.accessibilityLabel = "Subtitles"
        chrome.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(captionLabel)
        view.addSubview(chrome)
        chrome.setTitle(summary.title)
        chrome.setTime(elapsed: 0, duration: file.duration)
        chrome.closeButton.addAction(UIAction { [weak self] _ in self?.close() }, for: .primaryActionTriggered)
        chrome.playButton.addAction(UIAction { [weak self] _ in self?.togglePlayback() }, for: .primaryActionTriggered)
        chrome.backButton.addAction(UIAction { [weak self] _ in if let self { self.seek(by: -Double(self.environment.settings.skipBackSeconds)) } }, for: .primaryActionTriggered)
        chrome.forwardButton.addAction(UIAction { [weak self] _ in if let self { self.seek(by: Double(self.environment.settings.skipForwardSeconds)) } }, for: .primaryActionTriggered)
        chrome.muteButton.addAction(UIAction { [weak self] _ in self?.toggleMute() }, for: .primaryActionTriggered)
        chrome.pictureInPictureButton.addAction(UIAction { [weak self] _ in
            guard let pictureInPicture = self?.pictureInPicture else { return }
            if pictureInPicture.isActive { pictureInPicture.stop() } else { pictureInPicture.start() }
        }, for: .primaryActionTriggered)
        chrome.scrubber.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.showControls()
            self.chrome.setTime(elapsed: self.chrome.scrubber.position, duration: self.file.duration)
        }, for: .valueChanged)
        chrome.scrubber.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.seek(to: self.chrome.scrubber.position)
        }, for: .primaryActionTriggered)
        chrome.setPictureInPictureAvailable(false)
        captionsAboveControls = captionLabel.bottomAnchor.constraint(equalTo: chrome.captionsGuide.bottomAnchor)
        captionsAtBottom = captionLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Self.captionBottomMargin)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.topAnchor), canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            chrome.leadingAnchor.constraint(equalTo: view.leadingAnchor), chrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: view.topAnchor), chrome.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            captionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: chrome.captionsGuide.leadingAnchor),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: chrome.captionsGuide.trailingAnchor),
            captionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            captionsAboveControls
        ].compactMap { $0 })
        setEnabled(false)
        observe(UIAccessibility.voiceOverStatusDidChangeNotification) { [weak self] in self?.showControls() }
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] in
            // Picture in Picture keeps the film playing outside the app.
            if self?.pictureInPicture?.isActive != true { self?.pauseForInterruption() }
            self?.savePosition()
        }
        observe(AVAudioSession.interruptionNotification) { [weak self] in self?.pauseForInterruption() }
        observe(AVAudioSession.routeChangeNotification) { [weak self] in self?.pauseForInterruption() }
        start()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(contentUnavailableConfiguration == nil, animated: false)
    }

    override var prefersStatusBarHidden: Bool { controlsHidden }
    override var prefersHomeIndicatorAutoHidden: Bool { controlsHidden }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    private var controlsHidden = false {
        didSet { setNeedsStatusBarAppearanceUpdate(); setNeedsUpdateOfHomeIndicatorAutoHidden() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        engine?.displayLayer?.frame = canvas.bounds
    }

    override func accessibilityPerformEscape() -> Bool { close(); return true }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent { finish() }
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor @Sendable () -> Void) {
        notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        })
    }

    private func start() {
        guard !closing, preparation == nil else { return }
        view.backgroundColor = .black
        contentUnavailableConfiguration = nil
        navigationController?.setNavigationBarHidden(true, animated: false)
        canvas.isHidden = true; chrome.isHidden = false; captionLabel.text = nil
        interruptionPauseRequested = false
        chrome.setNotice(nil)
        chrome.setTransport(.loading)
        showControls()
        UIAccessibility.post(notification: .announcement, argument: "Opening film")
        preparation = Task { [weak self] in
            guard let self else { return }
            defer { self.preparation = nil }
            do {
                guard let token = try await environment.playback.acquireVideoPlayback() else {
                    throw DemuxError.unsupported("Another player is using audio. Close it and try again.")
                }
                audioOwnership = token
                try Task.checkCancellation()
                await environment.downloads.waitUntilReady()
                try Task.checkCancellation()
                lease = environment.downloads.acquireLocalURL(identifier: summary.identifier, fileName: file.name)
                if downloadedOnly && lease == nil { throw DemuxError.unsupported("This download is no longer available. Download the film again.") }
                let source: any ByteSource
                if let lease { source = try LocalByteSource(url: lease) }
                else { source = HTTPRangeByteSource(url: ArchiveURLs.download(identifier: summary.identifier, fileName: file.name), session: ArchiveNetworkPolicy.session) }
                let adapter = OriginalCaptionDemuxer(source: source)
                captionDemuxer = adapter
                let playback = SampleBufferPlaybackEngine(demuxer: adapter)
                engine = playback
                playback.onStateChange = { [weak self] state in self?.stateChanged(state) }
                try await playback.prepare()
                try Task.checkCancellation()
                guard !closing else { throw CancellationError() }
                guard playback.selectedVideoTrackID != nil else { throw DemuxError.unsupported("The video format in this file cannot be played. Choose another version of the film.") }
                if let layer = playback.displayLayer { layer.videoGravity = .resizeAspect; canvas.layer.addSublayer(layer); layer.frame = canvas.bounds }
                // Tracks first: a track change before the first packet does not seek,
                // so the restore seek below stays the last word on position.
                let playable = Set(playback.tracks.map(\.id)).subtracting(playback.unsupportedTracks.map(\.id))
                let remembered = await trackMemory.startingChoices(
                    tracks: playback.tracks, playableAudio: { playable.contains($0.id) },
                    playableCaption: { CaptionPipeline.supportedCodecs.contains($0.codec) })
                try Task.checkCancellation()
                switch remembered.audio {
                case .track(let id) where id != playback.selectedAudioTrackID:
                    try await playback.selectTracks(audio: id, video: playback.selectedVideoTrackID)
                case .off where playback.selectedAudioTrackID != nil && playback.selectedVideoTrackID != nil:
                    try await playback.selectTracks(audio: nil, video: playback.selectedVideoTrackID)
                default: break
                }
                if case .track(let id) = remembered.caption { selectedCaption = id }
                try await bookmark.restore(duration: self.file.duration) { seconds in
                    try await playback.seek(to: CMTime(seconds: seconds, preferredTimescale: Self.seekTimescale))
                }
                try Task.checkCancellation()
                guard !closing else { throw CancellationError() }
                canvas.isHidden = false
                rebuildMenus(); setEnabled(true); chrome.setMuted(isMuted)
                remote?.activate()
                if let layer = playback.displayLayer { installPictureInPicture(layer: layer) }
                if interruptionPauseRequested { chrome.setTransport(.paused) }
                else { try playback.play(rate: rate) }
                startTicker(); showControls(); publishNowPlaying()
            } catch {
                await releasePlayback()
                if !closing && !(error is CancellationError) { showFailure(error) }
            }
        }
    }

    private func stateChanged(_ state: SampleBufferPlaybackState) {
        guard !closing else { return }
        switch state {
        case .failed(let message): showFailure(DemuxError.unsupported(message))
        case .playing, .finishedEnqueuing:
            chrome.setTransport(.playing)
            let silent = engine?.selectedAudioTrackID == nil
            if silent, chrome.noticeLabel.text == nil {
                UIAccessibility.post(notification: .announcement, argument: Self.silentNotice)
            }
            chrome.setNotice(silent ? Self.silentNotice : nil)
        case .paused:
            chrome.setTransport(.paused); showControls(); savePosition()
        case .ended:
            chrome.setTransport(.ended); showControls(); savePosition()
        default: break
        }
        publishNowPlaying()
        pictureInPicture?.invalidate()
    }

    /// What Picture in Picture's buttons do. Built separately so tests reach it on
    /// simulators that don't support Picture in Picture.
    var pictureInPictureTransport: OriginalVideoPictureInPicture.Transport {
        .init(
            isPaused: { [weak self] in
                guard let engine = self?.engine else { return true }
                return !(engine.state == .playing || engine.state == .finishedEnqueuing)
            },
            setPlaying: { [weak self] playing in _ = self?.handleRemote(playing ? .play : .pause) },
            skip: { [weak self] interval, completion in
                guard let self else { completion(); return }
                self.seek(to: max(0, (self.engine?.currentTime.seconds ?? 0) + interval), completion: completion)
            },
            duration: { [weak self] in self?.file.duration },
            stoppedInBackground: { [weak self] in self?.pauseForInterruption() })
    }

    private func installPictureInPicture(layer: AVSampleBufferDisplayLayer) {
        pictureInPicture = OriginalVideoPictureInPicture(layer: layer, transport: pictureInPictureTransport)
        chrome.setPictureInPictureAvailable(pictureInPicture != nil)
    }

    private static let silentNotice = "Playing without sound. No audio track in this file can be played."

    private var audioRenderer: AVSampleBufferAudioRenderer? {
        (engine?.rendering as? SampleBufferPlaybackRenderers)?.audioRenderer
    }
    private var isMuted: Bool { audioRenderer?.isMuted ?? false }
    private func toggleMute() {
        guard let audioRenderer else { return }
        audioRenderer.isMuted.toggle()
        chrome.setMuted(audioRenderer.isMuted)
        showControls()
    }

    private func publishNowPlaying() {
        guard let engine else { return }
        let playing = engine.state == .playing || engine.state == .finishedEnqueuing
        remote?.publish(title: summary.title, elapsed: engine.currentTime.seconds, duration: file.duration,
                        rate: playing ? rate : 0)
    }

    private func handleRemote(_ command: OriginalVideoRemoteControl.Command) -> Bool {
        guard !closing, let engine else { return false }
        let playing = engine.state == .playing || engine.state == .finishedEnqueuing
        switch command {
        case .play: if !playing { togglePlayback() }
        case .pause: if playing { togglePlayback() }
        case .toggle: togglePlayback()
        case .seek(let seconds): seek(to: seconds)
        case .skip(let interval): seek(by: interval)
        }
        return true
    }

    private func togglePlayback() {
        guard !busy, let engine else { return }
        if engine.state == .ended {
            interruptionPauseRequested = false
            perform { [weak self] engine in
                try await engine.seek(to: .zero)
                guard let self, !self.interruptionPauseRequested else { return }
                try engine.play(rate: self.rate)
            }
            return
        }
        if engine.state == .playing || engine.state == .finishedEnqueuing { engine.pause() }
        else {
            interruptionPauseRequested = false
            do { try engine.play(rate: rate) } catch { showFailure(error) }
        }
        showControls()
    }

    private func seek(by interval: Double) { seek(to: max(0, (engine?.currentTime.seconds ?? 0) + interval)) }
    /// `completion` runs once the seek lands, fails, or can't start.
    private func seek(to seconds: Double, completion: (@MainActor () -> Void)? = nil) {
        guard seconds.isFinite, seconds >= 0 else { completion?(); return }
        let started = perform { engine in
            defer { completion?() }
            try await engine.seek(to: CMTime(seconds: seconds, preferredTimescale: Self.seekTimescale))
        }
        if !started { completion?() }
    }

    @discardableResult
    private func perform(_ work: @escaping @MainActor (SampleBufferPlaybackEngine) async throws -> Void) -> Bool {
        guard !busy, !closing, let engine else { return false }
        busy = true; setEnabled(false); chrome.setTransport(.loading); showControls()
        operation = Task { [weak self] in
            var operationFailed = false
            do { try await work(engine) }
            catch {
                operationFailed = true
                if let self, !Task.isCancelled, !self.closing {
                    if case .failed = engine.state { self.showFailure(error) }
                    else {
                        self.chrome.setNotice(Self.updateFailedNotice)
                        self.showControls()
                        UIAccessibility.post(notification: .announcement, argument: Self.updateFailedNotice)
                    }
                }
            }
            guard let self else { return }
            self.busy = false; self.operation = nil
            guard !self.closing else { return }
            if case .failed = engine.state { return }
            if self.interruptionPauseRequested { engine.pause() }
            self.setEnabled(true); self.rebuildMenus(); self.stateChanged(engine.state)
            if operationFailed { self.chrome.setNotice(Self.updateFailedNotice) }
        }
        return true
    }

    private static let updateFailedNotice = "Could not change playback. Try again."

    /// A menu row for a track, led by its language as the system player does.
    /// Embedded track names are often an uploader's tag ("Toonworld4all.me"), so a
    /// name only appears, underneath, to tell apart two tracks in one language.
    private func trackLabel(_ track: MediaTrack, among tracks: [MediaTrack]) -> (title: String, subtitle: String?) {
        func language(_ track: MediaTrack) -> String {
            track.language.map { tag in
                tag == "und" ? "Unknown language" : Locale.current.localizedString(forLanguageCode: tag) ?? tag
            } ?? "Unknown language"
        }
        let title = language(track)
        let roles = track.roles.sorted { $0.rawValue < $1.rawValue }.map {
            switch $0 { case .commentary: return "Commentary"; case .visualImpaired: return "Audio description"; case .hearingImpaired: return "SDH"; case .forced: return "Forced"; case .original: return "Original" }
        }
        let sharesLanguage = tracks.contains { $0.id != track.id && language($0) == title }
        let name = sharesLanguage ? (track.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Track \(track.id)") : nil
        let details = ([name] + roles.map(Optional.some)).compactMap { $0 }
        return (title, details.isEmpty ? nil : details.joined(separator: ", "))
    }

    /// The audio menu's action. Remembered for this file only once the switch succeeds.
    func chooseAudio(_ trackID: UInt32?) {
        guard let engine, engine.selectedAudioTrackID != trackID else { return }
        let language = trackID.flatMap { id in engine.tracks.first { $0.id == id }?.language }
        perform { [weak self] engine in
            guard let self else { return }
            if let trackID, engine.state == .playing {
                let source: any ByteSource
                if let lease = self.lease { source = try LocalByteSource(url: lease) }
                else {
                    source = HTTPRangeByteSource(
                        url: ArchiveURLs.download(identifier: self.summary.identifier, fileName: self.file.name), session: ArchiveNetworkPolicy.session)
                }
                try await engine.selectAudio(trackID: trackID, using: MatroskaDemuxer(source: source))
            } else {
                try await engine.selectTracks(audio: trackID, video: engine.selectedVideoTrackID)
            }
            self.trackMemory.remember(.audio, choice: trackID.map(TrackChoice.track) ?? .off, language: language)
        }
    }

    /// The captions menu's action.
    func chooseCaption(_ trackID: UInt32?) {
        guard let engine else { return }
        selectedCaption = trackID
        if trackID == nil { captionLabel.text = nil }
        let language = trackID.flatMap { id in engine.tracks.first { $0.id == id }?.language }
        trackMemory.remember(.caption, choice: trackID.map(TrackChoice.track) ?? .off, language: language)
        rebuildMenus(); showControls()
    }

    private static let speeds: [Float] = [0.5, 1, 1.25, 1.5, 2]
    private static let unavailableTrack = "Can't be played"

    /// One "More" menu with Playback Speed, Audio and Subtitles, as in the system player.
    private func rebuildMenus() {
        guard let engine else { return }
        let unsupported = Set(engine.unsupportedTracks.map(\.id))
        let audio = engine.tracks.filter { $0.kind == .audio }
        var audioActions = [UIAction(title: "Off", state: engine.selectedAudioTrackID == nil ? .on : .off) { [weak self] _ in
            self?.chooseAudio(nil)
        }]
        audioActions += audio.map { track in
            let label = trackLabel(track, among: audio)
            let playable = !unsupported.contains(track.id)
            return UIAction(title: label.title, subtitle: playable ? label.subtitle : Self.unavailableTrack,
                            attributes: playable ? [] : .disabled,
                            state: engine.selectedAudioTrackID == track.id ? .on : .off) { [weak self] _ in
                self?.chooseAudio(track.id)
            }
        }
        var subtitleActions = [UIAction(title: "Off", state: selectedCaption == nil ? .on : .off) { [weak self] _ in
            self?.chooseCaption(nil)
        }]
        let subtitleTracks = engine.tracks.filter { $0.kind == .subtitle }
        subtitleActions += subtitleTracks.map { track in
            let label = trackLabel(track, among: subtitleTracks)
            let supported = CaptionPipeline.supportedCodecs.contains(track.codec)
            return UIAction(title: label.title, subtitle: supported ? label.subtitle : Self.unavailableTrack,
                            attributes: supported ? [] : .disabled,
                            state: selectedCaption == track.id ? .on : .off) { [weak self] _ in
                self?.chooseCaption(track.id)
            }
        }
        let speedActions = Self.speeds.map { value in
            UIAction(title: "\(value.formatted())×", state: rate == value ? .on : .off) { [weak self] _ in
                guard let self else { return }; self.rate = value
                if engine.state == .playing || engine.state == .finishedEnqueuing {
                    do { try engine.play(rate: value) } catch { self.showFailure(error) }
                }
                self.rebuildMenus(); self.showControls()
            }
        }
        let speed = UIMenu(title: "Playback Speed", image: UIImage(systemName: "gauge.with.dots.needle.33percent"), children: speedActions)
        let audioMenu = UIMenu(title: "Audio", image: UIImage(systemName: "waveform"), children: audioActions)
        let subtitles = UIMenu(title: "Subtitles", image: UIImage(systemName: "captions.bubble"), children: subtitleActions)
        speedMenu = speed; self.audioMenu = audioMenu; subtitlesMenu = subtitles
        chrome.moreButton.menu = UIMenu(children: [speed, audioMenu, subtitles])
    }

    private func setEnabled(_ enabled: Bool) { chrome.setEnabled(enabled) }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, !self.closing, let engine = self.engine else { return }
                let time = engine.currentTime
                self.bookmark.saveIfDue(seconds: time.seconds, ended: engine.state == .ended)
                if time.seconds.isFinite, !self.chrome.scrubber.isTracking {
                    self.chrome.setTime(elapsed: max(0, time.seconds), duration: self.file.duration)
                }
                if let captionDemuxer = self.captionDemuxer {
                    let (text, failed) = await captionDemuxer.text(at: time, trackID: self.selectedCaption)
                    self.captionLabel.text = text.isEmpty ? nil : text
                    self.captionLabel.accessibilityValue = text
                    if failed { self.chrome.setNotice("Some subtitles couldn't be shown.") }
                }
                if self.controlsShown, !UIAccessibility.isVoiceOverRunning, !self.busy, !self.chrome.scrubber.isTracking,
                   (engine.state == .playing || engine.state == .finishedEnqueuing),
                   Date().timeIntervalSince(self.lastInteraction) > Self.controlsFadeDelay {
                    self.hideControls()
                }
            }
        }
    }

    /// A tap on the film shows the controls, or hides them if they're up, as in the system player.
    @objc private func canvasTapped() {
        if controlsShown, !UIAccessibility.isVoiceOverRunning, engine?.state == .playing { hideControls() } else { showControls() }
    }
    private func savePosition() {
        guard let engine else { return }
        bookmark.save(seconds: engine.currentTime.seconds, ended: engine.state == .ended)
    }
    private func showControls() {
        lastInteraction = Date()
        chrome.accessibilityElementsHidden = false
        captionsAtBottom?.isActive = false; captionsAboveControls?.isActive = true
        controlsHidden = false
        animate { self.chrome.alpha = 1; self.view.layoutIfNeeded() }
    }
    private func hideControls() {
        chrome.accessibilityElementsHidden = true
        captionsAboveControls?.isActive = false; captionsAtBottom?.isActive = true
        controlsHidden = true
        animate { self.chrome.alpha = 0; self.view.layoutIfNeeded() }
    }
    private func animate(_ changes: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled || view.window == nil { changes() }
        else { UIView.animate(withDuration: Self.controlsFadeDuration, animations: changes) }
    }
    private func pauseForInterruption() {
        if engine != nil { interruptionPauseRequested = true }
        engine?.pause(); showControls()
    }

    private func showFailure(_ error: Error) {
        savePosition()
        ticker?.cancel(); ticker = nil
        setEnabled(false); showControls()
        canvas.isHidden = true; chrome.isHidden = true; captionLabel.text = nil
        // The error page needs a way out; the controls' Close is hidden with them.
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.close() })
        navigationController?.setNavigationBarHidden(false, animated: false)
        var config = UIContentUnavailableConfiguration.empty()
        config.text = "Could not play film"
        if case .unsupported(let reason) = error as? DemuxError { config.secondaryText = reason }
        else { config.secondaryText = "Check your connection or choose another version of this film." }
        config.button.title = "Try Again"
        config.buttonProperties.primaryAction = UIAction { [weak self] _ in
            guard let self, self.preparation == nil, self.operation == nil else { return }
            Task { [weak self] in
                guard let self else { return }; await self.releasePlayback(); self.start()
            }
        }
        contentUnavailableConfiguration = config
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    private func releasePlayback() async {
        // Before the audio player gets its token back, so its Now Playing stands.
        remote?.deactivate()
        ticker?.cancel(); ticker = nil
        bookmark.suspend()
        pictureInPicture?.stop(); pictureInPicture = nil
        chrome.setPictureInPictureAvailable(false)
        let old = engine; engine = nil
        old?.onStateChange = nil
        await old?.stop(); old?.displayLayer?.removeFromSuperlayer()
        captionDemuxer = nil
        if let lease { environment.downloads.releaseLocalURL(lease); self.lease = nil }
        if let token = audioOwnership { environment.playback.releaseVideoPlayback(token); audioOwnership = nil }
    }
    private func close() { finish(); navigationController?.dismiss(animated: true) }
    private func finish() {
        guard !closing else { return }
        savePosition(); closing = true
        ticker?.cancel(); preparation?.cancel(); operation?.cancel()
        let prepare = preparation, update = operation
        Task { [self] in await prepare?.value; await update?.value; await releasePlayback() }
    }
}

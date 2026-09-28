import UIKit
import AVFoundation
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
    private static let seekTimescale: CMTimeScale = 1_000
    private var engine: SampleBufferPlaybackEngine?
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
    private let controls = UIStackView()
    private let controlsContainer = UIScrollView()
    private let status = UILabel()
    private let captionLabel = UILabel()
    private let timeLabel = UILabel()
    private let slider = UISlider()
    private let playButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let audioButton = UIButton(type: .system)
    private let captionsButton = UIButton(type: .system)
    private let speedButton = UIButton(type: .system)

    init(summary: ArtifactSummary, file: ArchiveFile, environment: AppEnvironment, downloadedOnly: Bool) {
        self.summary = summary; self.file = file; self.environment = environment; self.downloadedOnly = downloadedOnly
        bookmark = OriginalVideoBookmark(store: environment.store, identifier: summary.identifier, fileName: file.name)
        super.init(nibName: nil, bundle: nil)
        title = summary.title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Read-only view of the engine for tests.
    var playbackEngine: SampleBufferPlaybackEngine? { engine }

    isolated deinit {
        preparation?.cancel(); operation?.cancel(); ticker?.cancel()
        notifications.forEach(NotificationCenter.default.removeObserver)
        let engine = engine, lease = lease, token = audioOwnership, environment = environment
        Task { @MainActor in
            await engine?.stop()
            if let lease { environment.downloads.releaseLocalURL(lease) }
            if let token { environment.playback.releaseVideoPlayback(token) }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "original.video.viewer"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.close() })
        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        canvas.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(canvasTapped)))
        controls.axis = .vertical; controls.spacing = 8
        controls.isLayoutMarginsRelativeArrangement = true
        controls.directionalLayoutMargins = .init(top: 12, leading: 16, bottom: 12, trailing: 16)
        controls.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.95)
        controls.layer.cornerRadius = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        controlsContainer.translatesAutoresizingMaskIntoConstraints = false
        controlsContainer.addSubview(controls)
        view.addSubview(controlsContainer)
        for label in [status, timeLabel, captionLabel] {
            label.font = .preferredFont(forTextStyle: label === captionLabel ? .title3 : .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0; label.textAlignment = .center
        }
        timeLabel.font = .preferredFont(forTextStyle: .body)
        status.text = "Opening film"
        captionLabel.textColor = .white
        captionLabel.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        captionLabel.layer.cornerRadius = 4
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.accessibilityLabel = "Captions"
        view.addSubview(captionLabel)
        configure(playButton, title: "Play", symbol: "play.fill") { [weak self] in self?.togglePlayback() }
        configure(backButton, title: "Back 15 seconds", symbol: "gobackward.15") { [weak self] in self?.seek(by: -15) }
        configure(forwardButton, title: "Forward 15 seconds", symbol: "goforward.15") { [weak self] in self?.seek(by: 15) }
        for (button, title) in [(audioButton, "Audio"), (captionsButton, "Captions"), (speedButton, "Speed")] {
            button.configuration = .bordered(); button.setTitle(title, for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .body)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.showsMenuAsPrimaryAction = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        let transport = UIStackView(arrangedSubviews: [backButton, playButton, forwardButton])
        transport.distribution = .fillEqually; transport.spacing = 8
        let menus = UIStackView(arrangedSubviews: [audioButton, captionsButton, speedButton])
        menus.distribution = .fillEqually; menus.spacing = 8
        controls.addArrangedSubview(status); controls.addArrangedSubview(timeLabel)
        controls.addArrangedSubview(slider); controls.addArrangedSubview(transport); controls.addArrangedSubview(menus)
        slider.accessibilityLabel = "Playback position"
        slider.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        slider.minimumValue = 0
        slider.maximumValue = Float(file.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1)
        slider.addAction(UIAction { [weak self] _ in self?.showControls() }, for: .touchDown)
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.seek(to: Double(self.slider.value))
        }, for: [.touchUpInside, .touchUpOutside, .primaryActionTriggered])
        slider.addAction(UIAction { [weak self] _ in
            guard let self, !self.slider.isTracking else { return }
            self.seek(to: Double(self.slider.value))
        }, for: .valueChanged)
        let naturalControlsHeight = controlsContainer.heightAnchor.constraint(equalTo: controls.heightAnchor)
        naturalControlsHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controlsContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            controlsContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            controlsContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            controlsContainer.heightAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.heightAnchor, multiplier: 0.65),
            naturalControlsHeight,
            controls.leadingAnchor.constraint(equalTo: controlsContainer.contentLayoutGuide.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: controlsContainer.contentLayoutGuide.trailingAnchor),
            controls.topAnchor.constraint(equalTo: controlsContainer.contentLayoutGuide.topAnchor),
            controls.bottomAnchor.constraint(equalTo: controlsContainer.contentLayoutGuide.bottomAnchor),
            controls.widthAnchor.constraint(equalTo: controlsContainer.frameLayoutGuide.widthAnchor),
            captionLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            captionLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            captionLabel.bottomAnchor.constraint(equalTo: controlsContainer.topAnchor, constant: -12)
        ])
        setEnabled(false)
        observe(UIAccessibility.voiceOverStatusDidChangeNotification) { [weak self] in self?.showControls() }
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] in self?.pauseForInterruption(); self?.savePosition() }
        observe(AVAudioSession.interruptionNotification) { [weak self] in self?.pauseForInterruption() }
        observe(AVAudioSession.routeChangeNotification) { [weak self] in self?.pauseForInterruption() }
        start()
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

    private func configure(_ button: UIButton, title: String, symbol: String, action: @escaping @MainActor () -> Void) {
        button.configuration = .bordered()
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = title
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }

    private func observe(_ name: Notification.Name, action: @escaping @MainActor @Sendable () -> Void) {
        notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        })
    }

    private func start() {
        guard !closing, preparation == nil else { return }
        view.backgroundColor = .systemBackground
        canvas.isHidden = true; controlsContainer.isHidden = true; captionLabel.text = nil
        interruptionPauseRequested = false
        var loading = UIContentUnavailableConfiguration.loading(); loading.text = "Opening film"
        contentUnavailableConfiguration = loading
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
                else { source = HTTPRangeByteSource(url: ArchiveURLs.download(identifier: summary.identifier, fileName: file.name)) }
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
                try await bookmark.restore(duration: self.file.duration) { seconds in
                    try await playback.seek(to: CMTime(seconds: seconds, preferredTimescale: Self.seekTimescale))
                }
                try Task.checkCancellation()
                guard !closing else { throw CancellationError() }
                contentUnavailableConfiguration = nil
                view.backgroundColor = .black; canvas.isHidden = false; controlsContainer.isHidden = false
                rebuildMenus(); setEnabled(true)
                if interruptionPauseRequested { status.text = "Paused" }
                else { try playback.play(rate: rate) }
                startTicker(); showControls()
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
            playButton.setImage(UIImage(systemName: "pause.fill"), for: .normal); playButton.accessibilityLabel = "Pause"
            status.text = engine?.selectedAudioTrackID == nil ? "Playing without sound. No audio track in this file can be played." : "Playing"
        case .paused:
            playButton.setImage(UIImage(systemName: "play.fill"), for: .normal); playButton.accessibilityLabel = "Play"
            status.text = "Paused"; showControls(); savePosition()
        case .ended:
            playButton.setImage(UIImage(systemName: "arrow.counterclockwise"), for: .normal)
            playButton.accessibilityLabel = "Replay"
            status.text = "Finished"; showControls(); savePosition()
        default: break
        }
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
    private func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        perform { engine in try await engine.seek(to: CMTime(seconds: seconds, preferredTimescale: Self.seekTimescale)) }
    }

    private func perform(_ work: @escaping @MainActor (SampleBufferPlaybackEngine) async throws -> Void) {
        guard !busy, !closing, let engine else { return }
        busy = true; setEnabled(false); status.text = "Updating playback"; showControls()
        operation = Task { [weak self] in
            var operationFailed = false
            do { try await work(engine) }
            catch {
                operationFailed = true
                if let self, !Task.isCancelled, !self.closing {
                    if case .failed = engine.state { self.showFailure(error) }
                    else {
                        self.status.text = "Could not update playback. Try again."
                        self.showControls()
                        UIAccessibility.post(notification: .announcement, argument: self.status.text)
                    }
                }
            }
            guard let self else { return }
            self.busy = false; self.operation = nil
            guard !self.closing else { return }
            if case .failed = engine.state { return }
            if self.interruptionPauseRequested { engine.pause() }
            self.setEnabled(true); self.rebuildMenus(); self.stateChanged(engine.state)
            if operationFailed { self.status.text = "Could not update playback. Try again." }
        }
    }

    private func trackTitle(_ track: MediaTrack) -> String {
        let language = track.language.map { tag in
            tag == "und" ? "Unknown language" : Locale.current.localizedString(forLanguageCode: tag) ?? tag
        } ?? "Unknown language"
        let roles = track.roles.sorted { $0.rawValue < $1.rawValue }.map {
            switch $0 { case .commentary: return "Commentary"; case .visualImpaired: return "Audio description"; case .hearingImpaired: return "Hearing impaired"; case .forced: return "Forced"; case .original: return "Original" }
        }
        return ([track.name, language, "Track \(track.id)"] + roles.map(Optional.some)).compactMap { $0 }.joined(separator: " · ")
    }

    private func rebuildMenus() {
        guard let engine else { return }
        let unsupported = Set(engine.unsupportedTracks.map(\.id))
        let audio = engine.tracks.filter { $0.kind == .audio }
        var audioActions = [UIAction(title: "Audio Off", state: engine.selectedAudioTrackID == nil ? .on : .off) { [weak self] _ in
            self?.perform { engine in try await engine.selectTracks(audio: nil, video: engine.selectedVideoTrackID) }
        }]
        audioActions += audio.map { track in
            UIAction(title: trackTitle(track) + (unsupported.contains(track.id) ? " · Unavailable" : ""),
                     attributes: unsupported.contains(track.id) ? .disabled : [], state: engine.selectedAudioTrackID == track.id ? .on : .off) { [weak self] _ in
                guard let self, engine.selectedAudioTrackID != track.id else { return }
                self.perform { engine in
                    if engine.state == .playing {
                        let source: any ByteSource
                        if let lease = self.lease { source = try LocalByteSource(url: lease) }
                        else {
                            source = HTTPRangeByteSource(
                                url: ArchiveURLs.download(identifier: self.summary.identifier, fileName: self.file.name))
                        }
                        try await engine.selectAudio(trackID: track.id, using: MatroskaDemuxer(source: source))
                    } else {
                        try await engine.selectTracks(audio: track.id, video: engine.selectedVideoTrackID)
                    }
                }
            }
        }
        audioButton.menu = UIMenu(title: "Audio track", children: audioActions)
        audioButton.accessibilityValue = engine.selectedAudioTrackID.flatMap { id in audio.first { $0.id == id }.map(trackTitle) } ?? "Off"
        var captionActions = [UIAction(title: "Off", state: selectedCaption == nil ? .on : .off) { [weak self] _ in
            self?.selectedCaption = nil; self?.captionLabel.text = nil; self?.rebuildMenus(); self?.showControls()
        }]
        captionActions += engine.tracks.filter { $0.kind == .subtitle }.map { track in
            let supported = CaptionPipeline.supportedCodecs.contains(track.codec)
            return UIAction(title: trackTitle(track) + (supported ? "" : " · Unavailable"), attributes: supported ? [] : .disabled,
                            state: selectedCaption == track.id ? .on : .off) { [weak self] _ in
                self?.selectedCaption = track.id; self?.rebuildMenus(); self?.showControls()
            }
        }
        captionsButton.menu = UIMenu(title: "Captions", children: captionActions)
        captionsButton.accessibilityValue = selectedCaption.flatMap { id in engine.tracks.first { $0.id == id }.map(trackTitle) } ?? "Off"
        speedButton.menu = UIMenu(title: "Playback speed", children: [Float(0.5), 1, 1.25, 1.5, 2].map { value in
            UIAction(title: "\(value.formatted())×", state: rate == value ? .on : .off) { [weak self] _ in
                guard let self else { return }; self.rate = value
                if engine.state == .playing || engine.state == .finishedEnqueuing {
                    do { try engine.play(rate: value) } catch { self.showFailure(error) }
                }
                self.rebuildMenus(); self.showControls()
            }
        })
        speedButton.accessibilityValue = "\(rate.formatted()) times"
    }

    private func setEnabled(_ enabled: Bool) {
        for button in [playButton, backButton, forwardButton, audioButton, captionsButton, speedButton] { button.isEnabled = enabled }
        slider.isEnabled = enabled && file.duration.map { $0.isFinite && $0 > 0 } == true
        slider.isHidden = file.duration.map { $0.isFinite && $0 > 0 } != true
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, !self.closing, let engine = self.engine else { return }
                let time = engine.currentTime
                self.bookmark.saveIfDue(seconds: time.seconds, ended: engine.state == .ended)
                if time.seconds.isFinite {
                    self.timeLabel.text = PlayerTimePresentation.clock(max(0, time.seconds))
                    self.slider.accessibilityValue = self.timeLabel.text
                    if !self.slider.isTracking { self.slider.value = Float(time.seconds) }
                }
                if let captionDemuxer = self.captionDemuxer {
                    let (text, failed) = await captionDemuxer.text(at: time, trackID: self.selectedCaption)
                    self.captionLabel.text = text.isEmpty ? nil : text
                    self.captionLabel.accessibilityValue = text
                    if failed { self.status.text = "Some captions could not be displayed" }
                }
                if !UIAccessibility.isVoiceOverRunning, !self.busy, !self.slider.isTracking,
                   (engine.state == .playing || engine.state == .finishedEnqueuing),
                   !self.controlsContainer.isTracking, !self.controlsContainer.isDecelerating,
                   Date().timeIntervalSince(self.lastInteraction) > 5 {
                    self.controlsContainer.alpha = 0; self.controls.accessibilityElementsHidden = true
                }
            }
        }
    }

    @objc private func canvasTapped() { showControls() }
    private func savePosition() {
        guard let engine else { return }
        bookmark.save(seconds: engine.currentTime.seconds, ended: engine.state == .ended)
    }
    private func showControls() { lastInteraction = Date(); controlsContainer.alpha = 1; controls.accessibilityElementsHidden = false }
    private func pauseForInterruption() {
        if engine != nil { interruptionPauseRequested = true }
        engine?.pause(); showControls()
    }

    private func showFailure(_ error: Error) {
        savePosition()
        ticker?.cancel(); ticker = nil
        setEnabled(false); showControls()
        view.backgroundColor = .systemBackground
        canvas.isHidden = true; controlsContainer.isHidden = true; captionLabel.text = nil
        var config = UIContentUnavailableConfiguration.empty()
        config.text = "Could not play this film"
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
        ticker?.cancel(); ticker = nil
        bookmark.suspend()
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

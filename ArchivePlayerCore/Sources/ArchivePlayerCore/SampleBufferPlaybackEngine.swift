import Foundation
import AVFoundation
import CoreMedia

/// All rendering and mutable playback state is confined to the main actor.
@MainActor public protocol SampleBufferPlaybackRendering: AnyObject {
    var currentTime: CMTime { get }
    var failure: String? { get }
    var onFailure: (@MainActor @Sendable (String) -> Void)? { get set }
    func isReady(for kind: MediaKind) -> Bool
    func enqueue(_ sample: CMSampleBuffer, kind: MediaKind)
    func setRate(_ rate: Float, time: CMTime)
    func flush()
    func requestMediaDataWhenReady(for kind: MediaKind, callback: @escaping @MainActor @Sendable () -> Void)
    func stopRequestingMediaData()
    func stopRequestingMediaData(for kind: MediaKind)
    func flushAudio()
    func scheduleDrain(at time: CMTime, completion: @escaping @MainActor @Sendable () -> Void)
    func cancelDrain()
}

@MainActor public final class SampleBufferPlaybackRenderers: SampleBufferPlaybackRendering {
    public let displayLayer = AVSampleBufferDisplayLayer()
    public let audioRenderer = AVSampleBufferAudioRenderer()
    public let synchronizer = AVSampleBufferRenderSynchronizer()
    public var onFailure: (@MainActor @Sendable (String) -> Void)?
    private var videoObservation: NSKeyValueObservation?
    private var audioObservation: NSKeyValueObservation?
    private var drainObserver: Any?

    public init() {
        // iOS 18 supports these APIs; receiver APIs require newer operating systems.
        synchronizer.addRenderer(displayLayer.sampleBufferRenderer)
        synchronizer.addRenderer(audioRenderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        synchronizer.setRate(0, time: .zero)
        videoObservation = displayLayer.sampleBufferRenderer.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let failure = self.failure else { return }
                self.onFailure?(failure)
            }
        }
        audioObservation = audioRenderer.observe(\.status, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let failure = self.failure else { return }
                self.onFailure?(failure)
            }
        }
    }

    public var currentTime: CMTime { synchronizer.currentTime() }
    public var failure: String? {
        if displayLayer.sampleBufferRenderer.status == .failed {
            return displayLayer.sampleBufferRenderer.error?.localizedDescription ?? "Video renderer failed"
        }
        if audioRenderer.status == .failed { return audioRenderer.error?.localizedDescription ?? "Audio renderer failed" }
        return nil
    }
    public func isReady(for kind: MediaKind) -> Bool {
        switch kind {
        case .video: displayLayer.sampleBufferRenderer.isReadyForMoreMediaData
        case .audio: audioRenderer.isReadyForMoreMediaData
        case .subtitle: false
        }
    }
    public func enqueue(_ sample: CMSampleBuffer, kind: MediaKind) {
        if kind == .video { displayLayer.sampleBufferRenderer.enqueue(sample) }
        if kind == .audio { audioRenderer.enqueue(sample) }
    }
    public func setRate(_ rate: Float, time: CMTime) { synchronizer.setRate(rate, time: time) }
    public func flush() {
        displayLayer.sampleBufferRenderer.flush()
        audioRenderer.flush()
    }
    public func requestMediaDataWhenReady(for kind: MediaKind, callback: @escaping @MainActor @Sendable () -> Void) {
        let block: @Sendable () -> Void = { MainActor.assumeIsolated { callback() } }
        if kind == .video { displayLayer.sampleBufferRenderer.requestMediaDataWhenReady(on: .main, using: block) }
        if kind == .audio { audioRenderer.requestMediaDataWhenReady(on: .main, using: block) }
    }
    public func stopRequestingMediaData() {
        displayLayer.sampleBufferRenderer.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
    }
    public func stopRequestingMediaData(for kind: MediaKind) {
        if kind == .video { displayLayer.sampleBufferRenderer.stopRequestingMediaData() }
        if kind == .audio { audioRenderer.stopRequestingMediaData() }
    }
    public func flushAudio() { audioRenderer.flush() }
    public func cancelDrain() {
        if let drainObserver { synchronizer.removeTimeObserver(drainObserver); self.drainObserver = nil }
    }
    public func scheduleDrain(at time: CMTime, completion: @escaping @MainActor @Sendable () -> Void) {
        cancelDrain()
        if currentTime >= time { completion(); return }
        drainObserver = synchronizer.addBoundaryTimeObserver(forTimes: [NSValue(time: time)], queue: .main) {
            MainActor.assumeIsolated { completion() }
        }
    }
}

public enum SampleBufferPlaybackState: Sendable, Equatable {
    case idle, ready, playing, paused, finishedEnqueuing, ended, stopped
    case failed(String)
}

/// Requires one decoder-ready access unit per packet. In particular, raw PES
/// payloads must pass through a codec framing adapter before reaching this engine.
@MainActor public final class SampleBufferPlaybackEngine {
    public let rendering: any SampleBufferPlaybackRendering
    public private(set) var state = SampleBufferPlaybackState.idle
    public private(set) var tracks: [MediaTrack] = []
    public private(set) var selectedAudioTrackID: UInt32?
    public private(set) var selectedVideoTrackID: UInt32?
    public private(set) var enqueuedPacketCount = 0
    public private(set) var lastError: String?
    public var unsupportedTracks: [MediaTrack] { tracks.filter { formats[$0.id] == nil } }
    public var onStateChange: (@MainActor (SampleBufferPlaybackState) -> Void)?
    public var currentTime: CMTime { rendering.currentTime }
    public var displayLayer: AVSampleBufferDisplayLayer? {
        (rendering as? SampleBufferPlaybackRenderers)?.displayLayer
    }

    private let demuxer: any Demuxer
    private var formats: [UInt32: CMFormatDescription]
    private var pumpTask: Task<Void, Never>?
    private var generation = 0
    private var pumpSerial = 0
    private var pendingPacket: DemuxedPacket?
    private var requestedRate: Float = 1
    private var needsAnchor = true
    private var needsVideoKeyframe = true
    private var inputEnded = false
    private var seekAnchor: CMTime?
    private var independentAudio: IndependentAudioSampleProducer?
    private var audioPreparationSerial = 0
    private var lastQueuedEnd: CMTime?
    private(set) var independentAudioEnqueuedPacketCount = 0
    private(set) var independentAudioFirstPTS: CMTime?
    private(set) var independentAudioCommitTime: CMTime?
    private(set) var independentAudioCommitDate: Date?
    private(set) var independentAudioFirstEnqueueDate: Date?
    private(set) var lastPrimaryAudioEnqueueDate: Date?
    private(set) var lastPrimaryAudioEndTime: CMTime?

    public init(demuxer: any Demuxer, formats: [UInt32: CMFormatDescription] = [:],
                rendering: (any SampleBufferPlaybackRendering)? = nil) {
        self.demuxer = demuxer
        self.formats = formats
        self.rendering = rendering ?? SampleBufferPlaybackRenderers()
        self.rendering.onFailure = { [weak self] message in
            guard let self, self.state != .stopped else { return }
            self.generation += 1
            self.pumpTask?.cancel(); self.pumpTask = nil
            self.fail(DemuxError.unsupported(message))
        }
    }

    isolated deinit {
        pumpTask?.cancel()
        independentAudio?.cancel()
        rendering.stopRequestingMediaData()
        rendering.cancelDrain()
        rendering.onFailure = nil
        rendering.setRate(0, time: .invalid)
    }

    public func prepare() async throws {
        guard state != .stopped else { throw DemuxError.unsupported("Create a new engine after stop") }
        guard state == .idle else { return }
        let token = generation
        do {
            guard !(demuxer is TransportStreamDemuxer), !(demuxer is ProgramStreamDemuxer) else {
                throw DemuxError.unsupported("Raw PES requires an access-unit framing adapter before playback")
            }
            let discoveredTracks = try await demuxer.tracks()
            guard generation == token, state != .stopped else { throw CancellationError() }
            tracks = discoveredTracks
            for track in tracks where formats[track.id] == nil {
                guard let config = track.codecPrivate else { continue }
                switch track.codec.lowercased() {
                case "h264", "avc", "v_mpeg4/iso/avc":
                    formats[track.id] = try? FormatDescriptionFactory.h264(avcC: config)
                case "aac", "a_aac":
                    formats[track.id] = try? FormatDescriptionFactory.aac(audioSpecificConfig: config)
                case "opus", "a_opus":
                    formats[track.id] = try? FormatDescriptionFactory.opus(opusHead: config)
                default: break
                }
            }
            selectedAudioTrackID = tracks.first { $0.kind == .audio && formats[$0.id] != nil }?.id
            selectedVideoTrackID = tracks.first { $0.kind == .video && formats[$0.id] != nil }?.id
            guard selectedAudioTrackID != nil || selectedVideoTrackID != nil else {
                throw DemuxError.unsupported("No selected track has a usable format description")
            }
            lastError = nil
            transition(.ready)
        } catch {
            if generation == token, state != .stopped { fail(error) }
            throw error
        }
    }

    public func play(rate: Float = 1) throws {
        guard rate.isFinite && rate > 0 && rate <= 4 else { throw DemuxError.unsupported("Playback rate must be in (0, 4]") }
        guard state == .ready || state == .paused || state == .playing || state == .finishedEnqueuing else {
            throw DemuxError.invalidFormat("Prepare playback before calling play")
        }
        requestedRate = rate
        if !needsAnchor { rendering.setRate(rate, time: .invalid) }
        if inputEnded { transition(.finishedEnqueuing); independentAudio?.resume(); return }
        transition(.playing)
        startPump()
        independentAudio?.resume()
    }

    public func pause() {
        guard state == .playing || state == .finishedEnqueuing else { return }
        rendering.setRate(0, time: .invalid)
        rendering.stopRequestingMediaData()
        transition(.paused)
    }

    /// Prepares a separately positioned reader while current playback continues.
    /// Commits by flushing only audio; it never seeks or flushes the video reader.
    /// The caller must supply a fresh demuxer and independently bounded byte source.
    public func selectAudio(trackID: UInt32, using replacement: any Demuxer) async throws {
        try validateTrack(trackID, kind: .audio)
        guard state == .playing, !needsAnchor,
              (demuxer as AnyObject) !== (replacement as AnyObject),
              !(replacement is TransportStreamDemuxer), !(replacement is ProgramStreamDemuxer) else {
            throw DemuxError.unsupported("Independent audio switch requires active playback and a fresh access-unit demuxer")
        }
        audioPreparationSerial += 1
        let preparationStarted = Date()
        let preparation = audioPreparationSerial, token = generation
        let replacementTracks = try await replacement.tracks()
        guard generation == token, audioPreparationSerial == preparation, state == .playing else { throw CancellationError() }
        guard let original = tracks.first(where: { $0.id == trackID }),
              replacementTracks.contains(where: { $0.id == trackID && $0.codec == original.codec && $0.codecPrivate == original.codecPrivate }) else {
            throw DemuxError.invalidFormat("Replacement reader does not describe the selected audio track")
        }
        try await replacement.seek(to: rendering.currentTime)
        var bytes = 0
        for _ in 0..<10_000 {
            try Task.checkCancellation()
            guard Date().timeIntervalSince(preparationStarted) < 30 else { throw DemuxError.unsupported("Independent audio preparation exceeded 30 seconds") }
            guard generation == token, audioPreparationSerial == preparation, state == .playing else { throw CancellationError() }
            guard let packet = try await replacement.nextPacket() else { throw DemuxError.truncated }
            bytes += packet.data.count
            guard bytes <= 32 * 1024 * 1024 else { throw DemuxError.unsupported("Independent audio catch-up exceeded 32 MiB") }
            guard packet.trackID == trackID, packet.pts.isNumeric,
                  packet.pts >= CMTimeAdd(rendering.currentTime, CMTime(value: 50, timescale: 1000)) else { continue }
            try Task.checkCancellation()
            guard generation == token, audioPreparationSerial == preparation, state == .playing else { throw CancellationError() }
            let old = independentAudio
            old?.cancel()
            // No await after this point: selection, audio-only flush and producer
            // installation are one main-actor transaction; video keeps its clock.
            rendering.stopRequestingMediaData(for: .audio)
            rendering.flushAudio()
            selectedAudioTrackID = trackID
            independentAudioEnqueuedPacketCount = 0; independentAudioFirstPTS = nil
            independentAudioFirstEnqueueDate = nil
            independentAudioCommitTime = rendering.currentTime; independentAudioCommitDate = Date()
            let producer = IndependentAudioSampleProducer(demuxer: replacement, trackID: trackID,
                format: formats[trackID]!, first: packet, rendering: rendering,
                isPlaying: { [weak self] in self?.state == .playing || self?.state == .finishedEnqueuing },
                onEnqueue: { [weak self] pts in
                    guard let self else { return }
                    self.enqueuedPacketCount += 1; self.independentAudioEnqueuedPacketCount += 1
                    if self.independentAudioFirstPTS == nil {
                        self.independentAudioFirstPTS = pts; self.independentAudioFirstEnqueueDate = Date()
                    }
                    self.recordEnd(pts: pts, duration: .invalid, format: self.formats[trackID]!)
                },
                onEnd: { [weak self] in self?.scheduleEndIfDrained() },
                onError: { [weak self] in self?.fail($0) })
            independentAudio = producer
            // A primary producer may have been waiting for old audio readiness.
            if pendingPacket?.trackID != selectedVideoTrackID { startPump() }
            producer.resume()
            return
        }
        throw DemuxError.unsupported("Independent audio catch-up exceeded 10000 packets")
    }

    /// Runtime changes seek to the current clock, flush both renderers, and restart
    /// from a video keyframe. This is a functional discontinuous switch, not seamless.
    public func selectTracks(audio: UInt32?, video: UInt32?) async throws {
        guard state == .ready || state == .playing || state == .paused || state == .finishedEnqueuing || state == .ended else {
            throw DemuxError.unsupported("Track selection requires a prepared, active engine")
        }
        try validateTrack(audio, kind: .audio)
        try validateTrack(video, kind: .video)
        guard audio != nil || video != nil else { throw DemuxError.unsupported("Select at least one media track") }
        let wasPlaying = state == .playing || state == .finishedEnqueuing
        let target = enqueuedPacketCount > 0 ? rendering.currentTime : nil
        rendering.setRate(0, time: .invalid)
        let token = await cancelPump()
        guard generation == token, state != .stopped else { throw CancellationError() }
        if let target {
            do { try await demuxer.seek(to: target) }
            catch { if generation == token, state != .stopped { fail(error) }; throw error }
        }
        guard generation == token, state != .stopped else { throw CancellationError() }
        selectedAudioTrackID = audio; selectedVideoTrackID = video
        pendingPacket = nil
        rendering.setRate(0, time: .invalid); rendering.flush()
        needsAnchor = true; needsVideoKeyframe = true; inputEnded = false
        seekAnchor = target
        if let target { rendering.setRate(0, time: target) }
        transition(wasPlaying ? .playing : .paused)
        if wasPlaying { startPump() }
    }

    public func seek(to time: CMTime) async throws {
        guard state == .ready || state == .playing || state == .paused || state == .finishedEnqueuing || state == .ended else {
            throw DemuxError.unsupported("Seeking requires a prepared, active engine")
        }
        guard time.isNumeric, time >= .zero else { throw DemuxError.outOfBounds }
        let wasPlaying = state == .playing || state == .finishedEnqueuing
        let token = await cancelPump()
        guard generation == token, state != .stopped else { throw CancellationError() }
        rendering.setRate(0, time: .invalid)
        do {
            try await demuxer.seek(to: time)
            guard generation == token, state != .stopped else { throw CancellationError() }
            rendering.flush(); pendingPacket = nil; inputEnded = false
            needsAnchor = true; needsVideoKeyframe = true
            seekAnchor = time
            rendering.setRate(0, time: time)
            transition(wasPlaying ? .playing : .paused)
            if wasPlaying { startPump() }
        } catch { if generation == token, state != .stopped { fail(error) }; throw error }
    }

    public func stop() async {
        transition(.stopped)
        rendering.setRate(0, time: .invalid)
        _ = await cancelPump()
        rendering.setRate(0, time: .invalid); rendering.flush()
        pendingPacket = nil; needsAnchor = true; needsVideoKeyframe = true
    }

    private func validateTrack(_ id: UInt32?, kind: MediaKind) throws {
        guard let id else { return }
        guard tracks.contains(where: { $0.id == id && $0.kind == kind }), formats[id] != nil else {
            throw DemuxError.unsupported("Track has no compatible format description")
        }
    }

    private func cancelPump() async -> Int {
        generation += 1
        let token = generation
        audioPreparationSerial += 1
        rendering.cancelDrain(); lastQueuedEnd = nil
        independentAudio?.cancel(); independentAudio = nil
        let old = pumpTask; pumpTask = nil
        old?.cancel()
        rendering.stopRequestingMediaData()
        await old?.value // Never race a demuxer's read with its seek.
        return token
    }

    private func startPump() {
        guard pumpTask == nil else { return }
        let token = generation
        pumpSerial += 1
        let serial = pumpSerial
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == token, self.pumpSerial == serial else { return }
                do {
                    if let failure = self.rendering.failure { throw DemuxError.unsupported(failure) }
                    if self.state != .playing {
                        if self.pumpSerial == serial { self.pumpTask = nil }
                        return
                    }
                    guard try await self.pumpOne(generation: token) else {
                        if self.generation == token, self.pumpSerial == serial { self.pumpTask = nil }
                        return
                    }
                    await Task.yield()
                } catch is CancellationError { return }
                catch {
                    if self.generation == token, self.pumpSerial == serial { self.fail(error); self.pumpTask = nil }
                    return
                }
            }
        }
    }

    private func pumpOne(generation token: Int) async throws -> Bool {
        if pendingPacket == nil {
            pendingPacket = try await demuxer.nextPacket()
            guard generation == token, !Task.isCancelled else { return false }
        }
        guard let packet = pendingPacket else {
            inputEnded = true
            // Renderers retain their queued samples and clock continues to drain them.
            // This state deliberately does not claim that the final frame is presented.
            transition(.finishedEnqueuing)
            scheduleEndIfDrained()
            return false
        }
        guard let track = tracks.first(where: { $0.id == packet.trackID }),
              packet.trackID == selectedAudioTrackID || packet.trackID == selectedVideoTrackID else {
            pendingPacket = nil; return true
        }
        if track.kind == .audio && independentAudio != nil { pendingPacket = nil; return true }
        if track.kind == .video && needsVideoKeyframe && !packet.isKeyframe {
            pendingPacket = nil; return true
        }
        if track.kind == .audio, let seekAnchor, packet.pts.isNumeric, packet.pts < seekAnchor {
            pendingPacket = nil; return true
        }
        guard state == .playing else { return true }
        guard rendering.isReady(for: track.kind) else {
            // A readiness callback can run before this async call returns to its
            // caller. Serial tokens prevent the old pump from clearing a new one.
            pumpTask = nil
            rendering.requestMediaDataWhenReady(for: track.kind) { [weak self] in
                guard let self else { return }
                // A callback already dispatched before the audio-only commit may
                // still arrive after stopRequestingMediaData. It must not cancel
                // the independent producer's new audio demand registration.
                if track.kind == .audio && self.independentAudio != nil { return }
                guard self.generation == token, self.state == .playing else { return }
                self.rendering.stopRequestingMediaData(for: track.kind)
                self.startPump()
            }
            return false
        }
        guard packet.pts.isNumeric, let format = formats[track.id] else {
            throw DemuxError.invalidFormat("Selected packet requires a timestamp and format")
        }
        let sample = try SampleBufferFactory.make(packet: packet, format: format)
        rendering.enqueue(sample, kind: track.kind)
        recordEnd(pts: packet.pts, duration: packet.duration, format: format)
        if track.kind == .audio {
            lastPrimaryAudioEnqueueDate = Date()
            var duration = packet.duration
            if !duration.isNumeric, let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
                let audio = description.pointee
                if audio.mSampleRate > 0 { duration = CMTime(seconds: Double(audio.mFramesPerPacket) / audio.mSampleRate, preferredTimescale: 1_000_000) }
            }
            if duration.isNumeric { lastPrimaryAudioEndTime = CMTimeAdd(packet.pts, duration) }
        }
        if track.kind == .video { needsVideoKeyframe = false }
        enqueuedPacketCount += 1; pendingPacket = nil
        if needsAnchor {
            rendering.setRate(requestedRate, time: seekAnchor ?? CMTimeMaximum(.zero, packet.pts))
            needsAnchor = false
        }
        if let failure = rendering.failure { throw DemuxError.unsupported(failure) }
        return true
    }

    private func transition(_ newState: SampleBufferPlaybackState) {
        state = newState; onStateChange?(newState)
    }
    private func recordEnd(pts: CMTime, duration: CMTime, format: CMFormatDescription) {
        var span = duration
        if !span.isNumeric || span <= .zero {
            if CMFormatDescriptionGetMediaType(format) == kCMMediaType_Audio,
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format), asbd.pointee.mSampleRate > 0 {
                span = CMTime(seconds: Double(asbd.pointee.mFramesPerPacket) / asbd.pointee.mSampleRate, preferredTimescale: 1_000_000)
            } else { span = CMTime(value: 1, timescale: 10) } // Conservative unknown final video duration.
        }
        let end = CMTimeAdd(pts, span)
        lastQueuedEnd = lastQueuedEnd.map { CMTimeMaximum($0, end) } ?? end
    }
    private func scheduleEndIfDrained() {
        guard inputEnded, independentAudio == nil || independentAudio?.isFinished == true else { return }
        let token = generation
        rendering.scheduleDrain(at: lastQueuedEnd ?? rendering.currentTime) { [weak self] in
            guard let self, self.generation == token, self.inputEnded, self.state != .stopped else { return }
            self.rendering.cancelDrain(); self.rendering.setRate(0, time: .invalid)
            self.transition(.ended)
        }
    }
    private func fail(_ error: Error) {
        lastError = String(describing: error)
        rendering.setRate(0, time: .invalid)
        rendering.stopRequestingMediaData()
        rendering.cancelDrain()
        independentAudio?.cancel()
        transition(.failed(lastError!))
    }
}

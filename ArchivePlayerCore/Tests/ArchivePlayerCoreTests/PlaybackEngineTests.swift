import XCTest
import CoreMedia
import AudioToolbox
import AVFoundation
import Darwin
@testable import ArchivePlayerCore

private actor PlaybackFixtureDemuxer: Demuxer {
    let mediaTracks: [MediaTrack]
    let packets: [DemuxedPacket]
    var cursor = 0
    var reads = 0
    var seeks: [CMTime] = []
    init(tracks: [MediaTrack], packets: [DemuxedPacket]) { mediaTracks = tracks; self.packets = packets }
    func tracks() async throws -> [MediaTrack] { mediaTracks }
    func nextPacket() async throws -> DemuxedPacket? {
        reads += 1
        guard cursor < packets.count else { return nil }
        defer { cursor += 1 }
        return packets[cursor]
    }
    func seek(to time: CMTime) async throws { seeks.append(time); cursor = 0 }
}

private actor PlaybackSuspendedDemuxer: Demuxer {
    let mediaTracks: [MediaTrack]
    init(tracks: [MediaTrack] = [MediaTrack(id: 1, kind: .audio, codec: "pcm")]) { mediaTracks = tracks }
    private var continuation: CheckedContinuation<[MediaTrack], Never>?
    var waiting: Bool { continuation != nil }
    func tracks() async throws -> [MediaTrack] {
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume(returning: mediaTracks)
        continuation = nil
    }
    func nextPacket() async throws -> DemuxedPacket? { nil }
    func seek(to time: CMTime) async throws {}
}

@MainActor private final class PlaybackFixtureRenderer: SampleBufferPlaybackRendering {
    var currentTime = CMTime.zero
    var failure: String?
    var onFailure: (@MainActor @Sendable (String) -> Void)?
    var ready = true
    var samples: [CMSampleBuffer] = []
    var kinds: [MediaKind] = []
    var rates: [Float] = []
    var flushes = 0
    var callback: (@MainActor @Sendable () -> Void)?
    var stopRequests = 0
    var blockAfterSamples: Int?
    var drainCompletion: (@MainActor @Sendable () -> Void)?
    var drainTime: CMTime?
    func isReady(for kind: MediaKind) -> Bool { ready }
    func enqueue(_ sample: CMSampleBuffer, kind: MediaKind) {
        samples.append(sample); kinds.append(kind)
        if let blockAfterSamples, samples.count >= blockAfterSamples { ready = false }
    }
    func setRate(_ rate: Float, time: CMTime) { rates.append(rate); if time.isNumeric { currentTime = time } }
    func flush() { flushes += 1 }
    func requestMediaDataWhenReady(for kind: MediaKind, callback: @escaping @MainActor @Sendable () -> Void) { self.callback = callback }
    func stopRequestingMediaData() { callback = nil; stopRequests += 1 }
    func stopRequestingMediaData(for kind: MediaKind) { stopRequestingMediaData() }
    func flushAudio() { flushes += 1 }
    func scheduleDrain(at time: CMTime, completion: @escaping @MainActor @Sendable () -> Void) { drainTime = time; drainCompletion = completion }
    func cancelDrain() { drainCompletion = nil }
    func signalReady() { ready = true; callback?() }
}

@MainActor final class PlaybackEngineTests: XCTestCase {
    private func format() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var result: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &result)
        XCTAssertEqual(status, noErr)
        return try XCTUnwrap(result)
    }
    private func packet(_ id: UInt32, index: Int64 = 0) -> DemuxedPacket {
        DemuxedPacket(trackID: id, data: Data([0, 0]), pts: CMTime(value: index, timescale: 48_000),
                      duration: CMTime(value: 1, timescale: 48_000), isKeyframe: true)
    }
    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Playback state did not converge")
    }

    func testSyntheticSamplesReachRendererAndEOFDoesNotStopClock() async throws {
        let demuxer = PlaybackFixtureDemuxer(tracks: [MediaTrack(id: 1, kind: .audio, codec: "pcm")], packets: [packet(1), packet(1, index: 1)])
        let renderer = PlaybackFixtureRenderer()
        let engine = SampleBufferPlaybackEngine(demuxer: demuxer, formats: [1: try format()], rendering: renderer)
        try await engine.prepare(); try engine.play()
        try await waitFor { engine.state == .finishedEnqueuing }
        XCTAssertEqual(renderer.samples.count, 2)
        XCTAssertEqual(CMSampleBufferGetNumSamples(renderer.samples[0]), 1)
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(renderer.samples[0]), 2)
        XCTAssertEqual(renderer.rates.last, 1)
        await engine.stop()
        XCTAssertEqual(renderer.rates.last, 0)
    }

    func testBackpressureHoldsOnlyOnePacketUntilCallback() async throws {
        let demuxer = PlaybackFixtureDemuxer(tracks: [MediaTrack(id: 1, kind: .audio, codec: "pcm")], packets: [packet(1), packet(1)])
        let renderer = PlaybackFixtureRenderer(); renderer.ready = false
        let engine = SampleBufferPlaybackEngine(demuxer: demuxer, formats: [1: try format()], rendering: renderer)
        try await engine.prepare(); try engine.play()
        try await waitFor { renderer.callback != nil }
        let reads = await demuxer.reads
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(renderer.samples.isEmpty)
        renderer.signalReady()
        try await waitFor { engine.state == .finishedEnqueuing }
        XCTAssertEqual(renderer.samples.count, 2)
        await engine.stop()
        XCTAssertNil(renderer.callback)
    }

    func testTrackSwitchFlushesAndSeekIsExplicit() async throws {
        let demuxer = PlaybackFixtureDemuxer(tracks: [MediaTrack(id: 1, kind: .audio, codec: "pcm"), MediaTrack(id: 2, kind: .audio, codec: "pcm")], packets: [packet(1), packet(2)])
        let renderer = PlaybackFixtureRenderer()
        let f = try format()
        let engine = SampleBufferPlaybackEngine(demuxer: demuxer, formats: [1: f, 2: f], rendering: renderer)
        try await engine.prepare()
        try await engine.selectTracks(audio: 2, video: nil)
        XCTAssertEqual(renderer.flushes, 1)
        XCTAssertEqual(engine.selectedAudioTrackID, 2)
        let initialSeeks = await demuxer.seeks
        XCTAssertTrue(initialSeeks.isEmpty)
        try await engine.seek(to: .zero)
        let seeks = await demuxer.seeks
        XCTAssertEqual(seeks, [.zero])
        XCTAssertEqual(renderer.flushes, 2)
        try engine.play(rate: 1.5)
        try await waitFor { engine.state == .finishedEnqueuing }
        XCTAssertEqual(renderer.samples.count, 1)
        XCTAssertEqual(renderer.rates.last, 1.5)
        try await engine.selectTracks(audio: 1, video: nil)
        XCTAssertEqual(engine.selectedAudioTrackID, 1)
        let switchedSeeks = await demuxer.seeks
        XCTAssertEqual(switchedSeeks.count, 2)
        XCTAssertEqual(renderer.flushes, 3)
        await engine.stop()
    }

    func testRendererFailureSurfacesAndStopsClock() async throws {
        let renderer = PlaybackFixtureRenderer()
        let engine = SampleBufferPlaybackEngine(demuxer: PlaybackFixtureDemuxer(tracks: [MediaTrack(id: 1, kind: .audio, codec: "pcm")], packets: [packet(1)]), formats: [1: try format()], rendering: renderer)
        try await engine.prepare(); renderer.failure = "Injected decoder rejection"; try engine.play()
        try await waitFor { engine.lastError != nil }
        XCTAssertTrue(engine.lastError?.contains("Injected decoder rejection") == true)
        XCTAssertEqual(renderer.rates.last, 0)
        await engine.stop()
    }

    func testUnsupportedTrackAndRateRejected() async throws {
        let renderer = PlaybackFixtureRenderer()
        let engine = SampleBufferPlaybackEngine(demuxer: PlaybackFixtureDemuxer(tracks: [MediaTrack(id: 1, kind: .audio, codec: "pcm"), MediaTrack(id: 9, kind: .audio, codec: "unknown")], packets: []), formats: [1: try format()], rendering: renderer)
        try await engine.prepare()
        XCTAssertEqual(engine.unsupportedTracks.map(\.id), [9])
        do { try await engine.selectTracks(audio: 9, video: nil); XCTFail("Expected unsupported selection") } catch {}
        XCTAssertThrowsError(try engine.play(rate: .nan))
        await engine.stop()
    }

    func testDeinitStopsDemandCallbacks() async throws {
        let renderer = PlaybackFixtureRenderer(); renderer.ready = false
        var engine: SampleBufferPlaybackEngine? = SampleBufferPlaybackEngine(demuxer: PlaybackFixtureDemuxer(tracks: [MediaTrack(id: 1, kind: .audio, codec: "pcm")], packets: [packet(1)]), formats: [1: try format()], rendering: renderer)
        try await engine?.prepare(); try engine?.play()
        try await waitFor { renderer.callback != nil }
        engine = nil
        XCTAssertNil(renderer.callback)
        XCTAssertEqual(renderer.rates.last, 0)
    }

    func testDeferredRendererFailureAfterEOF() async throws {
        let renderer = PlaybackFixtureRenderer()
        let engine = SampleBufferPlaybackEngine(demuxer: PlaybackFixtureDemuxer(tracks: [MediaTrack(id: 1, kind: .audio, codec: "pcm")], packets: [packet(1)]), formats: [1: try format()], rendering: renderer)
        try await engine.prepare(); try engine.play()
        try await waitFor { engine.state == .finishedEnqueuing }
        renderer.onFailure?("Deferred decoder failure")
        XCTAssertTrue(engine.lastError?.contains("Deferred decoder failure") == true)
        XCTAssertEqual(renderer.rates.last, 0)
        await engine.stop()
    }

    func testThreeTrackInitialSelectionIncludesAACAndOpus() async throws {
        let opusHead = Data(Array("OpusHead".utf8) + [1, 2, 0, 0, 0x80, 0xbb, 0, 0, 0, 0, 0])
        let mediaTracks = [MediaTrack(id: 1, kind: .audio, codec: "pcm"),
            MediaTrack(id: 2, kind: .audio, codec: "A_AAC", codecPrivate: Data([0x11, 0x90])),
            MediaTrack(id: 3, kind: .audio, codec: "A_OPUS", codecPrivate: opusHead)]
        let engine = SampleBufferPlaybackEngine(demuxer: PlaybackFixtureDemuxer(tracks: mediaTracks, packets: []), formats: [1: try format()], rendering: PlaybackFixtureRenderer())
        try await engine.prepare()
        XCTAssertEqual(engine.tracks.count, 3)
        XCTAssertTrue(engine.unsupportedTracks.isEmpty)
        for id: UInt32 in [3, 2, 1] {
            try await engine.selectTracks(audio: id, video: nil)
            XCTAssertEqual(engine.selectedAudioTrackID, id)
        }
        await engine.stop()
    }

    func testActualIARenderersIfEnabled() async throws {
        guard ProcessInfo.processInfo.environment["IA_RENDER_TESTS"] == "1" else {
            throw XCTSkip("Set IA_RENDER_TESTS=1 for real IA renderer validation")
        }
        var before = rusage(); getrusage(RUSAGE_SELF, &before)
        let started = Date()
        let url = URL(string: "https://archive.org/download/the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub/")!.appendingPathComponent("The Ancient Magus' Bride S01E03 720p HD BluRay Multi Audio ESub.mkv")
        let source = HTTPRangeByteSource(url: url, windowSize: 64 * 1024)
        let renderers = SampleBufferPlaybackRenderers()
        renderers.audioRenderer.volume = 0
        let engine = SampleBufferPlaybackEngine(demuxer: MatroskaDemuxer(source: source), rendering: renderers)
        try await engine.prepare()
        let audio = try XCTUnwrap(engine.tracks.first { $0.codec == "A_AAC" })
        let video = try XCTUnwrap(engine.tracks.first { $0.kind == .video })
        try await engine.selectTracks(audio: audio.id, video: video.id)
        try engine.play()
        var startup: TimeInterval?
        for _ in 0..<200 {
            if engine.lastError != nil { break }
            if renderers.displayLayer.sampleBufferRenderer.status == .rendering && renderers.audioRenderer.status == .rendering {
                startup = Date().timeIntervalSince(started); break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .seconds(3))
        var after = rusage(); getrusage(RUSAGE_SELF, &after)
        let cpuBefore = Double(before.ru_utime.tv_sec + before.ru_stime.tv_sec) + Double(before.ru_utime.tv_usec + before.ru_stime.tv_usec) / 1_000_000
        let cpuAfter = Double(after.ru_utime.tv_sec + after.ru_stime.tv_sec) + Double(after.ru_utime.tv_usec + after.ru_stime.tv_usec) / 1_000_000
        let bytes = await source.transferredBytes
        print("ACTUAL IA RENDER startup=\(String(describing: startup)) elapsed=\(Date().timeIntervalSince(started)) cpuSeconds=\(cpuAfter-cpuBefore) peakRSSBytes=\(after.ru_maxrss) transferredBytes=\(bytes) enqueued=\(engine.enqueuedPacketCount) clock=\(engine.currentTime.seconds) videoStatus=\(renderers.displayLayer.sampleBufferRenderer.status.rawValue) audioStatus=\(renderers.audioRenderer.status.rawValue) failure=\(String(describing: engine.lastError))")
        XCTAssertNotNil(startup)
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(renderers.displayLayer.sampleBufferRenderer.status, .rendering)
        XCTAssertEqual(renderers.audioRenderer.status, .rendering)
        XCTAssertGreaterThan(engine.currentTime.seconds, 1)
        XCTAssertGreaterThan(engine.enqueuedPacketCount, 5)
        let replacement = try XCTUnwrap(engine.tracks.first { $0.codec == "A_OPUS" })
        let switchClock = engine.currentTime.seconds
        let beforeSwitchCount = engine.enqueuedPacketCount
        let beforeVideoMetrics = await renderers.displayLayer.sampleBufferRenderer.videoPerformanceMetrics
        let switchStart = Date()
        let independent = ProcessInfo.processInfo.environment["IA_INDEPENDENT_AUDIO_TESTS"] == "1"
        let replacementSource = HTTPRangeByteSource(url: url, windowSize: 256 * 1024)
        var videoStatusFailures = 0
        var clockStalls = 0
        var displayedBuffers = 0
        var lastClock = engine.currentTime.seconds
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                if renderers.displayLayer.sampleBufferRenderer.status != .rendering { videoStatusFailures += 1 }
                if renderers.displayLayer.sampleBufferRenderer.displayedPixelBuffer() != nil { displayedBuffers += 1 }
                let now = engine.currentTime.seconds
                if now <= lastClock { clockStalls += 1 }
                lastClock = now
            }
        }
        defer { monitor.cancel() }
        if independent {
            try await engine.selectAudio(trackID: replacement.id, using: MatroskaDemuxer(source: replacementSource))
        } else {
            try await engine.selectTracks(audio: replacement.id, video: video.id)
        }
        let selectionSeconds = Date().timeIntervalSince(switchStart)
        var switchRecovery: TimeInterval?
        for _ in 0..<200 {
            if engine.lastError != nil { break }
            if engine.enqueuedPacketCount >= beforeSwitchCount + 10,
               (!independent || engine.independentAudioEnqueuedPacketCount > 0),
               renderers.displayLayer.sampleBufferRenderer.status == .rendering,
               renderers.audioRenderer.status == .rendering,
               engine.currentTime.seconds > switchClock + 0.2 {
                switchRecovery = Date().timeIntervalSince(switchStart); break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        try await Task.sleep(for: .seconds(2))
        monitor.cancel(); await monitor.value
        let replacementBytes = await replacementSource.transferredBytes
        let enqueueGap = engine.independentAudioFirstEnqueueDate.flatMap { first in engine.independentAudioCommitDate.map { first.timeIntervalSince($0) } }
        let timestampGap = engine.independentAudioFirstPTS.flatMap { first in engine.independentAudioCommitTime.map { CMTimeSubtract(first, $0).seconds } }
        let lastOldEnqueueGap = engine.independentAudioFirstEnqueueDate.flatMap { first in engine.lastPrimaryAudioEnqueueDate.map { first.timeIntervalSince($0) } }
        let afterVideoMetrics = await renderers.displayLayer.sampleBufferRenderer.videoPerformanceMetrics
        print("ACTUAL IA SWITCH AAC->Opus independent=\(independent) selectionSeconds=\(selectionSeconds) recoverySeconds=\(String(describing: switchRecovery)) beforeClock=\(switchClock) afterClock=\(engine.currentTime.seconds) videoStatus=\(renderers.displayLayer.sampleBufferRenderer.status.rawValue) audioStatus=\(renderers.audioRenderer.status.rawValue) videoStatusFailures=\(videoStatusFailures) clockStalls=\(clockStalls) displayedBufferObservations=\(displayedBuffers) replacementBytes=\(replacementBytes) failure=\(String(describing: engine.lastError))")
        if independent {
            print("INDEPENDENT AUDIO commitToFirstEnqueueSeconds=\(String(describing: enqueueGap)) lastOldToFirstNewEnqueueSeconds=\(String(describing: lastOldEnqueueGap)) firstPTSMinusCommitClock=\(String(describing: timestampGap)) oldQueuedAudioEnd=\(String(describing: engine.lastPrimaryAudioEndTime?.seconds)) newAudioPackets=\(engine.independentAudioEnqueuedPacketCount)")
            print("VIDEO METRICS beforeTotal=\(String(describing: beforeVideoMetrics?.totalNumberOfFrames)) afterTotal=\(String(describing: afterVideoMetrics?.totalNumberOfFrames)) beforeDropped=\(String(describing: beforeVideoMetrics?.numberOfDroppedFrames)) afterDropped=\(String(describing: afterVideoMetrics?.numberOfDroppedFrames))")
        }
        XCTAssertEqual(engine.selectedAudioTrackID, replacement.id)
        XCTAssertNotNil(switchRecovery)
        XCTAssertNil(engine.lastError)
        if independent {
            XCTAssertEqual(videoStatusFailures, 0); XCTAssertEqual(clockStalls, 0)
            XCTAssertGreaterThan(engine.independentAudioEnqueuedPacketCount, 30)
        }
        await engine.stop()
    }

    func testStopWhilePrepareSuspendedCannotResurrectEngine() async throws {
        let demuxer = PlaybackSuspendedDemuxer()
        let engine = SampleBufferPlaybackEngine(demuxer: demuxer, formats: [1: try format()], rendering: PlaybackFixtureRenderer())
        let preparation = Task { try await engine.prepare() }
        for _ in 0..<100 {
            if await demuxer.waiting { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        await engine.stop()
        await demuxer.release()
        do { try await preparation.value; XCTFail("Expected cancelled stale preparation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(engine.state, .stopped)
        do { try await engine.seek(to: .zero); XCTFail("Stopped seek must fail") } catch {}
        do { try await engine.selectTracks(audio: 1, video: nil); XCTFail("Stopped selection must fail") } catch {}
        XCTAssertEqual(engine.state, .stopped)
    }

    func testIndependentAudioPreparationFailureAndCancellationPreserveOriginal() async throws {
        let mediaTracks = [MediaTrack(id: 1, kind: .audio, codec: "pcm"), MediaTrack(id: 2, kind: .audio, codec: "pcm")]
        let renderer = PlaybackFixtureRenderer(); renderer.blockAfterSamples = 1
        let f = try format()
        let engine = SampleBufferPlaybackEngine(demuxer: PlaybackFixtureDemuxer(tracks: mediaTracks, packets: [packet(1), packet(1, index: 1)]), formats: [1: f, 2: f], rendering: renderer)
        try await engine.prepare(); try engine.play()
        try await waitFor { renderer.callback != nil }
        let empty = PlaybackFixtureDemuxer(tracks: mediaTracks, packets: [])
        do { try await engine.selectAudio(trackID: 2, using: empty); XCTFail("Expected missing replacement data") } catch {}
        XCTAssertEqual(engine.selectedAudioTrackID, 1)
        XCTAssertEqual(renderer.flushes, 0)
        XCTAssertEqual(renderer.rates.last, 1)
        let suspended = PlaybackSuspendedDemuxer(tracks: mediaTracks)
        let switching = Task { try await engine.selectAudio(trackID: 2, using: suspended) }
        for _ in 0..<100 {
            if await suspended.waiting { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        switching.cancel(); await suspended.release()
        do { try await switching.value; XCTFail("Expected switch cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(engine.selectedAudioTrackID, 1)
        XCTAssertEqual(renderer.flushes, 0)
        XCTAssertEqual(engine.state, .playing)
        await engine.stop()
    }

    func testEOFFinalDrainEndsAndSeekCanRestart() async throws {
        let renderer = PlaybackFixtureRenderer()
        let engine = SampleBufferPlaybackEngine(demuxer: PlaybackFixtureDemuxer(tracks: [MediaTrack(id: 1, kind: .audio, codec: "pcm")], packets: [packet(1)]), formats: [1: try format()], rendering: renderer)
        try await engine.prepare(); try engine.play()
        try await waitFor { engine.state == .finishedEnqueuing }
        XCTAssertEqual(renderer.drainTime, CMTime(value: 1, timescale: 48_000))
        engine.pause(); XCTAssertEqual(engine.state, .paused)
        try engine.play(); renderer.drainCompletion?()
        XCTAssertEqual(engine.state, .ended)
        XCTAssertEqual(renderer.rates.last, 0)
        try await engine.seek(to: .zero)
        XCTAssertEqual(engine.state, .paused)
        try engine.play(); try await waitFor { engine.state == .finishedEnqueuing }
        await engine.stop()
    }
}

import Foundation
import CoreMedia

/// One separately positioned, demand-driven audio reader. It never changes the
/// shared clock or touches video renderer state. At most one packet is pending.
@MainActor final class IndependentAudioSampleProducer {
    private let demuxer: any Demuxer
    private let trackID: UInt32
    private let format: CMFormatDescription
    private let rendering: any SampleBufferPlaybackRendering
    private let isPlaying: @MainActor () -> Bool
    private let onEnqueue: @MainActor (CMTime) -> Void
    private let onError: @MainActor (Error) -> Void
    private let onEnd: @MainActor () -> Void
    var isFinished: Bool { ended }
    private var pending: DemuxedPacket?
    private var task: Task<Void, Never>?
    private var serial = 0
    private var cancelled = false
    private var ended = false
    private var scannedPackets = 0
    private var scannedBytes = 0

    init(demuxer: any Demuxer, trackID: UInt32, format: CMFormatDescription,
         first: DemuxedPacket, rendering: any SampleBufferPlaybackRendering,
         isPlaying: @escaping @MainActor () -> Bool, onEnqueue: @escaping @MainActor (CMTime) -> Void,
         onEnd: @escaping @MainActor () -> Void, onError: @escaping @MainActor (Error) -> Void) {
        self.demuxer = demuxer; self.trackID = trackID; self.format = format
        self.pending = first; self.rendering = rendering
        self.isPlaying = isPlaying; self.onEnqueue = onEnqueue; self.onError = onError
        self.onEnd = onEnd
    }

    func cancel() {
        cancelled = true; serial += 1; task?.cancel(); task = nil
        rendering.stopRequestingMediaData(for: .audio)
    }

    func resume() {
        guard task == nil, !cancelled, !ended, isPlaying() else { return }
        serial += 1; let token = serial
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.serial == token, !self.cancelled else { return }
                do {
                    guard self.isPlaying() else { self.task = nil; return }
                    if self.pending == nil { self.pending = try await self.demuxer.nextPacket() }
                    guard self.serial == token, !Task.isCancelled else { return }
                    guard self.isPlaying() else { self.task = nil; return }
                    guard let packet = self.pending else { self.ended = true; self.task = nil; self.onEnd(); return }
                    self.scannedPackets += 1; self.scannedBytes += packet.data.count
                    guard self.scannedPackets <= 10_000, self.scannedBytes <= 32 * 1024 * 1024 else {
                        throw DemuxError.unsupported("Independent audio scan limit between samples")
                    }
                    guard packet.trackID == self.trackID else { self.pending = nil; continue }
                    guard packet.pts.isNumeric else { throw DemuxError.invalidFormat("Independent audio timestamp missing") }
                    if packet.pts < self.rendering.currentTime { self.pending = nil; continue }
                    guard self.rendering.isReady(for: .audio) else {
                        self.task = nil
                        self.rendering.requestMediaDataWhenReady(for: .audio) { [weak self] in
                            guard let self, !self.cancelled else { return }
                            self.rendering.stopRequestingMediaData(for: .audio)
                            self.resume()
                        }
                        return
                    }
                    let sample = try SampleBufferFactory.make(packet: packet, format: self.format)
                    self.rendering.enqueue(sample, kind: .audio)
                    self.pending = nil; self.onEnqueue(packet.pts)
                    self.scannedPackets = 0; self.scannedBytes = 0
                    if let error = self.rendering.failure { throw DemuxError.unsupported(error) }
                    await Task.yield()
                } catch is CancellationError { return }
                catch { if self.serial == token { self.task = nil; self.onError(error) }; return }
            }
        }
    }

    isolated deinit { task?.cancel() }
}

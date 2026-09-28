import XCTest
import AVFoundation
import VideoToolbox
import AudioToolbox
import Darwin
@testable import ArchivePlayerCore

@MainActor
final class ProgramStreamDecodeTests: XCTestCase {
    private final class Observation {
        var count = 0
        var status: OSStatus = 0
        var dimensions = ""
    }
    private final class AudioInput {
        let pointer: UnsafeMutableRawPointer
        let count: Int
        var supplied = false
        let description: UnsafeMutablePointer<AudioStreamPacketDescription>
        init(_ bytes: Data) {
            count = bytes.count
            pointer = .allocate(byteCount: count, alignment: 16)
            bytes.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: count)
            description = .allocate(capacity: 1)
            description.initialize(to: AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 1536, mDataByteSize: UInt32(count)))
        }
        deinit { pointer.deallocate(); description.deinitialize(count: 1); description.deallocate() }
    }

    func testRealVOBNativeImageAndBothAC3Tracks() async throws {
        guard let path = ProcessInfo.processInfo.environment["PROGRAM_STREAM_CORPUS_PREFIX"] else { throw XCTSkip("Set PROGRAM_STREAM_CORPUS_PREFIX") }
        let adapter = ProgramStreamAccessUnitDemuxer(source: try LocalByteSource(url: URL(fileURLWithPath: path)))
        let formats = try await adapter.formatDescriptions()
        var first = [UInt32: DemuxedPacket]()
        while first.count < 3 {
            guard let packet = try await adapter.nextPacket() else { break }
            if first[packet.trackID] == nil && packet.isKeyframe { first[packet.trackID] = packet }
        }
        let video = try XCTUnwrap(first[0xE0])
        let observed = Observation()
        let callback: VTDecompressionOutputCallback = { pointer, _, status, _, image, _, _ in
            guard let pointer else { return }
            let state = Unmanaged<Observation>.fromOpaque(pointer).takeUnretainedValue()
            state.status = status
            if let image { state.count += 1; state.dimensions = "\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image))" }
        }
        var record = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: callback, decompressionOutputRefCon: Unmanaged.passUnretained(observed).toOpaque())
        var session: VTDecompressionSession?
        let create = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: try XCTUnwrap(formats[0xE0]), decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: &record, decompressionSessionOut: &session)
        XCTAssertEqual(create, noErr)
        let decoder = try XCTUnwrap(session)
        defer { VTDecompressionSessionInvalidate(decoder) }
        let sample = try SampleBufferFactory.make(packet: video, format: try XCTUnwrap(formats[0xE0]))
        let submit = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        VTDecompressionSessionFinishDelayedFrames(decoder)
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        print("REAL VOB MPEG2: create=\(create) submit=\(submit) callback=\(observed.status) images=\(observed.count) dimensions=\(observed.dimensions) bytes=\(video.data.count) pts=\(video.pts.seconds)")
        XCTAssertEqual(submit, noErr); XCTAssertEqual(observed.status, noErr); XCTAssertGreaterThan(observed.count, 0)
        for id: UInt32 in [0xBD80, 0xBD81] {
            let packet = try XCTUnwrap(first[id])
            var input = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(try XCTUnwrap(formats[id]))).pointee
            var output = AudioStreamBasicDescription(mSampleRate: input.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: input.mChannelsPerFrame * 4,
                mFramesPerPacket: 1, mBytesPerFrame: input.mChannelsPerFrame * 4, mChannelsPerFrame: input.mChannelsPerFrame, mBitsPerChannel: 32, mReserved: 0)
            var audioConverter: AudioConverterRef?
            let created = AudioConverterNew(&input, &output, &audioConverter)
            XCTAssertEqual(created, noErr)
            let converter = try XCTUnwrap(audioConverter)
            defer { AudioConverterDispose(converter) }
            let context = AudioInput(packet.data)
            let audioCallback: AudioConverterComplexInputDataProc = { _, requested, list, descriptions, pointer in
                guard let pointer else { return -50 }
                let context = Unmanaged<AudioInput>.fromOpaque(pointer).takeUnretainedValue()
                guard !context.supplied else { requested.pointee = 0; return noErr }
                context.supplied = true; requested.pointee = 1
                list.pointee.mNumberBuffers = 1
                list.pointee.mBuffers.mData = context.pointer
                list.pointee.mBuffers.mDataByteSize = UInt32(context.count)
                descriptions?.pointee = context.description
                return noErr
            }
            let capacity = 1536 * Int(output.mBytesPerFrame)
            let bytes = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
            defer { bytes.deallocate() }
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: output.mChannelsPerFrame, mDataByteSize: UInt32(capacity), mData: bytes))
            var frames: UInt32 = 1536
            let decoded = AudioConverterFillComplexBuffer(converter, audioCallback, Unmanaged.passUnretained(context).toOpaque(), &frames, &buffers, nil)
            var prime = AudioConverterPrimeInfo()
            var primeSize = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
            let primeStatus = AudioConverterGetProperty(converter, kAudioConverterPrimeInfo, &primeSize, &prime)
            print("REAL VOB AC3 \(id): create=\(created) fill=\(decoded) frames=\(frames) channels=\(output.mChannelsPerFrame) PCMbytes=\(buffers.mBuffers.mDataByteSize) compressedBytes=\(packet.data.count) pts=\(packet.pts.seconds) primeStatus=\(primeStatus) leading=\(prime.leadingFrames) trailing=\(prime.trailingFrames)")
            XCTAssertEqual(decoded, noErr); XCTAssertGreaterThan(frames, 0); XCTAssertLessThanOrEqual(frames, 1536)
        }
    }

    func testRealVOBSampleBufferEngineOptIn() async throws {
        guard ProcessInfo.processInfo.environment["PROGRAM_STREAM_RENDER_NETWORK"] == "1" else { throw XCTSkip("Set PROGRAM_STREAM_RENDER_NETWORK=1") }
        let start = ProcessInfo.processInfo.systemUptime
        let cpuStart = Double(clock()) / Double(CLOCKS_PER_SEC)
        var before = rusage(); getrusage(RUSAGE_SELF, &before)
        let source = HTTPRangeByteSource(url: URL(string: "https://archive.org/download/vts-01-1_20250820_1408/VTS_01_1.VOB")!, windowSize: 256 * 1024)
        let adapter = ProgramStreamAccessUnitDemuxer(source: source)
        let formats = try await adapter.formatDescriptions()
        let rendering = SampleBufferPlaybackRenderers()
        let engine = SampleBufferPlaybackEngine(demuxer: adapter, formats: formats, rendering: rendering)
        try await engine.prepare()
        try engine.play()
        try await Task.sleep(for: .seconds(2))
        let count = engine.enqueuedPacketCount
        let time = engine.currentTime.seconds
        let failure = rendering.failure
        let state = engine.state
        let transferred = await source.transferredBytes
        await engine.stop()
        var after = rusage(); getrusage(RUSAGE_SELF, &after)
        print("REAL VOB engine state=\(state) enqueued=\(count) clock=\(time) rendererFailure=\(String(describing: failure)) transferred=\(transferred) wall=\(ProcessInfo.processInfo.systemUptime - start) processCPU=\(Double(clock()) / Double(CLOCKS_PER_SEC) - cpuStart) peakRSS=\(after.ru_maxrss) peakGrowth=\(max(0, after.ru_maxrss - before.ru_maxrss))")
        XCTAssertNil(failure); XCTAssertGreaterThan(count, 5)
        if case .failed(let message) = state { XCTFail(message) }
    }
}

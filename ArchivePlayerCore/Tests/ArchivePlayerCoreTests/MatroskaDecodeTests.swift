import XCTest
import CoreMedia
import CoreVideo
import VideoToolbox
import AudioToolbox
@testable import ArchivePlayerCore

/// Opt-in real compressed data decode, not just a format/session construction probe.
final class MatroskaDecodeTests: XCTestCase {
    private final class Observation {
        let lock = NSLock()
        var status: OSStatus = 0
        var width = 0
        var height = 0
        var images = 0
        func record(_ status: OSStatus, image: CVImageBuffer?) {
            lock.lock(); defer { lock.unlock() }
            self.status = status
            if let image { images += 1; width = CVPixelBufferGetWidth(image); height = CVPixelBufferGetHeight(image) }
        }
    }
    private func fixture() throws -> HTTPRangeByteSource {
        guard ProcessInfo.processInfo.environment["IA_NETWORK_TESTS"] == "1" else { throw XCTSkip("Set IA_NETWORK_TESTS=1 for actual IA compressed-frame decoding") }
        let url = URL(string: "https://archive.org/download/the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub/")!.appendingPathComponent("The Ancient Magus' Bride S01E03 720p HD BluRay Multi Audio ESub.mkv")
        return HTTPRangeByteSource(url: url, windowSize: 4096)
    }
    func testRealIAH264ProducesDecodedImage() async throws {
        let started = Date()
        let source = try fixture()
        let demux = MatroskaDemuxer(source: source)
        let tracks = try await demux.tracks()
        let video = try XCTUnwrap(tracks.first { $0.codec == "V_MPEG4/ISO/AVC" })
        let format = try FormatDescriptionFactory.h264(avcC: XCTUnwrap(video.codecPrivate))
        var keyframe: DemuxedPacket?
        for _ in 0..<1000 {
            guard let packet = try await demux.nextPacket() else { break }
            if packet.trackID == video.id, packet.isKeyframe { keyframe = packet; break }
        }
        let packet = try XCTUnwrap(keyframe)
        let sample = try SampleBufferFactory.make(packet: packet, format: format)
        let observation = Observation()
        let callback: VTDecompressionOutputCallback = { context, _, status, _, image, _, _ in
            guard let context else { return }
            Unmanaged<Observation>.fromOpaque(context).takeUnretainedValue().record(status, image: image)
        }
        var record = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: callback, decompressionOutputRefCon: Unmanaged.passUnretained(observation).toOpaque())
        var session: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: &record, decompressionSessionOut: &session)
        XCTAssertEqual(createStatus, noErr)
        let decoder = try XCTUnwrap(session)
        defer { VTDecompressionSessionInvalidate(decoder) }
        let submitted = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], frameRefcon: nil, infoFlagsOut: nil)
        let finish = VTDecompressionSessionFinishDelayedFrames(decoder)
        let waited = VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        let bytes = await source.transferredBytes
        print("REAL IA H264 decode: create=\(createStatus), submit=\(submitted), finish=\(finish), wait=\(waited), callback=\(observation.status), images=\(observation.images), dimensions=\(observation.width)x\(observation.height), packetBytes=\(packet.data.count), transferredBytes=\(bytes), seconds=\(Date().timeIntervalSince(started))")
        XCTAssertEqual(submitted, noErr); XCTAssertEqual(finish, noErr); XCTAssertEqual(waited, noErr)
        XCTAssertEqual(observation.status, noErr); XCTAssertGreaterThan(observation.images, 0)
        XCTAssertEqual(observation.width, 1280); XCTAssertEqual(observation.height, 720)
    }

    private final class AudioInput {
        let bytes: UnsafeMutableRawPointer
        let size: Int
        var supplied = false
        let description: UnsafeMutablePointer<AudioStreamPacketDescription>
        init(_ data: Data) {
            size = data.count
            bytes = .allocate(byteCount: max(1, size), alignment: 16)
            data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: size)
            description = .allocate(capacity: 1)
            description.initialize(to: AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size)))
        }
        deinit { bytes.deallocate(); description.deinitialize(count: 1); description.deallocate() }
    }
    func testRealIAAACProducesPCM() async throws {
        try await decodeAudio(codec: "A_AAC")
    }
    func testRealIAOpusProducesPCM() async throws {
        try await decodeAudio(codec: "A_OPUS")
    }
    private func decodeAudio(codec: String) async throws {
        let started = Date(); let source = try fixture(); let demux = MatroskaDemuxer(source: source)
        let tracks = try await demux.tracks()
        let audio = try XCTUnwrap(tracks.first { $0.codec == codec })
        let configuration = try XCTUnwrap(audio.codecPrivate)
        var input: AudioStreamBasicDescription
        if codec == "A_AAC" {
            let format = try FormatDescriptionFactory.aac(audioSpecificConfig: configuration)
            input = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format)).pointee
        } else {
            input = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(audio.channels ?? 2), mBitsPerChannel: 0, mReserved: 0)
        }
        var output = AudioStreamBasicDescription(mSampleRate: input.mSampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4 * input.mChannelsPerFrame, mFramesPerPacket: 1, mBytesPerFrame: 4 * input.mChannelsPerFrame, mChannelsPerFrame: input.mChannelsPerFrame, mBitsPerChannel: 32, mReserved: 0)
        var converter: AudioConverterRef?
        let created = AudioConverterNew(&input, &output, &converter)
        XCTAssertEqual(created, noErr); let decoder = try XCTUnwrap(converter)
        defer { AudioConverterDispose(decoder) }
        let cookieStatus = configuration.withUnsafeBytes { AudioConverterSetProperty(decoder, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!) }
        var compressed: DemuxedPacket?
        for _ in 0..<1000 {
            guard let packet = try await demux.nextPacket() else { break }
            if packet.trackID == audio.id { compressed = packet; break }
        }
        let packet = try XCTUnwrap(compressed)
        let context = AudioInput(packet.data)
        let callback: AudioConverterComplexInputDataProc = { _, count, buffers, descriptions, pointer in
            guard let pointer else { return -50 }
            let context = Unmanaged<AudioInput>.fromOpaque(pointer).takeUnretainedValue()
            if context.supplied { count.pointee = 0; return noErr }
            context.supplied = true; count.pointee = 1
            buffers.pointee.mNumberBuffers = 1
            buffers.pointee.mBuffers.mData = context.bytes
            buffers.pointee.mBuffers.mDataByteSize = UInt32(context.size)
            descriptions?.pointee = context.description
            return noErr
        }
        let capacity = 8192 * Int(output.mBytesPerFrame)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { memory.deallocate() }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: output.mChannelsPerFrame, mDataByteSize: UInt32(capacity), mData: memory))
        var frames: UInt32 = 1024
        let decoded = AudioConverterFillComplexBuffer(decoder, callback, Unmanaged.passUnretained(context).toOpaque(), &frames, &list, nil)
        let bytes = await source.transferredBytes
        print("REAL IA \(codec) decode: create=\(created), cookie=\(cookieStatus), fill=\(decoded), PCMframes=\(frames), PCMbytes=\(list.mBuffers.mDataByteSize), packetBytes=\(packet.data.count), transferredBytes=\(bytes), seconds=\(Date().timeIntervalSince(started))")
        XCTAssertEqual(decoded, noErr); XCTAssertGreaterThan(frames, 0); XCTAssertGreaterThan(list.mBuffers.mDataByteSize, 0)
    }
}

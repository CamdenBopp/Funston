import XCTest
import CoreMedia
import VideoToolbox
import AudioToolbox

/// A format-description/session gate, not a positive playback claim. The conformance
/// harness must also submit a known-good compressed sample and check decoded output.
final class CodecCapabilityTests: XCTestCase {
    private final class DecodeObservation {
        var decodedFrames = 0
        var lastStatus: OSStatus = 0
    }

    func testVideoSessionCreationMatrix() throws {
        let formats: [(String, CMVideoCodecType)] = [
            ("H264", kCMVideoCodecType_H264),
            ("HEVC", kCMVideoCodecType_HEVC),
            ("MPEG2", kCMVideoCodecType_MPEG2Video),
            ("VP9", kCMVideoCodecType_VP9),
            ("AV1", kCMVideoCodecType_AV1)
        ]
        for (name, codec) in formats {
            var format: CMVideoFormatDescription?
            let formatStatus = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, codecType: codec, width: 64, height: 64,
                extensions: nil, formatDescriptionOut: &format)
            var session: VTDecompressionSession?
            let sessionStatus: OSStatus
            if let format {
                sessionStatus = VTDecompressionSessionCreate(
                    allocator: kCFAllocatorDefault, formatDescription: format,
                    decoderSpecification: nil, imageBufferAttributes: nil,
                    outputCallback: nil, decompressionSessionOut: &session)
            } else {
                sessionStatus = formatStatus
            }
            print("CAPABILITY \(name): format=\(formatStatus) session=\(sessionStatus) hardware=\(VTIsHardwareDecodeSupported(codec))")
            if let session { VTDecompressionSessionInvalidate(session) }
        }
    }

    func testMPEG2DecodesKnownGoodFrameOnMac() throws {
        let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else {
            throw XCTSkip("ffmpeg test oracle is unavailable")
        }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m2v")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let generator = Process()
        generator.executableURL = ffmpeg
        generator.arguments = ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                               "testsrc=size=64x64:rate=25", "-frames:v", "1", "-pix_fmt", "yuv420p",
                               "-c:v", "mpeg2video", "-q:v", "3", "-f", "mpeg2video", fixture.path, "-y"]
        try generator.run()
        generator.waitUntilExit()
        XCTAssertEqual(generator.terminationStatus, 0)
        let encoded = try Data(contentsOf: fixture)

        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                       codecType: kCMVideoCodecType_MPEG2Video,
                                                       width: 64, height: 64, extensions: nil,
                                                       formatDescriptionOut: &format), noErr)
        let observation = DecodeObservation()
        let callback: VTDecompressionOutputCallback = { refcon, _, status, _, imageBuffer, _, _ in
            guard let refcon else { return }
            let state = Unmanaged<DecodeObservation>.fromOpaque(refcon).takeUnretainedValue()
            state.lastStatus = status
            if imageBuffer != nil { state.decodedFrames += 1 }
        }
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: callback,
            decompressionOutputRefCon: Unmanaged.passUnretained(observation).toOpaque())
        var session: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                     formatDescription: try XCTUnwrap(format),
                                                     decoderSpecification: nil,
                                                     imageBufferAttributes: nil,
                                                     outputCallback: &callbackRecord,
                                                     decompressionSessionOut: &session), noErr)
        let decoder = try XCTUnwrap(session)
        defer { VTDecompressionSessionInvalidate(decoder) }

        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                           memoryBlock: nil, blockLength: encoded.count,
                                                           blockAllocator: kCFAllocatorDefault,
                                                           customBlockSource: nil, offsetToData: 0,
                                                           dataLength: encoded.count, flags: 0,
                                                           blockBufferOut: &block), noErr)
        let buffer = try XCTUnwrap(block)
        XCTAssertEqual(encoded.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: try! XCTUnwrap(bytes.baseAddress), blockBuffer: buffer,
                                          offsetIntoDestination: 0, dataLength: encoded.count)
        }, noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 25),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = encoded.count
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: buffer,
                                                 formatDescription: format, sampleCount: 1,
                                                 sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                 sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                                 sampleBufferOut: &sample), noErr)
        var flags = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: try XCTUnwrap(sample),
                                                              flags: [], frameRefcon: nil,
                                                              infoFlagsOut: &flags)
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        print("DECODE MPEG2 macOS: submit=\(decodeStatus) callback=\(observation.lastStatus) frames=\(observation.decodedFrames)")
        XCTAssertEqual(decodeStatus, noErr)
        XCTAssertEqual(observation.lastStatus, noErr)
        XCTAssertGreaterThan(observation.decodedFrames, 0)
    }
}

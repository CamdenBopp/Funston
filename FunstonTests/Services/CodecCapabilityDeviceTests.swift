import XCTest
import CoreMedia
import VideoToolbox

/// Device/simulator codec probe. Format creation and actual decoded-frame output are
/// logged separately; a positive session status alone is not treated as support.
final class CodecCapabilityDeviceTests: XCTestCase {
    private final class DecodeState {
        var frames = 0
        var status: OSStatus = 0
    }

    func testMPEG2KnownGoodFrame() throws {
        let base64 = "AAABswQAQBP//+AYAAABtRSKAAEAAAAAAbgACABAAAABAAAP//gAAAG1j//zQYAAAAEBG/h9KUiLlKUiLlKUiLlKUiIAAAECG/h9KUiLlKUiLlKUiLlKUiIAAAEDG/h9KUiLlKUiLlKUiLlKUiIAAAEEG/h9KUiLlKUiLlKUiLlKUiI="
        let encoded = try XCTUnwrap(Data(base64Encoded: base64))
        var format: CMVideoFormatDescription?
        let formatStatus = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                           codecType: kCMVideoCodecType_MPEG2Video,
                                                           width: 64, height: 64,
                                                           extensions: nil, formatDescriptionOut: &format)
        XCTAssertEqual(formatStatus, noErr)
        let state = DecodeState()
        let callback: VTDecompressionOutputCallback = { refcon, _, status, _, image, _, _ in
            guard let refcon else { return }
            let state = Unmanaged<DecodeState>.fromOpaque(refcon).takeUnretainedValue()
            state.status = status
            if image != nil { state.frames += 1 }
        }
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: callback,
            decompressionOutputRefCon: Unmanaged.passUnretained(state).toOpaque())
        var session: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                         formatDescription: try XCTUnwrap(format),
                                                         decoderSpecification: nil,
                                                         imageBufferAttributes: nil,
                                                         outputCallback: &record,
                                                         decompressionSessionOut: &session)
        guard createStatus == noErr, let session else {
            print("DEVICE_CODEC MPEG2: session=\(createStatus) hardware=\(VTIsHardwareDecodeSupported(kCMVideoCodecType_MPEG2Video)) decoded=0")
            return
        }
        defer { VTDecompressionSessionInvalidate(session) }
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                           memoryBlock: nil, blockLength: encoded.count,
                                                           blockAllocator: kCFAllocatorDefault,
                                                           customBlockSource: nil, offsetToData: 0,
                                                           dataLength: encoded.count, flags: 0,
                                                           blockBufferOut: &block), noErr)
        let buffer = try XCTUnwrap(block)
        let copyStatus = encoded.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: buffer,
                                          offsetIntoDestination: 0, dataLength: encoded.count)
        }
        XCTAssertEqual(copyStatus, noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 25),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = encoded.count
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                                 dataBuffer: buffer, formatDescription: format,
                                                 sampleCount: 1, sampleTimingEntryCount: 1,
                                                 sampleTimingArray: &timing,
                                                 sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                                 sampleBufferOut: &sample), noErr)
        var flags = VTDecodeInfoFlags()
        let submit = VTDecompressionSessionDecodeFrame(session,
                                                       sampleBuffer: try XCTUnwrap(sample),
                                                       flags: [], frameRefcon: nil,
                                                       infoFlagsOut: &flags)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        print("DEVICE_CODEC MPEG2: session=\(createStatus) submit=\(submit) callback=\(state.status) decoded=\(state.frames) hardware=\(VTIsHardwareDecodeSupported(kCMVideoCodecType_MPEG2Video))")
    }
}

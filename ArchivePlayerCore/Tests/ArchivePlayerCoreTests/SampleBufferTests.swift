import XCTest
import CoreMedia
@testable import ArchivePlayerCore

final class SampleBufferTests: XCTestCase {
    func testAACDescriptionAndSampleBuffer() throws {
        // AAC-LC, 44.1 kHz, stereo (AudioSpecificConfig 0x1210).
        let format = try FormatDescriptionFactory.aac(audioSpecificConfig: Data([0x12, 0x10]))
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format))
        XCTAssertEqual(asbd.pointee.mSampleRate, 44_100)
        XCTAssertEqual(asbd.pointee.mChannelsPerFrame, 2)
        let packet = DemuxedPacket(trackID: 2, data: Data([0x21, 0x22, 0x23]),
                                   pts: .zero, duration: CMTime(value: 1024, timescale: 44_100))
        let sample = try SampleBufferFactory.make(packet: packet, format: format)
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), 1)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), .zero)
    }

    func testMalformedCodecConfigurationFails() {
        XCTAssertThrowsError(try FormatDescriptionFactory.h264(avcC: Data([1, 2, 3])))
        XCTAssertThrowsError(try FormatDescriptionFactory.aac(audioSpecificConfig: Data([0xFF])))
        XCTAssertThrowsError(try FormatDescriptionFactory.mpeg2Video(sequenceHeader: Data([0, 1, 2])))
    }

    func testOpusHeadDescription() throws {
        let header = Data(Array("OpusHead".utf8) + [
            1, 2,        // version, channels
            0x38, 0x01, // pre-skip 312
            0x80, 0xBB, 0, 0, // input rate 48 kHz
            0, 0, 0     // gain and channel mapping family
        ])
        let format = try FormatDescriptionFactory.opus(opusHead: header)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format))
        XCTAssertEqual(asbd.pointee.mSampleRate, 48_000)
        XCTAssertEqual(asbd.pointee.mChannelsPerFrame, 2)
    }

    func testAACConfigurationSevenMeansEightChannelsAndFrameLengthFlagMeans960() throws {
        let eightChannels = try FormatDescriptionFactory.aac(audioSpecificConfig: Data([0x12, 0x38]))
        let eight = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(eightChannels))
        XCTAssertEqual(eight.pointee.mChannelsPerFrame, 8)
        let shortFrames = try FormatDescriptionFactory.aac(audioSpecificConfig: Data([0x12, 0x14]))
        let short = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(shortFrames))
        XCTAssertEqual(short.pointee.mChannelsPerFrame, 2)
        XCTAssertEqual(short.pointee.mFramesPerPacket, 960)
    }
}

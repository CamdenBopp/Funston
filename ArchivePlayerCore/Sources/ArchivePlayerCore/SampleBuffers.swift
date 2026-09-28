import Foundation
import CoreMedia
import AudioToolbox

public enum FormatDescriptionFactory {
    /// Matroska AVC CodecPrivate is an AVCDecoderConfigurationRecord (ISO/IEC 14496-15).
    public static func h264(avcC: Data) throws -> CMVideoFormatDescription {
        let bytes = Array(avcC)
        guard bytes.count >= 7, bytes[0] == 1 else {
            throw DemuxError.invalidFormat("Invalid AVC configuration")
        }
        var cursor = 6
        let spsCount = Int(bytes[5] & 0x1F)
        guard spsCount > 0 else { throw DemuxError.invalidFormat("AVC configuration has no SPS") }
        var parameterSets = [[UInt8]]()
        for _ in 0..<spsCount {
            guard cursor + 2 <= bytes.count else { throw DemuxError.truncated }
            let size = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
            cursor += 2
            guard size > 0, size <= bytes.count - cursor else { throw DemuxError.truncated }
            parameterSets.append(Array(bytes[cursor..<(cursor + size)]))
            cursor += size
        }
        guard cursor < bytes.count else { throw DemuxError.truncated }
        let ppsCount = Int(bytes[cursor])
        cursor += 1
        guard ppsCount > 0 else { throw DemuxError.invalidFormat("AVC configuration has no PPS") }
        for _ in 0..<ppsCount {
            guard cursor + 2 <= bytes.count else { throw DemuxError.truncated }
            let size = (Int(bytes[cursor]) << 8) | Int(bytes[cursor + 1])
            cursor += 2
            guard size > 0, size <= bytes.count - cursor else { throw DemuxError.truncated }
            parameterSets.append(Array(bytes[cursor..<(cursor + size)]))
            cursor += size
        }
        let nalHeaderLength = Int(bytes[4] & 0x03) + 1
        let storage = parameterSets.map { bytes -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytes.count)
            pointer.initialize(from: bytes, count: bytes.count)
            return pointer
        }
        defer { storage.forEach { $0.deallocate() } }
        var pointers: [UnsafePointer<UInt8>] = storage.map { UnsafePointer($0) }
        var sizes = parameterSets.map(\.count)
        var result: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault, parameterSetCount: parameterSets.count,
            parameterSetPointers: &pointers, parameterSetSizes: &sizes,
            nalUnitHeaderLength: Int32(nalHeaderLength), formatDescriptionOut: &result)
        guard status == noErr, let result else {
            throw DemuxError.unsupported("H.264 format description failed: \(status)")
        }
        return result
    }

    /// AAC AudioSpecificConfig is commonly two bytes. Extended AOT/frequency variants
    /// deliberately fail until their bitstream representation is covered by tests.
    public static func aac(audioSpecificConfig: Data) throws -> CMAudioFormatDescription {
        let bytes = Array(audioSpecificConfig)
        guard bytes.count >= 2 else { throw DemuxError.truncated }
        let objectType = bytes[0] >> 3
        let frequencyIndex = Int(((bytes[0] & 0x07) << 1) | (bytes[1] >> 7))
        let channelConfiguration = Int((bytes[1] >> 3) & 0x0F)
        // ISO/IEC 14496-3 Table 1.19: configuration 7 denotes eight
        // channels; configuration 0 requires a ProgramConfigElement.
        let channels = channelConfiguration == 7 ? UInt32(8) : UInt32(channelConfiguration)
        let framesPerPacket: UInt32 = (bytes[1] & 0x04) != 0 ? 960 : 1024
        let rates: [Float64] = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000,
                                24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350]
        guard objectType == 2, frequencyIndex < rates.count,
              (1...7).contains(channelConfiguration) else {
            throw DemuxError.unsupported("AAC profile/frequency/channel configuration")
        }
        var asbd = AudioStreamBasicDescription(mSampleRate: rates[frequencyIndex],
                                                mFormatID: kAudioFormatMPEG4AAC,
                                                mFormatFlags: 0, mBytesPerPacket: 0,
                                                mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
                                                mChannelsPerFrame: channels, mBitsPerChannel: 0,
                                                mReserved: 0)
        var result: CMAudioFormatDescription?
        // ASC describes the ASBD fields above, but is not an Apple AAC
        // decompression magic cookie. The real IA AudioConverter probe rejected
        // raw ASC as a cookie (!dat) and decoded the packet with this ASBD.
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                    asbd: &asbd, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil,
                                                    extensions: nil, formatDescriptionOut: &result)
        guard status == noErr, let result else {
            throw DemuxError.unsupported("AAC format description failed: \(status)")
        }
        return result
    }

    public static func opus(opusHead: Data) throws -> CMAudioFormatDescription {
        let bytes = Array(opusHead)
        guard bytes.count >= 19,
              bytes.prefix(8).elementsEqual(Array("OpusHead".utf8)),
              bytes[8] == 1, bytes[9] > 0 else {
            throw DemuxError.invalidFormat("Invalid OpusHead")
        }
        let channels = UInt32(bytes[9])
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000,
                                                mFormatID: kAudioFormatOpus,
                                                mFormatFlags: 0, mBytesPerPacket: 0,
                                                mFramesPerPacket: 960, mBytesPerFrame: 0,
                                                mChannelsPerFrame: channels, mBitsPerChannel: 0,
                                                mReserved: 0)
        var result: CMAudioFormatDescription?
        let status = bytes.withUnsafeBytes { cookie in
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                           layoutSize: 0, layout: nil,
                                           magicCookieSize: cookie.count,
                                           magicCookie: cookie.baseAddress,
                                           extensions: nil, formatDescriptionOut: &result)
        }
        guard status == noErr, let result else {
            throw DemuxError.unsupported("Opus format description failed: \(status)")
        }
        return result
    }

    public static func mpeg2Video(sequenceHeader packet: Data) throws -> CMVideoFormatDescription {
        let bytes = Array(packet)
        guard bytes.count >= 8 else { throw DemuxError.truncated }
        guard let i = (0..<(bytes.count - 7)).first(where: {
            bytes[$0] == 0 && bytes[$0 + 1] == 0 && bytes[$0 + 2] == 1 && bytes[$0 + 3] == 0xB3
        }) else { throw DemuxError.invalidFormat("MPEG-2 sequence header missing") }
        let width = (Int(bytes[i + 4]) << 4) | (Int(bytes[i + 5]) >> 4)
        let height = (Int(bytes[i + 5] & 0x0F) << 8) | Int(bytes[i + 6])
        guard width > 0, height > 0 else { throw DemuxError.invalidFormat("Invalid MPEG-2 dimensions") }
        var result: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                     codecType: kCMVideoCodecType_MPEG2Video,
                                                     width: Int32(width), height: Int32(height),
                                                     extensions: nil, formatDescriptionOut: &result)
        guard status == noErr, let result else {
            throw DemuxError.unsupported("MPEG-2 format description failed: \(status)")
        }
        return result
    }
}

public enum SampleBufferFactory {
    /// This baseline performs exactly one copy from Data into CoreMedia-owned memory.
    /// A borrowed Data pointer is not safe once withUnsafeBytes returns; zero-copy
    /// requires an explicit lifetime-owning custom block source.
    public static func make(packet: DemuxedPacket,
                            format: CMFormatDescription) throws -> CMSampleBuffer {
        guard !packet.data.isEmpty else { throw DemuxError.invalidFormat("Empty packet") }
        var block: CMBlockBuffer?
        let create = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                        memoryBlock: nil,
                                                        blockLength: packet.data.count,
                                                        blockAllocator: kCFAllocatorDefault,
                                                        customBlockSource: nil, offsetToData: 0,
                                                        dataLength: packet.data.count, flags: 0,
                                                        blockBufferOut: &block)
        guard create == noErr, let block else {
            throw DemuxError.unsupported("CMBlockBuffer allocation failed: \(create)")
        }
        let copy = packet.data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copy == noErr else { throw DemuxError.unsupported("CMBlockBuffer copy failed: \(copy)") }
        var timing = CMSampleTimingInfo(duration: packet.duration,
                                        presentationTimeStamp: packet.pts,
                                        decodeTimeStamp: packet.dts)
        var size = packet.data.count
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                               dataBuffer: block,
                                               formatDescription: format,
                                               sampleCount: 1,
                                               sampleTimingEntryCount: 1,
                                               sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1,
                                               sampleSizeArray: &size,
                                               sampleBufferOut: &result)
        guard status == noErr, let result else {
            throw DemuxError.unsupported("CMSampleBuffer creation failed: \(status)")
        }
        if !packet.isKeyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return result
    }
}

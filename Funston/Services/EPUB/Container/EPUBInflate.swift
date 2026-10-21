import Compression
import Foundation

/// Raw DEFLATE decoding for ZIP entries. The Compression framework's zlib mode
/// is the raw rfc1951 stream, which is exactly what a ZIP entry holds: no zlib
/// header, no Adler-32 trailer.
enum EPUBInflate {
    /// Entries above this size decode through a window loop instead of one
    /// allocation of the declared size.
    static let singleShotLimit = 4 * 1024 * 1024
    static let windowSize = 1024 * 1024

    enum Failure: Error, Equatable {
        /// The stream ended before the declared size was reached.
        case truncated
        /// The stream produced more output than the central directory declares.
        case overlong
        /// The decoder reported corrupt input.
        case corrupt
        case initialization
    }

    static func inflate(_ source: Data, declaredSize: Int) throws(Failure) -> Data {
        guard declaredSize > 0 else {
            // A zero-length entry carries an empty stream; nothing to decode.
            return Data()
        }
        let bufferSize = min(declaredSize, singleShotLimit > declaredSize ? declaredSize : windowSize)
        var output = Data()
        output.reserveCapacity(declaredSize)
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw .initialization
        }
        defer { compression_stream_destroy(streamPointer) }

        let result: Result<Void, Failure> = source.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return .failure(.corrupt) }
            streamPointer.pointee.src_ptr = base.assumingMemoryBound(to: UInt8.self)
            streamPointer.pointee.src_size = raw.count
            while true {
                streamPointer.pointee.dst_ptr = destination
                streamPointer.pointee.dst_size = bufferSize
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - streamPointer.pointee.dst_size
                if produced > 0 {
                    if output.count + produced > declaredSize { return .failure(.overlong) }
                    output.append(destination, count: produced)
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return output.count == declaredSize ? .success(()) : .failure(.truncated)
                case COMPRESSION_STATUS_OK:
                    if produced == 0 {
                        // No progress with all input consumed: the stream stopped early.
                        return .failure(streamPointer.pointee.src_size == 0 ? .truncated : .corrupt)
                    }
                    if output.count > declaredSize { return .failure(.overlong) }
                    continue
                default:
                    return .failure(.corrupt)
                }
            }
        }
        switch result {
        case .success: return output
        case .failure(let failure): throw failure
        }
    }
}

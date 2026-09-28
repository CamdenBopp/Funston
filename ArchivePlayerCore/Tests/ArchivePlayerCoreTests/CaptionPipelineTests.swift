import XCTest
import CoreMedia
@testable import ArchivePlayerCore

final class CaptionPipelineTests: XCTestCase {
    private func track(_ codec: String = "S_TEXT/UTF8", id: UInt32 = 1) -> MediaTrack { MediaTrack(id: id, kind: .subtitle, codec: codec) }
    private func packet(_ text: String, start: Int64 = 1, duration: Int64 = 2, id: UInt32 = 1) -> DemuxedPacket {
        DemuxedPacket(trackID: id, data: Data(text.utf8), pts: CMTime(value: start, timescale: 1), duration: CMTime(value: duration, timescale: 1))
    }
    func testUTF8TimingAndSafeLiteralMarkup() throws {
        var pipeline = CaptionPipeline()
        let cue = try pipeline.ingest(packet("<i>Hello</i> &amp; &#x1F600;<br>2 < 3\r\n&lt;b&gt;literal&lt;/b&gt;"), track: track())
        XCTAssertEqual(cue.text, "Hello & 😀\n2 < 3\n<b>literal</b>")
        XCTAssertTrue(pipeline.activeCues(at: .zero).isEmpty)
        XCTAssertEqual(pipeline.activeCues(at: CMTime(value: 1, timescale: 1)), [cue])
        XCTAssertTrue(pipeline.activeCues(at: CMTime(value: 3, timescale: 1)).isEmpty)
        XCTAssertTrue(pipeline.activeCues(at: .invalid).isEmpty)
    }
    func testASSAndSSAFieldsCommasAndOverrides() throws {
        for codec in ["S_TEXT/ASS", "S_TEXT/SSA"] {
            var pipeline = CaptionPipeline()
            let cue = try pipeline.ingest(packet(#"7,,Default,Speaker,0,0,0,,{\an8\i1}Hello, world!\NNext\hline &amp;"#), track: track(codec))
            XCTAssertEqual(cue.text, "Hello, world!\nNext\u{00a0}line &amp;")
        }
    }
    func testWebVTTMatroskaAndWebMDifferentFraming() throws {
        var pipeline = CaptionPipeline()
        let body = "<v Alice><b>Hi</b> &lt;there&gt;</v>"
        let matroska = try pipeline.ingest(packet(body), track: track("S_TEXT/WEBVTT"))
        let webm = try pipeline.ingest(packet("id-1\nline:90%\n" + body), track: track("D_WEBVTT/CAPTIONS"))
        XCTAssertEqual(matroska.text, "Hi <there>")
        XCTAssertEqual(matroska.text, webm.text)
        XCTAssertThrowsError(try pipeline.ingest(packet("not framed"), track: track("D_WEBVTT/SUBTITLES")))
        XCTAssertThrowsError(try pipeline.ingest(packet("Now<00:00:01.000>Later"), track: track("S_TEXT/WEBVTT"))) { error in
            XCTAssertEqual(error as? CaptionError, .unsupportedFeature("WebVTT inline timestamp animation"))
        }
    }
    func testOverlapsSelectionOutOfOrderAndReset() throws {
        var pipeline = CaptionPipeline()
        try pipeline.ingest(packet("Later", start: 3, duration: 3), track: track())
        try pipeline.ingest(packet("Earlier", start: 2, duration: 3), track: track())
        try pipeline.ingest(packet("Other language", start: 2, duration: 3, id: 2), track: track(id: 2))
        let time = CMTime(value: 4, timescale: 1)
        XCTAssertEqual(pipeline.activeCues(at: time, trackID: 1).map(\.text), ["Earlier", "Later"])
        XCTAssertEqual(pipeline.activeCues(at: time, trackID: 2).map(\.text), ["Other language"])
        // Repeat the same paused synchronizer time: no wall-clock expiry occurs.
        XCTAssertEqual(pipeline.activeCues(at: time).count, 3)
        pipeline.prune(endingBefore: CMTime(value: 5, timescale: 1))
        XCTAssertEqual(pipeline.activeCues(at: time).map(\.text), ["Later"])
        pipeline.reset(); XCTAssertTrue(pipeline.activeCues(at: time).isEmpty)
    }
    func testTypedFailuresDoNotInsertCues() throws {
        var pipeline = CaptionPipeline(maximumCues: 1, maximumPayloadBytes: 128)
        XCTAssertThrowsError(try pipeline.ingest(packet("bitmap"), track: track("S_HDMV/PGS"))) { XCTAssertEqual($0 as? CaptionError, .unsupportedCodec("S_HDMV/PGS")) }
        XCTAssertThrowsError(try pipeline.ingest(packet("no duration", duration: 0), track: track())) { XCTAssertEqual($0 as? CaptionError, .invalidTiming) }
        XCTAssertThrowsError(try pipeline.ingest(packet("wrong", id: 2), track: track())) { XCTAssertEqual($0 as? CaptionError, .trackMismatch) }
        let invalid = DemuxedPacket(trackID: 1, data: Data([0xff]), pts: .zero, duration: CMTime(value: 1, timescale: 1))
        XCTAssertThrowsError(try pipeline.ingest(invalid, track: track())) { XCTAssertEqual($0 as? CaptionError, .malformedText("Invalid UTF-8")) }
        XCTAssertThrowsError(try pipeline.ingest(packet(#"0,0,Default,,0,0,0,,{\p1}m 0 0 l 20 20"#), track: track("S_TEXT/ASS")))
        try pipeline.ingest(packet("valid"), track: track())
        XCTAssertThrowsError(try pipeline.ingest(packet("over capacity"), track: track())) { XCTAssertEqual($0 as? CaptionError, .resourceLimit) }
    }
}

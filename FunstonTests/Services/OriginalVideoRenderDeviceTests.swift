import XCTest
import AVFoundation
import UIKit
import ArchivePlayerCore

@MainActor final class OriginalVideoRenderDeviceTests: XCTestCase {
    func testRealIAMKVRendererOnThisPlatform() async throws {
        guard ProcessInfo.processInfo.environment["IA_RENDER_TESTS"] == "1" else {
            throw XCTSkip("Set IA_RENDER_TESTS=1 to run the live IA renderer probe")
        }
        let url = URL(string: "https://archive.org/download/the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub/")!
            .appendingPathComponent("The Ancient Magus' Bride S01E03 720p HD BluRay Multi Audio ESub.mkv")
        let source = HTTPRangeByteSource(url: url)
        let engine = SampleBufferPlaybackEngine(demuxer: MatroskaDemuxer(source: source))
        guard let renderers = engine.rendering as? SampleBufferPlaybackRenderers else {
            XCTFail("Expected platform renderers"); return
        }
        renderers.audioRenderer.volume = 0
        let started = ProcessInfo.processInfo.systemUptime
        try await engine.prepare()
        try engine.play()
        try await Task.sleep(for: .seconds(4))
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let bytes = await source.transferredBytes
        print("DEVICE_RENDER \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion): state=\(engine.state) time=\(engine.currentTime.seconds) video=\(renderers.displayLayer.sampleBufferRenderer.status.rawValue) audio=\(renderers.audioRenderer.status.rawValue) packets=\(engine.enqueuedPacketCount) bytes=\(bytes) elapsed=\(elapsed) error=\(engine.lastError ?? "none")")
        XCTAssertNil(engine.lastError)
        XCTAssertGreaterThan(engine.enqueuedPacketCount, 0)
        XCTAssertGreaterThan(engine.currentTime.seconds, 0)
        XCTAssertEqual(renderers.displayLayer.sampleBufferRenderer.status, .rendering)
        XCTAssertEqual(renderers.audioRenderer.status, .rendering)
        await engine.stop()
    }
}

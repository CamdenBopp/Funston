import XCTest
import AVFoundation
import UIKit
import ArchivePlayerCore

/// Opt-in network gate: this is a renderer/clock check, not a visible or audible QA pass.
@MainActor final class OriginalTransportStreamRenderDeviceTests: XCTestCase {
    func testRealIATransportStreamRendererOnThisPlatform() async throws {
        guard ProcessInfo.processInfo.environment["IA_TS_RENDER_TESTS"] == "1" else {
            throw XCTSkip("Set IA_TS_RENDER_TESTS=1 to run the live TS renderer probe")
        }
        let url = URL(string: "https://archive.org/download/twitch-videos-2179756722/2179756722.ts")!
        let source = HTTPRangeByteSource(url: url, windowSize: 256 * 1024)
        let renderers = SampleBufferPlaybackRenderers()
        renderers.audioRenderer.volume = 0
        let engine = SampleBufferPlaybackEngine(
            demuxer: TransportStreamAccessUnitDemuxer(source: source), rendering: renderers)
        let started = ProcessInfo.processInfo.systemUptime
        try await engine.prepare()
        try engine.play()
        var bothRendering = false
        for _ in 0..<200 {
            if engine.lastError != nil { break }
            if renderers.displayLayer.sampleBufferRenderer.status == .rendering,
               renderers.audioRenderer.status == .rendering {
                bothRendering = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let clockAtRendering = engine.currentTime.seconds
        try await Task.sleep(for: .seconds(3))
        let bytes = await source.transferredBytes
        print("DEVICE_TS_RENDER \(UIDevice.current.model) iOS \(UIDevice.current.systemVersion): bothRendering=\(bothRendering) state=\(engine.state) samples=\(engine.enqueuedPacketCount) clockAdvance=\(engine.currentTime.seconds - clockAtRendering) bytes=\(bytes) elapsed=\(ProcessInfo.processInfo.systemUptime - started) video=\(renderers.displayLayer.sampleBufferRenderer.status.rawValue) audio=\(renderers.audioRenderer.status.rawValue) error=\(engine.lastError ?? "none")")
        XCTAssertTrue(bothRendering)
        XCTAssertNil(engine.lastError)
        XCTAssertEqual(renderers.displayLayer.sampleBufferRenderer.status, .rendering)
        XCTAssertEqual(renderers.audioRenderer.status, .rendering)
        XCTAssertGreaterThan(engine.enqueuedPacketCount, 10)
        XCTAssertGreaterThan(engine.currentTime.seconds - clockAtRendering, 2)
        await engine.stop()
    }
}

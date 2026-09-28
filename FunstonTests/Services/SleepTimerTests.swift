import XCTest
@testable import Funston

@MainActor final class SleepTimerTests: XCTestCase {
    private final class FakeTarget: SleepTimerTarget {
        var stopsAfterCurrentRecording = false
        var stoppedAfterCurrentRecording: (() -> Void)?
        var fades = 0
        func fadeOutAndPause() async { fades += 1 }
    }

    func testCountdownFadesThenTurnsItselfOffAndSaysSo() async throws {
        let target = FakeTarget()
        var waited: [Duration] = []
        var spoken: [String] = []
        let timer = SleepTimer(sleep: { waited.append($0) }, announce: { spoken.append($0) })
        timer.attach(to: target)
        timer.start(after: .seconds(30 * 60))
        XCTAssertNotEqual(timer.setting, .off)
        try await waitUntil { timer.setting == .off }
        XCTAssertEqual(waited, [.seconds(30 * 60)])
        XCTAssertEqual(target.fades, 1)
        XCTAssertEqual(spoken, ["Sleep timer set for 30 minutes.", "Sleep timer ended. Playback paused."])
    }

    func testTurningOffCancelsTheCountdown() async throws {
        let target = FakeTarget()
        let timer = SleepTimer(sleep: { try await Task.sleep(for: $0) }, announce: { _ in })
        timer.attach(to: target)
        timer.start(after: .seconds(15 * 60))
        timer.turnOff()
        XCTAssertEqual(timer.setting, .off)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(target.fades, 0)
    }

    func testEndOfRecordingAsksPlaybackToStopAndClearsWhenItDoes() {
        let target = FakeTarget()
        var spoken: [String] = []
        let timer = SleepTimer(announce: { spoken.append($0) })
        timer.attach(to: target)
        timer.stopAtEndOfRecording()
        XCTAssertTrue(target.stopsAfterCurrentRecording)
        target.stoppedAfterCurrentRecording?()
        XCTAssertEqual(timer.setting, .off)
        XCTAssertFalse(target.stopsAfterCurrentRecording)
        XCTAssertEqual(spoken.last, "Sleep timer ended. Playback paused.")
        // Switching from end-of-recording to a countdown must clear the stop request.
        timer.stopAtEndOfRecording()
        timer.start(after: .seconds(15 * 60))
        XCTAssertFalse(target.stopsAfterCurrentRecording)
    }

    func testRemainingMinutesRoundUp() {
        let start = Date(timeIntervalSince1970: 0)
        let timer = SleepTimer(now: { start }, sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }, announce: { _ in })
        timer.start(after: .seconds(15 * 60))
        XCTAssertEqual(timer.minutesRemaining(at: start), 15)
        XCTAssertEqual(timer.minutesRemaining(at: start.addingTimeInterval(14 * 60 + 30)), 1, "The last minute never reads zero")
        timer.turnOff()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
}

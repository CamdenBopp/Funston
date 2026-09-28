import Foundation
import UIKit

/// What the sleep timer needs from playback. A protocol so the timer can be
/// tested without an audio session.
@MainActor protocol SleepTimerTarget: AnyObject {
    var stopsAfterCurrentRecording: Bool { get set }
    var stoppedAfterCurrentRecording: (() -> Void)? { get set }
    func fadeOutAndPause() async
}

/// Pauses playback after a chosen time or at the end of the current recording.
/// One scheduled wait, not a repeating timer, so it costs nothing while it runs.
@MainActor final class SleepTimer: ObservableObject {
    enum Setting: Equatable {
        case off
        case until(Date)
        case endOfRecording
    }

    static let choices: [Duration] = [.seconds(15 * 60), .seconds(30 * 60), .seconds(45 * 60), .seconds(60 * 60)]

    @Published private(set) var setting: Setting = .off
    private weak var target: SleepTimerTarget?
    private var wait: Task<Void, Never>?
    private let now: () -> Date
    private let sleep: (Duration) async throws -> Void
    private let announce: (String) -> Void

    init(now: @escaping () -> Date = Date.init,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         announce: @escaping (String) -> Void = { UIAccessibility.post(notification: .announcement, argument: $0) }) {
        self.now = now; self.sleep = sleep; self.announce = announce
    }

    func attach(to target: SleepTimerTarget) {
        self.target = target
        target.stoppedAfterCurrentRecording = { [weak self] in self?.finished() }
    }

    func start(after duration: Duration) {
        reset()
        setting = .until(now().addingTimeInterval(TimeInterval(duration.components.seconds)))
        announce("Sleep timer set for \(Self.spoken(duration)).")
        wait = Task { [weak self, sleep] in
            do { try await sleep(duration) } catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.target?.fadeOutAndPause()
            self.finished()
        }
    }

    func stopAtEndOfRecording() {
        reset()
        setting = .endOfRecording
        target?.stopsAfterCurrentRecording = true
        announce("Playback will stop at the end of this recording.")
    }

    func turnOff() {
        guard setting != .off else { return }
        reset()
        announce("Sleep timer off.")
    }

    /// Whole minutes left, rounded up so the last minute never reads "0 minutes".
    func minutesRemaining(at date: Date? = nil) -> Int? {
        guard case .until(let deadline) = setting else { return nil }
        return max(1, Int((deadline.timeIntervalSince(date ?? now()) / 60).rounded(.up)))
    }

    private func finished() {
        wait = nil
        target?.stopsAfterCurrentRecording = false
        guard setting != .off else { return }
        setting = .off
        announce("Sleep timer ended. Playback paused.")
    }

    private func reset() {
        wait?.cancel(); wait = nil
        target?.stopsAfterCurrentRecording = false
        setting = .off
    }

    static func spoken(_ duration: Duration) -> String {
        let minutes = Int(duration.components.seconds / 60)
        return minutes == 60 ? "1 hour" : "\(minutes) minutes"
    }
}

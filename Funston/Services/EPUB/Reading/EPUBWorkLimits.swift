import Foundation
import os

/// The bounded-work limits of Spec 19.3: what the reader refuses or degrades
/// before a hostile or enormous book can exhaust memory or time. Derived once
/// from the memory available to the process; tests inject smaller values.
struct EPUBWorkLimits: Sendable, Hashable {
    /// The largest single entry the reader will inflate.
    var entryBytes: UInt64 = EPUBWorkLimits.defaultEntryBytes
    /// The largest sum of declared uncompressed sizes an archive may have.
    var bookBytes: UInt64 = EPUBWorkLimits.minimumBookBytes
    /// A chapter whose styled build runs past this renders as plain text.
    var chapterBuildBudget: Duration = EPUBWorkLimits.defaultChapterBuildBudget
    /// A chapter whose layout runs past this is laid out again as plain text.
    var layoutBudget: Duration = EPUBWorkLimits.defaultLayoutBudget
    /// TextKit 2's own guard against pathological text (Spec 19.3; open question 5).
    var limitsSuspiciousLayout = false

    static let defaultEntryBytes: UInt64 = 256 * 1024 * 1024
    /// Chapters are read lazily, so the book cap guards against declared-size
    /// bombs, not residency: this many times the available memory, never below the floor.
    static let bookBytesPerAvailableByte: UInt64 = 8
    static let minimumBookBytes: UInt64 = 1024 * 1024 * 1024
    static let defaultChapterBuildBudget: Duration = .seconds(2)
    static let defaultLayoutBudget: Duration = .seconds(3)

    static let standard = derived(availableMemory: UInt64(max(0, os_proc_available_memory())))

    static func derived(availableMemory: UInt64) -> EPUBWorkLimits {
        let (scaled, overflow) = availableMemory.multipliedReportingOverflow(by: bookBytesPerAvailableByte)
        var limits = EPUBWorkLimits()
        limits.bookBytes = overflow ? .max : max(minimumBookBytes, scaled)
        return limits
    }

    /// The instant after which work on one unit must stop.
    func deadline(_ budget: KeyPath<EPUBWorkLimits, Duration>) -> ContinuousClock.Instant {
        ContinuousClock.now + self[keyPath: budget]
    }
}

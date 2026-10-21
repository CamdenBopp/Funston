import Foundation

/// The book-wide progress scale (Spec 12.3): each linear spine item weighs
/// its uncompressed size; a location is 1,024 bytes of that scale.
struct EPUBProgressScale: Sendable, Hashable {
    static let bytesPerLocation: UInt64 = 1024

    let weights: [UInt64]
    /// Bytes before each spine item.
    let starts: [UInt64]
    let total: UInt64

    init(weights: [UInt64]) {
        self.weights = weights
        var starts: [UInt64] = []
        var running: UInt64 = 0
        for weight in weights { starts.append(running); running += weight }
        self.starts = starts
        total = running
    }

    var totalLocations: Int {
        total == 0 ? 1 : Int((total + Self.bytesPerLocation - 1) / Self.bytesPerLocation)
    }

    /// Bytes through a position: the item's start plus its fraction of the item's weight.
    func bytes(spineIndex: Int, progression: Double) -> UInt64 {
        guard weights.indices.contains(spineIndex) else { return 0 }
        let fraction = min(1, max(0, progression))
        return starts[spineIndex] + UInt64((Double(weights[spineIndex]) * fraction).rounded(.down))
    }

    /// The book fraction of a position in 0...1.
    func fraction(spineIndex: Int, progression: Double) -> Double {
        guard total > 0 else { return 0 }
        return min(1, Double(bytes(spineIndex: spineIndex, progression: progression)) / Double(total))
    }

    /// The 1-based location of a position.
    func location(spineIndex: Int, progression: Double) -> Int {
        min(totalLocations, Int(bytes(spineIndex: spineIndex, progression: progression) / Self.bytesPerLocation) + 1)
    }

    /// The item and the fraction within it at a book fraction: the inverse map
    /// for the scrubber and for total-progression fallbacks.
    func position(forFraction fraction: Double) -> (spineIndex: Int, progression: Double)? {
        guard total > 0 else { return weights.indices.first { weights[$0] > 0 }.map { ($0, 0) } ?? (weights.isEmpty ? nil : (0, 0)) }
        let target = Double(total) * min(1, max(0, fraction))
        var chosen: Int?
        for index in weights.indices where weights[index] > 0 {
            if Double(starts[index]) <= target { chosen = index } else { break }
        }
        guard let index = chosen else { return nil }
        let within = (target - Double(starts[index])) / Double(weights[index])
        return (index, min(1, max(0, within)))
    }
}

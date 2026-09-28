import Foundation
import CoreMedia

public struct CEA608CaptionEvent: Sendable, Equatable {
    public let time: CMTime
    public let text: String
}

/// Narrow CEA-608 text state machine for already-extracted, field-selected byte pairs.
/// Does not extract MPEG user_data/SEI, decode 708, or reproduce caption styling.
public struct CEA608CaptionDecoder: Sendable {
    public enum Channel: Int, Sendable { case one = 1, two = 2 }
    private enum Mode: Sendable { case popOn, paintOn, rollUp(Int) }
    private let selectedChannel: Channel
    private let validateParity: Bool
    private var activeChannel: Channel = .one
    private var mode: Mode = .popOn
    private var displayed = Self.emptyScreen()
    private var hidden = Self.emptyScreen()
    private var row = 14
    private var column = 0
    private var lastControl: UInt16?

    public init(channel: Channel = .one, validateOddParity: Bool = true) {
        selectedChannel = channel; validateParity = validateOddParity
    }
    private static func emptyScreen() -> [[Character]] { Array(repeating: Array(repeating: " ", count: 32), count: 15) }
    public var displayedText: String {
        let lines = displayed.map { String($0).replacingOccurrences(of: #" +$"#, with: "", options: .regularExpression) }
        guard let first = lines.firstIndex(where: { !$0.isEmpty }), let last = lines.lastIndex(where: { !$0.isEmpty }) else { return "" }
        return lines[first...last].joined(separator: "\n")
    }
    public mutating func reset() {
        displayed = Self.emptyScreen(); hidden = Self.emptyScreen(); row = 14; column = 0
        mode = .popOn; lastControl = nil; activeChannel = .one
    }

    /// Returns a timestamped replacement snapshot only when visible text changes.
    /// Empty text means erase the overlay. Repeated control pairs are suppressed.
    public mutating func consume(_ first: UInt8, _ second: UInt8, at time: CMTime) throws -> CEA608CaptionEvent? {
        var candidate = self
        let event = try candidate.consumePair(first, second, at: time)
        self = candidate
        return event
    }

    private mutating func consumePair(_ first: UInt8, _ second: UInt8, at time: CMTime) throws -> CEA608CaptionEvent? {
        guard time.isNumeric else { throw CaptionError.invalidTiming }
        if validateParity, first.nonzeroBitCount % 2 != 1 || second.nonzeroBitCount % 2 != 1 { throw CaptionError.invalidParity }
        let a = first & 0x7f; let b = second & 0x7f
        let previous = displayedText
        if (0x10...0x1f).contains(a) {
            activeChannel = a & 0x08 == 0 ? .one : .two
            guard activeChannel == selectedChannel else { lastControl = nil; return nil }
            let pair = UInt16(a) << 8 | UInt16(b)
            if lastControl == pair { lastControl = nil; return nil }
            lastControl = pair
            let normalized = a & 0x17
            if normalized == 0x14, (0x20...0x2f).contains(b) {
                switch b {
                case 0x20: mode = .popOn // RCL
                case 0x21: // BS
                    if column > 0 { column -= 1; write(" ", advance: false) }
                case 0x24: // DER
                    for c in column..<32 { set(" ", row: row, column: c) }
                case 0x25...0x27:
                    if case .rollUp = mode { } else { displayed = Self.emptyScreen(); hidden = Self.emptyScreen(); row = 14; column = 0 }
                    let count = Int(b - 0x23)
                    for r in 0..<max(0, row - count + 1) { displayed[r] = Array(repeating: " ", count: 32) }
                    mode = .rollUp(count)
                case 0x29: mode = .paintOn // RDC
                case 0x2c: displayed = Self.emptyScreen() // EDM
                case 0x2d: // CR
                    if case .rollUp(let rows) = mode {
                        let top = max(0, row - rows + 1)
                        if top < row { for r in top..<row { displayed[r] = displayed[r + 1] } }
                        displayed[row] = Array(repeating: " ", count: 32); column = 0
                    }
                case 0x2e: hidden = Self.emptyScreen() // ENM
                case 0x2f: // EOC
                    swap(&displayed, &hidden); mode = .popOn; row = 14; column = 0
                case 0x28: break // Flash styling is intentionally flattened.
                default: throw CaptionError.unsupportedFeature("CEA-608 text/alarm mode")
                }
            } else if (0x40...0x7f).contains(b) {
                let rows = [10, -1, 0, 1, 2, 3, 11, 12, 13, 14, 4, 5, 6, 7, 8, 9]
                let target = rows[Int((a & 7) << 1 | ((b & 0x20) >> 5))]
                guard target >= 0 else { throw CaptionError.malformedText("Invalid CEA-608 PAC") }
                if case .rollUp(let count) = mode, target != row {
                    guard target >= count - 1 else { throw CaptionError.unsupportedFeature("CEA-608 roll-up window above display") }
                    let lines = Array(displayed[max(0, row - count + 1)...row])
                    displayed = Self.emptyScreen()
                    for (index, line) in lines.enumerated() { displayed[target - lines.count + 1 + index] = line }
                }
                row = target; column = b & 0x10 != 0 ? Int((b & 0x0e) >> 1) * 4 : 0
            } else if normalized == 0x17, (0x21...0x23).contains(b) {
                column = min(31, column + Int(b - 0x20))
            } else if normalized == 0x11, (0x20...0x2f).contains(b) {
                write(" ") // Mid-row style changes occupy one character cell.
            } else if normalized == 0x11, (0x30...0x3f).contains(b) {
                let special = Array("®°½¿™¢£♪à èâêîôû")
                write(special[Int(b - 0x30)])
            } else { throw CaptionError.unsupportedFeature("CEA-608 extended/control character") }
        } else {
            lastControl = nil
            guard activeChannel == selectedChannel else { return nil }
            for byte in [a, b] {
                if byte == 0 { continue }
                guard byte >= 0x20 else { throw CaptionError.unsupportedFeature("CEA-608 nonprinting data") }
                let substitutions: [UInt8: Character] = [0x2a: "á", 0x5c: "é", 0x5e: "í", 0x5f: "ó", 0x60: "ú", 0x7b: "ç", 0x7c: "÷", 0x7d: "Ñ", 0x7e: "ñ", 0x7f: "█"]
                write(substitutions[byte] ?? Character(UnicodeScalar(byte)))
            }
        }
        let text = displayedText
        return text == previous ? nil : CEA608CaptionEvent(time: time, text: text)
    }

    private mutating func write(_ character: Character, advance: Bool = true) {
        guard column < 32 else { return }
        set(character, row: row, column: column)
        if advance { column = min(31, column + 1) }
    }
    private mutating func set(_ character: Character, row: Int, column: Int) {
        if case .popOn = mode { hidden[row][column] = character }
        else { displayed[row][column] = character }
    }
}

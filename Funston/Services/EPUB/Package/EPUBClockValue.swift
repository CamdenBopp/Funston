import Foundation

/// SMIL clock values (EPUB 3.3 appendix H.4): full clock `h:mm:ss.f`, partial
/// clock `mm:ss.f`, and timecount `n(.f)?(h|min|s|ms)?`. A string that fits
/// no production is nil, never zero, so a bad value cannot restart audio.
enum EPUBClockValue {
    private static let nptPrefix = "npt="

    static func seconds(_ text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix(nptPrefix) { value = String(value.dropFirst(nptPrefix.count)) }
        guard !value.isEmpty else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 3:
            guard let hours = digits(parts[0]), let minutes = twoDigits(parts[1]), let seconds = fractionalSeconds(parts[2]) else { return nil }
            return Double(hours) * 3600 + Double(minutes) * 60 + seconds
        case 2:
            guard let minutes = twoDigits(parts[0]), let seconds = fractionalSeconds(parts[1]) else { return nil }
            return Double(minutes) * 60 + seconds
        case 1:
            return timecount(parts[0])
        default:
            return nil
        }
    }

    private static func digits(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(text)
    }

    private static func twoDigits(_ text: String) -> Int? {
        guard (1...2).contains(text.count) else { return nil }
        return digits(text)
    }

    /// `ss` or `ss.fraction`, two digits before the point.
    private static func fractionalSeconds(_ text: String) -> Double? {
        let halves = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(halves.count), let whole = twoDigits(String(halves[0])) else { return nil }
        if halves.count == 2 {
            guard !halves[1].isEmpty, halves[1].allSatisfy(\.isASCIIDigit) else { return nil }
            return Double("\(whole).\(halves[1])")
        }
        return Double(whole)
    }

    private static func timecount(_ text: String) -> Double? {
        let units: [(String, Double)] = [("ms", 0.001), ("min", 60), ("h", 3600), ("s", 1)]
        var number = text
        var scale = 1.0
        for (suffix, factor) in units where text.hasSuffix(suffix) {
            number = String(text.dropLast(suffix.count))
            scale = factor
            break
        }
        let halves = number.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(halves.count), !halves[0].isEmpty, halves.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              halves.count == 1 || !halves[1].isEmpty, let value = Double(number) else { return nil }
        return value * scale
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// The ISO 8601 subsets package metadata uses, parsed by length after
/// fractional seconds are stripped; a missing zone means UTC.
enum EPUBDateParser {
    static func date(_ text: String) -> Date? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dot = value.firstIndex(of: "."), value.count > 19 {
            let tail = value[dot...].drop { $0 == "." || $0.isNumber }
            value = String(value[..<dot]) + tail
        }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .iso8601)
        components.timeZone = TimeZone(identifier: "UTC")
        func int(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= value.count else { return nil }
            let start = value.index(value.startIndex, offsetBy: range.lowerBound)
            let end = value.index(value.startIndex, offsetBy: range.upperBound)
            let slice = value[start..<end]
            guard slice.allSatisfy(\.isNumber) else { return nil }
            return Int(slice)
        }
        guard let year = int(0..<4) else { return nil }
        components.year = year; components.month = 1; components.day = 1
        switch value.count {
        case 4: break
        case 7:
            guard value[value.index(value.startIndex, offsetBy: 4)] == "-", let month = int(5..<7) else { return nil }
            components.month = month
        case 10, 11, 16, 19, 20, 25:
            guard let month = int(5..<7), let day = int(8..<10) else { return nil }
            components.month = month; components.day = day
            if value.count >= 19 {
                guard let hour = int(11..<13), let minute = int(14..<16), let second = int(17..<19) else { return nil }
                components.hour = hour; components.minute = minute; components.second = second
                if value.count == 25 {
                    let sign = value[value.index(value.startIndex, offsetBy: 19)]
                    guard sign == "+" || sign == "-", let offsetHours = int(20..<22), let offsetMinutes = int(23..<25) else { return nil }
                    let seconds = (offsetHours * 3600 + offsetMinutes * 60) * (sign == "-" ? -1 : 1)
                    components.timeZone = TimeZone(secondsFromGMT: seconds)
                } else if value.count == 20 {
                    guard value.hasSuffix("Z") else { return nil }
                }
            }
        default:
            return nil
        }
        guard (1...12).contains(components.month ?? 1), (1...31).contains(components.day ?? 1),
              (0...23).contains(components.hour ?? 0), (0...59).contains(components.minute ?? 0), (0...60).contains(components.second ?? 0) else { return nil }
        return components.date
    }
}

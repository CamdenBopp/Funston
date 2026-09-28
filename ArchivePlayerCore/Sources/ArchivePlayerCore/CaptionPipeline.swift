import Foundation
import CoreMedia

public enum CaptionError: Error, Sendable, Equatable {
    case unsupportedCodec(String)
    case unsupportedFeature(String)
    case malformedText(String)
    case invalidTiming
    case trackMismatch
    case resourceLimit
    case invalidParity
}

public struct CaptionCue: Sendable, Equatable {
    public let trackID: UInt32
    public let start: CMTime
    public let end: CMTime
    /// Plain text only. Render as literal text, never HTML or executable markup.
    public let text: String
}

/// Bounded text-caption storage. The caller supplies media clock time (for example,
/// AVSampleBufferRenderSynchronizer.currentTime()), not wall-clock elapsed time.
/// Value semantics permit ownership by the player's existing actor or main actor.
public struct CaptionPipeline: Sendable {
    public static let supportedCodecs: Set<String> = ["S_TEXT/UTF8", "S_TEXT/ASS", "S_TEXT/SSA", "S_TEXT/WEBVTT", "D_WEBVTT/SUBTITLES", "D_WEBVTT/CAPTIONS"]
    private var cues: [CaptionCue] = []
    private let maximumCues: Int
    private let maximumPayloadBytes: Int

    public init(maximumCues: Int = 4096, maximumPayloadBytes: Int = 65_536) {
        self.maximumCues = max(1, maximumCues)
        self.maximumPayloadBytes = max(1, maximumPayloadBytes)
    }

    @discardableResult
    public mutating func ingest(_ packet: DemuxedPacket, track: MediaTrack) throws -> CaptionCue {
        guard track.kind == .subtitle, packet.trackID == track.id else { throw CaptionError.trackMismatch }
        guard Self.supportedCodecs.contains(track.codec) else { throw CaptionError.unsupportedCodec(track.codec) }
        guard packet.data.count <= maximumPayloadBytes, cues.count < maximumCues else { throw CaptionError.resourceLimit }
        guard packet.pts.isNumeric, packet.duration.isNumeric, CMTimeCompare(packet.duration, .zero) > 0 else { throw CaptionError.invalidTiming }
        let end = CMTimeAdd(packet.pts, packet.duration)
        guard end.isNumeric, CMTimeCompare(end, packet.pts) > 0 else { throw CaptionError.invalidTiming }
        guard var text = String(data: packet.data, encoding: .utf8) else { throw CaptionError.malformedText("Invalid UTF-8") }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        switch track.codec {
        case "S_TEXT/ASS", "S_TEXT/SSA":
            // Matroska removes Dialogue's start/end fields and inserts ReadOrder.
            // Only the first eight commas delimit fields; Text may contain commas.
            let fields = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9, Int(fields[0]) != nil else { throw CaptionError.malformedText("Expected Matroska ASS/SSA event") }
            text = try Self.assText(String(fields[8]))
        case "D_WEBVTT/SUBTITLES", "D_WEBVTT/CAPTIONS":
            let fields = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { throw CaptionError.malformedText("WebM WebVTT requires identifier and settings lines") }
            text = String(fields[2])
            text = try Self.webVTTText(text)
        case "S_TEXT/WEBVTT": text = try Self.webVTTText(text)
        default: text = Self.stripTags(text)
        }
        if track.codec != "S_TEXT/ASS", track.codec != "S_TEXT/SSA" { text = Self.decodeEntities(text) }
        text = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" })
        if text.first == "\u{feff}" { text.removeFirst() }
        let cue = CaptionCue(trackID: track.id, start: packet.pts, end: end, text: text)
        // Stable insertion preserves author order for equal start times.
        let index = cues.firstIndex { CMTimeCompare($0.start, cue.start) > 0 } ?? cues.endIndex
        cues.insert(cue, at: index)
        return cue
    }

    /// Start inclusive, end exclusive; overlapping cues remain independently available.
    public func activeCues(at mediaTime: CMTime, trackID: UInt32? = nil) -> [CaptionCue] {
        guard mediaTime.isNumeric else { return [] }
        return cues.prefix { CMTimeCompare($0.start, mediaTime) <= 0 }.filter {
            (trackID == nil || $0.trackID == trackID) && CMTimeCompare(mediaTime, $0.end) < 0
        }
    }

    public mutating func prune(endingBefore mediaTime: CMTime) {
        guard mediaTime.isNumeric else { return }
        cues.removeAll { CMTimeCompare($0.end, mediaTime) <= 0 }
    }

    /// Call when flushing a seek or changing the underlying asset.
    public mutating func reset() { cues.removeAll(keepingCapacity: true) }

    private static func assText(_ text: String) throws -> String {
        var output = ""; var cursor = text.startIndex
        while cursor < text.endIndex {
            let character = text[cursor]
            if character == "{", let close = text[cursor...].firstIndex(of: "}") {
                let contents = String(text[text.index(after: cursor)..<close])
                if contents.contains("\\") {
                    // Drawing vectors are not dialogue; do not expose coordinates as words.
                    if contents.range(of: #"\\p[1-9][0-9]*"#, options: .regularExpression) != nil {
                        throw CaptionError.unsupportedFeature("ASS vector drawing")
                    }
                    cursor = text.index(after: close); continue
                }
            }
            if character == "\\" {
                let next = text.index(after: cursor)
                if next < text.endIndex {
                    switch text[next] {
                    case "N", "n": output.append("\n"); cursor = text.index(after: next); continue
                    case "h": output.append("\u{00a0}"); cursor = text.index(after: next); continue
                    default: break
                    }
                }
            }
            output.append(character); cursor = text.index(after: cursor)
        }
        return output
    }

    private static func webVTTText(_ text: String) throws -> String {
        if text.range(of: #"<[0-9]{2}:[0-9]{2}(?::[0-9]{2})?\.[0-9]{3}>"#, options: .regularExpression) != nil {
            throw CaptionError.unsupportedFeature("WebVTT inline timestamp animation")
        }
        return stripTags(text)
    }

    private static func stripTags(_ text: String) -> String {
        var output = ""; var cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor] == "<", let close = text[cursor...].firstIndex(of: ">") {
                let inner = text[text.index(after: cursor)..<close]
                let tag = inner.trimmingCharacters(in: .whitespaces).lowercased()
                if let first = tag.first, first.isLetter || first == "/" || first == "!" {
                    if tag == "br" || tag == "br/" || tag == "br /" { output.append("\n") }
                    cursor = text.index(after: close); continue
                }
            }
            output.append(text[cursor]); cursor = text.index(after: cursor)
        }
        return output
    }

    private static func decodeEntities(_ text: String) -> String {
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}", "lrm": "\u{200e}", "rlm": "\u{200f}"]
        var output = ""; var cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor] == "&", let end = text[cursor...].prefix(16).firstIndex(of: ";") {
                let token = String(text[text.index(after: cursor)..<end])
                var replacement = named[token]
                if token.hasPrefix("#") {
                    let hex = token.hasPrefix("#x") || token.hasPrefix("#X")
                    if let value = UInt32(token.dropFirst(hex ? 2 : 1), radix: hex ? 16 : 10), let scalar = UnicodeScalar(value) { replacement = String(scalar) }
                }
                if let replacement { output += replacement; cursor = text.index(after: end); continue }
            }
            output.append(text[cursor]); cursor = text.index(after: cursor)
        }
        return output
    }
}

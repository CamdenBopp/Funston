import Foundation

/// A configuration policy gate, not a decoder or legal/compliance certification.
/// No FFmpeg headers, objects, binaries, or dynamic loader calls are included.
public enum FFmpegBuildPolicy {
    public static let sourceTag = "n9.0.2"
    public static let sourceCommit = "946fcce07b6dcd0331c8cc609192aeff5e1924f8"
    public static let decoderNames: Set<String> = ["mpeg2video", "ac3", "eac3", "dca"]
    public static let parserNames: Set<String> = ["mpegvideo", "ac3", "dca"]
    public static let decoderIntegrationImplemented = false

    /// Checks generated headers from an external source/build directory. A caller
    /// must separately authenticate the source and connect these headers to binaries.
    public static func audit(configHeader: String, componentsHeader: String, commit: String) throws {
        guard commit == sourceCommit else { throw AuditError.sourceRevision }
        let config = try definitions(configHeader)
        let components = try definitions(componentsHeader)
        guard config["FFMPEG_LICENSE"] == "\"LGPL version 2.1 or later\"" else { throw AuditError.license }
        for name in ["GPL", "GPLV3", "LGPLV3", "NONFREE", "VERSION3", "STATIC", "NETWORK", "AVFORMAT", "AVDEVICE", "AVFILTER", "SWSCALE", "SWRESAMPLE"] {
            guard config["CONFIG_" + name] == "0" else { throw AuditError.configuration("CONFIG_" + name) }
        }
        for name in ["SHARED", "AVCODEC", "AVUTIL"] {
            guard config["CONFIG_" + name] == "1" else { throw AuditError.configuration("CONFIG_" + name) }
        }
        for (key, value) in config where key.hasPrefix("CONFIG_LIB") && value == "1" {
            throw AuditError.configuration(key)
        }
        let allowed = Set(decoderNames.map { "CONFIG_" + $0.uppercased() + "_DECODER" })
            .union(parserNames.map { "CONFIG_" + $0.uppercased() + "_PARSER" })
        for key in allowed where components[key] != "1" { throw AuditError.configuration(key) }
        for (key, value) in components where key.hasPrefix("CONFIG_") && value == "1" && !allowed.contains(key) {
            throw AuditError.configuration(key)
        }
        guard let arguments = config["FFMPEG_CONFIGURATION"] else { throw AuditError.configuration("FFMPEG_CONFIGURATION") }
        // Reject conflicting flags even if a later flag overrides their effect.
        for forbidden in ["--enable-gpl", "--enable-nonfree", "--enable-version3", "--enable-lib", "--enable-autodetect"] where arguments.contains(forbidden) {
            throw AuditError.configuration(forbidden)
        }
        for required in ["--disable-gpl", "--disable-nonfree", "--disable-version3", "--disable-autodetect", "--disable-everything", "--disable-programs"] where !arguments.contains(required) {
            throw AuditError.configuration(required)
        }
    }

    public enum AuditError: Error, Equatable, Sendable {
        case sourceRevision
        case license
        case configuration(String)
        case duplicateDefinition(String)
    }

    private static func definitions(_ text: String) throws -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3, parts[0] == "#define" else { continue }
            let name = String(parts[1])
            guard values[name] == nil else { throw AuditError.duplicateDefinition(name) }
            values[name] = parts.dropFirst(2).joined(separator: " ")
        }
        return values
    }
}

import Foundation
import ArchivePlayerExtraCodecs

@main
struct AuditFFmpegBuild {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            throw ToolError.usage("Usage: audit-ffmpeg-build /absolute/config.h /absolute/config_components.h verified-source-commit")
        }
        try FFmpegBuildPolicy.audit(
            configHeader: String(contentsOfFile: arguments[1], encoding: .utf8),
            componentsHeader: String(contentsOfFile: arguments[2], encoding: .utf8),
            commit: arguments[3])
        print("Configuration policy passed. Binary provenance, linkage, notices and distribution obligations still require audit. Decoder integration is not implemented.")
    }
    enum ToolError: Error { case usage(String) }
}

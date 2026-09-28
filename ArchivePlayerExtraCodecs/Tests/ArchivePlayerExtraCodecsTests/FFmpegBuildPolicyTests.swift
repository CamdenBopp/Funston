import XCTest
@testable import ArchivePlayerExtraCodecs

final class FFmpegBuildPolicyTests: XCTestCase {
    private var config: String {
        var lines = [
            "#define FFMPEG_LICENSE \"LGPL version 2.1 or later\"",
            "#define FFMPEG_CONFIGURATION \"--disable-gpl --disable-nonfree --disable-version3 --disable-autodetect --disable-everything --disable-programs\""
        ]
        lines += ["GPL", "GPLV3", "LGPLV3", "NONFREE", "VERSION3", "STATIC", "NETWORK", "AVFORMAT", "AVDEVICE", "AVFILTER", "SWSCALE", "SWRESAMPLE"].map { "#define CONFIG_\($0) 0" }
        lines += ["SHARED", "AVCODEC", "AVUTIL"].map { "#define CONFIG_\($0) 1" }
        return lines.joined(separator: "\n")
    }
    private var components: String {
        (FFmpegBuildPolicy.decoderNames.map { "#define CONFIG_\($0.uppercased())_DECODER 1" }
         + FFmpegBuildPolicy.parserNames.map { "#define CONFIG_\($0.uppercased())_PARSER 1" }).joined(separator: "\n")
    }
    func testNarrowLGPLConfigurationPassesButDoesNotClaimDecoder() throws {
        try FFmpegBuildPolicy.audit(configHeader: config, componentsHeader: components, commit: FFmpegBuildPolicy.sourceCommit)
        XCTAssertFalse(FFmpegBuildPolicy.decoderIntegrationImplemented)
    }
    func testGPLAndNonfreeAndVersionThreeFail() {
        for flag in ["GPL", "NONFREE", "VERSION3"] {
            let changed = config.replacingOccurrences(of: "CONFIG_\(flag) 0", with: "CONFIG_\(flag) 1")
            XCTAssertThrowsError(try FFmpegBuildPolicy.audit(configHeader: changed, componentsHeader: components, commit: FFmpegBuildPolicy.sourceCommit))
        }
    }
    func testAdditionalComponentOrLibraryAndUnpinnedSourceFail() {
        XCTAssertThrowsError(try FFmpegBuildPolicy.audit(configHeader: config, componentsHeader: components + "\n#define CONFIG_H264_ENCODER 1", commit: FFmpegBuildPolicy.sourceCommit))
        XCTAssertThrowsError(try FFmpegBuildPolicy.audit(configHeader: config + "\n#define CONFIG_LIBX264 1", componentsHeader: components, commit: FFmpegBuildPolicy.sourceCommit))
        XCTAssertThrowsError(try FFmpegBuildPolicy.audit(configHeader: config, componentsHeader: components, commit: "main"))
    }
    func testConflictingFlagsAndDuplicateDefinitionsFail() {
        let changed = config.replacingOccurrences(of: "--disable-gpl", with: "--enable-gpl --disable-gpl")
        XCTAssertThrowsError(try FFmpegBuildPolicy.audit(configHeader: changed, componentsHeader: components, commit: FFmpegBuildPolicy.sourceCommit))
        XCTAssertThrowsError(try FFmpegBuildPolicy.audit(configHeader: config + "\n#define CONFIG_GPL 0", componentsHeader: components, commit: FFmpegBuildPolicy.sourceCommit))
    }
}

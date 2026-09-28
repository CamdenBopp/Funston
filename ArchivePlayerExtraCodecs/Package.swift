// swift-tools-version: 6.0
import PackageDescription

// Intentionally independent: no FFmpeg systemLibrary/binaryTarget and no dependency
// from ArchivePlayerCore or the app. This package currently audits build policy only.
let package = Package(
    name: "ArchivePlayerExtraCodecs",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ArchivePlayerExtraCodecs", targets: ["ArchivePlayerExtraCodecs"]),
        .executable(name: "audit-ffmpeg-build", targets: ["AuditFFmpegBuild"])
    ],
    targets: [
        .target(name: "ArchivePlayerExtraCodecs"),
        .executableTarget(name: "AuditFFmpegBuild", dependencies: ["ArchivePlayerExtraCodecs"]),
        .testTarget(name: "ArchivePlayerExtraCodecsTests", dependencies: ["ArchivePlayerExtraCodecs"])
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArchivePlayerCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "ArchivePlayerCore", targets: ["ArchivePlayerCore"])],
    targets: [
        .target(name: "ArchivePlayerCore"),
        .testTarget(name: "ArchivePlayerCoreTests", dependencies: ["ArchivePlayerCore"])
    ]
)

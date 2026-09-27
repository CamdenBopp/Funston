// swift-tools-version:6.2
// LNPopupController:4.5.12

import PackageDescription
// Archive packaging patch: deterministic paths avoid malformed private header
// paths when Xcode 27 evaluates this manifest. Runtime source is unmodified.
let settings: [PackageDescription.CSetting] = [
    .headerSearchPath("LNPopupController/Private"),
    .headerSearchPath("LNPopupController/Private/TransitionAnimators"),
    .headerSearchPath("LNPopupController/Private/Appearance"),
    .headerSearchPath("LNPopupController/Private/Utils"),
    .headerSearchPath("LNPopupController/Private/Titles"),
    .headerSearchPath("LNPopupController/Private/Swift"),
    .headerSearchPath("LNPopupController/Private/Minimization"),
    .headerSearchPath("LNPopupController/Private/GestureRecognizers"),
]

let package = Package(
	name: "LNPopupController",
	platforms: [
		.iOS(.v13),
		.macCatalyst(.v13)
	],
	products: [
		.library(
			name: "LNPopupController",
			type: .dynamic,
			targets: ["LNPopupController", "LNPopupController-ObjC", "LNPopupController-SwiftPrivate"]),
		.library(
			name: "LNPopupController-Static",
			type: .static,
			targets: ["LNPopupController", "LNPopupController-ObjC", "LNPopupController-SwiftPrivate"]),
	],
	dependencies: [
//		.package(path: "../LNSystemMarqueeLabel"),
		.package(url: "https://github.com/LeoNatan/LNSystemMarqueeLabel", from: Version(stringLiteral: "0.1.2"))
	],
	targets: [
		.target(
			name: "LNPopupController-ObjC",
			dependencies: [
				.product(name: "LNSystemMarqueeLabel", package: "LNSystemMarqueeLabel"),
			],
			path: "LNPopupController",
			exclude: ["Info.plist", "LNPopupController.xcodeproj", "LNPopupController/Private/Swift"],
			publicHeadersPath: "include",
			cSettings: settings),
		.target(
			name: "LNPopupController-SwiftPrivate",
			dependencies: ["LNPopupController-ObjC"],
			path: "LNPopupController/LNPopupController/Private/Swift"),
		.target(
			name: "LNPopupController",
			dependencies: ["LNPopupController-ObjC"],
			path: "LNPopupController+Swift")
	],
	cxxLanguageStandard: .gnucxx20
)

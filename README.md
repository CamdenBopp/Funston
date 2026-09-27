# Funston

A native iPhone and iPad client for exploring Internet Archive artifacts. Browse live collections through artwork shelves, search across media types, inspect provenance and files, save artifacts, and download supported media for offline use.

The repository is named Funston; the existing Xcode target and installed app are currently named Archive. Keeping the bundle identifier unchanged preserves existing on-device library and downloads.

Audio publishes album artwork and transport metadata to the system Now Playing surface, including the Lock Screen. Artwork is loaded asynchronously through the bounded image cache and retained across tracks from the same artifact.

UIKit owns navigation, adaptive tab/split layouts and reusable collections; SwiftUI composes artifact headers and the full audio player. A native interactive mini-player keeps listening available while browsing. Supported PDFs open in a PDFKit reader with page restoration and text search; compatible films open in AVKit. EPUB and OCR-specific reading tools remain future work.

The audio presentation uses MIT-licensed LNPopupController 4.5.12, vendored with a documented manifest-only build fix. Its MIT-licensed LNSystemMarqueeLabel dependency is locked to 0.1.2. Playback, artwork caching, downloads and persistence remain app-owned. See [component decisions and licensing](Docs/ComponentDecisions.md) and [vendored provenance](Vendor/LNPopupController/PROVENANCE.md).

Generate the Xcode project and build:

```sh
xcodegen generate
xcodebuild -project Archive.xcodeproj -scheme Archive -destination 'generic/platform=iOS Simulator' build
```

Requires Xcode 27 and XcodeGen; the app supports iOS 18 and later. Keep the workspace's `Package.resolved` to reproduce the transitive dependency version. Regenerate the original geometric app icon with `swift Scripts/GenerateAppIcon.swift`.

Simulator downloads use an in-process URLSession because the tested simulator's background-transfer daemon failed before starting transfers. Physical-device builds retain background downloads. See [simulator download behavior and validation limits](Docs/SimulatorDownloads.md).

The product and engineering contract, including acceptance gates that require physical-device validation, is in [ImplementationPlan.md](Docs/ImplementationPlan.md).

## License

Original project source is available under the [MIT License](LICENSE). Vendored dependencies retain their own copyright and license notices; see [ThirdPartyNotices.txt](Archive/Resources/ThirdPartyNotices.txt). Internet Archive media and artwork (including material visible in review screenshots) remain subject to their respective rights and are not relicensed by this repository.

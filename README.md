# Funston

A native iPhone and iPad client for exploring Internet Archive artifacts. Browse live collections through artwork shelves, search across media types, inspect provenance and files, save artifacts, and download supported media for offline use.

The repository is named Funston; the existing Xcode target and installed app are currently named Archive. Keeping the bundle identifier unchanged preserves existing on-device library and downloads.

Audio publishes album artwork and transport metadata to the system Now Playing surface, including the Lock Screen. Artwork is loaded asynchronously through the bounded image cache and retained across tracks from the same artifact.

UIKit owns navigation, adaptive tab/split layouts and reusable collections; SwiftUI composes artifact headers and the full audio player. A native interactive mini-player keeps listening available while browsing. Supported PDFs open in a PDFKit reader with page restoration and text search; scanned pages also have an on-device recognized-text view that defaults to Automatic and prefers Apple Live Text for Internet Archive derivatives. Readers are not prompted when opening a page, but Reading Options exposes an extensible engine list and remembers a choice until it is changed. Compatible films open in AVKit. EPUB remains future work.

The [PDF scrolling investigation and polish report](Docs/PDFScrollingPolish.md) records physical-device measurements and rejected rendering experiments. Fast-scroll blank pages in heavy scanned PDFs remain an open issue; the experimental raster cache is test-only.

The video viewer streams public MP4/M4V/MOV files or uses a leased local download, restores per-file position, and offers retry without discarding progress. An unmodified full-screen AVKit player supplies auto-hiding transport, speed, AirPlay, embedded media options, and supported Picture in Picture. Its native Close action ends the video; the audio queue remains paused and available afterward. The image uses aspect-fit rather than cropping to fill the phone. Downloads includes a dedicated Watch Downloaded Film action that never silently switches to streaming. Device PiP/AirPlay and manual accessibility verification remain release gates.

An experimental original-file path now opens MKV through the MIT-only [ArchivePlayerCore](https://github.com/CamdenBopp/ArchivePlayerCore): bounded HTTP Range reads, a Swift Matroska demuxer, and Apple's sample-buffer video/audio renderers. The demuxer understands WebM's container structure, but WebM video codecs have not passed a device decode gate and `.webm` is not yet offered as a Watch action. The existing AVKit path remains preferred for MP4/M4V/MOV. The MKV controls expose audio-track names/languages/roles, captions when a supported embedded text track exists, speed, seek, and VoiceOver actions; unsupported codecs/tracks are identified rather than silently discarded. This path is not AVKit, has no Picture in Picture, and has not passed physical-device or manual VoiceOver validation. Separate strict MPEG-TS and DVD/VOB access-unit adapters have passed early Mac renderer gates, but are not in the app and do not imply physical-iPhone compatibility; the raw demuxers alone are not playable. The player lives in its own package, [ArchivePlayerCore](https://github.com/CamdenBopp/ArchivePlayerCore), which records the measured device codec gates, playback findings and conformance results.

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

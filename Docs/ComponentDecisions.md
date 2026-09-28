# Native component decisions

Evaluated against primary repositories on September 27, 2026. This app targets iOS 18; the local toolchain is Xcode 27.0.

## Player presentation: adopt LNPopupController

[LNPopupController](https://github.com/LeoNatan/LNPopupController) supplies the presentation work we need: a native compact bar, interactive expansion and dismissal, artwork, accessibility and UIKit container integration. Keep Funston's AVPlayer engine, downloads, now-playing integration and bounded artwork pipeline. It is a UI component, not a replacement media engine.

Vendor [4.5.12](https://github.com/LeoNatan/LNPopupController/releases/tag/4.5.12), released September 19, 2026, as the local package `Vendor/LNPopupController`; do not track a branch. The exact [package manifest](https://github.com/LeoNatan/LNPopupController/blob/4.5.12/Package.swift) requires Swift tools 6.2 and iOS 13+, and offers static and dynamic products. We choose the static product. Its one package dependency is LNSystemMarqueeLabel. The resolved package file locks that dependency to 0.1.2. Both use MIT licenses, reproduced in the app's bundled `ThirdPartyNotices.txt`.

The remote package failed to compile under local Xcode 27: dynamically enumerated private header paths were truncated to `troller/...` even after fresh build/package caches and canonical paths. The CLI manifest output was correct, so the precise upstream/toolchain cause remains unproven. The vendored manifest replaces that directory enumeration with eight explicit relative header paths. No runtime source was changed; recursive comparison against the tagged checkout matched. The vendored package then compiled successfully. This is a build-packaging fix, not a runtime fork. See `Vendor/LNPopupController/PROVENANCE.md` for revision and manifest checksums.

`FunstonPlayerPresentation` adapts existing playback context/phase events and uses cancellable downsampled artwork loading. It adds no progress timer and does not subscribe every browse cell to playback progress. Explicit popup open/close callbacks own the existing visible progress consumer with an idempotent guard; a preloaded SwiftUI view cannot start progress updates. Marquee scrolling is disabled, full titles remain accessible, and initial presentation respects Reduce Motion. The library owns safe-area adjustments. A container change detaches and reinstalls the popup while preserving whether it was open; existing navigation history ownership remains intact.

The library does not design the full player: Funston still owns that SwiftUI view. Broad container behavior is documented by upstream; smoothness, VoiceOver, large Dynamic Type, Reduce Motion and live iPad resizing still need device validation. No numerical memory, startup or frame-rate claims have been measured. Upstream actively updates for current OS releases; that is evidence of maintenance, not a guarantee against UIKit changes.

## Reading: Readium for EPUB, PDFKit for a focused PDF reader

[Readium Swift Toolkit](https://github.com/readium/swift-toolkit) is the strongest maintained EPUB candidate. It is **BSD-3-Clause, not MIT** ([license](https://github.com/readium/swift-toolkit/blob/3.11.0/LICENSE)). Stable [3.11.0](https://github.com/readium/swift-toolkit/releases/tag/3.11.0) was released July 17, 2026. Its manifest targets iOS 15 and Swift tools 5.10; `develop` is a newer prerelease line, so use the stable tag if adopting it. The navigator covers pagination, themes, text preferences, EPUB search and decorations. Integration still requires publication acquisition, persistent reading position, reader chrome, errors and accessibility validation. A reader toolkit cannot establish authorization for restricted Archive loans.

Readium's parser, navigator and web-content stack are a justified dependency for EPUB, where a homegrown renderer would duplicate substantial standards work. Select only required products; do not import its audiobook engine into the music player. Its manifest includes several packages, so compile/binary and runtime costs need measurement on representative books. Upstream warns that minor releases can contain minor breaking API changes. Native EPUB content rendering uses web technologies; a native app shell does not mean every glyph is drawn by UIKit.

For a first PDF/scanned-book reader, Apple's [PDFView](https://developer.apple.com/documentation/pdfkit/pdfview) provides the system rendering surface and leaves Archive in control of toolbar, page position, thumbnails and file lifecycle. This has no additional third-party package, but PDFs with large scanned pages still require device memory/performance testing. A complete EPUB reader is a separate functional slice, not a visual restyle of the current external-file opener.

Reject [FolioReaderKit](https://github.com/FolioReader/FolioReaderKit) for new integration: GitHub marks it archived, its last release is 1.4.0 from January 2019, and its last repository push was September 2020. It is BSD-3-Clause, not MIT. Its attractive sample does not establish compatibility with modern iOS.

## Images: keep current pipeline; choose viewer based on scope

[Lightbox](https://github.com/hyperoslo/Lightbox) is genuinely [MIT](https://github.com/hyperoslo/Lightbox/blob/master/LICENSE.md), with pagination, zoom and interactive transitions. Latest release 2.5.1 is February 2024 and last repository push August 2024. Its current SPM manifest lists no package dependencies, while its README still describes older image-loader dependencies. Build and accessibility validation are needed before adoption; do not infer modern OS polish from screenshots.

[NYTPhotoViewer](https://github.com/nytimes/NYTPhotoViewer) offers mature UIKit paging, captions, zoom and interactive dismissal. Its exact license is Apache-2.0, not MIT; latest release 5.0.8 is October 2022, although the repository had a February 2026 push. It interoperates with Swift but is Objective-C. Its core can omit GIF-related framework overhead. Neither candidate is needed just to show an artwork cover. A focused UIScrollView viewer is reasonable for a single full-screen image; paged galleries merit a measured component spike.

No reader or image-viewer package is installed by this player change. Research timestamps were verified with the repositories' GitHub API metadata and release pages; recommendations and cost judgments above are engineering assessments, not measured benchmarks.

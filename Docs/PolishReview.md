# Polish review — 27 September 2026

## Verdict

The reviewed iPhone experience now presents recognizable artifacts and useful media actions rather than a directory of generic text rows. The second simulator screenshot set shows a coherent Explore gallery, illustrated collection results, book/audio detail, a working full player, and the native PDF reader. No blocking visual regression was identified in those reviewed screens.

This is a scoped design/code review, not a release certification. The final UIKit Explore cells passed the light-appearance iOS 27 automated accessibility audit with all checks enabled and no exclusions. The final full dark-appearance suite passed **53 of 53 tests**, with zero skipped tests and no runtime warnings (`/tmp/ArchivePolishFinal32.xcresult`). That suite includes the full Explore accessibility audit, compact-player Dynamic Type audit, live listening, and PDF reading/page restoration.

## Reviewed changes

- Explore uses real collection results and reusable UIKit cells containing one native button, stable artwork geometry, and Dynamic Type labels. The button exposes combined artifact identity; its decorative image and child labels do not create duplicate accessibility stops. Accessibility text sizes switch shelves to one column and remove caption line limits. Small status/error surfaces remain SwiftUI.
- Cached Explore content remains visible with refresh/error status and retry. Collection headers refresh their cached-state labels. Requests are small and visibility-triggered; the shared artwork pipeline bounds fetching and decoding.
- Collection and Library rows have reusable thumbnails, clear titles, and creator/media context. Collection results consistently navigate into a collection. Artifact detail separates identity and primary actions from recordings and technical information; meaningless numeric synopsis text is omitted while original metadata remains inspectable.
- The full player has clear transport, progress, queue, download, and audio-output controls. Progress updates are isolated from the artwork/queue subtree. The compact player remains present while browsing or reading.
- Public PDFs use durable validated downloads, cancellable preparation, local-file leases, page restoration, native page controls, Go to Page, text search, and sharing. PDF construction and validation occur on an exclusive worker before one-way handoff to the main actor. Private/restricted/unresolved media do not receive Read/Watch actions. Multiple supported files require explicit selection, avoiding an automatic cover/trailer choice.
- The reader screenshots show a real scanned book with page controls above the compact player. The final coordinated workflow tests demonstrate audio playback and PDF page restoration.
- The explicit Info.plist declares background audio, three iPhone orientations, and all four iPad orientations. These declarations are appropriate to the intended experience; they do not prove device background behavior or rotated-layout correctness.
- The opaque secondary text color is adaptive between light and dark appearances. Its stronger contrast avoids dependence on translucent secondary text over custom player surfaces. The supplied 1024-pixel icon is legible and visually consistent with a reading/listening app.

## Evidence and resolved findings

Reviewed actual iPhone 16 Pro simulator screenshots exported in `/tmp/ArchivePolishScreens1` and `/tmp/ArchivePolishScreens2`: Explore, collection results, audio artifact, full player, accessibility-size Explore, book detail, and PDF reader. A subsequent iOS 27 dark-appearance run covered the same journeys. Representative screenshots are preserved in [ReviewScreenshots](ReviewScreenshots).

The second set confirms improved cover quality, stronger metadata contrast, real artifact shelves instead of collection logos, shorter accessibility-size header copy, a populated full player, and removal of the book's spurious numeric About section. Subsequent source review confirms minimal artifact back labels and removal of the repeated collection-title row.

The final source cross-check found no blocking regression in the explicit background/orientation declarations, Explore button semantics, icon, or adaptive secondary text. The final native Explore-cell review confirmed replacement of old button actions during configuration, cancellation of artwork on reuse/offscreen transitions, identity checks before asynchronous image assignment, and reload on visible reconfiguration. No blocking reuse or accessibility-semantic issue was identified. A residual cosmetic limitation is that long creator text can truncate a shelf's trailing year; full artifact identity remains available when opening the item and through its accessibility label.

The dark-appearance visual review found no blocking defects in Explore, player, reader, or accessibility-size layout. Runtime review caught an iPad portrait sidebar obscuring Explore; split presentation now chooses two or three visible columns using content width budgets and reevaluates on resize. The native sidebar remains available. Audio-session activation/deactivation now run on a dedicated serial worker; ownership checks and race tests prevent late completions from overriding newer play/pause intent. Video waits for that handoff.

## Device evidence

An optimized, signed 0.2.0 (2) Release build was installed and launched on the connected iPhone 14 Pro Max running iOS 27. The compiled Info.plist was inspected and contains background audio and supported orientations. The first polished Release bundle occupied 4.2 MB on disk (not an App Store download-size claim). Final Release configuration explicitly disables code-coverage instrumentation; a symbol inspection confirmed no LLVM profile or sanitizer-coverage runtime symbols in that binary. Test coverage remains a development/test concern.

A 15-second Time Profiler attachment on that physical phone is saved at `/tmp/ArchivePolishPhoneIdle.trace`. Its potential-hangs table contains no events at the configured >250 ms threshold. This was a brief post-launch observation, not a controlled scrolling, battery, or long-duration idle benchmark; no frame-rate, battery, or steady-state CPU guarantee follows from it.

## Validation limits and remaining gates

- The final full 53-test dark-appearance suite and separate light-appearance accessibility audit passed without exclusions. These establish the tested workflows, not manual assistive-technology verification or every possible application state.
- Manual VoiceOver completion of search, open, play, save, download, reading, and focus restoration has not been verified. An automated accessibility audit and large-text screenshots do not establish this.
- Xcode Accessibility Inspector was opened and the connected iPhone selected, but it did not expose an app target or audit results through the available controls (it remained at “Select a target App”). This attempt is not counted as a passed Inspector audit; the XCTest audit results remain the recorded automated evidence.
- Physical-device background downloads, process termination/relaunch, locked-screen audio, interruption/route changes, and download completion while suspended have not been verified in this polish review. Simulator success is separate evidence.
- The iOS 27 iPad portrait listening journey and compact-player Dynamic Type audit passed after the adaptive-column fix (`/tmp/ArchivePolishIPad3.xcresult`). iOS 27 iPhone dark appearance was visually reviewed. Rotation, narrow multitasking, Bold Text, Increase Contrast, Reduce Transparency, and Voice Control still need dedicated runtime review.
- Beyond the brief phone trace described above, large/complex PDF preparation and scrolling, retained memory across repeated open/back cycles, and large archive normalization remain performance gates. Background parsing reduces main-thread work but does not establish a latency or memory target.
- Live video playback, corrupt/locked PDFs, no-searchable-text PDFs, and multiple-file chooser interaction require dedicated runtime coverage beyond the demonstrated audio/PDF journey.

The implementation should be handed off with these limits stated accurately. No additional feature expansion is required to close this polish pass.

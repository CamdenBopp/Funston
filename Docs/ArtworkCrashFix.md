# Lock Screen artwork crash — 27 September 2026

## Cause

Build 3 crashed when restoring playback and publishing artwork. Both the physical iPhone 14 Pro Max report and the simulator report show `dispatch_assert_queue`, Swift executor isolation checks, and the artwork request handler called by `-[MPMediaItemArtwork jpegDataWithSize:]`.

The handler was created inside a main-actor task and inherited its isolation. MediaPlayer invokes it on its own background access queue. Reinstalling build 3 reproduced signal 5; installation was not the remedy. Merely receiving a successful launch response was insufficient verification.

## Correction

Build 4 explicitly types the request handler as `@Sendable (CGSize) -> UIImage`. It captures only the immutable, already-decoded image and does no networking, decoding, or main-actor work. Artwork stays bounded by the existing image pipeline and is reused across transport updates.

The regression test invokes the actual `MPMediaItemArtwork` handler from `Task.detached`, in addition to checking metadata retention, same-cover reuse, and stale-request rejection. The full iOS 27 simulator suite passed **55/55 tests**, with no skipped tests or runtime warnings (`/tmp/FunstonCrashFixTests.xcresult`). The signed Release build compiled successfully with coverage disabled.

## Documentation consulted

- [Apple: Addressing crashes from Swift runtime errors](https://developer.apple.com/documentation/xcode/addressing-crashes-from-swift-runtime-errors)
- [Apple: Visualize and optimize Swift concurrency](https://developer.apple.com/videos/play/wwdc2022/110351/?time=1198) — non-Sendable closures inherit actor isolation from their context.
- [Apple: Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/?time=855) — Sendable closures and actor isolation.
- [Apple: MPMediaItemArtwork request handler](https://developer.apple.com/documentation/mediaplayer/mpmediaitemartwork/init(boundssize:requesthandler:))

These checks address this crash, not complete release certification or manual Lock Screen/VoiceOver verification.

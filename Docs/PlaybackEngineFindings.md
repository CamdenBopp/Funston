# Sample-buffer playback engine

`SampleBufferPlaybackEngine` owns producer/render-clock orchestration in ArchivePlayerCore. Its default `SampleBufferPlaybackRenderers` owns `AVSampleBufferRenderSynchronizer`, `AVSampleBufferAudioRenderer`, and `AVSampleBufferDisplayLayer.sampleBufferRenderer`. The exposed display layer can be attached by an app host.

Engine and renderer state are `@MainActor`: UIKit/Core Animation layer ownership and mutable renderer lifecycle stay serialized, and non-Sendable sample buffers never cross executors. Parsing/source access remain in the independently isolated demuxer actors. Format inference supports AVC configuration, AAC AudioSpecificConfig, and OpusHead through shared factories. Supplied format descriptions allow other codecs; `unsupportedTracks` exposes tracks with no usable description. Format creation alone does not prove device decoder support.

## Demand and lifecycle

The producer retains one pending packet and stops reading when its destination is backpressured. Main-queue `requestMediaDataWhenReady` callbacks resume the producer; there is no readiness polling. Every callback stops registrations before restarting. Generation and pump serial tokens prevent stale read completions/callbacks from replacing newer work. Pause, stop, failure, and actor-isolated deinitialization stop demand registrations. Stop awaits a cancelled in-flight demux operation asynchronously before flushing; an uncooperative source can delay completion but cannot synchronously block the main actor.

The first selected sample anchors the clock. Pause/rate changes update the synchronizer. Seek serializes with the producer, invokes demux seek, flushes, anchors the requested target, drops earlier audio and waits for a keyframe while forwarding video preroll. Exact frame-accurate seek and all decoder-specific preroll rules remain unverified. `finishedEnqueuing` drains through a synchronizer boundary observer at the maximum queued presentation end, then sets rate zero and transitions to `.ended`. Audio duration falls back to ASBD frames/rate; missing video duration uses a conservative 100ms tail. Replay is `seek(to: .zero)` then `play()`. Renderer KVO observers propagate delayed failures even after input ends. Stop marks the state terminal before any await; generation checks prevent suspended preparation, seek, or selection from resurrecting stopped playback.

Initial and runtime audio/video selection are supported. The general `selectTracks` path pauses the clock, seeks the shared demuxer to the current time, changes selection, flushes both renderers, and restarts keyframe/preroll processing while preserving the prior playing/paused state. A demuxer without seeking surfaces its seek error. This is a discontinuous switch with measurable interruption. The separate `selectAudio` path and its limitations are measured below; the MKV viewer now uses it while playing and falls back to `selectTracks` while paused. Neither path is certified acoustically gapless or visually hitch-free. Stop is terminal; create a new engine to restart. Supported rates are finite values in (0,4]; reverse playback is unsupported.

Known TS/PS demuxers are rejected at prepare because raw PES requires codec access-unit adapters. No iOS VOB/MPEG-2 renderer claim follows from macOS codec tests. The real render gate starts with AAC and switches to Opus.

## Actual renderer test, 2026-09-27

Command: `IA_RENDER_TESTS=1 swift test --filter PlaybackEngineTests` (an independent SwiftPM scratch directory was used to avoid another build process). All nine engine tests passed, no skips or failures.

The opt-in test reads the real [IA multi-audio item](https://archive.org/details/the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub), original file `The Ancient Magus' Bride S01E03 720p HD BluRay Multi Audio ESub.mkv`, through `HTTPRangeByteSource` and `MatroskaDemuxer`. It selects H.264 video and AAC audio, uses the actual Apple renderers and synchronizer, waits until both statuses become `.rendering`, then lets them run for three more seconds. Audio volume is zero. It asserts no asynchronous failure, advancing clock, both rendering statuses, and more than five queued samples.

Observed Apple-silicon macOS run:

| Measurement | Result |
| --- | ---: |
| Startup to both renderers reporting `.rendering` | 2.235 s |
| Initial render observation wall time | 5.242 s |
| Process user + system CPU time delta before switch | 0.230 s |
| Process peak RSS before switch (`getrusage`, bytes on macOS) | 48,988,160 bytes |
| HTTP bytes transferred | 327,681 bytes |
| Samples enqueued | 239 |
| Synchronizer time at initial observation | 3.060115 s |
| Video/audio status | 1 / 1 (`rendering`) |
| Engine error | nil |

The same test then switched from AAC to Opus while playing. The select/seek/flush call took **2.598 s**; both renderers reported rendering with ten additional samples and the clock advancing by at least 0.2 s after **2.808 s**. The clock advanced from 3.060176 s to 3.269540 s and no renderer error occurred. This metric is recovery to renderer/clock conditions, not an acoustic gap measurement. A first-use seek index and network round trips are included. Preserving uninterrupted video would require a separately positioned audio demux/source or a more elaborate retained-video buffer while only audio is flushed; the current shared cursor intentionally restarts both.

These values are one observed run, not performance guarantees. Peak RSS is the entire test process high-water mark. This proves real compressed samples reached running Apple renderers and clock progression on this Mac, including the Opus switch path. The test does not attach the display layer to a visible window, measure lip-sync, or listen to audio. It does not prove iPhone rendering, background/route changes, PiP, sample-exact seek continuity, long-duration stability, or seamless audio switching. Shared AAC factory changes removed the invalid raw-ASC magic cookie before this successful run; see `DecodeFindings.md` for that diagnosis.

Eight synthetic tests separately cover valid PCM sample-buffer delivery through an injected renderer, one-packet backpressure, callback teardown including deinit, EOF clock behavior, explicit seek/flush, initial three-track PCM/AAC/Opus selection, runtime selection invoking seek and flush, unsupported tracks/rates, and immediate/deferred failures.

## Apple references and availability

- [AVSampleBufferRenderSynchronizer](https://developer.apple.com/documentation/avfoundation/avsamplebufferrendersynchronizer).
- [AVSampleBufferVideoRenderer](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer).
- Installed iPhoneOS SDK headers inspected: `AVSampleBufferRenderSynchronizer.h`, `AVSampleBufferVideoRenderer.h`, and `AVSampleBufferDisplayLayer.h`. They document nonnegative rate, queue readiness, keyframes after flush, and renderer APIs available before iOS 18. New receiver APIs require later OS releases, so the engine uses established iOS-18-compatible APIs.

Compiled under Swift 6 strict concurrency using Swift 6.4. `isolated deinit` requires a compiler supporting actor-isolated deinitialization (Swift 6.2 or newer); deployment remains iOS 18. The runtime gate above is macOS only.

Final verification also passed an explicit `swiftc -swift-version 6 -strict-concurrency=complete -target arm64-apple-ios18.0` typecheck against the installed iPhoneOS SDK, and the full current Swift package suite: 64 tests, 12 opt-in skips, zero failures.

## Independent audio reader experiment

`selectAudio(trackID:using:)` accepts a fresh Matroska demuxer with its own byte source. It prepares and seeks that reader while current A/V playback continues, catches audio up to the live clock, then commits atomically by flushing **only audio**. The primary reader keeps its position, video renderer and synchronizer; after commit it discards its audio packets. `IndependentAudioSampleProducer` provides a second demand-driven producer with one pending packet. Demand cancellation is per renderer, and stale primary-audio callbacks cannot cancel the replacement registration. Failed/cancelled preparation leaves original selection and renderers untouched.

Catch-up is limited to 10,000 packets, 32MiB elementary payload and 30 seconds checked between reads. The existing demuxer's metadata/index limits also apply. These are not an absolute network-traffic cap: a caller-supplied source controls read-ahead and network timeout. Continuous replacement playback limits scanning between audio samples to 10,000 packets/32MiB. A superseding seek, stop, or track operation cancels the old independent producer. Pause/resume retains it. No PCM crossfade or audio-device output tap is installed.

Real test command: `IA_RENDER_TESTS=1 IA_INDEPENDENT_AUDIO_TESTS=1 swift test --filter PlaybackEngineTests`. Final run passed all 12 engine tests including preparation failure/cancellation preserving original audio, suspended-prepare/stop lifecycle, and EOF drain/replay.

With a 256KiB replacement HTTP window, AAC→Opus preparation took **3.065s while original playback continued**. Commit to first new compressed-audio enqueue was **8.675ms**; its PTS was **0.743ms beyond the commit clock**; 217 replacement packets enqueued during the following two seconds. Replacement transfer was **806,748 bytes**. The last old-audio enqueue preceded the first new enqueue by 773ms, but old audio was buffered through media time 6.185s, so this wall-clock enqueue interval is not an audible silence measurement. No audio output callback/tap measured the actual acoustic gap.

Clock advanced continuously from 3.068s to 8.193s; sampling at 50ms found no video-status failure or clock stall. However, the headless renderer's dropped-frame count increased from 23 to 62 while total frames increased from 102 to 224, and no displayed pixel buffer was available without a window. These results establish an independent cursor/audio-only-flush path and sustained replacement audio, **not verified visually uninterrupted or zero-hitch video**. Packet PTS is not required to be monotonic in H.264 decode order; no false monotonic-PTS test is imposed. A visible rendering/presentation-timestamp experiment is still needed to distinguish normal headless drops from switch-specific drops.

Earlier 64KiB replacement-window runs took 5.1–15.1s of preparation and 610KiB–1.59MiB transfer. An early run enqueued only two replacement packets because an already-dispatched old audio callback cancelled new audio demand; per-renderer stale-callback checks fixed this, and the final run requires more than 30 new audio packets. The original shared-cursor pause/seek/full-flush switch remains available as a measured discontinuous alternative (2.808s recovery in the prior run).

The coordinating task additionally validated actual H.264/AAC rendering on an iOS 18.3.1 iPhone 16 Pro simulator: clock4.029s,301 packets,262,145 bytes, both renderer statuses `.rendering`. This was the baseline path, not the independent-audio experiment. No physical iPhone was available.

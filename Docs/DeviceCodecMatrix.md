# Codec and renderer gates observed on 2026-09-27

These are *observations on the named environments*, not a blanket Apple codec
support table. The actual compressed-frame/renderer test is distinguished from
format-description or decoder-session creation.

| Environment | H.264 | AAC | Opus | MPEG-2 video | VP9 / AV1 |
| --- | --- | --- | --- | --- | --- |
| Apple M2 Pro, macOS 27.0 (26A428) | Real IA 1280×720 image decoded through VideoToolbox; sample-buffer video renderer reached rendering status | Real IA AAC packet produced 1,024 PCM frames; sample-buffer audio renderer reached rendering status | Real IA Opus packet produced 840 PCM frames through AudioConverter; complete renderer path not separately isolated | Generated known-good frame decoded through VideoToolbox (software; `VTIsHardwareDecodeSupported=false`) | Bare 64×64 format descriptions produced session errors `-12906`; no configured bitstream decode test |
| iPhone 16 Pro **simulator**, iOS 18.3.1 | Real IA MKV sample-buffer video renderer reached rendering status, 301 combined packets enqueued and clock advanced to 4.029 s | Same live render test: audio renderer reached rendering status | Not separately rendered on simulator | Generated frame's decoder session rejected with `-12906`; no decode | Not tested |
| iPhone 14 Pro Max, physical | **Not tested** | **Not tested** | **Not tested** | **Not tested** | **Not tested** |

The iPhone 14 Pro Max became connected over USB later on 2026-09-27. Signing is resolved: the certificate's actual organizational-unit/team field is `68Z6A6ACWF`, matching the existing wildcard profile. The earlier diagnosis incorrectly treated the parenthesized identifier in the certificate's display name as its team. A build using the correct team signed, installed, and launched successfully. The table remains **untested** for physical-device codecs; installation alone is not a codec result.

The iOS live test used the original six-track IA MKV from
[`the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub`](https://archive.org/metadata/the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub),
with `HTTPRangeByteSource`, `MatroskaDemuxer`, and the app's
`SampleBufferPlaybackEngine`. The renderer test on the iOS 18.3.1 iPhone 16 Pro
simulator transferred 262,145 HTTP body bytes, elapsed 5.89 seconds from
start through a four-second observation window, and recorded video/audio
renderer status `1` (rendering), synchronizer clock 4.029 seconds, 301 enqueued
packets, and no engine error. Audio output was muted. This does not prove
visible-window presentation, audible output, A/V drift, seek, track switching,
or physical-device behavior. Xcode unit-test output recorded the run; the test
is normally opt-in in `OriginalVideoRenderDeviceTests.swift`.

A second opt-in iPhone 16 Pro simulator gate used the real [IA MPEG-TS original](https://archive.org/metadata/twitch-videos-2179756722) through `TransportStreamAccessUnitDemuxer`. On iOS 18.3.1, both H.264 video and AAC audio renderers reported `.rendering`, 213 samples were enqueued, the media clock advanced **3.0003 s** during the observation, **1,310,721 HTTP body bytes** were transferred, wall time was **5.785 s**, and `engine.lastError` was nil. The targeted Xcode run passed **17 tests** (16 UI/presentation and this live gate), zero failures/skips. The TS viewer is not wired into the app; the test ran muted without a visible display layer or audible output. These statuses do not prove visible frame presentation, A/V drift, or full-file decoding.

The paired iPhone 15 Pro Max belongs to another named person and was not used. The next experiment is to run the device codec plus real-render tests on the connected iPhone 14 Pro Max with development team `68Z6A6ACWF`.

Mac tests: `IA_NETWORK_TESTS=1 swift test --filter MatroskaDecodeTests`,
`IA_RENDER_TESTS=1 swift test --filter PlaybackEngineTests`, and
`swift test --filter CodecCapabilityTests` in `ArchivePlayerCore`.
The iOS simulator test was run through the Archive Xcode scheme with its live
network opt-in temporarily enabled and then restored to opt-in.

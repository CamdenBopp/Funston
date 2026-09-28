# Funston roadmap

Written 2026-09-28 after reading the code of every repository ChatGPT suggested and checking each claim against Funston's source. Highest priority first. Sizes: S is an afternoon, M a few days, L a week or more.

## TL;DR

1. Fix four quiet bugs first: the database has no schema versioning, download bookkeeping errors are swallowed, failed downloads restart from zero, and AirPods and Lock Screen controls are missing commands.
2. Then make audio excellent: a continue-listening shelf, sensible resume rules and a sleep timer. No app we read has a sleep timer.
3. Bring the MKV player up to the AVKit player: Now Playing, Picture in Picture, saved position.
4. EPUB comes through Readium, but only for born-digital books. Scanned books stay in PDFKit with on-device OCR, because Internet Archive's EPUBs of scans are its own OCR.
5. Don't adopt GRDB, Kingfisher, waveforms, FFmpeg or VLCKit. Funston's own code is better for this app, and the reasons are below.
6. None of the eleven apps we read is better at VoiceOver than Funston already is. Their ideas are worth taking; their player UIs aren't.

## 1. Fix what's quietly broken

### 1.1 Version the database schema (S, done)
`SQLiteStore.migrate()` (`Funston/Services/SQLiteStore.swift:302`) is a single `CREATE TABLE IF NOT EXISTS` script with no `PRAGMA user_version`. The first time a table gains a column, existing installs will keep the old table and the new code will fail against it. Replace it with numbered migration steps and a test that upgrades a version-1 database. Everything that adds storage later (book positions, track preferences) depends on this.

### 1.2 Say so when the download list can't be read (S, done)
The roadmap first said swallowed writes could lose a finished download. Reading closer, they can't: the success path already handles its error, and launch reconciliation repairs the other three writes by design. The real hole was reading. If the saved list failed to load at launch, Downloads looked empty, exactly like having no downloads. It now shows "Could not load downloads" with Try Again, touches no files, and the recoverable writes are logged instead of discarded.

### 1.3 Resume failed downloads instead of restarting them (S, done)
`didCompleteWithError` (`DownloadManager.swift:83`) ignores `NSURLSessionDownloadTaskResumeDataKey`, and Retry starts over from byte zero. Internet Archive originals run to several gigabytes. Keep the resume data on disk with the record and use `downloadTask(withResumeData:)` on retry. JellyGo does this, but it's GPL, so write it fresh; it's standard Apple API anyway.

### 1.4 Complete the headphone and Lock Screen controls (S, done; needs a check on the iPhone)
`configureRemoteCommands` (`PlaybackController.swift:592`) registers play, pause, next, previous and scrubbing. It's missing:
- `togglePlayPauseCommand`, which a wired headset's button sends (verify AirPods behaviour on the device)
- `skipForwardCommand` and `skipBackwardCommand` with `preferredIntervals = [15]`, which give the Lock Screen and car ±15 s buttons that are far easier to use under VoiceOver than scrubbing
- `MPNowPlayingInfoPropertyPlaybackQueueIndex` and `...QueueCount`, so the system knows where you are in a multi-recording item

Swiftfin (MPL) and TomoTV (MIT) both do this; it's a few lines.

### 1.5 Check this week's changes under VoiceOver on the iPhone (S, your time)
The new copy, the engine-menu subtitles, the cardless shelves and the mini-player backing were checked with XCUITest and simulator screenshots, not with VoiceOver speaking on a device. The same goes for the manual gates in [ImplementationPlan.md](ImplementationPlan.md): focus order, rotor behaviour, Bold Text, Increase Contrast, Reduce Transparency and Voice Control.

## 2. Make audio excellent

### 2.1 Continue listening at the top of Explore (M, done)
Read `playback_positions` newest first, skip finished recordings, and show a shelf above the collections. Build it as a compositional-layout section, and give progress as a spoken value ("12 minutes left"), not a bar alone. Dusk and the Dumpert app (both MIT) have the idea. Their SwiftUI isn't worth porting.

### 2.2 Resume and finished rules (S, done)
`PlaybackController.restoredPosition` only starts over when you're within one second of the end. Better rules: don't resume under 5 s, and treat 95% or the last 10 s as finished. Write them as a pure function with tests. The Dumpert app's version is MIT and adaptable. Also confirm that the first periodic save after a resume seek can't write a position near zero; Dumpert and Labstream both had to guard against that.

### 2.3 Sleep timer (M, done)
None of the eleven apps has one. Offer 15, 30, 45 and 60 minutes, plus "end of this recording". Fade the audio out, announce when it's set and when it fires, and put it in the player's menu and as a VoiceOver action on the player.

### 2.4 Say when it ends (S, done)
Add remaining time, adjusted for playback speed, to the position slider's spoken value, or add an "ends at 11:40" line. Strimr does the second. It's cheap and useful context.

### 2.5 Start the next recording without a gap (M)
Prepare the next `AVPlayerItem` about 30 s before the current one ends, or move to `AVQueuePlayer`. Measure the gap on the device first; if it's already short, skip this.

### 2.6 "Still listening?" (dropped)
The sleep timer covers falling asleep to a long collection. A second prompt would be a weaker version of the same thing.

Original note:
Dusk pauses after a streak of autoplayed episodes. That's useful for falling asleep to a 487-episode collection. It has to be a real prompt with no countdown, because every app we read uses auto-dismissing overlays that VoiceOver users can miss entirely.

## 3. Video and reading

### 3.1 Bring the MKV player up to the AVKit player (S each, done; Picture in Picture needs a check on the iPhone because the simulator doesn't support it)
The AVKit path already saves your position and gets Now Playing, Picture in Picture and remote commands from the system. The MKV player (`ArtifactOriginalVideoController.swift`) has none of these. In order:
- Save and restore the position, using the rules from 2.2.
- Publish Now Playing info and handle remote commands.
- Remember the chosen audio and caption track per item, and your preferred language across items (Strimr's idea).
- Add Picture in Picture with `AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer:playbackDelegate:))`. The engine already renders through an `AVSampleBufferDisplayLayer`, which is exactly what this API needs.
- Add a "Show playback controls" VoiceOver action on the video surface, and confirm the track menus say which option is selected.

### 3.2 Decide how MKV should play long term (M, then maybe L)
Two of the apps we read (GMPlayer and Sodalite's engine) remux MKV into fragmented MP4, serve it as HLS from a localhost server, and let AVPlayerViewController play it. That gets the system's VoiceOver-tested controls, Picture in Picture and AirPlay for free. Both use FFmpeg to do it, and both still can't carry Opus or MPEG-2, which real Internet Archive MKVs and VOBs use.

Recommendation:
1. Run the matched iPhone comparison that ArchivePlayerCore's `DemuxMissionStatus.md` already plans (experiment 6).
2. If remuxing wins for compatible files, build it in Swift inside ArchivePlayerCore, without FFmpeg, and only for MKVs whose tracks are all H.264 or HEVC with AAC, AC-3 or E-AC-3. Those go to the existing AVKit player. Everything else stays on the sample-buffer engine.
3. The parts:
   - Timestamp synthesis for B-frame video (port GMPlayer's `gm_ts.c` ladder; MIT, and FFmpeg-free).
   - An fMP4 writer. Try `AVAssetWriter` with `.mpeg4AppleHLS` passthrough first; if that fails, hand-write the boxes.
   - A loopback HLS server (GMPlayer's `GMLoopbackServer.swift`, MIT, is the reference). GMPlayer's notes explain why `AVAssetResourceLoader` can't serve segment bytes.

### 3.3 Fast-scroll blank pages in heavy scanned PDFs (M)
Still open; see [PDFScrollingPolish.md](PDFScrollingPolish.md). It shows up mostly under the automated rapid-jump harness, not in ordinary reading, so it sits below the playback work.

## 4. Books

### 4.1 Split the item screen by experience, just before Books (M)
`ArtifactController` knows about recordings, PDFs and films in one class. Before adding EPUB, pull the shared overview out and route each item to an experience (audio, film, book, generic) behind a small protocol. Swiftfin's engine-capability protocols are a good model for the playback side of that routing. Land it as a refactor with no behaviour change, in its own commit.

### 4.2 EPUB through Readium (L, done; needs a VoiceOver check on the iPhone)
[readium/swift-toolkit](https://github.com/readium/swift-toolkit) 3.11, BSD-3. Use only its Shared, Streamer and Navigator products.
- Born-digital EPUBs open in `EPUBNavigatorViewController`, a plain UIViewController.
- Scanned books stay in PDFKit with on-device OCR. For those, Internet Archive's EPUB is generated from its own OCR (checked on `alicesadventures00carr`: EPUB, derived from ABBYY, derived from page scans). Offer it only as "Text version (from OCR)".
- Readium doesn't follow Dynamic Type. Map the text size setting to `EPUBPreferences.fontSize` yourself.
- Store reading positions as Readium `Locator` JSON in a new table. This needs 1.1.
- Read aloud through `PublicationSpeechSynthesizer`, sharing the audio session with the music player.
- Readium switches to scrolling when VoiceOver is on, because pagination breaks the screen reader. There's an open bug (#113) where swiping to the next paragraph during continuous reading can jump to the end of the chapter. Test it on the device before calling EPUB done.

### 4.3 Search the whole book's recognized text (L)
The plan lists this as deferred. It's the natural next step for the OCR engine choice: recognize every page once in the background, cache the results, and search those instead of Internet Archive's embedded text.

## 5. Infrastructure and someday

- **Private media corpus (M).** Borrow Labstream's pattern: a script that runs over Internet Archive search results, picks the smallest file for each codec and container pair, and stores the list outside git. Count a file as playing only when a non-black frame decodes and a seek works. Name regression tests after the bug they pin, as AetherEngine does.
- **Release-build performance gates on the device (M).** The acceptance scenarios in [ImplementationPlan.md](ImplementationPlan.md), with signposts.
- **CI (S).** Mac runners on a private repo cost ten times Linux minutes. Your call.
- **`hev1`-tagged HEVC (S or M).** Labstream rewrites the tag after download because AVFoundation shows black video. Only do this if an Internet Archive file reproduces it.
- **Deferred features.** CarPlay is probably the most valuable for audio. After that come App Intents and Siri, Spotlight, Wayback captures and SharePlay.

## Don't do

- **GRDB.** Funston's store is one process with one writer, and it republishes through Combine. Database observation adds nothing, and switching risks regressing 26 persistence tests. The only real gap, schema versioning, is 1.1 and takes about 20 lines.
- **Kingfisher.** It decodes full-size images by default, has no disk-cache size limit by default, and no response size cap. Funston's artwork pipeline downsamples at decode, caps responses, bounds concurrency and carries a tested fix for a real Lock Screen crash.
- **Waveforms.** They tell a VoiceOver user nothing. AudioKit's keeps the GPU busy, and DSWaveformImage needs the whole file downloaded. Neither library contains any accessibility code.
- **FFmpeg, VLCKit or KSPlayer.** LGPL or GPL, large binaries, and software decoding costs battery. ArchivePlayerCore exists to avoid them.
- **Timed overlays and countdowns.** Every app we read auto-dismisses resume prompts and up-next cards after a few seconds.
- **Hiding AVKit's controls and drawing your own on top.** Sodalite does this by matching private class names at runtime. It's fragile and leaves VoiceOver almost nothing.
- **Third-party UI frameworks and SwiftUI lists.** Nothing we read beats UIKit's own controls for accessibility or scrolling cost.

## Already done

The research suggested these, and Funston already has them:
- Audio position saves every 15 s, on pause and when the app goes to the background.
- Download progress is throttled to every 250 ms.
- The AVKit film path saves and restores your position.
- The MKV player's controls stay visible and reachable while VoiceOver runs; none of the other players do this.
- The position sliders are adjustable and speak the time; most of the other players have unlabelled scrubbers.

## What the suggested repositories turned out to be

| Repository | Actual license | Worth reading for | Can we reuse code? |
| --- | --- | --- | --- |
| [marvinvr/dusk-player](https://github.com/marvinvr/dusk-player) | MIT | continue watching, up next, "still watching" | yes, with attribution |
| [gastonmorixe/GMPlayer](https://github.com/gastonmorixe/GMPlayer) | MIT (app); FFmpeg static LGPL | MKV remux to HLS design, DTS ladder, loopback server | the Swift and FFmpeg-free C parts |
| [rm335/dumpert-apple-tv](https://github.com/rm335/dumpert-apple-tv) | MIT | resume rules, preloading, Now Playing | yes, with attribution |
| [keiver/tomotv](https://github.com/keiver/tomotv) | MIT | Now Playing queue index | yes, but it's mostly React Native |
| [jellyfin/Swiftfin](https://github.com/jellyfin/Swiftfin) | MPL-2.0 | skip commands, engine-capability protocols, card labels | ideas only |
| [wunax/strimr](https://github.com/wunax/strimr) | GPL-3.0 | auto-skip once per segment, remembered tracks, "ends at" | ideas only |
| [superuser404notfound/Sodalite](https://github.com/superuser404notfound/Sodalite) | GPL-3.0 + App Store exception | its engine's native-or-fallback routing | ideas only |
| [baykatre/jellygo](https://github.com/baykatre/jellygo) | GPL-3.0 | download resume data | ideas only |
| [jlipworth/Labstream](https://github.com/jlipworth/Labstream) | GPL-3.0 | media corpus testing, small pure policy types | ideas only |
| [piemonte/Player](https://github.com/piemonte/Player), [BrikerMan/BMPlayer](https://github.com/BrikerMan/BMPlayer), [DZVideoPlayerViewController](https://github.com/DZamataev/DZVideoPlayerViewController), [Alan881/AAPlayer](https://github.com/Alan881/AAPlayer), [swiftui-loop-videoPlayer](https://github.com/swiftuiux/swiftui-loop-videoPlayer) | MIT | nothing; no accessibility code in any of them, several years stale | not worth it |
| [maxovtsin/ororo-tv-player](https://github.com/maxovtsin/ororo-tv-player) | no license file (README says MIT) | nothing | no |
| [readium/swift-toolkit](https://github.com/readium/swift-toolkit) | BSD-3 | EPUB | yes, as a dependency |
| [GRDB](https://github.com/groue/GRDB.swift), [Kingfisher](https://github.com/onevcat/Kingfisher), [AudioKit/Waveform](https://github.com/AudioKit/Waveform), [DSWaveformImage](https://github.com/dmrschmidt/DSWaveformImage) | MIT | see "Don't do" | not needed |

What ChatGPT got wrong:
- It said VLCKit was optional in Dusk. Dusk embeds it as a required framework.
- It said GMPlayer's FFmpeg is an LGPL-compatible build. It is, but it's statically linked and enables some subtitle codecs the notice says it doesn't.
- It called Ororo MIT. There's no license file.
- Every repository it named does exist.

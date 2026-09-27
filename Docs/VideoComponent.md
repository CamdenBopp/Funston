# Native video component — full-screen follow-up

## Scope and behavior

Public MP4, M4V, and MOV files open in an unmodified `AVPlayerViewController`, presented full-screen over a small preparation/retry host. The preparation toolbar disappears behind AVKit during playback; Apple owns its auto-hiding Close, transport, speed, AirPlay, and available PiP controls. Films with MP3 derivatives still prioritize Watch; the audio derivative remains available in the artifact's recordings/files. Multiple film files require an explicit choice rather than guessing which is the main feature.

The player streams from Internet Archive or acquires a lease on a completed download. Watch Downloaded Film is strictly local: a missing file produces a useful error rather than silently consuming network data. Loading and error surfaces use adaptive system backgrounds; only the film canvas is black. AVKit supplies play/pause, seeking, speed, AirPlay, and supported embedded media-selection controls. Explicit `.resizeAspect` retains the full source frame, allowing letterboxing; it does not crop to fill the phone. Frame analysis is disabled to avoid irrelevant background work on archival film. Sidecar subtitle conversion is not implemented.

Per-file SQLite bookmarks restore before native controls attach, so an initial seek cannot race a user's Play command. A 15-second observer plus pause, background, completion, and close events save position; there is no per-frame UI polling. These bookmarks never replace the audio-only startup bookmark. The viewer cancels pending work and detaches the item before releasing its downloaded-file lease.

## Audio and Picture in Picture

Video acquires an exclusive token through the audio player's serial session-operation chain. Audio remote commands, transport actions, and Now Playing writes are suspended while AVKit owns playback. Interruption state continues to update without audio callbacks pausing/deactivating video. Token-checked release restores audio controls but does not automatically resume the old recording.

Native Picture in Picture is enabled. The viewer remains presented/retained while PiP is active, and the delegate restores that existing interface rather than creating a new player. The native full-screen Close control ends video; a host Done button is only visible during preparation or errors. This is a bounded viewing workflow, not a persistent cross-screen video queue. No app control is mislabeled as PiP: if PiP is unavailable on a device, we do not promise it by renaming another action.

## Review and validation limits

A GPT 6 Astra adversarial reviewer reviewed the plan and implementation through resolution. Findings fixed: interruption state stuck during video ownership; teardown omitted on nonanimated dismissal; unsafe test fixture media/database directory overlap. The reviewer reported no remaining scoped findings. Live UI testing also uncovered and corrected Watch being hidden by a film's MP3 derivative.

Initial verification was interrupted by a stale simulator test-service connection and host disk exhaustion. Those attempts are not clean test passes. The Mac needs additional free space. Only obsolete task-generated build caches and preliminary test reports were removed; source, final earlier acceptance bundles, and on-device data were preserved.

The earlier build-6 verification passed **62/62 selected tests** (all 61 unit tests plus the live-video UI journey), zero skipped, in `/tmp/FunstonVideoVerified3.xcresult`. The follow-up live journey opens *Duck and Cover*, checks native Close and speed controls, confirms its full 4:3 image is within the player frame, waits for the toolbar to auto-hide, closes, and reopens it. The [controls-visible](ReviewScreenshots/08-Native-Video.png) and [controls-hidden](ReviewScreenshots/09-Fullscreen-No-Toolbar.png) screenshots show that behavior. The full-suite follow-up also caught and fixed an audio artifact incorrectly prioritizing a PDF companion over Play; a regression test now covers that case. The final iOS 27 simulator run passed **69/69 tests**, with zero skips and no reported runtime warnings, in `/tmp/FunstonFullScreenAccepted.xcresult`.

On the subsequent build request, Release 0.2.0 (6) was rebuilt, installed on the iPhone 14 Pro Max, and launched. Its process remained alive through a 30-second post-launch check, with no new app crash reports. The full-screen follow-up is signed as Release 0.2.0 (7), installed on the same iPhone, and remained alive through a subsequent check with no new app crash report. Physical-device video playback, PiP restoration, AirPlay routes, interruptions, rotation, and manual VoiceOver completion remain release gates; launch survival does not establish these.

The follow-up reviewer found and drove fixes for two transition races: repeated `.idle`/`.failed` notifications while native presentation is in flight, and late PiP callbacks overwriting a closed session. The reviewer then reported no remaining blocking code findings. Native full-screen UI tests use the live public-domain *Duck and Cover* film; its 4:3 image rectangle should remain entirely within the player bounds. Other aspect ratios and any specific report of source-edge cropping still require the affected item's identifier and device observation.

## Platform references

- [AVPlayerViewController](https://developer.apple.com/documentation/avkit/avplayerviewcontroller) — native controls; not subclassed.
- [Picture in Picture with a standard player](https://developer.apple.com/documentation/avkit/adopting-picture-in-picture-in-a-standard-player) — retaining/restoring playback UI.

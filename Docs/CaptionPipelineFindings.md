# Caption pipeline implementation and boundaries

`CaptionPipeline` is a bounded, plain-text decoder and cue store. It accepts `DemuxedPacket` plus its `MediaTrack`, uses packet PTS and duration, and exposes overlapping cues at a supplied `CMTime`. Start is inclusive; end is exclusive. Call `activeCues(at: synchronizer.currentTime(), trackID: selectedID)` from the presentation layer. Pausing the media clock preserves the same caption; seeking requires `reset()` followed by caption preroll/refill. Call `prune(endingBefore:)` as playback advances. Defaults cap storage at 4,096 cues and each input at 64 KiB; exceeding either produces a typed error rather than silently discarding a caption.

Supported inputs:

| Codec ID | Input interpretation |
| --- | --- |
| `S_TEXT/UTF8` | UTF-8 subtitle body; simple tags and entities converted to plain text |
| `S_TEXT/ASS`, `S_TEXT/SSA` | Matroska event fields, with Text after the first eight commas; override styling removed; `\N`, `\n`, `\h` interpreted |
| `S_TEXT/WEBVTT` | Matroska cue body directly |
| `D_WEBVTT/SUBTITLES`, `D_WEBVTT/CAPTIONS` | WebM identifier line, settings line, then cue body |

ASS text keeps embedded commas and literal entity-like sequences. Input must be valid UTF-8. Missing/nonpositive duration, invalid media times, wrong track, malformed framing and unsupported codecs fail explicitly. ASS drawing commands and WebVTT inline timestamp animation are rejected; showing vector coordinates or revealing future animated text would misrepresent those inputs. Font/color/layout overrides and karaoke styling are intentionally flattened. WebVTT regions, cue settings, ruby positioning and Matroska BlockAdditions are not rendered. Outputs are literal strings, not HTML sanitization results; the UI must render them using a literal text API. Escaped angle brackets remain literal angle brackets after entity decoding.

`CEA608CaptionDecoder` is a separate state machine for already-extracted byte pairs from one selected field. It validates odd parity by default and selects channel one or two. It models two 15×32 character memories, pop-on swaps, paint-on, 2/3/4-row roll-up, basic/special characters, PAC row/indent, tabs, backspace, row erasure and memory erasure. It suppresses consecutive duplicate control transmissions. `consume(_:_:at:)` returns a timestamped replacement snapshot only when displayed text changes; empty text means erase. Failed operations leave decoder state intact. Roll-up scrolling updates text immediately; it does not implement animated scrolling.

This is a narrow decoder, not complete CEA-608 conformance: extended character sets, text/alarm modes, styling, background attributes, transparent-cell geometry, signal-loss timeout policy and automatic field extraction are not implemented. Some recognized style commands are flattened to text behavior; unsupported data returns `CaptionError.unsupportedFeature`. Snapshots preserve line structure and indentation but omit absolute vertical placement. MPEG user-data/AVC SEI extraction and CEA-708 service decoding remain separate work. Reset the decoder at stream discontinuities; a caller must maintain snapshot display intervals against the media clock.

No bitmap OCR, PGS renderer or VobSub renderer is implemented. The previously tested IA item `the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub` contains two PGS streams; this new pipeline truthfully rejects those. Its earlier successful track discovery/decode tests do not establish text-caption compatibility. Caption tests use synthetic standards-derived bytes and do not claim a real IA text-caption fixture.

Validation: `swift test --filter Caption` passed nine tests on 2026-09-27, covering timing boundaries, paused-time repeat lookup, overlap/track selection, out-of-order insertion, pruning/reset, ASS/SSA text extraction, both WebVTT framings, resource limits and typed rejection. CEA-608 tests cover parity/channel filtering, transactional rejection, pop-on with duplicate EOC, roll-up/erase, PAC, backspace and the last-column overwrite rule.

Primary references used (no GPL or third-party decoder code copied):

- [Matroska subtitle codec mapping](https://www.matroska.org/technical/subtitles.html), for event framing and container timing.
- [WebM WebVTT storage guidelines](https://www.webmproject.org/docs/container/#webvtt-guidelines), for identifier/settings lines that differ from Matroska's mapping.
- [W3C WebVTT](https://www.w3.org/TR/webvtt1/), for cue text constructs.
- [Historical FCC analog caption decoder specification, 47 CFR §15.119 (2011)](https://www.govinfo.gov/content/pkg/CFR-2011-title47-vol1/pdf/CFR-2011-title47-vol1-sec15-119.pdf), for the 608-compatible character/control tables, parity, display memories, cursor behavior and caption modes. Used as a published technical reference, not a claim about current regulatory obligations or complete standards compliance.
- [Apple render synchronizer currentTime](https://developer.apple.com/documentation/avfoundation/avsamplebufferrendersynchronizer/currenttime()), for presentation clock integration.
- [Apple Media Accessibility captions](https://developer.apple.com/documentation/mediaaccessibility/captions), for system caption appearance and language preferences. The presentation layer should read user settings and observe `kMACaptionAppearanceSettingsChangedNotification`; this core decoder does not select an on-screen style, modify preferences, or implement the accessible UI.

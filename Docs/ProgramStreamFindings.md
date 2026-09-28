# MPEG program streams and DVD VOBs

Implemented independently in `ArchivePlayerCore/ProgramStreamDemuxer.swift`; no GPL decoder or demuxer code was copied or linked.

## Supported parsing

- Incremental reads over `ByteSource`, including short reads and split start codes. Declared PES lengths bound allocation to 65,535 bytes plus a small read buffer; probing retains at most the configured discovery window (capped at 16 MiB) plus one packet/read chunk.
- MPEG-1 and MPEG-2 pack headers, pack stuffing, MPEG-1 and MPEG-2 PES headers, optional PTS/DTS with marker validation, 90 kHz timestamps, and nearest-epoch 33-bit wrap handling. Small backwards timestamps are preserved for reordered video. Large discontinuities/cell transitions cannot be distinguished reliably from timestamp wrap without DVD navigation.
- DVD `private_stream_1` IDs: AC-3 `0x80–0x87`, DTS `0x88–0x8f`, LPCM `0xa0–0xa7`, subpictures `0x20–0x3f`. Public track IDs are `0xbd00 | substream`; MPEG video/audio use their original PES stream IDs. The private stream header is removed; LPCM retains its three format bytes as track codec-private metadata and exposes channels.
- System headers, padding, private_stream_2/NAV, and program maps are skipped using their declared lengths. MPEG audio/video codec labels are DVD-oriented assumptions; generic program-map codec negotiation is not implemented.
- Caller-ordered VOB segments can be joined with `ProgramStreamSegmentSource`; reads cross segment boundaries without concatenating whole files in memory. Declared segment lengths must be accurate and segments must belong to the same logical title in playback order.
- Optional `ProgramStreamDVDMetadata` reads VTS IFO title audio attributes and selected PGC physical-stream mappings, then enriches observed tracks with declared language, channels, and commentary/accessibility roles. The caller selects the program chain; unsupported audio coding modes are omitted.
- Nonzero seek uses the selected PGC's IFO time map when available. It chooses the preceding indexed VOBU, requires a known source length, verifies a pack start at the target, and rejects requests outside the map, backwards sectors, or maps containing discontinuity flags. This is a coarse seek requiring decoder preroll, not frame-accurate navigation. Rewind remains available without IFO metadata.

`DemuxedPacket.data` is an elementary-stream fragment from one PES, **not a decoder-ready sample or necessarily a full audio/video frame**. Frame reconstruction, sequence/audio-header interpretation, codec configuration, accurate per-frame PTS association, and sample durations remain downstream work. DVD audio PES PTS applies to the first access unit designated by the removed private header, which can follow continuation bytes; packet PTS must not be blindly assigned to a decoder frame. Keyframe is deliberately false and duration invalid. LPCM 20/24-bit unpacking and subpicture assembly/palette rendering are not implemented.

The paragraph above describes `ProgramStreamDemuxer` itself. An optional `ProgramStreamAccessUnitDemuxer` adapter now implements the bounded MPEG-2 frame-picture/AC-3 subset described below. Raw PES remains unsuitable for direct engine input.

Malformed/truncated framing, timestamp markers and header lengths produce typed errors. Scrambled PES, unknown DVD private substreams, and zero-length/unbounded PES are explicitly unsupported. The parser does not decrypt CSS, execute DVD menus, choose titles/cells/angles, or implement NAV-based seeking. Track discovery is bounded and cannot guarantee discovery of sparse subtitles or delayed tracks; further packets update the known track list. Serialize calls to a demuxer instance (actor isolation does not make a multi-await parsing transaction atomic).

## Real corpus validation

On 2026-09-27, a successful HTTP 206 range request for bytes `0–1048575` of [VTS_01_1.VOB](https://archive.org/download/vts-01-1_20250820_1408/VTS_01_1.VOB) from [IA item vts-01-1_20250820_1408](https://archive.org/details/vts-01-1_20250820_1408) produced **509 PES media packets** and three observed IDs: `0xe0` MPEG-2 video, `0xbd80` AC-3, `0xbd81` AC-3. This validates early demuxing of two original audio streams; it is not an end-to-end playback or full-title validation and does not establish languages. The bounded prefix may end inside a PES, so the corpus probe permits a final truncation error after checking parsed packets.

The [IA metadata response](https://archive.org/metadata/vts-01-1_20250820_1408) lists `VTS_01_0.IFO`, six title VOB segments of 1,073,739,776 bytes and a final `VTS_01_7.VOB` of 918,220,800 bytes, plus a distinct menu `VTS_01_0.VOB`. Segment joining must exclude the menu. The downloaded `VTS_01_0.IFO`, parsed with PGC 1, declares **both audio streams as English, six channels**, despite the item title advertising Russian/Hindi. These are declared tags, not verified spoken languages; the parser preserves them. The corpus IFO yields no usable conservative seek points. Its playback therefore cannot claim nonzero seeking from this metadata; synthetic tests exercise the valid continuous-map path.

Validation command:

```sh
PROGRAM_STREAM_NETWORK_TEST=1 swift test --package-path ArchivePlayerCore --filter ProgramStreamTests
```

The full package suite passed: 37 tests, three optional corpus probes skipped, zero failures, with local VOB-prefix and IFO probes enabled. The live network PS probe also passed separately. Offline CI exercises synthetic private streams, pack/PES headers, timestamp markers/wrap, truncated input, short reads, segment boundaries, IFO attribute remapping, continuous-map nonzero seek, discontinuity rejection, and rewind. Local probes use `PROGRAM_STREAM_CORPUS_PREFIX` and `PROGRAM_STREAM_CORPUS_IFO`. Network probe failures are skipped when the corpus is unavailable; parser/assertion failures after a successful response fail the test.

## Specification references

- [ITU-T H.222.0, Systems](https://www.itu.int/rec/dologin_pub.asp?id=T-REC-H.222.0-201206-S%21%21PDF-E&lang=e&type=items), especially PES syntax (§2.4.3.6) and program stream syntax (§2.5): primary normative source for pack/PES framing and timestamps.
- [Microsoft: Audio and Subpicture Streams](https://learn.microsoft.com/en-us/windows/win32/directshow/audio-and-subpicture-streams): primary platform documentation for DVD stream-selection concepts and limits; stream selection and IFO metadata are distinct from byte demultiplexing.
- [DVD-Video technical notes: LPCM layout](https://dvd.sourceforge.net/dvdinfo/lpcm.html), [DVD/MPEG differences](https://dvd.sourceforge.net/dvdinfo/dvdmpeg.html), and [PES header](https://dvd.sourceforge.net/dvdinfo/pes-hdr.html): public format notes used for DVD-specific layout context, not a licensed DVD Book or normative replacement. Original mpucoder host was unavailable during research. No implementation source was copied.
- [IFO header and attributes](https://dvd.sourceforge.net/dvdinfo/ifo.html), [PGC audio controls](https://dvd.sourceforge.net/dvdinfo/pgc.html), and [VTS time-map structures](https://dvd.sourceforge.net/dvdinfo/ifo_vts.html) describe the additional metadata/index layouts.

## Exact-read source tail regression

The read buffer clamps requests to a known `ByteSource.length` before asking exact-read sources for data. The regression tests now cover a valid 4,100-byte PES payload ending at a non-4-KiB file boundary, clean EOF, and a genuinely truncated PES which must still throw `DemuxError.truncated`. A real IA prefix trimmed at its last suitable complete PES boundary also passes: **1,046,542 bytes, 508 media PES packets, clean EOF** through `LocalByteSource`. The existing length clamp required no further source change for these tests.

## Optional decoder-ready MPEG-2/AC-3 adapter

`ProgramStreamAccessUnitDemuxer`, in the same source file, collects split pictures/audio frames across PES boundaries. It exposes `formatDescriptions()` for explicitly supplying formats to the existing sample-buffer engine; no engine or app routing was changed in this workstream. Its aggregate buffered payload limit defaults to 4 MiB (maximum 16 MiB), with independent 4,096-PES and byte scan/probe limits. No decoder implementation or FFmpeg source was copied or linked.

The raw demuxer exposes the DVD first-audio-access-unit offset, retaining it alongside probe packets. The adapter uses that offset to anchor AC-3 timestamps after continuation bytes, then advances by 1,536 samples per frame. Rate, channel count, or AC-3 `bsid` changes are explicitly rejected against the original format description. Tests cover frames spanning PES boundaries and 48 kHz stereo changing to 44.1 kHz, six channels, or another profile.

MPEG-2 uses sequence headers, picture boundaries/types and temporal references to associate timestamps and frame duration. Field pictures, repeat-first-field pulldown, and extended frame rates are rejected. This is a limited frame-picture path, not general MPEG-2/DVD navigation. Format changes, open-GOP recovery, temporal-reference rollover, long discontinuous titles, variable frame timing, final-picture completeness, and full A/V drift require broader validation. The adapter only selects MPEG-2 video and AC-3; DTS, LPCM, MPEG audio and subtitles remain outside it.

Primary syntax references: [ITU-T H.262](https://www.itu.int/rec/T-REC-H.262-200002-S/en) for sequence/picture framing and temporal reference; [ETSI TS 102 366 v1.4.1](https://www.etsi.org/deliver/etsi_ts/102300_102399/102366/01.04.01_60/ts_102366v010401p.pdf) for AC-3 sync/header/frame sizing. Native Apple APIs perform decoding.

## Real IA decode and renderer evidence

On the same macOS 27 arm64 host, the first real corpus I-picture produced a VideoToolbox decoded image: create/submit/callback status **0/0/0**, **720×480**, **66,190 compressed bytes**, PTS **0.233566667 s**. Both `0xbd80` and `0xbd81` AC-3 tracks independently produced PCM with converter create/fill status **0/0**: **1,248 frames, six channels, 29,952 PCM bytes**, from **1,792 compressed bytes** at the same starting PTS. The converter reports prime-info leading/trailing zero; the 1,248-frame first output is recorded as observed, without attributing its difference from 1,536 encoded samples to an unverified cause. Continuous output/sample-count accounting remains untested.

A two-second real HTTP source engine smoke run, using adapter formats and the unmodified native renderers, reported **playing**, **47 samples enqueued**, media clock **2.173472501 s**, **no renderer error**, and **786,433 response-body bytes**. This establishes the adapter can feed the sample-buffer engine on this Mac; the test has no visible display surface or audible listening assertion and does not establish synchronized, smooth playback or iOS support. CPU/RSS were not captured in that live run; instrumentation was subsequently added for future runs without redownloading solely for metrics.

A cached local-prefix run preparing formats and constructing the first 30 sample buffers (14 MPEG-2, eight from each AC-3 stream) measured **0.569888 s wall**, **0.569351 s process CPU**, **34,275,328-byte process peak RSS**, **606,208-byte peak growth**. These debug-process metrics include test/runtime work; they are not per-adapter allocation or a release benchmark. The adapter currently uses `Array.removeFirst`/packet queue shifts and rescans buffered video for boundaries, so there is real copying/scanning overhead. The observed CPU is substantial for this small startup batch and cannot justify a claim of efficient or sustained real-time playback; cursor/ring storage, incremental scanning and release/device measurements remain performance work.

Exact successful command with real decoding, IFO and engine gates enabled:

```sh
PROGRAM_STREAM_CORPUS_PREFIX=/tmp/archive-programstream-prefix.vob PROGRAM_STREAM_RENDER_NETWORK=1 PROGRAM_STREAM_CORPUS_IFO=/tmp/archive-programstream-title.ifo swift test --package-path ArchivePlayerCore --filter ProgramStream
```

That run passed **18 selected tests, one optional separate network-prefix probe skipped, zero failures**. The final bounded-scan revision was then rerun against cached data without another HTTP download: **18 selected tests, three optional skips, zero failures**. The selected count includes one byte-source integration regression alongside the owned PS tests. No engine/UI files were edited.

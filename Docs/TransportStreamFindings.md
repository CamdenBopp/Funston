# MPEG transport stream demuxing

`ArchivePlayerCore/TransportStreamDemuxer` is a native Swift, bounded 188-byte TS parser. It implements PAT/PMT section assembly and MPEG CRC checking; PMT stream and ISO-639/audio-type descriptors; payload continuity counters, duplicate suppression, explicit discontinuity resets; PES assembly with checked PTS/DTS marker bits and 90 kHz timestamps. Packet framing is explicitly exposed as `raw-pes-payload`.

Identified codecs: AVC/H.264, HEVC, AAC ADTS, AAC LATM, AC-3, E-AC-3, and MPEG audio. MPEG audio stream types cannot distinguish Layer II from Layer III: the first available elementary header refines `mpeg-audio` to `mp2`/`mp3`. Private-stream AC-3/E-AC-3 use DVB or registration descriptors. Language uses the first ISO-639 entry; audio types 2 and 3 map to hearing/visual impairment roles. Clean-effects type 1 is not commentary and is not incorrectly labeled as such.

Reads are at most 48,128 bytes, discovery scans at most approximately 4 MiB, each PES defaults to 4 MiB (configurable up to 16 MiB), aggregate in-progress PES is limited to 16 MiB, and program/track counts are capped at 64. PSI sections are capped at 1,024 bytes. Invalid sync, malformed lengths, truncated packets and excessive buffers fail with typed errors. Damaged/encrypted payload and interrupted PES are discarded.

## Boundaries

The raw `TransportStreamDemuxer` performs demuxing, not decoder-ready framing. One PES may contain multiple access units or parts of one. The separate `TransportStreamAccessUnitDemuxer` now supplies a verified narrow H.264/AAC playback path described below. Other codec framing remains unsupported. A small Annex-B helper identifies NAL units within a buffer and flags AVC IDR/HEVC IRAP; it caps returned units at 4,096.

Seeking returns `seekUnavailable`: no PCR index exists. Timestamps preserve the raw 33-bit clock; wrap normalization, PCR synchronization, and discontinuity timeline reconstruction are not implemented. PMT updates add/update tracks but do not atomically replace program inventories. Multi-program selection, M2TS (192 bytes), RS-protected 204-byte packets, byte resynchronization, encrypted TS, MPEG-2 video, subtitles, and complete malformed-stream recovery remain unsupported. Discovery stops at the first supported PMT. `tracks()` can later reflect MPEG audio header refinement.

## Sources and corpus

The parser is original Swift code; no FFmpeg, GPL, or third-party demuxer implementation was copied.

- [ITU-T H.222.0, Systems](https://www.itu.int/rec/dologin_pub.asp?id=T-REC-H.222.0-201410-S%21%21PDF-E&lang=e&type=items): transport packet, PES, PSI, stream types, timestamp and descriptor structure; clauses 2.4 and 2.6.
- [ETSI TS 101 154 V2.2.1](https://www.etsi.org/deliver/etsi_ts/101100_101199/101154/02.02.01_60/ts_101154v020201p.pdf): DVB carriage and AC-3/E-AC-3 descriptor context.
- [Apple HTTP Streaming Architecture](https://developer.apple.com/library/archive/documentation/NetworkingInternet/Conceptual/StreamingMediaGuide/HTTPStreamingArchitecture/HTTPStreamingArchitecture.html): MPEG-2 transport streams as encoded audio/video delivery containers.
- Real Internet Archive item: [Can I Name 100 MaxGGs Viewers? (Speedrun)](https://archive.org/details/twitch-videos-2179756722). [Item metadata](https://archive.org/metadata/twitch-videos-2179756722) lists `2179756722.ts`, format `MPEGTS`, size 3,438,030,260 bytes. On 2026-09-27, only bytes 0–1,048,575 were fetched from the [original TS](https://archive.org/download/twitch-videos-2179756722/2179756722.ts) for a bounded demux smoke test. This is corpus evidence, not a redistribution license or full-file playback certification.

The real-prefix test passed: Swift discovered PID 256 AAC and PID 257 H.264 and emitted ten nonempty PES payloads. Independent `ffprobe` on that same prefix reported audio AAC, 48,000 Hz, stereo, PID `0x100`; video H.264, PID `0x101`; and timed-ID3 data, PID `0x102`. Timed-ID3 is intentionally omitted from media tracks. `ffprobe` is only a development diagnostic; it is not linked or shipped in the app.

## Verification

`swift test` passed all 22 tests present at the initial run (one unrelated opt-in corpus test skipped). Synthetic TS tests cover PAT/PMT, CRC rejection, PSI/PES spanning packets, PES/PTS/DTS, IDR detection, language/role descriptors, duplicate/continuity-gap behavior, explicit discontinuity, MPEG audio Layer III identification, memory limit, truncated packets, and Annex-B start codes. The opt-in corpus test is enabled by `TRANSPORT_STREAM_CORPUS_PREFIX=/path/to/prefix.ts swift test --filter TransportStreamTests`; it probes tracks and extracts ten nonempty PES packets without claiming frame decoding.

Final TS-only run: 12 tests passed, zero failures or skips, including the real IA prefix (2026-09-27, macOS arm64, Swift 6.4).

## Decoder-ready H.264/AAC adapter and real rendering gate

`TransportStreamAccessUnitDemuxer(source:maximumBufferedBytes:)` wraps the raw parser. For H.264 it joins Annex-B bytes across PES boundaries, locates AUD-delimited access units, associates each AU with the applicable PES PTS/DTS via byte-offset markers, extracts SPS/PPS to avcC configuration, and emits length-prefixed NAL samples. The supported subset requires one first slice per AUD region and individual timestamps for separate AUs; absent AUD framing, multiple untimestamped AUs, and midstream configuration changes are not generally supported. HEVC and other video remain outside this adapter.

For AAC-LC ADTS, it carries partial frames, validates headers/profile/rate/channels, removes 7/9-byte ADTS headers, emits one 1,024-sample access unit per packet, and advances timestamps at the ADTS sample rate. A new frame-aligned PES without PTS preserves the computed AAC clock; regression coverage verifies this. LATM, HE-AAC, multiple raw blocks, program-config-element channel layouts, and discontinuity timeline reconstruction remain unsupported. Seeking still returns `seekUnavailable`.

The actual fixture disproved PES=frame: the first video PES was 258,677 bytes, while ffprobe's first AU was 258,741 bytes. The next PES began with the preceding frame's remaining 64 bytes, followed by the next AUD; its PTS applied to the next AU beginning inside that PES. The initial strict PES-aligned attempt therefore failed explicitly. The AUD/offset-marker assembler fixed this without discarding continuation bytes. A synthetic split-AU regression independently checks complete payload recovery and the next AU's timestamp.

Each PES timestamp marker is consumed by exactly one AU. A carried AUD region cannot reuse the preceding AU's timestamp after its buffer offset is rebased. Regression coverage includes PES1 containing A+B with only A's PTS, then PES2 containing C with a later PTS: B is rejected for a missing timestamp, rather than receiving A's or C's time. The same rejection is tested when B reaches EOF directly. No frame duration or missing timestamp is invented.

The adapter has a default **16MiB global retained-byte budget** across output queue, pending video, video carry, audio carry, SPS/PPS, codec configuration and timestamp markers. It checks the incoming packet before processing and retained state afterward. This is separate from the raw parser's own 16MiB PES budget. Individual video assembly is capped at 8MiB, audio carry at 1MiB, discovery at 512 PES packets and 8MiB queued samples; marker/NAL counts are bounded. A configurable tiny-budget regression verifies rejection. Temporary input/copy overhead and CoreMedia renderer-owned queues are not described as part of that retained-byte count.

Run `IA_TS_RENDER_TESTS=1 swift test --filter TransportStreamTests`. Final run: **17 tests, one unrelated opt-in prefix test skipped, zero failures**. The gate uses [the original 2179756722.ts file](https://archive.org/download/twitch-videos-2179756722/2179756722.ts) through bounded HTTP ranges, the raw TS parser, the access-unit adapter, shared CoreMedia factories, and actual Apple audio/video renderers (audio volume zero).

Observed macOS arm64 run on 2026-09-27: startup to both renderer statuses `.rendering` **3.009s**; wall observation **6.016s**; process CPU delta **0.474s**; process peak RSS **54,132,736 bytes**, versus prior high-water mark **26,509,312 bytes**; HTTP transfer **1,572,865 bytes**; **213 samples enqueued**; clock advanced **2.997s** during the final three-second interval; video/audio statuses **1/1**, error **nil**. RSS values are process high-water marks, not isolated per-engine allocation measurements. A previous cold run transferred1,310,721 bytes and completed in10.456s; network/startup variation is real.

This verifies the limited H.264/AAC TS renderer path on this Mac. It does not prove physical iPhone playback, visible-window smoothness, audible output, TS seek, all streams/codecs, or loss recovery across arbitrary discontinuities. Engine raw-TS rejection remains intentional; callers must use the adapter. Apple parameter-set construction reference: [CMVideoFormatDescriptionCreateFromH264ParameterSets](https://developer.apple.com/documentation/coremedia/cmvideoformatdescriptioncreatefromh264parametersets(allocator:parametersetcount:parametersetpointers:parametersetsizes:nalunitheaderlength:formatdescriptionout:)).

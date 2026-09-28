# Corpus conformance and startup measurements

`ArchivePlayerCore/Tests/ArchivePlayerCoreTests/CorpusConformanceTests.swift` adds three development tests: malformed-input typed errors, optional local ffprobe oracle comparisons, and optional real Internet Archive HTTP Range startup measurements. No oracle executable or library is added to the application or package dependencies.

## Measured run

2026-09-27, macOS 27.0 build 26A428, arm64, Swift 6.4, debug XCTest process, ffprobe 9.0.2. Three conformance tests passed with zero skips/failures in 8.767 seconds. The run used separate ephemeral URL sessions, a 256 KiB read-ahead window, sequential formats, and no decoded playback. This is one startup sample, not a statistically stable benchmark. The table below records the original HTTP reader.

Afterward, the HTTP reader changed to a bounded `URLSessionDataDelegate` that accepts chunks. A second live conformance run passed for all three items. Its metadata phases measured **0.046798 s process CPU / 262,145 response bytes for MKV**, **0.141444 s / 2,097,153 bytes over nine requests for VOB**, and **0.043209 s / 262,145 bytes for TS**. These are separate debug-process samples, not a paired benchmark. The current reader also passed seven adversarial tests for ignored Range headers, oversized responses, arithmetic overflow, ETag changes, cache-slice indexing, and cancellation.

| Format / phase | Wall seconds | Process CPU seconds | HTTP body bytes | Range requests | Process peak RSS bytes | Peak RSS growth bytes |
|---|---:|---:|---:|---:|---:|---:|
| MKV metadata | 1.762676 | 0.047994 | 262145 | 2 | 34291712 | 5079040 |
| MKV next 32 packets | 0.003702 | 0.003701 | 0 | 0 | 34455552 | 147456 |
| VOB metadata | 4.293820 | 0.123607 | 2097152 | 8 | 38404096 | 3932160 |
| VOB next 32 packets | 0.001586 | 0.001586 | 0 | 0 | 38404096 | 0 |
| TS metadata | 1.807734 | 0.027742 | 262144 | 1 | 39157760 | 753664 |
| TS next 32 packets | 0.754311 | 0.036656 | 262144 | 1 | 39927808 | 770048 |

Wall uses monotonic system uptime. CPU uses `clock()` for the entire test process; RSS uses Darwin `getrusage(RUSAGE_SELF).ru_maxrss` (bytes). Peak RSS is a process lifetime high-water mark, so neither the peak nor its growth isolates demuxer memory. Earlier tests, XCTest, Foundation, and networking contribute. Zero growth does not mean zero allocation. HTTP counts include successful response bodies and exclude headers, TLS overhead, and the separate local-fixture downloads. The metadata phase includes network waits; next-32 measures incremental delivery after metadata, often from buffers. The VOB probe retains PES packets while discovering tracks, explaining its zero additional packet transfer. Each corpus startup asserts total transfer below 8 MiB.

No release-build/device CPU, exact resident allocation, decoder memory, A/V drift, seek performance, energy, thermal behavior, full-file duration, long-run leak, or percentile latency measurements were performed by this harness. The results cannot establish decoded playback readiness.

## Track agreement

| Corpus original | Swift observed media | Local ffprobe oracle | Result / limitation |
|---|---|---|---|
| [Multi-audio MKV](https://archive.org/download/the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub/The%20Ancient%20Magus%27%20Bride%20S01E03%20720p%20HD%20BluRay%20Multi%20Audio%20ESub.mkv) | H.264; AAC Hindi, Opus English, Opus Japanese; two English PGS subtitles; all audio stereo | Same codec multiset, audio languages and channel counts | HTTP source and local ffprobe are compared to the same explicit fixture manifest. The local truncated MKV is not passed to Swift because its declared Segment length exceeds the prefix length. |
| [VTS_01_1.VOB](https://archive.org/download/vts-01-1_20250820_1408/VTS_01_1.VOB) | MPEG-2 video `0xe0`; AC-3 `0xbd80`, `0xbd81` | MPEG-2 `0x1e0`; AC-3 `0x80`, `0x81`, six channels each | Codec multiset and normalized stream IDs agree. Raw VOB demux alone does not expose channels/language. ffprobe NAV data stream is excluded. IFO enrichment is tested separately in ProgramStreamTests. |
| [2179756722.ts](https://archive.org/download/twitch-videos-2179756722/2179756722.ts) | AAC PID 256; H.264 PID 257 | AAC `0x100`, stereo; H.264 `0x101`; timed-ID3 `0x102` | Media codec/ID sets agree. Swift intentionally omits timed-ID3 and does not yet extract AAC channel count. |

The ffprobe comparisons use bounded 1 MiB original-file prefixes. They do not prove discovery of sparse tracks later in a file. Format-specific data streams are intentionally excluded when comparing media track sets. The harness emits the complete observed track descriptions for review.

## Reproduction

Download development-only prefixes (not committed):

```sh
curl -L --fail --max-time 40 --range 0-1048575 'https://archive.org/download/the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub/The%20Ancient%20Magus%27%20Bride%20S01E03%20720p%20HD%20BluRay%20Multi%20Audio%20ESub.mkv' -o /tmp/ia-conformance-prefix.mkv
curl -L --fail --max-time 40 --range 0-1048575 'https://archive.org/download/vts-01-1_20250820_1408/VTS_01_1.VOB' -o /tmp/archive-programstream-prefix.vob
curl -L --fail --max-time 40 --range 0-1048575 'https://archive.org/download/twitch-videos-2179756722/2179756722.ts' -o /tmp/ia-transport-corpus.ts
```

Exact successful conformance invocation:

```sh
IA_CONFORMANCE_NETWORK=1 IA_FFPROBE=/opt/homebrew/bin/ffprobe IA_CONFORMANCE_MKV_PATH=/tmp/ia-conformance-prefix.mkv IA_CONFORMANCE_VOB_PATH=/tmp/archive-programstream-prefix.vob IA_CONFORMANCE_TS_PATH=/tmp/ia-transport-corpus.ts swift test --package-path ArchivePlayerCore --filter CorpusConformanceTests
```

Oracle command executed per prefix:

```sh
/opt/homebrew/bin/ffprobe -v error -show_entries stream=id,codec_name,codec_type,channels:stream_tags=language -of json /tmp/ia-conformance-prefix.mkv
```

Repeat with the VOB/TS paths. Without environment flags, network and oracle tests skip; malformed-input checks run offline. Network errors fail when the network test is explicitly enabled, so availability failures remain distinguishable in test logs.

## Error and regression evidence

Six malformed/truncated fixtures across MKV/VOB/TS return `DemuxError`, without accepting silent success or an unrelated error type. These are targeted parser-boundary checks, not exhaustive fuzzing.

The first network run exposed a real crash in Matroska header parsing: an HTTP cache read returned a `Data` slice with a nonzero start index, while the parser indexed `[0]`. The shared byte-source implementation was corrected to return rebased data, and the full three-format conformance run then passed. No shared source was modified by this harness workstream.

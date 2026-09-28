# Branch B: development-only fragmented-MP4 remux experiment

On the tested macOS 27 host, stream-copy remuxing made a synthetic H.264/AAC MKV readable by AVFoundation while preserving both audio streams. Synthetic MPEG-2/AC-3 VOB and TS originals already worked locally, as did their fragmented-MP4 variants. This is evidence for a container bridge on this host, not a decision to ship FFmpeg or a universal compatibility claim.

## Reproducible artifacts

- `Scripts/RemuxExperiment.sh` generates three-second synthetic originals, performs measured `-c copy` remuxes, saves ffprobe metadata and `/usr/bin/time -l` output, and compares compressed elementary-stream SHA-256 hashes.
- `ArchivePlayerCore/Tests/ArchivePlayerCoreTests/RemuxExperimentTests.swift` loads each original/result with AVURLAsset, enumerates tracks, decodes a PCM buffer from each audio track using AVAssetReader, and polls AVPlayerItemVideoOutput for a decoded video pixel buffer. AVPlayer stays muted.
- Fixtures and experiment logs live in temporary directories, not the application bundle. FFmpeg/ffprobe are development tools only; no library, binary, or dependency was added to the app.

Commands used:

```sh
bash Scripts/RemuxExperiment.sh
REMUX_EXPERIMENT_DIR=/tmp/archive-remux-experiment.9lFxmA swift test --package-path ArchivePlayerCore --filter RemuxExperimentTests
```

The script prints its newly created directory; substitute that directory when reproducing. `FFMPEG` and `FFPROBE` can override the default `/opt/homebrew/bin` executables. It avoids overwriting existing fixtures. Final script, including hash comparison, was independently rerun successfully in `/tmp/archive-remux-experiment.RwGvFE`.

Environment: 2026-09-27, macOS 27.0 build 26A428, arm64, Swift 6.4, ffmpeg/ffprobe 9.0.2. Fixture generation encodes H.264/AAC and MPEG-2/AC-3 from synthetic test video and two different sine tones; that generation is outside measured remux CPU/time. The VOB fixture is a program-stream file, not an authored DVD with menus/IFO/navigation.

## Preservation and remux cost

Every input contains one video and two mono audio tracks. H.264 MKV audio carries `eng`/`hin`. VOB cannot carry those IFO-style language tags in this standalone fixture, so its audio remains unknown; the TS fixture explicitly supplies language descriptors. All three remuxes preserve codec identities, track counts, channel counts, and available language tags in ffprobe. Every compressed video/audio stream hash matches before and after each remux. Container duration differs by less than a millisecond because of time-base representation; timestamps were not individually compared.

| Original | Input bytes | Fragmented MP4 bytes | Wall / user / system seconds | FFmpeg peak RSS bytes |
|---|---:|---:|---|---:|
| H.264 + 2 AAC MKV | 184030 | 185512 | 0.02 / 0.02 / 0.00 | 18120704 |
| MPEG-2 + 2 AC-3 VOB | 829440 | 821231 | 0.02 / 0.02 / 0.00 | 17465344 |
| MPEG-2 + 2 AC-3 TS | 863860 | 821231 | 0.02 / 0.02 / 0.00 | 17940480 |

These short-file timings are rounded by `/usr/bin/time`, include process startup, and cannot establish throughput. Bytes are whole local file sizes, not startup network transfer or filesystem I/O counts. Peak RSS belongs to the standalone FFmpeg process, not a hypothetical in-process remux implementation.

An initial `empty_moov+frag_keyframe+default_base_moof` attempt failed for both AC-3 cases: FFmpeg could not write the initialization metadata before reading AC-3 packets. Adding `delay_moov` allowed all remuxes to succeed. The final measured command shape is:

```sh
/usr/bin/time -l -o timing.txt ffmpeg -hide_banner -loglevel warning -nostdin -i input \
  -map 0:v -map 0:a -c copy \
  -movflags +empty_moov+delay_moov+frag_keyframe+default_base_moof -f mp4 output.fragmented.mp4
```

This shows that initialization may require inspecting media packets; immediate zero-read initialization is not demonstrated. The experiment reads completed local fragmented MP4s. It does not implement a growing-file, resource-loader, localhost, HLS, or on-demand range remux delivery mechanism.

## AVFoundation observations

Final AV test passed in 1.068 seconds. H.264 remux has explicit success assertions; other formats are observational probes and log unsupported outcomes rather than failing the experiment. In this run all playable cases emitted a video pixel buffer, both audio tracks emitted PCM, and AVPlayerItem reached ready status with no error.

| File | AVURLAsset | Asset load seconds | AVPlayer frame wait seconds | Total process CPU seconds | Test-process peak RSS bytes |
|---|---|---:|---:|---:|---:|
| Original MKV | Rejected: -11828 / underlying -12847 | 0.011558 to error | — | Not recorded | Not recorded |
| MKV → fragmented MP4 | Playable, 3 tracks | 0.019344 | 0.149941 | 0.090814 | 51544064 |
| Original VOB | Playable, 3 tracks | 0.013240 | 0.106904 | 0.057718 | 56999936 |
| VOB → fragmented MP4 | Playable, 3 tracks | 0.004228 | 0.105001 | 0.069722 | 58785792 |
| Original TS | Playable, 3 tracks | 0.009238 | 0.105957 | 0.065194 | 60964864 |
| TS → fragmented MP4 | Playable, 3 tracks | 0.004100 | 0.105443 | 0.073962 | 61325312 |

Asset load timing ends after track metadata. Frame wait begins at `play()` after per-track audio PCM probes, with 20 ms polling granularity. CPU includes asset loading, audio probes and player startup. Peak RSS is the entire XCTest process lifetime high-water mark and rises across cases; it is not per-player memory, allocation, or a reliable comparison of formats. Loading/decoding audio first may warm caches and affect later video startup. No cold-cache control or repetition statistics were used.

AVFoundation exposed `eng`/`hin` on MKV-remux and TS-remux audio tracks. Original TS tracks were reported with unknown language by AVFoundation despite ffprobe seeing TS descriptors. Both audio streams were decoded independently; audible listening, live switching, media-selection grouping, playback to end, full A/V sync, subtitle preservation, forced/commentary roles, and seeking were not tested. One decoded video frame proves more than `isPlayable`, but less than complete playback.

## Comparison with the sample-buffer path

The existing demux conformance results measure metadata/packet startup over real IA HTTP ranges; this experiment measures completed tiny local files through FFmpeg and native AVFoundation. Those workloads, clocks, buffers, and process boundaries differ. Their CPU/RSS numbers cannot rank the sample-buffer path against remuxing.

The custom path has separate H.264 sample-buffer/decoder checks and MPEG-2 session/frame evidence, but this experiment does not supply a matched two-audio-track rendering run, end-to-end startup, memory, switching, sync or seeking measurement for it. It also does not measure the engineering cost or behavior of a native fragmented-MP4 writer. A controlled same-source, same-device, same-network comparison remains necessary before choosing either architecture. macOS success does not establish iOS device/simulator MPEG-2 or AC-3 support, and the synthetic codecs do not cover arbitrary MKV/VOB/TS contents.

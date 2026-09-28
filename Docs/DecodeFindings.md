# Real Internet Archive decode validation

Run on Apple silicon macOS on 2026-09-27:

```sh
IA_NETWORK_TESTS=1 swift test --filter MatroskaDecodeTests
```

All three tests passed. Each uses the app's HTTP Range source and Matroska demuxer against IA item `the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub`, file `The Ancient Magus' Bride S01E03 720p HD BluRay Multi Audio ESub.mkv`. [Exact IA metadata](https://archive.org/metadata/the-ancient-magus-bride-s-01-e-03-720p-hd-blu-ray-multi-audio-esub). No whole-file download or external codec library is involved.

| Stream | Compressed packet | Actual decoded output | HTTP bytes | End-to-end observed time |
| --- | ---: | --- | ---: | ---: |
| H.264 video | 974 bytes | One callback CVImageBuffer, 1280 × 720 | 4,097 | 1.203 s |
| Hindi AAC | 371 bytes | 1,024 interleaved Float32 PCM frames, 8,192 bytes | 12,289 | 2.924 s |
| English Opus | 250 bytes | 840 interleaved Float32 PCM frames, 6,720 bytes | 4,097 | 1.236 s |

These are single observed runs with a 4 KiB Range read-ahead window; times include network, demux, format setup and decode. They are not performance guarantees. H.264 uses the real avcC CodecPrivate through `FormatDescriptionFactory.h264`, a real demuxed keyframe through `SampleBufferFactory.make`, and VTDecompressionSession submission. Session creation, submission, delayed-frame completion, asynchronous wait and callback status were all zero. The test requires a non-nil callback image with the expected dimensions; session creation alone cannot pass it. This does not distinguish hardware from software decode.

AAC uses the real AudioSpecificConfig through `FormatDescriptionFactory.aac` to establish the input ASBD, then AudioConverter to obtain PCM. Offering the raw AudioSpecificConfig as `kAudioConverterDecompressionMagicCookie` returns 560226676 (`!dat`) on this host. The explicit ASBD is sufficient for this AAC-LC sample: converter creation and `AudioConverterFillComplexBuffer` both return zero and produce the frames above. The test prints the cookie rejection rather than treating raw ASC as a proven valid Apple cookie. Other AAC profiles/cookie representations need independent validation.

Opus uses the track's actual OpusHead CodecPrivate as the decompression magic cookie, 48 kHz, its declared channels, and a 960-frame packet ASBD for this fixture. Cookie installation, converter creation and fill all return zero. This validates this stereo packet, not all Opus channel mapping families or variable packet durations. Container CodecDelay/SeekPreRoll and continuous playback trimming remain responsibilities of the complete player.

An initial run trapped before decoding because HTTP Range Data slices had nonzero indices while the EBML header parser accessed byte zero. LLDB located the trap in `MatroskaDemuxer.header` during EBML metadata parsing. The parent task corrected ByteSource index rebasing, after which all real decode tests passed. These tests therefore also exercise that integration boundary.

Primary Apple API references:

- [VTDecompressionSessionDecodeFrame](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsessiondecodeframe(_:samplebuffer:flags:framerefcon:infoflagsout:))
- [VTDecompressionSessionFinishDelayedFrames](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsessionfinishdelayedframes(_:))
- [VTDecompressionSessionWaitForAsynchronousFrames](https://developer.apple.com/documentation/videotoolbox/vtdecompressionsessionwaitforasynchronousframes(_:))
- [AudioConverterFillComplexBuffer](https://developer.apple.com/documentation/audiotoolbox/audioconverterfillcomplexbuffer(_:_:_:_:_:_:))

Scope: these are real single-packet decode gates on this Mac, not end-to-end playback, A/V synchronization, seeking continuity, long-duration resource use or iPhone validation. Native format and sample construction are shared with the player, but the audio conversion harness here is test code and is not an audio renderer implementation.

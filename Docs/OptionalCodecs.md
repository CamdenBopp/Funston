# Branch D: optional codec investigation

The repository now has an independent `ArchivePlayerExtraCodecs` Swift package containing a configuration-policy audit library and CLI. It contains **no FFmpeg source, headers, objects, binaries, binary target, system-library target, dynamic loader or decoder implementation**. Core and app were not edited and do not depend on/import it. Adding the package does not enable any extra playback codec. The intended narrow future fallback is software MPEG-2 video, AC-3, E-AC-3 and DTS (`dca`) decoding; FFmpeg encoders, demuxers, protocols and filters are outside this proposal.

## Local development binary is excluded

On 2026-09-27, `ffmpeg -version` reported Homebrew FFmpeg **9.0.2**, configured with `--enable-gpl`, `--enable-version3`, `--enable-libx264` and `--enable-libx265` among other libraries. `otool -L /opt/homebrew/opt/ffmpeg/lib/libavcodec.dylib` independently showed x264/x265 and other Homebrew dependencies. That installed binary is unsuitable for the proposed LGPL-only component. It was inspected as development evidence only; nothing from it was copied, linked or loaded by this package.

FFmpeg's default project license is LGPL 2.1 or later, while optional GPL components change the resulting FFmpeg license. Nonfree configuration can make a resulting build unredistributable. An LGPL-only build is therefore a deliberately selected build, not a property inferred from the name “FFmpeg.” See the [official licensing page](https://ffmpeg.org/legal.html) and [release-specific license inventory](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.2/LICENSE.md). These sources describe license obligations; this investigation is not a determination that a particular App Store distribution/relinking arrangement satisfies them.

## Reproducible external build candidate

The candidate is pinned to official mirror tag **n9.0.2**, peeled commit **946fcce07b6dcd0331c8cc609192aeff5e1924f8**. `git ls-remote` verified that mapping on 2026-09-27. The [official download page](https://ffmpeg.org/download.html) identifies the GitHub repository as a mirror and describes signed release verification. Before building, authenticate the release/tag against the upstream signing key and verify the exact commit; a matching unverified string is not provenance. No FFmpeg source checkout was created by this task. Its upstream tree includes optional GPL files, so do not vendor that entire tree into the app as if every file were LGPL.

The following is the **proposed, not executed**, macOS arm64 configure recipe. Set the two absolute paths to an authenticated external checkout and a new installation prefix. Run it from a separate empty build directory. It uses the [release's actual configure switches](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.2/configure), disables external-library autodetection and names a small decoder/parser allowlist:

```sh
FFMPEG_SOURCE=/absolute/external/verified-ffmpeg-n9.0.2
FFMPEG_PREFIX=/absolute/new/ffmpeg-lgpl-macos-arm64
test "$(git -C "$FFMPEG_SOURCE" rev-parse HEAD)" = 946fcce07b6dcd0331c8cc609192aeff5e1924f8
test -z "$(git -C "$FFMPEG_SOURCE" status --porcelain)"
"$FFMPEG_SOURCE/configure" \
  --prefix="$FFMPEG_PREFIX" \
  --cc="$(xcrun --find clang)" \
  --arch=aarch64 --target-os=darwin \
  --extra-cflags=-mmacosx-version-min=15.0 \
  --extra-ldflags=-mmacosx-version-min=15.0 \
  --disable-gpl --disable-nonfree --disable-version3 \
  --disable-autodetect --disable-everything \
  --disable-programs --disable-doc --disable-network \
  --disable-avdevice --disable-avformat --disable-avfilter \
  --disable-swscale --disable-swresample \
  --disable-static --enable-shared --enable-pic \
  --enable-avcodec --enable-avutil \
  --enable-decoder=mpeg2video,ac3,eac3,dca \
  --enable-parser=mpegvideo,ac3,dca
```

Audit the generated `config.h` and `config_components.h` before running `make`. From this repository:

```sh
swift run --package-path ArchivePlayerExtraCodecs audit-ffmpeg-build \
  /absolute/build/config.h /absolute/build/config_components.h \
  946fcce07b6dcd0331c8cc609192aeff5e1924f8
```

The gate requires the generated LGPL-2.1-or-later license string, disabled GPL/nonfree/version3/static/network and unused libraries, shared avcodec/avutil, exactly the allowed enabled components and no enabled `CONFIG_LIB*` external library. It rejects missing fields, duplicated definitions, conflicting GPL-enable flags and unpinned revisions. It checks text inputs, not binary authenticity. This recipe and gate have **not** been exercised against a newly configured FFmpeg tree, so dependency selections still need a real configuration/build review before integration. Host macOS instructions are not an iOS device/simulator build recipe; those need separate SDK/target slices and packaging validation. FFmpeg's [platform guide](https://ffmpeg.org/platform.html) supplies platform context.

## Artifact and distribution audit still required

For an eventual build, retain authenticated source identity, exact source archive and hash, patches, configure command, configure output, generated headers, toolchain/SDK versions and binary hashes. Inspect every dylib with `otool -L` and `nm -u`; accept only the specifically built avcodec/avutil libraries and audited Apple system dependencies. A missing x264 dependency alone is insufficient proof: static GPL code would not appear as a dylib dependency. Check `avcodec_configuration()`/`avcodec_license()` and the corresponding avutil APIs against the retained build evidence. Review all included file notices and dependencies, not merely flags.

Before distribution, complete the upstream LGPL checklist: make exact corresponding source and changes available, preserve applicable notices, document the build, supply attribution and satisfy the applicable modification/relinking requirements. Dynamic linking is upstream's recommended route; an XCFramework or Swift package wrapper does not itself meet those obligations. Static-linking alternatives require their own relinking materials and review. App signing/store terms, installation constraints and codec patent obligations remain separate questions; no shipping clearance is claimed here. [FFmpeg's official compliance guidance](https://ffmpeg.org/legal.html).

## Integration remains unimplemented

The eventual bridge would own decoder contexts and use [FFmpeg's send/receive API](https://ffmpeg.org/doxygen/trunk/group__lavc__encdec.html), including EAGAIN, drain and seek-flush behavior. It must map demux codec-private data and timestamps, preserve packet lifetime/padding, bound allocations, convert output frames/planes into CoreVideo or PCM buffers, and report actual native-versus-fallback capability. None of that bridge exists here. No fallback decoder is advertised by this package; its `decoderIntegrationImplemented` value is false.

Validation completed: `swift package dump-package` succeeded and showed no external dependencies, binary targets or system-library targets. An initial `swift test` attempt failed during XCTest dependency scanning with **No space left on device**; only that generated `.build` directory was removed. After recovering space, `swift test --package-path ArchivePlayerExtraCodecs -j 2` passed all four audit tests with zero failures on macOS. The tests cover an allowed configuration, GPL/nonfree/version3 rejection, unexpected components/libraries/revision, and conflicting/duplicate definitions. No FFmpeg source checkout/archive, binary build or linking was attempted; configuration/license references were read remotely.

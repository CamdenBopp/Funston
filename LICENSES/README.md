# License inventory

The `ArchivePlayerCore` source target is original Swift source covered by the
repository's root `LICENSE` (**SPDX: MIT**). It has no package dependencies;
CoreMedia, AVFoundation, AudioToolbox, and VideoToolbox are Apple system
frameworks. It does not contain or link GPL, LGPL, or MPL code.

The iOS app also depends on:

| Component | Version/revision | SPDX | License evidence |
| --- | --- | --- | --- |
| LNPopupController | 4.5.12 (vendored) | MIT | `Vendor/LNPopupController/LICENSE` |
| LNSystemMarqueeLabel | 0.1.2 / `a87c80c36e8cc84f05a691da33c838a8e93015f6` | MIT | upstream `LICENSE` in the resolved SwiftPM checkout |

`ThirdPartyNotices.txt` contains the copyright and permission text for both
dependencies. The exact resolved revision is in
`Archive.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

Tools used only while developing or testing (for example, `ffmpeg`/`ffprobe`)
are not linked, vendored, or required by the core target. The separate
`ArchivePlayerExtraCodecs` package currently contains only MIT-licensed
configuration-audit code; it does **not** include a codec decoder or any
FFmpeg source, header, library, or binary. Its proposed future LGPL-only
build and outstanding verification gates are documented in
`Docs/OptionalCodecs.md`. The app and core package do not depend on it.

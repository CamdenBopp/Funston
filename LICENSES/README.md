# License inventory

The app's own source is covered by the repository's root `LICENSE`
(**SPDX: MIT**). It depends on:

| Component | Version/revision | SPDX | License evidence |
| --- | --- | --- | --- |
| [ArchivePlayerCore](https://github.com/CamdenBopp/ArchivePlayerCore) | 0.1.0 or later | MIT | same author; no dependencies of its own |
| LNPopupController | 4.5.12 (vendored) | MIT | `Vendor/LNPopupController/LICENSE` |
| LNSystemMarqueeLabel | 0.1.2 / `a87c80c36e8cc84f05a691da33c838a8e93015f6` | MIT | upstream `LICENSE` in the resolved SwiftPM checkout |

`ThirdPartyNotices.txt` contains the copyright and permission text for every
linked dependency. The EPUB reader is Funston's own code over system frameworks
(Foundation, Compression, zlib, libxml2, TextKit 2, ImageIO); it links no package.
The exact resolved revisions are in
`Funston.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

Tools used only while developing or testing (for example, `ffmpeg`/`ffprobe`)
are not linked, vendored, or required. Nothing in the app or its dependencies
contains or links GPL, LGPL, or MPL code.

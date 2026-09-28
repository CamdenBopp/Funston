# License inventory

The app's own source is covered by the repository's root `LICENSE`
(**SPDX: MIT**). It depends on:

| Component | Version/revision | SPDX | License evidence |
| --- | --- | --- | --- |
| [ArchivePlayerCore](https://github.com/CamdenBopp/ArchivePlayerCore) | 0.1.0 or later | MIT | same author; no dependencies of its own |
| LNPopupController | 4.5.12 (vendored) | MIT | `Vendor/LNPopupController/LICENSE` |
| LNSystemMarqueeLabel | 0.1.2 / `a87c80c36e8cc84f05a691da33c838a8e93015f6` | MIT | upstream `LICENSE` in the resolved SwiftPM checkout |
| [Readium Swift Toolkit](https://github.com/readium/swift-toolkit) | 3.11.0 (ReadiumShared, ReadiumStreamer, ReadiumNavigator) | BSD-3-Clause | upstream `LICENSE` |
| SwiftSoup, Zip, Fuzi, ZIPFoundation | as resolved by Readium | MIT | upstream `LICENSE` files |
| CryptoSwift | as resolved by Readium | zlib-style (attribution) | upstream `LICENSE` |
| DifferenceKit | as resolved by Readium | Apache-2.0 | upstream `LICENSE` |

`ThirdPartyNotices.txt` contains the copyright and permission text for every
linked dependency. GCDWebServer and SQLite.swift appear in `Package.resolved`
because Readium's package declares them, but neither is linked into the app. The exact resolved revision is in
`Funston.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

Tools used only while developing or testing (for example, `ffmpeg`/`ffprobe`)
are not linked, vendored, or required. Nothing in the app or its dependencies
contains or links GPL, LGPL, or MPL code.

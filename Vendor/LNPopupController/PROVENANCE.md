# LNPopupController provenance

- Upstream: https://github.com/LeoNatan/LNPopupController
- Tag: `4.5.12`
- Commit: `2c441458a4ed37a940ec01d63748f26375cae6e9`
- Retrieved: September 27, 2026 through Swift Package Manager.
- Included: `LNPopupController/`, `LNPopupController+Swift/`, upstream `LICENSE`, and patched `Package.swift`. Example app and supplementary media omitted.
- License: MIT; upstream license retained, with distribution notice in `Archive/Resources/ThirdPartyNotices.txt`.
- Runtime source comparison: `diff -qr` for both included runtime directories against the tagged SPM checkout produced no differences.

The only upstream file changed is `Package.swift`: replace dynamic directory enumeration with explicit private header search paths. Xcode 27 generated truncated paths from the original manifest and could not find existing headers. All runtime source, public headers, resources and APIs are unchanged. The patched package compiled in the app's iOS Simulator build.

SHA-256 of upstream `Package.swift`:
`f737effc194f56b5dc44f2c6cef0e5a2aa1514f58c84df5b0dce0c375fe8226b`

SHA-256 of patched `Package.swift`:
`d81616e5bf76c46265258a4cd2821df2f40f975627a6a06c773c175463b5afab`

The transitive MIT dependency `LNSystemMarqueeLabel` remains a remote package, resolved to `0.1.2`, commit `a87c80c36e8cc84f05a691da33c838a8e93015f6`. Keep the Xcode workspace `Package.resolved` when reproducing this build.

To update: compare a new stable tag's runtime changes and manifest against this revision, replace the runtime directories, re-evaluate whether the manifest patch is still necessary, update checksums/notices, resolve packages and validate both tab and split-container player presentation.

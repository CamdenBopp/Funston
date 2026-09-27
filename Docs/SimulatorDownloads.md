# Simulator downloads

Simulator builds use an in-process default URLSession for downloads. Physical-device builds keep the background session `com.camden.Archive.background-downloads`, including launch events and durable reconciliation. Explicit configurations supplied by tests still take precedence.

This development accommodation is based on an observed failure on the iOS 18.3.1 simulator under Xcode 27: CFNetwork could not establish the XPC connection to `com.apple.nsurlsessiond` (`NSCocoaErrorDomain` 4097), then failed to create the background download task (`NSURLErrorDomain` -1). The Flatland PDF transfer failed at zero bytes; a direct request returned HTTP 200, `application/pdf`, and the exact expected 6,986,644-byte size. No PDF parsing had occurred.

The simulator still exercises live HTTP transfers, progress, cancellation, response/size validation, file moves, database persistence, PDF opening and completed-file reuse. It cannot prove that an in-flight transfer continues after app termination. Validate background continuation and system relaunch on a physical device before release.

Unknown/disconnected-service failures now show actionable retry wording. Download diagnostics record error domain and code through unified logging, without logging artifact URLs.

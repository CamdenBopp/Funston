# Whole Earth Catalog reader and polish pass

## Status: polish implemented; fast-scroll blank pages remain unresolved

Follow-up clarification: the user reports that the flashing/blank reader happens during our device tests, not ordinary app use, and that ordinary scrolling feels smoother. The rapid-jump harness and its temporary-window teardown must not be presented as a reproduced normal-use crash. Further automated phone benchmarks were stopped. The latest physical crash log (20:47) identifies the earlier test-only `PDFPerformanceView.draw` Swift actor assertion, not the shipping reader; the corrected harness uses an Objective-C override. No later Archive crash or same-evening jetsam report was found when checked around 21:20.

The phone's download database identifies the user's actual item as [wholeearthcatalo00unse_2](https://archive.org/metadata/wholeearthcatalo00unse_2), *Whole Earth Catalog: Signal Communication Tools for the Information Age*, a 51,383,890-byte Text PDF. The 452-page fixture below is a different Whole Earth Catalog edition, used as a stress case—not a measurement of that exact download.

User reported blank pages for seconds during fast PDF scrolling and identified the Whole Earth Catalog. The physical-device fixture is [B-001-013-719](https://archive.org/metadata/B-001-013-719), `B-001-013-719.pdf`: 82,841,533 bytes, 452 pages. Its scanned images include JPEG 2000 (`JPXDecode`) and JBIG2 masks. The reader already downloads the entire PDF before displaying it, so scrolling does not wait for individual page network requests.

Keep native PDFKit and continuous scrolling. Native horizontal paging was tested and rejected as the default performance fix: in the first comparison it used 30.71 CPU seconds versus 11.58 for continuous scrolling, with sampled RSS 781 versus 550 MB. This was a sequential comparison, not a controlled cold-cache benchmark.

The rejected cache experiment uses PDFKit's public `PDFDocumentDelegate.classForPage` and `PDFPage.draw(with:to:)` hooks. Background tile draws can share a 1536-pixel-wide page raster. Main-thread cache misses immediately use native drawing rather than waiting on another renderer. The original PDF still supplies text, selection, links, native Find, and accessibility. Zoom above the cached resolution, annotations, rotated pages, nonzero-origin boxes, and unusual aspect ratios retain native drawing. Transparent content remains transparent. No PDF bytes are modified. This code now lives **only in FunstonTests**, not the application target, because the corrected measurements did not establish a reliable fix.

The LRU retains at most 48 MiB per document and clears on memory warnings. This limit is **not** a total-process memory ceiling: concurrent drawing contexts, PDFKit caches, decoded source images, and GPU backing stores are additional. No eager whole-book rendering, polling timer, disk derivative, or new third-party dependency is introduced.

## Physical measurements

iPhone 14 Pro Max, connected device `00008120-001854922238201E`, iOS 27.0, Release build. Each isolated run opens the already-downloaded file, warms for 900 ms, jumps through zero-based pages 10–25 with 200 ms dwell, then settles for 700 ms. Display Zoom produces a 375 × 730 pt PDF viewport in this harness.

| Run | CPU seconds | Measurement seconds | Sampled peak RSS, decimal MB | Maximum main-actor wake excess |
| --- | ---: | ---: | ---: | ---: |
| Native continuous, 21:00 | 12.182 | 3.986 | 524.3 | 5.58 ms |
| Native continuous repeat, 21:03 | 11.889 | 3.991 | 568.8 | 3.73 ms |
| Corrected cache, PDFPage drawing, 21:09 | 11.039 | 4.001 | 498.0 | 3.31 ms |
| Corrected cache, direct Core Graphics + low interpolation, 21:11 | 12.229 | 3.999 | 525.8 | 5.44 ms |
| Native continuous + low interpolation, 21:12 | 11.590 | 3.967 | 511.5 | 3.58 ms |

The earlier 21:01 cache run is **invalid as performance evidence**: a subsequent multipage regression exposed an identity collision, because PDFKit constructed Swift PDFPage subclasses without initializing their stored UUID/lock properties. The stateless experimental page subclass now uses Core Graphics' document-local page number, with lock state owned by the normally initialized delegate. An earlier cache version also caused a 215 ms main-actor delay. Both defects were caught before shipping. Do not cite the earlier 24% CPU/22% memory reductions; those numbers were withdrawn.

At the capture point native baseline, corrected PDFPage cache, and native low-interpolation runs still showed blank page surfaces. Direct Core Graphics showed the correct current page, but the adjacent page was blank and CPU/memory were comparable to baseline; one capture does not establish reliability. In-process hierarchy capture is not a compositor completion timestamp. An initial window capture was entirely black and is not used as visual evidence; the harness now captures the attached root view and records visibility/foreground diagnostics.

Limitations: `go(to:)` is not a real finger fling. CPU is whole-process `getrusage`, RSS is sampled, and the 16 ms main-actor heartbeat includes scheduler contention. Native draw callbacks are not complete-page presentation timing. Filesystem/OS caches are not flushed. This does not establish blank-free arbitrary-speed scrolling or performance for all PDFs/iPads. First-time scan decoding and high zoom can still be expensive.

## Other changes

- Native PDF Find replaces custom search state; page progress writes coalesce and flush on exit/background.
- Reading Options offers continuous or page-by-page layout without changing the selected page.
- Reader cancellation respects cancelled interactive Back gestures and adaptive iPad reparenting.
- Audio releases its session after terminal playback/failure; replay and position restoration respect newer user intent and queued persistence.
- Artwork transfer bodies are bounded before decode, including missing/false Content-Length cases.
- File/recording lists have native local search; Save prevents overlapping operations; Library retains loaded content on refresh error; iPad destinations expose selection.
- Artwork loading uses a stable SwiftUI container, explicit request identity, cancellation checks, and retains a loaded cover during same-artifact resize/scale reloads. Four mounted tests pass. A negative control changing only the container back to `Group` also passed, so the initially hypothesized Group-driven task loop is **not confirmed**. A broader negative control was interrupted when Xcode stalled saving results on the nearly full Mac; it establishes no causal result. This is lifecycle hardening, not an explanation of the user's test-only PDF blanking.
- Download reconciliation rebases validated managed filenames into the current app container before checking existence. It recovers surviving relocated files, including previously missing records; rejects wrong hashes/extensions, traversal, symlinks and wrong sizes; and leaves ambiguous files untouched. The physical database contained missing PDF/audio records with two obsolete container roots while the current Media directory was empty. This corroborates the path bug but does not prove how those particular bytes disappeared. Already-deleted downloads require downloading again.

## Reproduce

```sh
xcodegen generate
xcodebuild -project Funston.xcodeproj -scheme FunstonPDFPerformance \
  -configuration Release -destination 'platform=iOS,id=00008120-001854922238201E' \
  -derivedDataPath /tmp/ArchiveDemuxDerived -allowProvisioningUpdates \
  ENABLE_TESTABILITY=YES PDF_PERFORMANCE_MODE=continuousCached test
```

Use `continuousVertical` for baseline, `pagedHorizontal` for native paging, or `continuousLowInterpolation` for PDFKit low interpolation. `continuousCached` runs the current test-only Core Graphics variant. The opt-in harness attaches JSON, capture diagnostics, and an image to the xcresult. The fixture is downloaded once, outside the measurement interval. Ordinary tests skip this network/device benchmark.

Primary API references: [PDF page subclass selection](https://developer.apple.com/documentation/pdfkit/pdfdocumentdelegate/classforpage()), [page drawing](https://developer.apple.com/documentation/pdfkit/pdfpage/draw(with:to:)), [native Find](https://developer.apple.com/documentation/pdfkit/pdfview/isfindinteractionenabled). Local Xcode 27 `PDFPage.h` documents that drawing does not clear the destination background.

## Acceptance limits

Final validated simulator unit run: 93 passed, 3 opt-in device benchmarks skipped, zero failures (21:23). Reader restoration/native Find UI test passed at 21:17 after clearing disposable build caches; its prior failure was explicitly “No space left on device,” not a reader assertion about rendering. Earlier four UI journeys passed (navigation/accessibility audit, large text, playback next/previous behavior, PDF restoration/Find). Manual VoiceOver acceptance is not claimed.

Release build 9 compiled, installed, and launched on the connected iPhone 14 Pro Max after restoring the exact validated production artwork logic. The custom PDF raster cache and performance hooks are test-target only. No additional phone benchmark was run after the user's clarification.

Focused tests cover page identity, background raster reuse, main-thread miss behavior, transparency, zoom/annotation fallback, text/search retention, LRU bounds, layout preservation, and progress persistence. UI tests exercise native Find and returning to the saved page. Automated accessibility checks supplement, but do not replace, manual VoiceOver testing of the actual catalog on the user's phone. Full nonvisual reading quality also depends on the source PDF's OCR and reading order.

## Next experiment for the unresolved lag

Use an on-device Instruments Time Profiler trace during real flicks and record visible-page presentation latency after stopping, not just completed draw callbacks. Distinguish source-image decode cost from stale queued PDFKit tile work. If stale work dominates, evaluate a cancellable, visible-page-prioritized rendering scheduler against PDFKit while explicitly retaining text extraction, selection, links, zoom, and nonvisual reading order. Do not substitute an image-only viewer merely to improve the benchmark. No timing threshold or complete VoiceOver acceptance is claimed yet.

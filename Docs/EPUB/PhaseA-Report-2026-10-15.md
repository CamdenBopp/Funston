# Funston EPUB reader, Phase A report

2026-10-15. Phase A of Docs/EPUB/Spec.md (section 22.1): the native reader replaces Readium. This report is the one the brief asked for: the commits, the test counts, the element-model experiment's outcome, the VoiceOver checklist item by item, and every open question added to the spec.

## Commits

Branch `claude/sad-darwin-0e6cc1` on github.com/CamdenBopp/Funston, built on the Phase A head `4d21abc` (steps 1 to 9; hashes as in the public history, which omits two test fixtures). The close-out range is `4d21abc..HEAD`; each commit names its axis (soundness, speed, correctness) and the test watched red and green. Oldest first:

<!-- commits -->
- `a8986bd` Remove Readium: the native reader is the only EPUB path
- `62de04e` Rename EPUBCFIResolver and EPUBStyleResolver off the studies' name denylist
- `bc1545c` Delete the surfaces the strips replaced
- `cdeaed9` Test the strips' VoiceOver contract: persistent elements, list start, focus, three-finger scroll
- `1628e2c` Continuous strip: a paragraph showing only a sliver is not where VoiceOver's list starts
- `0c79cbe` Continuous strip: a focused paragraph is the reading position
- `9985feb` Show the book's diagnostics: the Phase A problems screen
- `857fc78` Bound the work a book can demand: EPUBWorkLimits and the whole-book cap
- `5e63e4b` A chapter whose styled build runs past its budget renders as plain text
- `33f1d71` A chapter whose layout runs past its budget is laid out again as plain text
- `7237348` Build chapters without bridging the whole string for every character
- `d19494c` Build chapters within the budget: attributes once per run, a counted buffer, no per-character strings
- `c06d273` Strips follow VoiceOver's focus notification and let swipes lead back
- `1b3ca17` Right-to-left books: the continuous strip maps left and right through the progression
- `e486d3e` Lines rotor: line boundaries stop before a soft wrap's trailing space
- `d73d34f` Page progression defaults to right-to-left for a right-to-left language
- `b844abd` Images carried as data: URLs render inline
- `cdc4100` Open a book with one chapter laid out; the window's neighbours arrive off the main actor
- `6717875` Run the W3C epub-tests and the corpus as gated tests; commit the first conformance table
- `3a72b05` Spec section 24: the answers, decisions and questions Phase A left behind
- `8512140` Corpus run: every chapter renders with no lost text, every chapter start is named right
- `9b61806` Phase A report and the VoiceOver checklist filled in item by item
<!-- /commits -->

## Test counts

The full FunstonTests suite on the iPhone 17 Pro simulator (iOS 26.5, Xcode 27), run from this branch's head with the two EPUB gates set:

| Run | Tests | Result |
| --- | --- | --- |
| FunstonTests, whole suite | 434 test methods, 7 skipped behind their gates | 0 failures (run of 19:43, 108 s) |
| EPUB unit tests inside it | 21 suites, 178 test methods | all pass |
| EPUBConformanceTests (`IA_EPUB_CONFORMANCE=1`) | 206 W3C publications | pass (table below) |
| EPUBCorpusTests (`IA_EPUB_CORPUS=1`) | 14 files of the study's corpus | pass (135 s; 14 books, every chapter rendered with no lost text) |
| FunstonUITests.testReadingABornDigitalBook | 1 | pass (39.7 s) on a fresh install |

The seven skipped tests are the gated ones: the two EPUB runs above, the three live-media tests, the resumable-download live test and the PDF rendering comparison. Each gated run was made separately with its gate set as a `TEST_RUNNER_` environment variable of xcodebuild (passing it as a build setting leaves the test skipped, which cost one run here).

The UI test reads the saved reading position: on a simulator that already holds a position for Man and Maid from an earlier run it opens at that position and the "page 1 of" assertion fails. It passed after the app was removed from the simulator. Making the test reset its own position is listed under open questions.

Three download timing tests (ArchiveNetworkPolicyTests.testLongDownloadsLeaveCapacityForMetadataAndQueuedRemoval, DownloadPermitCancellationTests.testColdRecoveryNeverResumesQueuedPrivateFile and testColdRecoveryResumesQueuedPublicFileOnlyAfterValidation) failed under full-suite load in two earlier runs of the day with one-second expectation timeouts and passed alone; they passed in the final run. They predate this work and touch nothing in the reader.

## The element-model experiment (Spec 14.6, open question 1)

Both candidate models were built behind the `epub.a11yModel` switch and run on the simulator and on Camden's iPhone 14 Pro Max (Docs/EPUB/VoiceOver-2026-10-15.md). The Books model (one reading-content element per page) carried Read All across page turns on both; the per-block model as first built turned pages but lost its place at every turn on the device, because each page rebuilt its elements and VoiceOver fell back to the element under its old focus point. Camden chose the paragraph model. What ships is that model on persistent elements: the window's pages side by side in one paging strip (continuous mode: the chapters stacked in one vertical strip), every paragraph a text element that is never rebuilt while reading, the list starting at the shown page's first paragraph and reaching back once focus is inside, a three-finger scroll moving one page or screen. On the iPhone, three-finger swipes, Read All and paragraph swipes "work beautifully" (Camden). One assumption of the design did not hold: VoiceOver on iOS 26.5 never delivers `accessibilityElementDidBecomeFocused` to the paragraph views; the strips now follow `UIAccessibility.elementFocusedNotification` instead. The Books model stays behind the switch for the record.

## VoiceOver checklist, item by item (APL-37 plus STD section 7.4)

The full record, with what each run spoke, is the table and the run sections of Docs/EPUB/VoiceOver-2026-10-15.md. In short:

| # | Item | Simulator (iOS 26.5, driven step by step) | iPhone 14 Pro Max (Camden) |
| --- | --- | --- | --- |
| 1 | Touch exploration lands on real text | not driven (no touch in the driver); element frames equal the text bounds | pending |
| 2 | Swipes in reading order | yes, across pages | yes; also automated by EPUBVoiceOverDeviceTests |
| 3 | Lines rotor, within and across | yes after the tokenizer fix (real lines, flows into the next paragraph) | pending |
| 4 | Characters and Words rotors | yes | pending |
| 5 | Read All across pages and chapters | yes (pages 19 to 22, III to IV, three turns in 75 s) | yes |
| 6 | Three-finger swipe turns and announces | unit test only | yes; from the Reading page element only after the forwarding fix of 2026-10-15 21:47 |
| 7 | Focus after a manual turn | yes (page and block models); paragraph model by unit test | yes |
| 8 | Headings rotor and levels | rotor yes, both directions across pages; levels not spoken | pending |
| 9 | Links rotor; link and note actions | actions offered; performing them is not possible from the driver | pending |
| 10 | Images announce their alternatives | yes | pending |
| 11 | Lists and tables announce containers | no (Phase B) | no |
| 12 | Notes open in a sheet and return | not performable from the driver | pending |
| 13 | Languages switch voices | attribute level yes (corpus run) | pending, by ear |
| 14 | Adjustable page element | yes | yes, automated by EPUBVoiceOverDeviceTests |
| 15 | Focus order equals document order | yes | yes |
| 16 | No empty label | yes (text is the value; label empty by design) | yes |
| 17 | Container start and end | partly: one container between the bars; label on entry not captured | pending |
| 18 | Page labels skippable | no (Phase B) | no |
| 19 | Continuous mode crossing at a chapter end | Read All forward yes; the crossing not re-run since the lazy window | yes, before the lazy window |

The device items marked pending are the next run with Camden; their results go into the VoiceOver report as a new section. The run of 21:30 to 21:47 (VoiceOver report) added the device UI test, found and fixed the three-finger swipe from the Reading page element, and Camden called the result good enough to publish.

## Performance (Spec 20)

EPUBPerformanceTests, iPhone 17 Pro simulator on the M2 Pro host, XCTest clock metric over five iterations after warm-up (the budgets are for an iPhone-class device; the simulator run is allowed 1.2 times the parse-and-style budget):

| Measurement | Budget | Measured |
| --- | --- | --- |
| Open a twelve-chapter book to its package and navigation | 30 ms | 5.1 ms |
| Parse and style a 60 KB chapter | 50 ms | 48 ms (4.9 s before the builder fixes) |
| Lay out a 200 KB chapter | 300 ms | 86 ms |
| Draw one page at 3x | 8 ms | 0.95 ms |
| A VoiceOver line-frame query | 1 ms | 0.044 ms |
| Open a chapter to its first page, warm | 500 ms (cold 1 s) | 3.2 ms |

The builder was quadratic when first measured: it bridged the whole chapter string to Swift for every character. Three commits took the 60 KB chapter from 4.9 s to 48 ms (no bridging, then attributes computed once per run with a counted UTF-16 buffer, then a fast path for plain scalars). The device figures are still to be taken (open question 25).

The work limits of Spec 19.3 are in place and tested: a per-entry cap, a whole-book cap derived from the memory available to the process, a 2 s build budget and a 3 s layout budget, each falling back to plain text with a diagnostic the problems screen lists.

## Conformance and corpus

W3C epub-tests (Docs/EPUB/Conformance-2026-10-15.md, 206 publications): pass 72, degraded 74, n/a 54, fail 4. The four failures are explained in the table's header: `text-align-last` is not drawn (open question 24); the package language is inherited as the speech language on purpose (two rows; Spec 23); SVG content renders as its description in Phase A (Spec 23).

Corpus (Docs/EPUB/Corpus-2026-10-15.md, the 14 files of the standards study): all 14 open, with the contents source and cover rule the study predicts; 453 readable spine items render with no lost text; a position saved in the middle of each book restores to the exact offset at a larger text size by the offset path and by the CFI path; the first pages of the first chapter files carry the expected entry (Man and Maid: none for the Gutenberg header page, then "IV"); runs carrying a VoiceOver speech language are counted per book (Elektra 18, Relativity 36, Moby Dick 65); the suspicious-contents guard moves page breaks only in the Gutenberg licence chapters and the Factbook's two closing files, so it stays off (open question 5 answered).

## Open questions added to the spec (section 24)

Answered while implementing: 1 (the element model, above), 3 (synthetic contents thresholds refined), 4 (Core Text decodes WOFF and WOFF2), 5 (the suspicious-contents guard moves page breaks in the Gutenberg licence chapters, so it stays off), 13 (Readium removed).

Added as 24.3:

14. `word-spacing` has no attributed-string expression; accepted, not applied.
15. Whether a collapsed space between runs takes the link context of the DOM node it came from or of the following text.
16. Block backgrounds and borders are not drawn in Phase A.
17. Whether a full edit-distance search is ever needed for approximate text anchoring.
18. The reading layout setting is still the PDF reader's `pdf.readingLayout` key; whether EPUB gets its own is Camden's call.
19. Right-to-left books are reversed in both strips by unit test only; none has been read under VoiceOver.
20. List and table containers and skippable page-break markers are not exposed (checklist items 11 and 18).
21. The Lines rotor stepped 45-character chunks on the simulator; closed by the tokenizer fix in this range (the mechanism is recorded in 24.2).
22. `accessibilityElementDidBecomeFocused` is never delivered to the UITextInput paragraph views on iOS 26.5; the strips use the focus notification.
23. Heading levels are not spoken for the paragraph elements.
24. `text-align-last` is accepted but not applied.
25. The performance budgets are measured on the simulator only; the device figures are the ones that count.

Also open, recorded in the VoiceOver report's open points rather than the spec: the first-page chapter label (the simulator once showed "III, page 1 of 48" on Man and Maid, which the corpus assertion on every chapter start does not reproduce), a deep restore in continuous mode under VoiceOver, and the UI test's dependence on a fresh install.

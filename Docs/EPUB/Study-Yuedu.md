# Study: Yuedu's native Core Text EPUB pipeline

Written 2026-10-14 for the clean-room EPUB reader spec. Requirement IDs use the prefix YUE. The twelve H2 headings below are fixed so the eight candidate studies merge cleanly.

## Provenance

Repository: https://github.com/CHANG-JUI-LIN/Yuedu-reader
Commit read: b24d525b966d3ea3a7d650c884cd12e4c19153c0, committed 2026-10-07T16:52:11Z.
License: Mozilla Public License 2.0 (root LICENSE file). The project's own licensing note says every revision up to and including commit 87ffc527f5a9d1057591f448d402d07993af920f was MIT and later revisions are MPL-2.0; the app's name, icon and branding are excluded from the license. Nothing here relies on the MIT history; everything was read at the MPL commit and is treated as MPL.

The layout engine is split across the app and a second repository the app pins as a Swift package:

Repository: https://github.com/CHANG-JUI-LIN/YueduCoreText
Version pinned by the app: 0.8.0, commit 783ce903d5faf4ff5d15c546e32a107537ba5efe, committed 2026-10-07T16:48:38Z.
License: Mozilla Public License 2.0, with a NOTICE for Unicode Character Database data under the Unicode License v3.

Both were cloned shallow into a fresh directory under this session's scratchpad, outside the Funston worktree. Nothing was built or run; no script or interpreter was run from inside either clone. No file from either repository was copied into the worktree. Four read-only survey agents read peripheral areas (container and navigation, read-aloud, the package's layout engine, images and failure paths); their reports were re-expressed before anything entered this document, and the claims the requirements lean on were re-checked against the source lines they cited.

Third-party components on the EPUB path, from the app's resolved package list:

| Component | Version | License | Role on the EPUB path |
| --- | --- | --- | --- |
| Readium swift-toolkit (Shared, Streamer) | 3.8.0 | BSD-3 | Opens the archive, parses container, package document and navigation; serves resources |
| ReadiumFuzi | 4.0.0 | BSD-3 | XML and XPath used by Readium |
| ReadiumZIPFoundation | 3.0.1 | MIT | Zip access used by Readium |
| SwiftSoup | 2.13.7 | MIT | HTML parsing of chapter XHTML for the legacy engine |
| iosMath | 2.3.1 | MIT | Rasterises MathML converted to LaTeX |
| Lexbor (vendored C package) | repository copy | per its NOTICE | Present in the repository; the EPUB pipeline at this commit does not call it (one comment anticipates a future adapter) |

Claims checked against code:

- The README says the app renders "with CoreText, no WebView". Verified for text: every page is drawn with Core Text into a Core Graphics context. Not true for SVG: inline SVG and SVG image files are rasterised by offscreen WKWebViews, and fixed-layout pages are shown in a web view. MathML goes through iosMath. Online web-novel sources also fetch with WKWebView; that is outside this study.
- The README says iOS 18.0+ with Swift 6.0 and Xcode 16; the repository's orientation file for coding agents says iOS 17.0+. The deployment target in the project file was not inspected, so the minimum is unverified.
- The documentation describes two rendering paths. Verified: a legacy engine builds one attributed string per chapter and paginates it with Core Text framesetting; a newer engine in the YueduCoreText package computes CSS, builds a box tree and fragments it into pages. A compile-time setting selects per-chapter "automatic" admission: the newer engine is tried first and a chapter that it cannot render, or that fails or times out, goes to the legacy engine. Both are studied because both ship, and the fallback decides which one a given Gutenberg chapter actually gets.
- The orientation file claims blind users and lists VoiceOver rules for the SwiftUI chrome. Verified: the reading surface itself is one accessibility element per page. Section 7 covers what that means.
- The documentation says reading position is a spine index plus character offset and never a page index. Verified in the position type, the page data source and the persistence store; the project's own incident notes record the bugs that preceded that rule.

Scope: reflowable EPUB in paged mode (both engines), continuous scroll where it differs, read-aloud, annotations and bookmarks, accessibility, persistence and failure behaviour. Not studied beyond detection: fixed-layout EPUB, comics, TXT, online sources, RSS, AI features, cloud sync internals.

## What it is and why it matters to Funston

Yuedu is a shipping App Store reader, Chinese-first, that paginates EPUB with Apple's text engine instead of a web view. It is the one candidate doing what Funston intends to do, and it carries two generations of that attempt in one codebase. That is its main value: the second engine exists because of limits the first one hit, and the limits are written down in the code's comments, its tests and its incident notes.

The first engine turns a chapter's XHTML into a single attributed string and asks a framesetter for one page frame after another. It is quick to build and simple to reason about, and it is what a TextKit 2 attributed-string renderer in Funston would most resemble. Its ceiling is structural. An attributed string is one flat sequence of paragraphs, so nested block margins have to be folded into paragraph indents by hand, vertical margins on the first paragraph are ignored by the layout system, floats are faked by cutting a notch out of the page path, tables are rasterised to bitmaps, superscripts lose their raise, and `pre` and definition lists have no block identity at all. Each of those is an ordinary Gutenberg case.

The second engine computes CSS on a parsed tree, builds a box tree, lays out lines with Core Text and blocks with its own code, then fragments into pages with break rules. It is what a reader that honours publisher CSS needs. It also costs more: the package is about 21,000 lines, and the app still wraps it with per-chapter admission and a fallback to the first engine.

Three findings change how Funston should build:

1. The reading position is a spine index plus a UTF-16 offset into the chapter's rendered text, never a page number. Pages are derived from positions; neighbours are found by walking positions; a chapter that is only partly laid out hands out "first unmeasured character" as a destination; a relayout re-resolves the page from the saved position. Funston's Readium locator is richer (CFI, progression), but the candidate shows that the minimum robust identity is small, that every page-number shortcut it tried became a bug, and how to keep page numbers purely for display.
2. Decide the layout model before writing the renderer. A flat attributed string inherits the first engine's limits on day one and will need the same list of workarounds; honouring publisher CSS needs a box-model stage in front of the text engine, which is a different project. The candidate's fallback architecture is the hedge it chose after shipping the first engine.
3. Accessibility is the gap, not the model. One static-text element per page, labelled with the whole page's text and carrying page-turn actions, keeps a VoiceOver user from being stranded and does no more. There is no per-paragraph or per-line element, no link or image element, no selection through VoiceOver on the legacy engine, no heading trait, no language per run, and no Dynamic Type. Funston's PDF reader already exposes recognised lines as elements with live frames; the EPUB renderer has every input it needs to do the same, because the candidate already computes per-line geometry from the page frame for selection and highlights.

## Architecture in our words

This section uses the candidate's internal names as orientation only. Requirements and algorithms use spec and Apple vocabulary.

Opening a book. A `PublicationSession` wraps a Readium publication. It opens the archive through Readium's streamer, reads the container document itself with Foundation's XML parser, reads the package document's text and scans it with regular expressions for language, writing mode, rendition properties, page progression direction, viewports and the unique identifier (so the package is parsed twice: once by Readium, once by the candidate), flattens Readium's table of contents into entries with href, title and depth, and exposes Readium's reading order, filtered to HTML items, as an ordered list of "chapters" with href and title. Chapter XHTML and resources are read on demand through a resource adapter that turns a publication-relative path into an app-scheme URL and reads bytes from Readium, de-obfuscating fonts itself. Survey agent A's findings on this layer are in sections 4, 6 and 8.

Building a chapter (legacy engine). `EPUBAttributedStringBuilder` fetches the chapter XHTML, parses it with SwiftSoup's HTML5 parser (after lifting large data: URI payloads out so the parser does not stall), collects `style` elements and `link rel=stylesheet` hrefs in document order, loads and preprocesses each stylesheet through `EPUBStyleResolver` (local `@import` inlined with cycle detection, `@font-face` blocks extracted into a pending registry and removed, `url()` values rewritten to resource URLs), and parses the CSS with the package's `CSSParser` into rules with specificity and order; one parsed copy per stylesheet text is shared by every chapter of the book. `HTMLBuilderStyleResolver` walks the DOM producing a styled AST (`ElementNode` with a `ResolvedStyle`, plus a parallel dark-mode style when the book has `prefers-color-scheme: dark` rules). `HTMLStyledASTRenderableNodeConverter` turns that into a small IR (`RenderableNode`: paragraph, heading, block, list item, inline, anchor, ruby, image, table, media, page break and so on), and `NodeAttributedStringRenderer` turns the IR into one `NSAttributedString` carrying standard attributes plus about twenty private keys (link href, anchor id, forced page break, block decoration style and id, spacer run, float placeholder, inline border chip, pronunciation hint). Fonts referenced by the chapter are registered just before rendering. The result is a `ChapterDocument` (string, optional image page, optional page background, anchor-id to offset map, content revision), held by `ChapterDocumentStore`, an eight-entry LRU keyed by spine index plus every render setting.

Paginating (legacy engine). `CoreTextPaginator` takes the chapter string, page size, insets and typography settings, prepares the string (vertical writing only), creates one `CTFramesetter`, and slices page ranges by repeatedly creating a frame for the remaining range in the content rectangle and taking its visible range; forced breaks, keep-together ranges, CJK boundary protection and float notches adjust each cut. After the ranges are fixed it creates one `CTFrame` plus line origins per page and extracts, from those frames, the rectangles of inline images, block images, inline annotations, block decorations and upright cells. The output is a `ChapterLayout`, cached by a key that includes every layout-affecting input and a content revision.

The engine. `CoreTextPageEngine` owns a five-entry distance-LRU of chapter layouts, per-chapter preload tasks guarded by a generation counter, a device-tiered `NSCache` of page snapshot bitmaps, per-chapter byte sizes for estimating total pages, and the mapping between (spine, offset) and a display-only global page index. It hands out `UIViewController`s for pages and placeholders and implements position walking. `EPUBPageRenderer` sits above it and translates reader settings into engine invalidations and "refresh transactions".

Hosting. `CoreTextPagedView` wraps a `UIPageViewController` whose data source asks the engine for the page before or after the visible page's position, never by index; a write gate serialises changes to the page stack so UIKit's own transitions are never interrupted. `CoreTextPageViewController` hosts one `CoreTextPageView`, which draws the page in `draw(_:)` (or displays a prerendered bitmap), owns gesture recognisers for tap, long press and handle drag, the edit menu, overlays for selection, annotations, note markers and read-aloud highlight, and the accessibility contract. Continuous scroll slices the chapter string into roughly 2000-point chunks shown in a `UICollectionView`, with the same selection and annotation code and a one-element-per-chunk accessibility contract.

The browser engine. `BrowserLayoutPageEngine` (app) feeds chapter XHTML and stylesheets to the package's `HTMLLayoutDocument`, which computes styles, builds a box tree, lays out inline content with Core Text typesetting and blocks with its own layout, fragments into pages and emits a display list per page. `BrowserLayoutPageView` paints a display list with Core Graphics and offers link hit-testing, a text interaction controller for selection, a highlight overlay and the same accessibility contract. A capability scanner decides per chapter whether this engine is admitted; the named fallback reasons are unsupported SVG, an unsupported layout property, an image-only document, no renderable content, a resource failure, a layout failure, a 5-second timeout, and an active whole-chapter translation. A rejected chapter goes to the legacy engine. Survey agent C's findings are in sections 4 and 5.

Read-aloud, annotations, position. `TTSCoordinator` and `SystemTTSEngine` drive `AVSpeechSynthesizer` over text split by `TTSTextChunker`; the spoken segment is highlighted by searching its text within the visible page's range, disambiguated by an expected chapter offset. Bookmarks, underlines and highlights are one `Bookmark` list per book with a (spine, offset, length) range. The reading position is a `(spineIndex, charOffset)` pair written as JSON per book, debounced, and flushed when the reader closes.

Source map for the parent session's verification:

| File | Responsibility |
| --- | --- |
| Modules/Core/EPUB/PublicationSession.swift | Readium wrapper: container, package scan, navigation, resources, de-obfuscation |
| Modules/Core/EPUB/EPUBPackageResources.swift, EPUBCFIResolver.swift, EPUBMediaOverlay.swift, PLSLexicon.swift | Container document, CFI parsing, SMIL parsing, pronunciation lexicons |
| Modules/Core/ReaderCore/CoreText/EPUBAttributedStringBuilder.swift | Per-chapter build: fetch, parse, fonts, render |
| Modules/Core/ReaderCore/CoreText/HTMLBuilderPipelines.swift | DOM parse, stylesheet collection, CSS parse cache, dark-rule split |
| Modules/Core/ReaderCore/CoreText/HTMLAttributedStringBuilder.swift | Cascade, user-agent defaults, length and colour parsing, styled AST |
| Modules/Core/ReaderCore/CoreText/CSSPropertyApplier.swift | Property handlers and direction resolution |
| Modules/Core/ReaderCore/CoreText/HTMLStyledASTRenderableNodeConverter.swift | Whitespace policy, element to IR mapping, ruby pairing |
| Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift | IR to attributed string: paragraph styles, fonts, images, tables, lists |
| Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift | Page slicing, page artifacts, attachment and decoration extraction, theme recolour |
| Modules/Core/ReaderCore/CoreText/CoreTextPageEngine.swift | Chapter cache, preload, page offsets, estimates, snapshots, link resolution, fonts registration |
| Modules/Core/ReaderCore/CoreText/CoreTextReadingPosition.swift | Position type and position walking |
| Modules/Core/ReaderCore/CoreText/CoreTextPageView.swift | Drawing, gestures, selection, edit menu, overlays, accessibility |
| Modules/Core/ReaderCore/CoreText/CoreTextHorizontal/CoreTextHorizontalLineDrawer.swift | Line-by-line drawing, justification, bottom distribution, chips, rules |
| Modules/Core/ReaderCore/CoreText/CoreTextAnnotation*.swift, TextSelectionInteractor.swift, FootnoteStore.swift | Annotation model, merge rules, rect computation, selection state, footnotes |
| Modules/Core/ReaderCore/ReadingPositionStore.swift, ReaderNavigator.swift, EPUBProgress.swift | Position persistence, debounce, progress |
| Modules/Core/ReaderCore/BrowserLayout/*.swift | Browser engine host, admission, display-list painting, text interaction |
| Modules/Core/TTS/*.swift, Modules/Core/ReaderCore/CoreText/ReaderPlaybackHighlight.swift | Read-aloud and its highlight |
| Modules/Features/Reader/CoreTextPagedView.swift, ReaderView+SourceChange.swift | Page controller host, TTS coupling |
| YueduCoreText/Sources/YueduCoreText/Engine/*.swift | CSS frontend, computed style, box tree, inline and block layout, fragmentation, display list |
| YueduCoreText/Sources/YueduCoreTextTypography/*.swift | CJK typography, vertical orientation, hyphenation tagging, glyph boundaries |

## Requirements

Each requirement states what a Funston renderer shall do, why, the public spec reference when one exists, edge cases, and how to test it. "Verified" means read in the candidate's code at the commit above; "claimed" means stated in its documentation and not confirmed in code. Where the candidate deviates from a specification the deviation is named and judged. Section numbers are given where I am sure of them; otherwise the section is named.

### Position identity and navigation

#### YUE-01 Reading position is a spine index plus a UTF-16 offset

The reader shall identify a reading position as the pair (index of the spine item in reading order, UTF-16 offset into that spine item's rendered text), and shall never persist or compare a page number as identity.

Why: pages renumber whenever font size, margins, rotation, a late-loading chapter or a partial layout changes; the candidate's incident notes record four distinct bugs (double page turns, stuck placeholders, jumps into the next chapter) that all traced back to a page index stored across a relayout. Verified in the position type, the data-source walkers and the persistence store.

Spec: EPUB 3.3 §5, the spine as the default reading order. The offset is into rendered text, not into the XHTML source; see YUE-05 for anchors and YUE-52 for CFI.

Edge cases: the offset counts UTF-16 units of the rendered string, so an emoji is two units and an attachment placeholder (object replacement character) is one; the chapter end is a sentinel offset (the maximum integer) that resolves against the chapter's layout when it exists; a position inside spliced translation text carries a second optional offset, which Funston does not need.

Test: save a position mid-chapter, change font size by two steps, rotate, reopen; the first visible character must be the saved offset. Walk forward to the next chapter and back; the position must land on the previous chapter's last page without that chapter's layout being requested first.

#### YUE-02 Neighbour pages are derived from positions, not indices

The page controller's data source shall compute the page after or before a given page from that page's position and the chapter's page ranges, and shall return "no page" rather than guess when the neighbour's chapter has no layout, or the current chapter is only partly laid out and the requested direction is unmeasured.

Why: UIKit asks the data source speculatively for pages the user may never visit; answering with an index that a background layout later renumbers produced visible one-page skips. Verified in the walkers and the project's paging note.

Edge cases: within a chapter the next page is the start offset of the next page range; at the chapter's last page it is the start of the next spine item (offset 0), which needs no layout of that chapter; the previous page across a chapter boundary is the sentinel end of the previous chapter; for a partial layout the next page after the last measured page is the first unmeasured offset, and only when that offset is strictly ahead of the current one (handing back the same offset made the walker a fixed point, logged as 26 of 26 "next equals start" reports in one device session).

Test: with a chapter that paginates to N pages, assert next(page k) is the start of range k+1 for all k, next(last) is (spine+1, 0), previous(first) is (spine-1, end sentinel). With a partial layout covering one page, assert next(page 0) is the first unmeasured offset and next(that offset) is nil.

#### YUE-03 A global page number is display-only and recomputed on every layout install

The reader shall keep a global page counter for the footer and progress slider that sums, per spine item in order, the real page count when laid out and otherwise an estimate; shall recompute it on every layout install; shall re-derive the current page from the current position; and shall never use it to decide content identity.

Why: readers expect "12 of 300" and a scrubber; the candidate shows the estimate drifting as chapters lay out, which is acceptable for display and fatal for identity. Verified in the offset rebuild.

Edge cases: a spine item with neither layout nor byte size counts as one page; estimates scale with font size (YUE-34); a background-image-only chapter with no text still owns one page so its page base does not alias the next chapter.

Test: open a book, note the footer total, let the next chapters lay out; the total may change but the current page's first character must not.

#### YUE-04 Relayout preserves the reader's place

On any change that affects layout (font size, line height, letter spacing, paragraph spacing, margins, page size, writing mode, arrival of an embedded font), the reader shall capture the current position, discard cached layouts and snapshots, re-lay out the chapters that were in memory plus the visible one, then resolve and show the page containing the captured position.

Why: this is the operation every Dynamic Type or rotation change triggers. Verified in the invalidation routine, which bumps a generation counter so stale preload tasks abandon their results, re-paginates in a task group, and discards its own result if a newer invalidation started.

Edge cases: overlapping invalidations (rotation during a font change) must let the newest win; the captured position is in memory, never re-read from disk; theme changes do not invalidate layout at all (YUE-39).

Test: rotate twice during a font-size change and assert the final page contains the pre-change position.

#### YUE-05 Internal links resolve to a position through anchor offsets

The reader shall record, for every element with an id, the UTF-16 offset of its first rendered character; an internal link shall split into path and fragment, resolve the path relative to the current spine item's href to a spine index, ensure that chapter is laid out, then use the fragment's recorded offset as the target position; a fragment that is unknown shall be reported, not silently mapped to the chapter start.

Why: TOC pages inside the book, cross references and footnotes all depend on it. Verified in the link resolver and the anchor-id attribute. Verified deviation: the candidate maps an unknown fragment to offset 0 silently in both engines and, in the legacy engine, matches paths by exact, suffix-either-way and percent-decoded comparison (the browser engine matches exactly with percent variants only), so the two engines disagree on fuzzy links.

Spec: EPUB 3.3 §5 (publication resources, relative URLs), HTML fragment identifiers.

Edge cases: an element that renders no text gets no offset; an href with the `kindle:` scheme is ignored; http and https hrefs open externally; mailto and other schemes fall through to the internal resolver and fail quietly in the candidate (Funston shall hand them to the system); a path that matches no spine item is logged and the tap does nothing; the fragment lookup is keyed by raw id, so percent-encoded fragments are not decoded.

Test: a chapter with `<p id="x">` on page three; a link `#x` from page one lands on page three; a link to a missing fragment is flagged; a link to a non-spine resource does nothing and logs; `mailto:` opens Mail.

#### YUE-06 Right-to-left page progression flips the page controller, not the content

When the package document declares right-to-left page progression (or the book is vertical), the reader shall put the page controller's spine on the opposite side, force right-to-left semantic layout on its scroll view, and invert the meaning of accessibility scroll directions, while laying out each page's content by its own CSS direction.

Spec: EPUB 3.3 §5, the spine element's page-progression-direction attribute. Verified in the paged host and the accessibility scroll handler.

Edge cases: a left-to-right book with Hebrew or Arabic text keeps left-to-right page progression but right-to-left paragraphs (YUE-23).

Test: a two-chapter book with `page-progression-direction="rtl"`: a leftward swipe goes back; VoiceOver's three-finger left swipe goes back; a bidi paragraph still right-aligns.

### XHTML and CSS to attributed text

#### YUE-07 Parse chapter XHTML with a lenient HTML parser

The reader shall parse spine item content with an HTML5-style parser that repairs malformed markup rather than an XML parser that rejects it, shall drop `script`, `style` (after harvesting its text) and `noscript` subtrees, and shall tolerate very large inline data URIs without slowdown.

Why: real EPUBs ship unbalanced tags, entities XML rejects, and multi-hundred-kilobyte base64 SVGs. Verified: the candidate uses SwiftSoup's HTML parser and lifts data: payloads out before parsing (restoring them afterwards) because the parser stalled on about 275 KB of inline base64.

Spec: EPUB 3.3 §6 requires XHTML content documents; this is a deliberate deviation worth keeping. The cost is that a document which is valid XHTML but uses XML-only features (CDATA sections, processing instructions, namespaced elements such as `epub:switch`) is parsed by HTML rules.

Edge cases: a parse failure yields an empty chapter (zero-length string, no image page), which the engine names as a distinct outcome and the user sees as a blank page, not a crash; entities are decoded by the parser; `epub:type` survives as an ordinary attribute but the legacy path reads it nowhere; recursion has no depth limit (YUE-85).

Test: feed an unclosed `<p>` chain, a stray `</div>`, an `&nbsp;` and an undefined entity; assert text content and paragraph count match a browser's.

#### YUE-08 Collect and order stylesheets as the document does

The reader shall gather author CSS from `style` elements in `head` first and then `link rel="stylesheet"` hrefs, in document order, resolve link hrefs relative to the chapter, inline local `@import` rules recursively with cycle detection and reject remote imports, extract `@font-face` blocks into a font registry and remove them from the sheet, rewrite relative `url()` values to absolute resource references, and assign each stylesheet an order offset so later sheets win ties.

Verified: order offset 10,000 per stylesheet; cyclic and remote imports are recorded as diagnostics and removed; processed sheets and parsed rules are cached per book; a `link` element's `media` attribute is not checked, so print stylesheets apply.

Spec: CSS Cascade Level 4 §6 (order of appearance), CSS Syntax Level 3 (@import placement; the candidate inlines wherever it appears, which is harmless).

Edge cases: a stylesheet that fails to load is skipped; `@media` blocks other than the dark-scheme query pass to the CSS parser (YUE-10 and YUE-73).

Test: two sheets setting `p { color }` differently; the later wins. A sheet importing itself terminates. A `@font-face` family referenced by no element is never read from the archive.

#### YUE-09 Cascade order: user agent, presentational hints, author, inline, important

For each element the reader shall start from inherited values, apply built-in per-tag defaults, apply the HTML `dir` attribute, apply presentational width and height attributes, then matched author rules sorted by specificity then order, then the inline `style` attribute's normal declarations, then matched rules' `!important` declarations, then inline `!important`.

Verified in the per-element resolver. Spec: CSS Cascade Level 4 §6 (origin and importance, specificity, order of appearance).

Edge cases: logical properties (`margin-inline-start` and friends) are mapped to physical ones for horizontal text before application; a rule's declarations are a dictionary, so two declarations of the same property in one block keep the later and lose the "first valid wins when the later is invalid" rule.

Test: `p { color: red !important }` with `style="color: blue"` renders red; `.a .b` beats `.b`; two equal-specificity rules take the later.

#### YUE-10 Honour the dark colour-scheme media query as a parallel palette

The reader shall parse rules inside `@media (prefers-color-scheme: dark)` separately, resolve a second per-element style against the parent's dark style, keep the dark colours on the attributed string as separate attributes, and swap them in when the reader appearance is dark without rebuilding or re-paginating.

Why: born-digital EPUBs increasingly ship dark palettes; applying them at paint time keeps appearance changes instant. Verified: dark rules are split once per document; foreground, block fill and border colours have light and dark variants; the body background has a dark variant.

Spec: Media Queries Level 5, the prefers-color-scheme feature.

Edge cases: a dark rule that changes anything other than colour (font size, margins) is resolved but only colours are read out, so a layout-affecting dark rule is dropped; absent dark rules keep the authored light colour in dark mode, matching the cascade.

Test: `body { color: #333 } @media (prefers-color-scheme: dark) { body { color: #ccc } }`: light paints #333, dark paints #ccc, a paragraph with no CSS colour paints the theme colour in both.

#### YUE-11 Supported properties and their mapping

The reader shall map at least the following properties onto text attributes and paragraph geometry. This is the legacy cascade's verified set; the browser engine's larger set is in YUE-73.

| Property | Values understood | Becomes |
| --- | --- | --- |
| font-size | px, pt (same as px), em, rem, %, unitless, smaller, larger (±20%), calc with one operator | font point size |
| font-family | comma list, quotes stripped | ordered family list for the font resolver |
| font-weight | number; bold, bolder → 700; normal, lighter → 400; other keywords keep inherited | weight; bold at 600 and above |
| font-style | any value containing "italic" | italic (oblique not recognised) |
| color | #rgb, #rrggbb, rgb(), rgba() with numbers or percents; named: red, white, black, gray, grey, blue, transparent | foreground, marked as author-specified |
| background-color, background (embedded colour) | same colours | block fill or inline fill |
| background-image, background-size (cover, contain, %, lengths), background-repeat | url() | block decoration image |
| line-height | unitless × font size, or a length | fixed line box height (minimum = maximum) |
| text-align | left, center, right, end, justify; start and others → natural | alignment; natural becomes justified by default (YUE-21) |
| text-indent | lengths, % of content width | first-line head indent added to margins |
| margin and sides | lengths, %, auto (left and right auto centres a fixed-width block) | top → spacing before; bottom → spacing after; left and right → indents, clamped at 0 |
| padding and sides | lengths, % | added to indents and to spacing before and after; drawn as part of a decoration box |
| border, border sides, border-width, border-color (first token), border-style, border-radius (largest corner) | widths, colours including currentColor, solid, dashed, dotted, none, hidden | block decoration box or inline chip; `none` recorded so a borderless `hr` is invisible |
| width, height | lengths, %, auto | block or image box size; raw percentage kept for images and rules |
| max-inline-size | length | tail indent limiting line length (page height in vertical writing) |
| display | none → drop subtree; block, list-item, table, flex, grid → block; everything else inline | block or inline treatment |
| float | left, right, none | image float with wrap (YUE-18) or chat-bubble block |
| letter-spacing | normal, length | kern |
| direction | rtl, ltr, auto, inherit, initial, unset | base writing direction |
| writing-mode and prefixed forms | vertical-rl, vertical-lr | vertical layout for the chapter |
| text-combine-upright and prefixed forms | all, digits, none | upright cells in vertical text |
| list-style-type, list-style | none suppresses markers | list marker |
| opacity | 0 to 1 | image opacity only |
| page-break-before, page-break-after, break-before, break-after | always, page, left, right, recto, verso | forced page break (YUE-25) |
| page-break-inside, break-inside | avoid, avoid-page | keep-together range (YUE-26) |
| vertical-align | super, sub, top, middle, bottom, text-top, text-bottom | recorded, then dropped before rendering (see edge cases) |

Not understood by the legacy cascade (verified absent): the `font` shorthand; text-decoration from CSS (underline and strike-through come only from the `u`, `ins`, `s`, `strike`, `del` tags); text-transform; font-variant; word-spacing; white-space; hyphens; orphans; widows; max-width; min-width; max-height; visibility; position; overflow; columns; generated content and counters; text-shadow; box-shadow.

Edge cases that matter for Gutenberg: `sup` and `sub` get 0.75em from the built-in defaults but their raise or lowering is lost because the vertical alignment never reaches the render style, so footnote markers sit on the baseline; `font: italic 1em serif` is ignored entirely; `text-decoration: underline` in CSS does nothing; `max-width: 100%` on images is ignored but images are clamped to the column anyway (YUE-16).

Spec: CSS 2.1 and the relevant Level 3 and 4 modules per property; EPUB 3.3 §6 (the CSS profile is the open web platform's).

Test: one fixture paragraph per row above, compared against a reference rendering by eye and by attribute inspection.

#### YUE-12 Built-in defaults per element

The reader shall supply user-agent defaults at least for: body (block); div, section, article, main, header, footer, nav, aside, figure, address (block, inherit line height); figcaption and caption (block, centred, 0.9em); table, thead, tbody, tfoot, tr (block, zero indent) and th, td (inline, zero indent); p (block, the reader's paragraph spacing as default margin); blockquote (block, margin-left 2em); h1 to h6 (block, bold, 2em, 1.5em, 1.17em, 1em, 1em, 1em, zero indent); ul and ol (block, margin-left 1.5em); li (block, zero indent); hr (block, 1px top border in currentColor); img, image, svg (inline-block); b, strong (700); i, em, cite (italic); sup, sub (0.75em); mark (pale yellow fill); u, ins (underline); s, strike, del (line-through).

Verified. Deviations from the HTML standard's rendering section to note: `pre`, `code`, `kbd`, `samp`, `tt`, `var` have no default, so `pre` is inline and its newlines collapse; `dl`, `dt`, `dd` have no default, so definition lists run together inline; `center`, `small`, `big` have no default; `q` adds no quotes; `address` is not italic. For Gutenberg, `pre` poetry and `dl` glossaries are common, so Funston's defaults shall add: pre (block, preserve whitespace, monospace), code, kbd, samp, tt (monospace), dl, dt, dd (block; dd margin-left 40px), center (block, centred), small (0.83em).

Spec: HTML living standard §15.3 (the rendering section's default style sheet).

Test: a chapter using every tag above with no CSS; compare block boundaries and font changes to a browser.

#### YUE-13 Whitespace collapsing and block boundaries

The reader shall collapse runs of space, tab, carriage return, line feed and form feed to one space; shall keep U+00A0 as a non-collapsing, non-breaking space (the candidate collapses it, a deviation); shall drop whitespace-only text nodes adjacent to a block boundary (a block sibling, a line break, a page break, or the edge of a block parent); shall trim a leading space after a block boundary and a trailing space before one; shall keep spaces between inline siblings and keep U+3000 ideographic space verbatim; shall emit U+2028 for `br` and a paragraph separator for a `br` promoted to display:block; shall terminate every block with exactly one paragraph separator and insert one before a block child that follows unterminated inline content; and shall preserve whitespace inside `white-space: pre` and `pre-wrap` (not modelled by the candidate's legacy engine; its browser engine has tests for both).

Verified in the IR converter and the block renderer. Spec: CSS Text Level 3 §4.1 (white space processing rules).

Edge cases: a whitespace-only node between two inline elements becomes one space; an empty block emits nothing unless it has its own height, fill or border; a chapter whose body is only whitespace produces an empty string and is reported as an empty document; soft hyphen (U+00AD) and zero-width characters pass through untouched.

Test: hard-wrapped `<p>` source with leading indentation renders as one flowing paragraph; `a<b> b</b>` keeps the space; `<p>x</p> <p>y</p>` has no blank line between; `<pre>` with internal newlines keeps them (Funston addition).

#### YUE-14 Headings

The reader shall render h1 through h6 as blocks with bold weight and a size scale, keep the author's alignment, and shall not treat any heading level as "the chapter title" to be resized, spaced or hidden by a reader setting.

Verified: the IR renderer scales headings 2.0, 1.5, 1.25, 1.1, 1.0, 0.9 times the body size and forces weight 700, overriding the built-in 2em, 1.5em, 1.17em defaults from YUE-12. Verified deviation to avoid: every level-one heading is treated as the chapter title: its size is replaced by the reader's chapter-title setting, its top spacing by a spacer line, and it is removed entirely when the reader's "show title" setting is off. For a Gutenberg book whose h1 is the book title or a part title that hides or resizes the author's heading.

Spec: HTML living standard §15.3 (sections and headings).

Test: an h1 and an h2 in a chapter render at their CSS or default sizes; toggling any reader setting never removes them.

#### YUE-15 Lists

The reader shall render `li` as a block whose marker is computed from its parent: an ordinal with a trailing period for `ol` (counting preceding `li` siblings), a bullet for anything else; shall suppress the marker when the inherited `list-style-type` is `none` or the `list-style` shorthand contains `none`; shall separate marker and content with a thin space; shall indent nested lists by accumulating the list's left margin into the children's indents; and shall honour `ol` `start`, `value`, `reversed` and `type` (the candidate ignores all four, so every ordered list is decimal from 1).

Verified. Spec: CSS Lists Level 3 (markers and list-style-type), HTML living standard §4.4 (ol attributes) and §15.3 (list rendering).

Edge cases: an `li` whose children are blocks (`<li><p>`) splices the marker into the first paragraph instead of adding a marker paragraph; markers are plain text in the flow, so selection and read-aloud include them.

Test: an `ol start="3"` shows 3., 4.; a `ul` inside an `ol` indents further; `ol { list-style-type: none }` shows no markers; `type="i"` shows roman numerals.

#### YUE-16 Images: sizing, placement and alt text

The reader shall load an image referenced by `img src`, `image href` or `xlink:href` relative to the chapter, place it as a run delegate attachment whose width is the drawn width plus horizontal padding and whose ascent and descent come from the drawn height, and size it in this order: a vertical-writing block image fills the column ignoring authored width; explicit width and height are used as given; one explicit dimension scales the other by aspect; otherwise intrinsic size; then clamp to the available width (column minus paragraph indents minus padding) and to a maximum height of 1.5 times the base width, preserving aspect each time. An image alone on its line is centred unless the paragraph's alignment is left or right; an image flowing with text keeps its inline position. A chapter whose body renders no text and exactly one block image becomes an "image page" drawn aspect-fit into the content area. A tap on an image opens a zoomable preview whose accessibility label is the alt text, else the source path, else "Image". When an image is missing or fails to decode the reader shall render its alt text in place (the candidate reserves a blank square of up to 180 points and draws nothing, and shows alt only when no image loader is configured, when an inline SVG fails, or for MathML).

Verified in the IR renderer's image metrics, the paginator's image extraction and the attachment extractor (runs with no image are skipped). Intrinsic size is taken from the decoded image with pixel dimensions treated as points (YUE-81).

Spec: HTML living standard §4.8 (the img element), EPUB 3.3 §5 (publication resources), WCAG 1.1.1 (text alternatives).

Edge cases: an image taller than the page after clamping (1.5 × width can exceed a landscape page height) is cut at the page edge because a run delegate is one unbreakable line (YUE-82); a 180-point placeholder is reserved while an image loads asynchronously in online books; alt is not exposed for in-page images to VoiceOver (section 7); http, https and data: image sources inside an EPUB chapter pass through the resolver unchanged and are expected to fail the archive lookup.

Test: a 4000 × 3000 image in a 350-point column draws 350 wide; a 100 × 2000 image is clamped to 525 points tall; `<figure><img><figcaption>` centres the image; an `img` with a bad path shows "[its alt]" (Funston rule).

#### YUE-17 SVG and MathML are rasterised

The reader shall rasterise inline `svg` elements and SVG image files to bitmaps at the resolved size and place them as images; shall convert MathML to LaTeX and rasterise it, placing inline math on the text baseline using the rasteriser's reported descent; and shall fall back to alt text when rasterisation fails.

Verified: SVG rasterisation uses a pool of offscreen WKWebViews with a watchdog (YUE-83); MathML is converted by a bundled JavaScript library in a JSContext and rendered by iosMath, with tables (`mtable`) converted to aligned environments; an SVG referenced from an `img` element is handed to `UIImage(data:)`, which is expected to yield nothing and therefore a blank box. This is the one place the "no WebView" claim fails and it is a reasonable choice; Funston can rasterise the simple SVG Gutenberg uses (decorative rules, drop caps) with Core Graphics and keep an offscreen web view as last resort.

Spec: EPUB 3.3 §6 (SVG content documents), MathML Core.

Test: an inline `<svg>` with a rect renders a rect; `<math>` inline sits on the baseline; an SVG file in an `img` renders (Funston rule).

#### YUE-18 Floated images wrap text with a notch

For an image with `float: left` or `float: right` in horizontal writing, the reader shall emit a zero-width marker at the float's position, and the paginator shall, for the page containing the marker, cut a rectangular notch (image size plus margins) out of the page's text path at the marker's line so following lines wrap beside the image; when the notch would extend below the page bottom and the marker is not at the page start, the page shall end before the marker so the float starts the next page at full height.

Verified. A floated image's default width is half the render width, capped at 60 percent, height capped at 1.5 times the render width. Spec: CSS 2.1 §9.5 (floats). Deviation: one float per page, rectangular notch only, no clearance, text blocks that float become side-aligned "bubbles" (a chat idiom not relevant to Funston); vertical writing ignores floats.

Test: a left-floated 120-point image followed by three paragraphs: the first lines wrap right of the notch; a float near the page bottom moves to the next page.

#### YUE-19 Ruby

The reader shall pair each run of base content with the `rt` that follows it, producing one Core Text ruby annotation per base run (not one across the whole `ruby`), positioned before the base, centred, with automatic overhang and a 0.85 size factor; `rp` content shall be dropped; an `rt` with empty text leaves the base plain.

Verified. Spec: HTML living standard §4.5 (the ruby, rt and rp elements), CSS Ruby Level 1. TextKit 2 honours the same Core Text ruby attribute.

Test: `<ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>` yields two annotations; `<ruby>x<rp>(</rp><rt>y</rt><rp>)</rp></ruby>` shows no parentheses.

#### YUE-20 Tables

The reader shall parse `table` into caption, rows and cells (colspan, rowspan, cell text runs and images) and carry a text alternative formed from the caption and the rows' cell texts joined by commas and newlines. The candidate then rasterises the table at the paragraph's available width into bitmaps no taller than the page's content height, places each as a block image with link regions mapped back from cell links, and disables the image preview for them. Funston shall lay tables out as text (one element per cell for VoiceOver) and keep the alternative string as the minimum.

Verified. Spec: HTML living standard §4.9 (tables). The rasterised table is invisible to selection, search and read-aloud, and does not reflow at larger sizes.

Test: a 3 × 3 table with a caption yields the alternative "caption\na, b, c\n..." and three selectable rows (Funston rule).

#### YUE-21 Alignment and justification

The reader shall treat an unspecified alignment as justified (or as the reader's alignment setting; see open question 3); shall never stretch a paragraph's last line, a line whose natural width is under 70 percent of its available width, or a line already at or beyond the available width; and shall justify by adding space only, never compressing: on word spaces when the line has more than one, otherwise between grapheme clusters except around CJK punctuation, attaching the added space to the trailing unit of each cluster and none after the last. Justification shall respect the paragraph's own right edge (tail indent), not the column.

Why: Core Text's built-in justified line also compresses full-width punctuation until glyphs overlap, and a framesetter asked for justified alignment may return pre-stretched lines, a paragraph's last line included; rebuilding each line from its own substring at natural width and distributing the residual by hand avoids both. Verified in the horizontal line drawer. Hyphenation factor 1.0 and an "en" language tag are set on Latin runs so justified English hyphenates regardless of device locale.

Spec: CSS Text Level 3 §6 (alignment and justification), §5 (line breaking and hyphenation). Deviation: tagging every Latin run "en" mis-hyphenates French and German; Funston shall tag runs with the element's or package's language (YUE-23).

Test: a justified Latin paragraph has no stretched last line; a line with one long word (coverage under 0.7) stays ragged; a CJK line adds no space before "，".

#### YUE-22 Line height, baseline and paragraph spacing

The reader shall set each paragraph's minimum and maximum line height to the larger of (font size × line height multiple) and (font ascender + |descender| + 1), centre glyphs in that box with a baseline offset of half the slack minus half the leading, and apply CSS `line-height` as an exact override (unitless times font size, or a length) that bypasses the default clamp of 1.1 to 2.0 times the font size. Default spacing: the reader's paragraph spacing for `p` (0.8 × font size by default), 0.6 of that for headings, author `margin-bottom` as spacing after and `margin-top` plus `padding-top` as spacing before; inside a decorated box an author's explicit zero margin beats the reader default. Margins between adjacent blocks shall not collapse except at a decorated container's edges, where the container's collapsible margin and the first or last child's margin take the larger of the two and padding plus border are added on top.

Verified. Defaults: 18 pt body, 1.65 line height multiple, 0.8 paragraph spacing multiple, 24 pt horizontal and 16 pt vertical page margins. Spec: CSS 2.1 §10.8 (line height), §8.3.1 (collapsing margins; the no-collapse rule is a deviation). Observed limitation: a first paragraph's spacing before is ignored by Core Text, so a chapter's opening margin needs a spacer line, and in vertical writing margin-top cannot be expressed at all.

Edge cases: a drop-cap first letter relaxes the maximum line height to zero so the large glyph is not clipped; images taller than the line box relax the paragraph too.

Test: `p { line-height: 2 }` doubles line pitch; two adjacent `p` with 1em margins show 2em in the candidate and 1em in a browser; Funston should decide and test one.

#### YUE-23 Direction and language

The reader shall set the paragraph base direction from the `dir` attribute (rtl, ltr, auto by first strong character, inherit) and CSS `direction`, defaulting to right-to-left when the package language's primary subtag is one of ar, arc, ckb, dv, fa, ha, he, iw, khw, ks, ku, nqo, prs, ps, sd, syr, ug, ur, yi; shall carry the right inset of right-aligned RTL paragraphs in the head indent because Core Text double-counts a negative tail indent on the leading edge; and shall tag every run with its language from `xml:lang` or `lang`, falling back to the publication language.

Verified for direction. Verified deviation for language: `lang` and `xml:lang` are not read; Latin runs are tagged "en" and CJK runs are tagged from a per-book script decision; the package language drives only direction, CJK style and lexicon matching. VoiceOver pronunciation and hyphenation both depend on the run language.

Spec: HTML living standard §3.2.6 (lang and dir attributes), CSS Writing Modes Level 4 §2 (direction), EPUB 3.3 §5 (dc:language).

Test: a Hebrew paragraph in an English book right-aligns; a French `<p lang="fr">` hyphenates by French rules and is read by VoiceOver in French (Funston addition).

#### YUE-24 Fonts: embedded faces, cascade and synthesis

The reader shall register `@font-face` sources lazily, only for the (family, weight, italic) requests that the chapter's resolved styles reference, by writing the font bytes to a temporary file named by a hash of the resource URL and registering it with the font manager; shall pick, among a family's registered variants, the one with the smallest weight distance and then matching italic; shall resolve `font-family` as a glyph fallback list by building a cascade of the resolved faces in order followed by the reader's last-resort faces (the candidate's are Georgia and Apple Color Emoji, deliberately no CJK face, which comes from a separate CJK pass); shall synthesise bold (weight 600 and above) and oblique (slant 0.2) when a face lacks the trait; and shall let a reader-selected font replace authored families while keeping size, weight and italic.

Verified. Temporary font files older than seven days are cleaned at launch; failed font URLs are negatively cached for the book's lifetime; `@font-face` descriptors with `bolder` or `lighter` read as 700 and 400; the registrar compares glyph maps when a PostScript name collides with an already-registered font and renames embedded subsets. Cascade descriptors carry the real point size because a size of zero re-matched against a bold primary resolves to Core Text's 12 pt default.

Spec: CSS Fonts Level 4 §4 (font resources, @font-face), §5 (font matching); EPUB 3.3 §4 (font obfuscation, YUE-54).

Edge cases: a `@font-face` whose `src` lists `local()` first is parsed only for its `url()`; `font-display`, `unicode-range` and `font-stretch` are ignored.

Test: a book with regular and bold `@font-face` for one family: bold text uses the bold file, not synthetic bold; a book with only a regular file synthesises bold; `font-family: "Missing", serif` falls back without an error log.

#### YUE-25 Forced page breaks

The reader shall emit a zero-width marker (U+200B, drawn transparent) before an element whose `page-break-before` or `break-before` is `always`, `page`, `left`, `right`, `recto` or `verso`, and after an element whose `page-break-after` or `break-after` is one of those; the paginator shall start a new page at each marker, skip a marker at the current page start, and never place a marker's character on the preceding page.

Verified. A heading whose id follows a known authoring tool's TOC-anchor convention also starts a page unless it is the first content; Funston need not copy that. Spec: CSS Fragmentation Level 3 §3 (break-before, break-after); `left`, `right`, `recto`, `verso` collapse to a plain break, right for a single-page phone reader.

Edge cases: a marker inside a hidden element is never emitted; consecutive markers produce one break; a marker after the last text produces no empty page.

Test: three `<section style="page-break-before: always">` paragraphs become three pages with no blank page between.

#### YUE-26 Keep together

The reader shall union the ranges of decorated blocks (fill, border or background image) whose `page-break-inside` or `break-inside` is `avoid`, and when a page's natural end falls strictly inside such a range that does not start at the page start, end the page before the range instead; a range longer than a page breaks naturally.

Verified; horizontal writing only, and only for blocks that draw a decoration, because the grouping rides on decoration attributes. Spec: CSS Fragmentation Level 3 §3 (break-inside; orphans and widows are not read, YUE-31).

Test: a bordered `aside` of five lines with `break-inside: avoid` near a page bottom moves whole to the next page; one of 40 lines splits.

#### YUE-27 Horizontal rules

The reader shall render `hr` as a paragraph containing only a separator, half a font size of spacing above and below, carrying a divider style (colour from border colour, else text colour, else fill colour; line width from border width, else height; rule width from width or width percent; margins; alignment; dash pattern for dashed and dotted) drawn by the line drawer in place of the empty line; an `hr` with `border: none` and no explicit height is an invisible spacer of the same height.

Verified. Spec: HTML living standard §15.3 (the hr default: a 1px inset border, centred). Why the spacer case: Calibre's scene-break class uses a borderless `hr` as whitespace.

Test: a default `hr` draws a 1-point rule across the column; `hr { width: 30%; margin: auto }` draws a centred short rule; `hr.transition { border: none }` draws nothing but keeps the gap.

#### YUE-28 Links and anchors in the attributed string

The reader shall attach the href to every run inside an anchor; shall attach the anchor id to the first character rendered by any element with an id; shall tint a link with the system link colour only when the author left it completely unstyled (no colour, bold, italic, size or family change, no underline or strike, no inline chip or attachment); and shall treat an anchor wrapping a single image as a linked image whose tap follows the link.

Verified. Spec: HTML living standard §4.5 (the a element). Deviation worth keeping: not forcing a link colour onto authored TOC entries preserves publisher design; Funston shall additionally expose links to VoiceOver (section 7).

Test: `<a href="#x">plain</a>` is link-coloured; `<a href="#x"><b>bold</b></a>` keeps the author's colour; tapping `<a><img></a>` navigates.

#### YUE-29 Footnotes and pop-up notes

The reader shall detect note references and bodies by the EPUB 3 structural semantics vocabulary (a reference with `epub:type="noteref"` or `role="doc-noteref"` whose target is an `aside` or element with `epub:type` footnote, endnote or rearnote), show a tapped reference's note in a popover anchored at the marker with the note's full content, keep an `aside` so marked out of the main flow, and still make the note reachable by ordinary navigation for EPUB 2 books that have no vocabulary; it may also accept a known authoring convention (a list item with an id whose class contains "footnote").

Verified: the legacy engine indexes only the list-item convention while building the chapter, keyed by spine and id, and shows a popover (200 to 300 points wide, at most 360 tall, selectable text) for a tapped reference whose fragment is indexed; the browser engine's package collects `aside` footnotes and noteref semantics into the same store and shows the popover only when the tapped link was a noteref, so a plain link to a note body still navigates. Neither engine hides note bodies from the flow.

Spec: EPUB 3.3 structural semantics vocabulary (noteref, footnote, endnote, rearnote) and the guidance on hiding footnote `aside` elements; DPUB-ARIA doc-noteref.

Test: Standard Ebooks' noteref to an endnotes section opens a popover; Gutenberg's `<a href="#fn1">` to a plain paragraph navigates.

### Pagination and caching

#### YUE-30 Content rectangle and line grid

The paginator shall compute the content rectangle from the page size and insets (left and right margins, a top inset from the safe area or header, a bottom inset of footer height plus footer padding plus text gap), then in horizontal writing enlarge the bottom inset so the content height is a whole number of lines, so every full page ends at the same baseline.

Verified. Observed quirk: the grid uses (font size + line spacing) as the pitch rather than the paragraph's actual line box, which is exact only because the settings define line spacing as (multiple − 1) × font size. Funston shall align to the real line box.

Test: at any font size the last baseline of a full text page is at the same y across pages of one chapter.

#### YUE-31 Page slicing loop

The paginator shall create one framesetter per chapter and slice pages by: skipping a forced-break marker at the cursor; limiting the search range to the next forced break; probing the frame to place a float notch if a float marker falls in range; creating a frame for the search range in the (possibly notched) page path; taking the frame's visible string range as the proposed advance (at least one character, so an unbreakable run cannot stall); adjusting the end so a surrogate pair is not split and a line does not begin with CJK punctuation that must not start a line; pulling the end back to the start of a keep-together range the boundary falls inside; recording the page range; and repeating until the string is consumed or a requested page cap is reached. After slicing it shall create and keep one frame plus line origins per page for drawing and hit-testing.

Verified. Spec: none; this is the Core Text idiom. Verified absence: an orphan and widow pass exists in the source but is never called, so no orphan or widow control is active in the legacy engine; the project's notes say it conflicts with filling every page to the last grid line. Funston shall choose between bottom-aligned pages and orphan control, or specify the browser engine's approach (YUE-78).

Test: a 20,000-character chapter paginates identically twice; a chapter consisting of one 10,000-character word advances at least one character per page and terminates.

#### YUE-32 Two-phase open for long chapters

For a chapter of 20,000 UTF-16 units or more with no layout yet, the engine shall first run a one-page pagination, install it as a partial layout with an estimated page count (measured pages × character density, at least one more than measured), announce it so the placeholder is replaced, then run the full pagination and install that; partial layouts shall never enter the pagination cache; a chapter under the threshold paginates in one pass.

Verified. Why: first paint of a huge opening chapter is otherwise gated on paginating all of it. Edge: a cache hit for the full layout short-circuits the partial pass.

Test: open a 400,000-character chapter; the first page appears before full pagination completes; the footer total changes once when the full layout lands; the visible page's text does not change.

#### YUE-33 Layout cache key and invalidation

The pagination cache key shall include spine index, page width and height, font size, left, top and bottom insets, line spacing, paragraph spacing, letter spacing, writing mode, a content revision (a fresh identity per attributed-string build, or a fingerprint of the string when none is given) and a fingerprint of the authored page background colour. Font size and view size changes shall clear the whole cache; theme changes shall clear nothing and recolour in place.

Verified. The engine's own chapter cache holds five layouts, evicting the chapter farthest from the current one; a jump sets the current chapter before the destination's layout is inserted so the destination is not evicted. Under a memory warning the engine drops every snapshot, keeps only the current chapter's layout, cancels preloads and clears built documents, but does not touch the paginator's own unbounded layout dictionary or the image cache (YUE-81). The built-document cache holds eight chapters and dedupes concurrent equal requests into one task.

Test: change the theme; no pagination runs. Change letter spacing by 0.1; every chapter re-paginates. Trigger a memory warning on page 2 of chapter 5; chapter 5 stays, chapters 4 and 6 rebuild on return.

#### YUE-34 Estimating total pages and progress

The engine shall obtain every spine item's byte size at open (from the archive's central directory when available) in the background, estimate an unlaid chapter's pages as bytes ÷ (600 × (20 ÷ font size)²) with a floor of 100 bytes per page and one page, estimate the page of an offset inside an unlaid chapter at 400 characters per page, compute whole-book progress as the prefix sum of bytes before the chapter plus the current offset scaled from characters to bytes over the total, and map a progress fraction back to a chapter and a proportional character offset.

Verified; the 600 bytes per page constant is calibrated for 20 pt Chinese. Byte sizes are uncompressed XHTML including markup, so markup-heavy chapters are over-weighted. For Gutenberg English the constant is off by roughly the ratio of UTF-8 bytes per rendered character, so Funston should calibrate per book from the first laid-out chapter. Why bytes: stable before layout and weights long chapters correctly; the alternative, chapter index plus fraction, drifts as neighbours load.

Test: chapters of 10, 90 and 10 KB: at chapter 2 start progress reads about 9 percent; dragging the scrubber to 50 percent lands in chapter 2.

#### YUE-35 Preloading neighbours

The engine shall preload the next chapter when 20 percent of the current chapter's pages (at least three) remain, and the previous chapter when within the same distance of the chapter start and it has no layout, and shall render page snapshots for chapter boundaries so cross-chapter page-turn animations have an image ready.

Verified. Snapshot cache tiers by physical memory: under 4 GB, 16 MB and 4 images; 4 to 6 GB, 32 MB and 6 images; otherwise 5 percent of memory clamped to 64 to 128 MB and 12 images.

Test: on a 3 GB device class, no more than four page bitmaps are retained.

#### YUE-36 Install and announce are one act

The engine shall install a chapter layout and announce it to every consumer (page data source, read-aloud text source, progress) in one step, and every layout-producing exit (partial pass, cache hit, full pass) shall go through that step; a preload shall report one of a closed set of outcomes (laid out, already laid out, superseded by a newer generation, cancelled, content unavailable, build failed, out of range) and a caller waiting on a layout shall retry at most twice when superseded.

Why: the candidate's incident history shows placeholders stuck on screen whenever a layout landed without an announcement, and read-aloud stopping at chapter ends when a cancelled preload was mistaken for failure. Verified.

Test: a placeholder on screen while its chapter paginates in the background is replaced without user action; cancelling a preload mid-flight and re-requesting succeeds.

### Rendering

#### YUE-37 Page drawing order

The page renderer shall draw, in order: the page fill (authored body background, its dark variant in dark mode, else the reader theme; the theme when a reader background image is set), the background image aspect-filled, block decorations (fills, borders, background images) in UIKit coordinates, then flip to Core Text coordinates and draw text line by line, then flip back and draw inline annotations, upright cells, block images, inline images, decorated-block images and decorated-block explicit text; header and footer bars are drawn into the same context last so they turn with the page in every animation. An image-only page draws its image and returns.

Verified. Why bars last: a UIKit subview on the page controller would be visible only on the live page, not on curl backs, cover snapshots or auto-read reveals.

Test: screenshot a page with a bordered aside and an inline image; the border is behind the text and the image above the text's background.

#### YUE-38 Line-by-line drawing with bottom distribution

In horizontal writing the renderer shall draw each line with `CTLineDraw` at its origin offset by the content rectangle, skipping lines whose ranges belong to separately drawn blocks, drawing a divider in place of an `hr` line, and on a non-last page without block decorations distributing the slack between the last line's descent and the content bottom evenly across paragraph gaps so the page is bottom-aligned; inline border chips are drawn behind glyphs and the optional reader underline decoration after them. Vertical writing draws the whole frame with `CTFrameDraw`.

Verified. Why decorations disable distribution: decoration rectangles were measured from unshifted origins. TextKit 2's layout fragments give per-line geometry equivalent to line origins.

Test: a non-last page with five paragraph gaps ends exactly at the content bottom; a page with a decorated block keeps natural spacing.

#### YUE-39 Theme colours without re-pagination

On an appearance change the renderer shall copy the chapter string, set the theme foreground on every run, restore author-specified foregrounds from their marker attribute, apply dark author foregrounds in dark mode, clear stale theme-coloured run backgrounds, swap block fills that equalled the old theme background to the new one, apply dark block fills in dark mode, rebuild the framesetter and the per-page frames from the recoloured string with the same page ranges, and keep every attachment rectangle unchanged.

Verified. Colour attributes never change line breaking in Core Text. Run background is not painted because `CTLineDraw` and `CTFrameDraw` ignore the background colour attribute, so inline fills are custom drawn.

Test: switch light to dark mid-chapter; page ranges are identical before and after; author red text stays red; author dark variants apply.

#### YUE-40 Prerendered pages

The page view shall display a prerendered bitmap when one exists for the same size and scale, else render into an image renderer and set the layer contents; prerenders shall be invalidated whenever the page, its layout revision or its bars change, and snapshot keys shall carry the layout revision so a stale background render cannot repopulate the cache.

Verified; signposts record whether a display came from a prerender, a draw, or a mismatch.

Test: turn pages quickly; the signpost shows prerendered displays for neighbours; change the font and no old snapshot is shown.

### Selection and annotations

#### YUE-41 Hit-testing a point to a character

The page view shall convert a touch to layout coordinates (dividing by the view-to-layout scale), flip to Core Text coordinates, choose the line whose ascent-to-descent band contains the point or else the nearest line, reject the touch when it lies more than 10 points outside the line's typographic width (so blank margin neither selects nor follows a link and the touch falls through to page turning), and ask the line for the string index at the x offset using a boundary that corrects for negative kerning so a squeezed punctuation glyph is not cut. Vertical writing chooses a column by x within 10 points and measures the advance from the column top.

Verified. Why the correction: Core Text places the boundary before a character halfway through the preceding character's kern, which for negative kerns lands inside the next glyph (measured by the project at a quarter em).

Test: tapping 30 points right of a short line's end does not select; tapping on the last glyph does; dragging a handle across a kerned "？」" pair never splits a glyph.

#### YUE-42 Selection model

Selection shall be a UTF-16 range held as an anchor index and a focus index (normalised on set), confined to the chapter string and in practice to the visible page; a long press of 0.25 seconds selects the enclosing paragraph trimmed of leading and trailing whitespace (one character when the paragraph is blank), expanded to include any annotation that overlaps or comes within two characters, and marks an annotation fully containing the selection as the one being edited; two handles (6-point circles with 24-point stems) are hit within 36 points and dragging moves the logical endpoint resolved at gesture start, so handles may cross; after each drag update the range snaps again to nearby annotations (tolerance 3) and the gesture stays attached to the same visual boundary; a tap inside the selection re-presents the menu, a tap outside clears it.

Verified. Selection rectangles are computed per line from the intersection of the line's range with the selection, using kern-corrected boundaries and the line's ascent and descent. Deviations from the system: no word granularity, no double-tap to select a word, no drag-to-start selection, no `UITextInteraction`, no cross-page selection, no Look Up.

Test: long press mid-paragraph selects the paragraph; dragging the start handle past the end handle keeps a valid range; a two-line selection yields two rectangles with no gap.

#### YUE-43 Edit menu actions

With a non-empty selection the page view shall present the system edit menu containing the system suggestions plus: delete annotation when one is selected; replace rule; "emphasis" (a submenu of five highlight colours plus underline, with the current annotation's style checked); note or edit note; and optional assistant actions. The emphasis submenu is a second edit menu presented at the same source point.

Verified. The candidate's responder accepts only copy among the standard actions, so Look Up, Translate, Search Web, Share and Speak are absent. Funston shall return the full standard set and add Speak for read-aloud from the selection.

Test: select text; the menu shows Copy, Look Up, Speak, Highlight, Note (Funston set).

#### YUE-44 Annotation model and merge rules

An annotation shall be (id, spine index, UTF-16 range in the chapter's own text, style: highlight or underline, colour: one of yellow, green, blue, pink, orange, optional note). Adding one shall merge it with every existing annotation of the same spine, style and colour that overlaps or touches it into one range (preserving the first non-empty note) and report created, updated or merged with the absorbed ids; a different style or colour stays separate; removing shall delete by id or by exact range; hit-testing shall find an annotation within two characters of a tap; tapping an existing annotation selects its exact range and marks it for editing.

Verified. Rendering: per page, annotations are grouped by (style, colour) into layers of rectangles computed like selection rects; highlights fill at 25 percent alpha; underlines stroke a 1 to 2 point red line at the rect bottom (the right side in vertical text); a note marker circle is drawn once at the annotation's first character on the page where it starts. The browser engine shares the model.

Test: highlight "quick brown" yellow then "brown fox" yellow: one annotation "quick brown fox"; then "brown" green: two annotations, the yellow unchanged (the candidate does not split; Funston should decide whether overlapping colours split the older one).

#### YUE-45 Bookmarks

A page bookmark shall be stored at the page's start position with a 90-character excerpt and the chapter title; "is this page bookmarked" shall be answered by range containment (page start ≤ bookmark position < next page start, or to chapter end when the next page is unknown), never by equality, so a bookmark survives a relayout that moves page starts; duplicates at the same position are refused.

Verified. Why: after a font change the saved page start fell mid-page and equality said "no bookmark here", which created a second bookmark that could never be removed.

Test: bookmark page 4, increase font size, open the bookmark list; the page containing the saved offset shows the ribbon.

### Accessibility (what exists; gaps are in section 7)

#### YUE-46 The page is one VoiceOver element with page-turn actions

Each rendered page shall be an accessibility element with the static text trait, labelled with the page's plain text, hinted with how to open the toolbar and turn pages, carrying custom actions for next page, previous page, menu and table of contents; double-tap shall open the menu; three-finger scroll left or up shall go forward and right or down back, inverted for right-to-left page progression; when a page appears the reader shall post a screen-changed notification focused on it; header and footer text shall be exposed as custom content (the rotor's "more content"), not as separate elements; a loading placeholder shall be an element labelled with the chapter title and "loading" and shall keep the menu and contents actions.

Verified in both engines' page views and the placeholder. Continuous scroll exposes each roughly 2000-point chunk as one element with a menu action and no page actions. The browser engine's page additionally offers a "select text" custom action that begins a selection at the first text fragment. The read-aloud highlight overlay is not an accessibility element.

Test: with VoiceOver on, swipe right from the toolbar lands on the page and reads its text; a three-finger swipe left turns the page and focus follows; the rotor's custom content lists the footer.

### EPUB container, package and navigation

The candidate opens the archive with Readium's streamer and, in parallel, reads the container document with Foundation's XML parser and scans the package document's text with regular expressions for the fields Readium does not expose the way it wants. Everything below is what Funston's own parser must do, with the candidate's behaviour as evidence.

#### YUE-47 Open the container once, from the rootfile the container names

The reader shall open the archive, read META-INF/container.xml with an XML parser, take the first rootfile element whose media type is the package document type, read the package document at that path (percent-decoded, container-root relative), and parse it once; a missing container document, a container with no rootfile, a missing package document or one that is not well-formed XML shall each fail the open with a distinct, user-visible reason.

Verified in the candidate: the first rootfile is taken regardless of media type; the mimetype entry and the rootfile media type are never checked; the package document bytes must decode as UTF-8 or UTF-16; the package is parsed twice. Resources are read from the archive on demand and never extracted, except audio and video, which are copied to a temporary directory for AVFoundation, and fixed-layout pages, which are rewritten with inlined data URIs for a web view.

Spec: EPUB 3.3 §4 (OCF: the container.xml rootfiles element and the mimetype file).

Edge cases: multiple rootfiles (take the first of the package type; it is the default rendition); a package document at the container root; zip entries with backslashes or absolute paths (reject); a mimetype entry that is compressed or not first (tolerate, log).

Test: W3C epub-tests container cases; a hand-made EPUB with two rootfiles.

#### YUE-48 Resolve resource references by the specification, then tolerate what books do

The reader shall resolve every href in the package document against the package document's directory and every href in a content document against that document's path, remove dot segments, treat a leading slash as container-root relative, and look the result up in the archive by its exact percent-encoded and percent-decoded spellings.

Verified: the candidate's lookup tries five spellings (as given, slash-stripped, slash-prefixed, decoded, slash-prefixed decoded) because reading-order hrefs arrive percent-encoded and requests decoded; its chapter lookup also accepts a suffix match in either direction, which makes TOC entries with wrong directory prefixes work and a wrong match possible when two spine items share a file name in different directories.

Spec: EPUB 3.3 §5 (URLs in the package document), RFC 3986 §5.2 (reference resolution). Keep percent-encoding tolerance; drop suffix matching in favour of exact, then path-normalised, then a logged failure.

Test: a package in OEBPS/ with a chapter in OEBPS/Text/ linking ../Images/a.png and Text/b.xhtml#x; a chapter name with a space percent-encoded in the package and decoded in a link.

#### YUE-49 Package metadata the reader reads

The reader shall read: the first dc:title; dc:creator values in order; the first dc:language as the publication language; the dc:identifier named by the package element's unique-identifier attribute (for font de-obfuscation and a stable book key); dcterms:modified; the spine's page-progression-direction (ltr, rtl, default); rendition:layout (reflowable or pre-paginated); rendition:spread, rendition:orientation and per-itemref properties for fixed layout; and it shall accept both the EPUB 3 property form and the EPUB 2 name/content form of meta elements.

Verified: the candidate reads language, a non-standard primary-writing-mode meta (a value containing "vertical" selects vertical right-to-left), layout, flow, spread, orientation, page progression direction, viewport (including refines-scoped viewports) and the unique identifier itself, and takes title and creators from Readium. It does not read dc:date, dcterms:modified, publisher or creator roles. Deviation of note: an rtl page progression with no declared writing mode and a language that is not a right-to-left script is promoted to vertical writing; a Japanese-novel heuristic that would make an English book declaring rtl vertical. Funston shall not adopt it.

Spec: EPUB 3.3 §5 (metadata, dc elements, the spine and page-progression-direction) and §8 (layout rendering control: rendition:layout, orientation, spread, flow); EPUB 2.0.1 OPF §2.2 (metadata), §2.4 (spine).

Test: IDPF samples with rtl progression and rendition:layout; a Gutenberg EPUB 2 with dc:identifier scheme attributes.

#### YUE-50 Spine items become chapters

The reader shall make one paginated chapter per spine itemref in document order whose manifest item is XHTML; non-linear items shall be excluded from the page sequence but remain resolvable as link targets; a spine item of SVG or image media type shall render as an image page; an itemref whose idref matches no manifest item shall be dropped with a logged warning and shall not shift the CFI spine-step numbering of the items after it; manifest fallback chains shall be followed for non-core media types.

Verified: the candidate keys everything to Readium's reading order filtered to HTML media types (or html, htm, xhtml extensions when the type is missing); if that filter leaves nothing the unfiltered order is used, so an all-SVG spine is handed to the HTML builder; an unknown idref is dropped silently from the candidate's own spine model, which shifts its CFI fallback indices; linear="no" is consulted only by an opening-animation preflight, and the test that pins non-linear handling relies on Readium excluding the item; fallback chains are not modelled.

Spec: EPUB 3.3 §5 (itemref and the linear attribute; manifest fallbacks), §6 (SVG content documents in the spine).

Test: IDPF sample with a non-linear cover; a spine whose second itemref has a bad idref; an SVG spine item.

#### YUE-51 Navigation document and NCX to a chapter list

The reader shall prefer the EPUB 3 navigation document's toc nav and fall back to the NCX navMap, flatten the tree depth first preserving depth, map each entry's href (path plus fragment) to a spine index and fragment, never silently attach an unresolvable entry to the first chapter, carry a sanitised title (entities decoded, tags stripped, whitespace collapsed; an empty or unreasonably long title replaced by a label from the file name or an ordinal), fall back to spine items as a flat list when the TOC is empty, and read the page-list and landmarks navs for "go to page" and "go to cover or body".

Verified: the candidate flattens Readium's table of contents (nav-versus-NCX precedence is Readium's); an entry pointing outside the spine is mapped to chapter 0 without a signal; titles over 240 characters or that still look like markup fall back; entries with empty titles are dropped; duplicates by (index, fragment, title) are removed; page-list and landmarks are not read; a nav document that is itself a spine item renders as a chapter and relies on the hidden attribute to keep page-list and landmarks out of the pages; the current TOC entry is the one with the largest resolvable offset not beyond the reader's offset.

Spec: EPUB 3.3 §7 (navigation document: toc, page-list and landmarks navs); EPUB 2.0.1 NCX (navMap, navPoint, playOrder).

Edge cases: nested ol in a toc nav; an entry with a CFI fragment (YUE-52); a nav document with hidden page-list.

Test: Moby Dick sample (nav plus page-list); a Gutenberg NCX with playOrder gaps; a TOC entry to a non-spine resource (expect a disabled or flagged entry, not chapter 0).

#### YUE-52 Canonical fragment identifiers

The reader shall parse a CFI found in a TOC href or a saved position (the epubcfi(...) form with one step indirection from the package document's spine into the content document), honour id assertions on steps, resolve the spine step to a spine item by id assertion first and then by step number (even steps count child elements including non-linear itemrefs), resolve the content path by walking element steps when possible and by id assertion when present, apply the character offset, ignore text location assertions, and reject or degrade gracefully on ranges, temporal and spatial offsets and side bias. For saved positions the reader shall also generate a CFI for the current position so another renderer or edition can find it.

Verified: the candidate's resolver parses but never generates; it uses only the last spine component, requires id assertions to place the content offset (element steps without ids are ignored, so a CFI with no ids resolves to an offset into the whole chapter), accepts a single indirection, and discards text assertions. A second generator produces a private partial CFI that is not document-accurate (the offset is into the rendered string) and has no production caller. A third builds Calibre-style CFIs from a prepared DOM by matching a unique text window (radii 512 down to 8 UTF-16 units) and serves only progress upload to a Calibre server.

Spec: EPUB CFI 1.1 §3.1 (paths: steps, indirection, id assertions, character offsets, text location assertions), §3.2 (ranges).

Test: epubcfi(/6/4[chap01]!/4/2/1:10) resolves to the chapter whose itemref id is chap01, 10 characters into the second child's first text node; a CFI with no id assertions still resolves by element steps (Funston rule); a range CFI is rejected with a diagnostic.

#### YUE-53 Decode content documents by their declared or detected encoding

The reader shall decode a content document from a byte order mark, else the XML declaration's encoding, else the manifest's declared encoding, else UTF-8, and shall fail loudly (a diagnostic and a visible "could not read this chapter") rather than fall back to a single-byte encoding that silently produces wrong characters.

Verified deviation: the candidate tries the declared encoding, UTF-8, "Unicode", UTF-16, UTF-16LE, UTF-16BE and ISO Latin-1 in order; Latin-1 never fails, so a mislabelled chapter renders as mojibake with no error, and no byte order mark or meta charset sniffing exists on the local path.

Spec: EPUB 3.3 §6 (XHTML content documents are UTF-8 or UTF-16), XML 1.0 §4.3.3 (encoding declaration).

Test: a UTF-16 chapter with a BOM; a chapter claiming UTF-8 that contains invalid sequences (expect a diagnostic, not replacement characters shown as content).

#### YUE-54 Font obfuscation and encryption

The reader shall read META-INF/encryption.xml, recognise the IDPF font obfuscation algorithm (key: SHA-1 of the unique identifier with whitespace removed; XOR the first 1040 bytes) and the Adobe algorithm (key: the 16 bytes of the identifier's UUID; first 1024 bytes), read the raw bytes of each listed resource and de-obfuscate them before font registration, and treat a resource encrypted with any other algorithm as unreadable (fallback font, one log line) rather than hand encrypted bytes to the renderer.

Verified: the candidate recognises both algorithms, derives the key from the unique identifier or Readium's identifier, caches de-obfuscated bytes in an unbounded dictionary, and returns bytes unchanged for an unknown algorithm; an encryption.xml that exists but cannot be read fails the open.

Spec: EPUB 3.3 §4 (OCF: encryption.xml and the font obfuscation algorithm with its 1040-byte count).

Test: IDPF sample with obfuscated fonts; an encryption.xml listing an LCP-encrypted chapter (expect a clear "protected book" message).

#### YUE-55 Media overlays

The reader shall discover a spine item's media overlay through the manifest item's media-overlay attribute, parse the SMIL document (body, seq and par elements; text src with fragment; audio src with clipBegin and clipEnd in the SMIL clock value forms: full clock, partial clock, timecount with h, min, s or ms), map each par's text fragment to a rendered offset through the anchor table (YUE-05), highlight the active par's text and turn pages to follow it, play the audio resource from the archive, honour the active-class and playback-active-class metadata when present, and expose skip and escape for structures marked skippable or escapable.

Verified in the candidate: discovery by manifest attribute; a regular-expression SMIL parser that takes every par in document order, the first audio and the first text child of each (a par with no audio is dropped; seq nesting and epub:type are ignored); clock value parsing for npt=, ms, min and s suffixes, h:mm:ss, mm:ss and bare seconds; the highlighted text is the substring from the fragment's anchor to the next fragment's anchor or 180 UTF-16 units; the audio URL handed to AVPlayer is the app's private resource scheme with no resource loader registered for it, which the surveying agent judged unplayable for audio inside the archive (not run, so unconfirmed); a time observer fires every 0.15 seconds; fragments on a second audio file are never reached; nothing turns pages; active-class metadata is not read.

Spec: EPUB 3.3 §9 (media overlays: SMIL structure, clock values, active-class and playback-active-class metadata, skippability and escapability).

Test: IDPF cc-shared-culture sample: play the first chapter's overlay, assert the highlight advances par by par and the page turns at the page boundary; a par with clipEnd before clipBegin is skipped with a diagnostic.

#### YUE-56 Book identity for persisted positions

The reader shall key saved positions and annotations by Funston's existing (identifier, file name) pair and additionally record the package's unique identifier and dcterms:modified inside the saved locator so a position can be matched to another file of the same edition and detected as stale against a different edition.

Verified in the candidate: a book is a UUID assigned at import; the file is copied under that UUID; positions are keyed by the UUID string, a second offset store by file path, the spine cache by file name, and fixed-layout offsets by a per-open session id (so they never survive a reopen); no hash and no package identifier participate; importing another edition gets a new UUID and nothing migrates.

Spec: EPUB 3.3 §5 (dc:identifier, unique-identifier, dcterms:modified; the release identifier is the pair).

Test: save a position in pg20512-images.epub, re-download the same file under another name, open it: the position is offered; open a different Gutenberg edition of the same title: the position is reported stale and the CFI or text-context fallback is attempted.

### Read-aloud

The candidate drives the system synthesizer from a coordinator that also owns the audio session and the lock screen. A second engine streams audio from network voices; it does not change the model below and is out of Funston's scope.

#### YUE-57 Narration text and the offset map

The reader shall narrate the chapter's rendered text (the same string that was laid out), with attachment placeholders removed and runs of spaces, tabs and blank lines collapsed, and shall keep a map from every narration offset back to a rendered-text offset built by a single forward alignment (each narration unit matches the next source unit that is equal, or is whitespace when the narration unit is whitespace) so any spoken range becomes a chapter range without re-running the cleanup; when narration starts mid-chapter the map shall be sliced, not re-aligned, so repeated text does not latch onto an earlier occurrence.

Verified. Source precedence in the candidate: the legacy layout's string (not when the chapter is rendered by the browser engine or displays a translation); else the engine's chapter text with an identity map; else page strings or raw content with no map. Alt text is never spoken; headings are spoken as plain text with no pause; ruby bases are replaced by their readings at speak time; tables are silent (bitmaps) and their alternative is not spoken either.

Funston addition: speak image alt text ("image: ...") and table alternatives; pause at headings.

Test: a chapter with an inline image and two blank lines between paragraphs: the narration omits the placeholder and the offset of the word after the image maps to its rendered offset.

#### YUE-58 Utterance segmentation

The reader shall split narration into utterances at sentence boundaries within paragraphs, shall never split inside a ruby base, shall fold punctuation-only fragments into the preceding utterance of the same paragraph and drop punctuation-only paragraphs, shall cap an utterance at a safe length, and shall record each utterance's chapter range.

Verified deviation: the candidate splits only at paragraph breaks (any character whose Unicode newline property is set) and at a 2000-character cap for the system synthesizer (300 for the network engine), by design (a test pins that three sentences stay one chunk), so a long paragraph is one utterance and sentence-level highlight and skip are impossible; its ruby and punctuation rules are as stated. Funston shall use the system sentence tokenizer per language.

Test: a paragraph of three sentences yields three utterances with contiguous ranges; "...!?" alone folds into the previous utterance; a ruby base straddling the cap moves whole into the next utterance.

#### YUE-59 Highlight and page following

The reader shall highlight the current utterance's range on every visible page by converting the utterance's chapter range through the layout to line rectangles, shall turn to the page containing the utterance start when it is off screen while playback is playing, shall not auto-follow in continuous scroll beyond keeping the highlight visible, and shall offer a user who has navigated away a choice between returning to the narrated position and restarting narration from the visible chapter.

Verified deviation: both the highlight and page following locate the spoken text by searching the page or chapter for the utterance text, biased toward an expected offset, which failed on repeated short lines and is why the expected offset was added; the highlight is paragraph granularity, a 28 percent alpha fill of a user colour, redrawn whenever a page is configured or its bounds change (so rotation and font changes do not strand it); scroll mode nudges forward when the highlighted line's bottom passes 72 percent of the viewport so it sits at 30 percent; the synthesizer's will-speak callback is consumed only to remember the resume offset, never to move the highlight.

Test: a chapter with "Yes." three times on one page: the third utterance highlights the third occurrence; narration crossing a page boundary turns the page once; rotate during speech and the highlight follows.

#### YUE-60 Chapter boundaries and background continuity

When narration reaches a chapter's end the reader shall request the next chapter's narration text; if that chapter is not yet built it shall enter a waiting state that keeps the audio session active (the candidate loops a one-second silent PCM buffer at zero volume through an audio player and shows a loading title on the lock screen), resume automatically when the text arrives, and treat a chapter that is built but empty as the end of narration with a diagnostic rather than a retry; it shall also build the chapter after the one being narrated during playback, because page-turn preloading does not run with the screen locked.

Verified. Funston note: narration text can come from the parsed XHTML without waiting for pagination, which removes most of the waiting state.

Test: start narration two pages before a chapter end with the next chapter unbuilt: narration continues with no gap beyond the build; lock the screen and the next chapter still begins.

#### YUE-61 Voice and language per utterance

The reader shall choose each utterance's voice from the language of its text, taken from the run's language (YUE-23) and falling back to the publication language, then the user's preferred voice for that language, then the system default voice for the language; shall map the rate setting onto the synthesizer's default rate scaled and clamped to its range; and shall leave pitch and volume at defaults unless the user changes them.

Verified deviation: the candidate infers the language per utterance by script detection (any CJK ideograph makes it Chinese, Traditional when the device prefers zh-Hant or a TW, HK or MO region, else Simplified; everything else uses the device's current language), ignores the publication language for voice choice, sets only voice and rate on each utterance, and exposes a rate scale of 0.1 to 2.5 where 0.5 means 100 percent. A role-voice feature assigns voices to detected speakers of quoted dialogue by CJK quotation heuristics; out of scope.

Test: a French book speaks with a French voice on an English device; a Chinese book on an English device speaks Chinese.

#### YUE-62 Pronunciation hints

The reader shall apply, in priority order, authored SSML phoneme hints (the ssml:ph attribute with an IPA alphabet) as the synthesizer's IPA notation attribute on the utterance's attributed string, ruby readings by substituting the base text with the reading while mapping offsets back, and matches from Pronunciation Lexicon documents listed in the manifest (media type application/pls+xml) whose alphabet is IPA and whose language matches the publication's, matched at word boundaries left to right without overlap.

Verified; the candidate matches lexicon graphemes as literal substrings without word boundaries (deviation).

Spec: EPUB 3.3 §6 (SSML attributes in XHTML content documents and the pronunciation lexicon), W3C PLS 1.0 §4.

Test: Standard Ebooks or the IDPF samples with ssml:ph; a PLS mapping "Gutenberg" to an IPA string does not alter "Gutenbergs".

#### YUE-63 Playback control

The reader shall pause at a word boundary; resume by continuing the paused utterance when the synthesizer still holds it and otherwise by re-speaking the unspoken tail from the last word-boundary offset the synthesizer reported (mapped back to the chapter); skip forward and back by one utterance; skip by chapter; scrub by mapping a 0 to 1 fraction onto an utterance index; apply a rate change by re-speaking the current utterance's tail at the new rate; and offer a sleep timer (the candidate: 15, 30, 60 and 90 minutes; Funston's roadmap: 15, 30, 45, 60 and end of recording for audio; align them).

Verified.

Test: pause mid-sentence, background the app, return and resume: speech continues from the paused word, not the utterance start; change rate mid-utterance: the rest is re-spoken at the new rate once.

#### YUE-64 Audio session, lock screen and interruptions

On starting narration the reader shall set the shared audio session to the playback category, spoken audio mode and long-form audio routing policy with no mixing options, activate it, and begin receiving remote control events; shall publish Now Playing info (book title, author, chapter, artwork, an estimated duration from characters at about 5.5 per second scaled by rate, elapsed time, playback rate 1 or 0) and enable play, pause, toggle, next and previous track (chapters) and change playback position commands; shall pause on interruption and resume only when the interruption ends with the should-resume option and the session reactivates; shall pause when the audio route loses its device; shall recover from a media services reset by re-activating and re-speaking the current utterance's tail, and shall treat a synthesizer cancellation as a voice failure unless a reset preceded it; and shall deactivate the session with the notify-others option only when narration stops.

Verified. Funston note: the roadmap says read-aloud shares the audio session with the music player; the candidate's ownership rules (one coordinator claims the system media role, re-registers commands on every start, only the owner writes Now Playing) are its answer to two players fighting over the lock screen and should carry over.

Test: start narration, receive a call, hang up: narration resumes; unplug headphones: it pauses; trigger a media services reset in the simulator: it resumes at the current sentence.

### The browser engine

YUE-65 to YUE-80 are reserved for the CSS box-model engine in the YueduCoreText package: its CSS parser and selector support, computed style and units, box tree, inline and block layout, page fragmentation (break rules, orphans and widows, tall images), display list and painting, viewport estimation in scroll mode, chapter admission and fallback, source mapping, selection and fonts. The survey of that package had not reported when this version was committed; the section will follow in a later commit with the same IDs, and the merged spec should not renumber around it.

### Images, memory and failure

#### YUE-81 Image decoding and memory budget

The reader shall read an image's pixel size from its header without decoding, reserve its box from that size, decode lazily and downsampled to the largest size the page can show, cache decoded images per book with a cost equal to the decoded byte count (the candidate: 256 entries, 32 MB), and purge that cache, every cached chapter layout except the visible one, every page snapshot and every page frame on a memory warning.

Verified deviations in the candidate: images are loaded and decoded sequentially while the attributed string is built, so image I/O sits on the chapter build's critical path (the project measured 97 percent of a chapter's render time before caching); the EPUB path decodes full size with pixels treated as points while the online path downsamples through ImageIO to a 2048-pixel longest edge; the memory-warning handler does not touch the image cache or the paginator's own layout dictionary.

Test: a chapter with twenty 3000 × 2000 JPEGs builds without decoding any until drawn; a memory warning on page 1 leaves the image cache empty.

#### YUE-82 Images taller than a page

A block image whose scaled height exceeds the content height shall be scaled down to fit the page (preserving aspect) or moved to its own page; it shall never be clipped by the page edge.

Verified: the legacy engine clamps height to 1.5 times the column width, not to the page, so a tall image on a landscape phone is cut; the browser engine's behaviour is in YUE-77.

Test: a 400 × 3000 image on a landscape phone fits within the page.

#### YUE-83 SVG rasterisation bounds

When rasterising SVG the reader shall resolve the target size from CSS width and height, else the root element's width and height attributes (pixels, percent of column, unitless), else the viewBox aspect, else a default of 240 × 120 points; scale down to the column width; inject a viewBox when the root has only width and height so forced sizing scales instead of clipping; bound every rasterisation by a watchdog (the candidate: 7 seconds, two retries 150 ms apart on snapshot failure); cache results by content hash and size (the candidate: 1024 entries); and fall back to alt text or a blank box of the resolved size on failure.

Verified; the candidate uses a pool of four offscreen web views confined to the main actor, and the same pool and cache serve a decorative battery-indicator feature with hard limits (scale 0.5 to 4, maximum dimension 4096, maximum area 8,388,608 pixels).

Spec: SVG 2 §8 (coordinate systems; the viewBox attribute and intrinsic sizing).

Test: an inline svg with width and height but no viewBox renders at its declared size scaled to the column; an svg file in an img renders.

#### YUE-84 Page frame retention

The reader shall budget retained layout objects: the candidate keeps one framesetter plus one frame and line origins per page for every cached chapter (five chapters) and rebuilds frames only on recolour; Funston shall keep frames for the visible page and its neighbours and recreate others from page ranges on demand, and shall record the footprint of a chapter layout in its diagnostics.

Verified by reading; no footprint measurement exists in the candidate's repository (its memory design note's before-and-after table is blank).

Test: a 300-page chapter's cached layout holds at most three frames after reading page 150.

#### YUE-85 Bounded work per chapter

Every chapter build shall be bounded: a time limit after which the chapter is reported as too complex and shown as plain text or a diagnostic (the candidate's browser engine uses 5 seconds and falls back to the legacy engine), a depth limit on the element tree (the candidate's DOM walk and renderer recurse without one), and a size threshold above which the two-phase first-page path is mandatory (the candidate: 20,000 UTF-16 units). The first paint shall wait on the layout task's completion, never on a timer (the candidate polls every 16 milliseconds for the first layout, which its own notes list as debt).

Spec: none; this is Funston's bounded-work guard, the analogue of the gen-UI evaluation limits.

Test: a chapter nested 10,000 divs deep is rejected with a diagnostic and does not overflow the stack; a chapter exceeding the limit shows its text unstyled.

#### YUE-86 Named outcomes and diagnostics

Every exit of a chapter build and layout shall be named (laid out, already laid out, superseded, cancelled, content unavailable, build failed, empty document, out of range) and logged at a level that reaches exported diagnostics without a debug switch; stage timings (chapter fetch, HTML parse, stylesheet collect, parse and match, AST build, IR convert, attributed render, image load and decode, framesetter create, page ranges, display list, first page publish, render page) shall be recorded as signposts with content-free metadata; a ring buffer of recent trace lines shall be attached to any anomaly.

Verified: the candidate records all of these, keeps a 300-entry in-memory ring of trace-level lines attached to the next anomaly or fault, and defines position-sentry anomalies (a page turn landing elsewhere than stepped, a chapter jump of two or more, an animation finishing without advancing, scroll content moving more than 120 characters under the reader) whose thresholds its notes call guesses awaiting device logs.

Test: force each outcome and assert the diagnostic line; assert no page content appears in signpost metadata.

#### YUE-87 Observed performance figures

Recorded so the merged spec can set budgets; all are the candidate's own measurements on a debug simulator, reproduced from its notes and comments, not re-run:

| Measurement | Value |
| --- | --- |
| Chapter build, two large commercial EPUBs (169 MB and 235 MB), before skipping absent font files | 11,025 ms and 5,129 ms |
| Same, after an availability check stopped probing absent fonts (the books declare about 123 faces and ship 4 and 11) | 984 to 1,638 ms and 2,272 to 3,237 ms |
| First-page pagination | 5.7 to 18.4 ms |
| Full chapter pagination | 5.7 to 20.0 ms |
| Framesetter creation, 3,400-character chapter | 1.2 ms plain, 3.6 ms styled |
| One page frame build | 1.7 ms median |
| Archive read of one image in an obfuscated book | 33 to 40 ms; 102 loads for 11 distinct images before caching |
| HTML parser stall | about 275 KB of inline base64 made the parser unusable |

The lesson: chapter build, not pagination, dominates, through stylesheet parsing, font probing and image I/O. Funston's budget should put pagination under 50 ms per chapter and treat more than 1 s of build as a diagnostic.

#### YUE-88 Test corpus discipline

Rendering tests shall build small EPUBs in memory from XHTML strings for unit cases and use public fixtures by URL for corpus cases; no test shall depend on a file at an absolute path on one machine.

Verified: the candidate's unit tests mostly build archives in memory and ship six synthetic regression EPUBs (block image before paragraph, centred percent image, hr width and alignment, basic nav, paragraph border and background, basic NCX); several corpus tests are gated on commercial books at absolute paths on the author's machine or on environment variables.

## Algorithms

Pseudocode here is written from the behaviour, not from the source's shape.

### Position walking

```
next(position):
  layout = layouts[position.spine]            // nil → return nil
  page   = pageIndex(layout, clamp(position.offset))
  if page + 1 < layout.pageCount: return (spine, layout.pageStart[page + 1])
  if layout.isPartial:
      covered = end of last measured page
      if covered < layout.length:
          return covered > position.offset ? (spine, covered) : nil
  return spine + 1 < chapterCount ? (spine + 1, 0) : nil

previous(position):
  layout = layouts[position.spine]            // nil → return nil
  page   = pageIndex(layout, clamp(position.offset))
  if page > 0: return (spine, layout.pageStart[page - 1])
  return spine > 0 ? (spine - 1, END_SENTINEL) : nil

pageIndex(layout, offset): binary search for the last page whose start ≤ offset
```

The end sentinel resolves to the last page whenever the layout exists, so crossing backwards never needs the previous chapter laid out first.

### Page slicing (legacy)

```
insets  = gridAlign(insets)                  // horizontal only: bottom inset grows to whole lines
rect    = contentRect(pageSize, insets)      // Core Text coordinates, origin bottom-left
breaks  = forcedBreakMarkers(string)         // sorted ranges
keep    = keepTogetherRanges(string)         // decorated blocks with break-inside avoid
floats  = floatMarkers(string)
cursor  = 0
while cursor < length:
  if cursor inside a break marker: cursor = marker.end; continue
  limit   = next break after cursor, else length
  notch   = nil
  if a float marker m lies in [cursor, limit):
      probe = frame(cursor..limit, rect)
      top   = lineTop(probe, m.offset)
      if top − notchHeight < rect.minY and m.offset > cursor:
          emit page [cursor, m.offset); cursor = m.offset; continue
      notch = rect carved at the float's side from top down notchHeight
  f       = frame(cursor..limit, path(rect minus notch))
  advance = max(1, visibleLength(f))
  end     = protectCJKBoundary(cursor + advance)   // never split a surrogate, never start a line with closing punctuation
  if some k in keep contains end strictly inside and k.start > cursor: end = k.start
  emit page [cursor, end); cursor = end
  if pageCap reached: break
isPartial = cursor < length
```

Then, per page, create the frame once more with the final notch and keep its lines and origins.

### Cache key

Key = (spine, width, height, font size, left inset, top inset, bottom inset, line spacing, paragraph spacing, letter spacing, writing mode, content revision or string fingerprint, authored page background fingerprint). Content revision is minted once per attributed-string build; a cache hit requires the same build, so a changed replace rule or translation setting never reuses a layout.

### Total pages and progress

```
rebuildOffsets():
  bytesPerPage = max(100, 600 × (20 / fontSize)²)
  offset = 0
  for each spine i:
      start[i] = offset
      offset += layouts[i]?.displayPageCount
             ?? (byteSize[i] > 0 ? max(1, byteSize[i] / bytesPerPage) : 1)
  totalPages = offset
  currentPage = pageIndex(for: anchorPosition) ?? estimatedPage(for: anchorPosition)

estimatedPage(position): start[spine] + min(position.offset / 400, estimatedPages(spine) − 1)

progress(spine, offset):
  prior = Σ byteSize[0..<spine]
  scaled = offset / charLength(spine) × byteSize[spine]
  return (prior + scaled) / Σ byteSize
```

A partial layout's displayed page count is max(measured pages, estimated pages).

### Relayout with anchor

```
invalidate(newSize):
  anchor = currentPosition
  generation += 1; cancel preloads; clear snapshots and layout cache
  toReload = chapters that had layouts ∪ {visible chapter}
  for each in parallel: preload(chapter)      // results tagged with generation
  if a newer invalidation started: return
  currentPage = pageIndex(for: anchor) ?? clamp(currentPage)
  announce
```

### Hit-testing

```
index(at point):
  p = (point − viewOrigin) / scale          // layout coordinates
  y = layoutHeight − p.y                    // Core Text y
  line = line whose [baseline − descent, baseline + ascent] contains y, else nearest
  x0 = contentMinX + origin(line).x
  if p.x < x0 − 10 or p.x > x0 + width(line) + 10: return nil
  return boundaryIndex(line, p.x − x0)      // string index for position, corrected for negative kern
```

### Selection rectangles

For each line intersecting the range: x from the boundary offset of the intersection start to that of its end, y from baseline + ascent down to baseline − descent, converted to UIKit coordinates and scaled to the view. Vertical text swaps axes: the column's x band comes from ascent and descent, the y extent from the two boundary offsets measured from the column top.

### Manual justification

```
justify(line substring, available):
  natural = width(line) − trailingWhitespace(line)
  if lastLineOfParagraph or natural / available < 0.7 or natural ≥ available: return natural line
  clusters = grapheme clusters of the substring
  gaps = clusters without the last
  targets = spaces in gaps, if more than one
          else gaps not adjacent to CJK punctuation (all gaps when fewer than a third qualify)
  extra = (available − natural) / targets.count
  add extra to the kern of each target's final UTF-16 unit
  return new line
```

### Theme recolour

Copy the string; set theme foreground everywhere; restore author foregrounds from the marker attribute; in dark mode apply dark author foregrounds; drop run backgrounds equal to the old theme background; retarget block fills equal to the old background to the new one; in dark mode apply dark block fills; rebuild framesetter and per-page frames with the unchanged page ranges.

### CFI resolution (as the candidate does it, with Funston's completion)

```
parse(href):
  body = text between "epubcfi(" (case-insensitive, anywhere in the href) and the last ")"
  spinePart, docPart = split body at the first "!"
  spineStep = last component of spinePart: integer, optional [idAssertion]
  docSteps  = components of docPart: integer, optional [idAssertion], optional :offset[text assertion dropped]

resolveSpine(spineStep):
  if idAssertion: itemref whose id or idref equals it → its chapter
  else: itemref at index spineStep / 2 − 1 counting every itemref (linear or not) → its chapter
  else: chapter at that index directly

resolveOffset(docSteps, chapter):
  // Candidate: deepest step with an id the chapter's anchor table knows → anchorOffset + charOffset, clamped
  // Funston: walk element steps from the body (even steps = child elements, odd = text nodes),
  //          fall back to id assertions when the walk fails, then apply the character offset
```

### SMIL clock values

Accept `npt=` prefix; `h:mm:ss(.f)`, `mm:ss(.f)`, a number with `h`, `min`, `s` or `ms`, or a bare number of seconds. A fragment has a duration only when both clips exist and the end is after the start; the overlay's duration is the largest clipEnd.

### Narration offset map

```
align(narration, source):
  s = 0
  for each narration unit n at index i:
      while source[s] does not match n: s += 1       // whitespace matches whitespace; else equality
      map[i] = s; s += 1
  map[count] = s
sliceForStart(k): drop the first k entries                 // never re-align a suffix
```

### Read-aloud highlight placement (candidate) and Funston's replacement

Candidate: search the page's range case- and diacritic-insensitively for the utterance text; when an expected offset is known and the chapter matches, continue while the distance to the expected offset decreases and keep the nearest occurrence; wash that range with the selection-rect routine. Funston: take the utterance's chapter range from the map directly and wash it; search only as a fallback when the layout's text differs from the narration source.

### Box-model engine (reserved)

Fragmentation and viewport algorithms of the box-model engine are reserved for the same later commit as YUE-65 to YUE-80.

## Data model and persistence

### Reading position

One JSON file per book under the app's reading-position directory, named by the book id, containing the spine index, the UTF-16 character offset and an optional translation offset. Writes are debounced 300 ms after each settled page turn, scroll commit, jump or mode switch; restoring never writes; closing the reader cancels the debounce and writes synchronously. A second store (one JSON per book, base64 of the book id as file name, 1 s debounce, ISO 8601 timestamp) exists for TXT and migration. Positions are also pushed to a cloud store, debounced. The library record separately stores a progress fraction for the bookshelf. Fixed-layout offsets are keyed by a per-open session id and do not survive a reopen.

### Bookmarks and annotations

A list per book record, each entry: UUID, chapter index, chapter title, position (spine, offset), length in UTF-16 units (0 for a page bookmark), kind (bookmark, underline, highlight), date, note, excerpt, optional style and colour. Legacy entries with separate spine and offset keys are migrated on decode. The list is sorted by position then date. A text annotation is the same record with a non-zero length.

### Book identity

A UUID assigned at import; the EPUB is copied under that UUID; the spine cache (titles, hrefs, byte sizes, encryption entries, schema version 2) is a JSON file keyed by the file name without extension; no content hash and no package identifier participate. See YUE-56.

### Relation to Funston's book_positions

Funston stores one Readium locator JSON per (identifier, file name). The candidate's identity is strictly weaker than a locator (no CFI, no progression, no text context) but maps onto it: a locator for Funston's own renderer can carry the spine item's href, a CFI computed from the DOM position of the rendered offset, a progression fraction, and the (spine index, UTF-16 offset) pair as the renderer's private key inside the locator's locations, plus the package's unique identifier and dcterms:modified for edition matching. That keeps the existing table and the existing debounced-save code in the EPUB controller. The merged spec should require the rendered-text offset to be recomputable from the XHTML so that a different file of the same book falls back to the CFI, then to text context, then to progression.

## Accessibility

What exists is YUE-46. What a VoiceOver reader needs and the candidate lacks, each verified by reading the page views and searching the whole app for the relevant APIs:

- No elements below the page. Funston's PDF reader exposes one element per recognised line with a live frame; the candidate exposes one element per page whose label is the entire page text, so VoiceOver reads a page as one utterance, touch exploration cannot find a line, and the rotor's characters, words and lines navigation runs over one giant label. Funston shall expose at least one element per block (paragraph, heading, list item, image, table) and preferably per line, with frames derived from the same line geometry the selection code uses, in reading order, and shall keep the page container's start and end announced.
- No heading trait, no link elements. Headings are text; links are not elements, so a VoiceOver user cannot find or activate a link except by the whole-page activate, which opens the menu. Funston shall give headings the header trait, expose each link as an element with the link trait and an activate action that follows it, and expose footnote references as links whose activation opens the note.
- No image elements. Inline and block images are drawn into the page; their alt text is reachable only by a sighted tap into the preview. Funston shall expose each image as an element labelled with its alt text (or "image" when absent) and offer the preview as an action.
- Tables are bitmaps. The alternative string exists but is not exposed; Funston shall expose cells as text elements.
- No selection through VoiceOver on the legacy engine; the browser engine adds a "select text" action that selects the first fragment. Funston shall support the system text-selection rotor or actions to select the current element and extend by sentence.
- No language per run (YUE-23), so VoiceOver pronounces every book in the device voice. Funston shall set the language attribute from `xml:lang` so VoiceOver switches voices.
- No Dynamic Type. The font size is a setting (18 pt default); nothing in the reader pipeline reads the preferred content size category (the only uses are in chrome, a footnote popover and a search list). Funston's EPUB controller already maps Dynamic Type to a scale; the merged spec shall make the base size follow the body text style with a per-book override.
- Focus after a page turn relies on a screen-changed notification posted on view appear, which announces the whole page; with per-line elements Funston shall post a layout-changed notification focused on the first element of the new page.
- Read-aloud and VoiceOver are independent; the one VoiceOver check in the TTS module only annotates a timing log. The merged spec shall define how Speak Screen, Speak Selection and the app's own read-aloud coexist, and how the read-aloud highlight relates to VoiceOver focus.
- Reduce Motion is honoured for the pull-down bookmark animation only; page-turn animation style is a setting with a "none" option.
- Chrome (toolbar, panels, voice picker) is labelled per the project's design checklist, including a record of three shipped VoiceOver bugs in those surfaces; that part is adequate and not the subject here.

## Malformed input and failure behaviour

Verified in the candidate, grouped by stage.

Container and package:
- Missing EPUB file: the open fails before Readium; the reader clears its document and stops loading with a log line; at import with validation on, the copied file is removed.
- Not a zip or not a container: a parsing error, same outcome.
- container.xml missing: resource not found; malformed or without a rootfile: parsing error; a second rootfile is ignored.
- Package document missing or in an unsupported encoding: resource not found or parsing error.
- Package document malformed: the regex scanner is tolerant; missing manifest or spine produce empty structures; an itemref with an unknown idref is dropped and shifts CFI fallback indices.
- Empty TOC: spine-derived chapters; empty reading order after the HTML filter: unfiltered order; still empty: one pseudo-chapter and nothing to lay out.
- TOC entry pointing outside the spine: attached to chapter 0; TOC fragment not found: jump lands at chapter start, entry excluded from current-entry highlighting.
- Chapter resource missing: a read-failed error; the chapter build throws (build failed outcome).
- Chapter in an unknown encoding: decoded as Latin-1, mojibake, no error.
- Corrupt spine cache: decode fails and the list is recomputed; malformed viewport string: ignored.
- encryption.xml present but unreadable: open fails; unknown algorithm: bytes handed through encrypted.
- Remote archive: zero content length, short tail, authentication or range failure all fail the open; no unbounded GET is issued; a changed version cannot reuse the old spine cache.

Chapter build:
- XHTML that fails to parse: empty chapter; "built empty document" logged; blank page with the chapter title; no crash.
- A chapter whose text is empty but has a body background image: one page with no text range.
- Unknown elements: generic block or inline by resolved display, children preserved; only an allow-listed set of attributes is kept.
- Deeply nested markup: plain recursion, no depth limit (YUE-85).
- A 5 MB chapter: no size cap; the two-phase path applies above 20,000 characters; large base64 payloads are lifted before parsing; no measurement exists at that size.
- Missing or undecodable image: logged with the URL (and byte count on decode failure); a blank square of up to 180 points is reserved and nothing drawn; alt text is not shown.
- Image source that is http, https or data: inside an EPUB chapter: passes the resolver unchanged and is expected to fail the archive lookup (not run).
- SVG file in an img: handed to UIImage(data:), expected to fail, blank square (not run).
- Inline SVG that fails to rasterise or times out (7 s): alt text in brackets in the secondary colour, or nothing when alt is empty.
- MathML that fails to convert or render: alt text in brackets when it is non-empty, differs from the LaTeX, is at most 80 characters and is not a boilerplate phrase, else a generic bracketed word.
- Stylesheet that fails to load or is empty: skipped with a log; remote import: removed with a diagnostic; import cycle: removed with a diagnostic; a `@font-face` block the parser cannot read: logged and skipped.
- Font fetch or registration failure: negatively cached per URL, logged, next declared face tried, text falls back to the cascade; a PostScript name collision is detected by comparing glyph maps and the embedded subset is renamed.
- `display: none` and the hidden attribute (except until-found): the subtree is dropped before any node or page break is emitted.
- Script, style and noscript text: never becomes content; head style text is collected as CSS.
- A very long single word: default Core Text wrapping, no special handling.

Layout and engine:
- A preload that is cancelled is reported as cancelled, not failed; a build error is logged with the error; a chapter out of range is reported as such; a layout superseded by a newer generation is retried at most twice.
- A zero-length visible range from the framesetter (unbreakable content wider than the column) advances one character so pagination terminates.
- The browser engine: unsupported SVG, unsupported layout property, image-only document, empty renderable content, resource failure, layout failure, timeout (5 s) and active translation each fall back to the legacy engine with a named reason; in a debug forced mode they publish a one-page diagnostic instead.
- A tap that maps to no character falls through to page turning rather than being swallowed.
- A memory warning drops all but the current chapter's layout, every snapshot, every preload and every built document, but not decoded images or the paginator's dictionary.
- A surrogate half at a selection boundary is treated as "stop trimming", never force-unwrapped.

Read-aloud:
- No voice for the utterance's language: a voice-unavailable error, an alert, state cleared.
- Synthesizer cancellation without a preceding media-services reset: treated as a voice failure, not retried.
- Empty chapter at start: start fails with an anomaly, the reader jumps to the chapter if asked and requests a fetch.
- Chapter still loading at a boundary: waiting state; a failed fetch aborts the wait through the engine's stop path; a cancelled fetch waits for the re-request; a chapter laid out but empty aborts with an anomaly.
- Audio session activation failure: start aborted with a message.
- Text that produces no utterances (all punctuation): a warning, nothing plays, the coordinator stops.
- Media overlay audio URL that cannot be resolved: a localized message in the panel.

## Test fixtures and vectors

Public fixtures (none of the candidate's are copied):

- W3C EPUB 3 test suite: https://github.com/w3c/epub-tests (per-feature content documents with expected results; use the container, page-progression-direction, rendition, nav and CSS tests).
- IDPF EPUB 3 samples: https://github.com/IDPF/epub3-samples (Moby Dick with nav and page list; cc-shared-culture with media overlays and video; childrens-literature with ruby and footnotes; regime-anticancer-arabic and haruko-html-jpeg for RTL and vertical writing).
- Project Gutenberg via archive.org originals, for example item manandmaid20512gut, file pg20512-images.epub (EPUB 2 with NCX, `pre` poetry, `hr` scene breaks, images with alt).
- Standard Ebooks (https://standardebooks.org): EPUB 3 with semantic inflection, `epub:type="noteref"` endnotes, embedded fonts and `@media` rules.

Vectors written from the specifications, each with an expected result an implementer can check without this document:

1. Position round trip: open the fixture, go to spine 3 offset 1,234, change font size 14 → 24 → 14, assert the first visible character offset is 1,234 on the page containing it and that the page's start ≤ 1,234 < next page start.
2. Neighbour walking: for every page of a 50-page chapter, next(previous(p)) == p and previous(next(p)) == p; at chapter boundaries the pair is (spine ± 1, 0 or sentinel).
3. Partial layout: a 100,000-character chapter: after the first-page install, next(page 0) is the first unmeasured offset; after the full install it is page 1's start, and the two are equal.
4. Forced breaks: four `h2 { page-break-before: always }` sections yield exactly four pages plus overflow, no blank pages.
5. Keep together: a decorated 6-line block with `break-inside: avoid` starting 3 lines before a page end begins the next page.
6. Whitespace: `<p>\n   The\n   quick\n</p>` renders "The quick"; `<p>a&nbsp;b</p>` keeps a non-breaking space and never breaks between a and b; `<pre>` keeps its newlines.
7. Cascade: `p{color:red} .x{color:blue} p.x{color:green}` with `<p class="x" style="color:black">` renders black; add `!important` to the first rule and it renders red.
8. Dark palette: `@media (prefers-color-scheme: dark){ p{color:#eee} }` applies only in dark appearance; relayout count is zero on the switch.
9. Links: `<a href="ch2.xhtml#n">` from ch1 lands on the page containing `id="n"` in ch2; `<a href="#missing">` is flagged; `<a href="kindle:embed:0001">` does nothing; `mailto:` opens Mail.
10. Images: 4000 × 3000 in a 350-point column draws 350 wide; alt shown on a missing file; `<figure>` image centred; a left float wraps three following lines; a 400 × 3000 image fits a landscape page.
11. Ruby: two `rt` yield two annotations; `rp` content invisible.
12. Fonts: regular plus bold `@font-face`: bold runs use the bold file (check the resolved PostScript name); only-regular family: synthetic bold; a family referenced by no element is never read from the archive (instrument resource reads).
13. Justification: a justified paragraph's last line is natural width; a line under 70 percent coverage is natural; added space never precedes "，" or follows "「".
14. Theme: switch appearance mid-chapter; page ranges identical; author-coloured runs unchanged.
15. Selection: long press selects the trimmed paragraph; dragging handles across each other keeps a valid range; a touch 30 points beyond the line end does not select.
16. Annotations: overlapping same-colour highlights merge; a tap within two characters finds one; underline rects are one per line.
17. Bookmark survival: bookmark page 4 at 18 pt, switch to 24 pt, the page containing the saved offset is bookmarked and the old page is not.
18. Container: two rootfiles → the first of the package type; a bad idref → warning and stable CFI indices; a UTF-16 chapter with BOM decodes; a mislabelled chapter → diagnostic.
19. Navigation: Moby Dick's page-list offers "go to page 12"; a TOC entry to a non-spine resource is flagged; an NCX with gaps in playOrder still lists every navPoint in document order.
20. CFI: epubcfi(/6/4[chap01]!/4/2/1:10) resolves as in YUE-52; a CFI with no ids resolves by element steps; a range CFI is rejected.
21. Media overlay: cc-shared-culture's first chapter highlights par by par and turns the page; a par with clipEnd < clipBegin is skipped with a diagnostic.
22. Read-aloud: three sentences in one paragraph are three utterances; pause and resume continues from the paused word; a chapter boundary with the next chapter unbuilt continues without a gap beyond the build; a French `lang` run is spoken in French.
23. Accessibility (Funston targets): every paragraph, heading, image and link on a page is a VoiceOver element in reading order; headings carry the header trait; the container announces start and end; a page turn moves focus to the new page's first element; no element has an empty label; frames lie within the page bounds.
24. Progress: chapters of 10, 90 and 10 KB: progress at chapter 2 start is between 8 and 10 percent; scrubber at 50 percent lands in chapter 2.
25. Memory: open a 300-chapter book, read 20 pages, trigger a memory warning; resident layouts equal one, snapshots zero, image cache empty; reading on rebuilds without a visible position change.
26. Bounded work: a chapter nested 10,000 divs deep and a chapter exceeding the time limit each produce a diagnostic, not a hang or a crash.

What the candidate's own tests cover, in prose, so the merged spec knows which behaviours have precedent: position walking within, across and at the ends of chapters and under partial layout, and that re-paginating an earlier chapter does not move a step destination; write gating of the page controller and page transition queueing; anchor compensation in scroll geometry; bookmark stable positions and legacy decode; annotation merge rules in the store; CFI parsing, spine id assertions and deepest-anchor offsets; the private partial CFI round trip; Calibre CFI mapping through CJK, emoji, collapsed whitespace, comments and rasterised tables, with rejection of ambiguous text; anchor offsets for ids on headings, divs and spans; first-letter selector parsing; EPUB image caching (one archive read per distinct image per chapter) and tall-image line heights; pronunciation hints from PLS and SSML through to the utterance; interactive placeholders; authored font cascade fallback; writing-mode pagination, vertical images, ruby and RTL frame progression; CJK line-break protection; chunk slicing with image lines; large-EPUB benchmarks and style resolver performance (raw bytes only for obfuscated resources, known-missing fonts not read, lazy font loading); SMIL clock values and fragment extraction; fixed-layout metadata, Hebrew RTL defaults and CJK-with-rtl vertical promotion; percent-encoded spine hrefs; combinator selectors and comment handling; remote archive reads without unbounded GETs; chapter document deduplication and eviction; chapter load state machine (cancelled versus failed); refresh transaction classification; snapshot reuse and invalidation; TTS chunking, offset maps, narratable text cleanup, highlight occurrence selection, speaker attribution, role casts, start planning with empty chapters, interruption and cancellation recovery; and about forty browser-engine files covering capability scanning, determinism, float layout, justification, cluster line breaking, ruby, source mapping, white-space modes including pre and pre-wrap, text-indent, used-value resolution, selection contract, fragment submission, memory lifecycle and stylesheet ingestion diagnostics.

## Things to avoid

- Storing or comparing a page index as identity, in any path, including "just for the data source". Every one of the candidate's page-turn incidents came from this.
- Treating h1 as "the chapter title" for EPUB: resizing it, spacing it or hiding it by a reader setting.
- Collapsing U+00A0 to a plain space.
- Tagging every Latin run with one language; read `xml:lang`.
- Ignoring `pre`, `code`, `dl`, `dt`, `dd`, `center`, `small`; Gutenberg needs them.
- Dropping `vertical-align` for `sup` and `sub`; footnote markers must rise.
- Ignoring CSS `text-decoration` and the `font` shorthand; both are common in Gutenberg stylesheets.
- Ignoring `ol` `start`, `value`, `reversed` and `type`.
- Letting a run delegate image exceed the page height; scale to the content height or move it to its own page.
- Rasterising tables when the reader has a VoiceOver user; lay out cells as text.
- Shipping one accessibility element per page as the end state.
- Using font size plus line spacing as the line grid instead of the real line box.
- Retaining every page's `CTFrame` for every cached chapter without a budget.
- Keeping two renderers with per-chapter admission. The candidate had to; Funston has not shipped yet and should pick one model.
- Parsing the package document twice (a full parser plus regexes) and the chapter twice (an HTML parser and a plain-text extractor with different rules).
- Mapping an unresolvable TOC entry to chapter 0, or a missing fragment to offset 0, silently.
- Decoding chapters with a Latin-1 fallback that cannot fail.
- Handing an audio URL on a private scheme to AVPlayer without a resource loader; media overlays never played from the archive.
- Keying caches by file name instead of content or package identity.
- Two overlapping position stores with different debounce and file naming.
- Locating the read-aloud highlight by text search; carry the utterance's range.
- One utterance per paragraph; readers need sentence granularity for skip and highlight.
- Choosing the speaking voice by script sniffing instead of the run's language.
- Reading reader settings from a global singleton at draw time (the candidate snapshots them into an immutable value precisely because it had to stop doing this).
- Hiding failures behind `try?`; the candidate names every exit from a chapter build and logs it, after a history of silent placeholders.
- Timing-based waits to let state settle (the candidate's own rule, learned from a reverted rewrite); its remaining 16 ms poll for the first layout is a known debt.
- Loading and decoding every image synchronously inside the chapter build; the project measured it at 97 percent of render time before caching.
- Fixed CJK justification constants and heuristics copied without the script check; they are tuned for Chinese novels.
- Unbounded caches (the paginator's dictionary, de-obfuscated resource bytes, MathML bitmaps) that a memory warning does not touch.

## Open questions for the merged spec

1. Attributed-string pagination or box-model layout? The candidate shows the ceiling of the first and the cost of the second. Decide before the renderer is written; the decision changes which of YUE-11 through YUE-29 are built in and which are worked around.
2. Position format: adopt (spine index, UTF-16 offset in rendered text) as the renderer key inside a Readium-style locator, and define the fallback order (CFI, text context, progression) when the file changes (YUE-56).
3. Justification default: the candidate justifies by default; Funston's EPUB controller aligns to the start edge for low vision. Make it a setting and specify which lines are never stretched.
4. Line grid versus orphan and widow control: choose one, or adopt the browser engine's fragmentation rules if both are required.
5. Dynamic Type mapping: base size from the body text style times a per-book multiplier, with the candidate's defaults as calibration (18 pt, 1.65 line height).
6. Footnotes: the EPUB 3 vocabulary plus which authoring conventions (the list-item class convention; a same-document link to a short block)?
7. Which `@media` queries beyond the colour scheme does Funston evaluate (`screen`, `max-width`, `orientation`)?
8. Memory tiers: how many chapters of layout and how many page frames on a 4 GB phone versus the M2 development host; the candidate's tiers are a starting point.
9. Table rendering for VoiceOver: text cells (preferred) versus bitmap plus alternative.
10. Read-aloud and the music player: one audio session owner, and how the read-aloud highlight relates to VoiceOver focus and Speak Screen.
11. Progress units: bytes (stable before layout, markup-weighted) versus rendered characters (accurate, needs every chapter parsed); the candidate uses bytes and plans a unit map.
12. Does Funston need media overlays at all for the Gutenberg corpus, or is detection plus "this book has narration" enough for the first release?

## Clean-room statement

This document describes behaviour observed in the Yuedu reader and its YueduCoreText package at the commits named in Provenance. It contains no code, comments, docstrings, string literals, test data or documentation text from either repository. Pseudocode in Algorithms was written from my understanding of the behaviour, not transliterated from the source. The candidate's internal type and file names appear only in "Architecture in our words" and its source map, as orientation for the parent session's verification. Four survey agents read parts of the source read-only and reported behaviour with file and line pointers; their reports were re-expressed here and nothing from them was pasted. The candidate's code was cloned into a scratchpad directory outside the Funston worktree, never built, never run, and no file from it was copied into the worktree. Fixtures named above are public-domain or openly licensed test corpora identified by URL; none of the candidate's fixtures or expected-output tables were reproduced. An implementer working from this document alone will not have seen the candidate's expression.

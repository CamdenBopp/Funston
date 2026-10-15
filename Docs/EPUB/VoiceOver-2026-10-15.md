# VoiceOver run, 2026-10-15

Phase A step 9. Spec section 14.6: the element-model experiment first, then the checklist.

## Build

- Branch `claude/epub-phase-a-e25ed0`, commit (filled in below).
- Switches: `epub.a11yModel` = `page` (Books model: one reading-content element per page) or `blocks` (one element per block with text navigation links); `epub.a11yExperiment` = true writes the log (`Documents/epub-a11y-<time>.log`) and mirrors it to OSLog category `EPUB.a11y`.

## Element-model experiment (APL section 11, V1 to V6)

Book: Man and Maid (Gutenberg 20512), chapter V. Read All from the first paragraph of the chapter, three automatic page turns.

| Variant | Model | Read All continues across the turn | Focus after the turn | Lines rotor crosses the page | Notes |
|---|---|---|---|---|---|
| V1 | page, reading content, causesPageTurn | | | | |
| V2 | page, plus UITextInput | | | | |
| V3 | blocks, trait on the last block, no links | | | | |
| V4 | blocks, with text navigation links | | | | |
| V5 | blocks, fresh page view per turn | | | | |
| V6 | page, rotors only | | | | |

Log excerpts per variant: (every accessibilityScroll call, pageScrolled post, reading content call, and the focused element one second after each scroll).

Outcome: both models carry Read All across pages on the simulator; on the iPhone the page model did, and the per-block model turned pages but lost its place at each turn (details below). Camden chose the per-block (paragraph) model; its page crossing is fixed in the next change and re-verified below.

## Checklist (APL-37 plus STD section 7.4)

Books: Man and Maid chapter 1, Moby Dick (Standard Ebooks) chapter 1, Poems of the Great War, Elektra, a Factbook page.

| # | Item | Simulator | iPhone | Notes |
|---|---|---|---|---|
| 1 | Line-by-line touch exploration lands on real text | | | |
| 2 | Block-wise swipes in reading order | | | |
| 3 | Lines rotor, including across a page | | | |
| 4 | Characters and Words rotors | | | |
| 5 | Read All continues across pages and chapters | | | |
| 6 | Three-finger swipe turns the page and announces "Page p of q" | | | |
| 7 | Focus after a manual turn is the new page | | | |
| 8 | Headings rotor and levels | | | |
| 9 | Links rotor; link and note actions | | | |
| 10 | Images announce their alternatives | | | |
| 11 | Lists and tables announce their containers | | | |
| 12 | Notes open in a sheet and return | | | |
| 13 | Languages switch voices | | | |
| 14 | The adjustable page element increments and decrements | | | |
| 15 | Focus order equals document order | | | |
| 16 | No empty label | | | |
| 17 | Container start and end announced | | | |
| 18 | Page labels skippable | | | |
| 19 | Continuous mode: crossing at the chapter end | | | |

## Simulator run (iPhone 17 Pro, iOS 26.5, "Funston EPUB VO")

Driven with the ios-sim-voiceover driver (HID keyboard commands into guest VoiceOver, caption panel OCR for speech). Man and Maid opened from the Library through the real download path; layout set to page by page; model `page`; experiment log on.

- Reading order on the reader screen: Download, "Man and Maid" heading, Go to, Contents, "Reading page, Chapter 1, page 1 of 52, adjustable", then the page element, which VoiceOver speaks as the chapter title followed by the page text (observed in the caption panel).
- Rotor options on the page element: Characters, Words, Lines, Speaking Rate, Containers, Edit, Paragraphs (the custom rotor; Headings, Links and Images are absent on page 1, which has none).
- Lines rotor: each VoiceOver line step calls `accessibilityContent(forLineNumber:)` for the next line and speaks that line (caption: "The Project Gutenberg EBook of Man and Maid," then "by Elinor Glyn" then "This eBook is for the use of anyone anywhere"). Item 3 holds within a page on the simulator.
- Reading the page: VoiceOver calls `accessibilityPageContent()` twice on focus, then line content as it reads.
- Lines rotor across the page (APL open question 2, answered on the simulator): after the last line of page 1 (line 30), VoiceOver itself called `accessibilityScroll(.next)` on the page element; the reader turned to page 2 and posted `pageScrolled` "Page 2 of 52"; VoiceOver then asked for `accessibilityPageContent()` and lines 0 and 1 and went on reading line by line. So the Lines rotor does cross a page boundary through the trait and the scroll call. First build defect: the pager had replaced the page view controller, so the calls went to the stale page-1 element and VoiceOver re-read page 1 (log lines 34 to 40, repeated at the next boundary with "Page 3 of 52"). Fixed in the same step: under VoiceOver the same page controller shows the next page in place, so the element VoiceOver holds is the one that now has page 2.
- After the fix, verified on the simulator: with the Lines rotor, stepping past the last line of page 4 made VoiceOver call `accessibilityScroll(.next)`; the reader posted "Page 5 of 52"; the same page element answered `accessibilityPageContent()` for page index 4 and VoiceOver read on from its line 0 ("appartement last night…"), then crossed again into page 6 the same way. Item 3 (Lines rotor across the page) holds on the simulator under the page model.
- Read All (VoiceOver's "Read All From Current Item", Control-Option-A) under the page model: VoiceOver asked for the page content (page index 5), read it for 60 s, then called `accessibilityScroll(.next)` on its own; the reader posted "Page 7 of 52"; VoiceOver asked the same element for page index 6 and the caption panel 40 s later showed page 7's text being spoken ("value of things, but they make the charm of life, for one reason o"). Item 5 (Read All continues across pages) holds on the simulator under the page model. This contradicts the earlier simulator note for the per-paragraph probe; the difference is the reading content protocol on a persistent element.
- Per-block model, first attempt: with `epub.a11yModel` = `blocks` the page view still appeared to VoiceOver as one text element with the page text as its value (traits without the ones the reader sets), although the log showed the model switch and six block elements built. Cause: UIKit treats any view adopting UITextInput as a text element, whatever `isAccessibilityElement` and `accessibilityElements` say. Fix: the reading content and UITextInput conformances moved to a child "text surface" view that is the page element under the page model and hidden under the block model; the page view itself is a semantic-group container.
- Per-block model after the fix, on the simulator: the tree shows one element per block on the page ("Three charming creatures…", "I used to wonder in my salad days…", and so on). Read All ran from the Contents button through the blocks and across three page turns: at each last block VoiceOver called `accessibilityScroll(.next)` (log 17:43:32, 17:43:57, 17:44:16), the reader built the next page's block elements (4, 6, 7) in the same page view and posted "Page 8 of 52", "Page 9 of 52", "Page 10 of 52", and one second after each turn VoiceOver's focus was on the first block of the new page ("They spoke of the theatre…", "When they had departed…"). The caption panel showed page 9's text being spoken. Items 5 and 7 hold for the block model on the simulator as well.
- Defect found and fixed in the same step: an image block without alt text was labelled with the attachment character under the block model; both models now label it with the alternative or "Image", and the page model's line content replaces attachment characters with the alternative.

## iPhone 14 Pro Max (Camden's), first run, 2026-10-15 13:41 to 13:50

Installed from the device build (empty entitlements, automatic signing) and launched with the page model and the experiment log. The reading layout setting on the phone was still "Continuous Scroll" (the shared `pdf.readingLayout` default), so this run exercised the continuous surface, not the paginated page element.

- Camden, by hand, Read All in Man and Maid: "the reading flow is smooth without issues". The log's only scroll entry is a `continuous accessibilityScroll forward=true spine=1 offset=0.0` at 13:49:47, i.e. Read All had crossed into chapter two at its top through the surface's crossing, and the focus one second later was the "Reading page" element.
- Camden's one gripe: after "Reading page, controls visible, adjustable", swiping right onto the content "takes me back to the top of the chapter". Two defects behind it, both fixed in this step: the controls element's value ("Controls visible") and the position report ("Chapter V, page 3 of 12") wrote the same accessibility value, so the position was lost (the controls state now lives only in the custom action, as 14.3 says); and the continuous surface rebuilt its block elements as new objects whenever the window moved, so VoiceOver could not find its current element in the new list and landed on the first visible block, which right after a crossing is the chapter's top. Blocks now keep their element objects across rebuilds.
- Second device run, 13:54 to 13:57, page by page, page model (`-pdf.readingLayout pages`), Camden's hands, chapter IV (spine 1, 63 pages on the phone's text size). Read All crossed pages 19 to 24: at the end of each page VoiceOver called `accessibilityScroll(.next)` (direction 5) on the text surface; the reader turned the page in the same element and posted "Page 20 of 63" and so on; VoiceOver asked that element for the new page's content twice and read on; one second after each turn the focused element was the text surface (label "IV"). Two turns were three-finger swipes (direction 4, left = forward): the page turned and was announced; after one of them the focus one second later was the "Reading page" element, after the other the text surface. No position reset appeared in this run. Items 5, 6 and 7 hold on the device under the page model.
- Third device run, 18:00 to 18:02, page by page, per-block model, Camden's hands, chapter IV. Read All and three-finger swipes both turned pages (block elements rebuilt for each page: 11, 5, 11, 10, 3, 5, 7 blocks). Problems, in Camden's words: "Turning the page does not resume reading from the top and sometimes this turns two pages instead of one, and then only partially reads a paragraph block." The log shows why:
  - After a three-finger swipe (directions 3 and 4) VoiceOver's focus one second later was the "Reading page" element twice (18:01:19, 18:01:34) and a block in the middle of the new page once (block 160, 18:01:02), never the first block.
  - Read All turned twice in 1.8 s (18:01:57 and 18:01:59, both `.next`): after the first turn VoiceOver put its focus on the block that now sat where its old focus had been, near the bottom of the screen (block 188). That block was the page's last, it carried causesPageTurn, so VoiceOver read it (often the first part of a paragraph that continues overleaf) and turned again.
  - Cause: every page rebuilt its block elements as new objects, so the element VoiceOver held vanished at each turn and VoiceOver fell back to its own guess (same screen position, or the first element of the screen).
- Decision (Camden, 2026-10-15): keep the paragraph model ("I want to retain the paragraph model, just fix it"). The page model stays behind the switch for the record; the per-block model becomes the default once its page crossing is fixed and verified below.

## The paragraph model, rebuilt on persistent elements (evening of 2026-10-15)

What failed, in one sentence: every design that replaced the element VoiceOver held during a page turn lost Read All, whatever was posted afterwards. Runs on the simulator with VoiceOver driven step by step:

- Look-ahead element that turns the page when focused: swipes worked; Read All stopped after the first turned paragraph (VoiceOver kept reading its old list).
- Page-turn trait, last paragraph kept first after the turn: VoiceOver re-read it and turned again.
- Page-turn trait, layoutChanged to the new first paragraph: read it, then turned again.
- Page-turn trait, all-new elements, layoutChanged to the first: VoiceOver ignored the post and chose the paragraph where its old focus had been, the page's last, then turned again (pages 11 to 16 in a minute). This reproduced the iPhone failure on the simulator.
- WWDC26 session 219 shape (one UITextInput text view per paragraph, linked, trait on the last, fresh page per turn): VoiceOver turned the page and stopped; its paragraph had left the window.

What Apple's own frameworks do (decompiled with swiftdc from the iOS 26.5 simulator runtime): PDFKit's accessibility bundle builds each page's elements once and caches them (`_axPageViewElements`, reset only by `resetAccessibilityTree`); a node asks for page turning (the trait on the page's last node) only when the PDF view is paged (`pdfViewRequiresPageTurning`: a page view controller, or two-up); in continuous mode nothing turns pages because every element exists. UIKit's accessibility for UIPageViewController turns pages with `_setViewControllers:withScrollInDirection:animated:NO` and posts its scroll status.

The design now shipped, on that footing: page by page is a horizontal paging scroll view holding the pages of the current chapter and its neighbours; continuous is a vertical scroll view holding the same chapters stacked. Every paragraph is a persistent text element (a transparent view adopting UITextInput over its range, linked with the text navigation links) that is never rebuilt while reading; VoiceOver's list starts at the first paragraph of the shown page or the first visible paragraph; focus brings its paragraph's page into view; a three-finger scroll moves one page or screen, posts pageScrolled and moves focus to the first paragraph there; when reading enters another chapter the window reloads with the existing elements kept.

Simulator, step by step (iPhone 17 Pro, iOS 26.5), page by page: swiping in from Reading page lands on the shown page's first paragraph; swiping past a page's last paragraph lands on the next page's first and the page follows; Read All ran pages 19 to 22 and across the chapter III to IV file boundary without a stop or a repeat; the Lines rotor flows from one paragraph's last line into the next; the Reading page control keeps focus and speaks the new page. Continuous: swiping in lands on the first visible paragraph; Read All reads forward with the view following and the location advancing; the book loads once at launch.

Camden's iPhone 14 Pro Max, both modes, three-finger swipes, Read All and paragraph swipes: "that works beautifully".

## Continuous mode on the simulator

- Read All in continuous mode (page model switch is irrelevant there) reads the surface's block elements in order; as VoiceOver focuses each block the surface scrolls it into view and the settled report follows (log: settled offsets 0, 195, 576, 535 over a minute of reading). Blocks keep their element objects across window rebuilds after the fix above.
- One run that opened at a restored position deep in the book (chapter II, surface scrolled 12,115 pt down) listed the chapter's first blocks as elements, with the "II" heading's frame 12,115 pt above the viewport; after Read All the Reading page value had fallen back to "Chapter 1, location 1", the book's start. The element window was built from a stale scroll offset and VoiceOver's reading pulled the surface back to the top. Open point: the window must be rebuilt (and VoiceOver told with layoutChanged) after the restore sets the content offset; not yet fixed, logged for the continuous-mode checklist item.

## Open points


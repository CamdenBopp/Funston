# Study: epub.js, for the clean-room EPUB reader spec

Requirement ID prefix: EJS.

## Provenance

- Repository: https://github.com/futurepress/epub.js
- Commit read: eee359d0790002115a1156a9833c54f4bcd44c1d
- Commit date: 2026-03-23 (merge of pull request 1414)
- Package version in the tree: 0.3.93
- License: BSD 2-Clause ("Simplified BSD"), copyright 2013 FuturePress. The license file permits reuse with attribution; this study carries no code from it regardless.
- Method: shallow clone into the session scratchpad, read only. Nothing was built or run. No file from the clone entered the Funston repository.
- Dependency also read, for the annotation layer only: https://github.com/fchasen/marks (the "marks-pane" package epub.js draws highlights with), commit 8c7877addf213a234d8fea9c8e2fea095a089b01, 2022-01-27. Its license file was not in the shallow clone; its package metadata says MIT. Nothing from it is reproduced here either.
- Spec texts consulted: EPUB CFI 1.1 (https://idpf.org/epub/linking/cfi/epub-cfi.html), W3C EPUB 3.3 (https://www.w3.org/TR/epub-33/), EPUB 2.0.1 OPF and NCX (https://idpf.org/epub/20/spec/OPF_2.0.1_draft.htm).
- Issue tracker searched with the GitHub CLI on 2026-10-14. Issue numbers below are from that search; status is as of that date.

Everything named in the task exists in this tree. Two things are not quite what the task described: the "continuous manager" is a subclass of the single-section manager and shares most of its paging and location code, so the two are described together in places; and the SVG highlight layer is not in epub.js itself but in the marks-pane dependency named above.

Where this document says "verified", the behaviour was read in the source. Where it says "claimed", the README or API comments say so and the code was not followed to the end. Numbers quoted (150 characters per location, 800 pixel spread threshold, 500 pixel preload offset, and so on) are constructor defaults read in the source unless stated otherwise.

## What it is and why it matters to Funston

epub.js is a browser library. It unzips an EPUB in JavaScript, parses the container and package documents, and renders each spine item into its own iframe, laid out either as CSS multi-columns (paginated) or as a tall scrolling document. Position is expressed as EPUB CFI strings, progress as "locations" (synthetic positions cut every N characters of text), and the current page as a start CFI and end CFI derived by measuring which text is inside the viewport.

None of its rendering transfers to Funston: we will have no WKWebView, no iframes, no CSS. What transfers is the set of decisions a reflowable-book reader has to make and the exact way epub.js made them, good and bad:

1. How a position in a chapter becomes a durable string (CFI), how two such strings compare, and what breaks when the reader itself has inserted markup into the content.
2. How a book without page numbers gets a stable progress scale (locations) that can be computed once, persisted, and turned back into a position.
3. How "what is on this page" is computed from layout geometry. For Funston this is the question VoiceOver asks on every page turn and the question the position store asks every second.
4. How a continuous scroller inserts a chapter above the viewport without the reader seeing a jump, and how a resize puts the reader back where they were.

epub.js has been the most used open EPUB renderer on the web for over a decade. Its issue tracker is therefore a record of what readers notice: positions drifting after a font change, blank pages at chapter ends, locations that count nothing in an illustrated book. Section "Things to avoid" is built from that record.

Funston context that shaped this study: positions are stored today as Readium Locator JSON in the SQLite table book_positions (identifier, file_name, locator, updated_at). The PDF reader exposes each recognised line as one VoiceOver element with a computed frame, and that is the house style a native EPUB renderer will match. epub.js' "mapping" algorithm is the browser-side ancestor of exactly that: a walk from geometry to text range and back.

## Architecture in our words

Internal names from the candidate appear only here, as orientation for anyone reading its issue tracker.

- Book: opens the input (URL, binary, base64, or an unpacked directory), unzips when needed, loads container.xml, loads the package document, builds the spine, kicks off navigation parsing, and pre-creates replacement URLs for every non-HTML resource.
- Archive: a thin wrapper over a JavaScript zip library. Entries are found by percent-decoded path. Text entries come back as strings, binary entries as blobs with a MIME type looked up from the file extension.
- Container and Packaging: parsers for container.xml and the package document (OPF). Packaging produces a manifest map (by id), a spine list (itemrefs in order), metadata, the navigation document path, the NCX path, the cover path, and the index of the spine element within the package element (needed for the CFI base).
- Spine and Section: one Section per itemref. A Section knows its index, href, linear flag, properties, its CFI base component, and its neighbours. It loads its XHTML into a DOM, runs "content" hooks on that DOM, serialises it back to a string, runs "serialize" hooks on the string, and that string is what the view puts into an iframe.
- Navigation and PageList: parsers for the EPUB 3 nav document (toc, landmarks, page-list) and for the EPUB 2 NCX (navMap, pageList).
- Resources: splits the manifest into HTML, CSS and other assets; creates blob or data URLs for assets; rewrites CSS and XHTML text so relative asset paths point at those URLs.
- EpubCFI: parse, generate (from a DOM node or Range), resolve (to a Range), compare, and collapse. Supports an "ignore class" so that elements the reader injected (highlights) do not shift step counts.
- Locations: walks every linear spine item's text and emits a CFI every N characters. Converts between CFI, location index, and percentage. Serialises to a JSON array of CFI strings.
- Layout: from the viewport size, spread setting and flow, computes column width, gap, pages per spread, and the scroll distance of one "page". Applies the result as CSS to a section's body (columns for paginated, width or height for scrolled, a scale transform for fixed layout).
- Mapping: given a section's DOM and a visible range of the scroll axis, finds the first and last visible text and returns two CFIs.
- Managers: the "default" manager shows one section at a time and scrolls within it. The "continuous" manager keeps a list of section views, appends and prepends neighbours as the reader nears the edges, and removes far-away ones. Both report the current location by asking Mapping about each visible view.
- Views: a view owns one iframe for one section, sizes the iframe to the content's full width (paginated) or height (scrolled), and hosts the SVG highlight layer next to the iframe.
- Rendition: the object an application talks to. It owns the manager, the layout, themes, annotations, and the hooks. It turns display requests (href, CFI, percentage) into a section plus an in-section target, and it emits the "relocated" event.
- Themes: registers named stylesheets or rule objects, injects them into every section document, and applies per-property overrides (font size, font family) as inline styles on the body.
- Annotations: a store of highlight, underline and mark entries keyed by CFI range, attached to views when their section renders and detached when it unloads.
- Hooks: lists of functions run at named points of the pipeline; each may return a promise and the pipeline waits for all of them.

Everything runs on the browser main thread. Section loading is asynchronous (network or unzip), but DOM parsing, CFI work, mapping and location generation are synchronous once the text is in hand.

## Requirements

Each requirement has: the statement, why it matters, the public spec citation where one exists, edge cases, and how to test it. "Verified" and "claimed" are as defined in Provenance. Requirements say what Funston's implementation shall do; where that differs from what epub.js does, the difference is stated.

### CFI

#### EJS-01 CFI syntax accepted and produced

The reader shall parse and produce EPUB CFI strings of the form `epubcfi(<package path>!<document path>)` for points and `epubcfi(<package path>!<common path>,<start path>,<end path>)` for ranges, where each path is a sequence of `/<integer>` steps, each step may carry an `[<assertion>]`, and a path may end in `:<offset>` followed by an optional `[<text assertion>]`.

Why: this is the interchange format for positions and annotations. The merged spec will almost certainly store positions as CFIs, and other readers (Readium, Apple Books, Calibre, Foliate) produce the same grammar.

Spec: EPUB CFI 1.1 sections 2 and 3.1. Verified in the candidate: it parses exactly this subset; it rejects a string that does not begin with the `epubcfi(` wrapper (it returns a spine position of -1 rather than throwing), and it treats everything before the first `!` as the package path, everything after it as the document path, splitting the latter on commas for ranges.

Edge cases: a CFI with no `!` (a package-only CFI pointing at a spine item) is valid per spec; the candidate handles it only because the document path becomes empty. Nested indirection (`a!b!c`) is valid per spec (for example into an iframe inside a chapter) and the candidate does not support it; Funston need not either, but the parser shall reject it cleanly rather than misread it. Temporal (`~`), spatial (`@`) and text location assertions (`[text]` after an offset) shall be parsed and carried, not understood (see EJS-11).

Test: round-trip a table of CFI strings (see "Test fixtures and vectors") and assert byte equality; assert that malformed inputs produce a typed error, never a crash.

#### EJS-02 Step numbering follows the spec's chunk model, not the DOM's text node list

For a step inside a document, even integers 2, 4, 6 number the element children of the current node in order, and odd integers 1, 3, 5 number the character-data chunks between them: chunk 1 is everything before the first child element, chunk 3 is between the first and second child elements, and so on through chunk 2n+1 after the last of n child elements. A chunk exists at every such position even when it is empty. Adjacent text nodes and CDATA sections in one position are one chunk. Comments and processing instructions are ignored and do not split a chunk.

Why: this is where epub.js deviates from the spec, and it is the largest source of CFI incompatibility between readers. Verified: the candidate numbers text steps by the position of the DOM text node among its sibling text nodes. For an element whose children are [element, text], the spec gives the text step 3 and the candidate gives it step 1. For text split by a comment, the spec sees one chunk and the candidate sees two. The candidate's own "ignore class" machinery (EJS-10) partially implements merging, which shows the author knew merged counting was needed, but only applied it to injected elements. A CFI from Apple Books or Readium resolved by the candidate can therefore land in the wrong text node, and one produced by the candidate can mislead them. Issue 470 (open since 2016) is this bug seen through its XPath resolver; issue 1358 reports Readium CFIs not matching the candidate's, and a contributor's reply there points at issue 470 as the cause.

Spec: EPUB CFI 1.1 section 3.1.1, which states there is one chunk between each pair of child elements, that CDATA is included and comments ignored, and that insignificant whitespace is preserved.

Edge cases: whitespace-only text between block elements is a real chunk and counts; an element with no element children has exactly one chunk (step 1), even if it has no text at all; index 0 refers to a non-existent element before the first child and is legal to parse but shall never be generated.

Test: the vectors in "Test fixtures and vectors" include an element whose first child is an element, and a text run split by a comment; generation and resolution shall agree with the spec values given there, not the candidate's.

#### EJS-03 Character offsets count UTF-16 code units

The offset after `:` shall be a zero-based count of UTF-16 code units from the start of the chunk, and resolution shall interpret it the same way.

Why: interchange with every browser-based reader (including Readium's, which run CFI code in a web view) and with the candidate, all of which inherit JavaScript's string model. A Swift implementation that counts Characters (grapheme clusters) or Unicode scalars will drift by one for every emoji, flag, or combining sequence before the position. Verified: the candidate uses JavaScript string lengths and DOM Range offsets throughout, which are UTF-16 code units.

Spec: EPUB CFI 1.1 section 3.1.4 says a character offset refers to a position between UTF-16 code units, and the note there gives the DOM Range model as the reason.

Edge cases: an offset that splits a surrogate pair is representable; the reader shall round it to the nearest scalar boundary when turning it into a layout position but preserve it when re-serialising. An offset equal to the chunk length is valid (end of chunk).

Test: a chunk containing an emoji followed by a letter; the letter's offset is 2.

#### EJS-04 Escaping with the circumflex

In assertions, the characters `[`, `]`, `^`, `,`, `(`, `)`, `;` and `=` shall be escaped with `^` on output and unescaped on input, and splitting a CFI on `!`, `,` and `[` shall respect escapes.

Why: ids and text assertions can contain these characters. Verified: the candidate does not implement escaping at all (its contributor noted this in issue 1358); it splits on `,` and `!` with plain string splitting, so an id containing a comma breaks its range parsing.

Spec: EPUB CFI 1.1 sections 2.2 and 2.3.

Test: an id `a,b` round-trips as `[a^,b]` and the step still resolves.

#### EJS-05 Package-level component derivation

The package path of a CFI for spine item k (zero-based position among itemref children) shall be `/<2 × (position of the spine element among the package element's child elements + 1)>/<2 × (k + 1)>` with the itemref's `id` attribute as an assertion when it has one. For a conformant package document the first step is `/6` (metadata, manifest, spine), but it shall be computed from the actual element position.

Why: the base must match what other readers produce for the same book, and real package documents sometimes put the spine elsewhere (or interleave a guide or collection). Verified: the candidate computes the spine element's index among element children and the itemref's zero-based position; it uses the itemref `id` (not the `idref`) as the assertion, which is what the spec intends.

Spec: EPUB CFI 1.1 section 3.1.1 and the examples in section 1.1; the assertion is the id of the itemref element.

Edge cases: an itemref without an id gets no assertion; parsing shall extract the spine position from the second package step without requiring the assertion. Reordering the spine invalidates every stored CFI; this is inherent and the merged spec should key stored positions by a hash of the spine order (see "Data model and persistence").

Test: for a package with the spine third, item 2 (zero-based 1) with id `c2` gives `/6/4[c2]`; for a package with the spine fourth, `/8/4[c2]`.

#### EJS-06 Generation from a point or range

Given a document position (node, offset) or a pair of positions, the reader shall produce a CFI by walking from the node to the document element, emitting one step per ancestor using the EJS-02 numbering. For a range, the two step lists share their common prefix; the common prefix becomes the common path and the remainders become the start and end paths. If the two positions are equal the result is a point, not a range. A position given as (element, child index), which is how DOM ranges express "before the k-th child", shall first be normalised to the start of that child in the element's chunk-and-element sequence (a chunk step with offset 0, or an element step) and never encoded as a character offset.

Why: every saved position, every highlight, every search hit is generated this way. The common-prefix factoring is what keeps range CFIs short and sortable by their start. The normalisation rule matters because selections made by "select all children of this element" arrive as element-container positions: the candidate encodes such a position as the element's step, a chunk step `/1`, and the child index as if it were a character offset, which is issue 1187 ("returns the CFI of only the first letter"). Verified in its path generation, where any non-null offset is attached as a terminal offset and a chunk step is appended if the last step was not already one.

Spec: EPUB CFI 1.1 sections 3.1.1 (steps) and 3.4 (simple ranges).

Edge cases: the document element (html) is the implicit origin of the document path and is not itself a step; the first step selects among its children, so body is `/4` in the spec's examples. Verified: the candidate stops its walk when a node's parent is the document, so html is not stepped. An id assertion is emitted for any ancestor that has an id. If start and end are in the same text chunk at different offsets, the common path includes the chunk step and the start and end paths are offsets only; the candidate instead leaves the chunk step in both the start and end paths (its common-prefix check treats a last step with differing offsets as not shared), which is also valid syntax. The parser shall accept both forms and the comparator shall treat them as equal.

Test: the range vector in "Test fixtures and vectors".

#### EJS-07 Resolution prefers id assertions, then verifies

When resolving a step that carries an id assertion, the reader shall look the element up by id first and fall back to the indexed child only when no element has that id. When the indexed child exists but its id differs from the assertion, the id lookup wins and the mismatch shall be recorded as a diagnostic.

Why: documents change between generation and resolution: a different build of the same Gutenberg book, or a reader that injected elements (scripts that add a div at the top of body were the trigger for the candidate's change, issue 561). The id is the robust anchor; the index is the fallback. Verified: the candidate's manual walker checks the id first and the index only otherwise, and stops the walk when a step cannot be satisfied rather than throwing. Its XPath resolver requires both the position and the id to match, which is stricter and is the path that fails in issue 470.

Spec: EPUB CFI 1.1 section 3.1.2 (the assertion lets a reading system detect that a location is not the intended one) and section 3.5 (intended target location correction: check assertions, search for the id when they fail, and correct the CFI; a CFI whose asserted id cannot be found is invalid, and a reading system that cannot check an assertion must ignore it). Funston departs from the "invalid" outcome deliberately: fall back to the indexed child with a partial-resolution flag, because a book rebuilt by Gutenberg may have renamed an id while keeping the structure, and a bookmark that lands one paragraph off is better than one that is refused.

Edge cases: duplicate ids in the document (common in bad EPUBs): take the first in document order. A step past the end of the children: stop and report the deepest node reached, with a flag that the CFI was partially resolved.

Test: resolve a CFI against a copy of the document with an extra element inserted at the top of body; the id-bearing step still finds its element.

#### EJS-08 Offset overflow recovery

When a terminal offset is larger than the length of the resolved chunk, the reader shall carry the surplus forward through the following text in the same chunk model (which, for the candidate, includes injected elements' text) until a position fits, and resolve there. If the document ends first, resolve to the end of the last text.

Why: the chunk model in EJS-02 merges text that the DOM may split. An offset computed against the merged chunk can exceed any one DOM text node's length. The candidate hit this with highlights that split text nodes and added a recovery pass (it catches the Range error and walks forward through siblings, subtracting lengths). Issue 1000 ("no child at offset") is the uncaught variant. A native text model that stores each chunk contiguously avoids the problem, but imported CFIs from other readers still need the tolerance.

Spec: none; this is implementation hardening.

Test: generate a CFI for offset 40 in a 60-character chunk, split the chunk into two text nodes at 10, resolve: the position is the 30th code unit of the second node.

#### EJS-09 Comparison by raw step integers, assertions ignored

Two CFIs compare as follows: strip all bracketed assertions; compare step by step, earlier steps dominating; at each step compare the raw step integers (not decoded indices, so a text step 1 sorts before an element step 2 at the same depth); if one runs out of steps first it is earlier (a less specific CFI precedes a more specific one that extends it); then compare terminal offsets numerically, a missing offset sorting before 0. For a range CFI, compare using its start (common path plus start path). Package paths compare first, so items earlier in the spine are earlier.

Why: locations (EJS-14) and page lists are binary-searched with this comparator, and the "which bookmark is first" question needs it. Verified: the candidate compares decoded indices instead of raw integers, so a text chunk at step 1 and an element at step 2 both decode to index 0 and compare equal; it then falls through to "shorter is earlier" and returns the wrong order. Issue 1200 reports exactly this with a real book. Everything else about its comparator matches the rule above, including spine position first and range-compares-by-start.

Spec: EPUB CFI 1.1 section 3.2 (sorting): unescape, drop assertions, earlier steps more important, offsets in natural order, step types ordered.

Edge cases: comparing a CFI that has a `!` with one that has none at the same depth: the spec orders the indirection step type above the child step type; Funston will not generate such pairs but shall not crash on them. Different spine items are decided by the package path before anything else.

Test: the compare vectors in "Test fixtures and vectors", which include the issue 1200 shape.

#### EJS-10 Reader-inserted markup never shifts step counts

CFIs shall be generated and resolved against the parsed document model, never against a decorated copy that the renderer has modified for display (highlights, search hit markers, footnote popovers, VoiceOver anchors). If the renderer must annotate the model, those annotations shall live in a separate layer keyed by position, or the CFI code shall be given the set of injected nodes to skip.

Why: the candidate renders into live HTML and its highlight implementation of 2016 wrapped text in span elements inside the content. That split text nodes and added elements, which shifted every step after the insertion point and every offset in the split node. Its fix was an "ignore class": when generating a CFI, elements with that class are skipped, their text is treated as part of the surrounding chunk, and offsets inside them are added to the preceding text's length; when resolving, the same class is used to walk a merged view of the children. Verified in generation, position mapping, offset patching and resolution. Its test fixtures cover a text node inside a highlight, a highlight node itself, a range past a highlight, a range between two highlights, and a range starting inside one highlight and ending after it. The lesson for a native renderer is simpler: keep the content model immutable after parsing, keep every decoration in a side table, and the whole class of bugs disappears. The current highlight layer in the candidate (SVG overlay, see EJS-47) already follows this principle; the ignore class remains for third-party annotators that still inject spans.

Spec: none; the spec assumes CFIs are computed against the publication's own content.

Test: generate CFIs for a page, add a highlight and a search marker over it in the display layer, regenerate: identical strings.

#### EJS-11 Unsupported step types parse and are carried, not rejected

Temporal (`~<seconds>`), spatial (`@<x>:<y>`) and text location assertions (`[pre,post;s=b]`) shall be parsed into the CFI model and preserved on re-serialisation, but the reader may ignore them when resolving.

Why: fixed-layout and media-overlay books, and other readers' CFIs, use them. The candidate documents that it does not implement any of them, and its parser treats the text after an offset's `[` as an assertion string without interpreting it; it drops `~` and `@` entirely. Rejecting such CFIs would make an imported bookmark unusable rather than slightly imprecise.

Spec: EPUB CFI 1.1 sections 3.1.5 to 3.1.9.

Test: a CFI with a text assertion round-trips byte for byte; one with a spatial offset resolves to the element step and reports the spatial part as unused.

### Locations

#### EJS-12 Synthetic locations by character count

The reader shall be able to compute a list of locations for a publication by walking the linear spine items in reading order, visiting the text content of each in document order, skipping text that is only whitespace, and emitting a position every N UTF-16 code units of counted text. Each location shall be recorded as a point CFI (the position where the run of N code units begins). N shall be a named constant; the candidate's default is 150 and its own example application uses 1600.

Why: Gutenberg books have no page list. Readers want "page x of y" and a progress scrubber, and both need a scale that is stable across font sizes, devices and orientations. Character counts are the stable scale; pages are not. Verified: the candidate's default break is 150 characters (set in the constructor); the shipping example that persists locations to local storage asks for 1600, which gives counts closer to printed pages. Its locations are range CFIs from the start of each run to its end; a point at the start is enough for lookup and halves the storage.

Spec: none. This is a reading-system convention. EPUB 3.3 section 7.4.3 (the page-list nav) is the spec's answer for publications that carry page breaks; EJS-35 covers that.

Edge cases, verified in the candidate:
- The count is per text node without trimming, so indentation whitespace inside a text node that also contains words is counted. Whitespace-only text nodes are skipped. A native implementation should count only the text it will render, after whitespace collapsing, so the scale matches what the reader sees.
- Text inside `script`, `style` and `template` elements under body is counted by the candidate because its walker takes every text node under body. Funston shall exclude those, and shall exclude `title`, `head` and any element with `hidden` or the EPUB `pagebreak` marker's empty content.
- Images, SVG, audio and video contribute nothing. An illustrated chapter of 40 pictures and 200 words is 1 or 2 locations. Issue 954 is this complaint. Alt text is not counted either. The merged spec should decide whether to charge a fixed number of code units per replaced element (see "Open questions").
- Tables and headings count like any text.
- Non-linear spine items are skipped (EJS-17).
- After a cut inside a text node the candidate restarts the next run one code unit later, so consecutive locations inside long paragraphs are N+1 apart and a character is never the first of any location. This is a quirk, not a design; Funston shall cut at exact multiples.
- The candidate resets its counter at the start of every spine item and closes the open run at the item's end, so every chapter ends with a short location and short chapters inflate the count. Funston shall decide (see "Open questions") whether to carry the remainder across the boundary; carrying it gives a truer percentage, resetting gives "each chapter starts on a location boundary".

Test: a section with one text node of 10 code units and N = 4 gives locations at offsets 0, 4 and 8; two sections of 10 code units each with N = 4 and carry-over give 0, 4, 8 in the first and 2, 6 in the second (carry) or 0, 4, 8 in each (reset).

#### EJS-13 Location count and indexing

The total shall be the number of locations minus one, so that the first location is 0 percent and the last is 100 percent. Location index i maps to the stored CFI at i. A CFI maps to a location index by binary search with the EJS-09 comparator, returning the index of the first stored location that is at or after the CFI, clamped to the total. Percentage from index is index divided by total; index from percentage is the ceiling of percentage times total; a percentage of 1 or more maps to the end of the last location.

Why: this is what the progress scrubber, the "page x of y" label and the percentage field of a saved position are built on. Verified in the candidate, including the clamp, the ceiling, and the special case that a percentage of exactly 1 goes to the very end rather than the start of the last location.

Spec: none.

Edge cases: a book with a single location has total 0 and every percentage is 0; division by zero shall be guarded. A CFI before the first location (for example in the package path only) maps to 0. A CFI in a non-linear item has no location; return the location of the nearest preceding linear item's end.

Test: with locations at offsets 0, 4, 8 in one section (total 2), the CFI at offset 5 maps to index 2, percentage 1.0 by the candidate's rule (first location at or after); the merged spec may prefer "last location at or before", which gives index 1 and 0.5. Pick one and pin it in the test.

#### EJS-14 Percentage and location in the relocation report

Whenever the reader reports its position, it shall include the location index and percentage of the start and of the end of the visible range, computed by EJS-13, when locations are available. When they are not, the fields shall be absent, not zero or -1.

Why: the candidate fills these from the start CFI and end CFI of each relocation. When locations have not been generated it reports location -1 and percentage 0 (verified by following the code path), which is indistinguishable from "at the start of the book" to a client. Funston's VoiceOver announcement must say "position unavailable" rather than "0 percent".

Test: relocate before and after location generation; before, the fields are nil; after, they are set.

#### EJS-15 Locations are persisted with a cache key

The computed list shall be serialised as an ordered array of CFI strings and stored under a key that includes the publication identifier, the location algorithm version, N, and a digest of the spine order. On open, a stored list whose key matches is loaded instead of recomputed.

Why: generation costs a parse of every chapter (EJS-16). The candidate serialises to a JSON array of CFI strings and its example keys the storage by a library version string plus the dc:identifier. It does not include N or the spine, so a list made with one N is silently used with another, and a re-downloaded book with a reordered spine resolves every stored location into the wrong chapter. Verified for the serialisation; the key weakness is an inference from its key format.

Spec: none.

Edge cases: dc:identifier is often missing or shared across editions of Gutenberg books; the key shall fall back to a content digest (for example of the package document bytes).

Test: save, reopen with the same book, assert no regeneration; change N, assert regeneration.

#### EJS-16 Generation runs off the main thread and reports progress

Location generation shall run as a cancellable background task, process one spine item at a time, free each item's parsed document before the next, and report progress by spine index so the UI can show "computing locations" and so a partially computed list can be used for items already processed.

Why: the candidate loads, parses and walks every spine item serially on the main thread with a 100 millisecond pause between items (the pause is a constructor default, verified). On a long book this is seconds to tens of seconds, and issues 1110 and 1405 ask for it to be made asynchronous. Cost model, verified from the algorithm: time is linear in total text plus one DOM parse per item; memory peaks at one parsed item plus the growing list; output size is the location count times the CFI string length (roughly 40 to 80 bytes each). For a 600,000 character novel at N = 150 that is about 4,000 CFIs and 250 kilobytes; at N = 1600 about 400 CFIs and 25 kilobytes.

Test: cancel midway; no partial list is persisted, and the UI shows locations unavailable.

#### EJS-17 Linear and non-linear spine items

Locations, next and previous navigation, and the first and last item of the book shall consider only spine items with `linear` not equal to `no`. A non-linear item shall still be displayable when the reader navigates to it directly (a link to a footnote file, a table of contents entry).

Why: EPUB 3.3 section 5.7.2 (the `itemref` element and its `linear` attribute) defines non-linear content as auxiliary and says reading systems should provide a way to reach it but need not place it in the default reading order. Verified: the candidate skips non-linear items in next and previous (it walks past them), in first and last, and in location generation; direct display by href works.

Edge cases: a book where every item is non-linear (invalid but seen): treat all as linear and record a diagnostic.

Test: a three-item spine with the middle item non-linear: next from item 0 is item 2; a link to item 1 displays it; locations count items 0 and 2 only.

### Mapping: what is on this page

#### EJS-18 Visible range determination

Given a laid-out section and the visible rectangle of the viewport along the scroll axis, the reader shall determine the first visible character and the last visible character in reading order and report them as two point CFIs. The algorithm, translated to a native layout engine:

1. Walk the laid-out text in reading order (for TextKit 2, line fragments in order; for the candidate, text nodes in document order measured as client rects).
2. Start: the first unit whose extent is not entirely before the viewport's leading edge along the axis (its trailing edge is past the viewport start). Within it, the first glyph whose leading edge is at or past the viewport start. If no glyph qualifies, the first glyph of that unit.
3. End: scan forward; when a unit begins after the viewport's trailing edge, the previous unit is the last visible; otherwise, when a unit extends past the trailing edge, that unit is the last visible. Within it, the last glyph whose leading edge is not past the trailing edge; a glyph that straddles the edge counts as visible. If the document ends first, the last glyph of the document.
4. For horizontal right-to-left pagination, mirror the comparisons (the viewport start is the right edge). For a vertical axis use top and bottom.

Why: this is the heart of position saving and of VoiceOver's "what is on this page". It is what Funston's PDF reader does with recognised line rectangles, which is why the house style translates directly. Verified in the candidate: it measures each non-whitespace text node's bounding rect, picks the first node not entirely before the page, splits that node into word ranges on the space character and picks the first word whose leading edge is at or past the page start; for the end it picks the node that extends past the page end (or the one before the first node that begins after it), splits into words and picks the straddling word or the last word before the edge. It rounds rects for the end search and not for the start, which is incidental. It then collapses the start range to its start and the end range to its end and generates both CFIs.

Spec: none.

Edge cases, verified or inferred from the candidate's approach:
- A paragraph flowing across two columns has one bounding rect spanning both; the node-level test still works because the rect overlaps the page; the word-level test picks the right word. A native engine does not have this ambiguity because line fragments never span columns.
- The candidate's word splitter uses the ASCII space only, so CJK text, text with non-breaking spaces, or a paragraph with no spaces becomes one "word" and the result degrades to node granularity. A native implementation works at glyph or character level and has no such failure.
- Whitespace-only text is skipped, so an empty page (image only) returns the last text before it as both start and end. Funston shall instead report the image's position (its element CFI) so an image-only page is not announced as the previous paragraph.
- Floats and absolutely positioned elements appear out of document order; the candidate ignores this. A native engine shall walk layout order, not document order, when they differ.

Test: lay out a three-paragraph section in two pages; page 2's start CFI is the first character on page 2 and its end CFI is the last; moving the viewport by one line moves the start by one line's worth of characters.

#### EJS-19 Page indices alongside the CFIs

With the CFIs, the reader shall report for each visible section the page index within the section of the first and last visible pages and the total pages in the section, where a page is one viewport-width (paginated) or one viewport-height (scrolled) of the section's laid-out extent.

Why: the candidate's relocation report carries `displayed.page` and `displayed.total` per section, and its "at end" flag is "last spine item and displayed page is the last". For Funston these are what "page 3 of 12 in this chapter" is built from. Verified: in paginated mode page index is the floor of the page start offset divided by the page width, plus one; total is the ceiling of the section's laid-out width divided by the page step, times pages per spread. In scrolled mode the same with heights. For right-to-left the indices are reversed from the total.

Spec: none.

Edge cases: the candidate clamps a negative start page to 0 and shifts the end page by one, which hides an off-by-one from fractional scroll positions; Funston shall compute pages from the layout model (which page did we snap to), not from pixel division.

Test: a section laid out to exactly four pages reports total 4 and indices 1 through 4 as the reader pages.

#### EJS-20 When the relocation report fires

The reader shall produce a relocation report after a display request completes, after each next or previous page, when scrolling settles (debounced), and after any relayout that changes where text falls (font size, viewport size, orientation, theme change that affects metrics). Reports during an in-progress page snap shall be suppressed until the snap finishes.

Why: this is when the position store writes and when VoiceOver is told the page changed. Verified: the candidate fires after display, after next and previous, and on a "scrolled" signal that the single-section manager emits 20 milliseconds after the last scroll event and the continuous manager emits after a 30 millisecond debounce plus a 10 millisecond settle, skipping if a snap is pending. It does not fire after a content resize (font size change), so the saved position is stale until the next user action; issue 982 reports it. It also fires on a frame callback after the manager has laid out, so the measurement sees final geometry.

Spec: none.

Test: change the font size with no other interaction; a report fires and its start CFI is unchanged (same character) while its page index changed.

### Managers and layout

#### EJS-21 Single-section and continuous presentation

The reader shall support presenting one section at a time (paging within it and replacing it at its ends) and presenting sections continuously (neighbours appended and prepended as the reader approaches the edges). The flow modes named by EPUB 3.3's `rendition:flow` shall map as follows: `paginated` and `auto` to the paged presentation; `scrolled-doc` to a single section that scrolls; `scrolled-continuous` to the continuous scroller.

Why: Funston already offers paged and continuous reading (its settings store has a reading layout setting), and VoiceOver is used in continuous mode because page boundaries interrupt the screen reader. Verified: the candidate maps exactly these flow values, and treats `auto` as paginated.

Spec: EPUB 3.3 section 8.3.1 (`rendition:flow`) defines the four values and lets the reading system treat them as hints.

Test: open a book with each flow value declared and assert the presentation chosen; override with a user setting and assert the override wins.

#### EJS-22 Continuous preload window

In continuous presentation the reader shall keep loaded the sections that intersect the viewport extended by a lookahead distance on each side, append the next section when the extended viewport reaches the end of the loaded content, prepend the previous when it reaches the start, and repeat until the extended viewport is covered. Sections outside the extended viewport shall be released after scrolling settles, keeping at most one beyond each edge.

Why: this is what lets continuous reading cross chapter boundaries without a pause and without loading the whole book. Verified: the candidate's lookahead is 500 pixels by default in scrolled mode and one page width in paginated mode (it recomputes the offset as the page step divided by pages per spread, and the swipe helper sets it to the layout width). After each append or prepend it re-checks and then updates visibility; it schedules a trim 350 milliseconds after the last scroll, and defers the trim while scroll velocity is above 2 pixels per event. Trimming keeps one view beyond the displayed window on each side. Views outside the window are hidden rather than destroyed during active scrolling to avoid flicker at section edges; a change made recently in its history and commented as such.

Spec: none.

Edge cases: a section shorter than the lookahead triggers an immediate further append; the loop must terminate at the spine's end. A section that fails to load shall be marked and skipped, not retried in the loop (the candidate hides a view whose display rejects).

Test: a book of ten one-line sections with a 500 point lookahead loads several on open and stops at the last; scrolling back releases far ones.

#### EJS-23 Insertion above the viewport does not move the reader's text

When content is prepended, or a section above the viewport changes size after load (images arriving, fonts resolving), the scroll offset shall be adjusted by exactly the size delta in the same layout pass, without emitting a scroll event, so the text under the reader's eyes stays put.

Why: this is the single hardest thing about continuous scrolling and the candidate's issues 1131, 1212, 1295 and 1416 are all jumps from getting it wrong or from fighting the browser's own scroll anchoring. Verified: the candidate listens for a prepended view's resize, scrolls by the reported height delta (or width delta on a horizontal axis), and marks the scroll as silent so its own scroll handler ignores it; when it removes a view above the window it subtracts that view's extent in the same way, with right-to-left variants. Its size delta is the difference between the view's new and previous bounds, so a late image load in a view above also compensates.

Spec: none.

Edge cases: two compensations racing (a prepend and an image load in the same frame) must sum, not overwrite. UIKit's own content offset adjustments on content size change must be accounted for so the delta is not applied twice (the browser analogue is scroll anchoring, issue 1416's cause).

Test: scroll to the middle of section 3, force section 2 to load above; the first visible CFI is unchanged and the visible rect of its first glyph moved by less than one point.

#### EJS-24 Resize relayout returns to the saved start

On a viewport size change, the reader shall debounce, compare the new size to the last laid-out size and do nothing if equal, otherwise relayout and navigate to the start CFI of the last relocation report. If no report has been produced yet, it shall navigate to the pending display target instead of leaving the view empty.

Why: the alternative is pixel-based restoration, which lands on the wrong page as soon as line breaks move. Verified: the candidate throttles window resize to 50 milliseconds, returns early when the stage size is unchanged, clears every view, recomputes layout, and then re-displays the last location's start CFI. When the first location has not been reported yet (resize during initial load) it displays nothing, which is issue 1384 ("blank page when resize happens during loading"). On iOS it also re-measures 500 milliseconds after an orientation change because the first measurement after the event can be stale (a comment in the source cites a known WebKit timing issue).

Spec: none.

Edge cases: a resize while a display request is in flight: queue the resize after the display completes, then re-display at the result.

Test: rotate the simulator mid-load; the target chapter appears. Rotate with a position; the same first character is on screen.

#### EJS-25 Layout arithmetic for reflowable pagination

From a content width W, content height H, a spread policy and a minimum spread width M (default 800 points), the paged layout shall compute: pages per spread D = 2 if spreads are allowed and W is at least M, else 1; column gap G = the largest even integer not greater than W/12 unless the caller supplies one (0 for fixed layout); column width C = W/D minus G when D is 2, else W; page step (the distance one "next" moves) = W; spread width = C × D + G; and the page count of a section as the ceiling of its laid-out extent divided by the page step, times D. In scrolled presentation the page count is the ceiling of the extent divided by H.

Why: these are the numbers every other requirement here refers to, and they are what the merged spec will have to pin so that page counts and page indices agree between the layout engine and the location reporter. Verified in the candidate, including the "even gap" rounding, the W/12 default, and the fixed-layout zero gap. The candidate also pads the body by half the gap on each side so two columns plus the gap fill the width exactly, and in scrolled mode pads the body horizontally by W/12 on each side.

Spec: EPUB 3.3 section 8.2.2.3 (`rendition:spread`) for the spread policy values (none, landscape, both, auto); the thresholds are the reading system's choice.

Edge cases: when D is 2 and a reflowable section lays out to an odd number of columns, the candidate appends a blank column so the next section starts on a left page ("force even pages", verified; it is on in the single-section manager and off in the continuous one). This is also the source of the "blank page at the end of every chapter" complaints (issues 823 and 1298), because the measured content width is rounded up to a multiple of the page width and the measurement (a bounding rect of the body's contents) can overshoot by a margin. Funston shall derive the page count from the last line fragment's position, not from a rounded extent.

Test: W = 1000, M = 800, no caller gap: D = 2, G = 82 (1000/12 = 83.3, floor 83, even 82), C = 418, spread width 918; W = 390: D = 1, G = 32, C = 390.

#### EJS-26 Fixed layout fitting

For a pre-paginated section, the reader shall read the section's viewport meta (width and height), scale the page uniformly by the smaller of (available width / viewport width) and (available height / viewport height), place a left-page section flush right and a right-page section flush left when showing two pages, show the first section (the cover) alone, and move by two sections per spread.

Why: Funston's corpus is reflowable Gutenberg text, so this is low priority, but the merged spec needs the rule so fixed-layout books degrade gracefully rather than crash. Verified: the candidate parses the viewport meta content attribute with regular expressions for width and height, scales with a transform from the top-left, treats a section with the `page-spread-left` property as needing a left margin equal to the leftover width, shows the first page alone, and on next and previous loads a second page only when the next section does not itself claim the left side.

Spec: EPUB 3.3 sections 8.2.2.1 (`rendition:layout`), 8.2.2.4 and appendix D.7 (`page-spread-left` and `page-spread-right`), 8.2.2.6 (content document dimensions) with appendix F (the viewport meta tag), and 8.2.2.5 for the deprecated package-level `rendition:viewport`.

Edge cases: fixed layout can also be declared by the iBooks display options file (EJS-43). A section without a viewport meta in a pre-paginated book: fall back to the package-level `rendition:viewport` if present, else treat as reflowable and record a diagnostic.

Test: a 1024 × 768 page in a 390 × 844 viewport scales by 390/1024 and is 292 points tall, centred vertically by the layout policy the merged spec chooses.

#### EJS-27 Writing mode and direction

The reader shall read the section's writing mode and the package's page progression direction, and shall: use a vertical scroll axis for horizontal writing in scrolled presentation and a horizontal axis for vertical writing; use a horizontal axis for horizontal writing in paged presentation and a vertical axis for vertical writing; mirror paging and the mapping comparisons for right-to-left progression; and disable spreads when the axis is vertical.

Why: Gutenberg's corpus is left-to-right, but Internet Archive hosts Japanese and Arabic books and a crash or mirrored mess is worse than an honest "unsupported". Verified: the candidate detects the writing mode from the rendered document's computed style, flips the axis as above, reads `page-progression-direction` from the spine element, sets the layout's page step to the height for vertical writing in paged mode, and has several open issues (1093, 1271, 1069, 1070) where vertical or right-to-left offsets are wrong, so its behaviour here is a starting point, not a reference. One more, directly relevant to Funston: the attribute's third legal value `default` is passed through as the direction string, and the paging code only recognises `ltr` and `rtl`, so next and previous stop working. Internet Archive's own EPUBs set `default` (issue 1138, diagnosed in the thread of issue 1340). The reader shall treat `default` and an absent attribute as left-to-right unless the writing mode says otherwise.

Spec: EPUB 3.3 section 5.7.1 (the `spine` element, `page-progression-direction` with values ltr, rtl and default); CSS Writing Modes for `writing-mode`.

Test: a right-to-left book pages from right to left and its mapping returns the right-hand column's text as the first page.

#### EJS-28 Images are constrained to the column

In reflowable presentation, images and inline SVG shall be constrained to at most the column width minus horizontal padding and at most 95 percent of the column height, preserving aspect ratio, and shall not be split across pages.

Why: without this an image wider than a column spills into the next page. Verified: the candidate injects a stylesheet into every reflowable section with these rules after layout (max-width to the column width minus the body's horizontal padding or 100 percent, max-height to 95 percent of the content height, object-fit contain, break-inside avoid, box-sizing border-box), then waits a tick for the browser to apply it. Issue 786 reports images still overflowing because the max-width is computed before the column padding is applied; the lesson is to compute the constraint from the final column box.

Spec: none; EPUB 3.3 leaves image sizing to CSS.

Test: a 2000 pixel wide image in a 390 point column renders at 390 points minus padding and starts a new page if it would not fit on the current one.

#### EJS-29 Page snapping

In paged presentation with touch scrolling, the reader shall snap to page boundaries after a drag: a drag shorter than a minimum distance snaps back; a drag beyond the minimum with velocity above a threshold snaps to the next or previous page in the drag direction; otherwise it snaps to the nearest page.

Why: Funston will use UIScrollView paging, which does this natively, so this requirement is a check that the native behaviour covers the same cases. Verified constants in the candidate: minimum distance 10 pixels, minimum velocity 0.2 pixels per millisecond, snap animation 80 milliseconds with an ease-in cubic curve, snap width = page width × pages per spread. Any drag at or beyond a full page width is treated as a scroll, not a swipe.

Spec: none.

Test: covered by UIScrollView's paging; assert that `isPagingEnabled` is set and the page width equals the layout's page step.

### Themes and font size

#### EJS-30 Reader styles layered after publisher styles

The reader shall apply its own styles after the publication's, so that at equal specificity the reader wins, and shall be able to mark individual overrides as mandatory so that they beat publisher rules of any specificity. A native renderer with no cascade shall model this as: publisher attributes first, reader theme attributes second, reader overrides last, applied at the paragraph and run level.

Why: Funston's current Readium integration turns publisher styles off entirely and sets a leading-aligned text style; the merged spec needs to say how far "off" goes. Verified: the candidate appends a `style` element to each section's head per theme (replacing it in place when the same theme is re-registered), adds the theme name as a class on the body so theme rules can be scoped, and applies overrides as inline styles on the body with an optional "important" flag. Font family is applied with the flag; font size is not. There is no built-in default theme; the only default injection is the image constraint of EJS-28.

Spec: EPUB 3.3 section 6.3.1 (CSS in content documents) for what publishers may use; user and reading-system style overrides are the subject of EPUB Reading Systems 3.3, not of the core specification.

Edge cases: a publisher body font size in absolute units is unaffected by a body font-size override in the candidate, and a paragraph with its own absolute size ignores both. For a native renderer, "font size" shall be a scale factor applied to every computed font size, which is what the Dynamic Type integration already does for Readium (Funston's controller computes a multiplier from the body text style).

Test: a book with `p { font-size: 12pt }` and a reader size of 150 percent renders paragraphs at 18 points.

#### EJS-31 Theme changes apply to loaded and future sections

Selecting a theme or changing an override shall update every section currently loaded and shall be applied to every section loaded later, and shall trigger the relayout and relocation of EJS-20 and EJS-24.

Why: a theme change is a relayout in disguise. Verified: the candidate keeps the current theme and overrides in memory, re-injects them into each loaded section, and injects them via the content hook for each new one; because its font size override changes metrics after layout, it relies on a resize observer in each section to re-expand the view, and does not re-report location (issue 982).

Test: switch to dark theme with three sections loaded; all three repaint; the next section loaded is dark.

### Hooks

#### EJS-32 Pipeline stages

The content pipeline shall expose these stages, in order, each allowed to be asynchronous and each completing before the next begins:

1. After parse (the section's document model is in memory, before it is laid out): fix-ups that need the model, such as recording the section's base URL for relative references, its canonical URL, and the publication identifier.
2. Before render (the model is about to be handed to layout): resource reference resolution (EJS-44) and reader stylesheet or theme injection.
3. After render (the section has a layout): annotation attachment (EJS-47).
4. After content ready (the laid-out section is on screen or ready to be): link handling (EJS-33), event forwarding, image constraints (EJS-28), theme application (EJS-30).
5. On unload: annotation detachment and resource release.

Why: these are the points where every reader has to do something, and getting the order wrong gives the candidate's bugs: themes injected after layout cause a second layout, and highlights attached before layout have no geometry. Verified: the candidate's spine-level "content" hook runs on the parsed DOM (base element, canonical link, identifier meta, optional stylesheet link, optional script); its "serialize" hook runs on the string (asset URL substitution); the rendition's "render" hook runs when the view has displayed (annotations); its "content" hook runs when the section's content object exists (links, event pass-through, image adjustment, theme injection and overrides); its "unloaded" hook runs on removal (annotations). Its "display", "layout" and "show" hooks exist and are never used. All hooks are promise-aware and the pipeline waits on all registered functions.

Spec: none.

Test: register a probe at each stage; assert the order and that layout happens once per section load.

#### EJS-33 Link handling

Links inside content shall be classified: a `mailto:` link is left alone; an absolute link to another origin opens outside the reader; a relative link resolves against the section's URL and navigates within the publication to the target section and fragment.

Why: cross-references and footnotes in Gutenberg books are relative links with fragments. Verified: the candidate rewrites every anchor with an href in the content: mailto untouched, absolute links get a new-window target, relative links get a click handler that resolves the href against the document's base and asks the rendition to display the path plus fragment, made relative to the package document's directory.

Spec: EPUB 3.3 has no dedicated hyperlink section; relative references resolve per section 4.2.5 (URLs in the OCF abstract container), and the reading-system obligations are in EPUB Reading Systems 3.3.

Edge cases: a relative link to a non-spine resource (an image, a PDF): open as a resource viewer or ignore, with a diagnostic. A link to a non-linear item: display it (EJS-17). A fragment that does not exist: display the section's start and record a diagnostic.

Test: a footnote link `notes.xhtml#n12` from `ch1.xhtml` displays notes.xhtml positioned so the element with id n12 is at the top of the page.

### Navigation

#### EJS-34 Table of contents from the nav document or the NCX

The reader shall build the table of contents from the EPUB 3 nav document when the manifest has an item whose `properties` include `nav`: take the `nav` element whose `epub:type` is `toc`, its first `ol` child, and for each `li` take the label from an `a` or `span` child's text, the href from the `a` (empty for a `span` heading), the id from the `li` id or else the href, and nested `ol` children as sub-entries. Otherwise, when the manifest has an item of media type `application/x-dtbncx+xml`, or the spine's `toc` attribute names an item, build it from the NCX `navMap`: each `navPoint` gives an id, a label from `navLabel/text`, an href from `content/@src`, and its parent from the enclosing `navPoint`. Landmarks come from the `nav` with `epub:type` `landmarks` (each `a` with its `epub:type`, href and label).

Why: Gutenberg EPUBs are a mix: older ones carry only an NCX; newer ones carry both. Funston shows a flattened, indented contents list, so the tree shape must be right. Verified: the candidate does exactly the above, including the `span` label case for headings without links, the NCX parent reconstruction by id, and an `epub:type` check that works whether the attribute is namespaced or literal `epub:type`. Its lookup tables from href and id to entry are indexed by position within the sub-list rather than globally, which is fragile; Funston shall build flat maps.

Spec: EPUB 3.3 section 7 (navigation document), 7.4.2 (the toc nav), 7.4.4 (the landmarks nav); EPUB 2.0.1 OPF section 2.4.1 (the spine `toc` attribute and NCX requirement) and the NCX definition it references for navMap.

Edge cases: `li` elements without `a` or `span` are skipped. A nav document whose toc `nav` has no `ol`: empty table of contents, not a crash. An NCX `navPoint` whose parent id is missing from the map: attach at the top level with a diagnostic. Hrefs in the nav document are relative to the nav document, which may be in a different directory than the package document; resolve accordingly (the candidate resolves spine hrefs against the package directory and nav hrefs as given, and has open issues where they differ).

Test: the W3C epub-tests nav fixtures; a Gutenberg book with NCX only; a book with both (the nav document wins).

#### EJS-35 Page list with labels and resolvable targets

The reader shall parse the page list from the nav document (`nav` with `epub:type` `page-list`, each `a` giving a label and an href) or the NCX `pageList` (each `pageTarget` with `navLabel/text` and `content/@src`). Labels shall be kept as strings (roman numerals and lettered pages are common). Each entry's target shall be resolved to a CFI (an href with a fragment resolves to the element with that id in that spine item), so that "which printed page am I on" can be answered by binary search with the EJS-09 comparator.

Why: when a book has a page list, it is the right source of page numbers and the merged spec should prefer it over synthetic locations. Verified: the candidate parses both sources but converts every label with integer parsing (roman numerals become NaN, issue 1264), and only entries whose href is itself a CFI fragment (`#epubcfi(...)`) participate in lookup; href-based entries, which is every real book, produce no locations, so its page lookup is dead code in practice.

Spec: EPUB 3.3 section 7.4.3 (the page-list nav), and the `pagebreak` semantic in the EPUB structural semantics vocabulary; NCX pageList.

Test: a book with a page list of href targets; after resolution, the CFI of the element with id `pg12` maps to label "12".

#### EJS-36 Display target resolution

A display request shall accept: a spine index; an href with optional fragment; a CFI string; and, when locations exist, a percentage between 0 and 1. Resolution: an index names a section with no in-section target; an href is matched against spine items by exact string, by percent-decoded string, and by percent-encoded string, with the fragment stripped for matching and kept as the in-section target; a CFI's package path names the section and its document path is the in-section target; a percentage becomes a CFI through EJS-13. When the section is already on screen and the request has an in-section target, scroll within it; when it has none, scroll to the section start.

Why: this is the single entry point for the contents list, links, saved positions, the progress scrubber and search results. Verified: the candidate matches hrefs in all three encodings (a fix referenced in its spine code), strips fragments, takes spine position from a CFI, interprets a floating-point string as a percentage only when locations exist, and treats a target equal to the section's own href or a numeric target as "no in-section target". In paged mode it computes the target's leading offset, snaps down to a page boundary and clamps to the last page; in scrolled mode it scrolls the target's top to the viewport top.

Spec: EPUB 3.3 section 4.2.5 for href resolution within the container; EPUB CFI 1.1 for CFIs.

Edge cases: an href not in the spine (a nav document pointing at an image or an unknown file) resolves to nothing and shall surface a diagnostic, not a blank screen. A CFI whose section exists but whose document path does not resolve displays the section start and reports partial resolution (EJS-07).

Test: each target form against a three-section book; assert section index and in-section target.

#### EJS-37 Relocation report contents

The report shall contain, for the start and for the end of the visible range: spine index, section href, point CFI, page index within the section and total pages in the section (EJS-19), and when available the location index, percentage (EJS-14) and page-list label (EJS-35). It shall carry two flags: at start (first linear item and first page) and at end (last linear item and last page).

Why: this is the record the position store writes, the VoiceOver announcement reads, and the progress UI binds to. It is a superset of what Funston stores today in Readium Locator JSON. Verified: the candidate's report has exactly these fields; the "at end" flag is computed as last spine item and displayed page at or beyond total, "at start" as first spine item and page 1. It also emits an older, flatter event with index, href, start, end and percentage for compatibility.

Spec: none; compare Readium's Locator (href, type, title, locations with progression, totalProgression, position) for the merged spec's data model.

Test: at the last page of the last chapter, at end is true; at the cover, at start is true.

### Archive, container and packaging

#### EJS-38 Container parsing

The reader shall read `META-INF/container.xml`, take the first `rootfile` element's `full-path` as the package document path (the default rendition), and resolve all package-relative paths against that document's directory.

Why: this is the only entry point the spec guarantees. Verified: the candidate takes the first `rootfile` and ignores its `media-type` and any further rootfiles; it records the document encoding and nothing else from the container.

Spec: EPUB 3.3 section 4.2.6.3.1 (the container file) and 4.2.6.3.1.3 (the `rootfile` element; the first one is the default rendition); sections 4.2.3 to 4.2.5 for file paths and URLs inside the container.

Edge cases: no `rootfile`: fail with a typed error. A `full-path` that does not exist in the archive: fail with a typed error naming the path. Multiple rootfiles: use the first, record the count.

Test: the W3C epub-tests container fixtures.

#### EJS-39 Package document parsing

The reader shall parse the package document and require `metadata`, `manifest` and `spine` elements, failing with a typed error naming the missing one. From the manifest, each `item` gives id, href, media type, `properties` (space-separated), and `media-overlay`. From the spine, each `itemref` gives idref, `linear` (default yes), `properties`, and its position; the spine element's own position among the package element's children is recorded for EJS-05, and its `page-progression-direction` and `toc` attributes are kept. The navigation document is the item whose properties contain `nav`; the NCX is the item of media type `application/x-dtbncx+xml` or else the item named by the spine's `toc` attribute; the cover is the item whose properties contain `cover-image`, or else the item named by a `meta` with `name="cover"` and a `content` id. Metadata: the first `dc:title`, `dc:creator`, `dc:description`, `dc:date`, `dc:publisher`, `dc:identifier`, `dc:language`, `dc:rights`; `meta` elements with properties `dcterms:modified`, `rendition:layout`, `rendition:orientation`, `rendition:flow`, `rendition:spread`, `rendition:viewport`, `media:active-class`; the unique identifier is the `dc:identifier` whose id matches the package element's `unique-identifier`.

Why: this is the whole model the rest of the reader hangs off. Verified: the candidate does all of the above; it keeps only the first text node of each Dublin Core element (so a title with a nested element loses the tail), it does not read `refines` metadata, and it matches `properties` by whitespace-separated word (so `nav` is found whether first or last).

Spec: EPUB 3.3 sections 5.5 (metadata), 5.6 (manifest), 5.7 (spine), 5.3.5 (the `properties` attribute) with appendix D.6 for the `nav` and `cover-image` manifest properties; EPUB 2.0.1 OPF section 2.4 for `toc` and `linear`, and the de facto `meta name="cover"` convention.

Edge cases: an itemref whose idref is not in the manifest: keep the spine position (so CFIs still number correctly) but mark the item unloadable and skip it in reading order with a diagnostic. This is not hypothetical: Internet Archive's generated EPUBs reference a cover itemref with no manifest item, and the candidate shows a blank first page for them (issue 1340, diagnosed in its thread; issue 1138). Duplicate ids: first wins. A manifest item href containing spaces or percent-encoding: store the raw href and match in all three encodings (EJS-36).

Test: the IDPF epub3-samples package documents; a Gutenberg package document; a package missing its spine.

#### EJS-40 Fixed-layout detection

A publication shall be treated as pre-paginated when `rendition:layout` is `pre-paginated`, or when `rendition:layout` is absent and `META-INF/com.apple.ibooks.display-options.xml` exists with a `fixed-layout` option of `true`. Per-section `rendition:layout-*` spine properties override the publication default for that section.

Why: old fixed-layout books predate the EPUB 3 property and used Apple's file. Verified: the candidate loads the display options file only when `rendition:layout` is empty, reads the `interactive`, `fixed-layout`, `open-to-spread` and `orientation-lock` options, and reconciles per-section `rendition:` properties by splitting them at the first hyphen into property and value.

Spec: EPUB 3.3 section 8.2.2.1 for the property and its spine-level overrides; the Apple file is a vendor convention.

Test: a book with only the Apple file set to fixed layout opens pre-paginated.

#### EJS-41 Resource access by manifest href

The reader shall read a resource from the archive by resolving its manifest href against the package document directory, percent-decoding the result for the zip entry lookup, and typing it by the manifest media type (falling back to an extension table only for entries not in the manifest). Resources shall be read on demand and released when their section unloads, not materialised at open.

Why: the candidate, when given an archived book, creates a blob URL for every non-HTML asset at open, which means decompressing every image in the book into memory before the first page shows; CSS files are additionally rewritten so their relative `url()` references point at those blobs, and each section's serialised XHTML has every asset path replaced by regular-expression substitution before it reaches the iframe. Verified. It also types entries by file extension rather than manifest media type. For a native reader with an archive it can seek into, lazy access is both simpler and lighter.

Spec: EPUB 3.3 section 5.6 (the manifest item's `media-type` attribute is authoritative); sections 4.2.3 to 4.2.5 (file names, deriving file paths, and URLs in the container: hrefs are URLs and must be percent-decoded to find the archive entry).

Edge cases: a manifest href with a query string: strip it before lookup (the candidate strips queries when sniffing the input type). An href that escapes the container root (`../`): reject. An entry present in the archive but absent from the manifest (the `mimetype` file, fonts the author forgot): readable by path with a diagnostic.

Test: a book whose image href is `images/caf%C3%A9.jpg` and whose zip entry is `OEBPS/images/café.jpg` renders the image.

#### EJS-42 Document parsing tolerances

Section documents shall be parsed according to the manifest media type, never the file extension: `application/xhtml+xml` as XML, with the byte order mark stripped first; `text/html` as HTML. On an XML well-formedness error the reader shall fall back to a lenient HTML parse and record a diagnostic rather than show a blank section.

Why: Gutenberg's older EPUBs are generally well-formed, but Internet Archive hosts books converted by many tools and a single unescaped ampersand must not blank a chapter. Verified: the candidate strips the BOM but chooses the parser by file extension (xhtml as XML; html and htm as HTML; xml, opf and ncx as XML), and does not detect a parser error document, so a malformed chapter renders the browser's error text. Issue 1315 is the extension rule biting: XHTML files named `.html` were parsed as HTML, where a self-closing `title` element has no end and swallows the whole document, giving blank pages for an otherwise valid book.

Spec: EPUB 3.3 section 6.1 (XHTML content documents) and section 3.9 (XML conformance) state the well-formedness requirement on authors; tolerance is the reader's choice. Section 5.6 makes the manifest media type the source of truth for a resource's type.

Test: a chapter with a bare `&` in text renders its text.

### Annotations

#### EJS-43 Annotation store keyed by CFI range

Highlights, underlines and marks shall be stored keyed by (type, CFI range), grouped by spine index. When a section is laid out, every annotation for that index attaches to it; when the section unloads, they detach. Adding an annotation while its section is on screen attaches it immediately. Removing an annotation detaches it from every view showing that section.

Why: this is what makes highlights survive paging, scrolling, resize and theme changes without the application doing anything. Verified: the candidate hashes the CFI range plus type for the key, keeps a per-spine-index list, attaches via the "render" hook and detaches via the "unloaded" hook. Issues 1164 and 1183 ("highlights disappear after scrolling") report the overlay ending up stacked under the content after paging back and forth, and issue 1226 ("resize messes up annotations") reports an exception when a highlight exists during a resize; both are ordering and lifecycle bugs in the drawing layer, not model bugs.

Spec: none; W3C Web Annotation uses the same idea (a selector, here a CFI range, plus a body).

Test: highlight a range, page away and back: the highlight is drawn; change font size: it follows the text.

#### EJS-44 Highlight geometry from the live range

A highlight shall be drawn as one rectangle per line fragment that the range covers (de-duplicated), in a layer above the text, with a default fill of yellow at 30 percent opacity blended multiplicatively so text stays legible; an underline as a one-point line along the bottom of each such rectangle with a default black stroke at 30 percent opacity; a mark as a single glyph-sized marker at the top trailing corner of the first rectangle, in the margin of the column that rectangle is in. Geometry shall be recomputed from the range after every layout pass, never cached across layouts.

Why: computing from the live range is what makes highlights survive relayout. Verified in the marks-pane dependency: the overlay is an SVG element positioned over the view, one `rect` per client rect of the range (rects serialised and de-duplicated through a set), offsets corrected by the container's position; the underline adds a line at the rect's bottom minus one pixel; the pane re-renders all marks whenever the view is re-framed. Verified in the candidate's view: default highlight attributes are fill yellow, fill-opacity 0.3, mix-blend-mode multiply; underline stroke black, stroke-opacity 0.3; the mark's position is the first rect's top and a right edge snapped to the column boundary minus half the gap, re-placed on the next animation frame after a resize. Cross-column highlights work because each line fragment has its own rect; cross-section highlights are impossible because a CFI range cannot span documents (issue 1347).

Spec: none.

Edge cases: a collapsed range (a bookmark): the candidate selects the containing element's contents for a mark. A range whose start or end fails to resolve: draw nothing and keep the annotation in the store with a diagnostic.

Test: highlight a sentence that wraps across a column break; two rectangles, one per column.

#### EJS-45 Hit testing and selection reporting

Tapping inside a highlight shall report the topmost (most recently added) annotation whose rectangles contain the point, with its CFI range and data. A text selection, once stable (debounced), shall be reported as a CFI range.

Why: the editing loop for annotations. Verified: the overlay has pointer events disabled and the candidate proxies mouse and touch events from the content to the marks, testing the bounding box first then each rect, newest mark first, dispatching to the first hit. Selection changes are debounced 250 milliseconds and the resulting range, if not collapsed, is converted to a CFI range with the section's base.

Spec: none.

Test: two overlapping highlights; a tap in the overlap reports the newer one.

#### EJS-46 Search within a section

The reader shall search a section's text case-insensitively and return each match as a CFI range plus an excerpt. Matches may span text node boundaries: the search shall run over a sliding window of consecutive text runs (the candidate uses a window of five), and shall report a match only when it starts in the window's first run so that each match is reported once. Excerpts shall be about 150 characters centred on the match.

Why: whole-book search is on Funston's roadmap for scanned books and will be wanted for EPUBs. Verified: the candidate has a single-node search and a windowed search; the windowed one concatenates the window's text, finds the query, and only accepts a match whose start lies in the first run, then computes the end run by accumulating lengths and builds a range across runs. Its tests cover a match ending in a nested element and a match with an element in the middle.

Spec: none.

Edge cases: a match that spans a block boundary (paragraph end to next paragraph start) is found by the window but is rarely what the user wants; the merged spec may restrict windows to inline runs within one block.

Test: the phrase that crosses an inline emphasis in the vector section.

## Algorithms

This section gives the algorithms in enough detail to implement, in our own words and in terms of a native layout engine. Where the candidate's behaviour differs from what we specify, the difference is marked.

### A1. CFI step generation and the chunk model

Define, for an element E with element children e1 … en in order, the child sequence S(E) = [chunk0, e1, chunk1, e2, …, en, chunkn], where chunk i is the character data (text and CDATA, comments and processing instructions removed) between e(i) and e(i+1), possibly empty. The step integer of e(i) is 2i (1-based i), of chunk i is 2i+1 (0-based i). The chunk's text is the concatenation of its text nodes in order; offsets are UTF-16 code unit positions in that concatenation.

Generating a point CFI from a document position (text node T at offset k, or element X):
1. If the position is in text: find T's parent P, find which chunk of S(P) contains T, and compute the offset as k plus the UTF-16 length of the text nodes before T in the same chunk. The terminal step is that chunk's integer and the offset.
2. Walk up from P (or from X) to the document element. For each node N with parent Q (stop when Q is the document itself, so the document element is not stepped), the step integer is N's position in S(Q) times 2 (as defined above), with an id assertion when N has an id attribute. Prepend each step.
3. Serialise: `/` + integer, `[` + escaped id + `]` if any, for each step; then `:` + offset if the position was in text.

The candidate's deviation: it numbers a text node by its position among its sibling text nodes (ignoring where element siblings fall), does not merge text nodes separated by comments, and does not add preceding text nodes' lengths to the offset unless the ignore class is in play. Funston shall follow the definition above.

Generating a range CFI from (start position, end position):
1. Normalise each position that is expressed as (element, child index) to the start of that child in S (EJS-06), then compute the full step lists and offsets for both as above.
2. Take the longest common prefix of the two step lists comparing integer and id. If the lists are identical and the offsets equal, the result is a point.
3. If the common prefix consumes the whole start list (start and end in the same chunk), the common path is the entire list and both start and end paths are empty with offsets.
4. Otherwise the common path is the prefix, the start path is the start remainder with its offset, and the end path is the end remainder with its offset.
5. Serialise `epubcfi(` + package path + `!` + common path + `,` + start path + `,` + end path + `)`.

Resolution (CFI to position):
1. Split the package path from the document path at the first unescaped `!`. From the package path take the second step's integer; spine index = integer/2 - 1. (Verify the first step against the recorded spine element position and record a mismatch.)
2. Starting at the document element (html), for each document step: if the integer is even, the target is the element child at position integer/2 - 1 among the current element's element children (the even entries of S); if an id assertion is present, look the id up first and prefer it (EJS-07). If odd, the target is chunk (integer-1)/2 of S; the "current node" becomes that chunk (a list of text nodes) and no further child steps are legal.
3. For a terminal offset on a chunk: walk the chunk's text nodes accumulating UTF-16 lengths until the offset falls within one; that node and the local offset are the position. If the offset exceeds the total, apply EJS-08.
4. For a range: resolve common+start and common+end separately.

### A2. CFI comparison

Normalise both CFIs by removing bracketed assertions (respecting escapes). Compare the package paths' step integers in order; if they differ, the smaller integer is earlier. Then the document paths (for a range, common path followed by start path): compare integers position by position; the first difference decides; if one list ends, the shorter is earlier. Then offsets: absent is earlier than 0; otherwise numeric. Equal if everything matches. This comparator is a strict weak ordering suitable for binary search.

The candidate compares decoded indices (dividing out the parity) so a chunk step and an element step at the same depth can compare equal; do not copy that.

### A3. Location generation

Inputs: the publication's linear spine items in order, N (code units per location), the counted-text rule (which text participates, see EJS-12), and the carry policy (reset per item or carry across).

For each linear item in order:
1. Parse the document; produce the sequence of counted text runs in reading order (text nodes under body, excluding script, style, template, hidden subtrees; whitespace-only runs skipped; whitespace collapsed if the merged spec says so).
2. Maintain a counter c of code units consumed since the last location (0 at book start, or at item start if resetting). For each run of length L at position p = 0: while p < L: let d = N - c; if p + d >= L then c += L - p, p = L; else p += d, emit a location at (run, p), c = 0. At item start with c = 0, emit a location at the first run's offset 0 before consuming (so every item start or book start is a location when resetting; when carrying, only the book start is).
3. Emit each location as a point CFI (A1) for (run, offset).
4. Release the document. Yield to the scheduler between items; honour cancellation.

Output: the ordered array of CFI strings, plus the key of EJS-15. Total = count - 1.

The candidate emits range CFIs (start to end of each run of N), skips one code unit after each in-node cut, and resets per item; its last location in each item is the remainder. None of that is required.

### A4. Position to location, location to percentage, percentage to position

Location index of a CFI: binary search the array with A2 for the first location at or after the CFI (or last at or before; the merged spec picks one, see EJS-13), clamp to [0, total]. Percentage = index / total (0 when total is 0). Index from percentage p: if p >= 1, total; else ceil(p × total). CFI from index: the array element; for p >= 1 the merged spec may prefer a CFI collapsed to the end of the last location's run so "go to the end" lands on the last page.

### A5. Visible range (page mapping) in a native layout engine

Inputs: the section's layout (an ordered list of line fragments, each with a frame in the section's content coordinates and the UTF-16 range of the section text it displays), the viewport rectangle in the same coordinates, the axis (horizontal for paged, vertical for scrolled), and the progression direction.

Define lead(f) and trail(f) as the leading and trailing coordinates of fragment f along the axis in reading direction (for left-to-right horizontal: left and right; right-to-left: right and left with comparisons reversed; vertical: top and bottom). Define vStart and vEnd as the viewport's leading and trailing edges.

Start:
1. Find the first fragment f in order with trail(f) past vStart (that is, not entirely before the viewport).
2. Within f, find the first glyph whose leading edge is at or past vStart (glyph-level only matters when a fragment straddles the leading edge, which in column layout happens only for the first line of a column cut mid-line, which column layout never does; in scrolled layout the fragment is wholly in or out). If none, the first glyph of f.
3. The start position is that glyph's character index; generate its point CFI (A1).

End:
1. Scan fragments in order from the start fragment. Let prev be the last fragment seen. When lead(f) is past vEnd, the end fragment is prev. Else when trail(f) is past vEnd, the end fragment is f. If the scan ends, the end fragment is the last fragment.
2. Within the end fragment, the last glyph whose leading edge is not past vEnd; a straddling glyph counts. If none, the last glyph of the fragment.
3. The end position is that glyph's index plus one (a position after the glyph); generate its point CFI.

Then the page indices (EJS-19) from the viewport's offset divided by the page step, and the report (EJS-37). The candidate performs the same scan at text node granularity using bounding rectangles, then word granularity by splitting on spaces; a native engine replaces both with fragments and glyphs, which also fixes its CJK and non-breaking-space failure.

Non-text pages: if no fragment intersects the viewport (an image-only page), the start and end CFIs shall point at the first and last non-text replaced elements in the viewport (their element CFIs), so the position is still monotonic and VoiceOver can announce "image".

### A6. Continuous insertion with scroll compensation

State: an ordered list of loaded views, each with its section index and its extent along the axis; the scroll offset; the lookahead L.

On every settle (and after every insertion): compute the extended window [offset - L, offset + viewport + L]. If the window's end reaches the loaded extent and the last loaded section has a next linear item, append a view for it. If the window's start is below zero and the first loaded has a previous, prepend a view for it. Lay out the new view; when a prepended view's extent becomes known (and whenever a view above the viewport changes extent later), add the delta to the scroll offset in the same layout pass and suppress the resulting scroll event. Repeat until the window is covered or the spine ends. After a quiet period, release views entirely outside the window except one beyond each edge; when releasing a view above the viewport, subtract its extent from the offset in the same pass.

The candidate's constants: L = 500 pixels (scrolled) or one page step (paged); quiet period 350 milliseconds, deferred while scroll velocity is above 2 pixels per event; one view kept beyond each edge.

### A7. Resize

On size change: debounce (the candidate: 50 milliseconds), compare with the last laid-out size, return if equal. Otherwise remember the target: the start CFI of the last relocation report, or the pending display target if none. Discard all views, recompute A8 with the new size, then display the remembered target (EJS-36), which triggers a relocation report. On iOS, perform the layout in the view controller's size transition callback, where the final size is known, instead of the candidate's second measurement after a delay.

### A8. Layout arithmetic

Given W, H, spread policy, M, optional gap: D = (spreads allowed and W >= M) ? 2 : 1; G = supplied gap, or for reflowable paged the largest even integer not above floor(W/12), or 0 for fixed layout; C = D == 2 ? W/D - G : W; page step = W (or H for vertical writing in paged mode); spread width = C × D + G; section page count = ceil(extent / page step) × D (paged) or ceil(extent / H) (scrolled). Content box: for paged, columns of width C with gap G, body padding G/2 on the leading and trailing sides, 20 points top and bottom (the candidate's constant), a page break never inside an image; for scrolled, body padding W/12 on each side.

### A9. Package to model

Open the archive. Read `META-INF/container.xml`, take the first rootfile's full-path. Read the package document; require metadata, manifest, spine. Build the manifest map by id. Build the spine list; for each itemref record its position, idref, linear flag, properties, and compute the CFI package path (EJS-05) from the spine element's position among the package element's children. Resolve each item's href against the package directory for archive access and keep the raw href for matching. Find the nav document (properties contain nav), the NCX (media type, else spine toc attribute), the cover (properties contain cover-image, else meta name cover). Parse navigation (EJS-34) and page list (EJS-35) from the nav document if present, else from the NCX. If rendition:layout is absent, look for the Apple display options file (EJS-40). Do not touch any other resource until a section asks for it.

## Data model and persistence

What the candidate persists, and what Funston should.

Position (the candidate's relocation report, which applications persist as they like): start and end, each with spine index, href, point CFI, section page index and section page total, and optionally location index, percentage and page label; plus at-start and at-end flags. A saved position needs only the start CFI; the rest is derived on load. Funston's book_positions.locator column is opaque text and today holds Readium Locator JSON; the merged spec can keep the column and change the payload to a JSON object with a format tag, the start CFI, and the derived fields as hints, so an old Readium locator (which also carries an href and a progression) remains convertible: href plus progression maps to a section and an approximate percentage within it, which EJS-13 can turn into a nearby location.

Locations: an ordered array of CFI strings and a key of publication identifier (or content digest), algorithm version, N and spine digest (EJS-15). Size: count × roughly 40 to 80 bytes. Store as one row per publication, not one row per location; it is only ever read whole.

Annotations: type, CFI range string, spine index (derivable, stored for grouping), application data (colour, note), and timestamps. Keyed by (publication key, type, CFI range). The candidate stores nothing itself; its example application keeps them in local storage keyed by CFI range.

Navigation: not persisted; cheap to rebuild from the package.

What must never be persisted: pixel offsets, page indices as the primary position, or anything derived from a particular viewport size or font. The candidate's issue tracker is full of positions lost because an application stored a page number.

Invalidation: a changed spine order, a changed section document (different Gutenberg build), or a changed location algorithm invalidates stored positions and locations. The key in EJS-15 catches the first and third; the second is caught at resolution time by EJS-07's id-first lookup and partial-resolution flag, and the UI should say "position approximate" when a CFI resolved only partially.

## Accessibility

The candidate has no accessibility layer of its own: its content is live HTML in an iframe, read by the browser's accessibility tree, and its hidden off-screen views remain in the DOM with visibility hidden, which most screen readers skip. Nothing it does is a model for Funston's VoiceOver surface. What it does offer is the two computations that surface needs:

- Page mapping (A5) tells the reader exactly which characters are on the page, which is what Funston uses to build the accessibility elements for the visible lines (one element per line fragment, labelled with the fragment's text, framed by the fragment's rect, following the PDF reader's PDFLineAccessibleView pattern) and to decide what to announce on a page turn.
- Locations (A3, A4) and the relocation report (EJS-37) give the "page x of y" and "n percent" values for the page-scrolled announcement that the PDF reader posts after each page change, and the chapter title from the table of contents entry whose href is at or before the start CFI.

Requirements for the merged spec that this study supports:

- The relocation report is the single trigger for VoiceOver announcements; it must fire on relayout (EJS-20), or font-size changes will leave VoiceOver announcing the old page.
- In continuous mode, released views must not leave accessibility elements behind, and hidden-but-loaded views outside the viewport must not be exposed; the candidate's visibility toggling is the browser-side analogue.
- Highlights are drawn in a layer that must not become accessibility elements (the candidate's overlay disables pointer events for the same reason); VoiceOver should learn about a highlight through the line element's custom actions or a trait, not through a separate element.
- Percentage and location must be absent, not zero, when unavailable (EJS-14).
- Image-only pages must announce the image (A5, non-text pages), using alt text when present.
- Rotor navigation by heading and by link needs the document model, not the layout; the candidate never built it, and the merged spec should require headings (h1 to h6 and elements with the EPUB structural semantics for sections) and links to be addressable from the visible line elements.

## Malformed input and failure behaviour

Verified behaviours in the candidate and what Funston shall do instead:

- Missing container.xml or rootfile: the candidate throws from the container parser and the book's open promise rejects with a generic "cannot load book" error. Funston: typed error naming the missing piece.
- Missing metadata, manifest or spine element: the candidate throws with a message naming the element. Funston: same, surfaced in the "can't be opened" status with the detail.
- Itemref whose idref is not in the manifest: the candidate creates a spine item with no href; loading it rejects and the view is hidden. Funston: skip in reading order with a diagnostic; keep the position for CFI numbering.
- Section that fails to parse as XML: the candidate renders the browser's parser error document (verified by the absence of any check). Funston: lenient fallback parse plus diagnostic (EJS-42).
- XHTML in a file named `.html`: the candidate parses it as HTML and a self-closing `title` swallows the document (issue 1315). Funston: parser chosen by manifest media type (EJS-42).
- Spine itemref whose manifest item is missing (Internet Archive's cover itemref): blank first page in the candidate (issues 1138, 1340). Funston: skip with a diagnostic (EJS-39).
- `page-progression-direction="default"`: paging stops in the candidate (issue 1138). Funston: treat as left-to-right (EJS-27).
- CFI that does not resolve: the candidate returns a null range and logs to the console; callers that do not check crash (issue 1000). Funston: resolution returns a result with a partial flag and the deepest node reached; display falls back to the section start.
- Offset beyond the chunk: the candidate recovers by walking forward (EJS-08); Funston: same.
- Resize before first location: blank view (issue 1384); Funston: display the pending target (EJS-24).
- Locations requested before generation: location -1 and percentage 0 (EJS-14); Funston: nil.
- Non-numeric page labels: NaN (issue 1264); Funston: strings (EJS-35).
- Zip without a mimetype entry or with a wrong one: the candidate never checks; Funston: tolerate with a diagnostic, since real Gutenberg files are inconsistent here.
- Archive entry name encoding: the candidate percent-decodes the href before lookup and otherwise trusts the zip; Funston: the same, plus a case-insensitive second attempt with a diagnostic, since Windows-authored books sometimes differ in case.
- Scripted content: the candidate sandboxes the iframe and disables scripts by default (its README says enabling them makes the sandbox insecure). Funston renders no scripts by construction; the spec should say so explicitly.
- Memory: the candidate materialises every asset at open (EJS-41). Funston: lazy, with one section's resources in memory at a time plus the preload window.
- Bounded work: location generation on a pathological book (one spine item of 50 megabytes) is linear and cancellable (EJS-16); the CFI resolver's walk is bounded by document depth; the continuous loop is bounded by the spine length (EJS-22). The merged spec should carry a limit on section size before the reader refuses to lay it out in one piece.

## Test fixtures and vectors

Public-domain fixtures to use (by URL, none copied):

- Project Gutenberg EPUB served by Internet Archive, the stated corpus: item manandmaid20512gut, file pg20512-images.epub (https://archive.org/details/manandmaid20512gut). Covers NCX plus nav, images, a page list in newer builds, and Gutenberg's indented XHTML.
- IDPF epub3-samples (https://github.com/IDPF/epub3-samples): childrens-literature (nav document with nested toc), moby-dick (long reflowable, page list), wasteland (nav plus NCX), page-blanche (fixed layout, page spreads), cole-voyage-of-life (fixed layout, display options file), regime-anticancer-arabic (right-to-left), kusamakura (vertical writing).
- W3C epub-tests (https://github.com/w3c/epub-tests): container, package and nav conformance tests with expected outcomes.
- Standard Ebooks (https://standardebooks.org): clean, well-formed EPUB 3 with semantic inflection, for the "everything valid" baseline.

What the candidate's own tests cover (described, not copied): parsing a CFI with and without a base, with an offset, with a range; serialising back to the same string; type detection for strings, ranges, nodes and CFI objects; comparison across spine items, different depths, same depth, text steps, offsets, and lists of different lengths; generating from an element, from a text node, from a text node inside an injected highlight, and from a highlight element; generating from a collapsed range, a range across paragraphs, a range at offset 0, ranges inside, past and between highlights, and text node counting with elements between; resolving a point and a range back to the same containers and offsets, with and without highlights; location counts for a short section at 100 characters per location, with both the browser and a pure-JavaScript XML parser; text search within one node, across a tag at the end of a match, and across a tag in the middle; opening unarchived, archived, buffer, and no-cover books and reading the cover URL; URL and path resolution including file URLs.

Vectors written from the spec. Document: a section whose html element has head and body children, body being the second element child of html (step /4). The section is the first itemref of a spine that is the third child element of the package element, with itemref id `c1`, so the package path is `/6/2[c1]`. Body's children, in order: an h1 containing the text `Title`; a p with id `p1` containing the text `Hello `, an em containing `big`, and the text ` world`; a p with id `p2` containing `Second`; a p with id `p3` whose first child is an em containing `Lead` followed by the text ` tail`; a p with id `p4` containing the text `a`, an XML comment, and the text `b`; a p with id `p5` containing the text `😀x`.

| Target | Expected CFI | Note |
|---|---|---|
| the h1 element | `epubcfi(/6/2[c1]!/4/2)` | first element child of body |
| p1 | `epubcfi(/6/2[c1]!/4/4[p1])` | id assertion emitted |
| offset 2 in `Hello ` | `epubcfi(/6/2[c1]!/4/4[p1]/1:2)` | chunk before the em is step 1 |
| the em in p1 | `epubcfi(/6/2[c1]!/4/4[p1]/2)` | |
| start of `big` | `epubcfi(/6/2[c1]!/4/4[p1]/2/1:0)` | |
| the `w` of ` world` | `epubcfi(/6/2[c1]!/4/4[p1]/3:1)` | chunk after the em is step 3 |
| start of `Second` | `epubcfi(/6/2[c1]!/4/6[p2]/1:0)` | |
| start of ` tail` in p3 | `epubcfi(/6/2[c1]!/4/8[p3]/3:0)` | spec: step 3 (chunk after first element). The candidate produces `/1:0` here; that is the deviation of EJS-02 |
| the `b` in p4 | `epubcfi(/6/2[c1]!/4/10[p4]/1:1)` | one chunk across the comment, offset 1. The candidate produces `/3:0` |
| the `x` in p5 | `epubcfi(/6/2[c1]!/4/12[p5]/1:2)` | UTF-16: the emoji is two code units |
| range `Hello` start to `Second` end | `epubcfi(/6/2[c1]!/4,/4[p1]/1:0,/6[p2]/1:6)` | common path /4; end offset 6 |
| range inside `Hello ` offsets 1 to 4 | `epubcfi(/6/2[c1]!/4/4[p1]/1,:1,:4)` | common path includes the chunk; start and end are offsets only. The equivalent unfactored form `epubcfi(/6/2[c1]!/4/4[p1],/1:1,/1:4)` is what the candidate emits and must also parse and compare equal |
| (element p1, child index 1) as a point | `epubcfi(/6/2[c1]!/4/4[p1]/2)` | a DOM position before the second child normalises to the em's step; the candidate emits `/1:1`, issue 1187 |
| id `a,b` on an element | `[a^,b]` in the step | escaping |

Comparison vectors (expected sign of compare(first, second)):

| First | Second | Expected |
|---|---|---|
| `/6/4!/4/2` | `/6/2!/4/8` | later (package path decides) |
| `/6/2!/4/8/1:273` | `/6/2!/4/8/2/1:4` | earlier (1 before 2; the candidate says the opposite, issue 1200) |
| `/6/2!/4/6` | `/6/2!/4/6/8/1:0` | earlier (less specific) |
| `/6/2!/4/5:1` | `/6/2!/4/5:0` | later |
| `/6/2[x]!/4/8/1:0` | `/6/2[y]!/4/8/1:0` | equal (assertions ignored) |
| `/6/2!/4/8/1` | `/6/2!/4/8/1:0` | earlier (missing offset before 0) |

Location vectors (N = 4, counted text as given): one item with the single text `abcdefghij` gives locations at offsets 0, 4, 8 and total 2; the CFI at offset 5 maps to index 2 under "first at or after" or 1 under "last at or before". Two items of `abcdefghij` each with reset give 0, 4, 8 in each (six locations, total 5); with carry give 0, 4, 8 and then 2, 6 (five locations, total 4).

Mapping vectors: lay out `Hello big world` in a column 60 points wide with a font where each glyph is 10 points: line 1 `Hello`, line 2 `big`, line 3 `world`; a viewport covering lines 2 and 3 reports start at the `b` of big and end after the `d` of world; one covering line 1 only reports start at `H` and end after `o`.

Layout vectors: see EJS-25's test (W = 1000 gives D = 2, G = 82, C = 418; W = 390 gives D = 1, G = 32, C = 390).

## Things to avoid

Each item names the candidate's issue or code path and the lesson.

1. Numbering text steps by DOM text nodes instead of spec chunks (EJS-02; issues 470, 1187, 1358). Lesson: implement the chunk model from day one; it is cheaper than the ignore-class patch it otherwise grows.
2. Comparing decoded step indices instead of raw step integers (EJS-09; issue 1200). Lesson: compare integers; test with a chunk step against an element step at the same depth.
3. No escaping (EJS-04). Lesson: ids with commas exist.
4. Modifying the content model to draw highlights (EJS-10). Lesson: immutable model, side-table decorations.
5. Locations that count raw text node lengths, skip a character after each cut, reset per chapter, and ignore images (EJS-12; issues 744, 954). Lesson: define counted text precisely, cut exactly, decide the carry policy, and decide what a picture is worth.
6. Reporting location -1 and percentage 0 before locations exist (EJS-14). Lesson: optional fields.
7. Generating locations on the main thread with a sleep between chapters (EJS-16; issues 1110, 1405). Lesson: background task with progress.
8. Cache keys without the chunk size or spine digest (EJS-15). Lesson: key everything that changes the output.
9. Word splitting on ASCII space for visible-range detection (EJS-18). Lesson: glyph-level in a native engine; nothing to port.
10. Not re-reporting the location after a relayout, and not holding the reader's place through a font change (EJS-20; issues 982, 1194, 974, 1007, 637). Lesson: relayout is a navigation event whose target is the last start CFI.
11. Resize before the first location report leaves a blank view (EJS-24; issue 1384). Lesson: always have a target.
12. Page counts from a rounded, measured content width (EJS-25; issues 823, 1298, 1103). Lesson: count from the last line fragment.
13. Image constraints computed before padding is final (EJS-28; issue 786). Lesson: compute from the final column box.
14. Scroll compensation that fights the platform's own anchoring (EJS-23; issues 1212, 1416, 1295, 1131). Lesson: adjust offset in the same layout pass, once, and know what UIKit already did.
15. Highlights lost when views are hidden and re-shown (EJS-43; issues 1164, 1183) and drawn from stale rects after resize (issue 1226). Lesson: geometry from the live range after every layout, attach on every show.
16. Page lists parsed to integers and never resolved to positions (EJS-35; issue 1264). Lesson: strings and CFIs.
17. Materialising every asset at open (EJS-41). Lesson: lazy.
18. Parser chosen by file extension, and XML parse errors undetected (EJS-42; issue 1315). Lesson: type from the manifest, detect errors, fall back.
19. Paging decided by comparing measured scroll extents, which iOS reports differently (issue 979, next jumps a whole chapter; the cause is my inference from the paging code, the issue has no diagnosis). Lesson: page from the layout model.
20. Theme font size as a body style that absolute publisher sizes ignore (EJS-30). Lesson: scale computed sizes.
21. Hooks that exist but are never called (display, layout, show). Lesson: a stage that is not exercised by the pipeline itself is a trap for integrators; define only the stages the pipeline runs.
22. Dependence on the dc:identifier for keys when Gutenberg reuses identifiers across editions. Lesson: content digest fallback.
23. Vertical writing and right-to-left handled by special cases scattered through managers (issues 1093, 1271, 1069, 1070). Lesson: one axis abstraction (lead, trail, step) used everywhere, as in A5.
24. Treating `page-progression-direction` as a two-valued string when the spec allows `default` (EJS-27; issue 1138, which is an Internet Archive book). Lesson: model closed sets as enums with the spec's full value list.
25. A spine itemref with no manifest item blanks the book (EJS-39; issues 1138, 1340, again Internet Archive books). Lesson: a bad itemref is a diagnostic, not a dead reader.
26. Element-container range positions encoded as character offsets (EJS-06; issue 1187). Lesson: normalise DOM-style (element, child index) positions before generating a CFI.

## Open questions for the merged spec

1. Chunk size N for synthetic locations. The candidate defaults to 150 and its own example uses 1600. The Readium streamer study (RDS) found Readium's positions are ceil(archive entry length / 1024) per reflowable spine item, using the compressed size for deflated entries, which is a byte scale on the stored file rather than a text scale, and which Funston's saved position and totalProgression values currently depend on. Apple Books uses an undocumented heuristic. A value near 1000 to 1600 code units reads like a printed page; 150 gives fine-grained progress. Recommendation: one constant, named, around 1024, with the UI free to show "page x of y" at that granularity.
2. Carry across section boundaries or reset per section (A3). Recommendation: carry, so percentage reflects text read, and force no boundary at chapter starts; chapter position comes from the table of contents, not from locations.
3. Location lookup direction: first location at or after the CFI (the candidate) or last at or before. Recommendation: last at or before, so a position inside a location reports that location, and "page 1" is the first page rather than the second.
4. Replaced elements in the location count: zero (the candidate), or a fixed charge per image (for example the equivalent of 200 code units) so illustrated books have progress. Recommendation: a fixed charge, named, with the alt text not counted separately.
5. Whether to count text after whitespace collapsing (rendered text) or raw. Recommendation: collapsed, matching what the reader sees and making counts robust to re-indented builds of the same book.
6. Position payload: stay with a Readium-shaped Locator JSON with a CFI added, or a Funston-native record. Both must be convertible from the existing rows in book_positions.
7. Whether to support continuous presentation at all for sighted readers, or only as the VoiceOver mode. The candidate's continuous manager is where most of its scrolling bugs live.
8. Whether to implement text location assertions on generation (`[pre,post]`), which would make our CFIs robust to small document changes at the cost of length. The candidate does not; Apple Books does.
9. Fixed layout: full support, cover-only degradation, or "open in a web view" fallback. The corpus does not need it; the merged spec needs a stated policy.
10. A section-size limit beyond which layout is chunked or refused (see Malformed input).
11. Which search window to use (five text runs in the candidate) and whether to restrict matches to a single block.

## Clean-room statement

This document was written by reading the epub.js source at the commit named in Provenance, its tests, its README, its TypeScript declarations, and selected issues in its tracker, plus the marks-pane dependency's source. No code, comment, docstring, test data, fixture content or README text from either repository has been copied into this document or into the Funston repository. Algorithm descriptions are written from an understanding of the behaviour, in the vocabulary of the EPUB specifications, and the pseudocode in Algorithms follows the behaviour rather than the shape of the source. The test vectors in "Test fixtures and vectors" were derived from the EPUB CFI 1.1 specification text, not from the candidate's fixtures; where the candidate would produce a different value, the table says so. The cloned repositories live only in the session scratchpad outside the worktree and were neither built nor executed. Internal names of the candidate appear only in "Architecture in our words" and in issue references, as orientation.

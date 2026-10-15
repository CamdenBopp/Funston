# Funston EPUB reader: clean-room specification

Version 1, 2026-10-15. This document is the contract for replacing Readium with an EPUB reader Funston owns. It merges the eight candidate studies in this folder, resolves their open questions, and fixes the architecture. The studies stay normative for detail: every requirement below cites the study requirement IDs it adopts (RDS, RDN, FOL, EJS, YUE, SWP, STD, APL), and section 23 lists where this document overrides a study. An implementer reads this document and the studies, and nothing else from the EPUB reader ecosystem.

## 1. Purpose and scope

Funston opens born-digital EPUBs from Internet Archive (Project Gutenberg's "original" files first) through Readium 3.11 inside a WKWebView. Readium forces continuous scrolling under VoiceOver, restores positions by scroll fraction, hands VoiceOver a WebKit tree it cannot correct, and brings seven transitive packages. Camden reads with VoiceOver and low vision; the PDF reader already exposes recognised lines as VoiceOver elements with live frames, and that quality is the bar.

The replacement is a native reader: a ZIP reader, an XHTML and CSS pass that produces one attributed string per chapter, TextKit 2 pagination, page views, VoiceOver elements per block, positions keyed by EPUB CFI, and read-aloud through AVSpeechSynthesizer. No WKWebView. No third-party packages; system libraries (Foundation, Compression, zlib, libxml2, Core Text, TextKit 2, ImageIO, AVFAudio) are allowed.

Delivery is in three phases. Phase A replaces Readium with feature parity plus the VoiceOver model and durable positions. Phase B adds find, read-aloud, highlights and bookmarks, the page list and landmarks, a data-table renderer, and the problems screen. Phase C covers media overlay playback, SVG, ruby and vertical writing, MathML and fixed layout, each gated on a real book that needs it. Section 22 lists the phases in full. Everything in this document applies to Phase A unless a sentence names a later phase.

## 2. Sources and the clean-room protocol

### 2.1 The studies

| Study | File | IDs | What it covers |
| --- | --- | --- | --- |
| Standards and real corpus | Study-Standards.md | STD-01 to STD-41 | Normative EPUB 2, EPUB 3.3, CFI 1.1, media overlays and accessibility requirements; leniencies; W3C and IDPF fixtures; dissection of 14 real books |
| Apple text stack | Study-AppleTextStack.md | APL-01 to APL-47 | What TextKit 2, Core Text, XMLParser, libxml2, Compression, ImageIO, UIAccessibility and AVSpeechSynthesizer give a native renderer, with measurements |
| Readium streamer | Study-ReadiumStreamer.md | RDS-01 to RDS-59 | Container, package, navigation, locator and position models as Readium implements them, including the JSON Funston has on disk |
| Readium navigator | Study-ReadiumNavigator.md | RDN-01 to RDN-70 | Presentation behaviours, preferences, navigation semantics, restore, VoiceOver handling and its open bugs |
| foliate-js | Study-FoliateJS.md | FOL-01 to FOL-51 | CFI algorithms, position anchoring, progress, read-aloud blocks, search, overlays |
| epub.js | Study-EpubJS.md | EJS-01 to EJS-46 | CFI chunk model and comparison, synthetic locations, visible-range mapping, continuous insertion |
| Yuedu | Study-Yuedu.md | YUE-01 to YUE-88 (YUE-65 to YUE-80 reserved) | The one native text-engine reader: position identity, the limits of a flat attributed string, pagination and caching, read-aloud |
| Swift parsers and FolioReaderKit | Study-SwiftParsers.md | SWP-01 to SWP-33 | What a minimal Swift parser must get right; media overlays and read-aloud in Swift; persistence mistakes |

### 2.2 Rules for whoever implements this

1. Read this document and the eight studies. Do not open, clone, search, or quote the repositories the studies describe, or any other EPUB reader's source. The studies were written by sessions that read those sources; the implementation is written by sessions that have not. That separation is the clean room and it is what makes the result Funston's own under the MIT licence.
2. A brief for an implementation session must not name a candidate repository or ask for a comparison with one. If a question cannot be answered from the studies and the public specifications, ask the parent session to commission a new study rather than looking at source.
3. The "Architecture in our words" section of each study lists the candidates' internal names. Those names are a review denylist: none of them may appear as a type, function, file or variable name in Funston. Use the vocabulary of EPUB 3.3 and of this document.
4. The Readium streamer study session went past its brief and wrote about 2,200 lines of Swift under `Funston/Services/EPUB/` and `Funston/UI/EPUBChapterView.swift` in its worktree (`.claude/worktrees/epub-study-readium-streamer-e39988`, untracked, uncommitted). That code was written minutes after reading Readium's source and is tainted. Delete it; do not read it; do not reuse its names.
5. Public specifications (W3C EPUB 3.3, EPUB Reading Systems 3.3, EPUB CFI 1.1, OPF and OPS 2.0.1, NCX, PKWARE APPNOTE, CSS, HTML) and Apple documentation may be read freely. Public-domain books may be downloaded as fixtures by URL and must never be committed.
6. Every commit follows the standing rules: one provable behaviour per change, named axis (soundness, speed, correctness), a `Verified:` line naming the test that was watched fail, no `try!`, no force unwrap on decoded input, no magic numbers, no refactor folded into a behaviour change.

## 3. Decisions

Each decision names the question the studies left open, the answer, and the reason. The rest of the document assumes these.

**D1 Layout model: a flat attributed string per chapter, laid out by TextKit 2.** The Yuedu study shows the ceiling of this model (nested margins, floats, tables, superscripts, preformatted text) and the cost of the alternative, a CSS box-model engine of about 21,000 lines (YUE section 2, YUE-11). Funston's corpus is Gutenberg and Standard Ebooks prose. The flat model with the mitigations in section 9 covers it; the box-model engine is out of scope for every phase. Where the subset cannot express a construct, the fallback is defined and diagnosed, never silent (YUE open question 1).

**D2 Pagination engine: one NSTextLayoutManager per chapter with an unbounded container; pages are cut at line fragment boundaries by the reader.** Measured ten to fifteen times faster than TextKit 1 containers and cheaper than a layout per page (APL-22, APL section 3.6). Widow and orphan control is on at two lines (section 11.2). Core Text is reserved for Phase C ruby and vertical fragments (APL-20).

**D3 Two modes, both on the same layout, neither forced by VoiceOver.** Paginated and continuous modes share the chapter layout, the block list, the accessibility elements and the position model (RDN-01). VoiceOver does not force continuous mode (APL-36; rejects RDN-06). The mode comes from the existing `readingLayout` setting, whose default stays continuous. Continuous mode is a custom vertically scrolling surface over the same line table, not a UITextView per chapter: a UITextView is one VoiceOver element, which brings back the "next item jumps past the chapter" failure (RDN-42, Readium issue 113) that this project exists to fix. Rejects APL section 3.7's UITextView suggestion for continuous mode.

**D4 Accessibility unit: the block.** One element per paragraph, heading, list item, table cell, figure caption, image and preformatted block (APL-28, SWP-33, RDN-38, STD-32, YUE section 7). Lines are the unit for OCR text because OCR produces lines; reflowed prose reads by paragraph. Touch exploration by line comes from UIAccessibilityReadingContent on the page view (APL-29), word and character navigation from UITextInput adoption (APL-30), and page-crossing from the causesPageTurn trait. Rejects FOL section 7's line-level proposal and YUE-46's one element per page.

**D5 Position identity: a CFI into the source document, with a rendered-text offset as the fast path.** The durable key is an EPUB CFI generated over the raw parsed tree with id assertions and a text assertion (STD-30, FOL-16, EJS-06). The renderer's private key is (spine index, UTF-16 offset into the chapter's rendered string) (YUE-01), stored beside the CFI and valid only for the same parser version, release identifier and chapter length. Restore order: offset when valid, then CFI with id correction, then text context search, then progression (STD-31, FOL section 6). Page numbers are never identity (YUE-01, YUE-03, EJS section 6).

**D6 Book-wide progress scale: uncompressed byte weights, locations of 1,024 bytes.** Each linear spine item's weight is its uncompressed size from the ZIP central directory, available at open without parsing (FOL-32, YUE-34). The reader speaks and shows "Location n of m" at 1,024-byte granularity, never a book-wide page number (RDS section 7, RDN "Things to avoid"). Chapter page numbers ("page 3 of 12 in this chapter") come from the actual layout. Character-weighted progress (EJS open question 1) is deferred: it needs every chapter parsed, and the byte scale is a last-resort restore key only. Rejects RDS-43's compressed-size positions (they change with the ZIP tool) and FOL-33's 1,500-byte unit; 1,024 keeps old Readium `position` values roughly comparable.

**D7 Parsing: XML first, HTML recovery second, raw tree kept.** Chapters parse with XMLParser after an entity pre-expansion and an encoding settle; a well-formedness error re-parses the bytes with libxml2's HTML parser and records a diagnostic (APL-08 to APL-11, STD-18). The parsed tree keeps the exact child sequence including whitespace-only text and CDATA, because CFI indices count chunks (FOL-15, STD "Things to avoid"). Rejects YUE-07's HTML-first parse (it loses CDATA, processing instructions and namespaces that valid XHTML uses).

**D8 CSS: a named subset, with user settings as a user-agent override.** Section 9 lists the selectors and properties. The user's text size (Dynamic Type), alignment (start), theme colours and the publisher-styles switch win over author CSS where RDN-12 to RDN-18 say they do; everything else the author declared stands. Attribute selectors with `@namespace` are in the subset because Standard Ebooks' advanced build needs them (STD-21).

**D9 Fixed layout, vertical writing, ruby, MathML, SVG, media overlays: detect in Phase A, render in Phase C.** Phase A opens every such book: image-only spine items render as full-page images; other pre-paginated items flow their text under a persistent diagnostic banner (STD-29; rejects FOL-48's decline-to-open, because the text still serves a VoiceOver user); ruby text renders inline in parentheses (APL-20); vertical writing is ignored with a diagnostic; `math` renders its `alttext` or linearised text (STD-25); SVG images render as a placeholder carrying the `alt`, `title` or `desc` (APL-19, STD-26); media overlays are detected from the manifest and reported as narration the reader does not play (STD-28, SWP open question 2).

**D10 Read-aloud, find, highlights, bookmarks, page list, landmarks, data tables: Phase B.** The Phase A text model and block list are designed so these attach without changing the position model (sections 15 to 17).

**D11 Audio session: PlaybackController owns it; read-aloud borrows it.** Read-aloud calls the existing hand-off, configures playback with spoken-audio mode, publishes Now Playing with paragraph skip commands, and stops when music starts (APL-41, RDN-61, YUE-64, SWP open question 4). Magic Tap toggles playback while read-aloud is active and the chrome otherwise (SWP open question 3), announced through the page element's value.

**D12 Tables: flatten in Phase A, grid in Phase B.** Every table renders as its cells in reading order, one block per cell, inside a container that VoiceOver announces as a table with its row and column counts (STD-37, YUE-20). Phase B adds the attachment grid for tables that have header cells or more than one column and more than one row (APL-21, APL-34). Rasterised tables are forbidden (YUE "Things to avoid").

**D13 Notes: open in place, never jump.** A note reference opens the note's block in a sheet whose last element returns focus to the reference (STD-33, APL-35, RDN-54, FOL-49). Detection uses the EPUB 3 vocabulary, DPUB-ARIA roles, the superscript heuristic, and the Gutenberg class conventions in section 13.4.

**D14 Diagnostics are the failure path.** Three outcomes exist for opening a book: open with diagnostics, open with some chapters replaced by a "could not read this section" page, or refuse with one sentence (STD-39, STD section 8, APL-47, SWP-30). Fatal causes are: not a ZIP, no `container.xml` and not exactly one `.opf`, package document unreadable, no usable spine item, and LCP or ADEPT protection (RDS-59). Nothing else is fatal.

**D15 Persistence: the `book_positions` table and its column stay; the JSON changes.** A version field distinguishes the new record from Readium's; old rows migrate on first open (STD-31, RDS section 6, SWP section 6). Highlights and bookmarks get new tables in Phase B.

## 4. Architecture

### 4.1 Modules

Suggested placement; names are Funston's, chosen by the implementer within rule 2.2.3.

- `Funston/Services/EPUB/Container`: ZIP reading, entry table, inflate, CRC, encryption manifest, font deobfuscation (section 5).
- `Funston/Services/EPUB/Package`: `container.xml`, package document, metadata, manifest, spine, navigation sources, synthetic TOC, URL resolution, property expansion (sections 6 and 7).
- `Funston/Services/EPUB/Content`: XHTML parsing to the raw tree, semantics, CSS tokeniser and cascade, style resolution, text model builder, block list, run table, CFI generation and resolution (sections 8 to 10 and 12.1).
- `Funston/Services/EPUB/Reading`: the publication value, chapter sessions, layout sessions, page tables, progress, locators, persistence and migration, diagnostics, limits (sections 11, 12, 19 and 20).
- `Funston/UI/EPUB`: the reader controller, page container, page view, continuous surface, accessibility elements, contents list (reuse `BookContentsController`), reader controls (reuse `ReaderControls` and `ReaderPageElement`), note sheet, problems screen (sections 13, 14 and 22).

### 4.2 Data flow

1. Open: map the file, read the central directory, sniff the mimetype, read `container.xml`, parse the package document, parse the navigation document or NCX, build the publication value with diagnostics. No content document is touched (RDS "Things to avoid", SWP-31, EJS-41). Target: under 30 ms for a Gutenberg book.
2. Chapter session (per spine item, lazily): read the entry, settle encoding, pre-expand entities, parse to the raw tree (HTML recovery on failure), compute styles, build the attributed string with the run table and block list, resolve images lazily. Target: under 50 ms for a 60 KB chapter (APL-26).
3. Layout session (per chapter session and layout key): TextKit 2 layout on a background queue, line table, page table, hand-over by value to the main actor (APL-22 to APL-24). Target: under 300 ms for a 200 KB chapter.
4. Presentation: page views draw line records; the continuous surface draws tiles; both expose blocks to VoiceOver from the same line table.
5. Position: every settled relocation produces a locator (section 12.2) and the controller saves it after one second, on background and on disappear, exactly as today.

### 4.3 Concurrency

The publication value and every model type are `Sendable` value types with no implicitly unwrapped optionals (SWP-31). Parsing and layout run on a per-book serial executor; views are main-actor. A chapter's layout objects are confined to the layout queue until the line table is complete, then handed over as immutable values (APL-24). Relayout requests carry a generation number; a stale result is dropped (YUE-04, YUE-36). No timing-based waits anywhere: layout completion, not a delay, gates every reveal (RDN "Things to avoid", YUE-85).

## 5. Container

Adopts STD-01 to STD-06, APL-01 to APL-07, RDS-01, RDS-02, RDS-05 to RDS-08, SWP-01 to SWP-03, FOL-08.

### 5.1 ZIP reading

The container reader opens the file with `Data(contentsOf:options:.alwaysMapped)`, finds the end-of-central-directory record by scanning backwards over at most 65,557 bytes and validating the comment length, reads the central directory into an entry table, and supports ZIP64 records and extra fields, data descriptors (sizes and CRC always from the central directory), stored and deflated entries, UTF-8 and CP437 names, directory entries (skipped), `__MACOSX` entries (skipped) and duplicate names (last wins, diagnostic) (APL-01, APL-04 to APL-06, STD-01). Any other compression method, ZIP encryption or a split archive marks the affected entries unreadable; the book still opens unless `container.xml` or the package document is affected.

Deflated entries decode with the Compression framework in `COMPRESSION_ZLIB` mode (raw DEFLATE) into a buffer of the declared size; only a status of end with the buffer exactly full is accepted, and entries over a few megabytes decode through a bounded window loop (APL-02). Every extracted entry is checked against the central directory CRC with zlib's `crc32`; a mismatch makes the entry unreadable (APL-03). Entries are read on demand and never extracted to disk (SWP-01). The algorithm is APL section 5.6 and 5.7.

### 5.2 mimetype, container.xml, META-INF

The mimetype entry is checked (first, stored, no extra field, exactly `application/epub+zip`) and every deviation is a diagnostic, never a refusal; a file whose first four bytes are not `PK\x03\x04` is refused as "not a book this app can read" (STD-02, RDS-03, SWP-03). `META-INF/container.xml` is parsed namespace-aware; the first rootfile with the package media type is used, else the first whose path ends in `.opf`; if the file is missing or unparsable, exactly one `.opf` anywhere in the archive is used with a diagnostic, otherwise the book is refused (STD-03, SWP-04). `encryption.xml` is parsed into a map from decoded entry path to algorithm; `manifest.xml`, `metadata.xml`, `rights.xml`, `signatures.xml` and unknown files are ignored; LCP or ADEPT key information refuses the book as protected before any parsing (STD-04, RDS-05, RDS-55, RDS-59). Apple and Kobo display-option files are read only to detect fixed layout when the package does not say (FOL-12, RDS-21, EJS-40).

### 5.3 Font deobfuscation

For each resource listed with the IDPF algorithm, the key is the SHA-1 of the UTF-8 unique identifier with every U+0020, U+0009, U+000D and U+000A removed (not only trimmed, and with any `urn:uuid:` prefix kept), and the first 1,040 bytes of the inflated resource are XORed with the key cycling (STD-06, STD section 5.2, RDS-06). For the Adobe algorithm the key is the 16 bytes of the UUID in the identifier (prefix and hyphens removed) over the first 1,024 bytes (RDS-07, FOL-08). Both run behind an sfnt header check (`00 01 00 00`, `OTTO`, `true`, `wOFF`, `wOF2`, a plausible table count); a failure falls back to system fonts with a diagnostic (STD-06). An empty identifier or a bare prefix disables deobfuscation (RDS-08). The verified vector is STD section 9.7. SHA-1 comes from CryptoKit's insecure namespace (RDS open question 4: accepted).

## 6. Package document and metadata

Adopts STD-07 to STD-14, RDS-12 to RDS-31, SWP-06 to SWP-13, SWP-17, SWP-18, FOL-02, FOL-03, FOL-06, FOL-07, EJS-39.

### 6.1 Parsing and version

The package document parses namespace-aware; elements match by namespace URI and local name, never by literal prefix (SWP-06), with a fallback to local name when the OPF namespace is missing (diagnostic). `version` is read and recorded but no decision depends on it: both EPUB 2 and EPUB 3 metadata forms are read everywhere, EPUB 3 winning when both appear (RDS-13, STD-07). The legacy `dc-metadata` and `x-metadata` wrappers are accepted (SWP-06).

### 6.2 Metadata

The reader keeps an ordered list of (property URI, value, id, refines target, language, direction) from every Dublin Core and `meta` element, expanding prefixed terms through the `prefix` attribute, then the reserved prefixes, then the default vocabulary for the attribute; a `refines` value without `#` is the id itself (RDS-14, STD-14, STD section 5.3). From that list it derives: the unique identifier (the `dc:identifier` named by `unique-identifier`, else the first, else a synthetic one from the file's SHA-256 with a diagnostic) (STD-07, SWP-08); the release identifier (unique identifier plus `dcterms:modified`) (SWP-10); titles with `title-type`, `display-seq` and `alternate-script` (RDS-16); creators and contributors with MARC roles from EPUB 3 refinements and EPUB 2 attributes, `file-as` from either form (RDS-17 closes its own gap: read the EPUB 3 `file-as` refinement on creators) (SWP-09); languages (first is primary; "und" when absent, with a diagnostic) (RDS-18, STD-08); dates (RDS-19, vector V-20); subjects (RDS-20); accessibility metadata (RDS-24, STD-35); collections and series (RDS-25); rendition layout, flow, orientation and spread with per-itemref overrides recorded, never silently dropped (STD-13; fixes RDS-28); media overlay metadata (RDS-26); and everything else as other metadata keyed by expanded URI (RDS-23).

### 6.3 Manifest, spine, fallbacks, guide

Manifest items keep id, raw href, resolved container path, media type (sniffed type recorded when it disagrees), properties as a token set, fallback and media-overlay ids; items missing id or href are skipped with a diagnostic; duplicate ids keep the first; missing media types keep the item with a diagnostic (STD-09, SWP-11, RDS-27). Fallback chains are walked to their end, stopping at a repeat (STD-09; rejects RDS-29's one level). The spine keeps every itemref in order with its index stable even when the idref resolves to nothing (placeholder, diagnostic; FOL-03, EJS-39), `linear`, properties, `page-progression-direction` (`default` and absent mean left-to-right; EJS-27) and the `toc` attribute (STD-10, SWP-13). An itemref to an image or SVG item renders as a page image; an itemref to anything else unrenderable is a placeholder. Duplicate itemrefs are distinct positions. The book must have at least one usable spine item. The guide is parsed into landmarks used when the navigation document has none (RDS-30, SWP-18), and the `text` reference or the `bodymatter` landmark is the first-open start position when no saved position exists (SWP-18; Les Misérables starts with a non-linear cover wrapper, STD section 9.4).

### 6.4 Cover

Cover discovery order: the `cover-image` item; the `meta name="cover"` item by id, then by href or file name; the guide or landmark cover reference, resolved through its XHTML page's first image; the first image item whose id or href contains "cover". The rule that fired is recorded (STD section 5.3, SWP-17, FOL-06). The cover feeds the artwork pipeline and Now Playing; a missing cover is normal.

### 6.5 URL and path resolution

Every href is resolved with the WHATWG algorithm against the content URL of the document that contains it (package document, navigation document, NCX, SMIL or chapter), over a container root URL that clamps leading slashes and excess `..` to the root; the fragment is kept aside and the query dropped with a diagnostic; the path is percent-decoded and looked up exactly, then NFC, then NFD, then case-insensitively, then with `\` and `/` swapped, each fallback recorded (STD-05, STD section 5.5, SWP-19, RDS-09, RDS-10). An href that is not a valid URL is repaired by splitting the fragment and query first and percent-encoding the path (RDS-09, vectors V-01 to V-03). Remote `http` and `https` references are never fetched without consent; `file:` and `javascript:` are refused; `data:` is allowed for images only (STD-23, STD-41). The vectors are STD section 9.8.

## 7. Navigation

Adopts STD-15 to STD-17, RDS-32 to RDS-36, SWP-14 to SWP-16, FOL-04, FOL-05, EJS-34, EJS-35, YUE-51.

The navigation document (the manifest item with the `nav` property, found whether the token is first or last) is authoritative. Its `nav` elements are found anywhere in the body and classified by every whitespace-separated token of `epub:type` (fixes RDS-32 and RDS-35); `toc`, `page-list`, `landmarks` and other typed navs are read; `hidden` on a nav or list is recorded, never used to hide entries from the reader's own list (STD-15). Entry labels concatenate descendant text with `alt` then `title` for images, whitespace collapsed; an empty label becomes "Untitled section" with a diagnostic and its children are kept (fixes RDS-33). A `span` entry is a heading without a target. The NCX is used when there is no navigation document, when it fails to parse, or when its `toc` is empty; the NCX `pageList` fills a page list the nav lacks and the guide fills missing landmarks (STD-16, STD section 5.4). NCX parsing walks to any depth, treats `playOrder`, `id` and DOCTYPE as optional, keeps entries without a target as diagnostic entries, and never crashes on a missing attribute (SWP-15).

Every entry is resolved at parse time to (spine index, fragment or nil); an unresolvable entry is kept and flagged, never mapped to chapter 0 (SWP-16, YUE-51). When the resulting table of contents has fewer than two entries into the body, or every entry points into a single spine item that is not the longest, a synthetic table is built from the first `h1` to `h3` of each spine item, then the `title` element, then "Section n of m", labelled as generated (STD-17; thresholds remain to validate against a larger sample, STD open question 4). `BookContentsController` keeps consuming a tree of (label, target, children) flattened with depth (RDS-36).

## 8. Content documents

### 8.1 Decoding and parsing

Adopts STD-18, APL-08 to APL-11, SWP-07, FOL-09, EJS-42, YUE-53.

Encoding is settled before any text pass: BOM, then the XML declaration, then a `meta charset` or `http-equiv` in the first 1,024 bytes, then UTF-8; bytes that do not decode re-decode as Windows-1252 with a diagnostic; C0 controls other than tab, line feed and carriage return are stripped (APL-10). A chapter whose bytes decode under no candidate shows the "could not read this section" page rather than mojibake (YUE-53).

The decoded string passes through entity pre-expansion: every `&name;` in the HTML named character reference table becomes a numeric reference, except the five XML entities and any name the internal subset declares; an unknown name becomes U+FFFD and is counted (APL-09, APL section 5.8). The parser is XMLParser with namespaces on, prefixes off, external entities never resolved, fed `Data`, never a URL (APL-08). On a fatal error the same bytes re-parse with libxml2's HTML parser (`htmlReadMemory` with recover, no network, no error output), the tree is walked into the same model, and a diagnostic records the XML error, line and column (APL-11). If that also fails, the text is extracted by stripping tags and rendered as one paragraph with a diagnostic (APL section 8). Linking `libxml2.tbd` is a project change the implementer makes in `project.yml`.

### 8.2 The raw tree

The parsed tree keeps the document's exact child sequence: elements, text nodes as delivered (whitespace-only text included), CDATA as character data, comments and processing instructions as skippable nodes. Nothing is merged, trimmed or collapsed at parse time, because CFI steps are computed over this tree (FOL-15, STD-30, EJS-02). Each element carries name, namespace, attributes (`epub:type` arrives as a literal attribute name from both parsers and is accepted from both; APL-11), inherited language and direction, an id, and expanded `epub:type` terms and `role`. Each text node carries its UTF-16 length. Nesting is capped (section 19.3).

### 8.3 Semantics

The element set of STD-19 is interpreted with HTML semantics; `script`, `style` (after harvesting), `link`, `meta`, `template` and `noscript`'s hidden content are never rendered; `hidden`, `display: none` and `aria-hidden="true"` remove a subtree from both the visual and the accessibility tree; `lang` and `xml:lang` inherit to every text run; `dir` and `bdo` set direction (STD-19). The structural semantics of STD-20 (notes, page breaks, landmarks, front and body matter, verse, drama, and the DPUB-ARIA roles) are read into the block list for the accessibility layer; `role` wins when it disagrees with `epub:type` (STD open question 9). `pre` keeps its whitespace; `br` is a line separator; `hr` is a thought break; `dl`, `dt`, `dd`, `center`, `small`, `big`, `code`, `kbd`, `samp`, `tt` get the defaults YUE-12 lists as missing from the candidate; U+00A0 never collapses (YUE-13); `ol` honours `start`, `value`, `reversed` and `type` (YUE-15); headings are never reinterpreted as "the chapter title" (YUE-14); `sup` and `sub` rise and fall (YUE-11 edge cases).

## 9. Style

Adopts STD-21, STD-22, APL-13, APL-18, RDN-10 to RDN-20, YUE-08 to YUE-12, YUE-24, EJS-30.

### 9.1 Author style sheets

Author CSS is collected in document order from `style` elements and `link rel="stylesheet"` (a `media` attribute other than `all` or `screen` excludes the sheet), `@import` is inlined recursively with cycle detection and only from the container, `@charset`, `@page` and unknown at-rules are dropped, `@media` evaluates `all`, `screen`, `prefers-color-scheme` and `orientation` only, and `@font-face` blocks are lifted into the font registry (YUE-08, STD-21, APL-13). Parsed sheets are cached per book.

Selectors: type, class, id, universal, descendant and child combinators, attribute selectors `[a]`, `[a=v]`, `[a~=v]`, `[a|=v]` with `@namespace` prefixes, and the pseudo-classes `:first-child` and `:last-child`. Everything else (other pseudo-classes, pseudo-elements, sibling combinators) does not match and is counted per selector form. Specificity and source order follow the cascade; the origins are user-agent defaults, presentational attributes, author rules, inline style, author `!important`, inline `!important`, then the user overrides of 9.3 (YUE-09).

Properties honoured, with their mapping: `display` (none, block, inline, list-item, the table family, inline-block as inline); `font-family`; `font-size` in px, pt, em, rem, %, keywords, `smaller` and `larger`, resolved against the user base size with the computed size clamped to 0.5 to 3 times the base; `font-weight`; `font-style`; `font-variant: small-caps` (synthesised at 80 percent uppercase when the font lacks the feature); the `font` shorthand (YUE "Things to avoid"); `text-align` and `text-align-last`; `text-indent`; margins and paddings (vertical values become paragraph spacing, collapsed like CSS by taking the larger of adjacent values; horizontal values accumulate into head and tail indents through nested blocks, clamped so the remaining measure is at least 60 percent of the column; STD section 8 on Gibbon's 15 percent margins); `line-height`; `text-decoration`; `text-transform`; `letter-spacing` and `word-spacing`; `white-space` (pre, pre-wrap, nowrap); `hyphens` and `-epub-hyphens`; `color` and `background-color` (block backgrounds drawn as decoration rectangles; honoured only when the user's theme is publisher colours); `width`, `max-width` and `height` on images and tables; `vertical-align` sub and super; `float` on figures and images as block placement (no text wrap in Phase A; YUE-18's notch is Phase C); `visibility`; `page-break-before`, `page-break-after`, `break-before`, `break-after` (always, page, left, right, recto, verso all mean a page break); `page-break-inside` and `break-inside: avoid` as keep-together hints; `list-style-type`; `writing-mode` and `-epub-writing-mode` (detected, reported, not laid out in Phase A). `direction` and `unicode-bidi` in author CSS are ignored as the specification requires. Units: 1em is the computed font size, 1rem the user base size, `vw`, `vh` and `calc()` are ignored. `position: absolute` renders inline (Gutenberg page numbers). Every ignored property is counted by name in the diagnostics.

### 9.2 Built-in defaults

The user-agent defaults are the HTML rendering section's for the elements in 8.3, with the heading scale, blockquote and list indents, `pre` and code monospace, `dd` indent, `hr` as a rule, `figcaption` centred and smaller (YUE-12 plus its additions). Headings use the type scale of RDN-12 when publisher styles are off.

### 9.3 User settings and their precedence

The settings are a value type snapshot, never a global read at draw time (YUE "Things to avoid"). Phase A settings: text size (Dynamic Type body style scaled from a 17 pt base; the base is a named token; RDN-11, APL-18); reading layout (existing setting); publisher styles (new, default off, as today); alignment (start by default; justify as an option, which turns on hyphenation unless the hyphens setting says otherwise; RDN-13, APL-16); hyphenation (default off); theme (system light and dark; sepia and high contrast later; RDN-14); skip notes and page numbers in continuous VoiceOver reading (default on; STD-33). Phase B adds font family (system serif and sans, plus the accessibility fonts if licensing allows; RDN-15), line height, paragraph spacing, margins and a per-book publisher-styles override.

Precedence: text size always wins (a scale over every computed size, not a body size; EJS-30); theme colours win for `color` and `background-color` unless the user chose publisher colours (STD section 10); alignment wins over author `text-align` on body copy but not on headings, captions and quotations (RDN-13); with publisher styles off, sizes normalise per RDN-12, author fonts, colours, margins and alignment are dropped, and structural defaults still apply (STD-21); with publisher styles on, author CSS stands except where a user setting is explicitly set. A font-size change, alignment change or margins change relays out; a theme change never does (RDN-19, YUE-39).

### 9.4 Fonts

Embedded fonts load from entry bytes with `CTFontManagerCreateFontDescriptorsFromData` into a per-book table keyed by `@font-face` family, weight and style; nothing is registered with the font manager; fonts carry a cascade list whose first fallback is the user's body font; bold and italic requests for a family that embedded only a regular face synthesise through symbolic traits; a failed decode falls back with a diagnostic (APL-18, YUE-24, STD-22). WOFF and WOFF2 acceptance by Core Text is unverified (section 24, Q4). Dynamic Type scales the book font at the base size through `UIFontMetrics(forTextStyle: .body)`, never a font that was already scaled (APL-18). Elements in a language other than the chapter's keep the author's font when a user family override is active (RDN-15).

### 9.5 Images

Intrinsic sizes come from ImageIO properties without decoding; decoding happens on a background queue through `CGImageSourceCreateThumbnailAtIndex` at the larger page dimension in pixels, with EXIF transform; block images are their own paragraph, inline images sit in the line; CSS or attribute sizes are honoured then clamped to the column width and to the page height minus two margins, preserving aspect and never splitting (APL-19, RDN-67, FOL-28, EJS-28, YUE-16, YUE-82); `srcset` picks the candidate nearest the screen scale (STD-23); a missing, undecodable or SVG image renders a placeholder carrying `alt`, else `title`, else the SVG `title` or `desc`, else "image" plus the file name, with a diagnostic; `alt=""` is decorative and hidden from VoiceOver (STD-36, RDN-47); animated images show their first frame; `background-image` is ignored. A spine item whose body renders no text and exactly one image is an image page drawn aspect-fit (YUE-16).

## 10. Text model

Adopts APL-14 to APL-17, FOL-36, YUE-13, YUE-28, RDS-47, RDN-56.

### 10.1 One attributed string per chapter

Each chapter session produces exactly one NSAttributedString in which every block ends in one paragraph separator, block images are a paragraph holding one attachment character, inline images are attachments in the paragraph, every character carries a font and a paragraph style, runs in another language carry `languageIdentifier`, links carry `.link` with the resolved target, and custom keys carry heading level, element id (at the element's first character), expanded structural semantics, alt text, note reference targets and forced page breaks (APL-14). Every paragraph style carries an explicit base writing direction resolved from `dir`, then the language's script, then the first strong character, never `.natural` (APL-15, APL section 5.9, YUE-23). Lists are NSTextList values with marker formats and starting numbers; list paragraph offsets account for the synthesised marker prefix (APL-17). Hyphenation is the layout manager's `usesHyphenation` (APL-16).

Whitespace follows CSS: runs collapse to one space, leading and trailing spaces at block boundaries drop, `pre` and `pre-wrap` preserve, `br` is U+2028, U+00A0 and U+3000 survive (YUE-13).

### 10.2 The run table and the block list

Beside the string, the chapter session keeps two tables.

The run table maps rendered UTF-16 ranges to source positions: for each run, the source text node, the source UTF-16 offset of its first character, the rendered start offset, the rendered length, and the collapse adjustments (positions where whitespace was dropped or merged). It converts a rendered offset to (node, offset) and back; an end offset that equals a node boundary maps to the end of the earlier node (FOL-36). This table is what CFI generation, find, read-aloud and VoiceOver use to cross between the layout and the document.

The block list is the ordered list of blocks: rendered range, kind (paragraph, heading with level, list item with ordinal, table and cell with row and column, figure, caption, image, preformatted, quotation, note body, page break with label, thought break), element id, language, alt text, inner links (range, target), note references (range, target), container membership (list, table, note, aside), and the structural semantics terms. Blocks with no rendered text and no image are dropped. It is the accessibility layer's and read-aloud's unit (RDS-47 with the heading, list and table roles the candidate lacked; APL section 6.5).

### 10.3 Offsets

Every offset in Funston's EPUB code is a UTF-16 offset. `String.count` is never used for positions; `utf16` views and NSString ranges are (STD "Things to avoid", EJS-03, FOL-15).

## 11. Layout and pagination

Adopts APL-22 to APL-27, APL-46, FOL-21 to FOL-26, FOL-30, RDN-02 to RDN-05, RDN-26, RDN-27, EJS-25, YUE-02 to YUE-04, YUE-25, YUE-26, YUE-30 to YUE-36, YUE-84.

### 11.1 Page geometry

The page content size is the reader view's bounds minus insets: horizontal margins from the readable content guide, a top inset that includes the safe area and a bottom inset that includes the controls when visible, stable across chrome changes so toggling the bars never scrolls the text (RDN-05). One column on compact widths; two columns when the content width is at least 60 times the base font size or a phone in landscape, with the line length capped at 40 times the base size and the text block centred (RDN-04, FOL-21). These are named tokens in one place.

### 11.2 Pagination

A layout session creates one NSTextContentStorage, one NSTextLayoutManager (hyphenation from the settings), one NSTextContainer of the content width and unlimited height with zero padding, calls `ensureLayout` for the document range, enumerates layout fragments and line fragments into a line table (document range, frame, fragment and line references), and cuts pages where a line's bottom would cross the page height (APL-22, APL section 5.1). Rules on the cut: a forced break before an element's first line always cuts; a keep-together range that would straddle a cut moves whole to the next page unless it is longer than a page (YUE-26); widow and orphan control moves a cut up by at most two lines so no paragraph leaves a single line on either side (decision on APL open question 14 and YUE open question 4: on, two lines, no bottom distribution); a line taller than a page gets a page of its own; the synthesised trailing empty line is skipped. Two-column pages are two consecutive column cuts of half the width each (RDN-04). Pages are never bottom-aligned by distributing slack (rejects YUE-38).

A page record is (first line, last line, page top, first offset, end offset). Position to page is a binary search on first offset; point to line is a binary search on y (APL section 5.1). Pages are never persisted as identity (YUE-01). A chapter over 20,000 UTF-16 units lays out in two passes: one page first, installed as a partial layout whose next-page walker hands out the first unmeasured offset, then the whole chapter (YUE-32, YUE-02). A chapter over 300 KB of rendered text splits into sections at paragraph boundaries that paginate as sub-chapters (APL-46).

### 11.3 Drawing

A page view draws its line records with `NSTextLineFragment.draw(at:in:)` at fragment origin plus typographic bounds origin minus page top, never adding `glyphOrigin`; selection and highlight rectangles are drawn first, decoration rectangles for block backgrounds and borders before text, attachments by the fragment (APL-23, APL section 5.2, YUE-37). Rectangles for any rendered range come from `enumerateTextSegments` clipped to the page; VoiceOver frames come from the line table (APL-25, APL section 5.3).

### 11.4 Continuous mode

The continuous surface is a vertical UIScrollView whose content is the chapter's line table drawn in tiles, with the same margins, the same block elements for the visible blocks plus one screen of lookahead, and explicit crossing: scrolling past the end of a chapter, or VoiceOver's scroll request at the end, replaces the surface with the next linear chapter at its top (previous at its bottom), which has already been laid out (RDN-03, RDN-24 as amended, FOL-30, FOL-26). Insertion of content above the viewport never moves the reader's text: offset adjustments happen in the same layout pass (EJS-23). Decision on RDN open question 2: per-chapter surfaces, not one book-long surface.

### 11.5 Relayout and the anchor

Before any relayout (text size, alignment, margins, hyphenation, rotation, size class, mode switch, embedded font arrival) the reader captures the anchor: the first visible line's rendered offset and its block, plus the current locator; after layout it shows the page or scroll position containing that offset, and only if the offset is gone (edition change) falls back to the locator's CFI, text and progression (FOL-23, RDN-36, YUE-04, SWP-25, EJS-24). A relayout that starts while another runs supersedes it by generation. Relayouts while the app is inactive are deferred (RDN-27, RDN-28). Rotation during loading displays the pending target, never a blank view (EJS-24).

### 11.6 Caching and memory

At most three chapter layouts are resident (current and neighbours); the next chapter lays out in the background when the reader is within two pages of a boundary; layouts beyond the window are dropped; decoded images live only at drawn size; on a memory warning or when available memory falls below 200 MB every non-current layout and decoded image is shed (APL-46, RDN-26, YUE-33, YUE-35, YUE-81). Page frames beyond the visible page and its neighbours are not retained (YUE-84). Page-start offsets are cached per chapter under a layout key (content size, base size, family, content size category, line height, spacing, margins, alignment, hyphenation, publisher styles, OS version, parser version, embedded font hash) in memory in Phase A and optionally in `cache_entries` later (APL-27, APL section 6.1).

## 12. Positions and progress

### 12.1 EPUB CFI

Adopts STD-30, STD section 5.6, FOL-13 to FOL-20, EJS-01 to EJS-11, YUE-52.

The CFI module parses the full CFI 1.1 grammar (steps, indirection, id and text assertions, character, temporal and spatial offsets, side bias, vendor parameters, ranges, circumflex escaping), rejects malformed strings with the offset of the first bad character, and serialises canonically so that parse then serialise is the identity (FOL-13, FOL-14, EJS-04). Child indexing follows the chunk model over the raw tree: element children at even indices from 2, character-data chunks at odd indices with empty chunks between adjacent elements, adjacent text and CDATA merged into one chunk, comments and processing instructions ignored, virtual positions 0 and n+2 accepted (FOL-15, EJS-02, STD section 5.6). Offsets are UTF-16 code units; one that splits a surrogate pair rounds down (STD-30).

Generation walks from the position to the document element, emitting id assertions for every element with an id and a text assertion of up to 32 characters each side at the leaf, then the package path computed from the real package document (the spine element's actual index, the itemref's index and id), never an assumed `/6` (FOL-16, FOL-19, EJS-05). A position expressed as (element, child index) normalises to the chunk or element step before serialising (EJS-06). Ranges take the longest common prefix as the parent path; "has an offset" means present, not non-zero (FOL-20).

Resolution checks id assertions at every element step, corrects by id when the index disagrees (recording "corrected by id"), falls back to the index when the id is absent from the document (recording partial resolution; decision on EJS-07 versus CFI 3.5: fall back rather than refuse), carries an overflowing offset forward through the chunk (EJS-08), checks the text assertion and records a mismatch, resolves the spine step by id then index and drops an id that names a non-itemref, and returns a value naming the failing step and reason, never an exception (FOL-17, FOL-19, EJS-07). Temporal and spatial offsets and text assertions are carried, not used (EJS-11).

Comparison strips assertions, compares package paths then document steps by raw integers (a chunk step 1 sorts before an element step 2 at the same depth), treats a shorter path as earlier, compares offsets with a missing offset as 0, then temporal before spatial with y before x; ranges compare by start then end (STD section 5.6, EJS-09, FOL-18). The vectors are STD section 9.6 (25 parses, 21 orderings, the malformed set), FOL section 9 and EJS section 9; all three sets must pass.

### 12.2 The locator

Adopts STD-31, RDS-37 to RDS-42, RDN-37, FOL section 6, EJS section 6, SWP-25, YUE-56.

The persisted record is JSON in `book_positions.locator`, sorted keys, no escaped slashes, no nulls:

```
{
  "v": 2,
  "href": "OEBPS/ch3.xhtml",
  "spineIndex": 3,
  "cfi": "epubcfi(/6/8[ch3]!/4/10[p12]/1:0[,The next])",
  "offset": 18422,
  "chapterLength": 61230,
  "parser": 1,
  "progression": 0.3009,
  "totalProgression": 0.1844,
  "location": 212,
  "text": { "before": "…up to 64 characters…", "after": "The next morning…" },
  "title": "Chapter III",
  "release": { "identifier": "http://www.gutenberg.org/ebooks/20512", "modified": null },
  "savedAt": "2026-10-15T14:02:11Z"
}
```

`offset` is the rendered UTF-16 offset of the first visible character (continuous mode) or of the page's first character (paginated mode); `chapterLength` and `parser` validate it. `progression` is `offset / chapterLength`; `totalProgression` and `location` come from the byte scale of 12.3. `text` holds up to 64 characters of rendered text before and after the position, whitespace collapsed. `release` carries the package's unique identifier and `dcterms:modified` so a different edition is detected (SWP-10, YUE-56).

Restoring: if `release` and `parser` match and the chapter's rendered length equals `chapterLength`, use `offset`; else resolve `cfi` (section 12.1) and map the source position to a rendered offset through the run table; else search the chapter for `text.after` preceded by `text.before` (exact, then approximate with the 50/20/20 scoring of RDN-52); else `progression` of the chapter; and if `href` matches no spine item, `totalProgression` of the book (STD-31, RDN-21 as amended). Each fallback is recorded and the reader says "approximate position" once when it had to fall past the CFI (RDN section 8).

Readium rows (no `v`) are read as: `href` (strip a leading slash; match normalised, then without fragment), `locations.fragments` (scroll to the first id), `locations.cssSelector` (evaluate the subset of RDS-48 against the raw tree), `locations.progression`, `locations.totalProgression`, `text` (RDS-38, RDS-40, RDS section 6 field table). They resolve as fragment, then selector, then text, then progression, then total progression, and a version 2 record is written on the next save. No schema migration is needed; the table and the one-second debounce stay (RDS section 6, SWP section 6).

A navigation-only fragment (a contents tap) is stripped before saving so a restore lands where the user read, not at the section start (RDN-35).

### 12.3 Progress and locations

Each linear spine item's weight is its uncompressed size from the central directory (zero for non-linear items and placeholders); cumulative fractions give each item's start; the book fraction of a position is (bytes before the item plus the item's fraction times its weight) divided by the total, where the item's fraction is `offset / chapterLength` (FOL-32, YUE-34). A "location" is 1,024 bytes of that scale: the current location is floor(bytes through the position / 1024) and the total is ceil(total / 1024) (decision D6). The inverse maps a fraction to an item and a proportional offset for the scrubber and for Readium `totalProgression` fallbacks (FOL section 5, RDS-42, vectors V-09 to V-11 reinterpreted for uncompressed sizes). The UI and VoiceOver say "Location n of m" and, in paginated mode, "Page p of q" for the chapter; a book-wide page number is never shown (RDN "Things to avoid", STD "Things to avoid"). When a book has a page list, the current print page label is shown and announced instead (FOL-35, STD-34; Phase B).

### 12.4 Reporting the current location

A relocation report is produced after a display request completes, after every page turn, when scrolling settles (one report, 0.3 s after motion stops, coalesced per frame), and after every relayout; reports during an in-flight navigation or while the app is inactive are deferred; a report equal to the last one is suppressed (RDN-31, EJS-20, RDN-28). The report carries the locator, the visible range (first and last rendered offsets), the chapter page index and count, the location, the table-of-contents entry (FOL-34), the page label when any, and at-start and at-end flags (EJS-37). The controller saves one second after the last report, on background and on disappear, as today (RDS section 6).

## 13. Reading behaviours

### 13.1 Going somewhere

Adopts RDN-21 to RDN-25, RDN-29, FOL-25, EJS-36, YUE-05.

Targets are a spine index, an href with optional fragment, a CFI, a locator, a book fraction, or a location. Resolution inside a chapter tries, in order and falling through on failure: the rendered offset when valid, the CFI, the fragment id (then an `a name`), the text context, the CSS selector (Readium rows), then progression (RDN-21 amended, YUE-05). The target's first line is placed at the top in continuous mode and its page is shown in paginated mode, snapped to a page boundary; a tiny inline target selects the page containing its start (RDN-23). Navigation is serialised with "last request wins": a jump requested while another is in flight replaces it rather than being dropped (RDN-25). A jump is reported distinctly from a page turn so a back stack can be kept; the back stack holds the departure locator for links and contents taps (RDN-29, FOL-50).

Forward and backward move one page in paginated mode and one visible height in continuous mode; at a chapter's end they enter the next linear chapter at its first page (previous at its last), skip non-linear items, and return false at the book's ends without moving (RDN-24, FOL-25, YUE-02). The existing adjustable page element's increment and decrement call them (section 14.3).

### 13.2 Page progression and direction

Page order follows `page-progression-direction`; left and right map through it; VoiceOver scroll directions swap for right-to-left; a right-to-left book's chapters sit in the container right to left; text direction comes from the content, never from the spine attribute (RDN-07 to RDN-09, YUE-06, SWP-28). Two-column spreads never pair two spine items in reflowable books (RDN section "Reading progression").

### 13.3 Links

Internal links resolve against the chapter's URL to a spine item and fragment and navigate with the departure recorded; a fragment that does not exist lands at the document start with a diagnostic; a link to a manifest resource outside the spine opens it in place when it is an image or a non-linear document, else does nothing with a diagnostic; `http`, `https`, `mailto` and `tel` links ask before leaving the app; `javascript:` and `file:` links are refused (STD-27, RDN-53, FOL-50, EJS-33, SWP-29). Taps on links never toggle the chrome or turn pages (RDN-55).

### 13.4 Notes

A link is a note reference when its `epub:type` contains `noteref`, `biblioref` or `glossref`, or its `role` is `doc-noteref`, `doc-biblioref` or `doc-glossref`; when it is not a backlink and is, contains only, or sits inside a superscript (`sup`, or `vertical-align` super, top or text-top); or, for the Gutenberg conventions, when its class contains `fnanchor` or `noteref`, or its target id begins with `Footnote_`, `fn`, or `note` and the target block is in a container whose class contains `footnote` or `note` (FOL-49, STD-33, STD section 9.4, RDN-54, YUE-29). The note body is the target element, or its nearest block ancestor when the target is inline (Les Misérables' empty anchor as the first child of the note paragraph), or the next block sibling when that ancestor is the body. Activating a reference presents the note's blocks in a sheet whose first element is the note text and whose last element is "Return to text"; the note's own backlink is that return path; the reading position does not move (STD-33, APL-35). A plain link to a note body (no reference semantics) navigates like any link. The superscript heuristic can be turned off per book when it misfires (FOL open question 12).

### 13.5 Contents, landmarks and page list

The contents sheet is the existing list, fed by section 7's tree and indented by depth; under VoiceOver each row announces its level (RDN section 7 issue 177). A landmarks menu offers cover, start of reading, table of contents and notes when present; "Start reading" goes to the `bodymatter` landmark or the guide `text` reference (STD-34, SWP-18). Phase B adds "Go to page" from the page list and the page-break elements in content (STD-34, EJS-35).

### 13.6 Input

Taps that the content did not handle toggle the chrome, except under VoiceOver, where Magic Tap toggles it and taps do nothing; edge-zone taps turn pages in paginated mode (the zone is the larger of 80 pt and 30 percent of the width, direction-mapped); keyboard arrows, space and page keys turn pages by physical key code; Reduce Motion disables page animations; pinch zoom is not offered on reflowable text (RDN-45, RDN-46, RDN-64, RDN-65). Selection gestures take precedence over the tap-to-toggle gesture (APL-43).

## 14. Accessibility

Adopts APL-28 to APL-38, STD-32 to STD-38, STD section 7, RDN-38 to RDN-47, SWP-33, YUE section 7, FOL-31. Nothing in this section is done until it runs under VoiceOver (14.6).

### 14.1 The element model

Each page (or, in continuous mode, the visible region plus one screen) exposes through `accessibilityElements`: first the existing "Reading page" adjustable element (APL-38), then one element per block in reading order. A block element has the block's text as its label; an attributed label carrying `accessibilityTextHeadingLevel` for headings and `accessibilitySpeechLanguage` for runs in another language; traits static text, plus header for headings, link for a block that is wholly a link, image for images; `accessibilityTextualContext = .narrative`; a frame computed from the line table on every read (never cached as screen coordinates); previous and next text navigation elements linking neighbours on the page (iOS 18); custom actions for inner links ("Open link: text"), note references ("Show note") and, in Phase B, highlights; and the causesPageTurn trait on the last element of the page (APL-28, APL section 7.4). A paragraph split across pages is two elements, one per page. Empty blocks, Gutenberg's empty page-number spans and paragraphs that are only `br` never become elements (STD "Things to avoid"). Off-page blocks are not exposed (RDN section 7).

Containers: a list's items sit in a container of type list whose label gives the item count; a table's cells sit in a container of type data table with row and column ranges and header cells from `th` (Phase B grid) or a semantic group announcing "table, r rows, c columns" (Phase A flatten); a note body is a semantic group labelled "note n"; the page view itself is a semantic group labelled with the chapter title (STD-37, APL-34, STD section 7.2 table). Container start and end are invariants (CLAUDE.md).

Page breaks (`epub:type="pagebreak"`, `role="doc-pagebreak"`, Gutenberg `span.pageno` with a `title`, anchors whose id starts with `Page_`) are skippable elements labelled "page 14" when the skip setting is off, and feed the current page label either way (STD-34, STD section 7.2). Images carry `alt` or the fallbacks of 9.5; `figcaption` is its own element; `aria-describedby` and `longdesc` become a "Description" action (STD-36). Inline SVG and `math` are elements labelled from their alternatives (STD section 7.2).

### 14.2 Reading content and text navigation

The page view implements UIAccessibilityReadingContent over the line table: line number for a point by y then x (NSNotFound in gutters), attributed content per line with speech languages, line frames in screen coordinates, and the page content with paragraph separators; it implements `accessibilityScroll(_:)` mapping next, left and down to forward and previous, right and up to backward (swapped for right-to-left progression), returning false at the book's ends and posting `pageScrolled` with "Page p of q" (chapter-relative) on success, never `layoutChanged` in that path (APL-29, APL section 5.4 and 5.5, RDN-40). The page view adopts UITextInput in full with custom position and range types over rendered offsets, a tokenizer that implements line granularity from the line table, selection rectangles from text segments, `isEditable` false, and a non-editable UITextInteraction (APL-30). Custom rotors exist for headings (and levels when more than one), links, images and chapters, searching the block list across pages and turning the page when the next match lies elsewhere (APL-31).

### 14.3 Page turning, focus and announcements

After a manual page turn the reader posts `layoutChanged` with the new page's first block; after a chapter change, `screenChanged` with the first block; after a relayout, `layoutChanged` with the block containing the previously focused offset; after a jump from the contents, a link or a search result, focus moves to the target's first element (RDN-41, APL-33, FOL-31). While VoiceOver's own read-all is turning pages (detected by `accessibilityScroll` having been called by VoiceOver) nothing is posted that would move focus (APL-33). The adjustable page element keeps its value ("Chapter 3, page 4 of 12" or "Location 212 of 940"), increment and decrement call forward and backward, Magic Tap toggles the chrome or playback (D11), and the custom action mirrors it (APL-38, STD section 7.3). Highlights and the spoken utterance are values and actions on the block element, never separate or invisible elements (RDN-43).

### 14.4 Languages, Speak Selection, system speech

Runs in another language carry the speech language attribute and, in read-aloud, their own utterance and voice (APL-32). Speak Selection and Speak Screen work on the page's text through UITextInput and the reading content protocol; Accessibility Reader gets the page's accessible text (APL section 7.5). Read-aloud never auto-starts under VoiceOver and never posts announcements while speaking (APL-42, SWP-33).

### 14.5 Accessibility metadata

The book's detail screen shows EPUB Accessibility 1.1 metadata as sentences ("Conforms to WCAG 2.2 level AA, certified by Standard Ebooks"; "No accessibility metadata"), never raw tokens; a book with many images lacking alternatives says so in its problems list (STD-35, STD-36, RDS-24). Phase B.

### 14.6 Verification

The checklist is APL-37 (14 items) plus STD section 7.4 (focus order equals document order, no empty label, heading levels, links in the rotor, container start and end, notes open and return, page labels skippable, languages switch voices). It runs with the `ios-sim-voiceover` tooling on the simulator and on Camden's iPhone after every change to the accessibility layer, against Man and Maid chapter 1, Moby Dick (Standard Ebooks) chapter 1, Poems of the Great War, Elektra and a Factbook page. Two experiments decide open points before the element code is final: which object receives the reading content protocol methods when the page has child elements, and whether the Lines rotor crosses a page boundary when the last block's next element is nil (APL open questions 1 and 2). A code-structure check is not evidence (CLAUDE.md).

## 15. Read-aloud (Phase B)

Adopts APL-39 to APL-42, RDN-56 to RDN-63, SWP-22, FOL-37 to FOL-39, YUE-57 to YUE-64.

Narration units come from the block list: one utterance per sentence within a block, split with the natural-language sentence tokenizer for the block's language, never inside a ruby base, punctuation-only fragments folded into the previous utterance, each utterance carrying its rendered range (YUE-58, RDN-57). Headings get a longer post-utterance delay; image alt text is spoken as "Image: …"; table cells are spoken row by row (APL-39, YUE-57). Each utterance is an AVSpeechUtterance built from an attributed string so IPA hints carry through, with a voice for its language (run language, else publication language, else the user's chosen voice, else the system default), `prefersAssistiveTechnologySettings` on, rate from the reader's presets (shared with the player's speed conventions), and two utterances queued ahead across page and chapter boundaries, the next chapter's narration coming from its parsed text without waiting for layout (APL-39, YUE-60, YUE-61, RDN-59). The spoken word range highlights through a rendering attribute mapped by the utterance's block offset; the page turns when the spoken range leaves the screen and not otherwise; pause is at a word boundary; resume continues the utterance or re-speaks its unspoken tail; next and previous step by utterance and by chapter; a user who navigates away is offered "return to narration" (APL-40, RDN-62, YUE-59, YUE-63). The engine never submits a new utterance before the previous one's start or finish callback (RDN-60). The audio session follows decision D11; interruptions pause and resume on `shouldResume`; route loss pauses; a media services reset re-speaks the current utterance's tail (APL-41, YUE-64). Pronunciation lexicons (`application/pls+xml`) and `ssml:ph` apply at word boundaries (YUE-62).

## 16. Find (Phase B)

Adopts APL-44, RDS-50 to RDS-52, FOL-40 to FOL-42, EJS-46.

Find uses UIFindInteraction with a UITextSearching document spanning the book; `performTextSearch` runs over every chapter's rendered text on a background queue with case- and diacritic-insensitive matching by default and the session's word-match option, reports ranges per chapter document, decorates found and highlighted ranges with rendering attributes, and scrolls to a result by laying the chapter out first; results order by spine index then offset (APL-44). Matches never cross chapter boundaries; within a chapter they may cross block boundaries when the query does (RDS-52, EJS-46). Excerpts show the matched text with up to 50 characters of context each side across blocks (FOL-42). Whole-word search uses the segmenter (FOL-41). Alt text and hidden content are not searched (RDS-52).

## 17. Highlights, bookmarks and selection (Phase B)

Adopts APL-43, RDN-48 to RDN-52, SWP-23, SWP-24, FOL-43 to FOL-45, EJS-43 to EJS-45, YUE-42 to YUE-45.

Selection is the UITextInput adoption of 14.2 with the system interaction; the edit menu offers Copy, Share, Look Up, Speak (enqueues in read-aloud) and Highlight; a selection reports a locator with the selected text and up to 200 characters of context trimmed at word boundaries (RDN-48, RDN-49, YUE-43). A highlight is stored in a new table keyed like positions, with a range CFI, a text-quote selector (exact text, 32 characters each side), the rendered range as a hint, a style (highlight or underline), a colour from a named set, an optional note, timestamps and the release identifier; it renders as rendering attributes over the resolved range, one rectangle per line, recomputed after every relayout; it is re-anchored by CFI, then quote, then position, and kept as orphaned when nothing resolves (SWP-23, RDN-50 to RDN-52, FOL-45, EJS-43, EJS-44). Overlapping same-colour highlights merge (YUE-44). Under VoiceOver a highlighted block reads with a "highlighted" value and offers "Remove highlight" and "Open note" (RDN-43). A bookmark is a locator with the chapter title and a 120-character preview; "this page has a bookmark" is answered by range containment, never offset equality (SWP-24, YUE-45).

## 18. Scope-limited formats

Adopts STD-25, STD-26, STD-28, STD-29, RDN-66, FOL-46 to FOL-48, EJS-26, SWP-20, SWP-21, FOL-10, FOL-11, APL-20.

Media overlays: the manifest's `media-overlay` attributes are recorded at open; SMIL parses lazily into a tree of `seq` and `par` nodes with `epub:type`, text targets resolved to (spine index, fragment), audio targets with `clipBegin` and `clipEnd` parsed by the full clock-value grammar (missing begin is 0, missing end is the file's end, a parse failure is nil with a diagnostic, never 0) (SWP-20, FOL-10, RDS-26). The UI says the book has narration the reader does not play. Phase C playback follows FOL-11 and SWP-21 (clock-driven by boundary observers, never a polling timer; skippable and escapable structures honoured).

Fixed layout: detected from `rendition:layout`, the itemref overrides, and the Apple or Kobo files; in Phase A image-only items are page images and others flow their text under a banner; Phase C spreads and viewports follow FOL-46, FOL-47 and EJS-26 (STD-29, D9).

Vertical writing and ruby: detected (writing mode in CSS or the content, `ruby` elements); Phase A ignores vertical writing with a diagnostic and renders `rt` inline in parentheses; Phase C draws those paragraphs with Core Text inside custom layout fragments (APL-20, YUE-19). Direction-agnostic page arithmetic is written now (FOL-27).

MathML and SVG: section 9.5 and D9. Phase C may add a Core Graphics rasteriser for the simple SVG Gutenberg uses (rules, drop caps), bounded by a watchdog and size limits (YUE-83).

## 19. Diagnostics, failure behaviour, limits and security

Adopts STD-39 to STD-41, APL-47, SWP-30 to SWP-32, RDN-70, FOL-51, RDS-58, RDS-59, YUE-85, YUE-86.

### 19.1 Diagnostics

Every lenient decision, missing resource, ignored property, recovery parse, fallback match and failed resolution is a diagnostic value: stage (zip, container, package, navigation, chapter.decode, chapter.parse, chapter.recover, css, font, image, layout, position, a11y, speech), archive path or spine index, a stable code (for example `mimetype.missing`, `container.rootfile.fallback`, `xml.tagsoup`, `href.caseFallback`, `font.deobfuscationFailed`, `nav.synthetic`, `position.approximate`, `css.ignoredProperty`), a one-sentence message and a count. Diagnostics live on the publication value and the chapter sessions, mirror to OSLog, and are shown on demand in a "Problems with this book" list (Phase B UI; Phase A has a debug screen). They are never printed. Tests assert on codes (STD-39, STD section 6, APL-47, SWP-32).

### 19.2 What the user sees

Not a ZIP, no container and no single OPF: "The file isn't a book this app can read." Unreadable package, empty spine, protected content: "The book's file looks damaged. Try downloading it again." or "This book is protected and can't be opened here." A chapter that cannot be decoded, parsed or laid out shows a page in its slot saying so, with forward and backward still working (RDN section 8, FOL-51). A saved position that could not be resolved exactly says "approximate position" once. A link whose target is not in the book says so. A fixed-layout, vertical or narrated book shows its banner. A blank page, a crash, a silently skipped chapter or a lost position are bugs by definition (STD section 8).

### 19.3 Limits

Before decoding: a per-entry decompressed cap and a whole-book cap derived from available memory; an entry count cap; an XML nesting depth cap; an entity-expansion cap on internal subsets; a time budget per chapter build and per layout after which the chapter renders as plain text with a diagnostic; and lazy chapter parsing with three resident layouts (STD-40, YUE-85, APL-46). TextKit 2's `limitsLayoutForSuspiciousContents` is enabled once the experiment in APL open question 6 shows it leaves corpus layouts unchanged.

### 19.4 Security

No remote fetch without consent and then only `https`; no `file:` URLs; no scripts; ZIP entry names are data (no traversal into any cache directory; nothing is extracted to disk in Phase A); text in books, including metadata, is content to display and never an instruction to anything (STD-41, RDN "Things to avoid"). All decoded input is bound with `guard let`; `try!`, `!` and `as!` are forbidden on it (CLAUDE.md, APL "Things to avoid").

## 20. Performance

Budgets on an iPhone-class device, measured with signposts named `epub.zip.open`, `epub.chapter.parse`, `epub.chapter.style`, `epub.chapter.layout`, `epub.page.draw`, `epub.find.search`, `epub.a11y.query` and `epub.speech.enqueue` with the chapter href and byte size as metadata (APL-26): open under 30 ms; parse and style under 50 ms for a 60 KB chapter; layout under 300 ms for a 200 KB chapter; page draw under 8 ms; VoiceOver line or frame query under 1 ms; chapter open to first page under 500 ms warm and 1 s cold. Chapter build, not pagination, is where real readers lose time (font probing, image decoding on the build path, stylesheet parsing), so images decode off the build path, missing fonts are negatively cached per book, and parsed sheets are shared (YUE-87, YUE-81). XCTest performance tests with committed baselines guard each budget (APL-26).

## 21. Test plan

### 21.1 Unit vectors from the studies

The following vector sets are normative and must pass as written: STD section 9.6 (CFI parse, rejection, ordering, round trip), 9.7 (font key), 9.8 (href resolution), 9.9 (property expansion); FOL section 9 (CFI parse, child indexing and round trip over document A, package document B, comparison, page geometry, visible range, progress, clock values, obfuscation, search, blocks); EJS section 9 (CFI generation table, comparison table, location and mapping vectors); RDS V-01 to V-23 (with V-09 to V-11 recomputed over uncompressed sizes and 1,024-byte locations); RDN section 9 vectors 1 to 12; SWP V1 to V21; APL section 9.1 (ZIP fixtures), 9.2 (XHTML cases), 9.3 (layout fixtures), 9.4 (accessibility fixture); YUE section 9 vectors 1 to 26. Where two sets disagree, this document's decisions resolve it and the test pins the decision.

### 21.2 Fixture builder

Tests build EPUBs in memory from a dictionary of entry name to bytes, controlling the mimetype order and compression, so no test depends on a third-party fixture or an absolute path (SWP section 9, YUE-88). Public-domain books (the corpus of STD section 9.4, the IDPF samples, the W3C tests) are downloaded by URL into a cache and the tests that need them are gated like `FunstonUITests`.

### 21.3 Conformance

The W3C epub-tests table in STD section 9.1 is the conformance report: every row marked P must pass, every row marked D must open with the named diagnostic, and the result file is committed with each release.

### 21.4 Corpus

Every book in STD section 9.4 opens, lists its contents, renders every chapter with no lost text (the extracted text order equals the XML text order), restores a saved position within one line after a text size change, and produces the expected diagnostic codes (the guide-image covers, the `tag` attributes, the synthetic TOC for Shiji and Relativity, the page list of Poems of the Great War).

### 21.5 VoiceOver

Section 14.6. Recorded per release in `Docs/EPUB/VoiceOver-<date>.md` with what was run and what was heard.

### 21.6 Regression discipline

Every test is seen red before it is green (CLAUDE.md). Every bug class found in a candidate's issue tracker that this document names (percent-based restore, next-item jumps, blank chapter on a bad itemref, locations before generation, page counts from rounded extents, scroll compensation fighting the platform) gets a test named after the behaviour.

## 22. Delivery and integration

### 22.1 Phase A (replaces Readium)

Container, package, navigation and synthetic TOC; chapter decoding, parsing and recovery; semantics; the CSS subset; fonts and images; the text model with the run table and block list; CFI; locators with migration; progress and locations; TextKit 2 pagination and the continuous surface; relayout anchoring; page views and drawing; go-to, page turns, links, notes in a sheet, contents and landmarks; the full VoiceOver model with the verification checklist; diagnostics, limits and the debug problems screen; performance tests; the conformance run. Fixed layout, vertical writing, SVG, MathML and overlays detected and degraded as in section 18.

Integration points: `EPUBReaderController` is rewritten around the native reader (same download lease, same status pages, same save cadence, same `BookContentsController`, same `ReaderControls`); `SettingsStore` gains the new keys of 9.3; `SQLiteStore.bookLocator` and `setBookLocator` stay; `MediaAvailability` and `ArtifactMediaPresentation.bookFile` stay; `project.yml` drops the Readium package and its products, adds `libxml2.tbd`; `Package.resolved` loses Readium, SwiftSoup, Zip, Fuzi, ZIPFoundation, CryptoSwift, DifferenceKit, GCDWebServer and SQLite.swift; `ThirdPartyNotices.txt` drops their licences; the README and Roadmap section 4.2 describe the native reader. `BookRoutingTests`, `SQLiteStoreTests` (book position round trip) and `testReadingABornDigitalBook` (book text reaches the accessibility tree, contents lists chapters, reopening shows the same lines) keep passing.

### 22.2 Phase B

Find; read-aloud with Now Playing; highlights, bookmarks and the edit menu; the data-table grid; page list "Go to page" and current page label; landmarks menu; the problems screen; reading-time estimate (words per minute as a named token, SWP-26); accessibility metadata on the detail screen; font family, line height, spacing and margin settings; the page-table cache in `cache_entries`.

### 22.3 Phase C

Media overlay playback; SVG rasteriser; ruby and vertical writing through Core Text fragments; MathML rendering; fixed-layout spreads; sepia and high-contrast themes; character-weighted progress if byte weights prove misleading. Each item ships only when a real book from archive.org needs it.

## 23. Deviations from the studies

Where this document overrides a study requirement, the override and its reason:

| Study requirement | Override |
| --- | --- |
| RDN-06 (force continuous mode under VoiceOver) | Not adopted; both modes work under VoiceOver through the reading content protocol (D3, APL-36). |
| RDS-43, RDN-33 (positions from compressed entry sizes, 1,024 bytes) | Uncompressed sizes, 1,024-byte locations, named "location" never "page" (D6). |
| FOL-33 (1,500-byte locations), EJS-12 to EJS-16 (character locations, cached CFI list) | Byte scale in Phase A; character weights deferred to Phase C (D6). |
| EJS-13 (first location at or after) | Last location at or before (EJS open question 3). |
| RDS-29 (one-level fallback) | Full chain walk (STD-09). |
| RDS-33 (drop subtree under a blank label) | Keep children, label "Untitled section" (STD-15). |
| RDS-32, RDS-35 (exact `epub:type` match, hidden navs ignored) | Token match; hidden navs read (STD-15). |
| RDS-14 (strip first character of `refines`) | A value without `#` is the id (STD-14). |
| RDS-21, RDS-28 (itemref rendition overrides dropped) | Recorded (STD-13). |
| RDN-21 (stop when text or fragment fails) | Fall through to the next resolution (13.1). |
| RDN-24 (scrolled-mode forward jumps a chapter) | One visible height; chapters cross at ends (11.4). |
| RDN-25 (reject navigation while busy) | Queue, last wins (13.1). |
| YUE-07 (HTML parser first) | XML first, HTML recovery second (D7). |
| YUE-21 (justify by default) | Start alignment by default; justify is a setting (9.3). |
| YUE-38 (bottom distribution), YUE-31 (no widow control) | No distribution; widow and orphan control at two lines (11.2). |
| YUE-46 (one element per page) | One element per block (D4). |
| YUE-20 (rasterised tables) | Flatten, then grid (D12). |
| YUE-18 (float notch) | Block placement in Phase A (9.1). |
| FOL section 7 (line-level elements) | Block-level (D4). |
| FOL-48 (decline fixed-layout books) | Open and flow with a banner (D9). |
| APL section 3.7 (UITextView continuous mode) | Custom continuous surface over the shared layout (D3). |
| APL open question 14 (widows off) | On (11.2). |
| STD-09 (unlisted resources) | Adopted as written: shown with a diagnostic (STD open question 3). |
| STD-26 (SVG through the system decoder) | Placeholder in Phase A; the system decoder cannot read SVG data (APL-19). |
| SWP-21 (overlay playback) | Phase C (D9). |
| SWP-33 (continuous layout under VoiceOver as default) | Mode follows the setting; VoiceOver forces nothing (D3). |
| EJS-07 versus CFI 1.1 section 3.5 (refuse on a missing asserted id) | Fall back to the index with a partial flag (12.1). |

Everything else in the studies is adopted as written.

## 24. Open questions

These need a device, a decision from Camden, or a wider sample; none blocks starting Phase A.

1. Which object VoiceOver sends the reading content protocol calls to when the page has block children, and whether the Lines rotor crosses a page when the last block's next element is nil (APL open questions 1 and 2). Decide by the experiment in 14.6 before the element code is final.
2. Whether UITextInput adoption on a custom page view gives braille routing keys and Speak Screen highlighting on a device (APL open question 3).
3. Synthetic TOC thresholds against a larger sample of archive.org Gutenberg items (STD open question 4).
4. Whether Core Text decodes WOFF and WOFF2 from data; if not, those `@font-face` sources fall back to system fonts with a diagnostic and the two W3C font tests are reported as failing (9.4).
5. Whether `limitsLayoutForSuspiciousContents` changes any corpus page breaks (APL open question 6).
6. Whether page breaks differ between iOS 18 and iOS 27 for the same text, which decides whether the OS version stays in the layout key (APL open question 7).
7. Whether TextKit 2 honours `languageIdentifier` for hyphenation on a device whose preferred language differs from the text (APL open question 8).
8. Now Playing for read-aloud: a separate session for speech with paragraph commands (this document's default) or none (APL open question 10).
9. Whether the superscript note heuristic should be on for every book or only for Gutenberg files (FOL open question 12).
10. Whether to show EPUB covers in the artwork pipeline (RDS open question 10).
11. The clamping fraction for author horizontal margins under Dynamic Type sizes, measured on real books (STD open question 10); 60 percent minimum measure is the starting value.
12. How the item screen records that a Gutenberg book lost its footnote apparatus in conversion so the HTML or text edition can be offered instead (STD open question 11).

## 25. Glossary

- Chapter: a spine item's content document as rendered; "section" in foliate-js terms.
- Block: one entry of the block list (10.2); the VoiceOver and read-aloud unit.
- Rendered offset: a UTF-16 offset into a chapter's attributed string.
- Source position: a (text node, UTF-16 offset) pair in the raw tree.
- Locator: the persisted position record of 12.2.
- Location: 1,024 bytes of the book-wide byte scale (12.3).
- Layout key: the settings tuple that identifies a pagination (11.6).
- Release identifier: unique identifier plus `dcterms:modified` (6.2).

# Study: foliate-js for the clean-room EPUB reader

Requirement prefix: FOL. Written 2026-10-14 for the merged Funston EPUB specification.

## Provenance

- Repository: https://github.com/johnfactotum/foliate-js
- Commit read: 78914aef4466eb960965702401634c2cb348e9b1
- Commit date: 2026-05-01T19:24:25Z (subject: "Use original hrefs for external links and add isExternal in fb2.js (#129)")
- License: MIT, copyright 2022 John Factotum. Vendored libraries carry their own licenses (zip.js BSD-3-Clause, fflate MIT, PDF.js Apache). None of the vendored code was read for this study.
- Clone method: `git clone --depth 1` into an empty scratch directory outside the repository. I built nothing and ran nothing from it. One Python script of my own, kept outside the clone, computed the test vectors in section 9.
- What I studied: the EPUB-relevant modules only. The repository is 7104 lines of JavaScript across 22 files. I read these in full: the CFI module (349 lines), the reflowable paginator (1130), the EPUB parser including its media overlay player and resource loader (1083), the higher level view (597), progress (113), text walker (43), search (130), read-aloud (278), overlayer (175), fixed layout (319), footnotes (103), the demo reader (239), the CFI tests (280) and the README. I did not read the MOBI, FB2, CBZ, PDF, dictionary and OPDS modules; they are out of scope for an EPUB reader.
- Everything named in the brief exists and matches its description. Two naming notes: the "text walker" is a 43-line utility rather than a module of its own weight, and the "overlayer" draws SVG over an iframe rather than owning annotation state; both are covered below at the depth their algorithms deserve.
- Funston context read first, unchanged: Funston/UI/EPUBReaderController.swift (Readium 3.11 integration, Dynamic Type mapping, position saving with a one second debounce), Funston/UI/PDFLineAccessibility.swift (the house style: one VoiceOver element per recognized line, frames computed on demand, an adjustable "Reading page" element that turns pages), Docs/Roadmap.md section 4, and the book_positions table in Funston/Services/SQLiteStore.swift (identifier, file_name, locator TEXT as Readium Locator JSON, updated_at; primary key identifier plus file_name).
- Public specifications cited: W3C EPUB 3.3 (https://www.w3.org/TR/epub-33/), EPUB CFI 1.1 (https://idpf.org/epub/linking/cfi/epub-cfi.html), EPUB 2.0.1 OPF (http://idpf.org/epub/20/spec/OPF_2.0.1_draft.htm) and NCX (DAISY Z39.86-2005 section 8.4), SMIL 3.0 clock values (referenced from EPUB 3.3 section 9.2.2.8). Section numbers and anchors were fetched from the live documents on 2026-10-14, not recalled.

Throughout, "verified" means I read the code path. "Claimed" means the README says it and I did not find or did not look for the code. Every number given says where it came from.

## What it is and why it matters to Funston

foliate-js is the rendering library behind the Foliate desktop reader (GTK, Linux). It parses EPUB, MOBI, FB2 and CBZ into one "book" interface, renders reflowable books by loading each spine item into an iframe and paginating it with CSS multi-column layout, and layers CFI generation, progress, search, read-aloud, annotations and media overlays on top. It has no dependencies beyond a zip reader, no build step, and about seven thousand lines in total. The author states plainly that the library is not stable and the API changes at will.

It matters to Funston for the reasons the brief gives: it is a complete, small, readable reference for the algorithms a native reader needs, written by someone who has shipped a reader to real users and fixed the bugs real books produce. The DOM and iframe mechanics are irrelevant to us. What transfers is:

- A CFI implementation that is close to the specification, generates CFIs from the real package document rather than assuming a shape, and comes with tests that cover escaping, merged text chunks, CDATA and comments.
- A pagination model that separates "page geometry" from "position": the reader keeps a position anchor (a text range or a fraction) and re-derives the page after any relayout. That is exactly what a Dynamic Type change or rotation needs, and what VoiceOver needs when focus moves text into view.
- A progress model with three outputs the UI can speak: a book fraction weighted by section size, a "location" grid of fixed byte size, and the current table-of-contents entry for a visible range.
- Read-aloud that walks blocks, segments them into words or sentences, and tracks the spoken mark back to a text range. Funston would drive AVSpeechSynthesizer with the same ranges, or hand the blocks to VoiceOver as elements.
- Search that handles diacritics, case and whole words with the platform's collation and segmentation rather than regexes.
- A real-world parser that falls back from the navigation document to the NCX, from well-formed XHTML to lenient HTML, from cover-image to the EPUB 2 conventions, and honours Apple and Kobo display-option files.

It also matters as a warning. Several behaviours are only reachable because a browser does the layout: visible-range bisection by measuring client rectangles, anchor scrolling by rectangles, overlays positioned by line boxes. A TextKit 2 renderer has exact line fragment geometry and does not need to search for it, but it does need the source-to-rendered offset mapping that the browser gives foliate for free. Section 5 says where each algorithm simplifies and where it gets harder.

## Architecture in our words

The library is a set of ES modules that mostly do not import each other. Their internal names are given here once for orientation; the rest of the document uses specification vocabulary.

- The EPUB parser (`epub.js`) takes a loader with three operations (read an entry as text, read an entry as a blob, get an entry's uncompressed size) and produces the book object: an ordered list of sections (one per spine itemref), the table of contents, the page list, landmarks, metadata, rendition and media overlay properties, the page progression direction, and resolvers from hrefs and CFIs to a section index plus an anchor function. It contains three helper classes: a resource table built from the manifest and spine, a loader that materializes each content document with every reference rewritten to a blob URL and reference-counts shared resources, and a media overlay player that parses SMIL and drives an audio element. Encryption and font deobfuscation live here too.
- The CFI module (`epubcfi.js`) is pure: a tokenizer, a parser into parts, a serializer, collapse of ranges to their start or end, comparison, and two DOM bridges (range to CFI, CFI to range) that take an optional node filter so injected nodes can be ignored.
- The reflowable renderer (`paginator.js`) is a custom element holding one iframe at a time. It computes column geometry from attributes and container size, loads a section, measures the content, sizes the iframe to a whole number of pages with a blank spacer page before and after, and scrolls between pages. It owns the position anchor, the visible-range computation, page turns, section transitions, touch swiping, running heads and feet, the scrolled mode, and the CSS rewriting that makes publisher styles behave in columns.
- The fixed-layout renderer (`fixed-layout.js`) composes spreads from spine items and scales iframes to fit.
- Progress (`progress.js`) has two independent classes: section-size weighting (book fraction, locations, time) and "which table-of-contents entry am I in" (also used for the page list).
- The text walker (`text-walker.js`) collects the text nodes under a range or document into an array of strings, lets a caller run string algorithms on them, and converts the string offsets back into DOM ranges.
- Search (`search.js`) is a generator over that string array with two strategies, substring and segment-window with a collator.
- Read-aloud (`tts.js`) splits a document into blocks, segments each block into marked ranges, and emits SSML with marks; it tracks the last mark reached so speech can resume.
- The overlayer (`overlayer.js`) is an SVG layer over the page with add, remove, redraw and hit test, plus five drawing styles.
- The view (`view.js`) strings these together: it opens the book, chooses a renderer, turns relocation events into progress plus CFI, keeps a history stack, resolves navigation targets of four kinds (section index, fraction, CFI, href), runs search across sections, manages annotations keyed by CFI, and wires media overlays to the renderer.
- Footnotes (`footnotes.js`) detects note references and extracts the referenced block for a popup.
- The demo reader (`reader.js`, `reader.html`) is explicitly not part of the library. It is useful only for its default stylesheet choices.

Section lifetime is simple: exactly one section is rendered at a time; moving to another section destroys the iframe, releases that section's resources, loads the new one, and scrolls to the requested anchor. There is no preloading and no continuous scrolling across sections.

## Requirements

Each requirement gives the statement, why it matters, the public citation where one exists, edge cases, and how to test it. "Verified" and "claimed" are marked where it matters. IDs are stable; do not renumber.

### Container, package and navigation

**FOL-01 Container and rootfile selection.** The reader shall read META-INF/container.xml, collect rootfile elements whose media-type is application/oebps-package+xml, and open the first one as the package document. A missing container or no qualifying rootfile shall fail the open with a diagnostic naming which. Why: EPUB 3.3 section 4.2.6.3.1 (#sec-container-metainf-container.xml) makes the first rootfile the default rendition; foliate takes the first and ignores the rest (verified). Edge cases: rootfile elements with other media types (ignored), a package path containing spaces or percent-encoding (the path is used verbatim as a zip entry name). Test: a container with two rootfiles opens the first; a container with none fails with the "no package document" diagnostic.

**FOL-02 Package document parsing and href resolution.** The reader shall parse the package document as XML, read the manifest items (id, href, media-type, properties as a whitespace-separated list, media-overlay), the spine itemrefs (idref, id, linear, properties), the spine's page-progression-direction and toc attributes, and the EPUB 2 guide. Every manifest href shall be resolved against the package document's own path and percent-decoded once, so that all later lookups by href use the same decoded, container-root-relative form. Why: EPUB 3.3 sections 5.6 (#sec-pkg-manifest), 5.7 (#sec-pkg-spine), 5.2 (#sec-parse-package-urls). foliate resolves and decodes at parse time and then matches hrefs by string equality everywhere (verified), which is what makes TOC hrefs, link hrefs and CipherReference URIs comparable. Edge cases: hrefs with a query string (foliate strips it), hrefs with a fragment (never in the manifest; split in FOL-05), an href that is an absolute URL (left as is and treated as external). Test: a package at OEBPS/content.opf with an item href "text/ch%201.xhtml" resolves to "OEBPS/text/ch 1.xhtml" and is found when a link in another chapter points at "ch%201.xhtml".

**FOL-03 One index space for sections.** The reader shall number sections by spine position and keep that numbering stable even when an itemref's idref does not resolve to a manifest item; such a section shall exist as an unloadable placeholder with a diagnostic, not be dropped. Why: foliate drops unresolved itemrefs from its section list but resolves CFIs and hrefs to indices in the full spine (verified), so a single bad itemref shifts every later section by one and makes saved positions open the wrong chapter. Citation: EPUB 3.3 section 5.7.2 (#sec-itemref-elem) requires idref to resolve, so this is error recovery, not conformance. Edge cases: duplicate idrefs; an itemref pointing at a non-XHTML item (keep its slot; it will fail to render with a diagnostic). Test: a spine with a broken second itemref; a CFI for the third spine item still opens the third item.

**FOL-04 Navigation document first, NCX as fallback, guide as landmarks fallback.** The reader shall take the table of contents, page list and landmarks from the navigation document (the manifest item with the nav property). If there is no navigation document, or it fails to parse, or it has no toc nav, the reader shall take the table of contents and page list from the NCX (the item named by the spine's toc attribute, else the first manifest item of media type application/x-dtbncx+xml). If there are no landmarks, the EPUB 2 guide references shall stand in (label from title, type from the type attribute, href resolved against the package document). Why: EPUB 3.3 sections 7.4.2 (#sec-nav-toc), 7.4.3 (#sec-nav-pagelist), 7.4.4 (#sec-nav-landmarks), 5.9.4 (#sec-opf2-guide), 5.9.5 (#sec-opf2-ncx); OPF 2.0.1 section 2.4.1 (NCX) and 2.6 (guide). Project Gutenberg EPUBs come in EPUB 2 and EPUB 3 flavours; the EPUB 2 ones have only an NCX and a guide. foliate's order is exactly this (verified). Edge cases: a nav document with two toc navs (first wins), a toc nav whose entries use span instead of a (no href; the label is still kept and children still parsed), li entries with an a that has no text but a title attribute (title used as label), hrefs that are percent-encoded (decoded after resolving against the nav document's path), nested ol under an li. For the NCX: navPoint nesting, pageList with pageTarget, navList with navTarget. Test: an EPUB 2 Gutenberg book shows its NCX chapters; an EPUB 3 book with a nav document ignores its NCX even when both exist; a nav document that is not well-formed XML falls back to the NCX with a logged diagnostic.

**FOL-05 Splitting navigation hrefs and finding fragments.** The reader shall split any navigation href at the first "#" into a resolved document path and a fragment identifier. A fragment shall resolve to the element with that id, else to the first element whose name attribute equals it (legacy anchors), else to nothing. An href with no fragment shall mean the start of the document. Why: this is how foliate resolves TOC entries, page list entries, landmarks and in-book links (verified), and how the current TOC entry is computed (FOL-34). EPUB 3.3 section 7.3 (#sec-nav-def-model) requires nav hrefs to resolve to a content document or a fragment within one. Edge cases: a fragment that contains characters needing escaping in a selector (foliate escapes for the name lookup); an href whose path is not in the manifest (resolution fails, see FOL-50); an href whose document is in the manifest but not the spine (foliate returns index -1 and the navigation silently does nothing; we shall report it, FOL-51). Test: hrefs "ch1.xhtml", "ch1.xhtml#p3", "ch1.xhtml#" and "#p3" (relative to the nav document) each resolve as described.

**FOL-06 Cover detection order.** The reader shall find the cover image as, in order: the manifest item with the cover-image property; the item whose id is the content of an EPUB 2 meta element with name "cover"; the item whose href matches a guide reference of type "cover". Why: EPUB 3.3 appendix D.6.1 (#sec-cover-image) is the only normative source; the meta name="cover" form is the de facto EPUB 2 convention that Gutenberg and calibre output use. foliate implements all three in this order (verified). Edge cases: meta content that names an XHTML cover page rather than an image (foliate returns whatever item it is; we shall accept only image media types); a guide cover reference that points at an XHTML page containing the image (foliate matches by href only, so this yields the XHTML item). Test: three fixtures, one per rule, each yields the image item; a book with none yields no cover and no error.

**FOL-07 Metadata, rendition and media overlay properties with prefix expansion.** The reader shall read the identifier named by the package's unique-identifier attribute (first dc:identifier as fallback), the main title (the dc:title refined with title-type "main", else the first), the subtitle, languages, publisher, dates, dcterms:modified, creators and contributors with their role refinements, and collection membership. Each meta element's property and scheme values shall be expanded to full URIs using the reserved prefixes plus any declared in the package's prefix attribute, and rendition and media overlay properties shall be collected by URI prefix into two tables: rendition (layout, orientation, spread, flow, viewport) and media (active-class, playback-active-class, duration as seconds, narrator). The page progression direction shall come from the spine attribute, default "ltr" when absent or "default". Why: EPUB 3.3 sections 5.4 (#attrdef-package-unique-identifier), 5.5.5 (#sec-metadata-last-modified), appendix D.1.4 (#sec-prefix-attr), D.1.5 (#sec-reserved-prefixes), D.3.13 (#sec-title-type), D.3.6 (#sec-file-as), D.5 (rendition vocabulary), D.8 (media overlay vocabulary), 5.7.1 (#attrdef-spine-page-progression-direction). foliate implements this (verified) and additionally maps everything into Readium's web publication manifest shape, which we do not need. Edge cases: the prefix attribute with more than one declaration (foliate's parser is greedy and mis-splits two declarations on one line; parse by whitespace into alternating "name:" and URI tokens instead); unprefixed property names (foliate leaves them as bare names; treat bare names as the default vocabulary for their context); xml:lang on metadata elements and alternate-script refinements (foliate builds language maps; we need only the primary title). Test: a package declaring "foo: http://example.com/# bar: http://example.org/#" yields both prefixes; a package with rendition:layout pre-paginated and media:duration "1:36:20" yields layout "pre-paginated" and duration 5780 seconds.

**FOL-08 Encryption manifest and font deobfuscation.** The reader shall read META-INF/encryption.xml if present, and for each EncryptedData entry record the EncryptionMethod Algorithm URI against the CipherReference URI. Two algorithms shall be implemented. IDPF (http://www.idpf.org/2008/embedding): the key is the SHA-1 digest (20 bytes) of the unique identifier string with every U+0020, U+0009, U+000D and U+000A removed; the first 1040 bytes of the resource are XORed with the key, cycling every 20 bytes; the rest is copied. Adobe (http://ns.adobe.com/pdf/enc#RC): the key is 16 bytes obtained from the first dc:identifier whose last colon-separated token is a UUID, by removing the hyphens and reading 32 hex digits; the first 1024 bytes are XORed with the key cycling every 16 bytes. Any other algorithm shall be recorded as unsupported and the resource passed through untouched, with a diagnostic; text shall still render in a fallback font. Why: EPUB 3.3 section 4.4 (#sec-font-obfuscation, #obfus-keygen, #obfus-algorithm, #obfus-specifying) and 4.2.6.3.2 (#sec-container-metainf-encryption.xml). The Adobe scheme is not in any W3C specification; it is a legacy of Adobe Digital Editions and InDesign exports and foliate supports it (verified) because real books use it. Edge cases: a resource shorter than 1040 bytes (XOR all of it); CipherReference URIs that are percent-encoded while the manifest href was decoded (foliate matches the raw string, so an obfuscated font named with a space would not be deobfuscated; match on the decoded form); fonts referenced from CSS only (they are deobfuscated when loaded through the loader, the same path as any resource). Test: vectors in section 9; the W3C tests ocf-font_obfuscation and ocf-font_obfuscation-bis; the IDPF samples wasteland-otf-obf and wasteland-woff-obf.

**FOL-09 Resolving references inside content documents, with lenient parsing.** When loading a content document the reader shall resolve, relative to that document's path, the references it will fetch: stylesheet links, image and media sources (src, poster, srcset candidates, object data), xlink:href on SVG image and use elements, url() and @import in stylesheets and style attributes, and href in xml-stylesheet processing instructions. Plain hyperlinks (a href) shall not be resolved at load time; they are resolved on activation (FOL-50). A document declared as XHTML that is not well-formed XML shall be re-parsed with a lenient HTML parser and a diagnostic recorded, rather than failing. Cycles (a stylesheet importing itself through another) shall be broken by refusing to re-enter a resource already in the current parent chain. Why: this is foliate's loader (verified). The lenient fallback and the explicit list of attributes are lessons from real books, and the decision not to rewrite hyperlinks avoids breaking links whose text happens to look like a path. For a native renderer the "rewriting" becomes "resolve and fetch from the container"; the list of what to resolve is the transferable part. Edge cases: srcset entries with width or density descriptors; data: and blob: URLs (left alone); absolute http URLs (external, not fetched in a reader that promises offline reading). Test: a chapter whose stylesheet uses @import "../fonts.css" with url(../f/a.otf) resolves both; a chapter with an unclosed p element renders with a diagnostic instead of an error page.

**FOL-10 Media overlay document parsing and clock values.** For a section whose manifest item has a media-overlay attribute, the reader shall parse the referenced SMIL document and produce the ordered list of par elements, each with its text src (resolved against the SMIL document, split into document path and fragment), its audio src (resolved), and clipBegin and clipEnd parsed as SMIL clock values into seconds. A par without text or without audio shall be skipped. Consecutive pars that share an audio file shall be grouped so one audio asset is opened per run. Clock values: "h:mm:ss(.f)", "mm:ss(.f)", or a number with optional unit h, min, s or ms, default seconds. Why: EPUB 3.3 sections 9.2.2.6 (#sec-smil-par-elem), 9.2.2.7 (#sec-smil-text-elem), 9.2.2.8 (#sec-smil-audio-elem, #attrdef-smil-clipBegin, #attrdef-smil-clipEnd), 9.3.2.2 (#sec-media-overlays-fragids), 9.3.5.1 (#sec-package-including); SMIL 3.0 clock value grammar. foliate flattens seq structure entirely and ignores epub:type on seq and par (verified), so it does not implement skippability (section 9.4.1) or escapability (9.4.2); our v1 may do the same, but the parser should keep the seq nesting and epub:type so a later version can. Edge cases: missing clipBegin (start of file), missing clipEnd (end of file), clipEnd beyond the audio length (treat as end of file, per W3C test mol-audio-exceeding-clipend), a text src pointing at a different content document than the section being played (foliate navigates there), a SMIL document that is not well-formed (diagnostic, no overlay for that section). Test: vectors in section 9; IDPF sample moby-dick-mo; W3C tests mol-audio, mol-audio-no-clipbegin, mol-audio-no-clipend, mol-timing-synchronization, mol-timing-synchronization_multiple_audio, mol-css.

**FOL-11 Media overlay playback synchronisation.** During playback the reader shall, for the current audio run, advance the active par whenever the audio time reaches the next par's clipBegin, and when the time passes the active par's clipEnd on the last par of a run, move to the next run (opening its audio and seeking to its first clipBegin). On each change the previously active text element shall lose the active class and the new one gain it; the document element shall carry the playback-active class while playing. Starting playback for a section shall find the first par whose text document is that section; a section without an overlay shall skip to the next section that has one; running past the last par shall continue into the next section. Previous shall step back one par, crossing runs and sections as needed; next shall step forward one par. Pause shall keep the audio position and resume shall continue from it; stepping while paused shall seek to the new par's clipBegin, mark it active, and stay paused. Why: EPUB 3.3 section 9.3.4 (#sec-docs-assoc-style) and appendix D.8 (#sec-active-class, #sec-playback-active-class). This is foliate's player (verified). In Funston, the "class" becomes a highlight range plus a VoiceOver announcement, and the audio is an AVPlayer. Edge cases: pars with undefined begin times never advance by time in foliate (comparisons with undefined are false), so a run with no clipBegin on later pars only advances at end of file; our implementation shall treat a missing clipBegin as 0 and a missing clipEnd as infinity so comparisons stay well defined. Test: with the moby-dick-mo sample, highlighting follows the narration, pause then resume continues mid-phrase, next while paused marks the next phrase without playing, and reaching the end of chapter 1 continues into chapter 2.

**FOL-12 Vendor display-option files.** If META-INF/com.apple.ibooks.display-options.xml or, failing that, META-INF/com.kobobooks.display-options.xml exists, an option named fixed-layout with value "true" shall set rendition layout to pre-paginated when the package did not say, and an option named open-to-spread with value "false" shall place the first linear section on the right (left for right-to-left books) when the package did not say. Why: no public specification; it is a real-world lesson foliate keeps (verified) because older Apple and Kobo fixed-layout books declare layout only there. Edge cases: both files present (Apple wins). Test: a reflowable package with an Apple file declaring fixed-layout true opens as fixed layout.

### EPUB CFI

**FOL-13 CFI parsing.** The reader shall parse a CFI string, with or without the "epubcfi(" wrapper, into a structure of paths. A path is a sequence of steps; steps are separated by "!" into indirection levels; a range CFI has a parent path and start and end local paths separated by ",". Each step carries a child index (integer after "/"), and may carry an id assertion (bracket immediately after an element step), a character offset (":" integer), a temporal offset ("~" decimal), a spatial offset ("@" x ":" y), a text location assertion (bracket after an offset, with one or two comma-separated strings), and a side bias parameter (";s=a" or ";s=b" inside the final bracket). "^" escapes the next character everywhere; within brackets an unescaped "," separates the two text strings and an unescaped ";" starts a parameter. A string that cannot be tokenised as such shall be rejected with a diagnostic that names the offset of the first bad character. Why: EPUB CFI 1.1 section 2.2 (syntax), 2.3 (character escaping), 3.1.1 to 3.1.9. foliate's tokenizer is a hand-written state machine that handles escaping in assertions correctly (verified; its tests cover ids containing "]", "!", "/", "^" and ","), but it does not reject malformed input: a non-digit after "/" yields a NaN index that fails later. We shall reject at parse time. Edge cases: a bracket after an element step is an id assertion, a bracket after a character offset is a text assertion (foliate decides by the preceding token, verified); an empty id bracket "[]" is not an id; a side bias with no other assertion "[;s=b]"; "^^" for a literal circumflex; leading and trailing whitespace trimmed. Test: vectors in section 9.

**FOL-14 CFI serialisation and round trip.** The reader shall serialise the parsed structure back to a canonical string: "epubcfi(" + paths joined by "!" + ")", ranges as parent "," start "," end; each step as "/" index, then "[" escaped id and optional ";s=" bias "]" when the step has an id, then ":" offset only when the step is a character data step (odd index), then "~" temporal, then "@" x ":" y, then a trailing bracket with the escaped text assertion strings and the bias when there is a text assertion or a bias without an id. The escape set is "^", "[", "]", "(", ")", ",", ";" and "=". Parsing then serialising a canonical string shall give the same string. Why: CFI 1.1 section 2.3 lists the characters that must be escaped; the grammar in 2.2 also treats "=" as a delimiter inside parameters. foliate's serializer (verified) drops offsets on element steps and drops a temporal offset of zero; we shall keep an offset of zero on character steps (foliate does, through a null check) and keep temporal zero (foliate does not; a truthiness check). Edge cases: id containing "^]" round-trips as "^^^]"; spatial offsets serialise with a colon between x and y. Test: vectors in section 9.

**FOL-15 Child indexing over an XHTML tree.** For CFI purposes the children of an element shall be indexed as follows: consider only element children and character data children (text and CDATA); ignore comments and processing instructions; merge every run of consecutive character data nodes into one chunk; number chunks and elements alternately so that chunks take odd indices and elements even indices starting at 2; where two elements are adjacent there is an empty chunk between them at the odd index; there is always a chunk before the first element (index 1) and after the last element, even when empty; index 0 and index n+2 are virtual positions before the first chunk and after the last. Offsets within a chunk count UTF-16 code units across the merged nodes. Why: CFI 1.1 section 3.1.1 and 3.1.4 (offsets are UTF-16 code units; offset 0 and the total length are valid). foliate implements the merging and the virtual positions (verified) and its tests exercise CDATA, comments between text, and numeric character references. For a native implementation this means the parsed document must keep the original node sequence: do not collapse whitespace, do not merge text nodes, do not drop CDATA at parse time; keep comments only if marked so they can be skipped. NSString and NSAttributedString already count UTF-16, so offsets map without conversion; Swift's String.count must not be used. Edge cases: an element whose only content is a comment (one empty chunk at index 1); text split by an entity reference parsed into two text nodes (merged into one chunk); a leading chunk that is only whitespace (still a chunk, not empty). Test: vectors in section 9.

**FOL-16 Generating a CFI from a position.** Given a position (a character data node and a UTF-16 offset, or an element), the reader shall produce the local path by walking up to the document element: at each level the step index is the position of the node, or of the chunk containing it, in the parent's indexing (FOL-15); the offset at the leaf is the offset within the merged chunk (add the lengths of earlier nodes in the same chunk); every element step whose element has an id shall carry that id as an assertion. A range position shall produce a range CFI (FOL-20). Nodes that the renderer injected (for example highlight wrappers, if any) shall be excluded from counting by a node filter: a rejected node and its subtree are invisible; a skipped node is transparent and its children count as the parent's. Why: CFI 1.1 sections 3.1.1, 3.1.2, 3.5 (assertions let a reading system correct a stale path). foliate does this (verified) including a regression test for offsets inside skipped wrappers. Edge cases: a position inside an element at child offset k is serialised by foliate as the element alone because offsets are dropped on even steps (verified); we shall instead convert such a position to the equivalent chunk or element step before serialising, so no information is lost. The document element itself is never a step (the path starts at its children; body is "/4" in a typical html with head and body). Test: vectors in section 9.

**FOL-17 Resolving a CFI to a position, with correction and failure reporting.** Given a local path and a document, the reader shall walk the steps from the document element using FOL-15 indexing. At an element step with an id assertion, if the element at that index does not have that id, the element with that id shall be used instead if it exists (and the walk continues from it); if neither the index nor the id resolves, resolution fails. A chunk step with an offset shall resolve to the character data node containing that offset within the merged chunk; an offset equal to the chunk length resolves to the end of the last node; an offset beyond it fails. A text location assertion, when present, shall be checked against the text around the resolved point (whitespace collapsed, element boundaries ignored) and a mismatch recorded as a diagnostic (a later version may search nearby for the asserted text). Virtual index 0 resolves to "before the first child", n+2 to "after the last child"; an empty leading or trailing chunk resolves to the start or end of the parent's content. Failure shall be a value, not an exception, carrying which step failed and why. Why: CFI 1.1 sections 3.1.1, 3.1.2, 3.1.4, 3.1.8, 3.5. foliate (verified) honours an id assertion only on the final step and then trusts it outright, ignores assertions on earlier steps, ignores text assertions, and throws a DOM exception for out-of-range indices which the view catches and logs; a stale saved position then opens the book at the start without telling the user. Edge cases: a CFI whose step indices are even where a chunk was expected (an element where text was expected; resolve to the element start); offsets on element steps (ignore); a chunk step on an element with no character data (resolve to the parent's content start or end per the virtual rules). Test: vectors in section 9; a position saved before a re-download of a book whose chapter was retypeset must still resolve by id when the paragraph has an id, and must report "offset beyond chunk" otherwise.

**FOL-18 Comparing and ordering CFIs.** The reader shall order two CFIs by comparing their paths level by level (indirection levels in order) and step by step: a smaller child index sorts first; when all compared indices are equal, a path that ends sooner sorts first; at the last step of a level, a smaller character offset sorts first, and a missing offset counts as zero; assertions and side bias do not participate. A range CFI is ordered by its start, then by its end. Temporal and spatial offsets are compared after character offsets, time before space and y before x, when both sides carry them. Why: CFI 1.1 section 3.2. foliate implements the index and offset rules and explicitly leaves temporal and spatial as a TODO (verified); it compares a missing offset as equal to any offset, which is a deviation we shall not keep. Edge cases: comparing a CFI with a package path against one without (treat the shorter as a prefix: it sorts first); comparing across different spine items (the package-level step decides). Test: vectors in section 9.

**FOL-19 The package-level prefix and spine step resolution.** For each spine item the reader shall generate its base CFI from the actual package document: the path from the package element to the itemref using FOL-15 indexing, with id assertions for the spine element and the itemref when they have ids (typically "/6/4[chap01]" for the second itemref of a spine that is the third element child of package). A full CFI is base + "!" + local path. To resolve a CFI, the first path shall be resolved in the package document; if the id assertion resolves to an element that is not an itemref, the id shall be dropped and the index used (other reading systems have emitted wrong ids); the itemref's idref gives the manifest item and the spine position gives the section index. If the resolved element is not an itemref at all, resolution fails with a diagnostic. Why: CFI 1.1 sections 3.1.3 (indirection through spine itemref via the manifest href) and 3.3 (intra-publication CFIs). foliate generates from the DOM rather than assuming "/6" (verified), which is right: a package with a guide element before the spine, or a collection element, changes the index. The non-itemref fallback is a real-world lesson from Epub.js output. Edge cases: CFIs produced by other software that assume "/6" when the real index differs (resolve by id assertion first, then by index, and record which was used); a CFI whose spine step resolves to an itemref that was dropped or is linear="no" (still valid). Test: vectors in section 9.

**FOL-20 Building a range CFI.** Given start and end positions in the same document, the reader shall take their local paths, find the longest common prefix of steps where indices are equal and neither step carries an offset, make that the parent path (together with the package path), and put the remaining steps into the start and end local paths. Ranges across documents are not representable and shall be rejected. When collapsing a range to a point, the start (or end) local path is appended to the parent path, merging into the parent's last path. Why: CFI 1.1 section 3.4 (the parent path is the common part; start and end are relative to it; start must not be after end). foliate does this (verified). Edge cases: start and end in the same chunk (parent ends at the chunk's parent; start and end are "/N:a" and "/N:b"); start and end both at offset 0 of the same chunk (foliate's falsy-zero test merges the offset-bearing step into the parent and emits empty start and end, verified; we shall treat "has an offset" as "offset is present", not "offset is non-zero"); a collapsed range serialises as a point, not a range. Test: vectors in section 9.

### Paginator

**FOL-21 Page geometry.** In paginated mode the reader shall divide the content area into columns as follows. Let W be the reader view's inline size (width in horizontal writing, height in vertical) and g the gap fraction (default 7 percent, from the paginator's CSS default, verified). An outer gutter of g × W ÷ 2 is reserved at each inline edge, so the page area is S = W × (1 − g), further capped at the maximum inline size times the orientation's maximum column count and centred when capped. The defaults are a maximum inline size of 720 points and a maximum of 2 columns in landscape and 1 in portrait (CSS defaults, verified). The column gap is G = S × g ÷ (1 − g), which equals g × W when S is not capped; the author derives this so that the gap between two columns equals the margin from the view's edge to the text (gutter plus the half-gap padding inside the page area). The number of columns per page is N = min(column cap, ceil(S ÷ maximum inline size)); each column's content width is S ÷ N − G; the page area carries G ÷ 2 of padding at each end so N columns and their gaps fill S exactly. The block size of a page is the view's block size minus the running head and foot regions, each at least the margin height (default 48 points, verified) and the page block size capped at the maximum block size (default 1440 points, verified) with any surplus going to the head and foot rows. Images and other replaced content shall not exceed the page (FOL-28). All of these shall be named tokens in one place. Why: the gap derivation and the column-count rule are the author's lessons about readable measure; 720 points is a comfortable line length on a tablet. There is no specification; rendition:flow (EPUB 3.3 appendix D.5) only says paginated or scrolled. Edge cases: S smaller than G (clamp to one column with a minimum content width); vertical writing swaps the roles of inline and block, and swaps the portrait and landscape column counts. Test: worked numbers in section 9.

**FOL-22 Page index and fraction within a section.** The reader shall number the pages of a laid-out section from 0 and report the position within the section as fraction = page ÷ pageCount (so the first page is 0 and the last page is (pageCount − 1) ÷ pageCount) together with the page size as a fraction, 1 ÷ pageCount. Going to a fraction f shall open page round(f × (pageCount − 1)). In scrolled mode the fraction is the scroll offset divided by the content height, and going to a fraction scrolls to f × content height. Why: this is foliate's model (verified). Combined with FOL-32 the book fraction then lands exactly on 1.0 on the last page of the last section. Edge cases: pageCount 1 (fraction 0, size 1); a fraction of 1 opens the last page; relayout changes pageCount, which is why the position must be anchored to text (FOL-23) and not to a page number. Test: a section with 3 pages reports fractions 0, 1/3 and 2/3 with size 1/3; goTo 0.5 opens page 1.

**FOL-23 The position anchor survives relayout.** The reader shall keep one anchor per open section: either the visible text range after a user scroll or page turn, or an explicit target (an element, a range, or a fraction) after navigation. After any relayout (size change, font size change, style change, font loading, image size change) the reader shall re-lay-out and then scroll so that the anchor is in view: for a range or element, the page containing the first non-empty line rectangle of its start; for a fraction, the page nearest that fraction. A scroll caused by anchoring shall not replace the anchor. Why: this is the paginator's central invariant (verified; the README calls it the view being "anchored"). It is exactly what Dynamic Type changes, rotation and split view need, and it is what keeps VoiceOver focus on the same paragraph when text reflows. Edge cases: a collapsed range (expand to one character, or to the enclosing element, before measuring); a range starting right after a hyphenation point whose first rectangle is zero width (skip zero-size rectangles, verified); a section whose anchor element was removed (fall back to the fraction). Test: open a section at a known paragraph, change the text size twice, rotate; the paragraph remains the first visible text each time.

**FOL-24 Determining the visible range.** After each relocation the reader shall compute the range of content on the current page: the first and last content positions whose rendered rectangles fall within the page's inline extent. In foliate this is a tree walk that rejects elements wholly outside the page, accepts elements wholly inside, descends into partially visible elements, accepts any non-blank text node that overlaps, and then bisects the first and last text nodes by character offset against the page boundary (verified). In a TextKit 2 renderer the layout manager's line fragments give the same answer directly: the visible range is from the start of the first line fragment on the page to the end of the last one, mapped back to source positions. The visible range is what gets saved, what the CFI is made from, what the current TOC entry is computed from, and what read-aloud starts from. Why: foliate's README notes bisection is more accurate than Epub.js's approach; for us the point is that the range is per page and derived from layout, never estimated. Edge cases: a page whose only content is an image (range is the image element); a page beginning mid-word after a hyphen; an element that is taller than the page (in scrolled mode foliate's walk can exclude it, noted by the author as a TODO). Test: a 20-character text node split across two columns at character 10 reports the second page's range starting at offset 10.

**FOL-25 Navigation to an element, a CFI, or a fraction.** The reader shall accept a target of four kinds: a section index (open at its start), an href (resolve per FOL-05 to a section and a fragment element, or the section start), a CFI (resolve per FOL-19 then FOL-17 to a section and a range), or a book fraction (resolve per FOL-32 to a section and a fraction within it). Opening the section and then anchoring to the result shall be one operation; the anchor becomes the resolved element, range or fraction. Page turns forward and backward shall move by one page within the section and, at the section's edge, open the adjacent linear section at its first page (forward) or last page (backward), skipping sections whose linear attribute is "no". Navigation by index or href may open a non-linear section. Why: EPUB 3.3 section 5.7.2 (#attrdef-itemref-linear): reading systems may skip non-linear content in the reading order but must make it reachable. foliate does exactly this (verified). Edge cases: a page turn while one is in progress (foliate locks and ignores); a target in the current section (no reload, just scroll); a target whose section fails to load (FOL-51). Test: a book whose notes file is linear="no": paging through never shows it, a link into it does, and paging forward from it continues with the next linear section.

**FOL-26 Section transitions and resource lifetime.** When leaving a section the reader shall release that section's resources (foliate revokes the blob URLs by reference count, verified); when entering, it shall load, lay out, and then anchor. foliate loads exactly one section at a time and does not preload (verified); the page turn awaits the load. For Funston, where VoiceOver reads continuously and a pause at a chapter boundary is audible, the merged specification should require laying out the next linear section ahead of time once the reader is within a page of the boundary, bounded by a memory ceiling. Why: the M2 with 16 GB rule in the project's standing guidance; Gutenberg chapters are small, so one section of lookahead is cheap. Edge cases: rapid turns across several small sections (coalesce); a section that fails to load (show a diagnostic page in its slot so paging continues). Test: with VoiceOver reading continuously, a chapter boundary produces no silence longer than a normal paragraph gap, measured on device.

**FOL-27 Right-to-left and vertical writing.** The reader shall detect the page progression direction from the spine and the writing mode from the content (the body's computed writing-mode and direction, the body or root dir attribute, in foliate; verified). All page arithmetic shall be done in progression-agnostic coordinates: map rectangles so that "start" is always the low coordinate, compute page indices there, and map back only when scrolling. Running heads and feet follow the book's progression direction. Why: foliate does this through one rectangle mapper per mode (verified) and notes that its scrolled vertical mode supports vertical-rl only, not vertical-lr (FIXME in the source). For version one of Funston, the Gutenberg corpus is horizontal left-to-right; the merged specification should require the agnostic arithmetic now so RTL can be added without rewriting, and may defer vertical writing. Test: IDPF samples regime-anticancer-arabic (rtl progression) and kusamakura-japanese-vertical-writing (vertical-rl); W3C tests pkg-spine-progression_ltr, pkg-spine-progression_rtl, pkg-spine-progression-default.

**FOL-28 Replaced content fits the page.** Every image, SVG and video shall be constrained to the page: maximum height equal to the page's block size minus two margins, maximum width 100 percent of the column (or the author's smaller maximum if set), contained within its box, and never split across pages. Why: foliate sets these as important styles on load (verified) because publisher CSS routinely sizes images in viewport units or absolute pixels, which overflow a column. Edge cases: an image wider than the column with no author constraint (scale down, keep aspect); an inline image taller than the page (scale down); vertical writing (swap the constraints). Test: pg20512-images.epub (the Gutenberg "images" variant) shows every illustration within a page at every Dynamic Type size.

**FOL-29 Running heads and feet.** In paginated mode the reader shall reserve a head region above and a foot region below the page, each the margin height, with one slot per column, laid out in the book's progression direction, and shall hide the running head on the first page of a section. The regions are empty by default; the host fills them (the demo reader does not; the README says they are meant for running heads and reading progress). Why: verified in the paginator; hiding the head on a chapter's first page is the typographic convention. Edge cases: vertical writing uses at most two slots across the width. Test: with two columns, two head slots exist; on page 0 of a section they are hidden.

**FOL-30 Scrolled mode.** The reader shall offer a scrolled mode in which a section is one continuous column of the maximum inline size, centred, with the margin as top and bottom padding; the fraction is offset ÷ content height; next and previous scroll by one viewport (or a given distance) and, within 2 points of the end (verified threshold), open the adjacent section. The anchor rules of FOL-23 still apply. Why: Funston's existing reader switches Readium to scrolling under VoiceOver because pagination breaks the screen reader; the merged specification will decide whether VoiceOver uses scrolled mode or page-per-screen with a tethered element list (see section 7). Edge cases: switching modes without reloading (foliate supports it, verified: the same anchor is reapplied). Test: toggle modes at a known paragraph; it stays in view.

**FOL-31 Caret and selection placement after navigation.** After a navigation the reader shall place the insertion point (or the equivalent focus for assistive technology) at the start of the newly visible range, or at its end when the navigation targeted the end of a section; after a scroll to a selection it shall select the anchor. A selection extended past the page edge with a pointer shall turn the page in that direction; a keyboard-extended selection shall scroll to keep its focus in view; a focused element shall be scrolled into view. Why: verified in the paginator's relocate handling. It is the one explicit accessibility behaviour in the library and it maps directly to VoiceOver: after a page turn, focus goes to the first element of the page. Test: after paging forward under VoiceOver, the first spoken element is the first line of the new page.

### Progress

**FOL-32 Section weights and the book fraction.** Each section's weight shall be its uncompressed byte size, with non-linear sections and sections of unknown size weighing zero. The cumulative fractions c[0] = 0, c[i+1] = c[i] + w[i] ÷ total give each section's start. The book fraction for (section i, fraction f within it, page size p within it) is (c[i] × total + (f + p) × w[i]) ÷ total, which is the end of the current page. The inverse maps a book fraction to a section (the last whose start is at or below the fraction, skipping zero-weight sections forward, with a small epsilon so section starts land on the right side) and a fraction within it. Why: verified in foliate's section progress; the (f + p) choice makes the last page of the last section report exactly 1.0 and the first page of the book report one page's worth rather than 0, which reads sensibly as "percent read". Edge cases: a book whose only section has weight zero (division by zero; report no fraction); fractions below 0 or above 1 (clamp); the epsilon on the inverse so that goTo(c[i]) opens section i, not i − 1. Test: vectors in section 9.

**FOL-33 Locations and time remaining.** The reader shall define a location as 1500 bytes of section weight (the view's constant, verified) and report the current location floor(bytes before the page ÷ 1500), the next location floor(bytes through the page ÷ 1500), and the total ceil(total ÷ 1500). It shall estimate time remaining in the section and in the book as remaining bytes ÷ 1600 bytes per minute (the view's second constant, verified; the unit is the author's reading-speed proxy). Why: locations give a stable "where am I" that does not change with text size, which matters when the page count changes with every Dynamic Type step; a spoken "location 212 of 940" is more useful to a VoiceOver user than a page number that shifts. Edge cases: markup-heavy books overstate bytes relative to text (an open question in section 11). Test: vectors in section 9.

**FOL-34 The current table-of-contents entry for a position.** The reader shall assign each flattened TOC entry a sequence number in document order, group entries by the section they point into, and for each section remember the entry that precedes the group (the last entry of an earlier section). Sections with no entries inherit the previous section's group. For a visible range in section i, the current entry is the last entry of the group whose target element is not after the end of the range; if every target is after the range, it is the entry preceding the group; if the group has one entry with no fragment, it is that entry. Why: verified in foliate's TOC progress. It gives the chapter title for running heads, the label for search result groups, and the announcement "Chapter 3" for VoiceOver on relocation. Citation: EPUB 3.3 section 7.4.2 says entries should follow spine order and then document order, which this relies on. Edge cases: a target id missing from the document (skip that entry); entries pointing into a document that is not in the spine (grouped under an id no section has; never current); a section before the first TOC entry (the preceding entry is nil; no chapter). Test: vectors in section 9.

**FOL-35 Page list progress and books without one.** The reader shall apply FOL-34 to the page list to find the current page label (the last page break at or before the end of the visible range). When the book has no page list, the reader shall show locations (FOL-33) instead of page labels, and shall not invent page numbers. Why: EPUB 3.3 section 7.4.3; page labels refer to a print edition and are meaningful to VoiceOver users sharing a reference with print readers; foliate's demo shows "Page N" when a page list exists and "Loc N" otherwise (verified). Gutenberg books have no page list; Standard Ebooks have none; the IDPF sample accessible_epub_3 has one (verify on download). Test: the two display paths on those fixtures.

### Text walking and read-aloud

**FOL-36 Walking text into strings with a way back.** The reader shall be able to collect, for a document or a range, the ordered list of character data nodes (skipping script and style subtrees and, optionally, other filtered nodes), expose their strings to a string algorithm, and convert any (string index, offset) pair the algorithm returns back into a source position. The joined string's offset o maps to the node whose cumulative start is the largest not exceeding o; an end offset that equals a node boundary maps to the end of the earlier node, not the start of the next. Why: verified in the text walker and in the segmenter helper, including the boundary adjustment. In a native renderer the "nodes" are the source text runs, and the attributed string the layout manager renders is built from them; the same table maps rendered offsets to source positions and must account for whitespace collapsing. Test: a two-node text "Hello, " + "world": the match "lo, w" maps to (node 0, 3) through (node 1, 1); the word "Hello" ends at (node 0, 5), not (node 1, 0).

**FOL-37 Blocks for read-aloud.** A section's speakable units shall be its blocks: walk the elements under body in document order; each element whose name is in the block set (article, aside, audio, blockquote, caption, details, dialog, div, dl, dt, dd, figure, footer, form, figcaption, h1 to h6, header, hgroup, hr, li, main, math, nav, ol, p, pre, section, tr) ends the previous block before itself and starts a new one; the last block ends after body's last child; blocks whose text is empty after trimming are dropped; a document with no block elements is one block. Why: verified in the read-aloud module. Note what is not in the set: table, ul, td and th (a row is one unit), img. The effect is that nested containers produce empty blocks that are dropped, and a list item is one unit. For VoiceOver this is the paragraph-level unit; see section 7 for why Funston may still want line-level elements. Edge cases: a p containing a nested div (the div starts a new block mid-paragraph, which is what the author intends); text directly in body before the first block (first block starts at body's first child). Test: a chapter with a heading, three paragraphs and a list of two items yields six blocks.

**FOL-38 Per-block language and SSML.** For each block the reader shall determine the language from the nearest ancestor of the block's common ancestor that has lang or xml:lang, and the phonetic alphabet from the nearest ancestor with ssml:alphabet. It shall segment the block's text (FOL-36) into words or sentences with the platform segmenter for that language, keeping only word-like segments at word granularity, and number the segments from 0. It shall build an SSML document whose root carries the language, with a mark before each segment, break for br, emphasis for em and strong, a lang wrapper for any element with its own language, and a phoneme element for any element with ssml:ph (alphabet from the element or inherited); all other elements are flattened to their text. Why: the ssml:ph and ssml:alphabet attributes are EPUB 3.3's pronunciation mechanism (section 6, XHTML content documents, under text-to-speech; the IDPF sample georgia-pls-ssml exercises them). foliate builds this (verified) with one defect: its alphabet lookup reads xml:lang instead of ssml:alphabet, so an inherited alphabet comes out as the language code (verified by reading the two near-identical helper functions). We shall read ssml:alphabet. Funston's synthesiser (AVSpeechSynthesizer) does not take SSML directly in all versions; the useful output is the list of (segment range, text, language) with the same mark names, which the host can feed as utterances with per-utterance language and use for highlighting. Edge cases: a block with mixed languages (one lang wrapper per element with its own language, not per segment); CDATA sections (copied as text); a block with no word-like segments (speak nothing, skip). Test: a paragraph with an inline French span yields a lang wrapper around it and marks numbered through it.

**FOL-39 Mark tracking, resume, start from a position, and crossing sections.** The reader shall remember the last mark reached while speaking a block, highlight (or move VoiceOver focus to) that mark's source range when the synthesiser reports it, resume from that mark after a pause by speaking only the part of the block from the mark on, start from an arbitrary position by finding the first block whose end is not before the position and the first mark in it whose range starts at or after the position, and step to the previous or next block (highlighting the block when paused so the user sees where they are). Reaching the end of the last block shall report "no more blocks"; moving to the next section and starting again is the host's job (foliate leaves it to the application, verified). Why: this is the read-aloud state machine (verified). Edge cases: a mark whose range was invalidated by relayout (ranges are source positions in our model, so they survive); starting from a position inside the last word of a block (that word's mark). Test: pause mid-paragraph, resume, and the speech continues from the current word; press next while paused and the next paragraph is highlighted without speech.

### Search

**FOL-40 Search options and strategy.** Search shall take a query and three booleans: match case, match diacritics, whole words. The locale shall be the document's body or root language, else the book language, else "en". Whole-word search shall always use the segment-window strategy (FOL-41) at word granularity. Otherwise, when both case and diacritics must match, or when diacritics must match and case need not, the substring strategy shall be used (lowercasing both sides with the locale when case is ignored); when diacritics are ignored, the segment-window strategy at grapheme granularity with a collator of the right sensitivity (base: ignore both; case: ignore diacritics only). Why: verified in the search module; the mapping from the three booleans to collator sensitivity is the author's. On Apple platforms the equivalents are String.range(of:options:locale:) with caseInsensitive and diacriticInsensitive, and the natural language tokenizer or enumerateSubstrings(byWords) for segments. Edge cases: a query of only whitespace (no results); a query longer than a block (matches can span nodes, there is no limit, verified). Test: in a Gutenberg French text, "élève" with diacritics ignored finds "eleve"; whole-word "art" does not match "part".

**FOL-41 Segment-window matching.** The segment-window strategy shall segment the joined text with the locale segmenter, ignore segments consisting only of Unicode format characters, collapse any whitespace segment to a single space and drop consecutive ones, keep a sliding window of as many segments as the query has, compare the window's concatenated text with the query using the collator (equal under the chosen sensitivity means a match), emit the match range from the first segment's start to the last segment's end, then drop the first segment and continue across node boundaries. Why: verified. The window technique is what makes whole-word and diacritic-insensitive matching possible without a regex per locale. The README says it is "extremely slow"; the per-window collator comparison is linear in text length times query length and is run per section. Edge cases: a query that begins or ends with whitespace (the window will include a space segment); hyphenated words (segmenters split them; a whole-word query "well-known" is three segments); the segmenter's "usage" option that foliate passes does not exist in the standard and is ignored. Test: the whole-word vector in section 9.

**FOL-42 Result excerpts and identities.** Each result shall carry the match range, the CFI for the range (base CFI of the section + local range CFI), and an excerpt of the matched text with up to 50 characters of surrounding text before and after it, taken across node boundaries (whitespace collapsed, trimmed, with an ellipsis when truncated; the constant is verified, the crossing of nodes is ours: the candidate takes context only from the start node and the end node, so a match beginning at a node boundary shows no preceding context). Results shall be produced per section, with a progress value after each section (sections searched ÷ sections), and grouped under the section's current TOC label. Search results shall be drawn as outlines keyed by a reserved prefix plus the CFI so they do not collide with user annotations, and cleared as a set. Why: verified in the view's search. One defect to avoid: foliate's excerpt builder, for a match spanning three or more nodes, drops the middle nodes' text from the matched string because it slices the node array with string values instead of indices (verified; the range itself is correct). We shall build the excerpt from the range's text. Edge cases: a match at the very start or end of a section (shorter context, no ellipsis); a result in a non-linear section (still reported, with its label). Test: a match spanning an inline emphasis element has the full matched text in its excerpt.

### Overlays and annotations

**FOL-43 Drawing marks from line rectangles.** Given the list of line rectangles of a range (one per line box fragment), the reader shall draw: highlight as filled rectangles at 30 percent opacity with a configurable blend mode; underline as a bar of stroke width 2 along each rectangle's bottom edge (right edge in vertical writing); strikethrough as a bar through each rectangle's vertical middle (horizontal middle in vertical writing); squiggly as a zigzag along the bottom edge with amplitude 1.5 × stroke width and segment length about 2.25 × stroke width (n = round(width ÷ (1.5 × stroke) ÷ 1.5) segments across the width; the constants are verified); outline as a stroked rectangle of width 3 with corner radius 3 (used for search results). Default colour is a token, not "red". Why: verified in the overlayer. In a native renderer the rectangles come from the layout manager's enumeration of text segments for the range, and the drawing is CoreGraphics in a layer above the text. Edge cases: a range spanning columns (one rectangle per fragment, so no spanning rectangle); zero-height rectangles (skip); vertical writing swaps edges. Test: a highlighted range across three lines draws three rectangles aligned to the line boxes at every text size.

**FOL-44 Hit testing.** A tap at a point shall hit the most recently added mark whose rectangles contain the point (top ≤ y < bottom, left ≤ x < right), returning its key and range; the rectangles tested are the range's line rectangles, not the drawn shape. Why: verified. Newest-first resolves overlapping highlights predictably. Edge cases: a squiggly's zigzag extends below the rectangle (not hittable there; acceptable); VoiceOver users do not tap, so every mark shall also be reachable as a custom action or rotor item on the text element that contains it (section 7). Test: two overlapping highlights; a tap in the overlap reports the newer one.

**FOL-45 Annotation identity and re-attachment.** An annotation's identity shall be its range CFI string (with the package path), so that it is stable across sessions, text sizes and devices; the host stores annotations by section index and, whenever a section is laid out, re-adds those for that section; the reader redraws all marks after each relayout. Showing an annotation shall navigate to its CFI and then report its range. Why: verified in the view; it is also how calibre's bookmarks are imported (by converting its CFI form). Edge cases: two annotations with the same CFI (the newer replaces the older); a CFI that no longer resolves (keep the record, do not draw, report in a diagnostics list the user can see). Test: create a highlight, quit, relaunch, change text size; it is drawn on the same words.

### Fixed layout

**FOL-46 Spread composition.** For a pre-paginated book the reader shall compose spreads from the spine in order. If rendition:spread is "none", each item is alone and centred. Otherwise, an item with page-spread-center is alone and centred; an item with page-spread-left or page-spread-right goes in that slot, starting a new spread when the slot or the centre is taken, and in a left-to-right book a left page always starts a new spread (the very first item aside) because the left slot is the first of a spread, mirrored for right-to-left books; an item with no placement fills the next free slot, except that the very first item goes on the right (left for right-to-left books) so the cover stands alone. In portrait, when rendition:spread is not "both" (or the deprecated "portrait"), only one page of the spread is shown and next and previous flip between the two pages before moving to the next spread. Why: EPUB 3.3 sections 8.2.2.3 (#spread), 8.2.2.4 (#page-spread), appendix D.7. foliate implements these rules in about forty lines (verified). Edge cases: rendition:spread "landscape" (foliate treats it like "auto"); per-item spread overrides (not implemented in foliate). Test: W3C tests lay-fxl-page-spread-left, lay-fxl-page-spread-right, lay-fxl-page-spread-combined, fxl-page-spread-center, lay-fxl-spread-none, lay-fxl-spread-both.

**FOL-47 Page viewport.** The size of a fixed-layout page shall come from, in order: the SVG root's viewBox for SVG documents; the first viewport meta element's width and height (foliate splits on commas, semicolons and whitespace, which is lenient beyond the specification's comma; verified); the package's rendition:viewport (deprecated) when it has both numbers; the natural size of the document's first image; else a fallback of 1000 × 2000 with a diagnostic (verified constant). The page is then scaled to fit the page or spread (minimum of the width and height ratios), to fit width, or to an explicit zoom. Why: EPUB 3.3 section 8.2.2.6 (#sec-fxl-content-dimensions) and appendix F (#app-viewport-meta). Test: W3C tests lay-fxl-xhtml-icb_device_sizes, lay-fxl-xhtml-icb_multi_declarations, lay-fxl-xhtml-icb_repeated-in-meta, lay-fxl-xhtml-icb_units, lay-fxl-xhtml-icb_invalid_meta.

**FOL-48 Version one decision for fixed layout.** The parser shall detect pre-paginated books (FOL-07 and FOL-12) and version one shall decline to open them with a clear message rather than render them. Why: a fixed-layout page is an arbitrary HTML and CSS composition at a fixed pixel size; TextKit 2 cannot lay out CSS, and the project rules out WKWebView. foliate's fixed-layout renderer also has no text selection, no overlays and no per-page relocation detail (its own TODOs, verified), which tells us that even with a browser the fixed-layout path is second class. The corpus (Gutenberg) has no fixed-layout books. The composition and viewport rules above are recorded so a later version can add rendering (for instance by rasterising with a private web view process) without re-studying. Test: the IDPF samples page-blanche and cole-voyage-of-life produce the "fixed layout not supported" message, not a blank screen.

### Links and footnotes

**FOL-49 Footnote references and extraction.** A link shall be treated as a note reference when its epub:type contains noteref, biblioref or glossref, or its role contains doc-noteref, doc-biblioref or doc-glossref. When detection by heuristics is enabled, a link that is not a backlink and that is, contains only, or is inside a superscript (a sup element, or vertical-align super, top, text-top, or a length) shall also be treated as one. The note's content is the referenced element; if that element is inline, the nearest block ancestor; if that ancestor is body, the next non-inline sibling. The note's kind is read from the target's epub:type or role (footnote, endnote or rearnote, biblioentry, definition, note), and a target that is an aside of type footnote is "hidden" (it is not rendered in the flow, so the popup is the only way to read it). Why: EPUB 3.3 structural semantics vocabulary; verified in the footnotes module. Standard Ebooks use noteref consistently; Gutenberg books usually rely on the superscript heuristic. For VoiceOver, a note reference becomes a custom action "Show note" on the text element, and the note content is announced in a sheet. Test: a Standard Ebooks endnote link and a Gutenberg superscript link both open the note; a backlink from the note does not.

**FOL-50 Internal and external links.** Activating a link shall resolve its href against the current section's path; an href with a scheme (anything matching a scheme prefix other than blob) is external and shall be offered to the system, never opened silently; an internal href resolves per FOL-05 to a section and fragment and navigates there, recording the departure point in a back stack. Why: verified in the view. Edge cases: links to manifest items that are not in the spine (FOL-51); mailto and tel schemes (external). Test: a Gutenberg footnote link navigates and "back" returns to the reference.

### Failure behaviour

**FOL-51 Failures are values and are shown.** Every resolution or load that can fail (container, package, navigation documents, section load, href resolution, CFI resolution, encryption, media overlay parse) shall return a diagnostic value that the reader records and, where the user initiated the action, shows: "This link's target is not in the book", "Your saved position could not be found; opened at the start", "This font could not be decoded". Why: foliate catches, logs to the console and continues, which in a desktop demo is fine; verified failure modes in the view are: a saved CFI whose spine step does not resolve leaves the reader with no section rendered; an unresolvable anchor leaves the section at its start with no relocation event, so the progress UI is stale; a link into a non-spine document does nothing. The project's standing rule is that a render path fails loud into a diagnostic. Test: each of the three cases above produces its message and a usable reader.

## Algorithms

This section describes the behaviours in enough detail to implement natively. Pseudocode is mine, written from the behaviour, not from the source. Where a step is only needed because the candidate runs in a browser, it says so and gives the TextKit 2 equivalent.

### CFI tokeniser and parser (FOL-13)

Tokenise one character at a time with a current state and an escape flag. A "^" that is not itself escaped sets the flag and consumes nothing else. In the neutral state, the characters "/", ":", "~", "@", "[", "!" and "," each set the state. The numeric states ("/" and ":") accumulate digits and end at the first non-digit, emitting an integer; "~" accumulates digits and dots and emits a decimal; "@" accumulates a decimal, and on ":" emits it and stays in "@" for the second coordinate. The bracket state accumulates characters until an unescaped "]" (emit the string), an unescaped "," (emit the string and stay in bracket state for the second text assertion string), or an unescaped ";" (emit the string and enter the parameter state). The parameter state accumulates a name until "=", then a value until an unescaped ";" (emit, stay in parameter state) or "]" (emit). Everything is processed with one trailing sentinel so the last token is emitted. A character that fits no state is an error for us (the candidate ignores it).

Parse the token list into parts. Split first at "," tokens: zero commas is a point CFI, two commas is a range (parent, start, end); any other count is an error. Within each, split at "!" into indirection levels. Within each level, a "/" token starts a new step with that index; ":" sets the step's offset; "~" its temporal offset; "@" appends to its spatial pair; a bracket string immediately after a "/" step (nothing between) is the step's id assertion if non-empty; a bracket string after anything else is appended to the step's text assertion list; a parameter named "s" sets the side bias. The result for a point is a list of levels, each a list of steps. For a range it is three such lists.

### CFI serialiser (FOL-14)

Emit each step as described in the requirement. Then join steps, join levels with "!", join parent, start and end with ",", and wrap. The canonical form has no whitespace. Normalise on write: offsets only on odd steps (if a caller hands an element step with an offset, convert it first; see FOL-16), temporal and spatial only when present, and the id assertion only when the id is non-empty.

### Child indexing (FOL-15)

Given an element, build its CFI child list:

```
children = element.children filtered to elements, text and CDATA
         (apply node filter: drop rejected; splice in a skipped node's own filtered children)
list = []
for node in children:
    if node is character data:
        if list is empty or list.last is an element: append chunk([node])
        else: list.last.append(node)            // merge adjacent character data
    else:
        if list is empty or list.last is an element: append emptyChunk
        append node
if list is empty: list = [emptyChunk]            // an element with no children has one empty chunk
if list.last is an element: append emptyChunk
prepend virtualBefore; append virtualAfter
```

The CFI step index is the position in this list: virtualBefore is 0, the first chunk 1, the first element 2, and so on. A chunk's length is the sum of its nodes' UTF-16 lengths.

For a native implementation, the parsed document must therefore preserve: the original child order, character data as separate nodes where the parser produced them (merging is done here, not at parse time), CDATA as character data, and comments and processing instructions as skippable nodes or not at all. Foundation's XMLParser reports text in pieces and CDATA separately; concatenating pieces within one element between element boundaries is correct because they form one chunk anyway, but the renderer must keep the UTF-16 length of each piece if it ever needs to map back to a piece.

### Position to CFI (FOL-16, FOL-20)

```
func steps(for node, offset) -> [Step]:
    if node is the document element: return []
    parent = nearest ancestor that the node filter does not skip (stop at document element)
    list = childList(parent)
    index = position in list of node, or of the chunk containing node
    if that entry is a chunk:
        offset = offset + sum of UTF-16 lengths of chunk members before node
    step = Step(index, id: node.id if element, offset: offset if chunk)
    return steps(for: parent, nil) + [step]
```

A point is `[steps]`. A range is built by comparing the two step lists from the top: while indices are equal and neither step has an offset, the step belongs to the parent path; the remaining steps go to start and end. If the start is after the end under FOL-18, swap or reject.

A position given as (element, childIndex) by a selection API should be converted before this: childIndex k means "before the k-th DOM child"; map it to the chunk or element step that begins there, with offset 0 for a chunk.

### CFI to position (FOL-17)

```
func resolve(local path, document) -> Result<Position, Failure>:
    node = document element
    for (i, step) in path.steps:
        list = childList(node)
        candidate = list[step.index] if in range
        if step.id present:
            if candidate is element with that id: ok
            else if element with that id exists in document: candidate = it; note "corrected by id"
            else if candidate is nil: fail(step i, "index out of range and id not found")
        if candidate is nil: fail(step i, "index out of range")
        if candidate is virtualBefore: return Position(before: node)
        if candidate is virtualAfter: return Position(after: node)
        if candidate is a chunk:
            if i is not the last step: fail(step i, "chunk step not last")
            offset = step.offset ?? 0
            walk chunk members accumulating lengths; the member where cumulative >= offset
              gives (member, offset - cumulativeBefore); boundary goes to the earlier member
            if offset > chunk length: fail(step i, "offset beyond chunk")
            if the chunk is empty: return the point between its neighbouring elements
              (the start of node's content for index 1, the end for the last odd index)
            check text assertion if present; record mismatch diagnostic
            return Position(member, localOffset)
        node = candidate
    return Position(element: node)   // path ended on an element
```

A range CFI resolves its start and end separately after collapsing (parent + start, parent + end). The package-level path is resolved the same way in the package document, ending on an itemref (FOL-19).

### Comparison (FOL-18)

Compare level by level, then step by step; the first differing index decides; a side that runs out of steps at a level is less; at the last step of a level compare offsets (missing is 0), then temporal (missing before present), then spatial y then x. Ranges compare by start then end. Assertions are ignored.

### Page geometry and page arithmetic (FOL-21, FOL-22)

With W the view's inline size, g the gap fraction, cap the orientation's column maximum:

```
S = min(W * (1 - g), maxInline * cap)   // page area between the outer gutters
G = S * g / (1 - g)                     // equals g * W when S is not capped
N = min(cap, ceil(S / maxInline))
columnWidth = S / N - G
pageInlineSize = S                      // one page is N columns, their gaps, and G/2 padding at each end
```

The candidate asks the browser to flow the content into columns of that width with gap G and half a gap of padding at each end, fixes the block size, and measures the total inline extent E of the content; pageCount = ceil(E ÷ S). It then sizes the scrollable surface to (pageCount + 2) pages, with one blank page before and after the content, so that a swipe past the first or last page lands on a blank page and that landing is the signal to open the adjacent section. Page index p (0-based over the content) has fraction p ÷ pageCount and size 1 ÷ pageCount; going to fraction f opens page round(f × (pageCount − 1)).

In TextKit 2 the equivalent is: one NSTextContainer per column (or one tall container per page column with the layout manager's page enumeration), fill containers in order, count the containers used; pageCount = ceil(containersUsed ÷ N). No measuring pass is needed; the layout manager reports where each line fragment landed. The blank spacer pages are a browser trick and are not needed; the section-edge condition is simply "page turn requested at page 0 or page pageCount − 1".

### Anchoring (FOL-23)

```
func scrollToAnchor(anchor):
    switch anchor:
    case fraction f:    page = round(f * (pageCount - 1)); show(page)
    case element or range:
        rects = line rectangles of the anchor (expand a collapsed range by one character first;
                 for an element use its first line rectangle)
        rect = first rect with width > 0 and height > 0, else rects.first
        page = floor(mappedStart(rect) / pageInlineSize); show(page)
    reason = "anchor"   // do not replace the anchor
after any user-initiated relocation (page turn, swipe, scroll):
    anchor = visibleRange()
```

Relayout triggers (size change, style change, fonts ready, image sizes known) re-run layout and then scrollToAnchor(anchor). The candidate also suppresses the scroll-debounced relocation report that an anchoring scroll would otherwise cause in scrolled mode.

### Visible range (FOL-24)

Browser version: walk body; element rect fully outside the page's inline window: reject with subtree; fully inside: accept; partial: descend; text node (non-blank) overlapping: accept. Take the first and last accepted nodes. For a text endpoint, binary-search the character offset at which the rectangle of [0, mid) ends before the window edge and the rectangle of [mid, end) begins after it. The window is [pageStart, pageEnd) in mapped coordinates, minus the spacer page in paginated mode and minus the margin in scrolled mode.

TextKit 2 version: enumerate the line fragments whose frames intersect the page's container(s); the visible range is [first fragment's start, last fragment's end) in the rendered attributed string; map both ends to source positions through the run table (FOL-36). This is exact and needs no bisection. Report the range with the page's fraction and size.

### Page turns and section edges (FOL-25, FOL-26)

```
func turn(direction):
    if locked: return; lock
    if direction forward:
        if page + 1 < pageCount: show(page + 1); reason "page"
        else if let next = nextLinearSection(): open(next, anchor: fraction 0)
    else:
        if page > 0: show(page - 1)
        else if let prev = previousLinearSection(): open(prev, anchor: fraction 1)
    unlock after the transition settles (the candidate waits 100 ms when not animating a scroll)
```

nextLinearSection skips sections whose linear is "no" in that direction. The candidate's swipe handling converts the finger's velocity into a page delta and snaps; a snap landing on a spacer page triggers the same section change.

### Section weights and book fraction (FOL-32, FOL-33)

```
w[i] = linear(i) && size(i) > 0 ? size(i) : 0
total = sum(w)
c[0] = 0; c[i+1] = c[i] + w[i] / total
progress(i, f, p):
    before = sum(w[0..<i]); here = before + f * w[i]; through = here + p * w[i]
    fraction = through / total
    location = (current: floor(here / 1500), next: floor(through / 1500), total: ceil(total / 1500))
    minutes = (section: (1 - f) * w[i] / 1600, book: (total - here) / 1600)
section(for fraction F):
    if F <= 0: (0, 0); if F >= 1: (last, 1)
    F += epsilon
    i = (index of first c > F) - 1; while w[i] == 0: i += 1
    return (i, (F - c[i]) / (w[i] / total))
```

### Current TOC entry (FOL-34)

```
flat = depth-first list of entries, numbered
groups: sectionHref -> (precedingEntry: flat[firstIndexInGroup - 1], entries: [(fragment, entry)])
for each section in spine order: map[section] = groups[section.href] ?? map[previousSection]
current(section i, visibleRange):
    g = map[i]; if nil: return nil
    if visibleRange is nil, or g.entries == [one entry without fragment]: return g.entries[0]
    for (k, (fragment, entry)) in g.entries:
        target = element(fragment) in this document; if nil: continue
        if target starts after visibleRange.end: return k > 0 ? g.entries[k-1].entry : g.precedingEntry
    return g.entries.last.entry
```

Apply the same to the page list.

### Blocks, segments and marks (FOL-37 to FOL-39)

Blocks as in the requirement. For each block: language and alphabet from ancestors; segment the joined text with the locale segmenter at word or sentence granularity; keep word-like segments; number them; for each, map (start, end) back to source positions (FOL-36, with the boundary adjustment so a segment ending at a node boundary ends in that node). Build the SSML as described, inserting a mark before each segment. Keep a table from mark name to source range for the block. State: current block index and last mark name. Resume = SSML of the current block with everything before the mark removed. Start from a position = first block whose end is not before the position; first mark whose start is at or after the position.

### Search (FOL-40 to FOL-42)

Substring strategy: join the strings; lowercase both query and text with the locale when ignoring case; find each occurrence; map start and end back through cumulative lengths. Segment-window strategy as in FOL-41. Excerpt: text of the range, plus up to 50 collapsed characters before from the start node and after from the end node, with ellipses when there was more. CFI: section base + range CFI.

### Overlay drawing and hit testing (FOL-43, FOL-44)

As in the requirements. Redraw all marks after relayout from fresh rectangles; hit test newest first on rectangles.

### Media overlay synchronisation (FOL-10, FOL-11)

```
entries = group consecutive pars by audio src: [(src, items: [(textDoc, fragment, begin, end)])]
play(run r, item j):
    stop current; open audio for entries[r].src; seek to items[j].begin ?? 0; highlight(items[j])
    on time t:
        if t > items[j].end ?? inf:
            unhighlight
            if j is last in run: play(r + 1, 0); return
        while items[j+1].begin ?? inf <= t: j += 1; highlight(items[j])
    on ended: unhighlight; play(r + 1, 0)
    if r is beyond the last run: start(nextSection)
start(section i): find the section's overlay; if none, start(i + 1); first item whose textDoc == section href
prev: j - 1, else last item of run r - 1, else last item of the previous section's overlay
next: j + 1
```

Highlight resolves the item's text href to a section and element, navigates there if needed, then applies the active class (for us: a highlight range and a VoiceOver announcement or focus move).

### Resource loading (FOL-09)

Load a content document by href: if cached, increment its reference count under the requesting parent and return it. Otherwise, for XHTML, HTML, SVG, CSS and scripts, read the text, resolve the references listed in FOL-09 against the document's path (each resolution loads that resource, recursively, with the current parent chain to prevent cycles), and cache the result keyed by href with a reference count of 1 and a list of children. For other media, read the bytes (through the decryption decoder when the href is in the encryption table). Unloading a section decrements its count and, at zero, releases it and recursively unreferences its children. For Funston this becomes a cache of parsed documents and decoded images keyed by href, bounded by memory, with the same parent-chain cycle guard.

### Fixed layout composition (FOL-46)

As in the requirement. Pseudocode from the rules, for a left-to-right book:

```
spreads = [empty]
for (i, item) in sections:
    last = spreads.last
    switch item.placement:
    case center: s = (last.left or last.right) ? newSpread() : last; s.center = item
    case left:   s = (last.center or last.left or i > 0) ? newSpread() : last; s.left = item
    case right:  s = (last.center or last.right) ? newSpread() : last; s.right = item
    case none:
        if last.center or last.right: newSpread().left = item
        else if last.left or i == 0: last.right = item
        else: last.left = item
```

Mirror left and right for right-to-left books.

## Data model and persistence

What foliate persists is the application's business (Foliate the app stores a CFI per book and annotations keyed by CFI). The library's contracts suggest this model for Funston.

**Position.** Save, per (identifier, file_name), a JSON record:

- `cfi`: the full CFI of the start of the visible range, with the package path (FOL-19). This is the primary key for restoring.
- `idref` and `sectionIndex`: the spine item's idref and index, so a position can be restored to the right chapter even when the local path fails (FOL-17 failure), and so a reader without the package document in memory can sort positions.
- `fraction`: the fraction within the section (FOL-22) as the second fallback, and `bookFraction` (FOL-32) for the library list's progress display without opening the book.
- `text`: up to 50 characters before and after the start (the search excerpt rule, FOL-42) so a later version can correct a stale CFI by searching nearby, which is what CFI 1.1 section 3.5 asks for.
- `format`: a version tag.

The existing book_positions.locator column holds Readium Locator JSON. Migration: a Readium locator has href (the section's resolved href), locations.progression (fraction within the section) and locations.totalProgression; map href to idref and index through the manifest, take progression as fraction, and leave cfi empty until the user next relocates. Keep the column name and primary key; add the format tag inside the JSON rather than a schema change, since the store already versions migrations.

**Save cadence.** Funston's current controller debounces position writes by one second and writes on background and disappear; keep that. A page turn produces one relocation and continuous VoiceOver reading produces one per element focus; the debounce absorbs both.

**Annotations.** Key by range CFI string (FOL-45); store colour or style, note text, created and modified dates, and the section index for fast re-attachment. Search results are transient and keyed under a reserved prefix.

**Book-level cache.** Section weights (byte sizes), the cumulative fractions, the flattened TOC with section grouping, and each section's base CFI are cheap to recompute from the package document but are needed before the first section renders; compute them on open and keep them in memory for the session.

**Settings.** Column maximum, maximum inline size, gap fraction, margin, flow (paginated or scrolled), line height, justification and hyphenation are the tokens of FOL-21 plus the demo's stylesheet choices (line height 1.4, justified text with automatic hyphenation limited to 3 characters before and 2 after a break and 2 consecutive hyphenated lines, widows 2, note asides hidden; all from the demo reader, which is explicitly not part of the library). Funston already prefers leading-aligned, unjustified text for low vision; keep that as the default and offer justification as a setting.

## Accessibility

foliate-js itself has almost no accessibility code; Foliate the application handles it through GTK. What the library gives an accessible reader is structure, and the house style in PDFLineAccessibility.swift tells us how to expose it.

- **Elements per page.** The PDF reader exposes one element per recognised line, computes frames on demand, and keeps a window of about eight pages of elements. For EPUB, TextKit 2 line fragments give the same line-level elements with exact frames and real text, so the PDF pattern transfers directly: one element per line fragment on the current page, frames from the layout manager, posted as layoutChanged when the page changes. The read-aloud block walker (FOL-37) gives the alternative unit, one element per paragraph, which reads more naturally with VoiceOver's continuous reading but makes "where am I on this page" coarser. The merged specification should pick one default and allow the other via the rotor; this study leans to line-level for consistency with the PDF reader and because Camden zooms and tracks lines, with heading levels and list containers preserved as traits and container boundaries (the PDF reader has no containers to preserve; EPUB does, and the standing rule is that container boundaries are invariants).
- **Focus tether.** Every element must be tethered to real text (FOL-24's visible range guarantees there is text on the page; blank spacer pages must not exist as elements). Off-page elements must not be exposed.
- **Page turning.** The PDF reader's adjustable "Reading page" element increments and decrements pages and announces "Page N of M". For EPUB the announcement should be the location or page label (FOL-33, FOL-35) and the chapter (FOL-34), not a layout-dependent page number alone.
- **Scrolled versus paginated under VoiceOver.** Funston's Readium integration switches to continuous scrolling under VoiceOver because pagination breaks the screen reader. With our own elements that reason disappears: a page is a container of line elements and VoiceOver's scroll gesture turns the page (accessibilityScroll, as the PDF reader does). The open question in section 11 is which mode to make the default under VoiceOver.
- **Chapter boundaries.** Because the candidate loads one section at a time, VoiceOver reading would pause at every chapter; FOL-26 asks for lookahead so the next section's first element exists when focus reaches the end of the current one.
- **Read-aloud and highlighting.** The mark ranges (FOL-39) are source ranges; the highlight of the spoken word is a drawn mark (FOL-43), and the same range is where VoiceOver focus should move if the user is following along with VoiceOver rather than the synthesiser. Media overlays (FOL-11) use the same mechanism.
- **Notes.** Note references (FOL-49) become custom actions on the containing element; the note's content is presented in a sheet with its own focus.
- **Links.** Links inside a line element become custom actions or the link trait on a sub-element; external links must say they leave the book.
- **Dynamic Type and appearance.** The paginator's anchor rule (FOL-23) is what keeps the reader on the same paragraph when the user changes text size in Settings; the current controller already maps Dynamic Type to a font scale and re-submits preferences on trait change.
- **Verification.** Per the standing rules, none of this is done until it is driven under VoiceOver on a simulator or device: focus order within a page, one element per line, no tick noise over gutters and running heads, rotor membership for headings and links, container announcements at list and section boundaries, and no off-page elements.

## Malformed input and failure behaviour

Observed in the candidate (verified unless marked), with the behaviour Funston should adopt.

- Missing container.xml, no rootfile with the package media type, package document not well-formed: the open fails with an error naming the stage. Adopt: fail the open with the same granularity and a user message that the book file is damaged.
- META-INF/encryption.xml present with an unknown algorithm: warning, resource passed through. Adopt, plus a visible diagnostic in the book's info.
- Spine itemref whose idref is not in the manifest: warning, section dropped, indices shift. Do not adopt the dropping (FOL-03).
- Navigation document missing, not well-formed, or without a toc nav: fall back to the NCX; both missing: no table of contents, no error. Adopt; show "No contents" rather than an empty list.
- Content document declared XHTML but not well-formed: re-parse as HTML, record a warning. Adopt (FOL-09). This requires a lenient parser; see section 11.
- A section whose content cannot be read: the candidate logs, renders nothing new, and scrolls the previous section to its start. Do not adopt; render a diagnostic page in the section's slot (FOL-51).
- A navigation target (href or CFI) that does not resolve: the candidate logs and does nothing; for a saved position it opens the book at the start silently. Adopt the fallback (open at the start, or at the section start if the spine step resolved) and tell the user (FOL-51).
- A CFI with an id assertion that resolves to a non-itemref in the package document: drop the id and resolve by index. Adopt (FOL-19).
- A CFI whose step index is out of range or whose offset exceeds the chunk: the candidate throws a DOM exception, caught by the view. A step into an element with no element or text children, or into an empty chunk between two elements, also throws in the candidate (its child list has no entry to return). Adopt failure values and the empty-chunk rule (FOL-17).
- A malformed CFI string: the candidate produces NaN indices and fails later. Reject at parse (FOL-13).
- Fixed-layout document without a viewport: 1000 × 2000 fallback with a warning. For version one, FOL-48 applies.
- Media overlay par without text or audio: skipped. Clock value that does not parse: NaN, which disables time-based advancing. Adopt the skip; treat unparsable clock values as missing (0 or infinity) with a diagnostic.
- Publisher CSS using viewport units, page-break properties or -epub- prefixes: the candidate rewrites them (vw and vh to pixels from the window size, page-break to column-break, prefix stripped). For a TextKit renderer the equivalent is: resolve viewport units against the page size, honour break-before and break-after as page breaks, and accept -epub- properties as their unprefixed form.
- Fonts that fail to load: the layout re-expands when fonts become ready (the candidate re-measures on the fonts-ready event and on a resize observer). Adopt: relayout when a font finishes loading, then re-anchor (FOL-23).
- Pinch zoom during a swipe (browser): paging is disabled while zoomed. Funston: TextKit text is not zoomed by pinch; Dynamic Type replaces it.
- Section load race: the candidate locks page turns during a transition and ignores further requests. Adopt the lock.

## Test fixtures and vectors

Public fixtures (all public domain or openly licensed; none copied from the candidate):

- Project Gutenberg via Internet Archive: item manandmaid20512gut, file pg20512-images.epub (305.5 KB, verified to exist on 2026-10-14; the item also carries pg20512.epub without images). This is the corpus shape: EPUB with NCX and guide, superscript note links, illustrations.
- IDPF EPUB 3 samples (https://github.com/IDPF/epub3-samples/tree/main/30): wasteland-otf-obf and wasteland-woff-obf (IDPF font obfuscation); moby-dick-mo (media overlays; its content lives under OPS with one SMIL per chapter, verified from the directory listing); accessible_epub_3 (navigation document bk01-toc.xhtml and package.opf under EPUB; expected to carry a page list, verify on download); childrens-literature (nested TOC with hidden entries, landmarks); kusamakura-japanese-vertical-writing (vertical-rl, rtl progression); regime-anticancer-arabic (rtl); page-blanche and cole-voyage-of-life (fixed layout); georgia-pls-ssml (ssml:ph and ssml:alphabet); linear-algebra (MathML, to confirm math blocks are handled as blocks and not crashed on); svg-in-spine (SVG spine items).
- W3C EPUB 3.3 test suite (https://github.com/w3c/epub-tests/tree/main/tests/<id>, index at https://w3c.github.io/epub-tests/epub33/): pkg-spine-progression_ltr, pkg-spine-progression_rtl, pkg-spine-progression-default, pkg-spine-nonlinear-activation, nav-activation, ocf-font_obfuscation, ocf-font_obfuscation-bis, lay-fxl-layout-default, lay-fxl-layout-pre-paginated, lay-fxl-spread-none, lay-fxl-spread-both, lay-fxl-page-spread-left, lay-fxl-page-spread-right, lay-fxl-page-spread-combined, fxl-page-spread-center, lay-fxl-xhtml-icb_multi_declarations, lay-fxl-xhtml-icb_invalid_meta, mol-audio, mol-audio-exceeding-clipend, mol-audio-no-clipbegin, mol-audio-no-clipend, mol-timing-synchronization, mol-timing-synchronization_multiple_audio, mol-css, pkg-dir_but_not_content, pkg-lang_but_not_content.
- Standard Ebooks (https://standardebooks.org): any title, for EPUB 3 navigation documents with landmarks, semantic endnotes with noteref and backlinks, and well-formed XHTML; they have no page lists.

What the candidate's own tests cover (so we know the edge cases it has met; our vectors below are written from the specification, not copied): resolving a spine step with and without an id assertion against the package document from the CFI specification's example; round-tripping five CFIs through an XHTML page from the specification's example, then through a variant of that page with text nodes removed, CDATA and comments inserted and characters replaced by numeric references, then through a variant with injected nodes that a filter rejects or skips; the ten single-character ranges "/4/10,/3:i,/3:i+1" over a mixed chunk; offsets inside skipped wrapper elements; ids and bodies containing "]", "!", "/", "^" and ","; and seven comparison cases including prefix paths and range versus point.

### CFI parse and serialise vectors (FOL-13, FOL-14)

Each line is input, then the expected structure, then the expected canonical output.

1. `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:10)` parses to two levels: [step 6; step 4 id "chap01ref"] and [step 4 id "body01"; step 10 id "para05"; step 3 offset 10]. Serialises unchanged.
2. `/6/4!/4/10,/2/1:1,/3:4` (no wrapper) parses to parent [[6,4],[4,10]], start [[2, 1 offset 1]], end [[3 offset 4]]. Serialises as `epubcfi(/6/4!/4/10,/2/1:1,/3:4)`.
3. `epubcfi(/6/4[chap0^]!/1ref^^]!/4)` parses the id as `chap0]!/1ref^`. Serialises unchanged.
4. `epubcfi(/6/4!/4/2~3.5@50:30)` parses step 2 with temporal 3.5 and spatial (50, 30). Serialises unchanged.
5. `epubcfi(/6/4!/4/10/3:10[xxx,yyy])` parses a text assertion with before "xxx" and after "yyy". Serialises unchanged.
6. `epubcfi(/6/4!/4/10/3:10[,yyy;s=a])` parses before empty, after "yyy", side bias "a". Serialises unchanged.
7. `epubcfi(/6/4!/4/10[para05;s=b])` parses id "para05" with side bias "b" and no text assertion. Serialises unchanged.
8. `epubcfi(/6/4!/4/10/3:0)` keeps the zero offset on output.
9. `epubcfi(/6/4!/4/10/3:0~0)` keeps temporal 0 on output (the candidate would drop it).
10. `epubcfi(/6/4!/4/10/x)` is rejected at the "x" (the candidate would produce NaN).
11. `  epubcfi(/6/4)  ` with surrounding whitespace parses as `epubcfi(/6/4)`.

### Child indexing and round trip vectors (FOL-15 to FOL-17)

Document A (our own, in the spirit of the specification's example):

```
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>t</title></head>
  <body id="b">
    <p id="p1">One</p>
    <p id="p2">ab<em>cd</em><!-- c --><![CDATA[ef]]>gh</p>
    <img id="i1" src="x.png" alt=""/>
    <p id="p3"><span>x</span><span>y</span></p>
  </body>
</html>
```

Whitespace text between the elements counts as chunks. Expected:

- The element body is `/4[b]` (html's children: chunk 1, head 2, chunk 3, body 4, chunk 5).
- p1 is `/4[b]/2[p1]`; p2 is `/4[b]/4[p2]`; img is `/4[b]/6[i1]`; p3 is `/4[b]/8[p3]`.
- Inside p2 the children index as: chunk 1 = "ab", element 2 = em, chunk 3 = "ef" + "gh" merged (the comment is ignored, CDATA is character data), so "g" is at `/4[b]/4[p2]/3:2`, and offset 4 (the chunk's length) is the end of "gh": `/4[b]/4[p2]/3:4` is valid, `:5` fails with "offset beyond chunk".
- `/4[b]/4[p2]/3:1` resolves to the CDATA node at local offset 1 (between "e" and "f"); `/3:2` resolves to the end of the CDATA node (boundary goes to the earlier member), which is the same point as the start of "gh".
- Inside p3 the children are: empty chunk 1, span 2, empty chunk 3, span 4, empty chunk 5; `/4[b]/8[p3]/1` resolves to the start of p3's content; `/4[b]/8[p3]/0` resolves to "before p3's content"; `/4[b]/8[p3]/6` resolves to "after p3's content".
- Generating from the position (text "cd" inside em, offset 1) yields `/4[b]/4[p2]/2/1:1`.
- The range from ("ab", 1) to ("gh", 1) yields `epubcfi(/4[b]/4[p2],/1:1,/3:3)` (parent stops at p2 because the next indices differ); its text is "b" + "cd" + "ef" + "g".
- The range from ("gh", 0) to ("gh", 2) yields `epubcfi(/4[b]/4[p2],/3:2,/3:4)` (offsets are relative to the merged chunk) and its text is "gh".
- Correction: if p2's id moves to a different paragraph and the CFI `/4[b]/4[p2]/3:2` is resolved, the element with id p2 is used and the result records "corrected by id".
- A filter that skips a wrapper: wrapping "ab" in `<span class="w">` that the filter treats as transparent leaves every CFI above unchanged.

Package document B (our own):

```
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="u">
  <metadata>...</metadata>
  <manifest>...</manifest>
  <guide/>
  <spine id="s" toc="ncx">
    <itemref idref="cover" linear="no"/>
    <itemref id="c1" idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>
```

Expected base CFIs: the spine is the fourth element child, so index 8: cover `/8[s]/2`, ch1 `/8[s]/4[c1]`, ch2 `/8[s]/6`. A CFI written by another reader as `/6/4[c1]!/...` resolves by the id assertion to ch1 with "corrected by id"; `/6/4!/...` with no id resolves to whatever is the second element child of the third element child (the guide has no children, so it fails) and the failure says so.

### Comparison vectors (FOL-18)

1. `/6/4!/10` equals `/6/4!/10`.
2. `/6/4!/2/3:0` is after `/6/4!/2` (longer path at the same prefix sorts later).
3. `/6/4!/2/4/6/8/10/3:0` is before `/6/4!/4`.
4. `/6/4[x]!/4/10[y]` equals `/6/4!/4/10` (assertions ignored).
5. `/6/4!/4/10/3:5` is before `/6/4!/4/10/3:7`; `/6/4!/4/10/3` (no offset) equals `/6/4!/4/10/3:0`.
6. `/6/4` is before `/6/4!/2`.
7. `/6/4!/4/10,/3:1,/3:4` is before `/6/4!/4/10,/3:1,/3:5` (same start, earlier end).
8. `/6/4!/4/2~1@0:0` is before `/6/4!/4/2~2@0:0`; `/6/4!/4/2@10:5` is before `/6/4!/4/2@0:6` (y before x).

### Page geometry vectors (FOL-21, FOL-22)

View 800 points wide, gap 7 percent, maximum inline 720, column cap 2 (landscape):

- Outer gutters 28 each; S = 800 × 0.93 = 744 (below the cap of 1440); G = 744 × 0.07 ÷ 0.93 = 56 (equal to 7 percent of 800, as intended); N = min(2, ceil(744 ÷ 720)) = 2; column width = 372 − 56 = 316. Across the view: 28 + 28 + 316 + 56 + 316 + 28 + 28 = 800, so the edge margin (56) equals the inner gap (56).
- Content measuring 2300 points inline yields pageCount = ceil(2300 ÷ 744) = 4; fractions 0, 1/4, 1/2, 3/4; size 1/4; goTo 0.5 opens page round(0.5 × 3) = 2.
- The same view in portrait (column cap 1): S = min(744, 720 × 1) = 720, centred with 40 on each side; G = 720 × 0.07 ÷ 0.93 = 54.19; N = 1; column width = 720 − 54.19 = 665.81.

### Visible range vector (FOL-24)

A text node of 20 characters laid out so characters 0 to 9 fall in column 1 and 10 to 19 in column 2 (same page, two columns): the page's visible range covers the whole node. If column 2 is on the next page, page 1's range starts at offset 10 and page 0's range ends at offset 10.

### Progress vectors (FOL-32 to FOL-35)

Sections with weights [0 (cover, linear no), 1000, 3000, 1000]: total 5000; cumulative [0, 0, 0.2, 0.8, 1.0].

- progress(2, 0.5, 0): fraction 0.5; location current floor(2500 ÷ 1500) = 1, next 1, total ceil(5000 ÷ 1500) = 4; minutes in section 1500 ÷ 1600 = 0.9375, in book 2500 ÷ 1600 = 1.5625.
- progress(3, 0.5, 0.5): fraction (4000 + 500 + 500) ÷ 5000 = 1.0 (last page of the last section).
- section(for: 0.5) returns (2, 0.5); section(for: 0.2) returns (2, 0) thanks to the epsilon, not (1, 1); section(for: 0) returns (0, 0); section(for: 1) returns (3, 1).

TOC: entries A (ch1.xhtml), B (ch2.xhtml#s1), C (ch2.xhtml#s2), D (ch4.xhtml); sections ch1, ch2, ch3, ch4.

- ch1 with any range: A. ch2 with a range ending before s1: A (the entry preceding ch2's group). ch2 with a range containing s1 but ending before s2: B. ch2 with a range after s2: C. ch3 (no entries, inherits ch2's group; neither fragment is found in ch3): C. ch4: D.

Page list: labels "1" (ch1.xhtml#pb1), "2" (ch1.xhtml#pb2); a range in ch1 ending between pb1 and pb2 is page "1"; a range in ch2 (no page breaks) is page "2" by inheritance. A book with no page list reports no page label and the UI shows the location.

### Clock value vectors (FOL-10)

"0:23:23.84" = 1403.84 s; "23s" = 23; "1.5min" = 90; "500ms" = 0.5; "1:36:20" = 5780; "02:03" = 123; "0:00:00" = 0; "7" = 7; "1.5h" = 5400; "23:59.5" = 1439.5. "abc" is a parse failure.

### Obfuscation vectors (FOL-08)

Unique identifier `urn:uuid:12345678-1234-1234-1234-123456789abc` (45 bytes of UTF-8). IDPF key = SHA-1 = `c12d11495401cf12256a830ecde8a78b17879cc3`; the same identifier with leading spaces and a trailing newline yields the same key after whitespace removal. For a resource beginning with the eight bytes `4f 54 54 4f 00 01 00 00`, the deobfuscated first eight bytes are `8e 79 45 06 54 00 cf 12` (XOR with the key's first eight bytes). Adobe key from the same UUID = `12345678123412341234123412345678 9abc` without the space (16 bytes); the first eight bytes become `5d 60 02 37 12 35 12 34`. XOR is its own inverse: obfuscating a real font header "OTTO" gives those bytes and deobfuscating gives "OTTO" back, so the vector direction does not matter.

### Search vectors (FOL-40 to FOL-42)

Text nodes ["The ", "élève", " learned ", "well-known", " art."] (five nodes, joined "The élève learned well-known art.").

- Query "eleve", diacritics ignored, case ignored: one match at (node 1, 0) to (node 1, 5); excerpt context before "The" (from the previous node; the candidate would show nothing here) and after "learned well-known art." with whitespace collapsed and trimmed.
- Query "art", whole words: one match at (node 4, 1) to (node 4, 4); "part" would not match.
- Query "élève learned well-known", case and diacritics matching, substring strategy: one match from (node 1, 0) to (node 3, 10) spanning three nodes; the excerpt's matched text is the full query (the candidate's excerpt would read "élèvewell-known", dropping the middle node).
- Query "ÉLÈVE", case ignored, diacritics matching: one match (lowercasing with the locale keeps the accents).

### Block vector (FOL-37)

A body containing h1, p, p, ul with two li, and a div containing a p yields blocks: h1, p, p, li, li, p (the div's own block is empty and dropped).

## Things to avoid

Patterns in the candidate that we should not carry over, each with the reason. Several are also recorded as edge cases above; this is the consolidated list.

1. Dropping spine items whose idref does not resolve while keeping a full-spine index space elsewhere (FOL-03). One index space, placeholders for broken items.
2. Honouring an id assertion only on the final step, and then trusting it outright without checking the index (FOL-17). Correct at every element step and record which path was used.
3. Treating a missing character offset as equal to any offset in comparison (FOL-18). Missing is zero.
4. Dropping offsets on element steps at serialisation, which silently loses selection positions expressed as (element, child index) (FOL-16). Convert first.
5. Testing "has an offset" by truthiness, so offset 0 behaves like "no offset" when building ranges, and temporal 0 is dropped (FOL-14, FOL-20).
6. Accepting malformed CFI strings and producing NaN indices (FOL-13).
7. Reading the phonetic alphabet from xml:lang instead of ssml:alphabet, so every inherited alphabet is wrong (FOL-38).
8. Building the search excerpt by slicing the node array with string values, which drops the middle of matches that span three or more nodes (FOL-42).
9. Parsing the package prefix attribute with a greedy pattern that mis-splits two declarations on one line (FOL-07).
10. Matching CipherReference URIs against decoded manifest hrefs without decoding the URI (FOL-08).
11. Comparing media overlay times against undefined clip boundaries, which silently disables advancing (FOL-11). Default missing clipBegin to 0 and clipEnd to infinity.
12. Letting navigation to a manifest item that is not in the spine, or to an unresolvable CFI, do nothing without telling the user, and letting a stale saved position open the book at the start silently (FOL-51).
13. Leaving the reader with no section rendered when a saved CFI's spine step does not resolve (FOL-51).
14. Loading one section at a time with no lookahead, which puts a load pause at every chapter boundary during continuous reading (FOL-26).
15. Flattening media overlay seq structure and discarding epub:type, which forecloses skippability and escapability (FOL-10). Parse the structure even if version one ignores it.
16. Treating a matched element at the end of the visible range as ending at its child offset 0, so a page ending in an image reports a range that excludes the image (FOL-24). With line fragments this does not arise, but the rule "the range ends after the last visible content" should be stated.
17. Blank spacer pages as a navigation mechanism. They are a browser scrolling trick and must not become VoiceOver elements (section 7).
18. Supporting vertical writing in scrolled mode for vertical-rl only (the author's FIXME). If vertical writing is in scope, do both or neither.
19. Hard-coded "red" as the default mark colour and inline magic numbers for stroke widths, opacities and gaps. Tokens with names (project rule).
20. The candidate's security model (scripted content, same-origin blob URLs) is a browser problem; our renderer never executes scripts, but it must also never fetch external resources during offline reading (FOL-09, FOL-50).

## Open questions for the merged spec

1. **VoiceOver element granularity.** Line fragments (house style, exact frames, matches the PDF reader) or blocks (natural reading units, matches read-aloud)? Proposal: lines by default, with headings and list items as containers, and a rotor option for paragraphs. Needs a prototype under VoiceOver before deciding.
2. **Mode under VoiceOver.** Paginated with an adjustable page element and accessibilityScroll (as the PDF reader does), or scrolled as the Readium integration does today? The candidate's reason for scrolled mode (a browser's screen reader support) does not apply to our own elements.
3. **Lenient parsing.** Funston has XMLParser (strict). The candidate's fallback to HTML parsing matters for older Gutenberg files. Options: libxml2's HTML parser through its C API (available on iOS), a small tolerant XHTML parser of our own, or refusing non-well-formed books with a message. Survey the corpus first: a script over a few hundred Gutenberg EPUBs would say how many fail strict parsing.
4. **Section weight unit.** Bytes of XHTML (the candidate) overstate markup-heavy chapters. Characters of text content after parsing are available to us at the same cost. Locations per 1500 bytes versus per some number of characters changes what "location 212" means; pick one before any position is saved.
5. **Reported fraction semantics.** End of the current page (the candidate) or start? The end makes the last page 100 percent; the start makes the first page 0 percent. Both are defensible; the spoken progress and the slider must agree.
6. **Text location assertions.** Generate them on save (cheap: 50 characters each side) so a later version can correct stale positions; whether version one checks them is a cost question.
7. **Position record migration.** Keep Readium locator JSON readable forever, or convert once at first open? The study proposes converting lazily (section 6).
8. **Lookahead budget.** One section ahead and one behind, or a byte budget? Gutenberg chapters are tens of kilobytes; one each way is probably enough on 16 GB, but the merged spec should state the ceiling.
9. **Read-aloud engine.** AVSpeechSynthesizer utterances per block with per-utterance language (no SSML), or Apple's SSML support where available? The mark names and ranges are the same either way.
10. **Fixed layout in version one.** Decline (this study's recommendation) or render through a rasteriser? Decline unless another study finds a native path.
11. **Vertical writing.** Out of scope for the Gutenberg corpus; the merged spec should say whether the geometry is written direction-agnostic now (this study recommends yes, it is cheap) and leave rendering for later.
12. **Footnote heuristics.** The superscript heuristic has false positives (superscript links that are not notes). Enable it for Gutenberg books only, or always with an easy "open as link" alternative?
13. **Whether to expose running heads and feet to VoiceOver.** They are decorative duplicates of the chapter title and progress that the page element already speaks; this study says hide them from VoiceOver.

## Clean-room statement

This document was written by reading the candidate's source at the commit named in Provenance and describing its behaviour in my own words and in the vocabulary of the public EPUB specifications. It contains no code, comments, docstrings, test data, fixture files or README text copied or transliterated from the candidate. The pseudocode in section 5 was written from my understanding of the behaviour, not from the structure of the source. The test vectors in section 9 were written from the EPUB CFI 1.1 and EPUB 3.3 specifications and from documents of my own; where the candidate's tests cover an edge case, that fact is stated and the case is re-expressed, not copied. The candidate's files were cloned into a scratch directory outside the repository, were never copied into the worktree, and were not built or run. The only program executed was a script of my own, outside the clone, that computed the SHA-1 and clock-value vectors. Internal names of the candidate's modules appear only in "Architecture in our words" as orientation. An implementer working from this document alone can build the behaviours described without having seen the candidate.

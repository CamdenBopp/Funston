# Study: lightweight Swift EPUB parsers and FolioReaderKit

Requirement ID prefix: SWP. This is one of eight candidate studies for Funston's clean-room EPUB reader. It covers the three small Swift parsers (EPUBKit, Bookbinder, epubparser), FolioReaderKit (the archived UIKit reader that has the only Swift media-overlay and read-aloud code in the field), and two SwiftUI readers that turned out to be thin wrappers. Everything below is in my words; see the clean-room statement at the end.

## Provenance

All repositories were shallow-cloned on 2026-10-14 into empty directories under this session's scratchpad, read, and never built or run. No file from any of them was copied into this repository.

| Repository | Commit read | Commit date | License (from the LICENSE file) | Size read |
| --- | --- | --- | --- | --- |
| https://github.com/witekbobrowski/EPUBKit | 8dac90d14074af3882ee2192be5baf892a130ad9 | 2026-03-26 | MIT, copyright 2022 Witek Bobrowski | 20 source files, 2,000 lines; 9 test files, 1,800 lines |
| https://github.com/stonezhl/Bookbinder | ed59f053d400d75d907d42515952340512b2e7cb | 2019-08-16 | MIT, copyright 2019 Stone Zhang | 10 source files, 640 lines; 5 test files, 430 lines |
| https://github.com/awxkee/epubparser | 933dd1ff2dc0dca0ed8bb3111c9d20a455f3a78b | 2023-09-03 | CC0 1.0 Universal | 12 source files, 1,570 lines; 1 test file, 11 lines (empty template) |
| https://github.com/FolioReader/FolioReaderKit | e67424be15ce8c6f5ce2d16872acab5c2953f76b | 2019-08-28 | BSD-3-Clause, copyright 2015-2018 Heberti Almeida | 33 Swift files, 8,500 lines, plus 3 vendored control files, 960 lines; Bridge.js 654 lines; Style.css 292 lines; 1 test file, 36 lines (empty template) |
| https://github.com/jtCodes/EPUBReaderSwiftUI | 677b90b328323e2914971662b3b92b73eb2ba9a3 | 2026-04-23 | No LICENSE file exists at this commit. The README says "MIT (or whichever license specified in the repository)" and points to a LICENSE file that is not there. Treat as unlicensed for provenance. | 1 source file, 1,607 lines |
| https://github.com/dancarvajc/EbookReader | 3269f16fc901a31810d3befe79185fb968654e27 | 2024-08-11 | MIT, copyright 2023 Daniel Carvajal | 7 source files, 479 lines |

Line counts come from `wc -l` over each clone.

Three support libraries were also shallow-cloned and read only where a candidate's behaviour depended on them, so that claims about extraction paths, path traversal and namespace handling below are verified rather than remembered:

| Library | Commit read | Commit date | Why |
| --- | --- | --- | --- |
| https://github.com/marmelroy/Zip | bca30f6d6c7d37cbc4aa8f6b0002e281dcc36195 | 2024-02-14 | EPUBKit's archive extraction destination |
| https://github.com/weichsel/ZIPFoundation | e7a17d57c583067eaa6659cd6d9521265b7664e9 | 2026-09-12 | Bookbinder's and epubparser's extraction; path-traversal check |
| https://github.com/tadija/AEXML | ae166cefbac3443299c205a1fbc63215263fadf5 | 2026-10-12 | EPUBKit's, epubparser's and FolioReaderKit's XML element matching |

Corrections to the brief:

- FolioReaderKit's last commit is from August 2019. The GitHub archive date given in the brief (November 2020) is a repository state, not a commit; nothing changed between the two.
- epubparser is not an independent design. Its parser and model files are FolioReaderKit's EPUBCore files with the type prefix renamed. A line-level diff of the nine model files shows only import lines and one added property differ; the parser differs only in the ZIP library, the error types, and an added step that concatenates every spine document into one HTML file. Its CC0 dedication therefore sits on top of BSD-3 code it does not attribute. This study treats the two parsers as one design and names the differences where they exist.
- EPUBReaderSwiftUI is a SwiftUI wrapper around Readium 3 (ReadiumShared, ReadiumStreamer, ReadiumNavigator, ReadiumAdapterGCDWebServer), not a parser or a renderer. EbookReader is a 479-line SwiftUI wrapper around WKWebView and a fork of Bookbinder. Both get one paragraph in section 3 and nothing else.

Funston files read for context and left unchanged: Funston/UI/EPUBReaderController.swift, Funston/UI/PDFLineAccessibility.swift, Docs/Roadmap.md section 4, and the book_positions migration in Funston/Services/SQLiteStore.swift.

Specifications cited: W3C EPUB 3.3 (https://www.w3.org/TR/epub-33/), the EPUB CFI specification maintained with it (https://w3c.github.io/epub-specs/epub33/epubcfi/; its editor's draft has unnumbered headings, so it is cited by heading title), IDPF OPF 2.0.1 (http://idpf.org/epub/20/spec/OPF_2.0.1_draft.htm), OCF 2.0.1 by section title, and the DAISY NCX definition in ANSI/NISO Z39.86-2005 section 8. Section numbers for EPUB 3.3 and OPF 2.0.1 were checked against the live documents on 2026-10-14.

## What it is and why it matters to Funston

Funston opens Project Gutenberg EPUBs served by archive.org as original files, in both the EPUB 2 build (NCX, XHTML 1.1 with a DOCTYPE) and the EPUB 3 build (nav document plus a compatibility NCX). Camden has decided to replace Readium with a parser and a native TextKit 2 renderer that Funston owns. The implementer will work from the merged spec alone.

The three small parsers answer one question: what is the minimum a Swift EPUB parser has to get right, and where do small parsers cut corners that real books punish. Each has an instructive failure:

- EPUBKit is the modern one (Swift 6 tools version, Swift Testing) and still cannot open an EPUB 3 book that has no NCX, cannot read the metadata of the oldest common EPUB 2 shape, and always reports left-to-right page progression. All three are verified by reading and named by file and function in section 10.
- Bookbinder is the only one that parses XML by namespace rather than by literal prefix, and it drops any NCX entry that lacks a playOrder, which the OPF 2.0.1 spec says is optional.
- epubparser and FolioReaderKit share one parser that percent-decodes paths, falls back to file extensions when media types are wrong, and reads EPUB 3 refinement metadata, but crashes with a precondition when a book has neither NCX nor nav document and prefers the NCX over the nav document even in EPUB 3.

FolioReaderKit matters for a different reason. It is the only Swift code base that implemented media overlays (SMIL parsing, clip scheduling, text highlighting, page turning) and sentence-level read-aloud with AVSpeechSynthesizer, plus highlights with notes, a saved position, reading-time estimates, a fonts menu, night mode, RTL and horizontal-or-vertical layout. All of it sits on UIWebView and a JavaScript bridge, so none of the rendering code transfers. The behaviours do, and so do the mistakes: polling the audio clock at 10 ms, anchoring highlights by 30 characters of surrounding HTML, and saving the reading position as a scroll offset in points.

For Funston the stakes are concrete. Reading positions already live in book_positions as Readium Locator JSON keyed by archive identifier and file name. VoiceOver is the primary test harness, and the PDF reader's line-element style (one accessibility element per recognized line, frames computed from live layout) is the house style the EPUB renderer must match. Nothing in these candidates addresses accessibility at all, which is itself a finding.

## Architecture in our words

### EPUBKit

A single parser object orchestrates four sub-parsers (metadata, manifest, spine, table of contents) behind small protocols, with an optional weak delegate that receives progress callbacks (began, unzipped, located content, finished each part, finished, failed). Internal names, for orientation only: EPUBParser, EPUBArchiveService, EPUBContentService, EPUBMetadataParser, EPUBManifestParser, EPUBSpineParser, EPUBTableOfContentsParser, EPUBDocument.

Pipeline, verified by reading:

1. If the input URL is a directory, use it as the extracted book; otherwise hand the file to the Zip library's quick-unzip call, which extracts the whole archive into the app's Documents directory under a folder named after the file (verified in the Zip library: its search path is the document directory on iOS, caches only on tvOS). Nothing deletes that folder afterwards.
2. Read META-INF/container.xml with AEXML, take the first rootfile element's full-path attribute. The rootfile's media-type is not checked.
3. Parse the package document with AEXML and hand the spine, metadata and manifest elements to the sub-parsers in that order.
4. Require the spine's toc attribute to name a manifest item; read that file as the NCX; otherwise throw. There is no nav document support at all.
5. Return an immutable document struct: directories, metadata, manifest keyed by id, spine, table of contents tree.

XML: AEXML is a thin tree over Foundation's XMLParser with namespace processing off (verified in AEXML's options and parser setup), so an element is found by its literal qualified name. Looking up "dc:title" finds a title only when the book used the dc prefix and put the element directly under metadata.

Public surface: a failable convenience initializer on the document struct that swallows the error, a throwing parse method on the parser, and the delegate protocol. Models are structs with optional fields; nothing is marked Sendable; the parser is a final class with mutable delegate state.

### Bookbinder

Three value types map onto the three files a parser must read (container, package, NCX), each a failable initializer that takes a file URL, parses it with Kanna (libxml2) and evaluates XPath expressions with explicit namespace maps. A book class wraps them and derives everything else lazily: unique identifier, release identifier, publication date, cover image URLs, nav document URL, NCX document, and the list of primary spine item URLs. A binder object owns extraction. Internal names: Bookbinder, BookbinderConfiguration, EPUBBook, ContainerDocument, OPFDocument, OPFMetadata, OPFManifest, OPFSpine, NCXDocument, NavPoint, XPath.

Pipeline, verified by reading:

1. Extract with ZIPFoundation into a root directory (default: the temporary directory) under a folder named by an identifier that defaults to the file's base name. If that folder already exists, skip extraction entirely and reuse whatever is there.
2. Container: XPath for any rootfile element with a full-path attribute, first match wins, media-type ignored.
3. Package: require the package element and its unique-identifier attribute (missing attribute means the whole book fails to open), then metadata, manifest, spine. Metadata iterates every child in the Dublin Core namespace regardless of prefix, and reads meta elements for dcterms:modified and the EPUB 2 cover name.
4. NCX: parsed on demand from the spine's toc attribute; nav point entries require an integer playOrder, a label and a src or they are silently dropped, children recursively.
5. The nav document is located (manifest item whose properties attribute equals "nav" exactly) but never parsed.

XML: libxml2 through Kanna; the only candidate with namespace-correct matching.

Public surface: the binder's bind method (returns an optional book, prints errors to the console), a subclassable book class, and the raw Kanna document exposed on each parsed file so callers can run their own XPath (the README and tests use this to read the guide).

### epubparser and FolioReaderKit's parser

One design, described once. Internal names in FolioReaderKit: FREpubParser, FRBook, FRMetadata, FRResource, FRResources, FRSpine, FRTocReference, FRSmilFile, FRSmilElement, FRSmils, MediaType; epubparser renames the FR prefix to Epub.

Pipeline, verified by reading:

1. Extract the whole archive into a base directory: FolioReaderKit uses SSZipArchive into the app's Documents directory (or a caller-supplied path) under a folder named after the file including its extension, and by default deletes the original .epub once extraction starts (a ZIP delegate callback does this when the remove flag is set, which the presenting API sets to true). epubparser uses ZIPFoundation into a caller-supplied path and never deletes. Both skip extraction when the folder already exists and mark the folder excluded from backup.
2. Container: first rootfile's full-path; media type guessed from the file extension.
3. Package: read the package element's unique-identifier and version; walk every manifest item, building a resource record with id, href, a percent-decoded absolute path, a media-type record (looked up by name, otherwise synthesized from the extension), the properties string and the media-overlay attribute; any item whose media type is SMIL is parsed immediately into a generic element tree. Resources are keyed by href. Then metadata: a flat loop over metadata children matching literal names (dc:title, dc:identifier with opf:scheme, dc:language, dc:creator and dc:contributor with opf:role and opf:file-as, dc:publisher, dc:description, dc:subject, dc:rights, dc:date with opf:event) and three overlapping records for meta elements (name/content, property/id/value, property/refines/value). Then the unique identifier by id lookup, the cover (EPUB 2 meta name first, then an item whose properties equal "cover-image"), the table-of-contents resource (first item whose media type is NCX, else first whose extension is .ncx, else first whose properties equal "nav"), a precondition failure if none, the TOC tree, a one-level flattened TOC, and finally the spine (itemrefs whose idref exists in resources, linear flag, page-progression-direction from the attribute).
4. epubparser then parses every spine document with SwiftSoup, appends each body's markup into the first document's body, and writes one combined HTML file next to the first chapter for a web view to load.

XML: AEXML, literal qualified names, as in EPUBKit. The SMIL tree is kept as generic elements (name, attributes, children) with helpers to find the text and audio children of a par and to convert clip times.

Public surface: an NSObject parser with a throwing read method that takes paths as strings, three convenience methods that re-parse the whole book just to return the cover image, title or author, and NSObject model classes with implicitly unwrapped optionals.

### FolioReaderKit reader

A container view controller parses the book on a background queue, then builds a navigation controller around a center view controller. The center is a UICollectionView with one cell per spine item; each cell owns a UIWebView that loads the chapter's HTML after injecting the kit's stylesheet and JavaScript bridge into the head and the current font, size, media-overlay style and night-mode classes onto the html element. All reader behaviours (highlighting, sentence wrapping, audio marking, anchor offsets, reading time) are JavaScript functions evaluated synchronously from Swift, and the page reports back by navigating to custom URL schemes (highlight, highlight-with-note, play-audio, and caller-registered schemes) that the web view delegate intercepts. Internal names: FolioReader, FolioReaderContainer, FolioReaderCenter, FolioReaderPage, FolioReaderWebView, FolioReaderAudioPlayer, FolioReaderFontsMenu, FolioReaderPlayerMenu, FolioReaderChapterList, FolioReaderHighlightList, FolioReaderPageIndicator, ScrollScrubber, Highlight (a Realm object), FolioReaderConfig, FolioReaderUserDefaults, Bridge.js, Style.css.

Chapter-level paging is the collection view; page-level paging within a chapter is UIWebView's built-in pagination mode (left-to-right, page breaking) in horizontal layout, or plain scrolling in vertical layout. Preferences persist in UserDefaults, either globally or under a per-reader identifier.

### EPUBReaderSwiftUI and EbookReader

EPUBReaderSwiftUI wraps Readium's EPUBNavigatorViewController in UIViewControllerRepresentable and adds SwiftUI chrome: a customizable overlay and TOC view, highlights as Readium decorations with a colour, a style (highlight or underline) and a note, bookmarks as a locator plus a chapter title and a text preview the app persists itself, font size through a small preferences struct, and a remote-URL downloader with a cache. Its one idea worth keeping is the bookmark shape (locator, date, chapter title, text preview of about 120 characters) and matching a bookmark to the current page by comparing locator href and progression. Nothing else is novel, and it inherits every Readium behaviour Funston is leaving.

EbookReader loads one spine document at a time into a WKWebView via file URL, injects four user scripts (body colour, image max-width, a viewport meta, transparent background), tracks the vertical scroll offset per chapter in an array and persists the array and the current chapter index in UserDefaults keyed by the book's unique identifier, and draws a custom scroll indicator. It is a readable minimum for "one chapter per web view with a saved offset", and its persistence is exactly the fragile shape section 6 argues against.

## Requirements

Each requirement is in "shall" form, followed by why, the specification citation if any, edge cases, and how to test it. IDs are stable; do not renumber.

### Container and archive

**SWP-01 The reader shall read the OCF container entry by entry from the ZIP central directory, decompressing each resource on demand, and shall never extract the whole book to disk in order to open it.**
Why: every candidate extracts the entire archive before reading one byte of XML. EPUBKit extracts into the user-visible Documents directory and never cleans up (verified in the Zip library's quick-unzip, which targets the document directory on iOS). FolioReaderKit also extracts into Documents and deletes the original file by default. Bookbinder, epubparser and FolioReaderKit all skip extraction when a folder of the same name exists, so a re-downloaded file with the same name shows the old book's contents. Funston keeps downloads under a lease and must not create a second copy or delete the first.
Spec: EPUB 3.3 4.3 (OCF ZIP container), 4.3.2 (ZIP file requirements).
Edge cases: entries stored with no compression (the mimetype entry must be), deflate entries, ZIP64 archives above 4 GB are out of scope but must fail with a typed error, data descriptors, duplicate entry names (first wins, diagnostic), a central directory whose entry names use CP437 rather than UTF-8 (treat as UTF-8, fall back to ISO Latin 1 on decode failure, diagnostic).
Test: open a 30 MB audio-bearing book and assert resident memory does not grow by the archive size; open two books with the same file name in succession and assert the second's title is shown; assert no file is written under Documents.

**SWP-02 The reader shall reject any ZIP entry whose normalized path escapes the container root and shall compare entry names to resolved hrefs case-sensitively after percent-decoding and path normalization.**
Why: ZIPFoundation checks containment on extraction (verified: it throws an invalid-file-name error when an entry URL is not contained in the destination). The Zip library EPUBKit uses performs no such check that I could find in its quick-unzip path. Since SWP-01 removes extraction, the check moves to the entry reader. Case matters because OCF names are case-sensitive and iOS file systems are not, which hides mismatches during development.
Spec: EPUB 3.3 4.2.3 (file paths and file names), 4.2.5 (URLs in the OCF abstract container).
Edge cases: entry names with "../" or leading "/", names longer than 255 bytes, names with characters OCF forbids (control characters, a trailing dot or space), two entries differing only by case.
Test: a hand-built archive with an entry named to escape the root must open with that entry reported as a diagnostic and unreadable, never written or served.

**SWP-03 The reader shall read the mimetype entry and the META-INF/container.xml entry, record a diagnostic when the mimetype entry is missing, not first, compressed, or not exactly the EPUB media type, and shall still open the book.**
Why: no candidate looks at the mimetype entry at all, and real books from Gutenberg and Standard Ebooks are correct here, so strictness buys nothing. Recording the diagnostic keeps a validator path available later.
Spec: EPUB 3.3 4.3.3 (OCF ZIP container media type identification).
Edge cases: mimetype with a trailing newline (common; accept), mimetype absent (open anyway), a plain ZIP of XHTML files with no container (fail with the container-missing error from SWP-30).
Test: three archives, one correct, one with a compressed mimetype entry, one with none; all open, the diagnostics differ.

**SWP-04 The reader shall parse container.xml with a namespace-aware parser, choose the first rootfile element whose media-type is application/oebps-package+xml, fall back to the first rootfile with a full-path attribute when none declares that media type, and fail with a typed error when there is no rootfile with a full-path.**
Why: all four parsers take the first rootfile without checking its media type. Real books occasionally list a second rootfile (an alternate rendition); picking by media type then by order is the lenient and correct choice.
Spec: EPUB 3.3 4.2.6.3.1 (container file), 4.2.6.3.1.2 (rootfiles), 4.2.6.3.1.3 (rootfile).
Edge cases: full-path with a leading "/" (strip it, diagnostic), full-path percent-encoded, container.xml with the default namespace undeclared (match on local name as a fallback, diagnostic), two rootfiles both valid (first wins, record the count), the whole book nested one folder down so the container file is not at the root (fail with container-missing, but record the nested path in the diagnostic; EPUBKit's archive-failure fixture has exactly this shape).
Test: EPUBKit's own error tests cover an archive with no container.xml and a container whose rootfiles element is empty; reproduce both as our own vectors (section 9, V5 and V6).

**SWP-05 All hrefs in the package document shall resolve relative to the package document's own location; hrefs in the nav document and src values in the NCX and in SMIL files shall resolve relative to their own file's location.**
Why: every candidate resolves manifest hrefs against the package directory, which is right, but looks up TOC targets by the raw string, which is only right when the nav or NCX sits beside the package document. FolioReaderKit's sample media-overlay book keeps its SMIL files in a Misc folder with text and audio references beginning with "../", and its player resolves audio against the SMIL's folder but looks up the text target by matching the fragment alone. Gutenberg's EPUB 3 builds keep the nav document and chapters in the same folder, so this bug stays hidden until a Standard Ebooks or publisher book puts the nav in the package root and chapters under text/.
Spec: EPUB 3.3 4.2.5 (URLs in the OCF abstract container), 5.6.2 (item element, href).
Edge cases: package document at the container root (full-path with no directory), nav in a sibling directory, NCX src containing "../", fragment-only hrefs in the nav ("#id" means the nav document itself).
Test: a book with the package document in OEBPS/, the nav in OEBPS/nav/, chapters in OEBPS/text/ and the NCX in OEBPS/; every TOC entry must resolve to the correct spine index.

### XML

**SWP-06 The parser shall match XML elements and attributes by namespace URI and local name, never by literal prefix, and shall accept the OPF 2.0.1 legacy dc-metadata and x-metadata wrappers around metadata children.**
Why: EPUBKit, epubparser and FolioReaderKit match "dc:title" and "opf:role" literally (AEXML runs with namespace processing off, verified). EPUBKit's own Alice fixture, a 2007-era EPUB 2 sample whose package names D. Appleton and Co as publisher, puts the Dublin Core elements inside a dc-metadata wrapper with the dc prefix declared on the wrapper; EPUBKit's document tests assert that this book has no title, no author and no publisher, which is the library asserting its own bug. Bookbinder matches by namespace but only on direct children of metadata, so it has the wrapper problem too.
Spec: EPUB 3.3 5.5 (metadata section), 5.5.1 (metadata element); OPF 2.0.1 2.2 (publication metadata; dc-metadata and x-metadata are deprecated but allowed).
Edge cases: a package that declares the Dublin Core namespace with a prefix other than dc; opf attributes written without a prefix on EPUB 2 books (some tools emit role="aut"; accept as a fallback with a diagnostic); the EPUB 3 ops namespace prefix "epub" on nav documents and SMIL; xml:lang and dir attributes.
Test: the same minimal package serialized three ways (dc prefix, custom prefix, dc-metadata wrapper) must yield identical metadata.

**SWP-07 The XML parser shall be non-validating, shall never fetch external entities or DTDs over the network, shall bound entity expansion, and shall supply the XHTML 1.1 named character entities from a built-in table when a content document declares an XHTML DOCTYPE.**
Why: no candidate thought about this; they delegate to a web view for content. A TextKit renderer parses the XHTML itself. Gutenberg's EPUB 2 builds use an XHTML 1.1 DOCTYPE and named entities such as the non-breaking space; Foundation's XMLParser reports an undefined-entity error for those when it is not resolving the DTD. The merged spec needs a built-in table of the roughly 250 XHTML named entities (the Latin-1, special and symbol sets) or an entity-expanding pre-pass.
Spec: EPUB 3.3 6.1 (XHTML content documents); XML 1.0 well-formedness.
Edge cases: entity references in attribute values, numeric character references, a DOCTYPE with an internal subset, the five predefined XML entities, CDATA sections in scripts.
Test: a chapter containing every XHTML named entity must round-trip to the expected Unicode text with no parser error and no network access (assert with a URL protocol stub).

### Package document

**SWP-08 The parser shall read the package element's version, unique-identifier, xml:lang, dir and prefix attributes; shall resolve the unique identifier to the dc:identifier whose id matches, falling back to the first dc:identifier with a diagnostic; and shall not refuse to open a book whose unique-identifier attribute is missing or dangling.**
Why: Bookbinder returns no book at all when unique-identifier is absent (verified). FolioReaderKit and epubparser resolve by id and leave the identifier nil when it dangles. EPUBKit ignores the attribute and takes the first dc:identifier's text.
Spec: EPUB 3.3 5.4 (package element), 5.5.3.1.1 (dc:identifier); OPF 2.0.1 2.1 (package identity).
Edge cases: version "2.0" versus "3.0" versus "3.1" versus missing (treat missing as 2.0 with a diagnostic); unique-identifier naming an id that belongs to a non-identifier element; several identifiers with schemes (ISBN, URL, UUID); Gutenberg uses a URL identifier such as http://www.gutenberg.org/20512.
Test: four packages (correct, dangling, missing, duplicate ids) all open; the resolved identifier and the diagnostic list are asserted.

**SWP-09 The parser shall keep every Dublin Core element as an ordered list with its text, id, xml:lang and dir, keep the EPUB 2 opf:role, opf:file-as, opf:scheme and opf:event attributes, keep every meta element in both the EPUB 2 name/content form and the EPUB 3 property/refines/scheme/id form, and shall apply refines so that role, file-as, title-type, display-seq, identifier-type and alternate-script attach to the element they refine.**
Why: EPUBKit keeps only the first of each element and one creator (verified: each field is read once from the first matching child). Bookbinder keeps lists but no roles. FolioReaderKit and epubparser keep lists and EPUB 2 attributes, record meta elements (a meta with both property and id is recorded twice), and never apply refines, so EPUB 3 creator roles are invisible. They also file every dc:contributor into the creators list (verified: both branches append to the same array) and treat the language oddly: the default is "en-US" and a declared value of exactly "en" is discarded in favour of that default (verified). Standard Ebooks and Gutenberg EPUB 3 books express author roles only through refines.
Spec: EPUB 3.3 5.5.3 (DCMES), 5.5.4 (meta element), 5.3.6 (refines attribute); OPF 2.0.1 2.2.1 through 2.2.15.
Edge cases: more than one dc:title (pick the one whose title-type refinement is "main", else the lowest display-seq, else the first; keep the rest as subtitles and collection titles); dc:creator with no text; file-as supplied both as an EPUB 2 attribute and an EPUB 3 refinement (the refinement wins); refines targets that do not exist (keep the meta, diagnostic); meta elements with no text; dc:date with an opf:event of "modification" on EPUB 2 books.
Test: one EPUB 2 and one EPUB 3 package expressing the same author, role, sort name, two titles and a modification date must produce the same normalized metadata record.

**SWP-10 The parser shall compute a release identifier as the unique identifier joined with the dcterms:modified value when present, and the reader shall store that release identifier with every position, highlight and bookmark so that a changed edition of the same archive file can be detected.**
Why: Bookbinder is the only candidate to compute this (unique identifier, "@", modified timestamp). FolioReaderKit keys highlights and positions by the file name without extension, so two different books with the same file name share highlights (verified: the book name is the last path component and the highlight book id drops its extension). Funston keys positions by archive identifier and file name; the release identifier is the integrity check on top.
Spec: EPUB 3.3 5.5.3.1.1 (dc:identifier, and the release identifier it defines together with dcterms:modified in 5.5.4).
Edge cases: EPUB 2 books have no dcterms:modified; use the identifier alone and treat any change in the manifest's item count or the spine length as a weaker edition signal.
Test: open a book, save a position, replace the file with a copy whose dcterms:modified differs, reopen; the reader must flag the position as from another edition rather than silently jumping.

**SWP-11 The parser shall keep every manifest item's id, href (raw and normalized), media-type, properties as a set of space-separated tokens, fallback and media-overlay attributes; shall index items by id and by normalized href; shall keep the first item on duplicate ids with a diagnostic; and shall keep items whose media-type is unknown.**
Why: Bookbinder and FolioReaderKit compare the properties attribute to a whole string, so "nav scripted" is not a nav document for them (verified: equality against "nav" and "cover-image"). EPUBKit keeps the last item on duplicate ids. FolioReaderKit and epubparser key resources by href, so duplicate hrefs collapse. EPUBKit maps media types into a closed enum with an unknown case, which loses the declared string for anything outside its fifteen cases (verified: the enum has fifteen named cases plus unknown).
Spec: EPUB 3.3 5.6.2 (item element), 5.6.2.1 (resource properties), appendix D.6 (manifest properties vocabulary: cover-image, nav, mathml, scripted, svg, remote-resources, switch).
Edge cases: an item element with whitespace before the equals sign in an attribute (legal XML; the 2007 Alice sample does this); an item with no media-type (OPF 2.0.1 and EPUB 3.3 both require it; keep the item with an empty type and a diagnostic rather than dropping it, since Bookbinder drops it and a dropped item can be the spine's only chapter); the NCX declared as text/xml (the 2007 Alice sample) or application/xml; fonts declared with any of the five font media types in the wild; an href with a fragment (illegal in the manifest; strip and diagnose).
Test: a manifest with two duplicate ids, one missing media-type, one unknown media-type and one multi-token properties value; assert the index contents and four diagnostics.

**SWP-12 The parser shall treat the declared media-type as the resource's type and shall use the file extension only as a tie-breaker to locate the NCX or nav document when no item declares the expected type.**
Why: FolioReaderKit's locate-the-TOC cascade (NCX media type, then .ncx extension, then nav property) is a lesson from real books where the NCX is declared with a wrong type; the 2007 Alice sample declares it as text/xml and EPUBKit still opens it only because EPUBKit follows the spine's toc attribute rather than the media type. Both heuristics are needed.
Spec: EPUB 3.3 3 (publication resources, core media types); 5.9.5 (NCX).
Edge cases: an .ncx file that is not in the manifest at all (ignore it; the spec requires manifest listing), an XHTML file named toc.xhtml with no nav property (do not guess; EPUB 2 books commonly have a toc.html chapter that is a spine item), a nav document declared as text/html.
Test: three variants of one book differing only in the NCX item's declared type must all yield the same TOC.

**SWP-13 The parser shall keep the spine as an ordered list of itemrefs with idref, id, linear (default yes) and properties, shall read page-progression-direction from the spine element's attribute (ltr, rtl, or default), shall keep the toc attribute, and shall skip an itemref whose idref matches no manifest item with a diagnostic.**
Why: EPUBKit reads page-progression-direction from a child element named like the attribute rather than from the attribute (verified at its spine parser's direction lookup), so every book is reported left-to-right; its spine tests assert only that some direction exists. FolioReaderKit reads the attribute correctly and uses it to mirror the collection view. EPUBKit keeps dangling itemrefs; FolioReaderKit drops them silently; both lose the information that a chapter is missing.
Spec: EPUB 3.3 5.7.1 (spine element, page-progression-direction), 5.7.2 (itemref element, linear and properties); OPF 2.0.1 2.4 (spine, linear).
Edge cases: linear="no" items (reachable by link, excluded from the page sequence and from progress totals), itemrefs pointing at non-XHTML items (SVG in spine is legal; an image in spine is not, keep with a diagnostic and render as an image), an empty spine (fail, SWP-30), the same idref twice (keep both; EPUBKit's edge-case test constructs this case directly on the model).
Test: a spine with rtl, one linear="no" item and one dangling idref; assert direction, the page sequence length, and the diagnostic.

### Navigation

**SWP-14 The parser shall prefer the EPUB 3 navigation document (the manifest item whose properties include nav), shall select the nav element whose epub:type includes "toc" rather than the first nav element in the body, shall also extract the page-list and landmarks nav elements when present, shall keep entries that the hidden attribute hides, and shall fall back to the NCX only for EPUB 2 books or when the nav document is absent or unparseable.**
Why: EPUBKit throws when the spine has no toc attribute, so an EPUB 3 book with a nav document and no NCX cannot be opened at all (verified: a missing toc id is a thrown error, and the test suite names this case as expected behaviour for a book whose NCX item is missing). FolioReaderKit prefers the NCX whenever one exists, even in EPUB 3, and when it does read a nav document it takes the first nav child of body or, through a recursive helper whose return value is discarded in the else branch, only a nav that is a grandchild of body (verified). Bookbinder never parses the nav document. Gutenberg's EPUB 3 builds ship both nav and NCX; Standard Ebooks ships both with landmarks; publisher EPUB 3 books increasingly ship nav only.
Spec: EPUB 3.3 7.4.2 (toc nav), 7.4.3 (page-list nav), 7.4.4 (landmarks nav), 7 (the hidden attribute on nav elements); 5.9.5 (NCX, legacy); OPF 2.0.1 2.4.1.
Edge cases: a nav document with several nav elements where toc is not first (landmarks first is common), a toc nav wrapped in div or section elements, a nav document that is also a spine item (common; keep it in the reading order), an li whose first child is a span rather than an a (a heading for a nested list; it has a label but no target, so it must be kept as a non-navigable node and its ol descended), an a with no href (treat as span), hidden="hidden" on the page-list nav (keep the data; do not show it in the TOC).
Test: the same book with (a) nav only, (b) NCX only, (c) both with differing depth; assert (a) opens, (b) opens, and (c) uses the nav tree.

**SWP-15 The NCX parser shall walk navMap and navPoint recursively to any depth, read the first navLabel's text and the content element's src, treat playOrder and id as optional, and shall also read pageList and navList when present; a navPoint that lacks a label or a src is kept as a diagnostic entry, never a crash.**
Why: EPUBKit force-unwraps the id attribute and the src attribute of every navPoint (verified at its nav point mapping), so an NCX missing either crashes the app; its TOC parser also looks up the book identifier with the name "dtb=uid" (verified), a typo for "dtb:uid" that never matches. Bookbinder drops any navPoint whose playOrder is missing or not an integer (verified), and OPF 2.0.1 2.4.1.2 makes playOrder optional in EPUB; Gutenberg's EPUB 3 NCX files do carry playOrder, but calibre and many conversion tools omit it. FolioReaderKit's flattening keeps only two levels (verified: the flattener appends top-level items and their direct children, not grandchildren), so a part/chapter/section TOC loses the sections in the chapter list.
Spec: OPF 2.0.1 2.4.1.2 (key NCX requirements), 2.4.2 (NCX exceptions); Z39.86-2005 section 8.
Edge cases: navLabel with several text children in different languages (take the first; keep the rest), src with a fragment, src percent-encoded, a navPoint whose src points outside the spine (keep; mark unresolvable), depth greater than three (EPUBKit's edge-case test constructs ten levels on the model but never parses such a file), docTitle absent.
Test: an NCX with no playOrder, no ids, five levels of nesting and one src with a fragment; assert the tree shape and that nothing crashes.

**SWP-16 Every navigation entry shall be resolved at parse time to a spine index plus an optional fragment, with the original href preserved; entries whose target is not a spine item shall be kept and marked unresolvable rather than dropped.**
Why: FolioReaderKit resolves TOC entries to resources by raw href after stripping every "../" (verified), which maps a nav href of "../text/ch1.xhtml" to "text/ch1.xhtml" only by accident, and leaves the resource nil when the href is percent-encoded differently from the manifest. Its chapter list then silently does nothing for unresolved entries (verified: the center prints a failure message when the resource index is out of range).
Spec: EPUB 3.3 7.4.2 (toc nav: links must reference spine or resource content), 4.2.5.
Edge cases: a TOC entry pointing at a non-linear spine item, at a resource that is in the manifest but not the spine (legal for the nav document; show it but do not count it toward progress), at the nav document itself.
Test: assert that every entry in the Gutenberg nav of pg20512-images.epub resolves to a spine index, and that a deliberately broken entry survives as unresolvable.

**SWP-17 Cover detection shall try, in order: a manifest item whose properties include cover-image; an EPUB 2 meta element named cover whose content is a manifest id; the same meta whose content matches a manifest href or file name instead of an id; the guide reference of type cover resolved to its XHTML page's first image; and finally the first bitmap or SVG manifest item whose id or href contains "cover". A book with no cover shall open normally.**
Why: EPUBKit implements only the EPUB 2 meta, resolved by id (verified). Bookbinder implements the property and the meta and returns both, so its own test expects the same URL twice. FolioReaderKit tries the meta first and then the property. None handles the meta whose content is a file name, which older conversion tools produced, or the guide reference, which Gutenberg's EPUB 2 builds use (their guide has a cover reference to a wrap page). The reader needs the cover only for Now Playing artwork during read-aloud and for a library tile, so a wrong guess is cheap and a missing cover is fine.
Spec: EPUB 3.3 appendix D.6.1 (cover-image), 5.9.3 (legacy meta), 5.9.4 (guide element); OPF 2.0.1 2.6 (guide).
Edge cases: the cover-image property on a non-image item (ignore), a meta cover content that names an XHTML page rather than an image (resolve through its first image), two items with the property (first in manifest order).
Test: five single-feature books, one per rule, plus one with none; assert the chosen href or nil.

**SWP-18 The parser shall read EPUB 2 guide references (type, title, href) and expose them as landmarks when no landmarks nav exists, and the reader shall use a reference of type text, or an EPUB 3 landmark of type bodymatter, as the start-of-reading hint for a book opened for the first time.**
Why: none of the four parsers reads the guide; Bookbinder's README shows callers how to do it with their own XPath, and its test counts six references on the Standard Ebooks Alice. Gutenberg EPUB 2 builds carry guide references for the cover and the TOC page. Opening at the first spine item puts the reader on a cover wrapper page, which under VoiceOver is an image with no text.
Spec: EPUB 3.3 5.9.4 (guide, legacy); OPF 2.0.1 2.6; EPUB 3.3 7.4.4 (landmarks).
Edge cases: guide types with the Standard Ebooks compound form (for example "title-page text"), references with a fragment, a guide with no text reference (open at the first linear item).
Test: a book with a cover page first in the spine and a guide text reference to chapter 1 must open at chapter 1 the first time and at the saved position every later time.

**SWP-19 The parser shall percent-decode every href and src it reads (manifest, nav, NCX, SMIL, content links), normalize "." and ".." segments, strip query and fragment into separate fields, and match against ZIP entry names by exact bytes of the normalized path; it shall never decode "+" as a space.**
Why: EPUBKit appends the raw href to a directory URL, so a manifest href containing %20 produces a path with a literal percent sequence and the file is not found (verified: no decoding anywhere in its path handling). Bookbinder does the same. FolioReaderKit and epubparser decode the absolute path but key the resource table by the raw href, so a nav link that is encoded differently misses. EPUBKit's edge-case test for "various path formats" builds model values with spaces and "../" and asserts they are stored unchanged; it never parses a file with such paths.
Spec: EPUB 3.3 4.2.5 (URLs), 4.2.3 (file names); RFC 3986 section 5.2.4 (remove dot segments).
Edge cases: a space encoded as %20 in the href and stored unencoded in the ZIP (the normal case); a literal space in the href (illegal but seen; accept); non-ASCII file names encoded as UTF-8 percent sequences in the href and as UTF-8 bytes in the ZIP; precomposed versus decomposed Unicode in the name (compare after NFC normalization, diagnostic when only the other form matches); an href that is already decoded and contains a literal "%".
Test: a book whose chapter files are named with a space, an accented letter, and a plus sign, referenced from the manifest, the nav and an internal link; all three must resolve.

### Media overlays

**SWP-20 The parser shall read each SMIL media overlay document named by a manifest item's media-overlay attribute into a tree of seq and par nodes, where a seq carries an optional epub:type set and an optional epub:textref, and a par carries an optional epub:type set, one text node (src resolved to a spine index plus fragment) and an optional audio node (src resolved to a resource, clipBegin, clipEnd); clock values shall be parsed with the full grammar: full clock values (hours:minutes:seconds with optional fraction), partial clock values (minutes:seconds with optional fraction), and timecount values (a number with optional fraction and an optional unit of h, min, s or ms, defaulting to seconds). A missing clipBegin means zero and a missing clipEnd means the end of the audio resource. The parser shall also read media:duration (total, and per overlay through refines), media:narrator, media:active-class and media:playback-active-class.**
Why: FolioReaderKit's SMIL tree is generic and adequate. Its clock-value conversion is not: it matches five regular expressions and then runs the string through a date formatter, so it rejects a timecount with more than two integer digits before the fraction, rejects the "s" unit entirely, rejects more than three fraction digits, and returns zero for anything it cannot parse (verified in the string extension that converts clock times). Zero is the worst possible failure value because it silently restarts the chapter's audio. Its sample media-overlay book (a LibriVox Sherlock Holmes chapter) uses full clock values with three-digit fractions throughout, 1,181 par elements under one seq with epub:type "bodymatter chapter", one 27.6 MB MP3 for the chapter, SMIL files kept in a separate folder with "../" references, and the package declares both a total and a per-overlay media:duration plus a custom media:active-class; that is the realistic shape to test against.
Spec: EPUB 3.3 9.2.2.1 (smil), 9.2.2.4 (body), 9.2.2.5 (seq), 9.2.2.6 (par), 9.2.2.7 (text), 9.2.2.8 (audio); appendix H.4 (clock values); appendix D.8.1 (active-class), D.8.2 (duration), D.8.4 (playback-active-class); 5.6.2 (media-overlay attribute on item).
Edge cases: a par with text but no audio (a silent par, legal; the player shows the highlight for a default dwell or skips it), audio src pointing at a resource not in the manifest, clipEnd before clipBegin (diagnostic; treat as zero-length), a seq with epub:textref but no pars, clock values with leading or trailing whitespace.
Test: a table-driven clock-value test covering every production in H.4 (see section 9, V10), and a parse of a hand-built SMIL with nested seq elements.

**SWP-21 Overlay playback shall be driven by the audio player's clock through boundary observers or an explicitly computed next-clip-end deadline, never by a repeating timer polling the current time; on reaching a clip's end the player shall advance to the next par in document order, descending into seq nodes, continue into the next spine item that has an overlay when a SMIL file ends, mark the active text fragment with the playback-active class, scroll it into view, and turn pages or chapters as needed; the user shall be able to skip structures whose epub:type is in the skippable set and escape the current seq.**
Why: FolioReaderKit schedules a 10 ms repeating timer on the main run loop while audio plays and compares the player's current time to the clip end on every tick (verified: the timer interval is 0.01 seconds, added in common modes); it loads each audio file fully into memory with a data initializer (verified) rather than streaming from disk; it finds the next par by a linear scan from the start of the file's tree each time; it suppresses highlight-driven page changes for two seconds after any user scroll; and it has no skippability or escapability. Those are the parts to replace. The parts to keep are: the audio session category is playback, Now Playing shows cover art, chapter title, book title and author, remote commands map previous and next track to previous and next chapter, and an interruption notification pauses playback.
Spec: EPUB 3.3 9.4.1 (skippability), 9.4.2 (escapability); 9.3 (packaging and the active classes).
Edge cases: an overlay whose audio is split across several files within one chapter (change the player item without a gap), the user tapping a word that is inside a par (start from that par: FolioReaderKit finds the nearest ancestor with an id from the selection, otherwise the first id-bearing span in the viewport), the user tapping play with no selection (start at the first par whose text is on the visible page), a chapter with no overlay between two that have one (FolioReaderKit waits one second and auto-advances; the merged spec should advance immediately with an announcement), background playback and lock-screen scrubbing.
Test: with the LibriVox-shaped vector, assert that the highlight moves exactly 1,181 times over the chapter, that no timer is scheduled (instrument the run loop), and that memory does not grow by the audio file's size.

### Read-aloud

**SWP-22 Read-aloud shall segment the current spine item's text into sentences using the text model and a natural-language tokenizer, speak one utterance per sentence with AVSpeechSynthesizer, select the voice from the publication's dc:language (falling back to the system voice), expose the four rates FolioReaderKit used as named presets, highlight the sentence being spoken as a range in the rendered text, keep the highlighted sentence in view, continue across page and chapter boundaries in spine order, and pause, resume and stop without losing the current sentence.**
Why: FolioReaderKit's sentence segmentation rewrites each paragraph's innerHTML with a regular-expression sentence splitter that wraps spans around guessed sentences, only looks at p elements, carries a safety counter of 100 iterations per paragraph, and has to be undone before highlights are stored (verified in the bridge script and in the highlight model's span-stripping helper). Sentence selection then scans the sentence spans for the first one whose offset is at or below the current scroll position and advances an index; crossing a page boundary is detected only when the script returns nothing, at which point the controller turns the page and starts again from the first visible sentence, which can skip or repeat a sentence at the boundary. Rates: 0.42, 0.5, 0.53, 0.56 as AVSpeechUtterance rates for the four menu steps (verified), paired with 0.5x, 1x, 1.5x, 2x for audio; the utterance rates are not proportional to the labels. Voice: the language code from the package, with the parser's default of "en-US" when the book declares none or declares exactly "en" (the bug in SWP-09). The synthesizer delegate's did-finish callback speaks the next sentence while the play flag is set; did-cancel calls a completion handler.
Spec: none in EPUB; see EPUB 3.3 9 for how overlays take precedence when present (FolioReaderKit disables read-aloud when the book has any overlay, which is the right default).
Edge cases: headings and list items (sentences in their own right), block quotes, poetry lines (Gutenberg has many; treat a line break inside a poem as a sentence boundary), abbreviations ("Mr." must not split), a sentence that spans a page boundary in paginated layout (highlight both parts; turn the page when the spoken range leaves the visible page), language changes inside the book (xml:lang on an element selects a voice for that range), VoiceOver running (see SWP-33).
Test: a chapter with known sentence count must produce that many utterances; pausing mid-sentence and resuming must not repeat the previous sentence; turning the page while speaking must not change the spoken sentence.

### Highlights, bookmarks and position

**SWP-23 A highlight shall be identified by a locator that is stable under reflow: the spine index plus a CFI or a character offset into the spine item's normalized text, plus a text-quote selector (exact text, up to 32 characters of prefix and suffix); it shall carry a style, an optional note, a creation date and the release identifier; it shall be rendered as attribute ranges in the text storage and restored after any font or layout change by re-resolving the locator, never by editing the document markup.**
Why: FolioReaderKit's highlight record stores the highlighted HTML, 30 characters of HTML before and after (verified: the context constant is 30), the chapter number, two DOM offsets it never uses to restore, a style, a note and a date, keyed by a generated UUID. Restoring works by concatenating prefix, text and suffix, stripping the sentence spans the read-aloud feature injected, searching the chapter's HTML for the literal string and splicing a custom element around the match; when the context is ambiguous the first match wins, when the markup changed the highlight is lost with a console message. Its highlight list navigates by chapter number and then scrolls to the element id. The two SwiftUI readers delegate highlights to Readium's decorations and locators. The W3C Web Annotation text-quote selector with a position fallback is the standard shape for exactly this problem.
Spec: EPUB CFI (step reference, character offset, text location assertion); W3C Web Annotation Data Model, TextQuoteSelector and TextPositionSelector.
Edge cases: a highlight across element boundaries (store start and end locators; render as several ranges), overlapping highlights, a highlight in a non-linear item, the same quote appearing twice in a chapter (the position selector breaks the tie), a highlight whose text no longer exists after an edition change (keep it in the list as orphaned, flagged).
Test: create a highlight, change the font size twice, rotate, reopen the book; the highlight must cover the same characters each time (assert on the text, not the frame).

**SWP-24 A bookmark shall be a locator plus a creation date, a chapter title derived from the TOC entry that contains the locator, and a text preview of the first sentence at the locator; bookmarks shall be listed in reading order by comparing locators, and the reader shall indicate when the current page contains a bookmark.**
Why: FolioReaderKit has no bookmarks (its "saved position" is one implicit bookmark per book). EPUBReaderSwiftUI's bookmark shape (locator, date, chapter title, about 120 characters of preview) and its current-page match by href and progression are the only concrete model among the candidates and are sound. EbookReader has none.
Spec: EPUB CFI sorting rules (bracketed assertions are ignored when sorting).
Edge cases: two bookmarks on one page, a bookmark in a chapter removed by an edition change, bookmark on an image-only page (preview from the image's alt text or the chapter title).
Test: three bookmarks in reverse creation order must list in reading order; the indicator must be on only while the page containing the locator is visible.

**SWP-25 The reading position shall be stored as a locator (spine index, href, a CFI or character offset to the first visible character, and the progression within the spine item), with the release identifier and a format version; it shall be restored by resolving the locator against the current layout, and on a font-size, margin, orientation or layout-mode change the reader shall keep the first visible character in view rather than a scroll offset or a page number.**
Why: FolioReaderKit saves the chapter number and the web view's content offset in points (verified: the saved dictionary has three keys, page number, x offset, y offset) and restores by scrolling to that offset after the chapter loads, so a font-size change, a rotation, a different device or a changed stylesheet lands the reader somewhere else; it saves on resign-active, terminate, opening the chapter list, and close. Its rotation and layout-direction changes keep a ratio of offset to content size, snap it to a page boundary in horizontal mode and re-apply it after a 100 to 200 ms delay (verified), which is a crude but real within-chapter fallback when no locator can be resolved. EbookReader stores one scroll offset per chapter plus the current chapter index in UserDefaults. Funston already stores a Readium Locator JSON string and saves it one second after the last change and when entering the background; the merged spec keeps that cadence and replaces the payload.
Spec: EPUB CFI (intra-publication CFIs, step reference, character offset); Readium Locator model (https://readium.org/architecture/models/locators/) for the format currently in book_positions.
Edge cases: a locator into a spine item that no longer exists (fall back to the progression across the book), a position at the very end of a chapter (restore at the end, not the start of the next), a position saved in paginated layout and restored in continuous layout under VoiceOver (the character must be the first visible one in either), a position saved before the book was ever laid out (opening and leaving within a second).
Test: save at a known sentence, change the text size through three Dynamic Type steps, reopen; the first visible sentence must be the same one each time.

**SWP-26 The reader shall estimate reading time from a word count over each spine item's text model computed once and cached, with the words-per-minute constant a named token (FolioReaderKit's observed value is 180 words per minute), and shall show time left in the chapter and in the book; the per-chapter count shall be derived from the text model, not from a layout pass.**
Why: FolioReaderKit's bridge script counts whitespace-separated tokens in the body's inner text and divides by 180 words per minute (verified: the constant is declared in the bridge and the estimate rounds to whole minutes), then the page indicator shows pages left in the chapter and minutes left as pages remaining times chapter minutes divided by chapter pages. It has no book-level estimate because each chapter's count is only known once that chapter's web view has loaded. Under VoiceOver this estimate is more useful than page counts, which change with every font change.
Spec: none.
Edge cases: chapters that are all images, non-linear items (exclude), languages without whitespace word boundaries (count with the natural-language tokenizer), front matter (counted but small).
Test: a chapter of 1,800 words must report 10 minutes at the default constant; the book total must equal the sum of linear chapters.

### Presentation

**SWP-27 Text size shall follow Dynamic Type through a body text style scaled from a named base size, margins shall follow the readable content guide, the theme shall follow the system appearance with an optional in-app override, publisher styles shall be reducible to a safe subset, and line length, alignment and hyphenation shall be named tokens; a fixed ladder of pixel sizes and bundled fonts is not required.**
Why: FolioReaderKit's fonts menu offers four bundled typefaces loaded at launch, five sizes (13, 15, 17, 19 and 21 CSS pixels, verified in its stylesheet), a day-or-night switch, and a vertical-or-horizontal switch, all persisted in UserDefaults; night mode sets a near-black background and mid-grey text through injected classes and a stylesheet that overrides publisher colours with important rules, plus an extra view that covers the gap after the last page in paginated mode (verified). Its stylesheet also resets margins, forces line height, breaks long words in headings, hides footnote asides, caps images at the viewport and hyphenates on phones only. Those are reasonable defaults for a web engine. Funston's existing Readium preferences already express the house policy: Dynamic Type for size, system appearance for colours, publisher styles off, leading alignment because justified text opens gaps that are hard to track with low vision, and continuous scrolling under VoiceOver. The merged spec should carry those forward rather than FolioReaderKit's menu.
Spec: none (EPUB 3.3 6.1 and the EPUB Reading Systems requirements allow user overrides of author styles).
Edge cases: books whose stylesheet sets colours only on body (night mode must not produce black on black), preformatted text that must not wrap, tables wider than the screen, drop caps implemented with floats.
Test: verify at the smallest and largest accessibility text sizes that no line is clipped, and that a book with a white-on-white publisher style is readable under both appearances.

**SWP-28 The reader shall honour page-progression-direction for paging gestures and page order, shall lay out right-to-left scripts with the text system's bidirectional algorithm, and shall detect vertical writing (a writing-mode of vertical-rl or vertical-lr in the publication's stylesheets, or the spine direction with a Japanese language tag) and either lay the text out vertically or fall back to horizontal with a visible diagnostic; it shall never mirror a horizontal layout to fake right-to-left.**
Why: FolioReaderKit's RTL support is a horizontal flip of the collection view with a mirror transform, each cell flipped back, applied only when the spine says rtl and the layout is horizontal (verified); it has no vertical writing support and relies on WebKit for bidirectional text. The flip works for page order and breaks any chrome drawn inside the flipped view. Gutenberg's corpus is overwhelmingly left-to-right, so this is low priority but must not be done the wrong way.
Spec: EPUB 3.3 5.7.1 (page-progression-direction); 6.1 (XHTML, CSS writing modes).
Edge cases: rtl spine with ltr text (Hebrew book with English front matter), ltr spine with rtl paragraphs, mixed-direction lines.
Test: an rtl book must page right-to-left with the page indicator and the adjustable page element counting the same way; a Japanese vertical book must either render vertically or show the diagnostic, never a mirrored horizontal page.

**SWP-29 Internal links shall resolve relative to the current content document: a same-document fragment scrolls to the element with that id (or name), a link to another spine item navigates there and then to the fragment, a link to a manifest resource that is not in the spine opens it in place (an image or a non-linear page), and external http or https links open in an in-app Safari view; mailto and other schemes go to the system.**
Why: FolioReaderKit intercepts every navigation in the web view delegate, parses its own custom schemes, and for file URLs splits the path on the package directory name to recover the href, compares the resolved page number with the current one, and either scrolls to the anchor or changes chapter (verified). Its anchor scrolling asks the page for the element's offset and, in horizontal mode, computes the page from the offset divided by the viewport height. The split-on-directory-name trick fails when a chapter folder name repeats inside the path. The behaviour to keep is the dispatch table; the mechanism must be the resolved href from SWP-19.
Spec: EPUB 3.3 6.1 (XHTML), 4.2.5 (URLs); EPUB Reading Systems requirements on hyperlink handling.
Edge cases: a link whose fragment does not exist (navigate to the document start, diagnostic), a footnote link with epub:type noteref to an aside that the stylesheet hides (show the note in a popover rather than navigating; FolioReaderKit hides footnote asides entirely), a link with a query string, a link to the cover image.
Test: a chapter with six link kinds; each must produce the expected navigation and VoiceOver must announce the destination's first element.

### Robustness and structure

**SWP-30 Opening shall fail only for: not a ZIP, no container.xml, no usable rootfile, package document missing or not well-formed, or an empty spine; every other defect (missing or broken navigation, missing cover, unresolvable items, bad SMIL, wrong media types) shall degrade with a diagnostic; failures shall be typed errors that distinguish these causes, and no parsing path shall assert, force-unwrap decoded input, or crash.**
Why: EPUBKit has four error cases and lets XML and file errors from its dependencies escape untyped (verified); it crashes on an NCX navPoint without id or src (SWP-15). Bookbinder returns nil for everything and prints. FolioReaderKit has eight error cases but fails with a precondition when no TOC resource exists (verified: a precondition with a message about the missing table of contents) and prints when a SMIL or TOC file cannot be read. epubparser keeps the precondition and force-unwraps the UTF-8 decoding of every spine document while building its combined HTML (verified). Funston's current controller already maps two failure classes to user-facing text ("not a book this app can read", "looks damaged"); the typed errors must map onto those plus a retry path.
Spec: EPUB 3.3 4.2.6.3.1, 5.4; EPUB Reading Systems conformance (reading systems must not fail on unknown content).
Edge cases: a package document encoded in UTF-16 with a BOM, a package with an XML declaration naming an encoding that is wrong, an XHTML chapter that is not well-formed (render what parsed up to the error with a visible marker, since Gutenberg's older builds occasionally have stray ampersands), a container that names a rootfile that is a directory.
Test: EPUBKit's four broken fixtures are the right shapes to rebuild as our own vectors (section 9, V4 to V7); assert the error case for each and that none of the degradable defects throws.

**SWP-31 Parsing shall run off the main actor as a pure function from the archive to an immutable, Sendable publication value (structs and enums, no implicitly unwrapped optionals, no NSObject models); resource bytes shall be read lazily through a Sendable archive reader so that a chapter is decompressed when first displayed; the parse shall be cancellable.**
Why: all three older parsers are NSObject subclasses with mutable state and implicitly unwrapped optionals (FolioReaderKit's resource has implicitly unwrapped id, media type, href and full path), designed to be driven once on a background queue and then read from the main thread. EPUBKit's models are structs but its README's "thread safe" and "designed for concurrent parsing operations" claims are not backed by any Sendable conformance or isolation annotation in the package (verified: no concurrency annotations, no strict-concurrency setting in the manifest); the claim is only that separate parser instances do not share state. Funston builds with Swift 6 strict concurrency.
Spec: none.
Edge cases: cancellation mid-parse while a large SMIL tree is being built, a publication value referenced from the reader after the archive file was removed under it (the lease in the current controller handles this; the reader must surface a resource-missing diagnostic rather than crash).
Test: parse on a background task, cancel at 50 ms, assert no partial model escapes; parse the same book from two tasks concurrently and assert equal results.

**SWP-32 Every lenient decision the parser makes shall be recorded as a structured diagnostic on the publication value (kind, location, message), never printed; the reader shall surface the ones that affect the user (no navigation, missing chapter, could not read audio) and log the rest.**
Why: FolioReaderKit and epubparser print to the console on TOC, SMIL and audio failures; Bookbinder prints parse failures and returns nil; EPUBKit has no diagnostics at all. The house rule for Camden's projects is that a render path fails loud into a diagnostic rather than blank or silent.
Spec: none.
Test: parse the 2007 Alice shape (SWP-06, SWP-11) and assert diagnostics for the dc-metadata wrapper and the text/xml NCX type, and that the book still opens with a title.

### Accessibility

**SWP-33 The renderer shall expose each block of text (paragraph, heading, list item, table cell, image with its alternative text) as one VoiceOver element whose frame is computed from the live TextKit 2 layout at query time, in reading order, with headings carrying the header trait and links the link trait; the reading page shall keep the existing adjustable page element for turning pages under VoiceOver; read-aloud and overlay playback shall be exposed as play and pause custom actions and shall not start speaking while VoiceOver is running unless the user chooses to; and the chrome shall use native controls with labels.**
Why: no candidate does any of this. FolioReaderKit's content accessibility is whatever UIWebView exposes, its menus are image-only buttons with no accessibility labels (verified across the fonts and player menus), and its active-sentence highlight is visual only. Funston's PDF reader already defines the house style: one accessibility element per recognized line, frames converted from the page at query time so zoom and scroll never go stale, focus moving the scroll view without re-fitting, a page element with the adjustable trait whose increment and decrement turn pages, Magic Tap toggling the controls, and a layout-changed notification when the visible set changes. The EPUB renderer must match it, with the block as the unit rather than the line, because a reflowed paragraph is one thought and VoiceOver users read by paragraph.
Spec: none in EPUB; EPUB Accessibility 1.1 for content expectations.
Edge cases: a paragraph that spans two pages in paginated mode (the element belongs to the page where it starts, with its frame clipped to the visible part), off-screen blocks (not exposed; the PDF reader keeps elements only for visible pages), a heading inside a link, images without alt text (expose the file name as a last resort, flagged), tables (row and column announcements are a later requirement).
Test: under VoiceOver on the simulator, swipe through a chapter and assert that every block is reached once, in order, that no element announces over empty space, and that paging with the adjustable element announces the page.

## Algorithms

### Opening a book

1. Open the archive, read the central directory, build a map from normalized entry path to entry record. Reject or flag entries per SWP-02.
2. Read "mimetype" if present; record diagnostics per SWP-03.
3. Read "META-INF/container.xml"; select the rootfile per SWP-04; resolve its full-path against the container root; the package directory is its parent.
4. Read and parse the package document per SWP-06 to SWP-13. Produce manifest, spine, metadata, diagnostics.
5. Locate navigation: the manifest item with the nav property if the package version is 3 or higher, else the spine toc attribute's item, else any item with the NCX media type, else any item whose href ends in ".ncx". Parse per SWP-14 to SWP-16. If the nav document fails to parse and an NCX exists, use the NCX and record a diagnostic.
6. Locate the cover per SWP-17 and landmarks per SWP-18.
7. For each manifest item with a media-overlay attribute, parse the SMIL per SWP-20 lazily, on first play, not at open.
8. Return the publication value. No content document has been read yet.

Observed costs for scale (byte sizes from the clones' directory listings): EPUBKit's four fixtures range from 0.2 MB to 1.1 MB; FolioReaderKit's Sherlock sample is a 27.5 MB archive whose single MP3 is 27.6 MB uncompressed, and its Silver Chair sample is 0.2 MB. A Gutenberg "images" EPUB is typically 1 to 5 MB. Full extraction of the Sherlock sample means a 27.6 MB write and, in FolioReaderKit's player, a 27.6 MB in-memory audio buffer.

### Href normalization

Given a reference string and the path of the document that contains it:

1. Split off the fragment at the first "#" and the query at the first "?" before it.
2. Percent-decode the remaining path as UTF-8; on an invalid sequence keep the raw bytes and record a diagnostic.
3. If the path is absolute (starts with "/"), strip the slash and record a diagnostic; EPUB hrefs are relative.
4. Join with the containing document's directory and remove dot segments per RFC 3986 5.2.4; a ".." that would climb above the container root stops at the root with a diagnostic.
5. Normalize to NFC. Look up the entry by exact match; if that fails, try the NFD form and record a diagnostic on success.
6. Keep the original string on the resolved reference for display and for re-serialization of locators.

### Navigation document extraction

1. Parse the nav document as XHTML (SWP-07). Find every nav element anywhere in the body, not only direct children.
2. Classify each by the tokens of its epub:type attribute: toc, page-list, landmarks, or other (keep others under their type name).
3. For the toc nav, take its first ol child. For each li in order: the label is the text content of the first a or span child (whitespace collapsed); the target is the a's href resolved per SWP-05 and SWP-19, or nil for a span; the children are the entries of the li's first ol child, recursively. An li with neither a nor span but with an ol is a heading-less group; keep it with an empty label and a diagnostic.
4. Resolve each target to a spine index per SWP-16. The nav document's own hidden attribute and hidden attributes on ol elements are recorded on the entries, not acted on by the parser.
5. The page-list nav yields a flat list of (label, target) used for "go to page" and for announcing print page breaks; the landmarks nav yields (type, label, target).

### NCX extraction

1. Parse the NCX as XML. Find the navMap. For each navPoint child in document order: label is the text of the first navLabel's text child; target is the content element's src, resolved against the NCX's own path; playOrder, id and class are optional and kept when present; children are nested navPoint elements, recursively, any depth.
2. pageList yields pageTarget entries (type front, normal or special; value; label; src). navList elements yield named lists.
3. docTitle and docAuthor are informative only; the package metadata wins.

### Cover detection

In order, stop at the first hit: an item whose property set contains cover-image and whose media type is an image; a meta with name "cover" whose content equals an item id, then whose content equals an item href or its last path component; a guide reference of type "cover" or a landmark of type "cover", resolved to its document, parsed, and its first img or svg image child resolved; the first image item whose id or href, lowercased, contains "cover". Record which rule fired.

### Clock values

Parse after trimming whitespace, in this order; the first grammar that matches the whole string wins:

| Form | Shape | Example in words | Seconds |
| --- | --- | --- | --- |
| Full clock | hours, colon, two-digit minutes, colon, two-digit seconds, optional dot fraction | one hour two minutes and three and a half seconds | h*3600 + m*60 + s.f |
| Partial clock | minutes, colon, two-digit seconds, optional dot fraction | four minutes eighteen seconds | m*60 + s.f |
| Timecount | digits, optional dot fraction, optional unit h, min, s or ms | ninety seconds written as a bare number, or as a number with the s unit, or 1.5min | value scaled by the unit, seconds by default |

Any other string is a parse failure, not zero: the par keeps a nil clip bound and a diagnostic, and the player treats a nil clipBegin as the previous clip's end and a nil clipEnd as the next clip's begin, so one bad value cannot restart the chapter. Hours and minutes in clock values may exceed two digits in the hours field only; fractions may have any number of digits.

### Overlay playback

State: the current spine index, the current SMIL tree, the index of the current par in a pre-flattened array of pars (document order, each with its ancestor seq chain for skippability), the audio resource in the player, and the deadline.

1. Start: choose the first par whose text target is at or after the requested position (a tapped fragment, or the first block visible on the page). Flatten the SMIL tree once per file.
2. Play par: if the audio resource differs from the loaded one, load it from the archive reader (streamed to a temporary file if the player cannot read from memory, or an in-ZIP stream) and keep it loaded while consecutive pars use it. Seek to clipBegin only if the player's time is outside [clipBegin, clipEnd); FolioReaderKit does this comparison and it avoids a seek between contiguous clips. Install a boundary observer at clipEnd. Apply the playback-active class to the text target: in Funston's model, add a temporary attribute range over the target element's text and scroll it into view; post a layout-changed notification if VoiceOver is running.
3. On the boundary: remove the active range; advance to the next par; if the next par's ancestor seq is skippable and skipping is on, keep advancing; if none remains, find the next spine item with an overlay and go to step 1 with its first par, turning the chapter; if there is none, stop and announce the end.
4. On user navigation during playback: FolioReaderKit suppresses highlight-driven page turns for two seconds after a user scroll. The merged spec should instead keep playing and stop following until the user returns to the playing page or taps the "return to playback" control.
5. Pause and resume keep the par index; stop clears the active range. Interruptions pause. Remote commands: play, pause, toggle, previous chapter, next chapter. Now Playing: cover art, chapter title from the TOC entry that contains the current spine index (FolioReaderKit searches the flattened TOC for an entry whose resource matches the current spine item), book title, first creator, duration and elapsed time from the player.

### Read-aloud loop

1. Build the sentence list for the current spine item from the text model with the natural-language sentence tokenizer, as ranges into the attributed string, excluding ranges inside elements that are hidden or decorative (page-break spans, footnote markers).
2. Choose the start sentence: the one containing the selection if any, else the first whose range begins on the visible page.
3. Speak: one utterance per sentence, with the voice from the sentence's language (element xml:lang, else dc:language, else the system default) and the rate preset. On will-speak-range, move a highlight attribute over the spoken range and keep it in view. On did-finish, if still playing, advance to the next sentence; at the end of the list, load the next linear spine item, build its sentence list, and continue from its first sentence without a pause. On did-cancel after a pause request, keep the index so resume speaks the same sentence from its start (FolioReaderKit resumes mid-utterance with the synthesizer's continue call; either is acceptable, but the index must survive).
4. The four rate presets are tokens; FolioReaderKit's values (0.42, 0.5, 0.53, 0.56) are the observed starting point, not a requirement.

### Highlight anchoring and re-anchoring

Create: from the selection, take the spine index, the character range in the normalized text model, and build the quote selector (exact text; up to 32 characters before and after, taken from the text model, not the markup). Store both. Resolve: given the current text model for the spine item, if the position range's text equals the exact quote, use it; otherwise search for the exact quote and pick the occurrence whose prefix and suffix match best, then the occurrence nearest the stored position; if none, mark the highlight orphaned. Render: apply a background or underline attribute over the resolved range; VoiceOver exposes the highlighted block with a "highlighted" value and a custom action to open the note.

### Position restore across layout changes

On any layout change (font size, margins, orientation, paginated versus continuous): before relayout, capture the locator of the first visible character (block index and character offset within the block); after relayout, scroll so that character is at the top of the visible area (continuous) or on the current page (paginated). Only if no character is visible (image-only page) fall back to the ratio of content offset to content size within the spine item, which is what FolioReaderKit does for every case.

### Reading time

Per spine item, once: tokenize the text model into words with the natural-language tokenizer; cache the count keyed by release identifier and spine index. Chapter minutes left = words after the first visible character divided by the words-per-minute token. Book minutes left = the chapter's remainder plus the sum of the remaining linear chapters' counts.

### Page progression and layout direction

Paging direction comes from the spine attribute. In paginated mode the "next page" gesture and the adjustable element's increment both advance in reading order regardless of which screen edge that is. In continuous mode the direction only affects which chapter comes next. Vertical writing is detected by scanning the publication's stylesheets for a writing-mode declaration on html or body; detection yields a flag on the publication, and the renderer decides.

## Data model and persistence

### Publication value (design input)

The merged spec should define a value tree along these lines; the names are suggestions, not candidate names.

- Publication: version, packagePath, uniqueIdentifier, releaseIdentifier, metadata, manifest, spine, navigation, cover, landmarks, overlays (by spine index, lazily parsed), layoutHints (page progression, vertical writing flag, primary language), diagnostics.
- Metadata: titles (text, type, displaySeq, language), creators and contributors (name, fileAs, roles, language), identifiers (text, scheme, id), languages, dates (text, event), publishers, descriptions, subjects, rights, sources, modified, raw meta records.
- Manifest item: id, href (raw), path (normalized), mediaType (string), properties (set), fallback, mediaOverlay.
- Spine entry: index, itemID, linear, properties, pageSpread.
- Navigation: toc (tree of entries: label, target as spine index plus fragment or nil, hidden, children), pageList, landmarks, plus the raw type for other nav kinds.
- Navigation target resolution is done at parse time; unresolved entries carry the raw href and a flag.
- Overlay: flattened pars (text target, audio resource, clipBegin, clipEnd, skippable types), total duration, active and playback-active class names, narrator.

By comparison, EPUBKit's document holds two directory URLs and four structs with mostly optional scalar fields and a single creator; Bookbinder exposes the raw XML documents next to its structs; FolioReaderKit's book holds mutable NSObject models with a resources table keyed by href and a flat TOC two levels deep.

### Locator

A locator is the unit for positions, highlights and bookmarks: spine index, href (for diagnostics and migration), a CFI string when one can be produced, a character offset into the spine item's normalized text model, a progression within the spine item (0 to 1), a total progression across linear items, and a short text context (before, highlight, after). A format version field is mandatory so the stored JSON can evolve.

### Relation to book_positions

Funston's table has identifier, file_name, locator TEXT, updated_at REAL, primary key on identifier and file_name (migration 4 in SQLiteStore). Today the locator column holds a Readium Locator JSON string. The Readium model allows href, type, title, locations (fragments, progression, position, totalProgression, cssSelector, partialCfi) and a text block (before, highlight, after), but the sibling navigator and streamer studies found by reading that the navigator writes only href, type, title, progression, totalProgression and position, occasionally fragments, never partialCfi or the text block; position and totalProgression follow Readium's convention of 1,024-byte slices of each spine item's archive entry, so they must not be reinterpreted as pages. The current controller writes the row one second after the last location change and on entering the background. The merged spec should keep the table and the cadence, write the new locator JSON with a version field into the same column, and read a row without a version field as a Readium locator: its href and locations.progression are enough to resolve a spine index and a within-item fraction, which is a good-enough first restore before the new format takes over. No schema change is needed for positions.

### Highlights and bookmarks

New tables, keyed like positions by identifier and file_name, with a release identifier column: highlights (id, locator JSON for start and end, exact text, prefix, suffix, style, note, created_at, updated_at, orphaned flag) and bookmarks (id, locator JSON, chapter title, preview, created_at). FolioReaderKit used Realm with a schema version of 2 and a per-reader configuration; the shape of its record (content, pre, post, page, type, note, date, id) maps onto the highlights table minus the page number, which the locator replaces.

### Preferences

FolioReaderKit persisted font family, font size step, audio rate step, highlight style, media-overlay style, scroll direction, night mode and the last chapter-list tab, globally or under a per-instance identifier. Funston already has a reading layout setting (paginated or continuous) in its settings store and derives size and theme from the system. The merged spec should add at most: read-aloud rate preset, overlay skippability on or off, and a per-book publisher-styles override.

## Accessibility

What the candidates offer: nothing beyond what UIWebView or WKWebView exposes on their own. FolioReaderKit draws its menus with image-only buttons and custom segment views without accessibility labels; its sentence and overlay highlights are CSS classes with no accessibility side effect; its page indicator is two labels of unlabelled text; its scroll scrubber is a rotated UISlider, which is at least a real control. EbookReader hides the native scroll indicator in favour of a drawn one. EPUBReaderSwiftUI inherits Readium's navigator behaviour, including the continuous-scroll switch under VoiceOver that Funston already relies on.

What Funston already has, and the EPUB renderer must match: PDFLineAccessibility exposes one static-text element per recognized line with a frame computed from the page at query time, so zoom and scroll never go stale; elements exist only for visible pages and the container posts a layout-changed notification when the visible set changes; becoming focused scrolls the line into view without re-fitting the page; the find navigator keeps its own accessibility while open; a page element with the adjustable trait sits first in the container, turns pages on increment and decrement, announces "Page N of M" through a page-scrolled notification, and toggles the chrome on Magic Tap with a custom action mirroring it; the controls' state is announced as the element's value.

Requirements for the EPUB renderer (SWP-33, with these specifics):

- The unit is the block (paragraph, heading, list item, figure, table cell), in reading order, not the line, because reflowed prose reads by paragraph; the PDF reader uses lines because OCR gives lines.
- Headings carry the header trait and their level where the platform allows; links carry the link trait and are rotor-reachable; images announce their alt text and a "image" trait; decorative images (empty alt) are not exposed.
- Elements exist only for blocks whose layout fragment intersects the visible area plus one page of lookahead, and the container posts a layout-changed notification when that set changes, exactly as the PDF reader does for pages.
- Continuous layout under VoiceOver remains the default, as it is today, because paginated layout breaks swipe-to-next across page boundaries.
- Read-aloud and overlays: exposed as play and pause custom actions on the page element and as Now Playing commands; while VoiceOver is running the reader does not auto-start speech, it announces the active sentence change through a layout-changed notification with the sentence's element as the argument, and the audio session ducks VoiceOver's output rather than mixing at full volume. The open question of whether Magic Tap should toggle playback (the platform convention) or the controls (the current behaviour shared with the PDF reader) is in section 11.
- The chapter list and highlight list are native lists, as the current contents sheet already is (indented rows for depth).
- Verification is by running VoiceOver on the simulator and walking the chapter: every block reached once, in order, no focus over empty space, the page element announcing page changes, and the active sentence announced during read-aloud. A code-structure check is not evidence.

## Malformed input and failure behaviour

Observed behaviour per candidate, verified by reading unless marked:

| Condition | EPUBKit | Bookbinder | epubparser and FolioReaderKit |
| --- | --- | --- | --- |
| Not a ZIP | Typed unzip error wrapping the library's error | nil, prints | ZIP library error propagates (epubparser) or extraction silently yields nothing and the container read fails (FolioReaderKit; SSZipArchive's result is not checked) |
| No container.xml | Typed container-missing error | nil | Data read error propagates untyped |
| container.xml without a rootfile | Typed content-path error | nil | Typed "path empty" error |
| rootfile full-path names a missing file | Data read error propagates untyped | nil | Data read error propagates untyped |
| Package document not well-formed | AEXML error propagates untyped | nil | AEXML error propagates untyped |
| Package without unique-identifier | Opens; identifier is the first dc:identifier | Whole book fails (nil) | Opens; identifier nil |
| Manifest item without media-type | Kept with unknown type | Dropped | Kept with an empty-name synthesized type |
| Spine itemref with unknown idref | Kept | Kept (spine is ids only) | Dropped silently |
| No spine toc attribute (EPUB 3 nav-only book) | Typed TOC-missing error; book cannot open | Opens; ncx nil; nav URL exposed, not parsed | Opens via nav property fallback; the nav is parsed |
| No NCX and no nav at all | Typed TOC-missing error | Opens; no TOC | Precondition failure (crash) |
| NCX navPoint without id or content src | Crash (force unwrap) | Dropped | Dropped (src) or kept with empty label |
| NCX navPoint without playOrder | Fine | Dropped | Fine |
| dc-metadata wrapper (OPF 2.0.1 legacy) | Metadata empty | Metadata empty | Metadata empty |
| NCX declared as text/xml | Fine (follows spine toc id) | Fine (follows spine toc id) | Fine (extension fallback) |
| Percent-encoded href | File not found | File not found | Found by decoded absolute path; TOC lookup by raw href may miss |
| Unparseable SMIL | Not parsed | Not parsed | Prints, overlay dropped |
| Unknown clock value | Not parsed | Not parsed | Zero seconds |
| Audio file missing | Not parsed | Not parsed | Prints, returns false, playback stops |
| Chapter not UTF-8 | Not read | Not read | Cell shows nothing (FolioReaderKit); crash on force-unwrapped decode (epubparser) |

Required behaviour: SWP-30 defines the five fatal causes and SWP-32 the diagnostic channel. The reader's two user-facing messages today ("The file isn't a book this app can read" and "The book's file looks damaged. Try downloading it again.") map to not-a-ZIP and no-container for the first, and to the other three fatal causes for the second, each with the retry path the current controller already has.

Memory and size: FolioReaderKit's audio path reads the entire audio file into a Data value (verified) and its parser reads every SMIL file at open; both must be lazy and streamed (SWP-01, SWP-21). None of the candidates bounds XML entity expansion or document size; the merged spec should set a ceiling on package document and nav document sizes (a diagnostic, then refusal, above a few megabytes) and on SMIL par counts per file (the real sample has 1,181 in one chapter; 100,000 would be a bomb).

## Test fixtures and vectors

### Public fixtures (by URL; do not vendor the candidates' test books)

- W3C EPUB 3 test suite: https://github.com/w3c/epub-tests (publication-level tests under tests/, with results at https://w3c.github.io/epub-tests/). Use its container, package, navigation and media-overlay tests as the conformance baseline.
- IDPF EPUB 3 samples: https://github.com/IDPF/epub3-samples. Useful ones by directory name: childrens-literature (nested nav with span headings), epub30-spec (deep nav, many spine items), moby-dick (plain EPUB 3), the media-overlay samples, georgia-cfi (CFI references), haruko-html-jpeg and kusamakura-vertical-writing (Japanese vertical writing, rtl spine), regime-anticancer-arabe (Arabic rtl), linear-algebra (MathML), accessible_epub_3 (accessibility metadata, page-list). Verify directory names against the repository before relying on them.
- Project Gutenberg: https://www.gutenberg.org/ebooks/11.epub3.images (Alice, EPUB 3 build) and https://www.gutenberg.org/ebooks/11.epub.images (EPUB 2 build); the archive.org original named in the brief, https://archive.org/download/manandmaid20512gut/pg20512-images.epub, is the primary corpus shape.
- Standard Ebooks: https://standardebooks.org/ebooks/lewis-carroll/alices-adventures-in-wonderland (EPUB 3 with nav, landmarks, NCX, and the compatible-EPUB variant). Bookbinder's tests use this book's 2017 release; its expectations (one creator, five contributors, two sources, six guide references, seventeen top-level NCX points, twenty-five manifest items, eighteen spine items) describe that release, not ours.
- epubcheck: https://github.com/w3c/epubcheck (its test resources are the richest set of malformed containers and packages).

### Edge cases the candidates' tests cover, in words

EPUBKit (Swift Testing, 1,600 lines): parsing four well-formed books and asserting title, author, publisher and cover presence; four broken books expecting, respectively, an archive-level failure, a missing container, a container with no rootfile, and a book whose spine toc id has no manifest item; nonexistent and directory inputs; delegate call order and weak delegate release; a pre-extracted directory parsed equal to the archive. Its "edge case" suite builds model values directly (empty manifest, empty spine, special characters and whitespace in a title, a ten-level nested TOC, fifty manifest items, duplicate spine idrefs, empty ids, nine path shapes) and asserts they are stored unchanged; none of those cases goes through the parser. The archive-level failure fixture is, by Info-ZIP's test mode, a well-formed stored archive whose entire contents, container file included, sit under one top-level folder, so there is no container file at the root and no mimetype entry (the shape you get by re-zipping an extracted book from a file manager); the test expects the ZIP library's own error, which I could not confirm without running the code, so pin the container-missing case instead and see vector V21.

Bookbinder (Quick and Nimble, 430 lines): one book (Standard Ebooks Alice) parsed from a directory and from a ZIP; container path; every metadata field; manifest item count and six specific items; spine ids in order; NCX title, seventeen points with ordered playOrder, labels and sources; cover URLs; nav URL; primary pages in order; guide references through a subclass. No malformed input at all.

epubparser and FolioReaderKit: no tests (both files are the Xcode template with no assertions).

### Our vectors (build from the spec; describe here, author in the test target)

- V1 Minimal EPUB 3: one chapter, nav only, no NCX, no cover. Must open (SWP-14); EPUBKit cannot.
- V2 Minimal EPUB 2 in the 2007 shape: dc-metadata wrapper, NCX declared text/xml, an Adobe page-template item, a manifest attribute with whitespace before its equals sign, GIF images. Must open with title and author (SWP-06, SWP-11, SWP-12).
- V3 Paths: chapter files named with a space, an accented letter, a plus sign and a non-Latin script, referenced percent-encoded in the manifest, raw in the nav, and percent-encoded differently in a link (SWP-19).
- V4 Container with two rootfiles, the first of a non-package media type (SWP-04).
- V5 No container.xml; V6 container with an empty rootfiles element; V7 rootfile naming a missing path (SWP-30).
- V8 Package with no unique-identifier, then with a dangling one (SWP-08).
- V9 Nav document with landmarks first, a toc nav inside a section, span headings over nested lists, a hidden page-list, and one unresolvable entry (SWP-14, SWP-16).
- V10 Clock values: a table of at least twenty strings covering every H.4 production (full clock with and without fraction, hours above 99, partial clock, bare seconds above 99, each of the four units, fractions of one and five digits, surrounding whitespace, and five invalid strings) with expected seconds or failure (SWP-20).
- V11 Overlay: one chapter, a seq with epub:type chapter containing a skippable seq (page-break) and two pars sharing one audio file, SMIL in a subfolder with "../" references, media:duration total and refined, custom active-class (SWP-20, SWP-21).
- V12 Cover: six single-rule books (SWP-17).
- V13 Manifest with duplicate ids, a missing media-type, an unknown media-type and a multi-token properties value (SWP-11).
- V14 Spine: rtl, a non-linear item, a dangling idref, a repeated idref (SWP-13).
- V15 NCX with no playOrder, no ids, five levels, one src with a fragment, one navPoint without content (SWP-15).
- V16 An archive entry whose name escapes the root, and a second entry differing only by case from a chapter (SWP-02).
- V17 Chapter XHTML with an XHTML 1.1 DOCTYPE and every named entity; a second chapter that is not well-formed at its last paragraph (SWP-07, SWP-30).
- V18 Wrong mimetype entry (compressed, then absent) (SWP-03).
- V19 Metadata expressed once in EPUB 2 attributes and once in EPUB 3 refines, including two titles, a contributor and a modification date (SWP-09, SWP-10).
- V20 A nav document in a subdirectory with chapters in a sibling directory and the NCX in the package root (SWP-05).
- V21 A whole book nested under one top-level folder inside the archive, container file included (SWP-04, SWP-30): must fail with the container-missing error, and the diagnostic should name the nested container path so the message can suggest the cause.

Each vector is a hand-written archive built by a test helper from a dictionary of entry name to bytes, so it never depends on a third-party fixture and the mimetype ordering is under the test's control.

## Things to avoid

- Full extraction of the archive before parsing; extraction into Documents; skipping extraction when a same-named folder exists; deleting the source file after extraction (EPUBKit, Bookbinder, FolioReaderKit, epubparser).
- Matching XML by literal prefix (EPUBKit, FolioReaderKit, epubparser). Reading only direct children of metadata (all three and Bookbinder).
- Reading page-progression-direction as a child element (EPUBKit, spine parser, direction lookup).
- Requiring the spine toc attribute, which rejects EPUB 3 nav-only books (EPUBKit, parser, TOC lookup).
- Force-unwrapping navPoint id and src (EPUBKit, TOC parser, child evaluation). The dtb identifier lookup with an equals sign instead of a colon (same file).
- Returning nil for the whole book when unique-identifier is absent, or dropping NCX entries without playOrder (Bookbinder).
- A precondition when no TOC resource exists (FolioReaderKit and epubparser, package reading).
- Preferring the NCX over the nav document in EPUB 3, taking the first nav rather than the toc nav, and flattening the TOC two levels deep (FolioReaderKit, epubparser).
- Filing contributors into creators; discarding a declared language of "en" in favour of "en-US"; recording a meta element up to three times (FolioReaderKit, epubparser, metadata reading).
- Keying resources by href, comparing the properties attribute by whole-string equality, and stripping every "../" from TOC hrefs instead of resolving them (FolioReaderKit, epubparser).
- Concatenating every spine document into one HTML file and writing it beside the first chapter (epubparser).
- A closed media-type enum that collapses everything else to unknown (EPUBKit).
- Clock-value parsing by regular expression plus a date formatter, returning zero on failure (FolioReaderKit, epubparser).
- A 10 ms repeating timer to detect clip ends; loading whole audio files into memory; a linear scan from the file start to find the next par (FolioReaderKit, audio player).
- Sentence segmentation by rewriting paragraph markup with a regular expression (FolioReaderKit, bridge script), and read-aloud state kept in page-level JavaScript so it resets on every page load.
- Highlights anchored by thirty characters of surrounding HTML and restored by literal string search and markup splicing (FolioReaderKit, highlight helper). Highlights keyed by file name without extension.
- Reading position as chapter number plus scroll offset in points (FolioReaderKit); scroll offsets per chapter in UserDefaults (EbookReader).
- Mirroring the view hierarchy with a scale transform to fake right-to-left paging (FolioReaderKit, center controller).
- Fixed pixel size ladders, bundled fonts loaded at launch, and important-flagged colour overrides for night mode (FolioReaderKit); Funston follows Dynamic Type and the system appearance.
- Image-only buttons without accessibility labels, custom segment controls, and drawn scroll indicators replacing native ones (FolioReaderKit, EbookReader).
- Re-parsing the whole book to answer "what is the title" (FolioReaderKit and epubparser convenience methods).
- Implicitly unwrapped optionals on decoded fields; NSObject models with mutable state shared across threads; printing instead of diagnostics (all three older code bases).
- Test suites that assert the library's own bugs (EPUBKit's document tests expect no title for its Alice fixture) or that construct model values and call it edge-case coverage.
- Copyrighted commercial books as test fixtures (one of EPUBKit's four books is a 2008 trade title); use public-domain fixtures only.
- UIWebView, the synchronous JavaScript evaluation API, custom URL schemes as a message bus, and Realm as a highlight store; all dead on current iOS.

## Open questions for the merged spec

1. Locator format: CFI strings (interoperable, verbose, needs a CFI generator and resolver over our own DOM) versus spine index plus character offset into a normalized text model (simple, but tied to our normalization rules). My recommendation is both: store the offset as the primary key and generate a CFI when cheap, so highlights can be exported later. The Readium JSON already in book_positions must stay readable during the transition (section 6).
2. Should media overlays ship in the first version at all? The Gutenberg corpus has none, and Internet Archive's LibriVox audio is separate from the text. The parser side (SWP-20) is cheap and keeps the door open; the player (SWP-21) is not. Suggest parsing in version one and playback later, with the sentence-level read-aloud (SWP-22) first because VoiceOver users benefit from it directly.
3. Magic Tap: the PDF and EPUB readers today use it to toggle the chrome. The platform convention during playback is play or pause. One answer is to toggle playback while read-aloud or an overlay is active and the chrome otherwise, announced through the page element's value; the merged spec should decide once for both readers.
4. Read-aloud while VoiceOver runs: offer it (some users prefer a narrator voice and sentence highlighting to VoiceOver's reading) but never auto-start, and duck rather than mix. Needs a decision on which audio session mode to use with the music player Funston already shares.
5. Block versus line as the accessibility unit for EPUB (section 7). I recommend block; the PDF reader's line granularity comes from OCR, not from preference.
6. Should the reader render non-well-formed XHTML at all (Gutenberg's older builds have a few), and if so with which recovery strategy: Foundation's parser stops at the first error; a tolerant HTML parser would be a dependency, which the project rules forbid. The fallback could be: render what parsed, insert a visible marker, record a diagnostic.
7. Edition changes: when the release identifier differs from the stored one, keep positions and highlights and try to re-anchor them, or reset? Re-anchoring by quote selector works for highlights; positions should fall back to total progression.
8. Vertical writing: out of scope for Gutenberg, but the detection flag (SWP-28) costs nothing. Decide whether TextKit 2's vertical layout is attempted in version one or the diagnostic path is taken.
9. The words-per-minute constant and whether it should adapt to the user's measured pace over time.

## Clean-room statement

I read the candidates' source to understand their behaviour and wrote this document from that understanding. It contains no code, comments, docstrings, README text, test data or fixture content from any candidate, and no pseudocode transliterated from their source; the algorithms in section 5 are written from the behaviour and from the EPUB specifications. Internal type and file names appear only in section 3 as orientation. Numbers given as observed (line counts, constants such as the 10 ms timer, the 30-character highlight context, the 180 words per minute, the five pixel sizes, the four utterance rates, the 1,181 pars and 27 MB audio in the sample book) were read from the source or from archive listings and are stated with their origin. The candidates' clones live outside the repository in this session's scratchpad and were never built, run or copied. The implementer of the merged spec should not read the candidates.

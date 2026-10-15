# Study: EPUB standards and the real corpus

Requirement ID prefix: STD. This study reads only public specifications, public conformance suites and real books. It is the clean half of the clean room: no reading-system source was opened while writing it.

## 1. Provenance

### Specifications read

| Document | Status and date | URL |
| --- | --- | --- |
| EPUB 3.3 (Core) | W3C Recommendation, 13 January 2026 (the maintained edition of the 25 May 2023 Recommendation) | https://www.w3.org/TR/epub-33/ |
| EPUB Reading Systems 3.3 | W3C Recommendation, 17 October 2024 | https://www.w3.org/TR/epub-rs-33/ |
| EPUB 3.4 and EPUB Reading Systems 3.4 | W3C Candidate Recommendation Drafts, 2 October 2026 and 21 July 2026. Not yet normative. The W3C epub-tests suite is already versioned against 3.4 | https://www.w3.org/TR/epub-34/ , https://www.w3.org/TR/epub-rs-34/ |
| EPUB Accessibility 1.1 | W3C Recommendation, 17 October 2024 | https://www.w3.org/TR/epub-a11y-11/ |
| EPUB Accessibility Techniques 1.1 | W3C Group Note, 13 March 2025 | https://www.w3.org/TR/epub-a11y-tech-11/ |
| EPUB 3 Structural Semantics Vocabulary 1.1 | W3C Group Note, 28 May 2026 | https://www.w3.org/TR/epub-ssv-11/ |
| Digital Publishing WAI-ARIA Module 1.1 | W3C Recommendation, 12 June 2025 | https://www.w3.org/TR/dpub-aria-1.1/ |
| EPUB Canonical Fragment Identifiers 1.1 | IDPF Recommended Specification, 5 January 2017 | https://idpf.org/epub/linking/cfi/epub-cfi.html |
| Open Packaging Format 2.0.1 | IDPF Recommended Specification, 4 September 2010 | https://idpf.org/epub/20/spec/OPF_2.0.1_draft.htm |
| Open Publication Structure 2.0.1 | IDPF Recommended Specification, 4 September 2010 | https://idpf.org/epub/20/spec/OPS_2.0.1_draft.htm |
| Open Container Format 3.0 (for the pre-3.0.1 obfuscation note) | IDPF, 11 October 2011 | https://idpf.org/epub/30/spec/epub30-ocf.html |
| ANSI/NISO Z39.86-2005, section 8 (the NCX) | DAISY, 2005 | https://daisy.org/z3986/2005/Z3986-2005.html |
| Font Embedding for Open Container Format Files (the original obfuscation note) | IDPF, 2008 | https://idpf.org/epub/20/spec/FontManglingSpec.html |
| ZIP File Format Specification (APPNOTE) | PKWARE, version 6.3.10, 1 November 2022 | https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT |
| Standard Ebooks Manual of Style | version 1.9.1 | https://standardebooks.org/manual/1.9.1/single-page |
| W3C epub-tests | clone at commit 54092b4233253e9aac80e93ec4782b380b4b3403 (29 September 2026), 211 test directories | https://github.com/w3c/epub-tests |
| IDPF epub3-samples | samples table last updated 4 July 2023, release tag 20230704 | https://github.com/IDPF/epub3-samples |
| EPUBCheck | 5.4.0, released 15 September 2026 | https://github.com/w3c/epubcheck/releases/tag/v5.4.0 |

Section numbers cited below are those of the documents above. "RS" means the Reading Systems 3.3 specification.

### Books downloaded

All Project Gutenberg files came from archive.org through the pattern `https://archive.org/download/<identifier>/<file>`. Every one is reported by the archive.org metadata API as `format: EPUB`, `source: original`, inside an item with `mediatype: texts` and `collection: gutenberg`. This is exactly the shape Funston's `MediaAvailability` and `ArtifactMediaPresentation.bookFile` already route to the book reader. The one derivative EPUB met during the search (`30155-pdf.epub`, derived from `30155-pdf_abbyy.gz`, so an OCR product) is correctly excluded by the `source == original` rule.

| archive.org identifier | File | Bytes (API `size`) | API md5 | mtime (epoch) | Item language | Generator |
| --- | --- | --- | --- | --- | --- | --- |
| manandmaid20512gut | pg20512-images.epub | 312819 | b3ba22ce250af25310657c6cbe70c317 | 1310966114 | eng | Project Gutenberg EPUB-Maker v0.03 |
| manandmaid20512gut | pg20512.epub | 211340 | 7e6eba32e033aac8b501f05a2feabfda | 1310966081 | eng | EPUB-Maker v0.03 |
| historyofthedecl00890gut | pg890.epub (Gibbon, Decline and Fall vol. 1) | 421894 | 87fb9b10d65f1ffae9972b4c026ed101 | 1310525467 | eng | EPUB-Maker v0.02 |
| relativitythespe30155gut | pg30155-images.epub (Einstein, Relativity) | 187853 | 6cb5fdb85fda593aa22d7e5a7cd07dc0 | 1310404652 | eng | EPUB-Maker v0.03 |
| relativitythespe30155gut | pg30155.epub | 94908 | e96dfdf32d6758b0c17d5273a4b3f98e | 1310404637 | eng | EPUB-Maker v0.03 |
| pgcommunitytexts24226gut | pg24226.epub (Sima Qian, Shiji, Chinese) | 944800 | bb40556cac7b8e2662ea3b83595d98d7 | 1310619489 | chi | EPUB-Maker v0.02 |
| pgcommunitytexts17995gut | pg17995.epub (Euripides, Elektra, Greek, verse drama) | 64058 | a7bb4a70f2e52eee7debedd99911bf8f | 1309253824 | gre | EPUB-Maker v0.02 |
| theciaworldfactb27348gut | pg27348.epub (2007 CIA World Factbook, preformatted data) | 2974227 | 75021ae66d5d2470d8eebf98a4a66a2f | 1310498320 | eng | EPUB-Maker v0.02 |
| poemsofthegreatw33681gut | pg33681-images.epub (Poems of the Great War, verse) | 73296 | 3d7aef1023c664d0bdf9c8773c91b70c | 1310101103 | eng | EPUB-Maker v0.03 |
| lesmisrablesvthe48734gut | pg48734-images.epub (Hugo, Les Misérables vol. 4, footnotes) | 844146 | dd2f0a061f7954a28bc2cea70d5ad11f | 1533422968 | en | Ebookmaker 0.4.0a5 |
| lesmisrablesvthe48734gut | pg48734.epub | 605540 | caa2622370483d54151be3b9db87bbeb | 1533422916 | en | Ebookmaker 0.4.0a5 |

Standard Ebooks files came from `https://standardebooks.org/ebooks/<author>/<title>/downloads/<file>?source=download`. Without the `?source=download` query the server returns an HTML interstitial page ("Your Download Has Started") that redirects by meta refresh; a downloader that saves the first response gets a 9 KB HTML file named `.epub`. That is itself a routing lesson: sniff the first four bytes for `PK\x03\x04` before trusting an extension.

| File | Bytes | SHA-256 (first 16 hex) | Build |
| --- | --- | --- | --- |
| herman-melville_moby-dick.epub | 1165523 | 5d9c3ddb9d4cda13 | SE toolset 4.0.3, "epub/compatible" build: EPUB 3.0 package plus NCX, guide and OPF2 cover meta for old readers |
| herman-melville_moby-dick_advanced.epub | 1401583 | 6f3f53d32615ae3e | SE toolset 4.0.3, "epub" build: no NCX, no guide, SVG images, attribute selectors in CSS |
| lewis-carroll_alices-adventures-in-wonderland_john-tenniel.epub | 18398848 | 8f957fd0c7fabc29 | SE toolset 4.1.0, compatible build with 88 PNG illustrations at 1x and 2x |

Archive.org metadata for the Gutenberg items also records `publicdate` (2011-06 to 2011-07 for the EPUB-Maker books, 2018-08 for the Ebookmaker book). Items ingested in 2006 (for example leavesofgrass01322gut, poemsbyemilydick12242gut, historyofthedecl00731gut, faustdertragdiee02229gut) carry no EPUB at all, only `.txt` and `.zip`; the EPUB files exist only on items (re)ingested from 2011 on. Funston should expect many Gutenberg items in the archive.org collection to have no book file, and must not treat that as an error.

### Handling of downloaded files

Every archive was unpacked by a Python script kept in a separate scripts directory and run with `python3 -I`, into its own empty directory under the scratchpad. Nothing from inside a book was executed. EPUBCheck 5.4.0 was downloaded from the W3C GitHub release and run with `java -jar` against each file by path. No downloaded file was copied into the repository.

## 2. What it is and why it matters to Funston

An EPUB is a ZIP file with a fixed entry point (`META-INF/container.xml`) that names a package document (the OPF). The package document lists every resource of the book (the manifest), gives the default reading order (the spine), carries bibliographic metadata, and in EPUB 3 names a navigation document (an XHTML file whose `nav` elements hold the table of contents, page list and landmarks). Content documents are XHTML (or SVG), styled by CSS, and can carry structural semantics in `epub:type` and ARIA roles. EPUB 2 (2010) has the same container and the same package shape but an NCX (a DAISY XML table of contents) instead of a navigation document, a `guide` element instead of landmarks, and an OPF2 `meta name="cover"` instead of the `cover-image` manifest property.

Funston today hands this whole stack to Readium 3.11 and gets back a `Publication`, a navigator view controller, and `Locator` JSON that it stores in the `book_positions` table (`Funston/Services/SQLiteStore.swift`, migration 4). The decision to replace Readium with a Funston-owned parser and a native TextKit 2 renderer means Funston has to own three things Readium currently hides:

1. The container and package model, including every leniency a real book demands. The Gutenberg corpus Funston actually serves is EPUB 2.0 generated by two generations of Gutenberg's converter, with quirks that a strict EPUB 3 parser rejects (see section 8).
2. The position model. Readium's `Locator` is a JSON object with `href`, `type`, `title` and a `locations` block holding `progression`, `totalProgression`, `position` and, when available, a `cfi` string, plus a `text` block with `before`, `highlight` and `after`. The clean-room reader needs a locator that survives both the migration from these stored rows and a change of rendering engine. EPUB CFI is the only interoperable position scheme in the standards and is the right spine for it.
3. The accessibility layer. Readium presents a WKWebView to VoiceOver. Funston's PDF reader instead exposes recognized lines as individual `UIAccessibilityElement`s (`Funston/UI/PDFLineAccessibility.swift`), so VoiceOver reads real text in order, elements are tethered to on-screen geometry, and page turns announce "Page N of M". The EPUB renderer must give VoiceOver the same quality from real markup, which is only possible if the parser preserves the structure (headings, paragraphs, list items, table cells, notes, page breaks) that the specifications define.

The payoff of standards work here is concrete. Every leniency in section 8 corresponds to a book Funston would otherwise refuse or render wrong. Every accessibility semantic in section 7 corresponds to something VoiceOver can announce instead of guess. And the CFI algorithm in section 5 is what lets a position saved under one font size, rotation or renderer version resolve under another.

## 3. Architecture in our words

This is the format as a reading system sees it, from the outside in.

### The container

The file is a ZIP archive (EPUB 3.3 section 4.3). The specification constrains the ZIP: entries are stored or Deflate-compressed only (4.3.2), no spanning or splitting, no ZIP encryption, ZIP64 "Version 1" allowed, file names UTF-8, `version needed to extract` 10, 20 or 45, compression method 0 or 8. The first entry must be `mimetype`, stored, with no extra field, containing exactly `application/epub+zip` (4.3.3). In practice the local file header of the first entry starts at byte 0, its name begins at byte 30, and the content at byte 38, which is why "`mimetype` at offset 30" is a cheap sniff for an EPUB. Every book in the corpus passed this sniff, including the Standard Ebooks ones.

Inside, the abstract container (4.2) is a tree with a single root. `META-INF/` is reserved and holds `container.xml` (required), and optionally `encryption.xml`, `signatures.xml`, `metadata.xml`, `rights.xml` and `manifest.xml` (4.2.6.3). Nothing in `META-INF` or the `mimetype` file is a publication resource and nothing there may appear in the manifest (4.2.2). Every other file can live anywhere outside `META-INF`. File names are case-sensitive, limited to 255 bytes, paths to 65535 bytes, and may not contain `/ " * : < > ? \ |`, a trailing full stop, control characters, private-use or non-characters (4.2.3). Spaces are discouraged (SHOULD NOT) but legal.

`container.xml` (4.2.6.3.1) has a `container` root (`version="1.0"`, namespace `urn:oasis:names:tc:opendocument:xmlns:container`) with one `rootfiles` element holding one or more `rootfile` elements, each with `full-path` (a path relative to the root, not to META-INF) and `media-type="application/oebps-package+xml"`. The first `rootfile` is the default rendition (RS 4.1.3). An optional `links` element follows; EPUB 3.3 defines no use for it. All elements from other namespaces are to be stripped before validating, so a parser must ignore what it does not know.

`encryption.xml` (4.2.6.3.2) wraps XML Encryption `EncryptedKey` and `EncryptedData` elements. Each `EncryptedData` has an `EncryptionMethod Algorithm` and a `CipherData/CipherReference URI` naming the encrypted file. Font obfuscation (4.4) is declared here with the algorithm `http://www.idpf.org/2008/embedding` and is not encryption; anything else in this file means a real DRM scheme and the resource is unreadable to us. `mimetype`, every reserved META-INF file and the package document may never be encrypted. `signatures.xml` holds XML Signatures; reading systems are not required to check them (4.2.6.3.6 note). `manifest.xml` exists only for Open Document compatibility and must not be used for processing (RS 4.1.3). `metadata.xml` carries container-level metadata that this version does not define.

### The package document

The OPF (section 5) is XML in the namespace `http://www.idpf.org/2007/opf`. The root `package` element carries `version` ("3.0" for every EPUB 3.x; "2.0" for EPUB 2), the required `unique-identifier` IDREF, and optional `xml:lang`, `dir` and `prefix`. Children in order: `metadata`, `manifest`, `spine`, then the legacy `guide`, the deprecated `bindings`, and zero or more `collection` elements (5.4).

Metadata (5.5) mixes Dublin Core elements in the `http://purl.org/dc/elements/1.1/` namespace with OPF `meta` elements. EPUB 3 requires at least one `dc:identifier` (the one referenced by `unique-identifier` is the unique identifier), at least one `dc:title` (the first in document order is the main title), at least one `dc:language` (BCP 47; the first is primary), and exactly one `meta property="dcterms:modified"` in the form `YYYY-MM-DDThh:mm:ssZ` (5.5.5). `meta` elements are either primary expressions or, with a `refines="#id"` attribute, subexpressions about another element or a manifest item (5.3.6, 5.5.4). The default vocabulary for `property` includes `title-type`, `file-as`, `role`, `display-seq`, `belongs-to-collection`, `collection-type`, `group-position`, `identifier-type`, `alternate-script`, `authority`, `term`, `source-of` (appendix D.3). Reserved prefixes that need no declaration include `dcterms`, `rendition`, `media`, `a11y`, `schema`, `marc`, `onix`, `msv`, `prism`, `xsd` (D.1.5); other prefixes must be declared on `package prefix="..."`. `link` elements (5.5.6) attach records (`rel="record"`, ONIX or JSON-LD and so on), which are not publication resources and are not in the manifest. EPUB 2 metadata uses the same DC elements with OPF attributes `opf:role`, `opf:file-as`, `opf:scheme`, `opf:event`, and `meta name="..." content="..."` elements, the most important of which is `name="cover"`.

The manifest (5.6) is an exhaustive list of every publication resource except the package document itself. Each `item` has `id`, `href` (absolute or path-relative URL, unique after parsing), `media-type`, and optional `fallback` (an IDREF forming a chain), `media-overlay` (IDREF to a SMIL document) and `properties` (space-separated: `nav`, `cover-image`, `mathml`, `svg`, `scripted`, `remote-resources`, `switch`). Exactly one item carries `nav` in EPUB 3. Order is not significant.

The spine (5.7) is the default reading order: `itemref` elements with `idref`, optional `linear="no"` (auxiliary content such as notes), optional `properties` (rendition overrides, `page-spread-left`/`right`). Each manifest item may be referenced at most once by an EPUB creator, but reading systems must tolerate duplicates and treat them as distinct positions (RS 5.5). `page-progression-direction` is `ltr`, `rtl` or `default`. The legacy `toc` attribute names the NCX item.

Core media types (3.2) are what a reading system must render without fallback: XHTML and SVG content documents, GIF, JPEG, PNG, WebP (and in 3.4 drafts AVIF and JPEG XL appear in tests), MP3 and AAC in MP4 audio, OpenType, TrueType, WOFF and WOFF2 fonts, CSS, JavaScript, SMIL media overlays, and the NCX media type `application/x-dtbncx+xml` is listed as a legacy allowance. Anything else is a foreign resource and needs a manifest fallback chain to a core type when it is in the spine (3.5.1).

### The navigation document

In EPUB 3 the navigation document (section 7) is an XHTML content document holding `nav` elements with `epub:type` values `toc` (required, exactly one), `page-list` (optional, at most one, flat), `landmarks` (optional, at most one, flat, every `a` must carry an `epub:type` such as `bodymatter`, `toc`, `loi`), and any other typed `nav`. The content model under a typed `nav` is strict: optional heading, exactly one `ol`, each `li` with exactly one `a` or `span` followed optionally by a nested `ol`; a `span` must be followed by an `ol`. Labels are the concatenated text, including `alt`/`title` of non-text descendants, after whitespace normalization, and must be non-empty. Links in `toc`, `page-list` and `landmarks` resolve to top-level content documents or fragments in them. Default list style is `none` and a reading system must not show numbering (RS 7). The `hidden` attribute affects rendering in the spine only, never the reading system's own TOC widget (7.5, RS 7, test nav-spine_in-spine-hidden-toc-html).

In EPUB 2 the NCX (OPF 2.0.1 section 2.4.1 and Z39.86-2005 section 8) has `head/meta` entries (`dtb:uid` required and equal to the unique identifier; `dtb:depth`, `dtb:totalPageCount`, `dtb:maxPageNumber` required by DAISY but allowed to be zero or ignored by OPF 2.4.2), `docTitle`, optional `docAuthor`, a `navMap` of nestable `navPoint`s (each with one or more `navLabel/text`, a `content src`, and a `playOrder` that OPF 2.0.1 makes optional unless the DOCTYPE references the DTD), an optional `pageList` of `pageTarget`s (`type` front/normal/special, numeric `value`), and optional `navList`s of non-nesting `navTarget`s. Standard Ebooks ship both nav and NCX in their compatible build and they agree exactly; Gutenberg ships NCX only.

### Content documents, CSS, scripting, overlays

XHTML content documents (6.1) are HTML documents in the XML syntax, with the `epub:type` extension, RDFa or microdata allowed, MathML and SVG embeddable, `base` discouraged. SVG content documents (6.2) are standalone SVG files that may be in the spine. CSS (6.3.1) is whatever the CSS Snapshot defines, except that `direction` and `unicode-bidi` are forbidden in author CSS (use `dir` and `bdo` instead), and a handful of `-epub-` prefixed properties are retained (appendix E: `-epub-writing-mode`, `-epub-text-orientation`, `-epub-text-combine-horizontal`, `-epub-hyphens`, `-epub-line-break`, `-epub-text-align-last`, `-epub-word-break`, the `text-transform: -epub-fullwidth` value, and the `-epub-text-emphasis-*` and `-epub-text-underline-position` properties). Scripting (6.3.2) is either container-constrained (in an `iframe`) or spine-level; a reading system may not support it, and then must process fallbacks (RS 6.4). Fixed layouts (8.2) are declared by `rendition:layout` `pre-paginated` and friends; reflowable overflow handling is a hint through `rendition:flow` (`paginated`, `scrolled-continuous`, `scrolled-doc`, `auto`) which a reading system may override for the user (RS 8.2.1). Media overlays (section 9) are SMIL 3.0 subsets attached through the manifest `media-overlay` attribute; a reading system that does not support them must ignore the attribute and the SMIL items (RS 9).

### Where Funston's reader sits

For Funston, version one is a reflowable reader for XHTML content with CSS interpreted into TextKit 2 attributes, no script execution, no fixed layout, and no media overlay playback. Everything in the architecture above still has to be parsed, because the package and navigation models decide what the reader shows, and because a failure to parse must degrade to a diagnostic and not to a blank screen.

## 4. Requirements

Each requirement has a statement in "shall" form, why it matters, the specification citation, edge cases, and how to test it. "Tolerant" requirements deliberately go beyond what the specifications allow EPUB creators to do, because the Reading Systems specification says a reading system "SHOULD attempt to process file names and paths that do not adhere" (RS 4.1.2), "MUST attempt to process an EPUB publication whose package document version attribute is less than 3.0" (RS 12), and is "not required to load" invalid publications (RS 2.2) but is never required to refuse them. Funston's choice is to open everything it can and report what it could not.

### Container

**STD-01 ZIP reading.** The reader shall open an EPUB by reading the ZIP central directory, shall support stored (method 0) and Deflate (method 8) entries, ZIP64 extended information (extra field 0x0001, the Zip64 end of central directory record and locator), entries whose local header sizes and CRC are deferred to a data descriptor (general purpose bit 3), and file names flagged UTF-8 (bit 11) or not flagged. It shall treat other compression methods, ZIP encryption (bit 0), an archive decryption header or archive extra data record, and multi-volume archives as errors for the affected entries only. Why: RS 4.2 lists exactly these as "in error" conditions and requires ZIP64 support; real archivers write data descriptors and Zip64 fields even for small files, and Standard Ebooks archives contain directory entries (zero-length names ending in `/`) that must be skipped, not treated as resources. Citations: EPUB 3.3 4.3.2, RS 4.2, APPNOTE 4.3.9 (data descriptor), 4.4.4 (bit 3 and bit 11), 4.5.3 (Zip64 extra field), 4.3.14 and 4.3.15 (Zip64 records). Edge cases: duplicate entry names (the ZIP format allows them; use the last central directory entry and record a diagnostic); a central directory that disagrees with the local headers (trust the central directory); names with backslashes (treat `\` as a literal, not a separator, per APPNOTE 4.4.17, but tolerate by also trying the `/` form); a CRC mismatch (record a diagnostic, still deliver the bytes); an `End of central directory` comment that pushes the record away from the file end (scan backwards up to 65557 bytes). Test: the W3C tests ocf-zip-comp and ocf-zip-mult must be reported as errors, not opened silently; a hand-built fixture with a data descriptor on `mimetype` and a Zip64 extra field must open; a zero-length `mimetype` entry must open with a diagnostic.

**STD-02 The mimetype entry.** The reader shall check that the first entry is `mimetype`, stored, without extra field, with content exactly `application/epub+zip`, and shall record a diagnostic for any deviation (missing, not first, compressed, trailing newline or whitespace, BOM) but shall not refuse the book on that basis. Why: the requirement is on EPUB creators (4.3.3); RS 4.2 lists no reading-system failure for it, and books produced by generic ZIP tools routinely get it wrong. Citation: EPUB 3.3 4.3.3, RS 4.2. Edge cases: `mimetype` present but with `application/epub+zip\n`; `mimetype` absent while `META-INF/container.xml` is present (open it); a file whose first entry is `mimetype` but whose `container.xml` is missing (refuse, see STD-03). Test: fixtures derived from a valid book with the mimetype entry removed, moved to the end, deflated, and padded; all four open, all four produce one diagnostic each.

**STD-03 container.xml and rootfile selection.** The reader shall parse `META-INF/container.xml`, select the first `rootfile` whose `media-type` is `application/oebps-package+xml` (or, if none has that media type, the first `rootfile` whose `full-path` ends in `.opf`), resolve `full-path` against the container root, and ignore elements and attributes in other namespaces, the `links` element, and unknown children. If `container.xml` is missing or unparsable, the reader shall look for exactly one `*.opf` entry anywhere in the archive and use it with a diagnostic; if there are zero or several, the book fails with a clear reason. Why: RS 4.1.3 makes the first rootfile the default rendition and allows a reading system to pick another only through a recognized selection mechanism (none exists for Funston). The spec says to validate the file "after removing all elements and attributes from other namespaces", so unknown content must never break parsing. Citation: EPUB 3.3 4.2.6.3.1, 4.2.6.2; RS 4.1.3. Edge cases: `full-path` with a leading slash or percent-encoding (normalize, see STD-05); `full-path` pointing at a missing entry (try case-insensitive match, then fail); several rootfiles for multiple renditions (use the first; the W3C test ocf-package_multiple checks this); the package in an odd subdirectory (ocf-package_arbitrary). Test: ocf-package_multiple, ocf-package_arbitrary, plus a fixture with no container.xml and one OPF.

**STD-04 META-INF reserved files.** The reader shall parse `encryption.xml` when present and classify each `EncryptedData` by algorithm: `http://www.idpf.org/2008/embedding` and `http://ns.adobe.com/pdf/enc#RC` mark obfuscated fonts (STD-06); every other algorithm marks the referenced resource as encrypted, which the reader shall report as "protected content" for that resource (fonts: fall back to system fonts; images: alt text; spine documents: the book is reported as protected). It shall ignore `manifest.xml`, `metadata.xml` with unknown roots, `rights.xml` and `signatures.xml` (signatures are not verified), and any other file in `META-INF`. Why: RS 4.1.3 forbids using `manifest.xml`, says to ignore unknown `metadata.xml` roots, and requires not failing on unlisted META-INF files (test ocf-metainf-inc, ocf-metainf-manifest). Citation: EPUB 3.3 4.2.6.3.2 to 4.2.6.3.6; RS 4.1.3. Edge cases: `encryption.xml` that is not well-formed (treat as absent with a diagnostic); a `CipherReference URI` with percent-encoding or a leading slash (normalize as in STD-05); an `EncryptedData` whose URI names a resource that does not exist (ignore). Test: ocf-metainf-inc, ocf-metainf-manifest, ocf-font_obfuscation, and a fixture with an Adobe ADEPT `encryption.xml` entry to see the protected-content path.

**STD-05 URL and path resolution.** The reader shall model a container root URL with the properties of EPUB 3.3 4.2.5 (parsing `/` or `..` against it yields the root itself), shall resolve every `href`, `src`, `full-path`, `CipherReference URI` and navigation link with the WHATWG URL parser against the content URL of the document that contains it (the package document's URL for the OPF and NCX, the content document's URL for XHTML, the container root for META-INF files), shall percent-decode the resulting path to look up the ZIP entry, and shall clamp any path that escapes the root to the root. Lookup shall try the exact decoded path first, then the NFC-normalized form, then NFD, then a case-insensitive match, and record a diagnostic when any fallback is used. A fragment (`#id`) is kept separately and never part of the entry lookup. Why: the specification forbids leading-slash and leaking `..` references but says conforming reading systems parse them to in-container URLs anyway (4.2.5 note and example 4; RS 4.1.1 table); real books use spaces, non-ASCII names and macOS NFD file names in ZIP entries. Citation: EPUB 3.3 4.2.5, 4.2.6.2, 5.2; RS 4.1.1, 4.1.2. Edge cases: `href="images/Caf%C3%A9.png"` against an entry named `images/Café.png` stored in NFD; `href="../../../EPUB/x.xhtml"` from `EPUB/a/b/c.xhtml`; `href="/EPUB/x.xhtml"`; `href` with `?query` (strip and warn); an `href` containing a raw space; a `src` that is an absolute `https:` URL (remote resource, STD-23); a `file:` URL (never load, RS 3.5); a `data:` URL (allowed inline for images, never as a top-level document, RS 3.4). Test: ocf-url_link-relative, ocf-url_link-path-absolute, ocf-url_link-leaking-relative, ocf-url_manifest, ocf-url_relative, plus the vectors in section 9.

**STD-06 Font deobfuscation.** For each manifest font resource named in `encryption.xml` with algorithm `http://www.idpf.org/2008/embedding`, the reader shall derive the key as the SHA-1 digest of the UTF-8 unique identifier with all XML whitespace (U+0020, U+0009, U+000D, U+000A) removed, and XOR the first 1040 bytes of the decompressed file with the key repeated (byte i with key[i mod 20]). For `http://ns.adobe.com/pdf/enc#RC` it shall use the commonly documented Adobe variant (see section 5 and the open question in section 11) and verify the result by checking the sfnt header; if the result is not a plausible font under either variant, it shall fall back to system fonts and record a diagnostic. If a deobfuscated font is still not a valid font and the package `version` is 3.0 without `dcterms:modified` newer than 2014, the reader may also try deobfuscating before inflating (the pre-3.0.1 ambiguity). Why: RS 4.3 says reading systems SHOULD deobfuscate; the ocf-font_obfuscation test checks it and the `_bis` test checks that a wrong key is detected, not used. Citation: EPUB 3.3 4.4.3, 4.4.4, 4.4.5; RS 4.3; the 2008 IDPF note. Edge cases: identifier containing internal whitespace or a `urn:uuid:` prefix (hash the whole string, whitespace removed); a font shorter than 1040 bytes (XOR the whole file); several `rootfile`s (use the identifier of the rendition being rendered). Test: the verified vector in section 9 (key `b562e83e...` for identifier `ocf-font_obfuscation` turns the first bytes `b563e83e...` into `00010000`, a TrueType header with 17 tables).

### Package document

**STD-07 Package parse and version handling.** The reader shall parse the package document as namespace-aware XML, accept `version` values "2.0", "3.0" and any other string, read `unique-identifier`, `xml:lang`, `dir` and `prefix` on `package`, and continue when `version` is missing (assume 2.0 if an NCX is referenced by `spine toc`, otherwise 3.0). Elements in unknown namespaces or unknown positions are ignored. Why: RS 12 and 13 require attempting EPUB publications with versions below and above 3.0 (test pkg-version-backward uses `version="0"`); every Gutenberg book is `version="2.0"`. Citation: EPUB 3.3 5.4; RS 12, 13. Edge cases: `package` not the root element (some tools wrap it); a default namespace missing on `package` (match by local name with a diagnostic); `unique-identifier` naming a missing `dc:identifier` (use the first `dc:identifier`; if none, synthesize one from the file's SHA-256 and say so). Test: pkg-version-backward; fixtures with a namespace-less OPF and with a dangling `unique-identifier`.

**STD-08 Metadata extraction.** The reader shall collect every DC element and `meta` element, strip and collapse ASCII whitespace in values (RS 5.3), treat the first `dc:title` in document order as the main title and the first `dc:language` as the primary language, order creators by document order, and attach `refines` subexpressions (`title-type`, `file-as`, `role`, `display-seq`, `alternate-script`, `belongs-to-collection`) to their targets. It shall accept EPUB 2 forms (`opf:role`, `opf:file-as`, `opf:scheme`, `opf:event`, OPF2 `meta name/content`) alongside EPUB 3 forms. Missing `dc:title` yields the file name as title with a diagnostic; missing `dc:language` yields "und" and does not block opening; missing `dcterms:modified` is a diagnostic only. Unknown `property` values are ignored and never fail the book (tests pkg-meta-unknown, pkg-meta-whitespace, pkg-title-order, pkg-creator-order). Why: Funston's bookshelf and VoiceOver announcements use title, creators and language; RS 5.3 defines the ordering rules; RS 5.2 warns that unique identifiers are not unique in practice (Gutenberg uses `http://www.gutenberg.org/ebooks/N`, which happens to be unique, but two editions of one Standard Ebook share one identifier). Citation: EPUB 3.3 5.5; RS 5.2, 5.3. Edge cases: several `dc:title` (Moby Dick has three: main, subtitle, expanded; use `title-type` when present, otherwise the first); `dc:language` values like "EN-US" or "gem" (accept any string, lower-case the primary subtag for matching); `dc:date` with `opf:event="conversion"` (keep both dates); HTML inside `dc:description` (Standard Ebooks embed `<p>` markup; strip tags for display). Test: pkg-meta-whitespace, pkg-title-order, pkg-creator-order, pkg-meta-unknown, pkg-dir_rtl-root-unset (title direction), and the corpus OPFs.

**STD-09 Manifest model.** The reader shall build a manifest keyed by `id`, record `href` (parsed to a content URL), `media-type`, `properties` tokens, `fallback` and `media-overlay`, ignore unknown property tokens (test pkg-manifest-unknown), resolve fallback chains by following `fallback` until a renderable media type is found and terminating at the first repeated item (RS 5.4), and tolerate items whose `href` does not exist in the archive (keep the item, mark it missing). It shall not treat resources present in the archive but absent from the manifest as part of the book, except that a content document reference to such a resource may still be served with a diagnostic (the spec says an unlisted image "should not be shown", test pkg-manifest-unlisted-resource; Funston serves it anyway because the alternative is a broken image in a public-domain book, and records the deviation). Why: the manifest is the authority for media types, for the `nav` and `cover-image` discovery, and for fallbacks of foreign resources (3.5.1). Citation: EPUB 3.3 5.6, 3.5.1; RS 5.4. Edge cases: duplicate `href`s after parsing (keep both ids, map to the same entry); `media-type` wrong for the bytes (sniff images and XHTML; prefer the sniffed type for rendering, record a diagnostic); an item with `properties="nav"` whose media type is not XHTML (ignore the property); more than one `nav` item (use the first in document order). Test: pkg-manifest-unknown, pub-foreign_image, pub-foreign_json-spine, pub-foreign_xml-spine, pub-foreign_bad-fallback.

**STD-10 Spine model.** The reader shall build the reading order from `itemref` elements in document order, skipping `itemref`s whose `idref` is not in the manifest (diagnostic) or whose target is neither an XHTML or SVG content document nor a foreign resource with a fallback chain to one, shall honour `linear="no"` as a hint that marks auxiliary content (reachable by link, skippable in sequential reading), shall keep duplicate references as distinct positions, shall read `page-progression-direction` (default `default`), and shall ignore unknown `properties` tokens (test pkg-spine-unknown). It shall require at least one usable spine item; a book with none fails with a clear reason. Why: RS 5.5 is explicit about order, duplicates, non-linear items and progression direction (tests pkg-spine-order, pkg-spine-duplicate-item-rendering, -ui, -hyperlink, pkg-spine-nonlinear-activation, pkg-spine-progression_ltr/_rtl/-default). Citation: EPUB 3.3 5.7; RS 5.5. Edge cases: a spine that lists the navigation document (render it as a page); a spine whose first items are all `linear="no"` (start at the first linear one); `page-progression-direction="rtl"` on a book whose content is left-to-right (keep the declared value for page turning, let text direction come from the content); an itemref to the NCX (skip, diagnostic, seen in the wild). Test: the pkg-spine-* tests and the Les Misérables cover wrapper (`linear="no"` on the first spine item).

**STD-11 Legacy features.** For EPUB 2 packages, and for EPUB 3 packages that lack a usable navigation document, the reader shall use the legacy features: the NCX named by `spine toc` (or the single manifest item of type `application/x-dtbncx+xml`), the `guide` element's `reference` entries as landmarks (`cover`, `title-page`, `toc`, `text`, `loi`, `lot`, `notes`, `index`, `glossary`, and `other.*`), and the OPF2 `meta name="cover" content="<item id>"` for the cover image. For conforming EPUB 3 packages that have a navigation document, legacy features shall not override it (RS 5.7), but the `guide` may still fill landmarks that the `landmarks` nav does not provide. Why: all eleven Gutenberg files are EPUB 2 and declare their cover only through `meta name="cover"`; six of them also put the cover JPEG itself in `guide type="cover"`, which EPUBCheck 5.4.0 flags as an error ("not a valid OPS Content Document") and which a reader must simply treat as an image reference. Citation: EPUB 3.3 5.9; OPF 2.0.1 2.4.1, 2.6; RS 5.7. Edge cases: `meta name="cover"` whose `content` is an href rather than an id (Standard Ebooks use `content="cover.jpg"`, which is an id that happens to look like a file name; try id first, then href); a `guide` entry pointing to an image; `spine toc` pointing at a missing item (search the manifest by media type). Test: the Gutenberg corpus; a fixture EPUB 3 with the `nav` item removed.

**STD-12 Collections and unknown package content.** The reader shall parse `collection` elements, keep those with roles it understands (none in version one), ignore the rest, and never fail on `bindings` or on unknown elements anywhere in the package. Why: RS 5.6 and test pkg-collections-unknown. Citation: EPUB 3.3 5.8, 5.6.3. Test: pkg-collections-unknown.

**STD-13 Rendering metadata.** The reader shall read `rendition:layout` (global and per-spine override), `rendition:flow` and its overrides, `rendition:orientation`, `rendition:spread`, `page-spread-left`/`right` and `rendition:align-x-center`, shall render reflowable content in the user's chosen flow mode regardless of the publisher's `rendition:flow` hint (RS 8.2.1 allows the user override; VoiceOver users need continuous scrolling), and shall detect pre-paginated spine items and render them as a single scaled page image of the content document's initial containing block (or, in version one, as flowed text with a diagnostic stating that the fixed layout was not honoured). It shall ignore everything in a `meta viewport` except the dimensions needed for fixed layout (RS 8.3). Why: the specification makes `rendition:flow` a preference, not a command, and Funston's accessibility choice is already to scroll under VoiceOver. Citation: EPUB 3.3 8.2, 8.3; RS 8.1, 8.2, 8.3. Edge cases: `rendition:layout` declared twice (first wins, RS 5.5.1 analogue); a spine item with both `rendition:layout-pre-paginated` and `rendition:layout-reflowable` (first wins). Test: lay-pkg-flow-paginated, lay-pkg-flow-scrolled-continuous, lay-pkg-flow-scrolled-doc, lay-rendition-flow-pre-pag, lay-viewport-meta-prop.

**STD-14 Property value expansion.** The reader shall interpret `property`, `properties`, `rel`, `scheme` and `epub:type` values as prefixed terms, split on the first colon, resolve declared prefixes from the `prefix` attribute of the document element first and reserved prefixes second, treat unprefixed terms as members of the default vocabulary for that attribute (structural semantics for `epub:type`, meta properties for `meta`, link vocabulary for `link`, item and itemref vocabularies for the manifest and spine), and treat a value beginning with a colon or an undeclared prefix as unknown rather than as an error. Why: Standard Ebooks use `z3998:` and `se:` prefixes declared on `html epub:prefix`; comparing expanded URLs is what makes `z3998:verse` recognizable regardless of the prefix chosen. Citation: EPUB 3.3 appendix D.1; RS 11. Test: the expansion algorithm vectors in section 9.

### Navigation

**STD-15 Navigation document processing.** The reader shall load the manifest item with the `nav` property, parse it as XHTML, and extract the `toc`, `page-list` and `landmarks` navs plus any other `nav` carrying an `epub:type`. For each `li` it shall produce an entry with a label (concatenated text of the `a` or `span`, with `alt`, then `title`, substituted for non-text descendants, whitespace collapsed), an optional target URL (absolute content URL plus fragment) and child entries from a following `ol`. The `hidden` attribute and CSS `display` shall be ignored when building the reader's own table of contents. Entries whose target does not resolve to a spine item (or a fragment inside one) shall be kept as unlinked headings with a diagnostic. The reader shall provide the table of contents whether or not the navigation document is in the spine, shall not display list numbering, and shall relocate the reading position when an entry is activated. Why: RS 7 lists these as MUST requirements; tests nav-access, nav-activation, nav-non-text_img, nav-non-text_img_title, nav-spine_in-spine, nav-spine_not-in-spine, nav-spine_in-spine-hidden-toc-css, nav-spine_in-spine-hidden-toc-html, nav-spine_in-spine-no-list-style. Citation: EPUB 3.3 7.2 to 7.5; RS 7. Edge cases: a `toc` nav whose `ol` contains `li` without `a` or `span` (take the li's own text); nested `ol` without a preceding label (treat as a continuation of the parent list); entries that link to resources outside the container in a custom nav (keep as external links); labels that are only an image without `alt` or `title` (label "Untitled section" and a diagnostic); a navigation document that is not well-formed XML (fall back to the NCX, then to a synthetic TOC). Test: the nav-* tests and both Standard Ebooks files (145 and 20 entries, two levels, exact agreement with their NCX).

**STD-16 NCX processing.** The reader shall parse the NCX's `navMap` into a tree (label from the first `navLabel/text`, target from `content src` resolved against the NCX's URL), shall parse `pageList/pageTarget` into page entries (label, `value`, `type`) and each `navList` into a named flat list, shall accept missing `playOrder` and ignore it when present (document order is the order), shall ignore `dtb:depth`, `dtb:totalPageCount` and `dtb:maxPageNumber` as advisory, and shall not require a DOCTYPE or validate against the DTD. When both a navigation document and an NCX exist, the navigation document is authoritative and the NCX is used only to fill a page list the nav lacks. Why: OPF 2.0.1 2.4.1.2 says reading systems "should" offer the navMap, pageList and navList and makes `playOrder` optional; Gutenberg books are NCX-only and one (Poems of the Great War) carries a 36-entry `pageList` with labels like "[Pg 4]". Citation: OPF 2.0.1 2.4.1, 2.4.2; Z39.86-2005 8.3, 8.4.3, 8.4.5. Edge cases: `navPoint`s whose `content src` points at anchors in files outside the spine (keep unlinked); labels with embedded newlines (the Poems NCX `docTitle` contains one); a `navMap` that covers only the license (Shiji, see STD-17); an NCX that is HTML-escaped or not well-formed (try the XML parser, then a forgiving parser, then give up with a diagnostic). Test: the Gutenberg corpus NCX files; a fixture NCX without `playOrder` and without DOCTYPE.

**STD-17 Synthetic navigation.** When the resulting table of contents has fewer than two entries that point into the body of the book, or when every entry points into a single spine item that is not the longest one, the reader shall build a synthetic table of contents from, in order of preference, the first `h1` to `h3` in each spine item, the `title` element of each spine item, and the spine position ("Section 3 of 23"). It shall label the result as generated. Why: the Shiji EPUB's NCX has six entries, all pointing at the Gutenberg license headings in the last file, while the 22 files of text have no headings at all and chapter titles are plain paragraphs; the Relativity EPUB has a single navPoint labelled "Start". Without a synthetic list VoiceOver users have no way to move through 2 MB of text. Citation: none (this is a leniency); RS 14 asks that users can "read from page-to-page and document-to-document" without getting trapped. Edge cases: spine items whose `title` is a single space (Shiji: `<title> </title>`); headings that repeat the book title in every file (Gutenberg puts the title on page one only). Test: pg24226 and pg30155 must get a usable list; Moby Dick must not get a synthetic one.

### Content documents

**STD-18 XHTML parsing.** The reader shall parse content documents as XML with a non-validating, namespace-aware parser that does not fetch external DTD subsets or external entities (RS 3.6, tests pub-xml-external-id, pub-xml-names), shall pre-declare the 253 XHTML 1.1 named character entities (`nbsp`, `mdash`, `eacute`, and so on) so that documents that use them without an internal DTD still parse, shall honour a leading BOM and the XML `encoding` declaration (falling back to UTF-8, then to Windows-1252 when the bytes are invalid UTF-8 and the document is EPUB 2), and shall, when XML parsing fails, re-parse with an HTML tag-soup parser that implements the HTML parsing algorithm's tree construction for the subset of elements the renderer knows, and record a diagnostic naming the file and the XML error. Why: the specification requires well-formed XML and the tests expect an "error" for an unclosed element, but RS 2.2 lets a reading system still load it, and Gutenberg's 2017 Ebookmaker emitted an invalid `tag` attribute on every link (121 EPUBCheck errors on Les Misérables) which no user should ever see as a refusal. Citation: EPUB 3.3 6.1.2, 3.9; RS 3.6; tests pub-xml-non-validating_unclosed, pub-xml-non-validating_comment, pub-xml-external-id, pub-xml-names. Edge cases: `&nbsp;` with no DOCTYPE; a DOCTYPE referencing the XHTML 1.1 DTD (never fetched); an `encoding="utf-8"` declaration followed by Latin-1 bytes; a `meta http-equiv` charset that disagrees with the XML declaration (the XML declaration wins); a document without the XHTML namespace (treat as XHTML with a diagnostic); CDATA sections; comments containing `--`. Test: the pub-xml-* tests plus a fixture with `&nbsp;` and no DOCTYPE, a fixture with a BOM, and a fixture that is HTML 4 tag soup.

**STD-19 Document semantics for rendering.** The reader shall interpret, at minimum, these HTML elements with their HTML semantics: `html`, `head`, `title`, `body`, `section`, `article`, `aside`, `nav`, `header`, `footer`, `main`, `div`, `p`, `h1` to `h6`, `hgroup`, `blockquote`, `pre`, `hr`, `br`, `ol`, `ul`, `li`, `dl`, `dt`, `dd`, `table`, `caption`, `thead`, `tbody`, `tfoot`, `tr`, `th`, `td`, `colgroup`, `col`, `figure`, `figcaption`, `img`, `picture` and `source` (choose the first candidate the renderer can decode), `a`, `span`, `em`, `strong`, `i`, `b`, `u`, `s`, `small`, `big`, `sub`, `sup`, `abbr`, `cite`, `q`, `code`, `kbd`, `samp`, `var`, `dfn`, `time`, `mark`, `ins`, `del`, `ruby`, `rt`, `rp`, `rb`, `bdi`, `bdo`, `wbr`, `details`, `summary`, `center` and `font` (as presentational blocks and inline runs), `svg` (inline, STD-26), `math` (STD-25), `audio`, `video`, `object`, `iframe` and `embed` (render their fallback content or a placeholder), `script`, `style`, `link`, `meta`, `template`, `noscript` (never rendered). The `hidden` attribute and `display: none` shall hide content from both the visual and the accessibility tree. `lang` and `xml:lang` shall be inherited down the tree and attached to every text run; `dir` and `bdo` shall set paragraph and inline direction. Why: this is the element set found across the corpus (see section 9) plus what EPUB 3.3 6.1 inherits from HTML. Citation: EPUB 3.3 6.1.2 ("inherit all definitions of semantics, structure, and processing behaviors from HTML"); RS 6.1. Edge cases: `<br/>` runs used as line breaks inside paragraphs for verse and addresses (Gibbon: 1356 `br` in six files; the Factbook: every record is a paragraph of `br`-separated lines); `<p>` elements that contain only `<br/>` as vertical space (Elektra); block elements nested inside `<p>` (tag soup; close the paragraph); `<table>` used purely for layout (Gutenberg title blocks and tables of contents, Standard Ebooks drama); `<img>` inside `<p class="titleblock">`; `<a id="x"/>` empty anchors as link targets (Gibbon chapter anchors). Test: render each corpus file and compare the extracted text order to the XML text order; check that no visible text is lost.

**STD-20 Structural semantics.** The reader shall read `epub:type` (expanded per STD-14) and ARIA `role` on every element and shall recognize at least: `noteref` / `doc-noteref`; `footnote`, `endnote`, `rearnote`, `footnotes`, `endnotes`, `rearnotes` / `doc-footnote`, `doc-endnote`, `doc-endnotes`; `backlink` / `doc-backlink`; `pagebreak` / `doc-pagebreak` with `aria-label` or `title` as the page label; `toc`, `landmarks`, `page-list`, `loi`, `lot` / `doc-toc`, `doc-pagelist`; `frontmatter`, `bodymatter`, `backmatter`; `cover`, `titlepage`, `halftitlepage`, `imprint`, `colophon`, `copyright-page`, `dedication`, `epigraph` / `doc-epigraph`; `part`, `chapter`, `subchapter`, `division`, `volume` / `doc-part`, `doc-chapter`; `title`, `subtitle`, `bridgehead`, `fulltitle`, `covertitle` / `doc-subtitle`; `glossary`, `glossterm`, `glossdef`, `index`, `bibliography`, `biblioentry` / `doc-glossary`, `doc-index`, `doc-bibliography`; `aside`, `sidebar`, `annotation`, `marginalia`; `table`, `table-row`, `table-cell`, `list`, `list-item`, `figure`; `z3998:verse`, `z3998:poem`, `z3998:song`, `z3998:hymn`, `z3998:stanza`, `z3998:drama`, `z3998:persona`, `z3998:stage-direction`, `z3998:letter`, `z3998:salutation`, `z3998:signature`. Unknown terms are kept as strings for diagnostics and ignored otherwise. Why: EPUB 3.3 appendix C says `epub:type` is for reading-system enhancements, not for assistive technology, which is exactly Funston's situation: the renderer owns the accessibility tree and can turn these into VoiceOver behaviour (section 7). Citation: EPUB 3.3 6.1.3.1, appendix C; EPUB SSV 1.1; DPUB-ARIA 1.1; RS 10. Edge cases: `epub:type` on `head` descendants (ignore, 6.1.3.1); conflicting `epub:type` and `role` (prefer `role`, since it is what the author intended assistive technology to see); `epub:type="noteref"` on an element that is not a link (treat as text). Test: pss-support and pss-support_ignore-title; the Standard Ebooks endnotes (22 noterefs, 22 endnotes with backlinks).

**STD-21 CSS support.** The reader shall parse author style sheets (linked through `link rel="stylesheet"`, embedded in `style`, and inline `style` attributes), resolve `@import` recursively against the stylesheet's URL (missing imports are a diagnostic, not a failure), evaluate `@media` with `screen`, `all`, `prefers-color-scheme` and `(orientation)` only, and compute a cascade for the properties that map to TextKit 2 and to the renderer's layout model: `display` (block, inline, none, list-item, table family, inline-block), margins and paddings, `text-indent`, `text-align` and `text-align-last`, `line-height`, `font-family`, `font-size` (absolute, relative, percentages, keywords), `font-style`, `font-weight`, `font-variant` (small-caps), `color`, `background-color` (block-level only), `text-decoration`, `text-transform`, `letter-spacing`, `word-spacing`, `white-space`, `hyphens` and `-epub-hyphens`, `page-break-before/after/inside` and `break-*` (as section and keep-together hints), `list-style-type`, `vertical-align` (sub, super), `width` and `max-width` for images, `float` for figures (as block placement, not true floats, in version one), `visibility`, `writing-mode` and `-epub-writing-mode` (vertical text may be unsupported in version one and then reported). It shall ignore `direction` and `unicode-bidi` in author CSS (6.3.1.2). User settings for font size, line spacing, alignment, margins and colour theme shall be applied as a user-agent override that preserves the cascade's relative sizes (a `font-size: smaller` footnote stays smaller after a Dynamic Type change). When the user turns off publisher styles, structural defaults still apply (headings, lists, tables, blockquote indentation, `pre` monospace). Why: RS 6.3 says to apply creator style sheets as written where supported, not to override them except by a user-agent style sheet or user interaction, and to support TrueType, OpenType, WOFF and WOFF2 in `@font-face`; the `-epub-` properties in appendix E are SHOULD-support. Gutenberg CSS is small and presentational (`.pagenum`, `.figcenter`, `.blockquot`, `hr.chap`); Standard Ebooks CSS relies on attribute selectors `[epub|type~="..."]` with an `@namespace epub` declaration in the advanced build and on generated classes `epub-type-contains-word-...` in the compatible build, so the selector engine must support `@namespace` and attribute namespace selectors or the advanced build loses all semantic styling. Citation: EPUB 3.3 6.3.1, appendix E; RS 6.3. Edge cases: `@charset`; a `@page` rule (ignore); `!important` in author CSS (honoured within the author origin, still below user overrides); CSS that sets `color: black; background: white` on body (Gutenberg `pgepub.css`), which must not defeat dark mode (user colour overrides win for `color` and `background-color`); `font-size: 12pt` on everything (Relativity, Word export); `margin: 15%` on `p` (Gibbon, which on a phone leaves a 70 percent column; clamp horizontal margins and paddings to a fraction of the viewport); `position: absolute` page numbers (Gibbon `.pagenum`; render inline as a skippable element instead). Test: the css-epub-* tests for the prefixed properties the renderer supports; cnt-css-fonts_tt, _ot, _woff, _woff2; a fixture that imports a missing stylesheet; both Standard Ebooks builds must render verse with hanging indents.

**STD-22 Fonts.** The reader shall load `@font-face` sources from the container (after deobfuscation), accept TrueType, OpenType, WOFF and WOFF2, register them per book for the lifetime of the reading session only, fall back to the user's or system font when a face is missing, unreadable or protected, and allow the user to replace all book fonts with a system font. Why: RS 6.3 requires the four formats; Funston's low-vision use needs reliable font replacement; corpus books embed no fonts, Standard Ebooks rely on system fonts, so missing-font paths will be exercised by the W3C fixtures and the Waste Land samples. Citation: EPUB 3.3 3.2 (core media types), 4.4; RS 6.3. Edge cases: `font-family` names that collide with system fonts; a WOFF2 that fails to decode (diagnostic, fall back); `local()` sources (ignore). Test: cnt-css-fonts_*, wasteland-otf, wasteland-woff, wasteland-otf-obf, wasteland-woff-obf.

**STD-23 Images and other embedded resources.** The reader shall decode GIF, JPEG, PNG, SVG and WebP images referenced from `img`, `picture/source`, `svg image`, CSS `background-image` (block backgrounds only) and `object`, shall render `alt` text (or a labelled placeholder when `alt` is absent) for an image that is missing, undecodable or a foreign type without a usable fallback, shall never fetch remote resources without the user's consent (RS 3.3, 3.8; test sec-untrusted-consent_network), shall never open `data:` URLs as top-level documents (RS 3.4) and shall never load `file:` URLs (RS 3.5). Why: the Gutenberg "images" editions reference 5 to 63 images each; Relativity uses 63 small GIF and JPEG equation images inline, which must render at their intrinsic size scaled with text; Alice uses `srcset` with 2x candidates. Citation: EPUB 3.3 3.2, 3.6, 3.7, 3.8; RS 3.1, 3.3, 3.4, 3.5. Edge cases: `width`/`height` attributes in pixels on `img` (treat as CSS pixels at the book's base size, cap to the column width); an image larger than the viewport (fit to width, keep aspect); animated GIF (first frame); SVG with external references (do not follow); an image with `alt=""` (decorative, hidden from VoiceOver); an image whose `alt` is "emblem" or "Cover" (announce as is). Test: pub-cmt-gif, -jpeg, -png, -svg, -webp (avif and jxl may fail with a placeholder), pub-data-urls_browsing-context, pub-file-urls, sec-untrusted-consent_network, pkg-manifest-unlisted-resource.

**STD-24 Scripting and forms.** The reader shall not execute scripts, shall treat documents with the `scripted` property like any other, shall render the intrinsic fallback content of `canvas` and `object` and the content of `noscript` (HTML shows `noscript` content when scripting is disabled, which is Funston's permanent state), and shall present form controls as static text of their labels and values. Why: RS 6.4 says reading systems SHOULD support scripting but MUST process fallbacks when they do not; Funston's TextKit renderer has no script engine and VoiceOver users gain nothing from Trees' canvas. Citation: EPUB 3.3 6.3.2, 6.3.2.5; RS 6.4. Test: scr-support-fallback (the fallback must show), sec-untrusted-consent_scripting (nothing runs), trees sample (the no-canvas text shows).

**STD-25 MathML.** The reader shall detect `math` elements, render Presentation MathML when a renderer is available, and otherwise show the `alttext` attribute, the `annotation` text content, or a linearized reading of the presentation tree, and mark the element for VoiceOver as math with that text. Why: RS 6.1.2.2 requires visual rendering of Presentation MathML for reading systems with a viewport; version one cannot promise a full renderer, so the fallback text path is the correctness floor. Citation: EPUB 3.3 6.1.4.1; RS 6.1.2.2. Test: cnt-mathml-support (expected to fail visually in version one, pass on the text fallback), the linear-algebra sample.

**STD-26 SVG.** The reader shall render SVG referenced from `img` through the system image decoder, shall render inline `svg` as an image of its own bounding box with the containing document's CSS applied (RS 6.1.2.3.1) or, where that is not available in version one, as a placeholder carrying the `svg title` or `desc`, and shall treat an SVG spine item as a single page image with its `title` as the accessible label. Why: RS 6.2 requires processing SVG content documents; Standard Ebooks' advanced build uses SVG for the title page and cover. Citation: EPUB 3.3 6.2, 6.1.4.2; RS 6.2, 6.1.2.3. Test: cnt-svg-support, cnt-svg-embedded, cnt-svg-css-inclusion, cnt-svg-css-reference, pkg-spine-order-svg.

**STD-27 Links and fragments.** The reader shall resolve `a href` targets per STD-05, shall navigate to the first spine occurrence of the target document (RS 5.5) and then to the element with the matching `id` (also matching `a name` in EPUB 2 content), shall open hyperlinks to non-linear spine items in place, shall ask before opening `http`, `https`, `mailto` and other external schemes (RS 3.9) and shall never follow `javascript:` links. A fragment that does not exist in the target shall land at the top of the document with a diagnostic. Why: footnote back-links, Gibbon's chapter table of contents and Standard Ebooks noterefs all depend on fragment navigation; `a name` anchors are common in older Gutenberg HTML. Citation: EPUB 3.3 5.7.1; RS 3.9, 5.5. Test: pkg-spine-duplicate-item-hyperlink, pkg-spine-nonlinear-activation, pub-external-links, pub-external-links_consent, the internallinks sample.

**STD-28 Media overlays.** The reader shall parse `application/smil+xml` items enough to validate their structure (smil, head, body, seq, par, text, audio with `clipBegin`/`clipEnd` clock values) and the `media:duration`, `media:narrator`, `media:active-class` and `media:playback-active-class` metadata, shall ignore them for rendering in version one (RS 9 requires ignoring the `media-overlay` attribute and SMIL items when overlays are unsupported), and shall record their presence so the UI can say "narration available but not supported". Why: ignoring must be silent to the user and must not break the book (test mol-ignore). Citation: EPUB 3.3 9; RS 9. Test: mol-ignore; moby-dick-mo and cc-shared-culture samples open and read as text.

**STD-29 Fixed layout detection.** The reader shall detect `rendition:layout: pre-paginated` globally or per spine item and shall present such items as scaled page images when the content is an image or SVG, or as flowed text with a diagnostic otherwise. Why: fixed layout is out of scope for the text renderer but must not produce a blank or crash. Citation: EPUB 3.3 8.2; RS 8.1. Test: page-blanche and sous-le-vent samples open; the lay-fxl-* and lay-pp-* tests are reported as not applicable.

### Locations and positions

**STD-30 EPUB CFI.** The reader shall parse, generate, compare and resolve EPUB CFIs as defined in section 5 of this study: the full grammar of CFI 1.1 section 2.2, circumflex escaping, step semantics over element children (even indices) and character-data chunks (odd indices, including the virtual 0 and n+2 elements), indirection through `itemref` and `iframe`/`object`/`embed`/SVG `image` and `use`, character offsets in UTF-16 code units, temporal and spatial offsets, ID and text-location assertions, side bias, vendor parameters, ranges, the sorting rules of 3.2, and intent-preserving correction of 3.5. Generated CFIs shall include ID assertions for every element that has an `id` and a text assertion of up to 32 characters before and after a character offset. Why: CFI is the only standardized position scheme, it is what Readium already stores inside `locations.cfi`, and its sorting rules make bookmarks orderable without opening the book. Citation: EPUB CFI 1.1, 2.2, 2.3, 3.1 to 3.5, 4. Edge cases: a CFI whose spine step points past the end of the spine (invalid, fall back to the href); a CFI whose ID assertion fails but whose element exists elsewhere (correct by ID); a text assertion that no longer matches (search the document for the before/after text near the step, else treat the CFI as invalid and fall back to progression); a terminal odd step without offset (read as `:0`); an element step with a character offset that is not an `img` (reject); a UTF-16 offset that splits a surrogate pair (round down); `s=b` on a location at a page boundary (keep the location on the preceding page). Test: the vectors in section 9; the georgia-cfi sample's page-list CFIs; round-trip every generated CFI through parse and serialize.

**STD-31 Position persistence and migration.** The reader shall persist a reading position as a locator record containing the spine item's href (container-relative), a CFI into that document, a progression fraction in the document, a total progression fraction in the book, and a text context (up to 64 characters before and after the position), and shall resolve a stored position by CFI first, by text context second and by progression last, in that order of trust. It shall read the existing Readium `Locator` JSON rows in `book_positions` (fields `href`, `type`, `title`, `locations.progression`, `locations.totalProgression`, `locations.position`, `locations.cfi` when present, `text.before`, `text.highlight`, `text.after`) and migrate each to the new record on first open, keeping the old JSON until the new record has been written. Why: switching renderers must not lose anyone's place; Readium's `cfi`, when present, is a standard CFI and resolves directly, and its `progression` is a usable fallback. Citation: EPUB CFI 1.1 3.5 (correction); no normative source for the record itself. Edge cases: a stored `href` that no longer matches any spine item after a re-download of a different edition (fall back to `totalProgression`); a `cfi` that Readium wrote with its own extensions (parse per section 4 of CFI 1.1, ignore unknown parameters); a position in a non-linear item. Test: migration fixtures built from real `Locator` JSON captured from the current app, one per field combination.

### Accessibility

**STD-32 Reading order exposure.** The renderer shall expose to VoiceOver one accessibility element per block-level unit (paragraph, heading, list item, table cell, figure caption, verse line group, `pre` block or line within it when long) in document order, tethered to that unit's on-screen frame, with the unit's text as the label, the heading level as a trait and value ("Heading level 2"), the unit's language as the element's language for pronunciation, and links, note references and page breaks as separate elements inside or beside the block so they appear in the Links rotor and can be activated. Off-screen units shall not be exposed until scrolled into view, as the PDF reader does. Why: this is the house style set by `PDFLineAccessibility.swift`, and RS 14 lists "API integration" and "reading control" among the reading system's accessibility obligations. Citation: RS 14; EPUB a11y 1.1 3.4 (page navigation objectives). Edge cases: a paragraph longer than a screen (split into line groups while keeping one logical element for the rotor, or expose by line as the PDF reader does); inline `img` elements (announce `alt` inline); `br`-separated verse (one element per stanza paragraph with line breaks preserved in the spoken text); table rows (announce row and column position when the table has headers). Test: run VoiceOver on the simulator against Moby Dick chapter 1, Man and Maid chapter 1, the Factbook record pages and Poems of the Great War, checking focus order, no empty elements, correct heading levels and that links appear in the rotor. This cannot be signed off from code reading.

**STD-33 Notes.** When a `noteref` (or `doc-noteref`) link is activated, the reader shall present the target note's content in place (a popover or a sheet whose first element is the note text and whose last element is a "Return" action that moves focus back to the reference), shall offer the note's `backlink` as that return path, shall announce note references as "note N, link", and shall offer a setting to skip notes and page numbers in continuous reading (the skippability semantics of EPUB 3.3 9.4.1 applied to text reading). Why: pss-support tests footnote popups; Standard Ebooks and Gutenberg both link notes but in opposite directions (end-of-book list versus end-of-chapter blocks); without a return path a VoiceOver user is stranded in the notes file. Citation: EPUB 3.3 9.4.1 (skippable structures), appendix C; DPUB-ARIA `doc-noteref`, `doc-footnote`, `doc-endnote`, `doc-backlink`; EPUB a11y 1.1 3.4.2.3.3. Edge cases: a note whose target id is on an `a` inside a `p` (Les Misérables: `<a id="Footnote_1_1"/>` as the first child of the note paragraph; take the enclosing block as the note body); a note target in the same file versus another file; Gutenberg books whose footnote markers are bare asterisks with no link (nothing to do; see section 9). Test: pss-support; Moby Dick note 1 to its backlink and back; Les Misérables note 1.

**STD-34 Page list and landmarks.** The reader shall expose the page list (from the `page-list` nav, else the NCX `pageList`, else `pagebreak` elements found in content) as a "Go to page" action and announce page breaks in reading as a skippable element whose label is the page label, and shall expose landmarks (from the `landmarks` nav, else the `guide`) as a short menu, using `bodymatter` to offer "Start reading" past the front matter. Why: EPUB a11y 1.1 3.4.1 makes page navigation the primary way to coordinate locations with print; RS 7 says a reading system SHOULD provide navigation to listed page breaks. Citation: EPUB 3.3 7.4.3, 7.4.4; RS 7; EPUB a11y 1.1 3.4.1; Z39.86-2005 8.4.5. Edge cases: page labels that are roman numerals or "[Pg 4]" (announce as written); Gutenberg `span.pageno` elements with the number in a `title` attribute and no text (use `title`); duplicate page labels (keep both, ordered). Test: the Poems of the Great War pageList (36 targets); the georgia sample page-list; Man and Maid's 327 `pageno` spans.

**STD-35 Accessibility metadata.** The reader shall read `schema:accessMode`, `schema:accessModeSufficient`, `schema:accessibilityFeature`, `schema:accessibilityHazard`, `schema:accessibilitySummary`, `dcterms:conformsTo` (matching the pattern `EPUB Accessibility 1.1 - WCAG 2.x Level A|AA|AAA`), `a11y:certifiedBy`, `a11y:certifierCredential` and `a11y:certifierReport`, and shall show them on the book's detail screen in words ("Conforms to WCAG 2.2 level AA, certified by Standard Ebooks", "No accessibility metadata"), never as raw tokens. Why: EPUB a11y 1.1 section 2 requires this metadata of publications so that readers can judge suitability; Standard Ebooks ship it; Gutenberg ships none, and "none declared" is itself information for a blind reader. Citation: EPUB a11y 1.1 2.2, 3.5.2, appendix A. Edge cases: metadata in a linked ONIX record only (not required to process; ignore); hazards "none" versus "unknown" versus absent (three different statements). Test: Moby Dick and Alice metadata; an EPUB 2 book shows "none declared".

**STD-36 Image text alternatives.** The reader shall announce `alt` for every content image, `figcaption` as a separate caption element, `aria-describedby` and `longdesc` targets as "description available" actions, treat `alt=""` and `role="presentation"` as decorative (hidden), and announce an image with no `alt` as "image" plus its file name without extension. Why: EPUB a11y 1.1 relies on WCAG 1.1.1; Gutenberg images have `alt=""` on equation images (Relativity), which hides 63 equations from VoiceOver; the detail screen should warn when a book has many images without text alternatives. Citation: EPUB a11y 1.1 3.2, 3.3; HTML `alt` semantics. Edge cases: `alt` identical to `figcaption` (announce once); `alt` that is a file name (announce as is). Test: Alice chapter 1 figure; Relativity equation images.

**STD-37 Structure announcements.** The reader shall announce list starts and ends, list item ordinals when the list is ordered, table starts with row and column counts and header cells, blockquote starts, and headings with their level, and shall keep these containers intact under VoiceOver (no fragmentation of a list into unrelated elements). Why: Camden's standing rule that container boundaries are invariants; EPUB content is rich in lists and tables (Standard Ebooks drama uses tables; Gutenberg uses them for title blocks and contents). Citation: RS 14; WCAG 1.3.1 through EPUB a11y 1.1 3.3. Test: the Moby Dick table of contents in the spine of the childrens-literature sample; the Man and Maid title table.

**STD-38 User display control.** The reader shall provide text size following Dynamic Type, line spacing, paragraph spacing, horizontal margins, text alignment (start by default, as the current reader does), font replacement, a colour theme (system light and dark plus a sepia and a high-contrast option), and a publisher-styles switch, and shall apply them as a user-agent override that preserves the author cascade (RS 6.3). It shall never require a horizontal scroll for text and shall reflow when the size changes while keeping the reading position (by CFI). Why: RS 14 lists display control and zoom; the existing reader maps Dynamic Type to a font scale and aligns to the leading edge for low vision. Citation: RS 6.3, 14. Test: change size and theme on each corpus book and confirm the CFI-restored position is within one line of the previous one.

### Failure behaviour

**STD-39 Diagnostics and degradation.** Every parse decision that deviates from the specification (a leniency applied, a missing resource, a non-well-formed document, an unknown version) shall be recorded as a diagnostic with a severity, the file path and a one-sentence reason, shall be visible to the user on demand (a "Problems with this book" list) and in logs, and shall never by itself prevent the book from opening when at least one spine document can be read. A spine document that cannot be read at all shall be shown as a page saying so, in sequence, so that the reading order is preserved. Why: RS 2.3 encourages error reporting; Funston's rule is that a render path fails loud into a diagnostic, never blank. Citation: RS 2.2, 2.3. Test: each leniency fixture in section 8 yields exactly the expected diagnostic.

**STD-40 Resource limits.** The reader shall enforce limits before decoding: a per-entry decompressed size cap and a whole-book cap derived from available memory (the host is a 16 GB Mac for tests but the target is an iPhone), an XML nesting depth cap, an entity-expansion cap (reject documents whose internal DTD subset defines entities that expand more than a small multiple of their text), a cap on the number of ZIP entries, and a time budget per document after which parsing yields with a diagnostic. It shall parse spine items lazily and keep only the current and adjacent documents in memory. Why: the Factbook has 63 documents of 190 KB and 11.9 MB of XHTML in total; the Shiji has 23 documents of 94 KB; a decompression bomb or a billion-laughs document is a two-line attack on a parser that trusts the archive. Citation: RS 15 (threat model: "an attack against the reading system itself"). Test: a fixture whose `mimetype` entry claims 4 GB; a fixture with a 1000-deep element nest; a fixture with an exponentially expanding entity.

**STD-41 Security boundaries.** The reader shall load no remote resource without explicit consent (and then only `https`), shall open no `file:` URL, shall execute no script, shall never write a decompressed file outside its own cache directory, shall treat every ZIP entry name as data (no path traversal into the cache: normalize and reject `..` segments and absolute names when extracting to disk), and shall treat text found in books, including instructions in metadata or content, as content to display, never as commands. Why: RS 15 and 3.8; the clean-room reader has no browser sandbox between it and the file system. Citation: RS 3.3, 3.5, 3.8, 15. Test: pub-file-urls, sec-untrusted-consent_network, a fixture with an entry named `../../x`.

## 5. Algorithms

### 5.1 Opening the container

1. Read the last 22 bytes; if the end-of-central-directory signature (0x06054b50) is not there, scan backwards through at most 65535 bytes of comment. If the entry count or offsets are 0xFFFF or 0xFFFFFFFF, read the Zip64 locator and the Zip64 end-of-central-directory record (APPNOTE 4.3.14, 4.3.15).
2. Walk the central directory. For each entry record name (decoded as UTF-8 when bit 11 is set, otherwise attempt UTF-8 and fall back to code page 437), compression method, flags, sizes, CRC and local header offset, and the Zip64 extra field (0x0001) when sizes are 0xFFFFFFFF. Entries ending in `/` are directories: skip. Duplicate names: keep the last, record a diagnostic.
3. To read an entry, seek to its local header, skip the variable name and extra field lengths found in the local header (not the central one), and inflate or copy. Do not trust the local header's sizes when bit 3 is set; use the central directory's.
4. Sniff: the first entry named `mimetype`, method 0, content `application/epub+zip`. Any deviation is a diagnostic.
5. Read `META-INF/container.xml`, pick the rootfile, parse the package (section 5.3), then the navigation sources (section 5.4). Content documents are parsed on demand.

### 5.2 Font deobfuscation

IDPF algorithm (EPUB 3.3 4.4.3 and 4.4.4), verified against the W3C test font:

```
key   = SHA1(utf8(strip_xml_whitespace(unique_identifier)))      // 20 bytes
for i in 0 ..< min(1040, font.count):
    font[i] ^= key[i % 20]
```

`strip_xml_whitespace` removes U+0020, U+0009, U+000D and U+000A anywhere in the string (not only at the ends). The identifier is the text of the `dc:identifier` named by `package unique-identifier`, after the ordinary whitespace collapsing of metadata values, including any `urn:uuid:` prefix. XOR is its own inverse, so one routine obfuscates and deobfuscates. Apply it to the decompressed bytes of the font. Then check the sfnt header: the first four bytes must be `00 01 00 00` (TrueType), `OTTO` (CFF OpenType), `true` (Apple TrueType), `wOFF` or `wOF2`, and the table directory must be plausible (numTables below 64, four-character ASCII tags). If the check fails, record a diagnostic and use fallback fonts.

Verified vector (W3C test ocf-font_obfuscation, identifier `ocf-font_obfuscation`, font `EPUB/fonts/Lobster.ttf`, 101356 bytes):

| Quantity | Value |
| --- | --- |
| SHA-1 key | `b562e83e1606579a9c6c70a75f4a14d2ea36b09e` |
| first 20 obfuscated bytes | `b563e83e1617569a9c6870b7180e5194ea39b084` |
| first 20 deobfuscated bytes | `00010000001101000004001047444546000f001a` |
| decoded | sfnt version 1.0, 17 tables starting with GDEF, GPOS, GSUB, OS/2, cmap |

The companion test ocf-font_obfuscation_bis ships a byte-identical font under identifier `ocf-font_obfuscation-bis` (key `67f12bb4...`); deobfuscating with that key yields `d292c38a...` and a nonsense table count of 858. A reader must therefore detect the failed header and fall back rather than render garbage. Both fonts decode correctly with the first key, which is the point of the test: the key comes from the identifier, not the file.

Adobe variant (algorithm URI `http://ns.adobe.com/pdf/enc#RC`), as commonly documented but not verified against an Adobe specification during this study: the key is the 16 raw bytes of the UUID in the unique identifier (strip a `urn:uuid:` prefix and hyphens, decode the 32 hex digits), and the XOR covers the first 1024 bytes of the font, cycling through the 16-byte key. When the identifier is not a UUID the variant has no defined key. Implement it behind the same sfnt-header check so a wrong guess fails safely. Standard Ebooks and Gutenberg embed no fonts, so this path will not be exercised by the main corpus.

Pre-3.0.1 ambiguity: EPUB 3.0 did not say whether to obfuscate before or after compression. RS 4.3 notes that deobfuscating the still-compressed bytes and then inflating may recover such fonts. Try this only after the normal order fails the header check.

### 5.3 Package and property processing

Property expansion (RS 11): split the value at the first colon; a value that starts with a colon is invalid. With no prefix, the base URL is the default vocabulary for the attribute: `http://idpf.org/epub/vocab/structure/#` for `epub:type`, `http://idpf.org/epub/vocab/package/meta/#` for `meta property`, `http://idpf.org/epub/vocab/package/link/#` for `link rel` and `properties`, `http://idpf.org/epub/vocab/package/item/#` for manifest `properties`, `http://idpf.org/epub/vocab/package/itemref/#` for spine `properties`; `scheme` has no default and an unprefixed scheme is invalid. With a prefix, look first in the document element's `prefix` (or `epub:prefix` on `html`) declaration, which is a whitespace-separated list of `name: URL` pairs, then in the reserved prefixes (`a11y`, `dcterms`, `marc`, `media`, `onix`, `rendition`, `schema`, `xsd`, `msv`, `prism`). Concatenate base URL and reference with no separator. Compare expanded URLs, not raw tokens.

Fallback chain resolution (RS 5.4): starting at a manifest item, if its media type is renderable stop; otherwise follow `fallback`; stop with failure at the first item already visited or at an item without `fallback`.

Cover discovery: manifest item with `cover-image` property; else the item named by OPF2 `meta name="cover"` (`content` as id, then as href); else the `guide reference type="cover"` target (if it is an image, use it; if it is an XHTML document, use the first `img` in it); else the first image whose href contains "cover". Record which rule fired.

### 5.4 Navigation merge

1. If a navigation document exists and parses, its `toc` nav is the table of contents, its `page-list` the page list, its `landmarks` the landmarks.
2. Else if an NCX exists and parses, `navMap` is the table of contents, `pageList` the page list, each `navList` an extra list; the `guide` supplies landmarks.
3. If a nav exists but has no `page-list`, and the NCX has a `pageList`, use the NCX page list. If a nav has no `landmarks`, use the `guide`.
4. Normalize every target to (spine index, fragment id or nil). Targets outside the spine become unlinked entries.
5. Apply the synthetic-TOC rule (STD-17) when the merged table of contents does not cover the body.
6. Label extraction: concatenate descendant text nodes; for `img` use `alt`, else `title`; collapse whitespace; if empty, use the entry's `title` attribute; if still empty, "Untitled section" plus a diagnostic.

### 5.5 Href and fragment resolution

Given a reference string `ref` found in a document whose content URL is `base`:

1. If `ref` has a scheme: `http`/`https` are external (consent before opening, never fetched as resources without consent); `data` is allowed for `img`/`source`/CSS images only; `file`, `javascript` and others are refused. Stop.
2. Split off `#fragment` and `?query` (query is dropped with a diagnostic; the container has no query semantics).
3. Parse the remainder with the WHATWG URL parser against `base`. The container root URL has the properties of EPUB 3.3 4.2.5, so leading slashes and excess `..` resolve to paths under the root. Record a diagnostic when either happened.
4. Percent-decode the path (UTF-8). Look up the ZIP entry by exact path; then by NFC form; then by NFD form; then case-insensitively; then with `\` and `/` swapped. Record a diagnostic when a fallback matched.
5. For a spine target, map the entry to the first spine index that references it (RS 5.5). For the fragment, find the element with that `id`, else an `a name` with that value, else the document start with a diagnostic.

Worked vectors are in section 9.

### 5.6 EPUB CFI

Grammar (CFI 1.1 section 2.2, EBNF): `fragment = "epubcfi(" path [ range ] ")"`; `path = step local_path`; `range = "," local_path "," local_path`; `local_path = { step } ( redirected_path | [ offset ] )`; `redirected_path = "!" ( offset | path )`; `step = "/" integer [ "[" assertion "]" ]`; `offset = ( ":" integer | "@" number ":" number | "~" number [ "@" number ":" number ] ) [ "[" assertion "]" ]`; `assertion = ( value [ "," value ] | "," value | parameter ) { parameter }`; `parameter = ";" value-no-space "=" csv`. Integers have no leading zeros; numbers have no trailing zeros in the fraction, zero is `0`, and fractions below one start with `0.`. Inside assertions the characters `^ [ ] ( ) , ; =` are escaped with a leading circumflex. Allowed characters are the XML character set.

Step semantics (3.1.1): children of an element are indexed so that element children get even indices 2, 4, 6, ... and the (possibly empty) character-data chunks between, before and after them get odd indices 1, 3, 5, ... Comments and processing instructions are ignored; CDATA counts as character data; entity references are expanded; insignificant whitespace is preserved as character data. Index 0 names a virtual element before the first chunk and n+2 one after the last (n is the last even index), and processors must accept both. A standard CFI starts with an even step that selects the `spine` element from the `package` root (in every real OPF `spine` is the third element child, so `/6`), then an even step selecting an `itemref` (`/4` for the second itemref), then `!` for indirection through the manifest item's href, then steps from the `html` root of that document. The indirection list is closed: `itemref` through the manifest, `iframe` and `embed` through `src`, `object` through `data`, SVG `image` and `use` through `xlink:href`. Hyperlinks (`a`) are never followed.

Offsets (3.1.4 to 3.1.7): `:n` after an odd step is a character offset in UTF-16 code units between characters, 0 before the first; a character offset after an even step is legal only for `img` with `alt` text. A terminal odd step with no offset means `:0`. `~t` is seconds into timed media; `@x:y` is a percentage position in an image or video, 0 to 100 each; `~t@x:y` combines them with the temporal part first.

Assertions (3.1.2, 3.1.8, 3.1.9): `[id]` after an element step records the element's `id` and must be included when the element has one. `[before,after]` after a character offset records text immediately before and after the point, with element boundaries ignored and whitespace collapsed; `[,after]` when there is no preceding text. `;s=b` or `;s=a` is side bias, always inside the final bracket. Other parameters are vendor extensions (`vnd.` prefix recommended) and must be ignored when not understood (section 4).

Sorting (3.2): unescape; drop every bracketed assertion; compare step by step, earlier steps more important; element indices, character-data indices, character offsets and temporal values compare numerically; for spatial offsets y is more important than x; an omitted spatial or temporal position sorts before a present one; temporal is more important than spatial; when the step kinds differ at the same position the order from least to most important is character offset `:`, child step `/`, temporal-spatial `~` or `@`, indirection `!`. A path that is a strict prefix of another sorts first (the start of an element precedes positions inside it). Ranges compare by their start location then their end location. Side bias and other parameters never affect ordering.

A practical comparator flattens each CFI into a key: a list of (kind, value) pairs where kind is one of `/`, `!`, `:`, `~@`, the value of `!` is 0, the value of `~@` is the triple (t or -1, y or -1, x or -1), and a terminal odd step with no offset appends (`:`, 0). Compare pairwise: different kinds order by the rank above, equal kinds by value, and the shorter key first when one is a prefix. The clean-room parser written for this study produced the 21 orderings in section 9 with this rule.

Ranges (3.4): `epubcfi(P,S,E)` where P is the deepest common parent path and S and E are relative; P must end at a step, not an offset; S and E must resolve in non-decreasing order; a range used where a point is expected yields its start; side bias is not allowed in ranges.

Intent-preserving resolution (3.5): while walking a CFI, check each ID assertion against the element reached; on mismatch search the document for an element with that `id` and continue from it, producing a corrected CFI. After reaching the character offset, check the text assertion; on mismatch search nearby text for the before/after strings and correct. If an assertion fails and no correction is possible, the CFI is invalid; the caller then falls back to the locator's text context and progression (STD-31). If the document's ids are not available at processing time the assertions are ignored, not treated as failures.

Generation (3.1.10 guidance): for a text location, start from the character-data chunk that contains the point, record the chunk's odd index and UTF-16 offset, then walk up through ancestors recording even indices and ids, cross the `!` into the package with the itemref index and id, and end at `/6`. Add a before/after text assertion of up to 32 characters, whitespace collapsed. Never emit `/0` or `/n+2` for a chunk that exists; refer to the real first or last element instead.

### 5.7 Text extraction for VoiceOver and search

For each block unit, build the spoken string from text nodes in document order, honoring `white-space: pre` for `pre` blocks, turning `br` into a line separator, dropping text in `hidden` or `display: none` subtrees, replacing `img` with its `alt`, attaching the inherited language to each run, and recording for each run the (spine index, CFI) of its first character so that a search hit or a VoiceOver focus can be converted back to a position.

## 6. Data model and persistence

The models below are what a reader needs to hold after parsing. Names are descriptive, not prescriptive; the merged spec decides Swift types.

### Container

- `rootURL`: the container root URL with the properties of EPUB 3.3 4.2.5 (an opaque scheme and host chosen by Funston, for example `epub-container://<book-id>/`).
- `entries`: path (decoded, case-sensitive), compressed and uncompressed sizes, method, CRC, local header offset, directory flag.
- `mimetypeDiagnostic`: nil or the deviation.
- `rootfiles`: ordered list of (full path, media type); `defaultRootfile` is the first.
- `encryption`: list of (resource path, algorithm URL, is-obfuscated-font); derived `protectedResources` and `obfuscatedFonts`.
- `diagnostics`: ordered list of (severity, path, message).

### Package

- `version`: raw string plus a parsed major (2 or 3, or unknown).
- `uniqueIdentifier`: text, plus the whole list of identifiers with their `identifier-type` or `opf:scheme`.
- `titles`: ordered (text, type from `title-type`, display sequence, language, direction); `mainTitle` is the first or the one typed `main`.
- `languages`: ordered BCP 47 strings; `primaryLanguage`.
- `creators` and `contributors`: ordered (name, file-as, roles from MARC relators, alternate scripts, display sequence).
- `dates`: publication date (`dc:date`), `dcterms:modified`, EPUB 2 event dates.
- `description`, `publisher`, `rights`, `sources`, `subjects` (with authority and term), `type`.
- `accessibility`: access modes, sufficient modes, features, hazards, summary, conformance statements, certifier and credential (STD-35).
- `rendition`: layout, flow, orientation, spread, and per-spine-item overrides.
- `extraMeta`: every unrecognized `meta` as (expanded property URL or raw token, refines target, value) for diagnostics and future use.
- `manifest`: dictionary id to item (href as content URL, path, media type, sniffed media type, properties set, fallback id, media-overlay id, exists-in-archive flag).
- `navigationItemID`, `coverImageItemID`, `ncxItemID` (from `spine toc`, then by media type).
- `spine`: ordered items (manifest id, linear flag, properties, override layout and flow, page-spread), `pageProgressionDirection`.
- `guide`: ordered (type, title, href) from EPUB 2.
- `collections`: (role, metadata, links) kept opaque.

### Navigation

- `tableOfContents`: tree of entries (label, target = (spine index, fragment) or nil, children, source = nav or ncx or synthetic, depth).
- `pageList`: flat ordered entries (label, numeric value if parseable, type front/normal/special, target).
- `landmarks`: flat entries (semantic term, label, target), merged from nav landmarks and guide.
- `otherLists`: named flat lists from extra `nav` elements and NCX `navList`s (list of illustrations, list of tables).
- `pageBreaksInContent`: for each spine item, ordered (label, element id or CFI) found at parse time, feeding "current page" announcements.

### Content document (per spine item, built lazily)

- The element tree after parsing (XML or tag soup), with for each element: name, attributes, inherited language and direction, computed `epub:type` terms (expanded) and `role`, an `id`, and for each text node its UTF-16 length. This tree is what CFI steps walk, so it must preserve the exact child sequence of the parsed document, including whitespace-only text nodes, because CFI indices count them.
- The computed style per element for the supported property set, and the flattened block list the renderer and the accessibility tree consume.
- Resolved resources: images with decoded size and alt text, fonts registered, stylesheets applied, missing resources listed.

### Locator (persisted)

A JSON record stored in `book_positions.locator`, versioned so the migration from Readium `Locator` JSON is detectable:

```
{
  "v": 2,
  "href": "20512/www.gutenberg.org@files@20512@20512-h@20512-h-3.htm.html",
  "spineIndex": 3,
  "cfi": "epubcfi(/6/8!/4/128[pgepubid00014]/3:0[,The next])",
  "progression": 0.4137,
  "totalProgression": 0.3192,
  "text": { "before": "...two sentences...", "highlight": "", "after": "The next morning..." },
  "title": "X",
  "savedAt": "2026-10-15T03:40:00Z",
  "renderer": "funston-epub/1"
}
```

Records without `"v"` are Readium locators: `href` (container-relative, possibly with a leading slash to strip), `type`, `title`, `locations.cfi` (optional), `locations.progression`, `locations.totalProgression`, `locations.position`, `text.before/highlight/after`. Migration resolves them in the order CFI, text, progression, and writes a v2 record on success. The primary key stays (identifier, file_name), so no schema migration is needed for the table itself; only the JSON changes.

### Diagnostics

One list per book: severity (info, warning, error), the archive path or spine index concerned, a stable code (for tests: `mimetype.missing`, `container.rootfile.fallback`, `xml.tagsoup`, `href.caseFallback`, `font.deobfuscationFailed`, `nav.synthetic`, and so on) and a sentence. Tests assert on codes.

## 7. Accessibility

### 7.1 What EPUB Accessibility 1.1 asks of publications, and what a reader should do with it

EPUB Accessibility 1.1 is written for publications, not reading systems, but every requirement it places on a book is a signal a reader can surface.

Discoverability (section 2.2). Every publication MUST carry schema.org metadata for `accessMode`, `accessibilityFeature` and `accessibilityHazard`, and SHOULD carry `accessibilitySummary` and `accessModeSufficient`. Metadata only in a linked record does not count (2.3). The values come from the Schema.org Accessibility Properties for Discoverability Vocabulary (a W3C Community Group report whose current page could not be fetched without JavaScript during this study; the Standard Ebooks files confirm `textual`, `visual`, `alternativeText`, `displayTransformability`, `readingOrder`, `structuralNavigation`, `tableOfContents`, `unlocked` and `none`). The commonly used value sets, to be confirmed against the vocabulary page when it is reachable: accessMode `auditory`, `tactile`, `textual`, `visual`, plus the `chartOnVisual`, `chemOnVisual`, `colorDependent`, `diagramOnVisual`, `mathOnVisual`, `musicOnVisual`, `textOnVisual` refinements; accessibilityFeature `alternativeText`, `annotations`, `ARIA`, `audioDescription`, `bookmarks`, `braille`, `captions`, `ChemML`, `describedMath`, `displayTransformability`, `highContrastAudio`, `highContrastDisplay`, `index`, `largePrint`, `latex`, `longDescription`, `MathML`, `none`, `printPageNumbers`, `readingOrder`, `rubyAnnotations`, `signLanguage`, `structuralNavigation`, `synchronizedAudioText`, `tableOfContents`, `taggedPDF`, `tactileGraphic`, `tactileObject`, `timingControl`, `transcript`, `ttsMarkup`, `unlocked`; accessibilityHazard `flashing`, `noFlashingHazard`, `motionSimulation`, `noMotionSimulationHazard`, `sound`, `noSoundHazard`, `unknown`, `none`. The reader shows these as sentences (STD-35) and treats unknown tokens as text.

Conformance (3.5.2). A conforming publication carries `dcterms:conformsTo` with a value matching `EPUB Accessibility 1.1 - WCAG 2.0|2.1|2.2 Level A|AA|AAA` exactly, may carry `a11y:certifiedBy`, `a11y:certifierCredential` (refining the certifier) and a `link rel="a11y:certifierReport"`, and may carry other `conformsTo` values including a WCAG URL or the literal `none`. The reader displays the statement and the certifier and never invents a level.

Page navigation (3.4.1). When a publication is the digital twin of a paginated edition it MUST identify the pagination source in metadata (the techniques note uses `dc:source` and a `pageBreakSource` property), MUST include a page list, SHOULD include page break markers (`epub:type="pagebreak"`, `role="doc-pagebreak"`, label in `aria-label` or `title`), and MUST list every marker in the page list. The reader's "Go to page" and "current page" features (STD-34) are the consumer. Note that only one Gutenberg book in the corpus (Poems of the Great War) has a page list, and its `value` attributes are sequence numbers, not page numbers, while its labels say "[Pg 4]": trust labels for display and values only for sorting.

Synchronized text and audio (3.4.2). Completeness, reading order, skippability (footnotes, endnotes, page breaks), escapability (tables, lists, figures, asides) and navigation-document overlays are SHOULD-level objectives for media overlays. Funston's reader reads with VoiceOver, not with overlays, but the same semantics drive VoiceOver skipping and escaping (STD-33, STD-37).

WCAG (3.2, 3.3). Content must meet WCAG 2 at some level; the reader cannot fix content, but it can do its part: give headings their level, expose alt text, keep language per run, and keep reading order equal to document order.

Reading-system accessibility (RS 14, non-normative). The listed concerns are bookshelf text alternatives (title and author with language), accessible controls, full-text search, display control (fonts, spacing, contrast), zoom, reading control that does not trap users at page or document ends, accessibility API integration with roles, states and properties, access to the document structure, and an accessible table of contents whose links can be activated by any input. Each maps to a requirement in section 4 (STD-32, STD-34, STD-38, STD-15).

### 7.2 Content semantics a VoiceOver reader must surface

The table maps markup to what VoiceOver should hear or be able to do. "Element" means a `UIAccessibilityElement` or view exposed by the renderer.

| Markup | Exposure |
| --- | --- |
| `h1` to `h6`, or `hgroup` with its first heading | One element with the heading trait and "Heading level N" as value. For `hgroup`, speak the ordinal and the title in one element ("I, Loomings, heading level 2"). |
| `p`, `li`, `dd`, `dt`, `figcaption`, `td`, `th`, `blockquote > p`, `pre` | One element per block, static text trait, in document order. |
| `br`-separated lines inside a block (verse, addresses, preformatted data) | One element per block with the line breaks kept in the spoken string so VoiceOver pauses; the Lines rotor can still step lines. |
| `ol`, `ul`, `dl` | Container with start and end announcement ("list, 4 items", "end of list"); ordered lists speak the ordinal; nested lists keep nesting. |
| `table` | Container announcing "table, R rows, C columns"; header cells associated with data cells; `caption` first. Layout tables (no `th`, one row or one column, Gutenberg title blocks) are flattened to blocks with a diagnostic. |
| `a href` internal | Element with the link trait, label from text, "link" announced; appears in the Links rotor; activation moves the reading position (STD-27). |
| `a href` external | Link trait plus hint "opens in browser"; activation asks first. |
| `a` with `epub:type="noteref"` or `role="doc-noteref"` | Link trait, label "note N"; activation presents the note (STD-33); setting to skip. |
| `aside`, `li`, `section` or `div` with `footnote`, `endnote`, `rearnote`, `doc-footnote`, `doc-endnote` | Container announced as "note N"; contains the backlink as a link element labelled "return to text". |
| `epub:type="pagebreak"` or `role="doc-pagebreak"` with `aria-label`/`title`; Gutenberg `span.pageno` with `title` or text; `a[id^=Page_]` | Skippable element "page 14" when the setting is on; always available to "current page" and "Go to page". Never announced as empty text. |
| `img` with `alt` | Element with the image trait and the `alt` as label; `alt=""` is hidden; missing `alt` yields "image, <file name>". |
| `figure` with `figcaption` | Container; image element then caption element. |
| `svg` inline | Element with image trait labelled from `title` then `desc`, else "graphic". |
| `math` | Element with label from `alttext`, `annotation`, or a linearized reading; hint "math". |
| `abbr` with `title` | Spoken as written; the `title` offered as a hint, not substituted (Standard Ebooks style). |
| `lang`/`xml:lang` | `accessibilityLanguage` on each element and on attributed runs for pronunciation (Elektra: Greek body, English transcriber notes; Moby Dick: 18 languages inline). |
| `dir`, `bdo` | Direction affects layout only; VoiceOver reads the logical string. |
| `hr` | Not an element (silence), or "section break" when it carries a class used for thought breaks and the user turned on structure announcements. |
| `epub:type` `frontmatter`, `bodymatter`, `backmatter`, `chapter`, `part` | Landmarks and "Start reading" target; chapter titles for the page element's value ("Chapter 3 of 40"). |
| `epub:type="toc"` nav in the spine | Rendered as a list of links; the reader's own TOC still comes from the nav document. |
| `hidden` attribute, `display:none`, `aria-hidden="true"` | Not exposed. |
| `role="presentation"` on `header`/`footer` inside letters (Standard Ebooks) | Children exposed, container not announced. |
| Scripted or interactive content | Static fallback only. |

### 7.3 The page element and reader chrome

The current PDF reader exposes a `ReaderPageElement` with the adjustable trait that turns pages on increment and decrement and a Magic Tap that toggles controls. The EPUB reader keeps that pattern: one adjustable element whose value is the position ("Chapter 3 of 40, 42 percent"), followed by the content elements for the visible region. The page-turn announcement should name the chapter and page label when known ("Chapter 3, page 57") rather than only "Page 12 of 300", because EPUB page counts are synthetic.

### 7.4 Verification

Nothing in this section is verified until it runs under VoiceOver on a simulator or device with real books. The `ios-sim-voiceover` skill drives VoiceOver on the simulator and reads back what it says; the acceptance list for each requirement above is: focus order equals document order; no element with an empty label; headings carry levels; links appear in the rotor; list and table containers announce start and end; notes open and return; page labels are skippable; languages switch pronunciation. Candidate books for the first pass: Standard Ebooks Moby Dick (semantics-rich), Man and Maid (Gutenberg baseline), Poems of the Great War (verse and page list), Elektra (non-Latin script), the Factbook (very long preformatted blocks).

## 8. Malformed input and failure behaviour

The rule: open what can be opened, render what can be rendered, report the rest. The specifications constrain EPUB creators far more than reading systems; RS 2.2 only says reading systems "are not required to load" invalid content. The table lists what the specification says, what the wild does, and what Funston's reader does. Every row produces a diagnostic code (STD-39).

| Deviation | What the specification says | Seen in | What the reader does |
| --- | --- | --- | --- |
| `mimetype` missing | Creators MUST include it first, stored (EPUB 3.3 4.3.3). RS 4.2 lists no reading-system error for its absence. | ZIP tools that drop it | Open; sniff `container.xml` instead; diagnostic. |
| `mimetype` wrong content, trailing newline, BOM, not first, compressed, with extra field | Same section forbids each. | Hand-zipped books | Open; diagnostic naming the exact deviation. |
| Compression method other than 0 or 8, split archive, ZIP encryption | RS 4.2: MUST treat as in error. | Rare | Refuse the affected entries; if a spine item is affected show a "cannot read" page; if `container.xml` or the OPF is affected refuse the book with that reason. |
| ZIP64 fields, data descriptors, directory entries, duplicate names | ZIP64 allowed (4.3.2), RS requires ZIP64; data descriptors and directories are ZIP features the spec is silent on; duplicates are not addressed. | Standard Ebooks (directory entries), large books | Support all; last duplicate wins with diagnostic (STD-01). |
| Zero-length entry | Not addressed. | Generated placeholders | Treat as an empty resource; an empty spine document renders as an empty page with diagnostic. |
| `container.xml` missing or malformed | Required (4.2.6.3.1). | Broken exports | Find a single `*.opf`; else refuse with reason. |
| Several `rootfile`s | Allowed; use the first (RS 4.1.3). | Multiple renditions | Use the first; diagnostic listing the others. |
| EPUB 2 without NCX | OPF 2.0.1 requires an NCX. | Minimal conversions | Build a synthetic TOC (STD-17). |
| EPUB 3 without `nav` item | Required (5.6.2.1). | Old EPUB 3 exports | Use NCX if present, else synthetic; diagnostic. |
| `nav` and NCX disagree | Legacy features are not used by EPUB 3 reading systems (5.9.2, RS 5.7). | Books edited after conversion | nav wins; NCX fills missing page list only; diagnostic with the entry count difference. |
| hrefs with percent-encoding, spaces, `+`, non-NFC Unicode | Must be valid URL strings; spaces are discouraged in file names (4.2.3). | macOS-authored books (NFD), Word exports (spaces) | Parse as URL, decode, try exact, NFC, NFD, case-insensitive (STD-05). |
| Relative paths with `..` beyond the root, leading `/` | Disallowed for creators; conforming readers clamp to the root (4.2.5 note). | Hand-edited books | Clamp; diagnostic. |
| `href` with `?query` or `#fragment` in the manifest | Not valid manifest hrefs. | Rare | Strip query; keep fragment aside; diagnostic. |
| BOM in XML or CSS | XML allows a BOM; CSS must be UTF-8 or UTF-16. | Windows tools | Accept. |
| Wrong or missing XML encoding declaration | Must be well-formed XML. | Les Misérables cover wrapper (no declaration), Latin-1 bytes labelled UTF-8 | Try the declared encoding, then UTF-8, then Windows-1252 for EPUB 2; diagnostic. |
| XHTML that is tag soup (unclosed elements, overlapping tags, unquoted attributes) | Must be XML; the test suite expects an error. | Old conversions, hand edits | Re-parse with a tag-soup parser; diagnostic `xml.tagsoup`. |
| Undefined named entities (`&nbsp;`, `&mdash;`) without a DTD | XML without a DTD knows only the five built-ins. | Common in EPUB 2 | Predeclare the XHTML 1.1 entity set; diagnostic only when an entity is still unknown (then keep the literal text). |
| Invalid attributes (Ebookmaker `tag="{http://www.w3.org/1999/xhtml}a"` on 121 elements) | Schema violation; EPUBCheck reports errors. | Les Misérables, 2017 Gutenberg output | Ignore unknown attributes silently; no diagnostic (too noisy), but a count in the book's problems list. |
| `<meta http-equiv="Content-Type" content="text/htmlcharset=utf-8"/>` | Not a well-formed media type. | Relativity (Word 10 export) | Ignore `meta http-equiv`; the XML declaration governs. |
| U+FFFD replacement characters and U+FEFF inside body text | Content bugs, not format errors. | Relativity, Shiji | Render as is; strip U+FEFF from spoken text. |
| `<title>` empty or a single space | HTML requires a title. | Shiji | Use the TOC label or the spine position for the page title. |
| Missing `dc:language` | Required (5.5.3.1.3). | Minimal books | Open; language "und"; pronunciation falls back to the system default; diagnostic. |
| Several `dc:title` | Allowed; first is main (5.5.3.1.2). | Standard Ebooks (main, subtitle, expanded; main, short) | Use `title-type="main"` else the first; keep the others for the detail screen. |
| Several `dc:language`, odd tags ("EN-US", "gem") | First is primary; must be BCP 47. | Gutenberg (`gem` is an ISO 639-2 group code), Word (`EN-US`) | Accept any string, lower-case for matching; diagnostic when not BCP 47. |
| Cover declared only through OPF2 `meta name="cover"` | Legacy; EPUB 3 uses `cover-image` (5.9.3). | Every Gutenberg book | Use it (STD-11). |
| `guide` entry whose target is an image | Guide references must be content documents. EPUBCheck: error. | Six Gutenberg books (`cover.jpg` in `guide type="cover"`) | Treat as cover image; no error. |
| Fonts referenced but missing, or protected | Reading systems fall back (RS 6.3 fonts list implies decoding only when present). | Books stripped by tools | System font; diagnostic. |
| Images referenced but missing, or not in the manifest | Unlisted resources "should not be shown" (test pkg-manifest-unlisted-resource). | Images editions versus text editions | Missing: `alt` or placeholder. Unlisted but present: shown, with diagnostic (a deliberate deviation, recorded as such). |
| CSS `@import` of a missing file, unknown at-rules, vendor properties (`adobe-hyphenate`, `-webkit-hyphens`) | CSS error recovery drops what it does not know. | Standard Ebooks (Adobe and Nook properties) | Ignore; diagnostic for missing imports only. |
| CSS forbidden properties `direction`, `unicode-bidi` | MUST NOT appear (6.3.1.2). | Rare | Ignore the declarations. |
| CSS that fights the user: fixed `pt` sizes, `margin: 15%`, `position: absolute`, `color: black; background: white` | Allowed for creators; RS 6.3 lets users override. | Relativity, Gibbon, every Gutenberg `pgepub.css` | User overrides win for size and colour; horizontal margins clamped; absolute positioning rendered inline. |
| Spine `itemref` to a missing manifest item | Must reference an item (5.7.2). | Edited books | Skip the itemref; diagnostic. |
| Spine `itemref` to a non-content type (NCX, CSS, image without fallback) | Each spine item must be a content document or have a fallback (5.7.2). | Conversions | Image: render as a page image; others: skip with diagnostic. |
| First spine item `linear="no"` (cover wrapper) | Allowed; non-linear may be skipped (RS 5.5). | Les Misérables 2017 | Start at the first linear item; the cover is still reachable from the landmarks. |
| Duplicate `itemref`s | Creators MUST NOT; readers MUST keep both (RS 5.5). | Rare | Keep both positions. |
| Unknown `version` (`"0"`, `"3.1"`, missing) | RS 12 and 13: attempt processing. | pkg-version-backward | Open; diagnostic. |
| Unknown `properties`, `property`, `rel`, collection roles | Ignore (RS 5.3, 5.4, 5.5, 5.6). | Standard Ebooks `schema:*`, `se:*` | Ignore, keep for diagnostics. |
| Package without the OPF namespace, or elements out of order | Must be in the OPF namespace, in order (5.4). | Old tools | Match by local name; accept any order; diagnostic. |
| NCX without `playOrder` or DOCTYPE, `dtb:depth` wrong, `dtb:uid` differs from the identifier | OPF 2.0.1 makes `playOrder` optional; DTD metadata is advisory. | Standard Ebooks NCX (no DOCTYPE, no depth meta) | Ignore all three; document order rules. |
| NCX that covers only the license, or one entry "Start" | Content bug. | Shiji, Relativity | Synthetic TOC (STD-17). |
| `pageList` values that are sequence numbers, labels that are the real page numbers | Z39.86 8.4.5 says the label is authoritative. | Poems of the Great War | Display labels; sort by document order. |
| Empty `span.pageno` with the number only in `title` | Content convention, not a spec matter. | Man and Maid (327), Poems | Read `title` as the page label; expose as a page break. |
| Inverted heading levels (`h5` chapter label above `h4` chapter title; parts in `h3`) | HTML outline misuse. | Les Misérables 2017 | Keep levels as authored for VoiceOver (it is what sighted readers get too); the TOC comes from the NCX, not from heading levels. |
| Footnote markers as bare asterisks with no linked notes | Content loss in conversion. | Gibbon (92 inline asterisks, no note bodies) | Nothing to link; render the asterisk; no diagnostic (it is text). |
| `a id="x"/>` empty anchors as link targets | Valid XHTML. | Gibbon, Les Misérables | Resolve fragments to the enclosing block. |
| Very large single documents (190 KB each, 63 of them, 11.9 MB) | No limit in the spec. | Factbook | Lazy parsing per spine item; layout in chunks; the position model must not require laying out the whole book (STD-40). |
| Hundreds of inline images used as glyphs or equations | Allowed. | Relativity (63) | Inline images scale with text; `alt=""` makes them invisible to VoiceOver, so the problems list reports "63 images without descriptions". |
| EPUBCheck false positives (`aria-labelledby` on `nav`) | The validator's schema lags HTML. | Standard Ebooks 4.x | Do not surface validator opinions to readers; use EPUBCheck in tests only. |
| Interstitial HTML saved as `.epub` | Not an EPUB. | Standard Ebooks download without `?source=download` | Sniff bytes before trusting the extension; "This file is a web page, not a book". |
| Resources inside META-INF referenced from content | Forbidden (4.2.2). | Rare | Serve anyway with a diagnostic; never treat META-INF files as spine items. |
| Decompression bombs, deep nesting, entity expansion, thousands of entries | Threat model (RS 15). | Hostile files | Hard limits with clear refusal (STD-40). |

### What never degrades silently

Three outcomes are allowed when a book is opened: the book opens with zero or more diagnostics; the book opens with some spine items replaced by a "could not read this section" page; or the book is refused with one sentence naming the cause (no container.xml and no OPF, no readable spine item, protected content, or a resource limit). A blank page, a crash, a silently skipped chapter, or a position lost without a message are bugs by definition.

## 9. Test fixtures and vectors

### 9.1 W3C epub-tests

Repository: https://github.com/w3c/epub-tests (cloned at depth 1, commit 54092b42, 29 September 2026, 211 test directories under `tests/`). Each test is a directory with `mimetype`, `META-INF/container.xml` and an `EPUB/` folder; the package document carries the test id in `dc:identifier`, the covered area in `dc:coverage`, the spec version it was added in (`schema:version` 3.3 or 3.4), a `dc:description` with the pass criterion, and a `dcterms:isReferencedBy` link to the normative statement. Built EPUBs are published at `https://w3c.github.io/epub-tests/tests/<id>.epub` and listed in the OPDS catalogue `https://w3c.github.io/epub-tests/opds/opds.json` (206 publications). Source for a test: `https://github.com/w3c/epub-tests/tree/main/tests/<id>`. Implementation reports live at https://w3c.github.io/epub-tests/results. Fixed-layout (`fxl-*`, `lay-fxl-*`, `lay-pp-*`, `lay-roll-*`), scripting (`scr-*`) and font-format tests are omitted from the table below except where version one must fail them gracefully.

"V1" marks the tests a version-one reader must pass (P), must handle by graceful degradation with a diagnostic (D), or may report as not applicable (N).

| Test id | Area | What it checks | V1 |
| --- | --- | --- | --- |
| ocf-package_multiple | OCF | Three packages all listed in container.xml; the first must be used. | P |
| ocf-package_arbitrary | OCF | Only one of three packages is referenced, in an odd subdirectory; it must be used. | P |
| ocf-metainf-inc | OCF | An extra file in META-INF must be ignored. | P |
| ocf-metainf-manifest | OCF | A META-INF/manifest.xml adding a spine item must be ignored. | P |
| ocf-url_link-relative | OCF | Simple relative image link resolves. | P |
| ocf-url_link-path-absolute | OCF | Leading-slash link resolves to the container root. | P |
| ocf-url_link-leaking-relative | OCF | Excess `..` segments resolve to the root. | P |
| ocf-url_manifest | OCF | Manifest href into an arbitrary subfolder resolves. | P |
| ocf-url_relative | OCF | Manifest href relative to the package's own folder resolves. | P |
| ocf-url_origin, ocf-url_parse-* | OCF | Scripted checks of the origin and URL parsing. | N (no scripting) |
| ocf-zip-comp | OCF | Non-Deflate compression must be treated as an error. | P (as error) |
| ocf-zip-mult | OCF | Split archive must be treated as an error. | P (as error) |
| ocf-font_obfuscation | OCF | Obfuscated TrueType font displays after deobfuscation. | P |
| ocf-font_obfuscation_bis | OCF | Font obfuscated with a different identifier must not display as that font. | P |
| pkg-version-backward | Package | `version="0"` must still open. | P |
| pkg-spine-order | Package | Spine order, not file-name or manifest order. | P |
| pkg-spine-order-svg | Package | Same with SVG spine items. | D |
| pkg-spine-duplicate-item-rendering, -ui, -hyperlink | Package | Duplicates rendered twice, bookmarked separately, hyperlink goes to the first. | P |
| pkg-spine-nonlinear-activation | Package | A `linear="no"` item is reachable through a link. | P |
| pkg-spine-unknown, pkg-manifest-unknown, pkg-meta-unknown, pkg-collections-unknown | Package | Unknown properties, meta properties and collection roles must not stop the book. | P |
| pkg-manifest-unlisted-resource | Package | An image not in the manifest should not be shown. | D (shown with diagnostic, a recorded deviation) |
| pkg-meta-whitespace | Package | Title and creator whitespace collapsed to single spaces. | P |
| pkg-title-order, pkg-creator-order | Package | First title is the main title; creators in document order. | P |
| pkg-unique-id, pkg-unique-id_duplicate | Package | Two books with the same identifier display independently. | P |
| pkg-linked-records | Package | Title and creator come from the package even when an ONIX record is linked. | P |
| pkg-dir_rtl-root-unset, pkg-dir_unset-root-rtl, pkg-dir_rtl-root-ltr, pkg-dir_creator-rtl | I18n | Base direction of metadata from `dir`. | P |
| pkg-dir-auto_root-rtl, pkg-dir-auto_root-unset, pkg-dir_unset-root-unset | I18n | Titles that render incorrectly without `dir` (negative tests). | P |
| pkg-dir_but_not_content, pkg-lang_but_not_content | I18n | Package language and direction do not leak into content documents. | P |
| pkg-spine-progression_ltr, _rtl, -default | I18n | Page progression from the spine attribute, default for an RTL language. | P (progression affects page-turn direction) |
| pkg-spine-progression-pre-paginated | I18n | Explicit `ltr` beats RTL content in pre-paginated items. | N |
| nav-access | Navigation | TOC with a single link is reachable through reader controls. | P |
| nav-activation | Navigation | Activating a TOC link moves the reading position. | P |
| nav-non-text_img, nav-non-text_img_title | Navigation | Image-only labels fall back to `alt`, then `title`. | P |
| nav-spine_in-spine, nav-spine_not-in-spine | Navigation | TOC reachable whether or not the nav is in the spine. | P |
| nav-spine_in-spine-hidden-toc-css, -html (3.4) | Navigation | `display:none` and `hidden` do not hide entries from the reader's TOC. | P |
| nav-spine_in-spine-no-list-style | Navigation | No numbering in the reader's TOC despite `list-style-type`. | P |
| cnt-xhtml-support | Content | XHTML renders. | P |
| cnt-svg-support, cnt-svg-embedded, cnt-svg-css, cnt-svg-css-inclusion, cnt-svg-css-reference | Content | SVG as document, inline, and the two CSS scoping rules. | D |
| cnt-mathml-support | Content | Presentation MathML renders. | D (text fallback) |
| cnt-css-fonts_tt, _ot, _woff, _woff2 | Content | The four font formats load from `@font-face`. | P |
| css-epub-hyphens, css-epub-line-break, css-epub-text-align-last, css-epub-word-break, css-epub-text-transform | CSS | Prefixed text properties. | D (hyphens and text-align-last P) |
| css-epub-writing-mode, css-epub-text-orientation, css-epub-text-combine-horizontal, css-epub-text-emphasis, css-epub-text-underline-position | CSS | Vertical writing and East Asian typography. | N for version one, reported |
| lay-pkg-flow-paginated, -scrolled-continuous, -scrolled-doc | Layout | `rendition:flow` honoured as a preference. | D (user setting wins) |
| lay-reflow-align-x-center | Layout | Centering reflowable pages. | N |
| lay-rendition-flow-pre-pag, lay-viewport-meta-prop | Layout | Flow ignored for pre-paginated; viewport meta ignored. | P |
| pss-support, pss-support_ignore-title | Semantics | Footnote popup from `epub:type`; not from the title element. | P |
| pub-cmt-gif, -jpeg, -png, -svg, -webp | Resources | Core image types display. | P |
| pub-cmt-avif, -jxl | Resources (3.4) | New image types. | D |
| pub-cmt-mp3, -mp4, -opus | Resources | Audio playback. | N |
| pub-data-urls_browsing-context | Resources | `data:` image shows inline, not as a new document. | P |
| pub-data-urls_top-level-content | Resources | Fixed-layout variant. | N |
| pub-external-links, pub-external-links_consent | Resources | External and `mailto:` links ask first. | P |
| pub-file-urls | Resources | `file:` URLs are not loaded. | P |
| pub-foreign_image, pub-foreign_json-spine, pub-foreign_xml-spine, pub-foreign_xml-suffix-spine | Fallbacks | Manifest fallbacks for an image and for foreign spine items. | P |
| pub-foreign_bad-fallback | Fallbacks | Both spine item and fallback unsupported: an error is acceptable. | D |
| pub-xml-external-id | Resources | External entity must not be resolved. | P |
| pub-xml-names | Resources | Invalid element name must produce an error. | D (tag-soup path with diagnostic) |
| pub-xml-non-validating_comment | Resources | Commented-out itemref is not in the spine. | P |
| pub-xml-non-validating_unclosed | Resources | Unclosed element must produce an error. | D (tag-soup with diagnostic) |
| sec-untrusted-consent_network, sec-untrusted-consent_scripting | Security | Remote resources and scripts only with consent. | P (never, in version one) |
| mol-ignore | Overlays | A reader without overlays ignores the SMIL items and attribute. | P |
| mol-* (all others) | Overlays | Playback behaviour. | N |
| scr-support-fallback | Scripting | Fallback shows when scripting is unsupported. | P |
| scr-* (all others) | Scripting | Script behaviour. | N |

How to run them: either load `https://w3c.github.io/epub-tests/opds/opds.json` and download each `.epub`, or clone the repository and run `sh tests/generateEpubs.sh` to zip each directory. Report results in the JSON format described in the repository README (`tests/<id>: true|false|"n/a"`).

### 9.2 IDPF epub3-samples

Repository: https://github.com/IDPF/epub3-samples (maintained by the W3C EPUB 3 Community Group). Built files: `https://github.com/IDPF/epub3-samples/releases/download/20230704/<name>.epub`. Samples table: http://idpf.github.io/epub3-samples/30/samples.html. Licensing is CC-BY-SA 3.0 unless noted. Worth using as fixtures:

| Sample (`<name>`) | What it exercises |
| --- | --- |
| accessible_epub_3 | A real book about EPUB accessibility; nav with page-list and landmarks, pagebreak markers, notes, proper headings. The first book to run under VoiceOver. |
| moby-dick | One spine item per chapter, embedded OpenType fonts, `epub:type` throughout. Compare with the Standard Ebooks edition of the same text. |
| moby-dick-mo | Same plus media overlays for two chapters: must open and read as text with overlays ignored. |
| wasteland | Single XHTML document with `section` elements, a linked note apparatus, day and night alternate stylesheets, plus an NCX and OPF2 cover meta for EPUB 2 compatibility: the nav versus NCX merge test. |
| wasteland-otf, wasteland-woff | Embedded OTF and WOFF fonts. |
| wasteland-otf-obf, wasteland-woff-obf | The same fonts obfuscated with the OCF algorithm: end-to-end deobfuscation on a real book. |
| childrens-literature | `span` headings in the TOC, the TOC in the spine with a hidden page list: the hidden-attribute rule. |
| page-blanche, page-blanche-bitmaps-in-spine | Fixed layout with XHTML wrappers and with JPEG spine items: graceful degradation. |
| sous-le-vent, sous-le-vent_svg-in-spine, svg-in-spine | Fixed layout with SVG, SVG spine items, page-spread properties. |
| cc-shared-culture | Audio and video embedding variants with media overlays: fallbacks and ignore paths. |
| georgia-pls-ssml, georgia-cfi | A page-list nav, the second version using CFIs in the page list: CFI resolution against real content. |
| internallinks | A test document for internal linking and fragments. |
| israelsailing | Hebrew, bidi, `page-progression-direction="rtl"`. |
| regime-anticancer-arabic | Arabic text without embedded fonts: system Arabic shaping. |
| mahabharata | Devanagari without embedded fonts. |
| kusamakura-japanese-vertical-writing, kusamakura-preview | Vertical writing, ruby, emphasis dots, non-ASCII file names and IRIs, media overlay, phonetic metadata. Version one reports vertical writing as unsupported but must still open the book (non-ASCII hrefs). |
| jlreq-in-japanese, jlreq-in-english | Long technical documents, many images, bilingual. |
| vertically-scrollable-manga, horizontally-scrollable-emakimono | Scrolled fixed layout: degradation. |
| linear-algebra | Substantial MathML: the text fallback path. |
| hefty-water | The deprecated `epub:switch` and some ruby. |
| trees | `canvas` with fallback text and multi-column CSS: no-script path. |
| figure-gallery-bindings, quiz-bindings | Deprecated `bindings`: fallback content shows all figures and all questions. |
| indexing-for-eds-and-auths-3f, -3md | EPUB Indexes, split across documents: `collection` elements. |
| epub30-spec | The EPUB 3.0 specification as an EPUB: a large technical book with many internal links. |
| WCAG | The WCAG guidelines as an EPUB; headings and lists at scale. |
| mymedia_lite, cole-voyage-of-life, cole-voyage-of-life-tol | Media queries; mixed reflowable and fixed; textual overlays on images. |
| haruko-* | Manga as image-per-page XHTML and as JPEG spine items. |

### 9.3 EPUBCheck

Download: https://github.com/w3c/epubcheck/releases/download/v5.4.0/epubcheck-5.4.0.zip (33 MB; SHA-256 33350c61038e71dfb3d45a76aed04bf5481e6d5500cb780f6e98db8bbd15a28c). Requires Java 11 or later (OpenJDK 26 from Homebrew worked). Unzip to a directory and run:

```bash
java -jar epubcheck-5.4.0/epubcheck.jar path/to/book.epub
```

Useful options: `--json report.json` for machine-readable output, `--mode exp` to check an unzipped directory, `--profile default`, `-w` to lower the reporting level to warnings, `--version`. Exit status is non-zero when errors are found. EPUBCheck validates against the EPUB schemas and the EPUB 3.3 (and 2.0.1) rules; it is the right tool for Funston's own fixture EPUBs (every fixture committed to tests should pass with zero errors except where a fixture deliberately exercises a leniency, and then the expected EPUBCheck message is part of the fixture's documentation). It is the wrong tool for the open path (section 10).

Results on the corpus, EPUBCheck 5.4.0:

| File | Fatals / errors / warnings | Messages |
| --- | --- | --- |
| pg20512-images.epub, pg20512.epub | 0 / 0 / 0 | clean |
| pg890.epub | 0 / 1 / 0 | guide references `890/cover.jpg`, not a content document |
| pg30155-images.epub, pg30155.epub | 0 / 0 / 0 | clean |
| pg24226.epub | 0 / 1 / 0 | guide references `24226/cover.jpg` |
| pg17995.epub | 0 / 1 / 0 | guide references `17995/cover.jpg` |
| pg27348.epub | 0 / 1 / 0 | guide references `27348/cover.jpg` |
| pg33681-images.epub | 0 / 0 / 0 | clean |
| pg48734-images.epub | 0 / 121 / 0 | `tag` attribute not allowed, 107 on `a`, 12 on `link`, 2 on `img` |
| pg48734.epub | 0 / 118 / 0 | same, 107 + 11 |
| herman-melville_moby-dick.epub, _advanced.epub | 0 / 2 / 0 | `aria-labelledby` not allowed on `nav` (two nav elements); HTML allows it, so this is a validator schema lag |
| lewis-carroll_alices-adventures-in-wonderland_john-tenniel.epub | 0 / 2 / 0 | same |

### 9.4 The real corpus, book by book

Common to every Gutenberg file: EPUB 2.0; `META-INF/container.xml` with a single rootfile; the OPF named `content.opf` inside a directory named after the ebook number (`20512/content.opf`) for the 2010 and 2011 EPUB-Maker files and `OEBPS/content.opf` for the 2017 Ebookmaker file; `mimetype` first and stored; no data descriptors, no directory entries, no non-ASCII entry names, no fonts; metadata `dc:identifier opf:scheme="URI"` = `http://www.gutenberg.org/ebooks/N`, `dc:language xsi:type="dcterms:RFC4646"`, `dc:date opf:event="publication"` and `opf:event="conversion"`, `dc:source` = the Gutenberg HTML or text file URL, `dc:rights` "Public domain in the USA.", and `meta name="cover" content="<item id>"`; an NCX with `dtb:uid` equal to the identifier, `dtb:depth`, `dtb:generator` ("Project Gutenberg EPUB-Maker v0.02" or "v0.03", or "Ebookmaker 0.4.0a5 by Marcello Perathoner"), `dtb:totalPageCount` 0 and `dtb:maxPageNumber` 0, every `navPoint` with `playOrder`; XHTML 1.1 DOCTYPE, UTF-8, an HTML Tidy `generator` meta, three stylesheets (`0.css`, the book's own; `1.css`, classes `c1`, `c2`, ... generated from inline `style` attributes; `pgepub.css`, the converter's own); content hrefs that are the source URL flattened with `@` for `/` (`www.gutenberg.org@files@20512@20512-h@20512-h-0.htm.html`, or `@public@vhost@g@gutenberg@html@files@48734@...` in 2017); the converter inserts `id="pgepubidNNNNN"` on every heading it puts in the NCX; the source's `h2` elements get `page-break-before: always` from `pgepub.css`; spine items are split by size (roughly 50 KB in v0.03, 95 to 240 KB in v0.02), not by chapter, so chapters straddle files; and a generic 19263-byte `cover.jpg` is added when the book has no cover (identical bytes in ten of the eleven files).

**pg20512-images.epub and pg20512.epub (Man and Maid, 1922 novel, EPUB-Maker v0.03).** 23 and 18 ZIP entries; 20 and 15 manifest items (5 JPEG + 1 PNG, or none, plus `cover.jpg`); 10 spine documents of 21 to 62 KB (491 KB of XHTML); NCX of 29 navPoints, depth 2, pointing at `h1`/`h2`/`h3` (Transcriber's Notes, title, 25 chapter numerals as `<h2 id="pgepubidNNNNN">I</h2>`); no guide. Tags: 2574 `p`, 445 `br`, 361 `a` (all anchors, no hrefs), 360 `i`, 16 `table` (title block in a bordered table with an emblem image; chapter-opening date lines in tables), 30 `hr` (`hr.major` 29 thought breaks), 26 `h2`. 327 page markers `<span class="pageno" title="5"/>` (empty element, number in `title`; `0.css` styles a `.pagenum` class that nothing uses, so the markers are invisible). `div.tnote` with `h3` and an `ol` of transcriber's notes. `div.figcenter` with `img` and a `caption` paragraph for the four plates, which link to full-size images in the source but are thumbnails (`-tn.jpg`) here. The two editions differ only in images: the text edition keeps the `figcenter` captions without the pictures. Zero EPUBCheck messages. No `lang` attributes anywhere. The book is Funston's routing fixture (`BookRoutingTests.swift`), and `pg20512-images.epub` is the one `ArtifactMediaPresentation.bookFile` picks.

**pg890.epub (Gibbon, Decline and Fall vol. 1, EPUB-Maker v0.02).** 14 entries; 6 spine documents of 48 to 238 KB (1.14 MB of XHTML, so one document is a full screenful of pages under TextKit); 57 `h2` chapter and part headings (`Chapter I: The Extent Of The Empire ... Part I.`), each followed by a `div.pgmonospaced` block of `br`-separated argument lines; `dc:title` contains a U+2014 em dash; `dc:contributor opf:role="cmm"` for Milman; two `dc:subject`; guide `type="cover"` pointing at `cover.jpg` (EPUBCheck error). The first file holds a `div.toc` with 56 cross-file links to empty anchors `<a id="ch3-2"/>` placed just before each heading. 1356 `br`: most paragraphs end `...text.<br/></p>`. The Milman footnotes did not survive conversion: 92 bare asterisks remain inline (" * A martial nobility ...") with no note bodies anywhere, and the `.foot` class in `0.css` is unused. `0.css` sets `p { margin: 15% }`, `.pagenum { position: absolute; left: 1% }` (also unused) and `pre { font-style: italic }`. Depth-2 NCX of 63 entries.

**pg30155-images.epub and pg30155.epub (Einstein, Relativity, EPUB-Maker v0.03).** The source was Microsoft Word 10 "filtered" HTML: `<meta name="Generator" content="Microsoft Word 10 (filtered)"/>`, a malformed `<meta http-equiv="Content-Type" content="text/htmlcharset=utf-8"/>`, `body xml:lang="EN-US"`, 34 `span xml:lang="FR-CA"`, classes `MsoNormal` (1232) and `Section1`, `0.css` with `@page Section1 { size: 8.5in 11in }` and `p.MsoNormal { font-size: 12pt; font-family: "Times New Roman" }`. There are no heading elements at all, so the NCX has one navPoint, "Start"; chapter titles are `p.MsoNormal` with a `span.c1`. 63 inline `img` with `alt=""` and pixel `width`/`height` carry every equation, table and figure (images editions) and are simply gone from the text edition, which still says "58 image files are part of this eBook". 262 `sub`/`sup`. U+FFFD replacement characters appear in the text where the Word export lost bytes. Spine of 7 documents, two of them 1.6 KB and 1.0 KB (near-empty splits). Zero EPUBCheck messages.

**pg24226.epub (Sima Qian, Shiji, EPUB-Maker v0.02, from plain text).** `dc:language zh`, title and `docTitle` in Chinese (史記). The source was `24226-0.txt`, so the converter made 23 documents of about 94 KB, each a run of `<p id="idNNNNN">` paragraphs (5153 ids in all) with hard line wraps inside paragraphs and U+3000 ideographic spaces for indentation; the first paragraph begins with a literal U+FEFF; `<title> </title>` is a single space; only `pgepub.css` is linked; chapter titles ("史記 五帝本紀") are plain paragraphs; the only headings (`h3`, `h4`, `h5`) are in the Gutenberg license at the end, so the NCX's six entries all point into the last file. The real contents are unreachable from the table of contents. Guide `cover` points at `cover.jpg` (EPUBCheck error).

**pg17995.epub (Euripides, Elektra, Greek, EPUB-Maker v0.02).** `dc:language el`, `dc:contributor opf:role="trl"`, source an OpenOffice HTML export: `class="western"` on all 1244 paragraphs, `xml:lang` on paragraphs and spans (`el-GR`, `en-GB`, `en-US`, `it-IT`), `0.css` in centimetres and points (`p.c4 { margin-top: 0.49cm }`). Verse is one `<p class="western c1">` per line (`c1` is `margin-bottom: 0`) with speaker names as their own paragraphs (ΓΕΩΡΓΟΣ) and `<p class="western c3"><br/></p>` as stanza spacing. Two `h3` headings; 3 documents of 94, 65 and 22 KB; NCX of 2 entries. Guide `cover` error.

**pg27348.epub (2007 CIA World Factbook, EPUB-Maker v0.02, from plain text).** 63 documents of 150 to 256 KB, 11.9 MB of XHTML, 1061 paragraphs per file, no element other than `p` and `br` in the body: the fixed-width source became `<p id="id00807">Natural resources:<br/>    petroleum, natural gas, coal,<br/>    nickel, salt, timber</p>`, with leading spaces kept as text (whitespace collapsing turns them into one space unless the renderer treats these blocks as preformatted). Some paragraphs carry `style="margin-right: 0%; margin-left: 0%"`. NCX of 33 entries (letters A to Z and sections), depth 3; guide `toc` and `cover`. This is the memory and layout stress fixture.

**pg33681-images.epub (Poems of the Great War, EPUB-Maker v0.03).** A single 60 KB document; 23 `h2` poem titles (`<h2 class="c3" id="pgepubid00001">DUTY.</h2>`), poems as `<p>` with `<br/>` line ends, `<span class="c5">` (a `margin-left`) for indented lines, whole poems wrapped in `<i>`, `<p class="sig padbase">` for the poet's name, `<big>` in the title, a contents table (`td` 52, `a.pginternal` 17), one cover image in the manifest. The NCX has both a depth-1 `navMap` of 23 entries and a `pageList` of 36 `pageTarget`s whose `value` runs 1 to 36 while the labels are `[Pg 4]`, `[Pg 5]`, ... and whose targets are `<span class="pageno" title="[Pg 4]" id="Page_4"/>`. `dc:title` contains a newline. Zero EPUBCheck messages.

**pg48734-images.epub and pg48734.epub (Hugo, Les Misérables vol. 4, Ebookmaker 0.4.0a5, 2017).** The newer converter: `OEBPS/content.opf`; `xmlns:dc` declared on `package`; `html xml:lang="en"`; a first spine item `wrap0000.html` (`linear="no"`, no XML encoding declaration, an inline `<style>`, `<img src="cover.jpg" alt="Cover"/>`) and a guide with `toc` and `cover` (pointing at the wrapper, which is valid); the real cover is `cover.png` (272 KB) referenced from every chapter's `<link rel="coverpage" ...>`, plus the generic `cover.jpg`. The converter leaked an lxml attribute, `tag="{http://www.w3.org/1999/xhtml}a"`, onto 107 `a`, 12 `link` and 2 `img` elements (121 EPUBCheck errors). Headings are inverted: `<h5><a id="CHAPTER_VI">CHAPTER VI.</a></h5>` then `<h4 id="pgepubid00017">ENJOLRAS AND HIS LIEUTENANTS.</h4>`, books in `h3`, so 94 `h5`, 82 `h4`, 19 `h3`. Footnotes: in the text `<a id="FNanchor_1_1"/><a href="...#Footnote_1_1" class="fnanchor"><span class="label">[1]</span></a>`; at the end of the chapter `<div class="footnote"><p><a id="Footnote_1_1"/><a href="...#FNanchor_1_1" class="pginternal"><span class="label">[1]</span></a> note text</p></div>` (7 notes). `hr.chap` and `hr.tb` thought breaks; `div.figcenter` with `span.caption` (and `pgepub.css` now has `div.figcenter span.caption { display: block }`); a contents table with `td.tdr` numerals and `td.tdl` links; `a.pginternal` on 107 internal links; one inline `<style>` in the wrapper. 13 documents of 21 to 80 KB; NCX of 103 entries, depth 3.

**Standard Ebooks, Moby Dick (compatible build, toolset 4.0.3).** EPUB 3.0; `epub/content.opf`; `package dir="ltr" xml:lang="en-US" prefix="rdf: ..."`; 166 ZIP entries including five directory entries; 157 manifest items (146 XHTML, 3 CSS, 1 JPEG, 6 PNG at 1x and 2x, 1 NCX) plus an unlisted `onix.xml` linked by `link rel="record"` (correct per 5.5.6); `toc.xhtml` with `properties="nav"` and `images/cover.jpg` with `cover-image`, and also `meta name="cover" content="cover.jpg"` (an id) and a `guide` with `title-page` and `notes`; `spine toc="ncx"`, 145 items, one file per chapter (1 to 48 KB), none non-linear. Metadata: three `dc:title` typed `main`, `subtitle`, `expanded` through `title-type`; nine `dc:subject` with `authority` LCSH and `term`; five `belongs-to-collection` with `collection-type` and `group-position`; `dc:language en-US`; two `dc:source`; `dcterms:modified`; `schema:accessMode` textual and visual, `schema:accessModeSufficient` textual, six `schema:accessibilityFeature`, `schema:accessibilityHazard none`, `schema:accessibilitySummary`, `dcterms:conformsTo` "EPUB Accessibility 1.1 - WCAG 2.2 Level AA" refined by `a11y:certifiedBy`; `schema:wordCount`, `schema:educationalLevel`; MARC relator roles for every contributor; `dc:description` containing HTML. The nav has `toc` (145 entries, depth 2 under the half title) and `landmarks` (frontmatter, bodymatter, backmatter endnotes); the NCX agrees entry for entry and has no DOCTYPE and only `dtb:uid`. Content: no DOCTYPE; `<html xmlns xmlns:epub lang xml:lang epub:prefix="z3998: http://www.daisy.org/z3998/2012/vocab/structure/, se: https://standardebooks.org/vocab/1.0">`; `<body epub:type="bodymatter z3998:fiction">`; `<section id="chapter-1" role="doc-chapter" epub:type="chapter">`; `<hgroup><h2 epub:type="z3998:ordinal z3998:roman">I</h2><p epub:type="title">Loomings</p></hgroup>`; word joiners (U+2060) on both sides of every em dash; `abbr`, `cite`, `time`, `i epub:type="se:name.vessel.ship"`; `xml:lang` for 18 languages including `und`, `he-Latn` and `enm`; verse as `<blockquote epub:type="z3998:verse"><p><span>line</span><br/><span class="i1">indented line</span></p></blockquote>`; drama in chapter 40 as `p.persona` with `<b epub:type="z3998:persona">` names, `p epub:type="z3998:stage-direction"`, and `blockquote epub:type="z3998:song"`; 22 `<a href="endnotes.xhtml#note-21" id="noteref-21" role="doc-noteref" epub:type="noteref">21</a>`; `endnotes.xhtml` as `<section id="endnotes" role="doc-endnotes" epub:type="endnotes footnotes"><h2 epub:type="title">Endnotes</h2><ol><li id="note-1" epub:type="endnote footnote"><p>text <a href="chapter-24.xhtml#noteref-1" role="doc-backlink" epub:type="backlink">↩︎</a></p></li>`. CSS: `core.css` opens with `@charset` and `@namespace epub "http://www.idpf.org/2007/ops"`, uses `hyphens` with `-webkit-`, `-moz-`, `-epub-` and `adobe-hyphenate` variants, `text-wrap: pretty`, `font-variant-numeric`, `break-*` and `page-break-*`, `@media all and (prefers-color-scheme: dark)`, `@supports`, and `:root[__ibooks_internal_theme]` selectors; the compatible build has rewritten every `[epub|type~="x"]` selector to a class `.epub-type-contains-word-x` and added those classes to the markup (`class="epub-type-contains-word-chapter"`), plus structural helper classes `first-child`, `has-h2`, `nth-child-2`. EPUBCheck: two `aria-labelledby` errors on the two `nav` elements.

**Standard Ebooks, Moby Dick (advanced build).** Same text; no NCX, no `guide`, no OPF2 cover meta, no `spine toc`; four `image/svg+xml` items (cover, title page, logo, one illustration) and `properties="svg"` on the four documents that embed them; CSS keeps `[epub|type~="..."]` attribute selectors (so `@namespace` support is required to style anything semantic). A pure EPUB 3 package.

**Standard Ebooks, Alice (compatible build, toolset 4.1.0).** 18.4 MB because of 88 PNG illustrations at 1x and 2x (`srcset="../images/illustration-2-2x.png 2x, ../images/illustration-2.png 1x"`) inside `<figure class="half-page" id="illustration-2">` (or `full-page`), each `img` with a full-sentence `alt` and `epub:type="se:image.color-depth.black-on-transparent se:image.style.realistic z3998:illustration"`; a `loi.xhtml` back-matter file with `<nav id="loi" epub:type="loi">` whose entries are `p`-wrapped links to `#illustration-N`; an `epigraph.xhtml` with `<section epub:type="epigraph" role="doc-epigraph"><blockquote epub:type="z3998:poem">` and `<span epub:type="title">` on the first line; `dc:language en-GB`; two titles (`main` and `short`); `display-seq` on the illustrator; `alternate-script` (Cyrillic) for the cover artist. 20 spine items. Same `aria-labelledby` validator messages.

### 9.5 Markup patterns a renderer must handle (illustrative snippets)

These snippets are written for this study to reproduce the patterns above; they are not copies of book files.

Gutenberg EPUB-Maker chapter heading with converter id and a page marker whose number lives only in `title`:

```html
<span class="pageno" title="57"/>
<h2 id="pgepubid00014">XII</h2>
<p class="c11">March, 1918.</p>
<p>The first paragraph of the chapter follows the dateline.</p>
```

Gutenberg verse: lines broken with `br`, indentation by a margin class, a signature paragraph:

```html
<p><i>Give gladly, you rich, 'tis no more than you owe,<br/>
<span class="c5">For the weal of your Country, your wealth's overflow!</span><br/>
Even I that am poor am performing my part.</i><br/>
<br/></p>
<p class="sig padbase"><i>WILLIAM WATSON</i><br/></p>
```

Gutenberg footnote pair (2017 Ebookmaker), reference in the text and note at the end of the chapter:

```html
<p>She spoke in the slang of the quarter.<a id="FNanchor_1_1"/><a href="chapter-4.html#Footnote_1_1"
   class="fnanchor"><span class="label">[1]</span></a> Nobody answered.</p>
<div class="footnote">
  <p><a id="Footnote_1_1"/><a href="chapter-4.html#FNanchor_1_1" class="pginternal"><span class="label">[1]</span></a>
     Listen, boy, if I were in the square with my mastiff ...</p>
</div>
```

Gutenberg preformatted data converted from plain text (no `pre`, leading spaces are text):

```html
<p id="id00807">Natural resources:<br/>
    petroleum, natural gas, coal, bauxite,<br/>
    nickel, salt, timber, hydropower<br/>
</p>
```

Gutenberg inverted heading levels and a cross-file anchor:

```html
<h5><a id="CHAPTER_VI">CHAPTER VI.</a></h5>
<h4 id="pgepubid00017">ENJOLRAS AND HIS LIEUTENANTS.</h4>
```

Gutenberg title block as a layout table with an inline emblem image:

```html
<table width="400" cellpadding="2" cellspacing="0" summary="" border="1"><tbody><tr><td>
<p class="titleblock c2">MAN AND MAID</p>
<p class="titleblock c3">By ELINOR GLYN</p>
<p class="titleblock c4"><img src="images/illus-emb.png" alt="emblem" width="80" height="82"/></p>
</td></tr></tbody></table>
```

Word-exported equations as inline images with empty alt (Relativity):

```html
<p class="MsoNormal">so that the velocity is given by
<img width="80" height="46" alt="" src="images/image003.jpg"/> in the moving system.</p>
```

Standard Ebooks chapter opening, note reference, verse and endnote:

```html
<section id="chapter-1" role="doc-chapter" epub:type="chapter">
  <hgroup>
    <h2 epub:type="z3998:ordinal z3998:roman">I</h2>
    <p epub:type="title">Loomings</p>
  </hgroup>
  <p>Call me Ishmael.<a href="endnotes.xhtml#note-1" id="noteref-1" role="doc-noteref" epub:type="noteref">1</a></p>
  <blockquote epub:type="z3998:verse">
    <p>
      <span>Sweet fields beyond the swelling flood,</span>
      <br/>
      <span class="i1">Stand dressed in living green.</span>
    </p>
  </blockquote>
</section>

<section id="endnotes" role="doc-endnotes" epub:type="endnotes">
  <h2 epub:type="title">Endnotes</h2>
  <ol>
    <li id="note-1" epub:type="endnote">
      <p>The note. <a href="chapter-1.xhtml#noteref-1" role="doc-backlink" epub:type="backlink">↩︎</a></p>
    </li>
  </ol>
</section>
```

Standard Ebooks figure with a responsive image and a list-of-illustrations entry:

```html
<figure class="half-page" id="illustration-2">
  <img alt="A white rabbit wearing a waistcoat stands upright consulting a pocket-watch."
       src="../images/illustration-2.png"
       srcset="../images/illustration-2-2x.png 2x, ../images/illustration-2.png 1x"
       epub:type="z3998:illustration"/>
</figure>

<nav id="loi" epub:type="loi">
  <h2 epub:type="title">List of Illustrations</h2>
  <ol><li><p><a href="chapter-1.xhtml#illustration-2">When the Rabbit took a watch out of its waistcoat-pocket</a></p></li></ol>
</nav>
```

Standard Ebooks navigation document (both navs, the landmarks typed):

```html
<nav aria-labelledby="toc-title" id="toc" role="doc-toc" epub:type="toc">
  <h2 id="toc-title" epub:type="title">Table of Contents</h2>
  <ol>
    <li><a href="text/titlepage.xhtml">Titlepage</a></li>
    <li><a href="text/halftitlepage.xhtml">Moby Dick</a>
      <ol><li><a href="text/chapter-1.xhtml">I: Loomings</a></li></ol>
    </li>
  </ol>
</nav>
<nav aria-labelledby="landmarks-title" id="landmarks" epub:type="landmarks">
  <h2 id="landmarks-title" epub:type="title">Landmarks</h2>
  <ol>
    <li><a href="text/chapter-1.xhtml" epub:type="bodymatter">Moby Dick</a></li>
    <li><a href="text/endnotes.xhtml" epub:type="backmatter endnotes">Endnotes</a></li>
  </ol>
</nav>
```

Standard Ebooks CSS selector forms (advanced versus compatible):

```css
@namespace epub "http://www.idpf.org/2007/ops";
[epub|type~="z3998:verse"] p > span { display: block; padding-left: 1em; text-indent: -1em; }
/* compatible build rewrites the same rule as: */
.epub-type-contains-word-z3998-verse p > span { display: block; padding-left: 1em; text-indent: -1em; }
```

### 9.6 CFI vectors

All vectors use the package and content document of CFI 1.1 section 3.1.10 (spine is the third child of `package`, hence `/6`; `chap01ref` is the second itemref, hence `/4`; `body01` is the second child of `html`; `para05` is the fifth paragraph, hence `/10`; its children are the text `xxx`, an `em` containing `yyy`, and the text `0123456789`). A clean-room parser written from the grammar for this study parsed all 25 valid vectors, serialized each back to the identical string, rejected the malformed ones, and produced every ordering below.

Parse expectations:

| # | CFI | Expected parse |
| --- | --- | --- |
| 1 | `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:10)` | steps 6, 4 (id chap01ref); indirection; steps 4 (id body01), 10 (id para05), 3; character offset 10. Points just after "9". |
| 2 | `epubcfi(/6/4[chap01ref]!/4[body01]/16[svgimg])` | the `img` element (eighth child element of body). |
| 3 | `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/1:0)` | before "xxx". |
| 4 | `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/2/1:0)` | before "yyy" inside `em`. |
| 5 | `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/2/1:3)` | after "yyy". |
| 6 | `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/2/1:3[yyy;s=b])` | same point; text assertion before = "yyy"; side bias b. |
| 7 | `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/1:3[xx,y])` | offset 3 in the first text chunk, that is after "xxx"; text assertion before "xx" and after "y" (element boundaries ignored, the spec's own example). |
| 8 | `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/2/1:3[,y])` | trailing-only text assertion. |
| 9 | `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05],/2/1:1,/3:4)` | range; parent ends at para05; start after the first "y"; end after "3". |
| 10 | `epubcfi(/6/14[chap05ref]!/4[body01]/10/2/1:3[2^[1^]])` | assertion text is `2[1]` after unescaping. |
| 11 | `epubcfi(/6/4!/4/10/2/1:3[Ф-"spa ce"-99%-aa^[bb^]^^])` | assertion text `Ф-"spa ce"-99%-aa[bb]^`; in an IRI the space becomes `%20` and `%` becomes `%25`. |
| 12 | `epubcfi(/6/2[titleref]!/4/2/1:0)` | first itemref (title page). |
| 13 | `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:0)` | before "0123456789". |
| 14 | `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05])` | the paragraph element itself. |
| 15 | `epubcfi(/6/4[chap01ref]!/4[body01]/16[svgimg]@50:30)` | spatial x=50, y=30 inside the image. |
| 16 | `epubcfi(/6/4[chap01ref]!/4[body01]/16[svgimg]@20:60)` | spatial x=20, y=60. |
| 17 | `epubcfi(/6/6[chap02ref]!/4/2~23.5@12.3:97.6)` | temporal 23.5 s then spatial. |
| 18 | `epubcfi(/6/6[chap02ref]!/4/2~23.5)` | temporal only. |
| 19 | `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/1)` | odd terminal step, implicit `:0`; equal to vector 3. |
| 20 | `epubcfi(/6/4[chap01ref]!/4[body01]/0)` | virtual element before body's first chunk. |
| 21 | `epubcfi(/6/4[chap01ref]!/4[body01]/22)` | virtual element after the last child (body has 10 element children, last even index 20). |
| 22 | `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/2[;s=b])` | the `em` element with side bias before (attached to preceding content); empty value part. |
| 23 | `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/2/1:3[yyy;s=b;vnd.funston.lineid=12,13])` | vendor parameter with a two-value csv; ignored by other systems. |
| 24 | `epubcfi(/6/4[chap01ref])` | an itemref alone (the start of chapter 1). |
| 25 | `epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/1:0[;s=a])` | offset with only a side-bias parameter. |

Must be rejected by the grammar: `epubcfi(/06/4!/4/1:3)` (leading zero), `epubcfi(/6/4!/4/1:3[unclosed)`, `epubcfi(/6/4!!/4/2)`, `epubcfi(6/4)`, `epubcfi(/6/4!/4/1:3.5)` (character offsets are integers), `epubcfi(/6/4!/4/10[a]b]/1:0)`, `epubcfi(/6/4!/4/16@1.50:20)` (trailing zero). Must be rejected by semantic checks after parsing: `epubcfi(/6/4!/4/1:3,/2,/4)` (range parent ends in an offset), `epubcfi(/6/4!/4/1:3[a;s=b],/2,/4)` (side bias in a range), `epubcfi(/6/4!/4/16@150:20)` (spatial outside 0 to 100), `epubcfi(/6/4[chap01ref]!/4/16:3)` (character offset on an element step that is not an `img` with alt).

Orderings (left sorts before right unless stated):

| Left | Right | Result |
| --- | --- | --- |
| 12 | 3 | before (itemref 2 before itemref 4) |
| 3 | 4 | before (chunk 1 before element 2) |
| 4 | 5 | before (offset 0 before 3) |
| 5 | 6 | equal (assertions ignored) |
| 13 | 1 | before (offset 0 before 10) |
| 14 | 3 | before (element before any position inside it) |
| 3 | 2 | before (element 10 before element 16) |
| 2 | 15 | before (no spatial offset before a spatial offset) |
| 15 | 16 | before (y 30 before y 60; x is less important) |
| 18 | 17 | before (temporal alone before temporal plus spatial) |
| 19 | 3 | equal (implicit `:0`) |
| 20 | 3 | before (virtual 0 before everything) |
| 2 | 21 | before (virtual n+2 after everything) |
| 3 | 10 | before (itemref 4 before itemref 14) |
| 5 | 9 | after (point after "yyy" is after the range start at `/2/1:1`) |
| 9 | 1 | before (range compares by its start) |
| 22 | 4 | before (the `em` element before the first character inside it; they are distinct locations) |
| 6 | 23 | equal (parameters ignored) |
| 24 | 12 | after (itemref 4 after itemref 2) |
| 3 | 25 | equal (side bias ignored) |
| 7 | 3 | after (offset 3 after offset 0) |

Round trips: every vector above serializes back to its input exactly, including escapes, when the serializer keeps assertion text verbatim, re-escapes the special characters, writes integers without leading zeros and numbers without trailing zeros, and preserves a leading comma in a trailing-only text assertion.

### 9.7 Font obfuscation vector

See section 5.2. Identifier `ocf-font_obfuscation`; key `b562e83e1606579a9c6c70a75f4a14d2ea36b09e`; first 20 bytes before `b563e83e1617569a9c6870b7180e5194ea39b084` and after `00010000001101000004001047444546000f001a`; the result is a TrueType font with 17 tables. The wrong key `67f12bb4154d714fbc8c681bbaae422116fbd137` (identifier `ocf-font_obfuscation-bis`) yields `d292c38a...`, which fails the header check.

### 9.8 Href resolution vectors

Container with entries `mimetype`, `META-INF/container.xml`, `EPUB/package.opf`, `EPUB/text/ch1.xhtml`, `EPUB/images/Café.png` (stored in NFD), `EPUB/images/Cover.png`, `EPUB/images/plate 1.jpg`, `EPUB/css/style.css`. The package document's content URL is `<root>/EPUB/package.opf`.

| Reference | Found in | Resolves to | Diagnostic |
| --- | --- | --- | --- |
| `text/ch1.xhtml` | package.opf | `EPUB/text/ch1.xhtml` | none |
| `../images/Caf%C3%A9.png` | text/ch1.xhtml | `EPUB/images/Café.png` via NFC to NFD fallback | `href.normalizationFallback` |
| `../images/plate%201.jpg` | text/ch1.xhtml | `EPUB/images/plate 1.jpg` | none (decoding is normal) |
| `../images/plate 1.jpg` | text/ch1.xhtml | same | `href.rawSpace` |
| `/EPUB/css/style.css` | text/ch1.xhtml | `EPUB/css/style.css` | `href.pathAbsolute` |
| `../../../../EPUB/css/style.css` | text/ch1.xhtml | `EPUB/css/style.css` | `href.leakingRelative` |
| `ch1.xhtml#note-3` | text/ch1.xhtml | same document, fragment `note-3` | none |
| `images/cover.png` | package.opf | `EPUB/images/Cover.png` by case-insensitive fallback | `href.caseFallback` |
| `images/COVER.PNG` | package.opf | `EPUB/images/Cover.png` by case-insensitive fallback | `href.caseFallback` |
| `images/missing.png` | package.opf | nothing | `resource.missing` |
| `https://example.org/x.png` | text/ch1.xhtml | external; not fetched | `resource.remote` |
| `file:///etc/passwd` | text/ch1.xhtml | refused | `resource.forbiddenScheme` |
| `META-INF/container.xml` | text/ch1.xhtml | served (it exists) | `href.metaInf` |
| `text/ch1.xhtml?x=1` | package.opf | `EPUB/text/ch1.xhtml` | `href.queryDropped` |

### 9.9 Property expansion vectors

| Value | Attribute | Expanded |
| --- | --- | --- |
| `chapter` | `epub:type` | `http://idpf.org/epub/vocab/structure/#chapter` |
| `z3998:verse` with `epub:prefix="z3998: http://www.daisy.org/z3998/2012/vocab/structure/"` | `epub:type` | `http://www.daisy.org/z3998/2012/vocab/structure/#verse` |
| `dcterms:modified` | `meta property` | `http://purl.org/dc/terms/modified` (reserved prefix) |
| `rendition:layout` | `meta property` | `http://www.idpf.org/vocab/rendition/#layout` |
| `media:duration` | `meta property` | `http://www.idpf.org/epub/vocab/overlays/#duration` |
| `a11y:certifiedBy` | `meta property` | `http://idpf.org/epub/vocab/package/a11y/#certifiedBy` |
| `nav` | manifest `properties` | `http://idpf.org/epub/vocab/package/item/#nav` |
| `page-spread-left` | spine `properties` | `http://idpf.org/epub/vocab/package/itemref/#page-spread-left` |
| `onix:codelist5` | `meta scheme` | `http://www.editeur.org/ONIX/book/codelists/current.html#codelist5` |
| `marc:relators` | `meta scheme` | `http://id.loc.gov/vocabulary/relators` |
| `foo:bar` without declaration | any | unknown; ignored, kept as text |
| `:bar` | any | invalid; ignored |
| `codelist5` (no prefix) | `meta scheme` | invalid (scheme has no default vocabulary) |

## 10. Things to avoid

- Do not validate before opening. EPUBCheck-style strictness refuses eleven of the fourteen books in this corpus for one reason or another (guide images, invalid attributes, aria attributes the schema lags on). Validation is for Funston's own fixtures in tests, never for the reader's open path.
- Do not treat the NCX as authoritative when a navigation document exists, and do not treat heading levels as the table of contents when either exists. Conversion tools get heading levels wrong (Les Misérables) and leave NCX stubs (Shiji).
- Do not count characters in code points or grapheme clusters for CFI offsets. The specification counts UTF-16 code units, and Swift `String.count` counts grapheme clusters. Use `utf16.count` and `utf16` offsets everywhere a CFI is built or resolved.
- Do not build CFIs over a DOM that dropped whitespace-only text nodes or merged adjacent text nodes differently from the source. The odd indices count every chunk between elements, so the parse tree used for CFI must be the raw one, not a layout-cleaned one.
- Do not store positions as a single progression fraction. It drifts with every font-size change, and Readium's own locators carry CFI for that reason. Progression is the last-resort fallback, never the primary key.
- Do not hash the identifier after stripping a `urn:uuid:` prefix, or before stripping internal whitespace, when deriving the font key. Both mistakes produce a key that fails the sfnt check on every real book.
- Do not fetch DTDs, external entities or remote stylesheets while parsing, ever. The test suite checks this and the threat model forbids it.
- Do not let author CSS set the colour of the page. Every Gutenberg `pgepub.css` says black on white, and a dark-mode user would get a white page.
- Do not respect `position: absolute`, `float` or percentage margins literally in a phone-width column. Gibbon's `p { margin: 15% }` leaves a column 70 percent of a phone's width; the Gutenberg `.pagenum { position: absolute; left: 1% }` places numbers over text.
- Do not expose empty elements to VoiceOver. Gutenberg page-number spans are empty with the number in `title`; Elektra has paragraphs that are only `<br/>`; an element with no label is "tick noise".
- Do not fragment lists and tables into unrelated VoiceOver elements to make a narrow request work. Container start and end announcements are invariants.
- Do not implement the Adobe obfuscation variant without the sfnt-header check. Its key derivation is only commonly documented, not specified, and a wrong guess must fail safely.
- Do not assume the first spine item is the start of the book or that it is linear. Les Misérables starts with a `linear="no"` cover wrapper.
- Do not assume one spine item per chapter. Gutenberg splits by byte size, so a chapter can straddle two files (Shiji, the Factbook, Gibbon); the TOC fragment, not the file boundary, is the chapter start.
- Do not load the whole book to show the first page. Lazy parse per spine item; the Factbook's 11.9 MB of XHTML will otherwise take seconds before the first line appears.
- Do not synthesize "Page N of M" from the renderer's own pagination as if it were a book property; label it as a position in the chapter and prefer print page labels when the book has them.
- Do not pass instructions found in a book's metadata or content to anything that acts on them; they are text to display.

## 11. Open questions for the merged spec

1. Adobe font obfuscation key derivation. The IDPF algorithm is verified against the W3C test font. The Adobe variant (`http://ns.adobe.com/pdf/enc#RC`, 16-byte UUID key over 1024 bytes) is reported consistently in community sources but no Adobe specification was found. Decide whether to implement it behind the header check (recommended, cheap) or to report Adobe-obfuscated fonts as protected and fall back to system fonts.
2. Tag-soup fallback scope. The HTML parsing algorithm is large. The merged spec should fix the subset: tree construction for the elements in STD-19, implied end tags for `p`, `li`, `dt`, `dd`, `tr`, `td`, `th`, `option`, foster-parenting ignored (misnested table content flattened), unknown elements treated as inline spans. Decide whether any book in Funston's routing actually needs more than that (none in this corpus does; all fourteen are well-formed XML).
3. Unlisted resources. The W3C test says an image not in the manifest "should not be shown". This study recommends showing it with a diagnostic because public-domain conversions omit manifest entries by accident. The merged spec must choose and record the deviation.
4. Synthetic TOC thresholds. "Fewer than two entries into the body" and "all entries in one spine item that is not the longest" are proposals from two books. Validate against a larger sample of archive.org Gutenberg items before freezing.
5. Pre-paginated items in version one. Flowed text with a diagnostic, or a page image rendered from the XHTML? The second needs a layout engine for absolutely positioned content that the text renderer does not have.
6. CFI generation for images and inline SVG. Decide whether a position inside a figure is stored as the `img` element step or as a spatial offset; the comparator supports both.
7. Position record versioning. The v2 locator proposed in section 6 adds `spineIndex` and `renderer`. Decide whether `spineIndex` is stored (fast) or derived from `href` on load (survives a change of edition).
8. Which EPUB 3.4 draft features to track. The 3.4 drafts add media types and tests (AVIF, JPEG XL) and tighten the hidden-TOC rules already adopted here. The merged spec should cite 3.3 as normative and list 3.4 deltas to watch.
9. Whether `epub:type` or `role` wins when they disagree, and whether `z3998:` and `se:` vocabularies are recognized by expanded URL (recommended) or by prefix text.
10. The clamping rule for author margins and the inline rendering of absolutely positioned page numbers need a measured default (a fraction of the column width) chosen with real books under Dynamic Type sizes.
11. How the reader records that a Gutenberg book had its footnote apparatus destroyed in conversion (Gibbon) so that the item screen can offer the HTML or text edition instead.
12. Whether the reader should honour `rendition:flow="paginated"` when VoiceOver is off, or always scroll. The current Readium integration follows the user's reading layout setting and switches to scrolling under VoiceOver.

## 12. Clean-room statement

This study was written from the W3C and IDPF specifications, the DAISY Z39.86-2005 standard, PKWARE's APPNOTE, the Standard Ebooks Manual of Style, the W3C epub-tests repository (test metadata and fixtures only), the IDPF epub3-samples table, EPUBCheck as a black-box validator, and fourteen downloaded books. No source code of any EPUB reading system (Readium, foliate-js, epub.js, EPUBKit, calibre's viewer, or any other) was opened, read or consulted. The CFI parser and comparator and the font deobfuscation routine used to produce the vectors in section 9 were written during this study from the specification text alone and exist only in the scratchpad; they are described in prose and pseudocode here, not copied. Web searches about the Adobe obfuscation variant returned forum posts and tool documentation; the one result that was a tool's source file was not opened. Specification text is quoted only in short normative phrases with section citations. Book text is quoted in short phrases from public-domain works. No downloaded file was copied into the repository; every fixture is linked by URL.

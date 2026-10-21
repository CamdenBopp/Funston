# Study: Readium Swift Toolkit, Shared and Streamer (parsing and model side)

Requirement prefix: RDS. Written for the clean-room EPUB spec. The implementer who works from this document never sees Readium's source.

## Provenance

- Repository: https://github.com/readium/swift-toolkit
- Tag studied: 3.11.0, the version Funston links today
- Commit: d82f44f4f05d87add9e22a8b75abbd61dce745dd
- Commit date: 2026-07-17 10:23:25 +0200
- License: BSD 3-Clause, copyright 2017 Readium (LICENSE at the repository root)
- Package platform floor: iOS 15
- Products read: ReadiumShared (Sources/Shared), ReadiumStreamer (Sources/Streamer), plus the small ReadiumInternal helper module both depend on. The Navigator product was opened only at the one place that builds the locator it reports to the app, so this study can say what Funston actually has on disk.
- Method: cloned with depth 1 into a scratch directory outside the repository, read only, never built or run. Tests were read for the edge cases they cover, not for their data.

Everything the brief named exists under the names it used, with three naming notes:

- "Fetcher" is Readium 2 vocabulary. In 3.x the same role is split into a Container (a set of entries keyed by relative URL) and a Resource (one entry, read lazily, optionally by byte range). This study uses the 3.x names.
- "StringSearchService" still exists but is marked deprecated. The EPUB parser wires the newer content-based search service, so both are described and the deprecated one is labelled as such.
- "Zip" (marmelroy) is pulled in only because it bundles the Minizip C library; the Swift-level ZIP reading goes through Readium's own fork of ZIPFoundation. Dependency versions are floor constraints in the manifest (CryptoSwift 1.10.0, Zip 2.1.2, Fuzi fork 4.0.0, ZIPFoundation fork 3.0.1, SwiftSoup 2.13.5); no lock file pins exact revisions for the library itself.

What is verified by reading code is stated plainly. Claims that come only from the toolkit's README or guides are marked "docs claim".

## What it is and why it matters to Funston

Readium's Shared and Streamer products turn an `.epub` file into an in-memory publication: a manifest (metadata, reading order, resources, navigation collections) over a lazily read container, with services attached for synthetic positions, locating, content extraction and search. The Navigator (not studied here) renders that model in web views.

Funston depends on this model in three concrete ways:

1. Opening. Funston/UI/EPUBReaderController.swift retrieves the asset, opens it with the default parser and `allowUserInteraction: false`, and shows one of two user-facing failures ("isn't a book this app can read" for format not recognised, "looks damaged" for any reading error).
2. Contents. It reads the manifest's table of contents (a tree of links) and flattens it with a depth per row for BookContentsController.
3. Positions. It stores the navigator's current locator as JSON text in the `book_positions` table (`identifier`, `file_name`, `locator`, `updated_at`) and decodes it with the non-legacy JSON initializer when the book is reopened.

The replacement reader has to open the same corpus (Project Gutenberg EPUBs served by archive.org as original files), build an equivalent table of contents, and read every locator row Funston has already written. Everything else in this study (positions, content iteration, search) is what a native reader needs so that saved places, read-aloud, and find-in-book can be built on the same model.

## Architecture in our words

The open pipeline has four stages. Internal names are given once, for orientation only.

1. Asset retrieval (AssetRetriever). A resource factory turns an absolute URL into a Resource (a file handle for `file:` URLs, an HTTP range reader for `http(s):`). A format sniffer guesses the format first from hints (file extension, declared media type), then by refining that guess against content: magic bytes for a blob, the `mimetype` entry and `META-INF` files for a container. If the format is a ZIP, an archive opener turns the Resource into a Container. The result is an Asset: either a single resource with a Format, or a container with a Format. Formats are sets of specification tags (zip, epub, lcp, adept, html, xml, pdf, and so on) plus a media type and extension.
2. Publication opening (PublicationOpener). Each registered content protection gets a chance to unwrap the asset (LCP does the decryption; a built-in fallback only marks LCP and Adobe ADEPT books as restricted). Then a composite parser tries EPUB, PDF, Readium web publication, image set and audio set parsers in order until one accepts the asset. The accepted parser returns a builder: manifest, container and a bag of service factories. App-supplied transforms may edit all three before the Publication is built.
3. EPUB parsing (EPUBParser). Reads `META-INF/encryption.xml` into a map from entry URL to encryption record; reads `META-INF/container.xml` for the first rootfile; parses that package document into metadata, reading order, resources and the EPUB 2 guide; parses the nav document, falling back to the NCX; wraps the container so obfuscated fonts are decoded on read; and registers four services: content (HTML iterator), guided navigation (SMIL media overlays), positions (synthetic, 1024-byte pages) and search (content-based).
4. Publication and services. The Publication exposes the manifest, resolves a URL to a Resource (services first, then the container, then the container ignoring query and fragment), and hands out services by protocol type. Services receive a weak reference to the publication, the manifest and the container at build time.

Two cross-cutting pieces matter for the native build:

- The URL model. Every href in the model is a string that is a valid percent-encoded relative URL (a container-root-relative path such as `OEBPS/ch1.xhtml`) or an absolute URL for remote resources. Comparisons are done after normalisation (lowercase scheme, dot segments removed) and lookups fall back to ignoring query and fragment.
- The JSON model. Every model type (Manifest, Link, Metadata, Locator, and the rest) round-trips through a JSON value type with one serializer: sorted keys, slashes not escaped, null-valued keys dropped, empty nested objects dropped. This is the encoding Funston has on disk.

## Requirements

Each requirement: statement, why, specification citation where one exists, edge cases, how to test. "Verified" means read in the code at the commit above.

Specification short names used below:

- EPUB 3.3: W3C Recommendation, https://www.w3.org/TR/epub-33/
- OPF 2.0.1: Open Packaging Format 2.0.1, https://idpf.org/epub/20/spec/OPF_2.0.1_draft.htm
- OPS 2.0.1: Open Publication Structure 2.0.1, https://idpf.org/epub/20/spec/OPS_2.0.1_draft.htm
- NCX: ANSI/NISO Z39.86-2005 section 8.4, as profiled by OPF 2.0.1 section 2.4.1
- CFI 1.1: EPUB Canonical Fragment Identifiers 1.1, https://idpf.org/epub/linking/cfi/epub-cfi.html
- MO 3.3: EPUB Media Overlays 3.3, https://www.w3.org/TR/epub-mediaoverlays-33/
- RWPM: Readium Web Publication Manifest, https://readium.org/webpub-manifest/
- Locator model: https://readium.org/architecture/models/locators/ and the HTML extension https://readium.org/architecture/models/locators/extensions/html.html
- ZIP APPNOTE: PKWARE APPNOTE.TXT, section 4.4.17 (file name)

### Container (OCF)

RDS-01 ZIP access shall be random access through the central directory, with each entry read lazily and by byte range.
- Why: Gutenberg EPUBs are small, but the reader must not inflate the whole book to show a chapter, and the positions service needs entry sizes without reading entries at all.
- Citation: EPUB 3.3 section 4.1.3 (ZIP container requirements). Entry names: ZIP APPNOTE 4.4.17.
- Verified: the central directory is read once at open; a Resource per entry exposes estimated length (uncompressed size), archive properties (compressed size when deflated, uncompressed when stored, plus a compressed flag) and a streaming read with optional range. Two backends exist: a Minizip reader (local files only, tried first) and a ZIPFoundation reader (local files and HTTP sources). For deflated entries the Minizip backend satisfies a range by inflating from the entry start and discarding bytes up to the offset; the ZIPFoundation fork exposes a range extraction call whose cost for deflated entries is not visible in this repository.
- Edge cases: ZIP64 end-of-central-directory (the HTTP path caches the last 65557 + 76 bytes to cover both forms); stored (method 0) versus deflated (method 8) entries; directories are skipped; entries with empty names after normalisation are skipped; CRC checking is skipped on full reads.
- Test: open a book whose spine files are deflated and another whose files are stored; read a 100-byte range at offset 5000 from each; compare to the bytes of the extracted file. Confirm no entry is inflated when only the central directory is needed (instrument the inflate call).

RDS-02 Entry keys shall be normalised relative paths: leading slashes removed, dot segments resolved, and the original stored name retained for the actual read.
- Why: some archivers store names with a leading slash; resolving such a name against a base URL replaces the base path and every lookup fails.
- Citation: ZIP APPNOTE 4.4.17.1 says entry names are relative and must not start with a slash; EPUB 3.3 section 4.1.3 forbids relative paths that escape the container.
- Verified: both backends strip every leading slash, drop entries that become empty, normalise dot segments, and key the entry by the normalised relative URL. The Minizip backend remembers the verbatim stored name and looks it up exactly first, then with the leading slash removed.
- Edge cases: duplicate names after normalisation (last one wins in the dictionary); names containing `..` that climb above the root keep the leading `..` segment and will not match anything.
- Test: repack a sample with `/OEBPS/ch1.xhtml` as the stored name and confirm `OEBPS/ch1.xhtml` resolves.

RDS-03 The `mimetype` entry shall be used for format detection only, with surrounding whitespace ignored, and its absence shall not prevent a file with an `.epub` extension from opening.
- Why: real books have a trailing newline in `mimetype`, or omit it; refusing them helps nobody.
- Citation: EPUB 3.3 section 4.1.3.1 requires the entry to be first, stored, and exactly `application/epub+zip`; the candidate is deliberately more lenient.
- Verified: the hint sniffer accepts the `epub` extension or the EPUB media type as sufficient to produce an EPUB format. The container sniffer then reads `mimetype`, trims whitespace and newlines, and adds the EPUB tag if the value matches `application/epub+zip` (parameters ignored). Neither entry position nor compression method is checked. The EPUB parser only requires the Format to carry the EPUB tag and the asset to be a container.
- Edge cases: a `.zip` extension with a correct `mimetype` entry is also recognised as EPUB; a `.epub` extension with a `mimetype` entry saying something else is still treated as EPUB (the hint already decided).
- Test: three fixtures: canonical, `mimetype` with trailing newline, `mimetype` missing but `.epub` extension. All three open.

RDS-04 `META-INF/container.xml` shall be parsed with the OCF container namespace, and the first `rootfile` element's `full-path` shall name the package document; a missing or unreadable `container.xml`, or no `rootfile`, is a fatal open error.
- Why: this is the only entry point to the package.
- Citation: EPUB 3.3 section 4.2.6.2 (container.xml) says the first rootfile is the default rendition.
- Verified: only the first rootfile is read; its `media-type` attribute is not checked; other rootfiles (multiple renditions) are ignored. The `full-path` value goes through the lenient href rule (RDS-09) and is a path relative to the container root.
- Edge cases: `full-path` with spaces or non-ASCII; a rootfile whose target entry does not exist (fatal at the next step, "missing file").
- Test: a `container.xml` with two rootfiles where the second is the real EPUB 3 package; expect the first to be used.

RDS-05 `META-INF/encryption.xml` shall be parsed into a map from normalised entry URL to an encryption record (algorithm URI, compression method, original length, scheme), and any failure to read or parse it shall yield an empty map rather than an error.
- Why: obfuscated fonts are common in commercial and some Gutenberg-derived books; the map decides which entries need decoding on read.
- Citation: EPUB 3.3 section 4.2.6.3 (encryption.xml) and section 4.4 (resource obfuscation); XML Encryption 1.1 for `EncryptedData`, `EncryptionMethod`, `CipherData/CipherReference`; the IDPF compression extension namespace `http://www.idpf.org/2016/encryption#compression`.
- Verified: for each `EncryptedData` child of the root: `EncryptionMethod@Algorithm` and `CipherData/CipherReference@URI` are required, else the element is skipped; the URI goes through the lenient href rule and is normalised; a `KeyInfo/RetrievalMethod@URI` equal to `license.lcpl#/encryption/content_key` sets the scheme to the LCP URI; the first `EncryptionProperties/EncryptionProperty/Compression` with `Method` and `OriginalLength` sets compression to `deflate` when Method is `8`, otherwise `none`, and the original length. The record is also copied onto the matching manifest link as an `encrypted` property.
- Edge cases: namespace prefixes other than the usual ones (the parser binds namespaces by URI, so prefixes are irrelevant); `CipherReference` URIs relative to the container root (they are not resolved against anything; the spec says they are container-root relative).
- Test: an encryption.xml listing one obfuscated font and one unknown-algorithm entry; the map has two entries; the unknown algorithm entry is served unchanged.

RDS-06 The IDPF font obfuscation algorithm shall be decoded on read: key = SHA-1 (20 bytes) of the publication's unique identifier after removing every XML whitespace character (U+0020, U+0009, U+000D, U+000A); the first 1040 bytes of the entry are XORed with the key repeated cyclically; the rest is untouched.
- Why: Gutenberg's own output does not obfuscate fonts, but many EPUB 3 books from other producers in the corpus do, and an undecoded font renders as nothing.
- Citation: EPUB 3.3 section 4.4.3 (obfuscation key) and 4.4.4 (obfuscation algorithm), algorithm URI `http://www.idpf.org/2008/embedding`.
- Verified: the identifier is the one selected by the package's `unique-identifier` attribute (RDS-15); whitespace is removed with the Foundation whitespace-and-newline set, which is broader than the four code points the spec lists; the decode is applied in a streaming wrapper that tracks the read offset so ranged reads starting inside or past the 1040-byte window stay correct.
- Edge cases: entries shorter than 1040 bytes (decode up to the entry length); ranged reads whose start is beyond 1040 (no XOR at all); identifier containing non-ASCII (hashed as UTF-8).
- Test: see vector V-04 in the fixtures section. Also: read bytes 1030..1050 by range and compare with the same slice of the full decoded entry.

RDS-07 The Adobe font obfuscation algorithm shall be decoded on read: key = the 16 bytes obtained by removing the `urn:uuid:` prefix and all hyphens from the unique identifier and decoding the remaining hex digits; the first 1024 bytes are XORed with the key repeated cyclically.
- Why: older InDesign and Adobe Digital Editions exports use it; Adobe's algorithm URI is `http://ns.adobe.com/pdf/enc#RC`.
- Citation: not part of the W3C specification; documented by Adobe ("font mangling" for EPUB) and referenced from EPUB 3.3 section 4.4 as a non-standard mechanism.
- Verified: the prefix removal is a plain string replace, so an identifier that is not a URN UUID yields whatever hex pairs survive; pairs that fail to parse are dropped, which can shorten the key silently.
- Edge cases: uppercase hex digits (parsed fine); identifiers that are not UUIDs (key may be shorter than 16 bytes or empty; an empty key must disable decoding rather than crash).
- Test: see vector V-05.

RDS-08 Obfuscation decoding shall be skipped entirely when the unique identifier is empty or is exactly the bare prefix `urn:uuid:`, and entries whose algorithm URI is neither of the two known ones shall be served unchanged.
- Why: a bare or empty identifier was a reported crash and data corruption case; XORing with a key derived from nothing corrupts valid fonts.
- Verified: both conditions are checked before any key is derived; unknown algorithms fall through untouched (the encryption record still appears on the manifest link so the app can tell the entry is protected).
- Test: the empty-identifier case must return the entry byte-for-byte.

RDS-09 Every href read from XML (package document items, nav document, NCX, encryption.xml, SMIL) shall be accepted when it is a valid percent-encoded URL; otherwise the fragment (from the first `#`) and then the query (from the first `?` before it) shall be split off verbatim, the remaining path percent-encoded, and the parts reassembled.
- Why: many real books write `my chapter.xhtml` or `ch1.xhtml#section one`; encoding the whole string would turn `#` into `%23` and break fragment navigation (this was a fix landed in 3.11.0).
- Citation: EPUB 3.3 section 5.1.2 and 3.3 (hrefs must be valid URL strings); RFC 3986.
- Verified: fragment is split first so a `?` inside a fragment stays in the fragment; the already-encoded query or fragment is reattached without re-encoding; an empty href yields no URL.
- Edge cases: `chapter one.xhtml?title=intro#frag` keeps both separators; a path that is valid but contains a literal `%` not followed by hex is treated as invalid and re-encoded (`%25`).
- Test: see vectors V-01 to V-03.

RDS-10 Hrefs in the package document shall be resolved against the package document's own directory, dot segments normalised, producing a container-root-relative path with no leading slash; hrefs with a scheme stay absolute (remote resources).
- Why: Gutenberg packages live in `OEBPS/` and reference `images/...` and `../` paths; the container keys are root-relative.
- Citation: EPUB 3.3 section 5.4.2 (`href` on item is relative to the package document); RFC 3986 section 5.2 (reference resolution) and 6.2.2 (normalisation).
- Verified: resolution keeps the query and fragment of the reference; a reference starting with `/` is returned unchanged (and then matches no entry, since entry keys have no leading slash); a base that is a file (not ending in `/`) resolves against its parent directory.
- Edge cases: base `content.opf` at the root (resolves to plain names); references that climb above the root keep `..` and match nothing; a reference that is only a fragment resolves to the base document plus fragment.
- Test: vectors V-06 to V-08.

RDS-11 The public href model shall be: a string that is a percent-encoded relative URL or an absolute URL; equality is tested after normalisation (lowercase scheme, dot segments removed, nothing else); link lookup by href tries the exact normalised string, then the string with query and fragment removed; lookup descends into each link's alternates and children.
- Why: locators store the href; navigation links carry fragments; both must find the same reading-order item.
- Citation: RWPM Link object (`href`); RFC 3986 section 6.
- Verified: an empty href becomes `#`; templated hrefs (RFC 6570) exist in the model but never come from EPUB parsing; percent-encoding case and unreserved-character decoding are not normalised, so `ch%41.xhtml` and `chA.xhtml` are different hrefs.
- Test: a locator with href `OEBPS/ch1.xhtml#p12` must resolve to the reading-order link `OEBPS/ch1.xhtml`.

### Package document

RDS-12 The package document shall be read from the rootfile path; an unreadable entry is a fatal "missing file" error and an XML parse failure is a fatal decoding error.
- Citation: EPUB 3.3 section 5 (package document); OPF 2.0.1 section 1.3.
- Verified: the whole document is loaded into an XPath-capable XML DOM; the package namespace is bound by URI (`http://www.idpf.org/2007/opf`), so prefixes in the file do not matter, but a package document with no namespace at all matches nothing and yields an empty manifest rather than an error.
- Test: strip the default namespace from a valid package and confirm the resulting failure mode is visible (empty reading order should be reported as unreadable, see RDS-58).

RDS-13 EPUB 2 and EPUB 3 shall not be distinguished by the `version` attribute; both metadata forms shall be read everywhere, with the EPUB 3 form taking precedence when both appear.
- Why: real books mix forms (EPUB 3 packages carry `<meta name="cover">`, EPUB 2 packages carry `dcterms:modified`), and the corpus is Gutenberg's EPUB 3 output with EPUB 2 compatibility baked in.
- Citation: EPUB 3.3 section 5.5.1 (`version` attribute); OPF 2.0.1 section 1.3.2 (default version).
- Verified: the `version` attribute is read (with a default string when absent) and then not used for any decision. Every rule below states its EPUB 2 and EPUB 3 forms.
- Test: the same book saved as EPUB 2 and as EPUB 3 should yield the same metadata except where the forms genuinely differ.

RDS-14 Metadata shall be collected as an ordered list of (property, vocabulary URI, value, id, refines-target) from all `meta` and Dublin Core children of `metadata`, including the EPUB 2 wrappers `dc-metadata` and `x-metadata`; EPUB 3 `meta` uses `property` and element text; EPUB 2 `meta` uses `name` and `content`; Dublin Core elements use the element name with the `dcterms` vocabulary; property prefixes resolve through the package `prefix` attribute first, then the reserved prefixes, and an unprefixed property belongs to the default package vocabulary.
- Why: everything else (titles, roles, series, accessibility) is a query over this list.
- Citation: EPUB 3.3 section 5.5.6 (`meta`), 5.6 (vocabularies, `prefix` attribute, reserved prefixes: a11y, dcterms, marc, media, onix, rendition, schema, xsd); OPF 2.0.1 section 2.2 (dc-metadata, x-metadata).
- Verified: reserved vocabularies plus `calibre` (`https://calibre-ebook.com`) and `tdm` (`http://www.w3.org/ns/tdmrep#`) are known; the `dc:` prefix is treated as `dcterms`, and a `prefix` declaration mapping to the Dublin Core elements namespace is folded into dcterms as well; values are trimmed of surrounding whitespace; `refines` has its first character removed unconditionally (it is assumed to start with `#`); properties and link rels are parsed with the same prefix rule; `metadata/link` elements are collected with `rel`, `href`, `refines`. Metadata not consumed by the model is kept as "other metadata" keyed by vocabulary URI concatenated with the property name, with refinements folded into an object under an `@value` key. Within the default vocabulary only `cover` is consumed.
- Edge cases: `refines="id"` without `#` loses its first character (deviation; our spec should treat a value without `#` as the id itself); duplicate properties are kept in order (first or last wins depends on the rule); whitespace inside `prefix` declarations.
- Test: a package with a custom prefix `foaf: http://xmlns.com/foaf/spec/` and `<meta property="foaf:depiction">` must produce an other-metadata key starting with the FOAF URI.

RDS-15 The unique identifier shall be the text of the `dc:identifier` element whose `id` equals the package element's `unique-identifier` attribute; absence yields no identifier (and disables obfuscation decoding).
- Citation: EPUB 3.3 section 5.5.2 (`unique-identifier`) and 5.5.4.1 (`dc:identifier`); OPF 2.0.1 section 2.2.10.
- Verified: an EPUB 2 `dc-metadata` wrapper is searched too; the value is not trimmed here (trimming happens only in the obfuscation key step); other identifiers are not retained individually (they land in other metadata as a list under the dcterms identifier key).
- Edge cases: `unique-identifier` naming a missing id; several identifiers with the same id (first match).
- Test: a package where the first `dc:identifier` is an ISBN and the second, referenced by `unique-identifier`, is a URN; expect the URN.

RDS-16 Titles shall be chosen as follows: the main title is the first `dc:title` refined by `title-type` = `main`, ordered by the `display-seq` refinement, else the first `dc:title`; the subtitle is the first `dc:title` with `title-type` = `subtitle`; a title is a localised string built from the element text keyed by its language (element `xml:lang`, else package `xml:lang`, else the first `dc:language`) plus every `alternate-script` refinement keyed by its `xml:lang`; `sortAs` comes from the `file-as` refinement of the main title (EPUB 3) or `<meta name="calibre:title_sort">` (EPUB 2).
- Citation: EPUB 3.3 section 5.5.4.4 (`dc:title`), D.3.3 (`title-type`), D.3.1 (`alternate-script`), D.3.6 (`display-seq`), D.3.7 (`file-as`); OPF 2.0.1 section 2.2.1.
- Verified: `display-seq` ordering is a string comparison, so `10` sorts before `2`; a title with no language and no translations is a plain string; when exactly one language is known it is still emitted as a plain string, not a one-entry map; title types `short`, `collection`, `edition`, `expanded` are recognised but not surfaced.
- Edge cases: a package with several `main` titles (first by display-seq); a title element whose text is empty (yields an empty string, not nil).
- Test: Gutenberg packages usually carry one `dc:title` and no `title-type`; verify the fallback path. A Standard Ebooks package carries `title-type` refinements; verify the main/subtitle split.

RDS-17 Contributors shall be read from `dc:creator`, `dc:publisher`, `dc:contributor` and `media:narrator` metadata; a role is taken from the `role` refinement (EPUB 3) else the `opf:role` attribute (EPUB 2); MARC relator codes `aut`, `trl`, `edt`, `pbl`, `art`, `ill`, `clr`, `nrt` route the contributor into the typed lists (authors, translators, editors, publishers, artists, illustrators, colorists, narrators); a `dc:publisher` is always a publisher and a `media:narrator` always a narrator; a `dc:creator` without a known role is an author; a `dc:contributor` without a known role goes to the generic contributors list with its role string kept; `file-as` (EPUB 2 attribute) becomes the sort key; names are localised strings per RDS-16.
- Citation: EPUB 3.3 section 5.5.4.3 (`dc:creator`, `dc:contributor`), D.3.9 (`role`); OPF 2.0.1 section 2.2.2 and 2.2.6 (`opf:role`, `opf:file-as`); MARC relators `http://id.loc.gov/vocabulary/relators`.
- Verified: only the first `role` refinement is used; a creator with an unknown role (for example `cmp`) is still filed as an author and keeps `cmp` in its roles list, because the "known role" test and the "creator means author" fallback interact that way.
- Edge cases: Gutenberg writes `<dc:creator id="author_0">Name, Given</dc:creator>` with `<meta refines="#author_0" property="role" scheme="marc:relators">aut</meta>` and `file-as` refinements; those parse into authors with `sortAs` nil (the EPUB 3 `file-as` refinement on a creator is not read, only the EPUB 2 attribute is). This is a gap worth closing in our spec.
- Test: one package with EPUB 3 refinements and one with EPUB 2 attributes; expect identical typed lists.

RDS-18 Languages shall be the ordered list of `dc:language` values; the first is the publication language; element language for localised strings falls back from element `xml:lang` to package `xml:lang` to the first `dc:language`.
- Citation: EPUB 3.3 section 5.5.4.2; BCP 47.
- Verified: values are not validated or canonicalised (`en_US` stays as written).
- Test: a package with `xml:lang="en-US"` on the package element and no `xml:lang` on the title; the title's language is `en-US`.

RDS-19 Dates shall be parsed as: modified = the first parseable `dcterms:modified` meta (EPUB 3), else `dc:date` with `opf:event="modification"` (EPUB 2); published = `dc:date` without an `opf:event` or with `opf:event="publication"`; the parser accepts ISO 8601 subsets by string length (4: year; 7: year-month; 10: date; 11 and 16: date plus zone; 19: date-time without zone; 25: date-time with offset), strips any fractional seconds first, and treats missing zones as UTC.
- Citation: EPUB 3.3 section 5.5.4.5 (`dcterms:modified`, must be a UTC date-time), 5.5.4.6 (`dc:date`); OPF 2.0.1 section 2.2.7 (`opf:event`).
- Verified: a trailing `Z` is handled by the 20-character default pattern; a value like `2007-01-20` (Gutenberg's usual `dc:date`) parses as a date at midnight UTC; unparseable values become nil silently.
- Test: `2024-03-05T12:34:56Z`, `2024-03-05`, `2024`, `2024-03-05T12:34:56.123Z`, `March 2024` (expect nil).

RDS-20 Subjects shall be every `dc:subject`; when there is exactly one and its text contains commas or semicolons it is split into several subjects at those characters with whitespace trimmed and empties dropped; `opf:authority` and `opf:term` attributes become scheme and code.
- Citation: EPUB 3.3 section 5.5.4.7 (`dc:subject`, `authority`, `term`); OPF 2.0.1 section 2.2.3.
- Verified: the split applies only to the single-subject case; Gutenberg emits many `dc:subject` elements in Library of Congress form (`Man-woman relationships -- Fiction`), which are kept whole; each subject name is a localised string per RDS-16.
- Test: one package with `Fiction, Romance; Classics` as a single subject (three subjects), one with three elements (three subjects, untouched).

RDS-21 Layout shall be `fixed` when the last `rendition:layout` meta says `pre-paginated`, `reflowable` when it says `reflowable`, else `fixed` when an Apple or Kobo display-options file (`META-INF/com.apple.ibooks.display-options.xml`, then `META-INF/com.kobobooks.display-options.xml`) has `<option name="fixed-layout">true</option>` under the platform `*`, else `ipad`, else `iphone`, else any platform; else `reflowable`. Independently, a reading order made only of bitmap images forces `fixed` and adds the Divina profile.
- Citation: EPUB 3.3 section 6.4.2 (`rendition:layout`); the display-options file is an Apple convention, not a specification.
- Verified: `rendition:orientation`, `rendition:spread` and `rendition:flow` are not interpreted; they survive only as other metadata under their vocabulary URI keys. Per-itemref `rendition:*` overrides are discarded (RDS-28). The positions service and the navigator use this single publication-level layout.
- Edge cases: a book declaring `pre-paginated` globally with `rendition:layout-reflowable` on some itemrefs is treated as entirely fixed.
- Test: three fixtures (meta pre-paginated, display-options only, neither).

RDS-22 Reading progression shall come from `page-progression-direction` on the `spine` element: `ltr`, `rtl`, otherwise `auto` (also when the attribute is absent or `default`).
- Citation: EPUB 3.3 section 5.7.1 (`page-progression-direction`).
- Verified: a `readingOrder` element is also searched, which is not an EPUB element (harmless).
- Test: Japanese vertical-writing sample (IDPF samples) must yield `rtl`.

RDS-23 Unconsumed metadata shall be preserved as a map from `vocabularyURI + property` to a string, an object with `@value` and refinement keys, or an array of those, so an app can read rendition hints and custom properties later.
- Verified as described in RDS-14. The media overlay class names are also folded into this map under `mediaOverlay`.
- Test: `rendition:orientation` must be retrievable under `http://www.idpf.org/vocab/rendition/#orientation`.

RDS-24 Accessibility metadata shall be read from the schema.org vocabulary (`accessMode` list, `accessModeSufficient` as a list of comma-separated lists filtered to `auditory`, `tactile`, `textual`, `visual`, `accessibilityFeature`, `accessibilityHazard`, `accessibilitySummary`), conformance from `dcterms:conformsTo` metas and `metadata/link rel="dcterms:conformsTo"` hrefs mapped to the EPUB Accessibility 1.0 (four URL spellings each for A, AA, AAA) and 1.1 (`EPUB Accessibility 1.1 - WCAG 2.x Level Y` strings) profiles, certification from `a11y:certifiedBy` with `a11y:certifierCredential` and `a11y:certifierReport` (as a refinement when the certifier has an id, else as top-level metas or links), and exemptions from `a11y:exemption`; the whole block is omitted when nothing was found.
- Citation: EPUB Accessibility 1.1, https://www.w3.org/TR/epub-a11y-11/, sections 3.5 (discovery metadata) and 4 (conformance and certification); schema.org accessibility properties, https://www.w3.org/2021/a11y-discov-vocab/latest/.
- Verified: unknown profile strings are dropped (not kept as raw); feature and hazard values are open strings.
- Test: the IDPF `accessible_epub_3` sample and a Gutenberg package (which typically has none; expect nil).

RDS-25 Collections and series shall be read from `belongs-to-collection` metas: those whose `collection-type` refinement is not `series` are collections; those whose refinement is `series` are series; each gets `group-position` (as a number), `dc:identifier` and `file-as` refinements; when `calibre:series` metas exist they replace the EPUB 3 series entirely, with `calibre:series_index` as the position.
- Citation: EPUB 3.3 D.3.2 (`belongs-to-collection`), D.3.4 (`collection-type`), D.3.8 (`group-position`); Calibre conventions are not a specification.
- Verified: a `belongs-to-collection` without an id can never be a series (it has nothing to refine) and lands in collections.
- Test: a Calibre-written package with both forms; expect the Calibre series to win.

RDS-26 Media overlay metadata shall be read as: publication duration from the `media:duration` meta without `refines`; per-item duration from `media:duration` refining the item's id, copied onto the link; `media:active-class` and `media:playback-active-class` kept as class names; SMIL clock values parsed per MO 3.3 (`hh:mm:ss.fff`, `mm:ss.fff`, `Nh`, `Nmin`, `Ns`, `Nms`, bare seconds).
- Citation: MO 3.3 section 3.5 (package metadata), SMIL 3.0 clock values.
- Verified: the `ms` suffix is checked before `s` so `1500ms` is 1.5 seconds; invalid values yield nil.
- Test: `0:01:30.5` = 90.5, `90s` = 90, `2h` = 7200, `1500ms` = 1.5, `abc` = nil.

RDS-27 Each manifest `item` shall require `id` and `href` (items missing either are skipped with a warning); the link carries the resolved href (RDS-10), the `media-type` string parsed as a media type (nil if unparseable), relations and properties derived from the union of the item's `properties` and its spine itemref's `properties` tokens: `nav` adds the `contents` relation; `cover-image` adds the `cover` relation, as does an id equal to the `content` of `<meta name="cover">`; `scripted`, `mathml`, `svg`, `remote-resources`, `onix-record`, `xmp-record` populate a `contains` list (`js`, `mathml`, `svg`, `remote-resources`, `onix`, `xmp`); `page-spread-left`, `page-spread-right`, `page-spread-center` and `rendition:page-spread-center` set a `page` property; an encryption record for the href becomes an `encrypted` property object; a `media:duration` refinement becomes the link duration.
- Citation: EPUB 3.3 section 5.6.1 (manifest), 5.6.2 (item), D.4 (item properties: cover-image, mathml, nav, remote-resources, scripted, svg, switch), D.5 (itemref properties: page-spread-left, page-spread-right, rendition page-spread-center); OPF 2.0.1 section 2.3 (manifest). `<meta name="cover">` is an EPUB 2 era convention used by Apple and Calibre, not a specification.
- Verified: the item `id` itself is not kept on the link (it was removed in 3.x); `switch` and `data-nav` properties are ignored; properties on the itemref are merged into the item's token list before interpretation, which is how spine-level `page-spread-*` reach the link.
- Test: a Gutenberg package: the `nav` item gains `contents`; the cover image declared with `properties="cover-image"` gains `cover`; the NCX item has media type `application/x-dtbncx+xml`.

RDS-28 The reading order shall be the spine `itemref`s in document order, each resolved to the manifest item with that `id`; an `idref` that matches nothing is skipped; `linear="no"` (case-insensitive) items are excluded from the reading order and left in resources; an item referenced twice is consumed by the first reference only; every manifest item not consumed by the spine (or by a fallback or media overlay reference) goes to the resources list, in manifest order.
- Citation: EPUB 3.3 section 5.7 (spine), 5.7.2 (`itemref`, `linear`); OPF 2.0.1 section 2.4.
- Verified: itemref `properties` other than page spread tokens (including `rendition:layout-*`, `rendition:orientation-*`, `rendition:spread-*`, `rendition:flow-*`) are discarded; the spine's `toc` attribute (EPUB 2 NCX pointer) is not read, the NCX is found by media type instead (RDS-34).
- Edge cases: an empty spine yields an empty reading order (the open succeeds; our spec should treat it as unreadable, RDS-58).
- Test: a spine with one `linear="no"` item and one dangling idref; reading order has the rest in order; resources contain the non-linear item.

RDS-29 Manifest fallbacks shall be resolved one level deep: the item named by a spine item's `fallback` is removed from resources and attached as an alternate of the spine link; when the spine item is HTML and its fallback is a bitmap, the bitmap becomes the reading-order link (carrying the spine item's properties) and the HTML becomes its alternate; a reading order of only bitmaps is treated as a fixed-layout image publication.
- Why: image-based EPUBs with HTML wrappers render better as a page-per-image publication.
- Citation: EPUB 3.3 section 5.6.2.1 (`fallback`), 3.4 (foreign resources and fallback chains); OPS 2.0.1 section 1.4.
- Verified: deeper chains are not walked (a fallback of a fallback stays in resources); fallbacks on non-spine items are ignored; this is a deviation from the spec's chain walk, acceptable for our corpus (Gutenberg uses no fallbacks) but it must be documented in the merged spec.
- Test: `html -> image` swap; `image -> html` keeps the image primary; `html -> html` keeps the first and attaches the second.

RDS-30 The EPUB 2 `guide` shall be parsed into landmark links (href resolved per RDS-10, `title`, relation from `type`) and used as the landmarks collection only when the nav document provided none; `type` maps `cover` to `cover`, `toc` to `contents`, `text` to `start`, `title-page` to `titlepage`, `notes` to `endnotes`, `acknowledgements` to `acknowledgments`, and anything else to the structure vocabulary URI `http://idpf.org/epub/vocab/structure/#` plus the type; `bindings` shall be ignored.
- Citation: OPF 2.0.1 section 2.6 (guide); EPUB 3.3 section 5.9 says reading systems must ignore `guide` when the nav document has landmarks and treats `bindings` as removed.
- Verified: references without a resolvable href are dropped; a blank title becomes nil.
- Test: an EPUB 2 package with `guide` entries `cover`, `toc`, `text`; expect three landmarks with relations `cover`, `contents`, `start`.

RDS-31 After navigation parsing, reading-order links whose href is equivalent to a landmark with relation `cover`, `start` or `contents` shall gain that relation.
- Why: the navigator and apps look up the first content page and the cover by relation.
- Verified: equivalence uses normalised string comparison including fragment, so a landmark pointing to `ch1.xhtml#start` does not mark `ch1.xhtml`.
- Test: landmark `bodymatter` pointing at the first chapter; that reading-order link has `start`.

### Navigation

RDS-32 The nav document shall be the manifest item carrying the `nav` property; it shall be parsed as XML with the XHTML and `epub` namespaces bound by URI; for each list type the first `nav` element anywhere in the document whose `epub:type` attribute equals exactly `toc`, `page-list`, `landmarks`, `loi`, `lot`, `loa` or `lov` is used; only the first `ol` child of the `nav` (and of each `li`) is read; each `li` produces a link whose label is the first `a` or `span` child's text, whose href is that child's `href` resolved against the nav document's own path, whose relation comes from the child's `epub:type` (`cover`, `toc` to `contents`, `bodymatter` to `start`, else the structure vocabulary URI) and whose children come from the nested `ol`.
- Citation: EPUB 3.3 section 7.2 (nav element definitions), 7.2.2 (content model: `ol` with `li` holding `a` or `span` and an optional nested `ol`), 7.2.3.1 (toc), 7.2.3.2 (page-list), 7.2.3.3 (landmarks), D.1 for the structure vocabulary.
- Verified: the document is parsed as XML, not HTML, so a nav document that is not well-formed XML yields nothing and the NCX fallback kicks in; a `nav` with `epub:type="toc landmarks"` (multiple tokens) matches nothing because the comparison is on the whole attribute value.
- Edge cases: `nav` nested inside `section` or `body > div` (found, since the search is document-wide); headings (`h1` to `h6`) inside `nav` are ignored, as the spec allows; a `li` whose first child is a nested `ol` before its `span` still finds the `span` (first matching child, not first child).
- Test: the Gutenberg nav (a `toc` and a `landmarks` nav, deep nesting in long novels) and the W3C epub-tests navigation fixtures.

RDS-33 Navigation labels shall have whitespace runs collapsed to a single space and be trimmed; an entry with an empty label shall be dropped together with its children; a `span` entry with no href and no children shall be dropped; a `span` entry with children shall get the href `#`.
- Citation: EPUB 3.3 section 7.2.2 ("a" and "span" content requirements; a zero-length label after whitespace collapse is an error; unlinked headings must have a nested list).
- Verified: dropping a mislabelled entry discards its subtree, which is a lossy reading of the spec; our spec should keep the children (promote them) or synthesise a label.
- Test: `<li><span></span><ol><li><a href="a.xhtml">A</a></li></ol></li>` currently loses "A".

RDS-34 When the nav document yields no table of contents (no nav item, unreadable, not XML, or an empty `toc` list), the NCX shall be used: the manifest item whose media type is `application/x-dtbncx+xml`, parsed with the NCX namespace; `navMap/navPoint` (recursive) gives the table of contents and `pageList/pageTarget` (recursive) the page list; each node's label is `navLabel/text` and its href `content@src` resolved against the NCX's own path; `playOrder`, `class`, the page target `type` and `value`, and the `dtb:depth` head meta are ignored; the NCX is never consulted for landmarks.
- Citation: OPF 2.0.1 section 2.4.1 (NCX); NCX 8.4.1 (`navMap`), 8.4.2 (`navPoint`), 8.4.3 (`pageList`).
- Verified: the merge keeps nav-document collections when both exist (the NCX only fills `toc` and `pageList` keys that are missing); a nav document that has only `landmarks` therefore gets its `toc` from the NCX.
- Edge cases: Gutenberg ships both; the nav document wins. An NCX with `navPoint` elements lacking `content` yields entries with `#` only if they have children, else they are dropped.
- Test: delete the nav item from a Gutenberg package and confirm the NCX table of contents matches.

RDS-35 The merged spec shall decide two things the candidate ignores: the `hidden` attribute on `nav` (EPUB 3.3 section 7.2.1: hidden navs are not for rendering as part of the content but are still usable for navigation) and multi-token `epub:type` values. Recommendation: tokenise `epub:type` on whitespace and match any token; read hidden navs for the contents list.
- Test: `epub:type="toc"` with `hidden=""` must still produce the table of contents.

RDS-36 The table of contents model shall be a tree of links: `href` (resolved, may carry a fragment, may be `#` for a grouping label), `title`, optional relation, and children; Funston flattens it depth-first with a depth per row.
- Verified: this is exactly what BookContentsController consumes today (`link.title`, `link.children`, and `go(to:)` with the link).
- Test: a Gutenberg novel with parts and chapters renders as two indentation levels.

### Locator model

RDS-37 A locator shall be encoded as a JSON object with keys `href` (string, required), `type` (media type string, required), `title` (string, optional), `locations` (object, omitted when empty) and `text` (object, omitted when empty); `locations` holds `fragments` (array of strings, omitted when empty), `progression` (number in 0...1), `totalProgression` (number in 0...1), `position` (integer, 1-based), plus any extension keys at the same level, of which the HTML extension defines `cssSelector` (string), `partialCfi` (string) and `domRange` (object); `text` holds `before`, `highlight`, `after` (strings, each omitted when nil). Serialisation sorts keys, does not escape slashes, and drops null values.
- Why: every row in Funston's `book_positions` table is this encoding; the new reader must read it, and should keep writing it so the two readers can be swapped without migration.
- Citation: Locator model (core and HTML extension).
- Verified: the serializer is Foundation's with sorted keys and unescaped slashes; integral doubles print as integers (a progression of exactly 0 or 1 is written as `0` or `1`), so decoders must accept integer literals for the double fields; `position` is written as an integer; the media type string is normalised (lowercase type and subtype, parameters sorted and joined with `;`).
- Edge cases: an extension key with a null value is dropped; `fragments` with one entry is still an array.
- Test: encode, decode, re-encode; the text must be identical (vector V-12).

RDS-38 Locator decoding shall: require `href` and `type` (otherwise fail); require `type` to parse as a media type; require `href` to parse as a URL (strict mode: no automatic percent-encoding); accept a singular `fragment` string by appending it to `fragments`; reject negative `progression`, `totalProgression` or `position` by treating them as absent; keep every unknown key inside `locations` as an extension; tolerate missing `locations` and `text` (empty); and fail when `locations` or `text` is present but not an object.
- Verified: the legacy initializer differs only in href handling (a leading `/` is stripped and a percent-decoded path is encoded), kept for apps migrating from Readium 2. Funston never wrote 2.x locators, so the strict path is the right one.
- Edge cases: `position: 0` is accepted (the non-negative check allows zero although the model documents positions as 1-based); `progression: 1.5` is accepted unchanged (no range check).
- Test: vectors V-13 to V-15.

RDS-39 Locator text shall support two derived operations: sanitising for display (collapse whitespace runs to one space, drop a leading space from `after` and a trailing space from `before`) and re-highlighting a sub-range of `highlight` (the part before the range moves to the end of `before`, the part after moves to the start of `after`, empties become nil).
- Verified: the sub-range is clamped to the highlight; a blank highlight yields a text with no highlight.
- Test: highlight `quick brown fox`, range `brown`; before ends with `quick `, after starts with ` fox`.

RDS-40 A locator produced by an older Readium (href starting with `/`) shall be normalised for a packaged publication by stripping the leading slash; for a remotely served publication the href is relativised against the manifest's `self` link.
- Verified: the navigator applies this before navigating. Funston's rows are 3.x rows and need no stripping, but the native reader should keep the leniency because it is free.
- Test: `/OEBPS/ch1.xhtml` resolves to `OEBPS/ch1.xhtml`.

RDS-41 A DOM range shall be encoded as `start` (required) and `end` (optional) points; a point is `cssSelector` (string, required), `textNodeIndex` (non-negative integer, required) and `charOffset` (non-negative integer, optional); on decode a legacy `offset` key is accepted for `charOffset`.
- Citation: Locator HTML extension (domRange object).
- Verified: the point's selector always names an element; `textNodeIndex` picks the child text node; `charOffset` is the character offset inside it; a missing `end` means a collapsed range. Funston does not store these today (only selections produce them).
- Test: vector V-16.

RDS-42 A locator service shall offer three resolutions: a locator whose href matches a manifest link is returned unchanged; otherwise, if it has `totalProgression`, the locator at that progression is returned with the original title and text; a link resolves to a locator with the fragment moved into `fragments`, `progression` 0 when there was no fragment (nil when there was), the media type of the matching manifest link (fail if none), and the manifest link's title falling back to the link's title; a total progression in 0...1 resolves to the position whose `totalProgression` is the greatest not exceeding it, with `progression` inside that resource interpolated linearly between the resource's first position and the next resource's first position (1.0 when there is no next resource).
- Why: table-of-contents taps and "go to 37 percent" both go through this.
- Verified: a progression outside 0...1 is an error (nil); when positions are empty the result is nil; matching the last position is handled explicitly.
- Test: vector V-11.

### Positions

RDS-43 Synthetic positions shall be computed per reading-order resource, numbered from 1 across the whole publication: a reflowable resource gets `max(1, ceil(L / 1024))` positions, where L is the entry's length in the archive (the compressed size when the entry is deflated, the stored size otherwise), falling back to the resource's uncompressed estimated length when archive properties are unavailable, then to 0; a fixed-layout resource gets exactly 1; the i-th position in a resource of N has `progression = (i - 1) / N`; every position has `totalProgression = (position - 1) / total`, where total is the publication's position count; each position locator carries the link's href, media type (defaulting to `text/html` when the link has none) and title.
- Why: positions are the only publication-wide coordinate a reader can show and store; the navigator's `position` and `totalProgression` values come from here.
- Citation: Readium locator best practices for EPUB (https://readium.org/architecture/models/locators/best-practices/format.html), which describe the 1024-byte convention shared with Adobe RMSDK; no W3C specification.
- Verified: the page length is a constructor parameter defaulting to 1024; the layout decision uses the publication-level layout only (nil counts as reflowable); the result is computed once and cached; the archive length is read from entry metadata, so no entry content is inflated. Note the consequence: for a deflated chapter the count depends on the compressed size, so the same text zipped by two tools yields different position counts. That is a known property of the convention, kept for compatibility with other Readium apps, not a requirement of the text.
- Edge cases: a reading-order link whose entry is missing from the container contributes zero positions and the numbering continues (the navigator then has no position for that resource); an empty reading order yields an empty list.
- Test: vector V-09.

RDS-44 The positions list shall be grouped by reading-order index, so a resource's first position and the next resource's first position bound its total-progression range; this range is what content iteration and search use to interpolate `totalProgression` for arbitrary points.
- Verified in the content iterator and both search services.
- Test: vector V-10.

RDS-45 Positions shall be exposed as a pseudo-resource at the href `~readium/positions` with media type `application/vnd.readium.position-list+json` returning `{"total": N, "positions": [...]}`; when no positions service exists, a manifest link of that media type is fetched instead. This is a Readium web convention and may be dropped by a native reader.
- Test: not needed for Funston.

### Content iteration

RDS-46 Content iteration shall walk the reading order from a start locator (or the beginning), creating a per-resource iterator for each resource whose media type is HTML or XHTML and skipping resources with no supported iterator; the start resource is the reading-order link matching the locator's href (index 0 if none); inside a resource the start element is the element matched by the locator's `cssSelector` (with a leading `:root > ` stripped), else the last element whose progression is below the locator's `progression` when that is strictly between 0 and 1, else the first element (progression exactly 1 means the last element); moving backward past the first element of a resource enters the previous resource at its last element; moving forward past the last enters the next resource at its first.
- Why: read-aloud starts from the saved place and must cross chapter boundaries.
- Verified: resources that fail to load are skipped with a logged warning rather than stopping the iteration; the iterator is bidirectional.
- Test: start at a locator in chapter 3 at progression 0.5; `previous()` repeatedly reaches chapter 2's last element.

RDS-47 An HTML resource shall be segmented into content elements by a document traversal with these rules: parse with an HTML5-tolerant parser; traverse from `body`; every block-level element boundary flushes the pending text into a text element; `br` flushes; text nodes accumulate with whitespace normalised (runs collapsed, leading space dropped after a space); a change of language (nearest `xml:lang`, else `lang`, inherited from ancestors) starts a new segment inside the element; `img` produces an image element whose link is the `src` resolved against the resource href, with a non-blank `alt` attached as the accessibility label (no caption; `figcaption` is not read); `audio` and `video` produce media elements from `src`, else from the first `source` child (further `source` children become alternates, with their `type`), and their descendant content (fallback text) is skipped entirely; a text element has role `body` always (headings, footnotes and quotes are not distinguished in this implementation), a list of segments (each with text, language attribute and its own locator) and a locator whose `cssSelector` names the nearest block ancestor and whose text has `before` = up to 50 raw characters preceding the element in the resource, `highlight` = the element's raw text trimmed, `after` = the trailing whitespace; the last segment's trailing whitespace is trimmed; after traversal each element gets `progression = index / count` and `totalProgression` interpolated in the resource's range from RDS-44.
- Why: this is the unit read-aloud speaks and search indexes; for VoiceOver it is also the natural unit to expose (one element per block).
- Citation: HTML living standard for block-level classification; EPUB 3.3 section 6.3 (content documents) and 6.3.4 (`xml:lang`).
- Verified: an element whose selector cannot be built (detached node) has no `cssSelector`; the `before` context is the raw resource text so far, not the normalised text; the cross-element `before` for a segment is computed from the whole resource's raw text so far, truncated to 50.
- Edge cases: inline elements inside blocks (one element, one or more segments); nested blocks (the inner block flushes the outer's pending text first, giving two elements); text directly inside `body` (an element with the `body` selector); `audio` with fallback text only and no `src` or `source` yields nothing at all.
- Test: the W3C and IDPF samples with mixed-language inline spans; count elements and check segment languages.

RDS-48 A CSS selector for an element shall be: `#` plus the escaped id when the element has an id; otherwise the parent's selector, ` > `, and a segment made of the tag name (a `:` in the tag replaced by `|`), `.` plus each class sorted alphabetically and escaped, and `:nth-child(k)` (1-based position among all element siblings) only when another sibling shares the tag name; the chain stops at the first ancestor with an id or at the document.
- Why: the selector is what the saved locator and the navigator use to find the element again; the native reader needs to both generate and evaluate this subset.
- Verified: escaping keeps letters, digits, `-` and `_`, and backslash-escapes everything else; this is a strict subset of CSS selectors that a native evaluator can implement (`#id`, `tag`, `.class`, `:nth-child(k)`, child combinator).
- Test: vector V-17.

RDS-49 Text tokenisation for speech or search shall split a text element's segments by unit (word, sentence, paragraph) using the platform natural-language tokenizer for the segment's language (falling back to a default language), trimming whitespace from each token and dropping empty tokens; each token becomes a segment whose locator text carries `before` and `after` of up to 50 characters within the original segment.
- Verified: three implementations exist (NaturalLanguage, NSLinguisticTagger, plain string enumeration); the default picks NaturalLanguage on iOS 12 and later.
- Test: a sentence in French inside an English paragraph is tokenised with French rules.

### Search

RDS-50 Search options shall default to case-insensitive, diacritic-insensitive, non-exact, non-regex matching, with the publication's primary language (else the device language) as the comparison locale; whole-word matching is not supported (option absent) in the default algorithm.
- Verified: the option set is reported by the service so the app can show only supported toggles.
- Test: the service's reported options contain `wholeWord` as unset.

RDS-51 The default string matching algorithm shall find every occurrence of the query in a text using the platform string search with case-insensitive and diacritic-insensitive compare options as configured; `exact` switches to literal comparison; `regularExpression` switches to regex matching (and disables the other options); overlapping matches are found by restarting one character after each match start; cancellation is checked between matches.
- Verified: an empty match (possible with a regex) stops the loop.
- Test: query `aa` in `aaaa` returns three ranges.

RDS-52 The content-based search service shall walk content elements in reading order and, within one resource, search a sliding window over the elements' texts joined by single spaces; matches that start within the last `query length - 1` characters of the searchable slice (256 for regex) are deferred until the next element arrives so a query can span two adjacent elements; the window is flushed at every resource boundary and at the end, so no match crosses resources; results are returned in batches, one batch per resource that had matches, and the running result count grows per batch; each result's locator is the segment locator at the match start with its `cssSelector` removed (because the snippet may span elements), `highlight` = the matched text, `before` = up to 200 characters before the match extended backward to a whitespace boundary by at most 100 further characters (trimmed of leading whitespace when it reaches the resource start), `after` = up to 200 characters after extended forward likewise (trimmed of trailing whitespace at the resource end); image alt text and media fallback content are never searched.
- Why: this is the newer service the EPUB parser installs; its snippet rules are what a find-in-book list would show.
- Verified: the lookahead buffer reads further elements to fill the `after` snippet before emitting; a text element with no segments is skipped; errors from a single element are logged and skipped.
- Edge cases: a match that straddles the separator space between two block elements (allowed); a match at the very start of a resource (`before` nil); a query longer than the window of one element (deferred until enough text is present).
- Test: vectors V-18 and V-19.

RDS-53 The deprecated whole-text search service shall be treated as reference only: it extracts each HTML resource's body text (strict XML parse first, HTML5-tolerant parse second, entities unescaped), computes `progression` as the match's UTF-16 offset over the text's UTF-16 length, interpolates `totalProgression` in the resource's position range, takes the title from the table-of-contents entry whose href (ignoring fragment) equals the resource href, and builds 200-character snippets that stop at the next whitespace after the budget runs out.
- Verified: marked deprecated in favour of RDS-52; not installed by the EPUB parser at this commit.
- Test: none required for the native reader.

### Media types, manifest model, resources, errors, protection

RDS-54 Media types shall be parsed per RFC 6838: type and subtype lowercased, parameter names lowercased, the `charset` parameter value uppercased, other values kept; the string form is `type/subtype` followed by `;name=value` pairs sorted by name; `A contains B` holds when types match (with `*` wildcards) and every parameter of A appears in B; `matches` is `contains` in either direction; helpers: HTML means `text/html` or `application/xhtml+xml`; bitmap means avif, bmp, gif, jpeg, jxl, png, tiff, webp; ZIP means `application/zip`, the LCP audiobook and PDF types, or any `+zip` suffix.
- Verified: an empty string or a string without exactly one `/` is not a media type; parameters without `=` are dropped.
- Test: `text/html;charset=utf-8` matches `text/html`; `text/html;charset=ascii` does not match `text/html;charset=utf-8`.

RDS-55 Format sniffing of an opened file shall proceed from hints to content: hint sniffers map extensions and media types (`epub`/`application/epub+zip` to EPUB with the zip tag; `zip`/`application/zip` to ZIP; `html`, `htm`, `xhtml`, `xht` and their types to HTML); blob sniffers refine an unknown format from the first four bytes (`50 4B 03 04`, `50 4B 05 06` or `50 4B 07 08` mean ZIP) and, for formats already known to be XML or unknown, by parsing as XML (root `html` means HTML, with a `body` in the XHTML namespace meaning XHTML; a document starting with `<!doctype html>` means HTML); container sniffers refine a ZIP to EPUB via the `mimetype` entry (RDS-03) and then add the `lcp` tag when `META-INF/license.lcpl` exists or `encryption.xml` carries an LCP key retrieval URI, and the `adept` tag when `encryption.xml` carries an `adept:resource` key info; refinement repeats until no sniffer adds information; blob reads for sniffing are limited to resources under 5,000,000 bytes.
- Verified: sniffers run in a fixed order (JSON, OPDS, RWPM, LCP license, XML, HTML, ZIP, RAR, Readium package, EPUB, audiobook, comic, language, PDF, audio, bitmap); only the ones relevant to EPUB are listed above.
- Test: a file renamed from `.epub` to `.bin` still sniffs as EPUB through the ZIP magic and `mimetype` entry.

RDS-56 The publication manifest model shall hold: metadata; `links` (publication-level links, where services add their pseudo-resources); `readingOrder`; `resources`; and named subcollections keyed by role (`toc`, `pageList`, `landmarks`, `loa`, `loi`, `lot`, `lov`), each a list of collections holding links; a link holds `href`, optional media type, `templated` flag, `title`, relations (lowercased on construction per RFC 8288), properties (open map), optional `height`, `width`, `bitrate`, `duration`, `language` list, `alternates`, `children`; JSON decoding of a manifest drops reading-order and resource links without a media type, accepts the legacy key `spine` for `readingOrder`, and repairs an invalid href by percent-encoding it as a path.
- Citation: RWPM (publication, link, metadata, subcollection schemas); EPUB profile of RWPM (https://readium.org/webpub-manifest/profiles/epub).
- Verified: the EPUB profile is declared by adding the EPUB profile URI to `conformsTo`; `tableOfContents` is a convenience view on the `toc` subcollection's first collection.
- Test: JSON round trip of a parsed Gutenberg manifest.

RDS-57 Resources and containers shall follow this contract: a container has an optional source URL, a set of entry URLs and a lookup by URL returning a resource or nil; a resource has an optional source URL, `estimatedLength` (hint only), `properties` (filename, media type, archive length and compressed flag), and `stream(range:)` where a nil range means everything and ranges are clamped; `read()` accumulates the stream; wrappers that change bytes lose the source URL (the deobfuscation wrapper passes length and properties through because XOR keeps the length; the generic whole-content transforming wrapper reports an unknown length); the publication's `get(href)` consults services, then the container, then the container with query and fragment removed. Errors are one enum: access (file system: not found, forbidden, out of space, I/O; or HTTP), decoding (content malformed), out of memory, unsupported operation, cancelled; Foundation Cocoa and POSIX errors are mapped into these.
- Verified: reading a whole resource monitors available process memory in the memory-aware variant and fails with out-of-memory instead of crashing when the estimated length exceeds what is available.
- Test: reading a missing entry returns nil from the lookup (not an error); reading a corrupt deflate stream returns a decoding error.

RDS-58 The open pipeline shall report, in order: asset retrieval failing with "scheme not supported", "format not supported" or a read error; publication opening failing with "format not supported" (no parser accepted the asset) or a read error that wraps the EPUB parser's own failures (container.xml missing, rootfile missing, package missing, XML parse failure) as decoding errors. The merged spec shall add a check the candidate lacks: an empty reading order after parsing is a failure, not a success.
- Verified: Funston maps the first class to "isn't a book this app can read" and the second to "looks damaged"; the mapping stays valid.
- Test: a ZIP with no `META-INF/container.xml` must produce the "damaged" message, not a blank reader.

RDS-59 Content protection hooks shall be dropped except for detection: `allowUserInteraction` only gates whether the LCP module may prompt for a passphrase, and the built-in fallback marks LCP and Adobe ADEPT containers as "restricted" (every user right denied) so the navigator refuses to render them; a native reader needs only the detection from RDS-55 to show "This book is protected and cannot be opened here".
- Verified: nothing in the EPUB parser depends on the protection layer; the `encrypted` link property (RDS-05) still tells the reader which individual entries are unreadable.
- Test: a sample with an LCP license file shows the protected message before any parsing.

## Algorithms

This section gives the procedures an implementer needs, in our own words.

### A1. Opening an EPUB file

1. Build a resource over the file. Record its length and its filename.
2. Sniff: extension or declared media type gives a provisional format; magic bytes confirm ZIP; open the ZIP (central directory only); read `mimetype` (trimmed) to confirm EPUB; look for `META-INF/license.lcpl` and for LCP or ADEPT key information in `META-INF/encryption.xml` to tag protection.
3. If protected: stop with a protected-book error (RDS-59).
4. Parse `META-INF/encryption.xml` (RDS-05) into the encryption map; errors give an empty map.
5. Parse `META-INF/container.xml` (RDS-04); take the first rootfile path.
6. Parse the package document (RDS-12 to RDS-31) into metadata, reading order, resources, guide.
7. Parse the nav document (RDS-32, RDS-33); if it produced no `toc`, parse the NCX (RDS-34); if no `landmarks` came from the nav document, use the guide.
8. Copy `cover`, `start` and `contents` relations from landmarks onto reading-order links (RDS-31).
9. Wrap the container so entries listed in the encryption map with a known obfuscation algorithm are decoded on read (RDS-06 to RDS-08).
10. Build services lazily: positions (RDS-43), locator resolution (RDS-42), content (RDS-46, RDS-47), search (RDS-52).

### A2. Lenient href to container key

Input: an href string from XML; the base path of the document that contained it.

1. If the string parses as a URL (percent-encoded form, no automatic repair), take it.
2. Else split at the first `#` (fragment, kept verbatim), then at the first `?` in what remains (query, kept verbatim); percent-encode the remaining path with the URL path allowed set; reassemble.
3. If the result has a scheme, it is a remote resource; keep it absolute.
4. Else resolve against the base: if the reference starts with `/`, keep it (it will not match an entry); otherwise take the base's directory (the base itself if it ends with `/`), append the reference, then remove `.` segments and collapse `..` against preceding segments, keeping any `..` that would climb above the root.
5. The container key is the path part only; the fragment and query stay on the link href for navigation.

### A3. Package metadata query model

1. Read the `prefix` attribute on the package element into a prefix-to-URI map (pairs of `prefix: URI` separated by whitespace).
2. Walk the children of `metadata`, in document order, plus the children of `dc-metadata` and `x-metadata` wrappers. For a `meta` with `property`, split at the first `:` into prefix and name; resolve the prefix (declared map first, `dc` means `dcterms`, reserved prefixes next, unknown prefix means the default package vocabulary); the value is the trimmed element text; keep `id` and `refines` (fragment part). For a `meta` with `name`, do the same split on `name` and take the trimmed `content` attribute; no id, no refines. For a Dublin Core element, the property is the local name, the vocabulary is dcterms, the value is the trimmed text, keep `id`.
3. Also collect `metadata/link` elements as (rel resolved the same way, href, refines).
4. Queries are "all entries with property P in vocabulary V", optionally "refining id X". Titles, roles, series, accessibility and media overlays are all such queries (RDS-16 to RDS-26).
5. Everything with no refines target and not in the consumed set becomes other metadata (RDS-23).

### A4. Manifest and spine to reading order

1. Index spine itemrefs by `idref` (first wins).
2. For each manifest item with id and href: resolve the href (A2); merge the item's and its itemref's `properties` tokens; derive relations, `contains`, page spread, encryption, duration (RDS-27). Keep the item's `fallback` and `media-overlay` ids aside.
3. Walk itemrefs in order; skip `linear="no"` and unknown ids; pop the item from the pool; if its fallback id is still in the pool, pop that too and attach per RDS-29; if its media-overlay id is in the pool and that item is SMIL, pop it and attach as an alternate; append to the reading order.
4. The remaining pool, in manifest order, is the resources list.
5. If every reading-order link is a bitmap: layout fixed, add the Divina profile.

### A5. Navigation list to link tree

For a `nav` element (or an NCX `navMap`): for each `li` of its first `ol` (or each `navPoint`): label = first `a` or `span` child's text (NCX: `navLabel/text`), collapsed and trimmed; href = the child's `href` (NCX: `content@src`) through A2 against the navigation document's path; children = recurse into the `li`'s first nested `ol` (NCX: nested `navPoint`s); drop the entry if the label is empty, or if it has neither href nor children; an entry with children but no href gets `#`.

### A6. Synthetic positions

Let total = 0 and pos = 0. For each reading-order link in order: if layout is fixed, N = 1; else L = archive entry length (compressed size if deflated, else stored size; else uncompressed length; else 0) and N = max(1, ceil(L / 1024)); if the entry is missing from the container, N = 0. Emit N locators with `position = pos + i` and `progression = (i - 1) / N` for i in 1...N; pos += N. After the walk, total = pos; set each locator's `totalProgression = (position - 1) / total`. Cache the result per publication.

### A7. Progression to location

Given t in 0...1: find the last position whose `totalProgression` is less than or equal to t (if t is at or beyond the last position's value, take the last position). Let s be the first position's `totalProgression` of that resource and e the first position's value of the next resource (1 if none). Resource progression = 0 if t <= s, 1 if t >= e, else (t - s) / (e - s). Return a copy of the found position with `totalProgression = t` and `progression` as computed.

### A8. HTML content segmentation

State: a stack of block ancestors (each with its selector), a pending segment buffer (normalised text), a raw-text buffer for the current segment, a raw-text buffer for the current element, the raw text of the whole resource so far, the current language, the list of segments for the current element, and the output list.

On entering an element: compute its selector (RDS-48). If it is block-level: flush the element (below) and push it. If it is `br`: flush. If `img`: flush, then emit an image element (RDS-47). If `audio` or `video`: flush, emit the media element, and mark the subtree as skipped until the matching exit.

On a text node (not inside a skipped subtree, not blank): determine its language from the nearest `xml:lang` or `lang`; if it differs from the current language, flush the segment and switch; append the unescaped text to the raw segment buffer and the normalised buffer.

On exiting an element: if it was the skipped media element, clear the skip; if it is block-level: flush the element and pop it.

Flush segment: if the normalised buffer has non-whitespace, create a segment (first segment of an element also loses leading whitespace) with the current language and a locator whose selector is the top of the block stack and whose text is `before` = the last 50 characters of the resource's raw text so far plus the leading whitespace of this segment, `highlight` = the segment's raw text trimmed, `after` = its trailing whitespace; append the raw buffer to the element and resource raw buffers; clear both segment buffers.

Flush element: flush segment; if the start element (from the locator's selector) is the top of the stack and no start index is set yet, record the output count as the start index; if there are segments, trim the last segment's trailing whitespace, emit a text element (role body) with the segments and a locator built like a segment's but from the element raw buffer; clear the element buffer and the segment list.

After traversal: if the start locator's progression is exactly 1, the start index is the last element; assign `progression = index / count` and interpolate `totalProgression`; if no selector was given and the locator's progression is strictly between 0 and 1, the start index is the last element whose progression is below it.

### A9. Sliding-window search within a resource

Maintain the joined text of the elements seen so far in the current resource (single space between elements), a floor (start of the unsearched slice), and a ceiling (end of the slice). On each new text element: append it; set the ceiling to the end; read ahead enough further elements of the same resource to have 300 characters after the ceiling (for `after` snippets); search the slice floor..ceiling; emit every match whose start is before `ceiling - tail`, where tail is `query length - 1` (256 for regex); advance the floor to `ceiling - tail`; drop leading entries that are more than 300 characters before the floor, rebasing offsets. At a resource boundary or at the end: set tail to 0, search once more, emit, reset. The locator for a match is the locator of the segment containing the match start (selector removed), with snippets built per RDS-52.

## Data model and persistence

### What Funston has on disk

Table `book_positions` (Funston/Services/SQLiteStore.swift, migration 4): `identifier TEXT`, `file_name TEXT`, `locator TEXT`, `updated_at REAL`, primary key on the first two. The `locator` column is the JSON string produced by the locator's serializer (RDS-37). Funston's own test writes a minimal `{"href":"ch1.xhtml","type":"application/xhtml+xml"}` and expects it back byte for byte, which confirms the column is opaque text.

The value written in normal use comes from the navigator's location report. By reading where that report is built: the navigator takes the position locator nearest to the first visible point of the first visible resource, replaces its `progression` with the actual scroll fraction in that resource, replaces its `totalProgression` with the interpolated publication fraction (continuous since 3.x, not quantised to a position), and sets `title` to the table-of-contents entry for that resource when one exists. While a jump is pending, the navigator reports the locator it was asked to go to instead, which can therefore be a table-of-contents link resolved per RDS-42 (fragments, progression 0 or absent) or any locator the app passed in.

So a typical row looks like this (illustrative paths; a Gutenberg package nests its files under one directory and names them from the original HTML):

```json
{"href":"OEBPS/2890895155094816955_20512-h-3.htm.xhtml","locations":{"position":41,"progression":0.37142857142857144,"totalProgression":0.19801980198019803},"title":"CHAPTER III","type":"application/xhtml+xml"}
```

A row saved while a contents jump was pending looks like this:

```json
{"href":"OEBPS/2890895155094816955_20512-h-5.htm.xhtml","locations":{"fragments":["pgepubid00012"]},"title":"CHAPTER V","type":"application/xhtml+xml"}
```

Rules the new reader must honour when reading these rows:

- Keys may appear in any order, but Readium wrote them sorted; do not depend on order.
- `progression` and `totalProgression` may be integer literals (`0`, `1`) or decimals.
- `locations` or `text` may be absent entirely.
- `partialCfi` is never present in Funston's rows (the Swift navigator does not write it); `domRange` only appears for selection locators, which Funston does not store; `cssSelector` can appear if a row was saved while jumping to a search result or a first-visible-element locator (Funston has no search today, so it is unlikely but must not crash).
- `href` is a container-root-relative percent-encoded path, equivalent to a reading-order link's href after normalisation; match by RDS-11, ignoring the fragment if the exact match fails.

### Field to native-reader mapping

| Field | Written by Readium as | Native reader use |
| --- | --- | --- |
| `href` | root-relative path of the spine item | pick the spine item (normalised compare, then without fragment) |
| `type` | the item's media type string | sanity check only; do not reject unknown values |
| `title` | contents title for that item | optional label while restoring ("Resuming Chapter III") |
| `locations.position` | 1-based synthetic page across the book | coarse fallback when progression is missing; also the "page x of y" display if we keep the 1024-byte convention |
| `locations.progression` | fraction of the resource scrolled past | primary restore key: scroll to that fraction of the laid-out resource |
| `locations.totalProgression` | fraction of the whole book | progress display; fallback restore via A7 when href is unknown |
| `locations.fragments` | element id from a contents link | scroll to the element with that id |
| `locations.cssSelector` | selector per RDS-48 | if present, evaluate the selector subset against our parsed document and prefer it over progression |
| `locations.partialCfi` | not written | may be ignored; if we ever write CFIs, use the right-hand side after the spine step (CFI 1.1 section 3.1) |
| `locations.domRange` | not stored by Funston | ignore for restore; keep for selections if we add them |
| `text.before/highlight/after` | context around a search result or first visible element | optional: verify the restore landed on matching text and announce it |

### What the new reader should write

Write the same encoding: `href`, `type`, `title`, `locations` with `position`, `progression`, `totalProgression`, sorted keys, no escaped slashes, nothing null. Add `cssSelector` for the first visible block when we have one (it is the most precise key and the one the candidate's own content iterator understands). Keep `fragments` only when the user jumped to an id. This keeps every row readable by either reader during the switch.

### Model summary

- Publication: manifest + container + services.
- Manifest: metadata, links, readingOrder, resources, subcollections by role.
- Link: href, mediaType, templated, title, rels, properties, height, width, bitrate, duration, languages, alternates, children.
- Metadata: identifier, type, conformsTo, localizedTitle, localizedSubtitle, accessibility, modified, published, languages, sortAs, subjects, typed contributor lists, layout, readingProgression, description, duration, numberOfPages, belongsTo (collection, series), tdm, otherMetadata.
- Locator: href, mediaType, title, locations (fragments, progression, totalProgression, position, other), text (before, highlight, after).
- Position list: array of locators grouped by reading-order index.
- Content element: locator plus attributes (language, accessibility label); text elements add role and segments; image elements add the embedded link; media elements add the embedded link with alternates.

## Accessibility

What the candidate offers that a VoiceOver-first reader can build on:

- Per-block elements with language. The HTML content iterator yields one element per block with per-segment language tags inherited from `xml:lang` or `lang`. That is exactly the shape Funston's PDF reader exposes to VoiceOver (one accessibility element per recognised line, tethered to real geometry, in Funston/UI/PDFLineAccessibility.swift). For EPUB the unit should be the block element, with the segment language used to pick the speech voice.
- Alt text. Images carry the `alt` attribute as an accessibility label; media elements carry nothing spoken. Missing alt should surface as "image" rather than silence.
- Table of contents as structure. The nav tree (RDS-36) is the only heading structure the candidate derives; it does not derive heading levels from `h1` to `h6` in content (every text element is role `body`). For a headings rotor the native reader must read heading elements itself.
- Reading progression. `rtl` books and the `page-progression-direction` value matter for swipe direction; the model carries it.
- Accessibility metadata. `accessModeSufficient` containing `textual`, `accessibilityFeature` values such as `structuralNavigation`, `readingOrder`, `alternativeText`, and the summary can be shown on the book's screen so a VoiceOver user knows what to expect before opening. The candidate parses them (RDS-24) and ships a separate display-guide module with localised strings (not studied; docs claim it follows the W3C accessibility metadata display guide).
- Positions as announcements. The synthetic position and total count give a stable "page 41 of 202" that does not change with font size, which is what a screen reader user can memorise. Keep the 1024-byte convention for that reason, even though it is arbitrary.

Gaps to cover in the merged spec, because the candidate leaves them to the web view:

- No heading, list, table, footnote, quote or figure roles in the content model (the role enum exists but only `body` is produced; `figcaption` is explicitly not read).
- No notion of what is on screen; the content iterator is independent of layout, so focus tethering to visible text must come from the renderer.
- Hidden navs and `aria-hidden` content are not filtered.

## Malformed input and failure behaviour

Fatal (open fails with a decoding or missing-file error):

- `META-INF/container.xml` missing, unreadable, not XML, or without a `rootfile`.
- The package document missing or not well-formed XML.
- A ZIP whose central directory cannot be read (the archive opener reports "not a ZIP" as format not supported, which Funston shows as "isn't a book this app can read").

Tolerated silently or with a logged warning:

- `mimetype` missing, wrong, with whitespace, not first, or deflated.
- `encryption.xml` missing, not XML, or with elements lacking an algorithm or cipher reference (those elements are skipped).
- Unknown obfuscation algorithms (entry served as stored), empty or bare-prefix identifiers (decoding disabled).
- Manifest items without id or href (skipped), spine idrefs with no item (skipped), duplicate ids (first wins), items with unparseable media type (link with nil media type; note that such a link is dropped on JSON re-decoding of the manifest, RDS-56).
- A package document without the OPF namespace (parses to an empty manifest; opening "succeeds" with nothing to show, which our spec turns into a failure, RDS-58).
- Nav document missing, not XML, or with no `toc` (fall back to NCX; if that is also missing, the contents list is empty and Funston hides the Contents button).
- Nav entries with blank labels or unlinked leaves (dropped, children lost, RDS-33).
- Hrefs that are not percent-encoded (repaired, RDS-09); hrefs that escape the root or start with `/` (kept, never match).
- Metadata with unparseable dates (nil), unknown accessibility profile strings (dropped), `refines` without `#` (first character lost).
- A chapter entry missing from the ZIP although listed in the spine (zero positions; the navigator will fail to load that page at read time).
- A reading-order resource that cannot be parsed as HTML by the tolerant parser (the content iterator skips it; the deprecated search logs and continues).
- A resource larger than available memory (memory-aware read fails with an out-of-memory error rather than crashing).

One hazard found by reading, not by running: when a per-resource content iterator has been created and its read then fails (the chapter is unreadable or not parseable), every call to it throws again, and both the sequence wrapper around the content iterator and the content-based search loop catch the error, log it and call the same iterator again. By reading, that never advances to the next resource. Our spec must make a failed resource advance the publication iterator (RDS-46) and count as "no matches" for search (RDS-52).

Behaviour we should not copy:

- Opening a book with an empty reading order as a success.
- Discarding navigation subtrees under a blank label.
- Treating a `refines` value without `#` by dropping its first character.
- Ignoring itemref-level rendition overrides without recording a diagnostic.

## Test fixtures and vectors

Public fixtures (download by URL; none of the candidate's test data is reused):

- Project Gutenberg via archive.org: item `manandmaid20512gut`, file `pg20512-images.epub` (EPUB 3 with nav and NCX, `<meta name="cover">` style cover declaration, Library of Congress subjects, `dc:creator` with role and file-as refinements). https://archive.org/download/manandmaid20512gut/pg20512-images.epub
- Project Gutenberg direct: https://www.gutenberg.org/ebooks/11.epub3.images (Alice, EPUB 3) and https://www.gutenberg.org/ebooks/11.epub.noimages (older EPUB 2 build with NCX only).
- IDPF EPUB 3 samples (https://github.com/IDPF/epub3-samples): `childrens-literature` (nav with nested lists, page-list, multiple title types), `moby-dick` (large reflowable, page-list), `wasteland-otf-obf` and `wasteland-woff-obf` (IDPF font obfuscation with `encryption.xml`), `cc-shared-culture` (media overlays, SMIL), `page-blanche` and `cole-voyage-of-life` (fixed layout, `rendition:layout`, page spreads), `haruko-html-jpeg` (fixed layout, right-to-left), `kusamakura-japanese-vertical-writing` (vertical text, rtl), `accessible_epub_3` (accessibility metadata), `linear-algebra` (MathML, `mathml` property).
- W3C epub-tests (https://github.com/w3c/epub-tests): the `pkg-` and `nav-` test publications for package metadata and navigation edge cases, and `cnt-` tests for content documents.
- Standard Ebooks (https://standardebooks.org/ebooks/lewis-carroll/alices-adventures-in-wonderland): EPUB 3 with a `prefix` attribute declaring `z3998` and `se` vocabularies, `title-type` refinements, landmarks nav with `epub:type` on anchors, and `toc.xhtml` as the nav document.

Vectors written from the specifications (expected values computed by hand or with a one-line script, not taken from the candidate):

V-01 href repair: input `text/ch 1.xhtml` gives `text/ch%201.xhtml`.
V-02 href repair with fragment: `text/ch 1.xhtml#p3` gives `text/ch%201.xhtml#p3`.
V-03 href repair with query and fragment: `a b.xhtml?x=1#f?g` gives `a%20b.xhtml?x=1#f?g` (fragment split first, so the second `?` stays in the fragment).
V-04 IDPF key: identifier `urn:uuid:9f1c6a0e-2b7d-4c3e-8a5f-0123456789ab` gives the SHA-1 key `0487e4aa817aef03a962b981bc8a63e7ce43d47b`; the same identifier with a space after the colon and a trailing newline gives the same key (whitespace removed first). Decode: XOR bytes 0..1039 with the 20-byte key cycling; byte 1040 onward unchanged.
V-05 Adobe key: the same identifier gives the 16-byte key `9f1c6a0e2b7d4c3e8a5f0123456789ab` (hex); XOR bytes 0..1023.
V-06 resolution: base `OEBPS/content.opf`, reference `text/ch1.xhtml` gives `OEBPS/text/ch1.xhtml`.
V-07 resolution with climb: base `OEBPS/content.opf`, reference `../images/a.png` gives `images/a.png`.
V-08 resolution of a fragment-only reference: base `OEBPS/nav.xhtml`, reference `#toc` gives `OEBPS/nav.xhtml#toc`.
V-09 positions: three reflowable resources with archive lengths 2048, 1000 and 5000 bytes give 2, 1 and 5 positions (total 8); positions 1..8; resource 3's third locator has `progression = 2/5 = 0.4` and `totalProgression = 5/8 = 0.625`. Lengths 0, 1024 and 1025 give 1, 1 and 2 positions.
V-10 ranges from V-09: resource 2 spans total progression `2/8` to `3/8`; a point 40 percent into resource 2 has `totalProgression = 0.25 + 0.4 * 0.125 = 0.3`.
V-11 progression to location with V-09: t = 0.3 picks position 3 (resource 2, value 0.25), returns `progression = (0.3 - 0.25) / (0.375 - 0.25) = 0.4`, `totalProgression = 0.3`; t = 1.0 picks position 8 with `progression = 1`.
V-12 locator encoding: a locator with href `OEBPS/ch1.xhtml`, type `application/xhtml+xml`, no title, position 3, progression 0, totalProgression 0.25, no text encodes exactly as `{"href":"OEBPS/ch1.xhtml","locations":{"position":3,"progression":0,"totalProgression":0.25},"type":"application/xhtml+xml"}`.
V-13 decoding leniency: `{"href":"a.xhtml","type":"text/html","locations":{"fragment":"p1"}}` decodes with `fragments = ["p1"]`.
V-14 decoding rejection: `{"href":"a.xhtml"}` fails (no type); `{"href":"a b.xhtml","type":"text/html"}` fails in strict mode (space in href) and succeeds in legacy mode as `a%20b.xhtml`.
V-15 negative values: `{"href":"a.xhtml","type":"text/html","locations":{"position":-1,"progression":-0.5}}` decodes with both absent.
V-16 DOM range: `{"start":{"cssSelector":"#p1","textNodeIndex":0,"charOffset":4}}` is a collapsed range; adding `"end":{"cssSelector":"#p1","textNodeIndex":0,"offset":9}` (legacy key) gives an end point with `charOffset = 9`.
V-17 selectors: for `<body><div id="c"><p>a</p><p class="x y">b</p></div></body>` the second paragraph's selector is `#c > p.x.y:nth-child(2)`; for `<body><section><p>a</p></section></body>` the paragraph's selector is `html > body > section > p` (no `nth-child` because no sibling shares the tag).
V-18 cross-element search: resource text `<p>The quick</p><p>brown fox.</p>`, query `quick brown` matches once, with highlight `quick brown`, before `The `, after ` fox.`; the match is emitted only after the second paragraph arrives.
V-19 overlapping matches: query `aa` in element text `aaaa` yields three results at offsets 0, 1 and 2.
V-20 date parsing: `2024-03-05T12:34:56Z` and `2024-03-05T12:34:56.123Z` give the same instant; `2024-03-05` gives midnight UTC that day; `2024` gives 1 January midnight UTC; `March 2024` gives nil.
V-21 media types: `Text/HTML; Charset=utf-8` has string form `text/html;charset=UTF-8` and matches `text/html`.
V-22 nav label cleanup: `<a href="c.xhtml">  Chapter\n   One </a>` gives the title `Chapter One`.
V-23 SMIL clock: `0:01:30.5` = 90.5 s, `1500ms` = 1.5 s, `2h` = 7200 s.

## Things to avoid

- Do not build the DOM of every chapter at open time. The candidate opens in milliseconds because it reads only the central directory, three small XML files and the nav; positions come from entry sizes. Keep chapter parsing lazy.
- Do not derive position counts from inflated sizes if we want position numbers to agree with other Readium apps; but do not promise users that positions mean anything physical either. Pick one convention and name it in the UI ("location", not "page").
- Do not key containers by raw ZIP names; normalise once (RDS-02) and keep the stored name for the actual read.
- Do not compare hrefs as plain strings; normalise dot segments and compare with and without the fragment.
- Do not trust `version`; read both metadata forms.
- Do not drop navigation children when a label is blank (RDS-33), do not require exact `epub:type` equality (RDS-35), and do not strip the first character of `refines` blindly (RDS-14).
- Do not resolve fallbacks only one level and silently; either walk the chain or record a diagnostic.
- Do not ignore itemref rendition overrides without a diagnostic; a mixed fixed/reflowable book exists in the wild even if not in our corpus.
- Do not let an empty reading order open as a blank book.
- Do not use `try!`, force unwraps or `fatalError` on anything read from the file. The candidate has a few of these on paths it considers unreachable (URL classification, hard-coded regexes, "already computed" caches); a clean build should route every such path to a diagnostic.
- Do not read deflated entries by range when the backend inflates from the start on every call; cache the inflated chapter instead.
- Do not let search cross resource boundaries; the candidate's experience is that the windowing complexity is not worth it.
- Do not retry a failing per-resource iterator in place; skip the resource with a diagnostic (see the hazard in the previous section).
- Do not serialise with escaped slashes or unsorted keys; stored rows should stay byte-stable.
- Do not accept hrefs starting with `/` as container-root paths without deciding what they mean; the candidate keeps them and they match nothing.

## Open questions for the merged spec

1. Position convention. Keep the 1024-byte archive-entry convention (compatible with existing rows and other Readium apps) or switch to a layout-based page count? If we keep it, confirm that our ZIP reader reports compressed sizes identically (central directory `compressed size` field) so stored rows restore to the same position.
2. XML parsing without Fuzi. The candidate uses libxml2 through Fuzi for XPath. Foundation's `XMLParser` is event-based and has no XPath; libxml2 is a system library on iOS and can be called directly. Decide between a small DOM over `XMLParser` with hand-written queries and direct libxml2.
3. HTML tolerance. Content documents in EPUB 3 are XHTML and must be well-formed, but real books are not always. The candidate falls back to an HTML5 parser (SwiftSoup) for content iteration and search. Decide whether the native text renderer needs an HTML5 fallback or whether a malformed chapter is shown as a diagnostic.
4. Font obfuscation key hashing. SHA-1 is available from CryptoKit's insecure namespace; confirm that is acceptable rather than vendoring a hash.
5. Deflate. Foundation's `Compression` framework handles raw deflate (RFC 1951), which is what ZIP entries are; confirm the plan for a dependency-free ZIP reader with ZIP64 support (Gutenberg files are small, but archive.org also serves larger originals).
6. Which locator fields the native navigator writes: at minimum `progression`, `position`, `totalProgression`; recommend adding `cssSelector` for the first visible block. Should we also write a CFI (`partialCfi`) for interoperability with other readers? Nothing in Funston's rows needs it.
7. Media overlays. The candidate parses SMIL into a guided-navigation tree (text ref, audio ref with `#t=begin,end` fragments, roles from `epub:type`). Our corpus has none; decide whether to parse SMIL at all or to reject such books gracefully.
8. Heading roles. The content model should carry heading levels, list and table structure for VoiceOver; the candidate does not. Which spec (this one or the navigator study) owns that model?
9. Accessibility metadata display. Do we want the book screen to show accessModeSufficient and features? The parser side is cheap (RDS-24); the display strings are a separate concern.
10. Cover extraction: the cover link is identified by relation (RDS-27); the candidate's cover service additionally renders SVG covers with a size cap (not studied in detail). Does Funston want EPUB covers in its artwork pipeline?

## Clean-room statement

This document was written by reading the Readium Swift Toolkit at the commit named in Provenance and describing its observable behaviour in my own words. It contains no code, comments, docstrings, README text, test data or fixture content from that repository. Internal type names appear only in "Architecture in our words" for orientation and nowhere else carry meaning. Test vectors were derived from the public specifications and computed independently; fixtures are pointed to by public URL. The candidate's source stayed in a scratch directory outside this repository and no file from it was copied, built or executed. An implementer working from this document alone can reproduce the behaviour described here without ever seeing the candidate.

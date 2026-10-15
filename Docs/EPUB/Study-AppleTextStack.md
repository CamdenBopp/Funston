# Study: the Apple native text stack for a clean-room EPUB reader

Requirement prefix: APL. Written 2026-10-14 for the merged EPUB spec. Everything here comes from Apple documentation, WWDC sessions, Apple sample code descriptions, the iOS 27 SDK headers, and throwaway experiments run against the iOS Simulator SDK. No third-party EPUB reader was read.

Numbers in this study are measurements from the setup in section 1 unless a sentence says "documentation says". Where a claim rests only on documentation, the sentence says so.

## 1. Provenance

### Toolchain and hardware used for the experiments

- Host: Apple M2 Pro, 16 GB, macOS 27.0.1 (26A434), Xcode 27.0 (27A266a), Swift 6.4.
- SDK: iPhoneSimulator27.0.sdk. Experiments compiled with `swiftc -O -target arm64-apple-ios18.0-simulator` and run inside booted simulators with `xcrun simctl spawn`, as command-line processes without a UIApplication or run loop. Two runtimes: iOS 18.3.1 (22D8075) on an iPhone 16 device, and iOS 27.0 (24A434) on an iPhone 17 Pro device. The same sources were also built for macOS to compare AppKit's TextKit 2.
- Timings are wall-clock from `CFAbsoluteTimeGetCurrent`, single runs unless a range is given. Simulator timings use the host CPU, so treat them as relative, not as device numbers. Bitmap drawing used a CGBitmapContext at 2x; no GPU.
- Corpus: archive.org item manandmaid20512gut, file pg20512-images.epub (312,819 bytes, 23 entries, Project Gutenberg EPUB-Maker v0.03, XHTML 1.1 with external DOCTYPE, three CSS files, ten chapter files of 21 KB to 62 KB, five JPEG and PNG images, NCX table of contents, OPF 2.0).
- ZIP fixtures made for the study: Info-ZIP `zip -r` (3.0), `zip -r -fz` (forced ZIP64), `ditto -c -k --sequesterRsrc --keepParent` (what Finder's Compress produces), and Python 3 `zipfile` with a stored `mimetype`, a `force_zip64` streamed entry and a UTF-8 flagged name.

### Apple reference pages read (developer.apple.com/documentation unless noted)

TextKit 2 and text layout:
- uikit/textkit (API collection, lists the samples named below)
- uikit/nstextlayoutmanager, uikit/nstextlayoutmanager/layoutqueue, uikit/nstextlayoutmanager/enumeratetextlayoutfragments(from:options:using:), uikit/nstextlayoutmanager/enumeratetextsegments(in:type:options:using:), uikit/nstextlayoutmanager/limitslayoutforsuspiciouscontents, uikit/nstextlayoutmanager/resolvesnaturalalignmentwithbasewritingdirection, uikit/nstextlayoutmanagerdelegate
- uikit/nstextcontentstorage, uikit/nstextcontentstorage/includestextlistmarkers, uikit/nstextcontentmanager, uikit/nstextcontentstoragedelegate, uikit/nstextparagraph, uikit/nstextelement, uikit/nstextlistelement, uikit/nstextrange, uikit/nstextlocation, uikit/nstextselection, uikit/nstextselectionnavigation
- uikit/nstextviewportlayoutcontroller, uikit/nstextviewportlayoutcontrollerdelegate, uikit/nstextviewportrenderingsurface
- uikit/nstextlayoutfragment, uikit/nstextlayoutfragment/state-swift.property, uikit/nstextlayoutfragment/state-swift.enum, uikit/nstextlayoutfragment/enumerationoptions, uikit/nstextlayoutfragment/renderingsurfacebounds, uikit/nstextlayoutfragment/draw(at:in:), uikit/nstextlayoutfragment/textattachmentviewproviders, uikit/nstextlayoutfragment/framefortextattachment(at:)
- uikit/nstextlinefragment, uikit/nstextlinefragment/characterrange, uikit/nstextlinefragment/typographicbounds, uikit/nstextlinefragment/draw(at:in:)
- uikit/nstextcontainer, uikit/nstextcontainer/size, uikit/nstextcontainer/exclusionpaths, uikit/nstextcontainer/maximumnumberoflines
- uikit/nstextattachment, uikit/nstextattachmentviewprovider, uikit/nstextattachmentviewprovider/trackstextattachmentviewbounds, uikit/uitextattachmentviewproviderreusepolicy, uikit/uitextview/register(_:fortextattachmentviewprovidertype:), uikit/nsadaptiveimageglyph
- uikit/nstextlist, uikit/nsparagraphstyle, uikit/nsparagraphstyle/hyphenationfactor, uikit/nsparagraphstyle/usesdefaulthyphenation, uikit/nsparagraphstyle/textlists, uikit/nsparagraphstyle/textblocks, uikit/nsparagraphstyle/lineheightmultiple, uikit/nsparagraphstyle/tabstops, uikit/nsparagraphstyle/basewritingdirection, uikit/nsparagraphstyle/defaultwritingdirection(forlanguage:), uikit/nsparagraphstyle/allowsdefaulttighteningfortruncation
- uikit/nstexttable, uikit/nstextblock, uikit/nstexttableblock, uikit/adding-tables-to-attributed-strings (article)
- uikit/uitextview/textlayoutmanager, uikit/uitextview/init(usingtextlayoutmanager:), uikit/uitextview/isfindinteractionenabled
- foundation/nsattributedstring/key/languageidentifier
- Samples: uikit/using-textkit-2-to-interact-with-text (iOS 16, WWDC21), uikit/enriching-your-text-in-text-views (iOS 27, WWDC26), uikit/display-text-with-a-custom-layout (TextKit 1, iOS 13), uikit/managing-viewport-layout-and-attachment-reuse-in-a-text-view-subclass (article, iOS 27)

Core Text, fonts and Dynamic Type:
- coretext/ctframesettersuggestframesizewithconstraints(_:_:_:_:_:), coretext/ctframesettercreateframe(_:_:_:_:), coretext/ctframegetvisiblestringrange(_:), coretext/ctframegetlineorigins(_:_:_:), coretext/cttypesettersuggestlinebreak(_:_:_:), coretext/cttypesettercreateline(_:_:), coretext/ctlinegetstringindexforposition(_:_:), coretext/ctlinegetoffsetforstringindex(_:_:_:), coretext/ctlinecreatetruncatedline(_:_:_:_:), coretext/kcttypesetteroptionallowunboundedlayout
- coretext/ctrundelegate, coretext/ctrundelegatecallbacks, coretext/kctrundelegateattributename
- coretext/ctrubyannotation, coretext/kctrubyannotationattributename, coretext/kctframeprogressionattributename, coretext/ctframeprogression, coretext/kctverticalformsattributename
- coretext/ctfontmanagercreatefontdescriptorsfromdata(_:), coretext/ctfontmanagerregisterfontdescriptors(_:_:_:_:), coretext/ctfontmanagerregisterfonturls(_:_:_:_:), coretext/ctfontmanagerregistergraphicsfont(_:_:), coretext/ctfontmanagerscope, coretext/kctfontcascadelistattribute
- corefoundation/cfstringgethyphenationlocationbeforeindex(_:_:_:_:_:_:)
- uikit/uifontmetrics, uikit/uifontmetrics/scaledfont(for:), uikit/uifont/preferredfont(fortextstyle:), uikit/uifont/familynames

XML, HTML import, ZIP and compression:
- foundation/xmlparser, foundation/xmlparserdelegate, foundation/xmlparser/shouldresolveexternalentities, foundation/xmlparser/shouldprocessnamespaces, foundation/xmlparser/externalentityresolvingpolicy-swift.enum, foundation/xmlparser/allowedexternalentityurls, foundation/xmlparserdelegate/parser(_:resolveexternalentityname:systemid:), foundation/xmlparserdelegate/parser(_:foundinternalentitydeclarationwithname:value:), foundation/xmlparser/errorcode
- foundation/nsattributedstring/documenttype/html, foundation/nsattributedstring/init(data:options:documentattributes:), foundation/nsattributedstring/documentreadingoptionkey
- compression/compression_stream, compression/compression_stream_init(_:_:_:), compression/compression_stream_process(_:_:), compression/compression_algorithm, compression/compression_zlib, compression/compression_status
- foundation/nsdata/readingoptions, foundation/nsdata/readingoptions/alwaysmapped, foundation/nsdata/readingoptions/mappedifsafe
- SDK headers: usr/include/libxml2/module.modulemap and libxml/module.modulemap (module libxml2), usr/include/zlib.modulemap, usr/include/compression.modulemap, Foundation/NSXMLParser.h (error code values), os/proc.h (os_proc_available_memory, iOS 13)

Accessibility:
- uikit/uiaccessibilityreadingcontent and its six methods, uikit/uiaccessibilitytraits/causespageturn, objectivec/nsobject-swift.class/accessibilityscroll(_:), uikit/uiaccessibilityscrolldirection, uikit/uiaccessibility/notification/pagescrolled, uikit/uiaccessibility/notification/layoutchanged, uikit/uiaccessibility/notification/screenchanged, uikit/uiaccessibility/notification/announcement, uikit/uiaccessibility/post(notification:argument:)
- uikit/uiaccessibilitycustomrotor, uikit/uiaccessibilitycustomrotor/systemrotortype-swift.enum, uikit/uiaccessibilitycustomrotorsearchpredicate, uikit/uiaccessibilitycustomrotoritemresult, uikit/uiaccessibilitycustomrotor/search, objectivec/nsobject-swift.class/accessibilitycustomrotors
- foundation/nsattributedstring/key/accessibilityspeechlanguage, foundation/nsattributedstring/key/accessibilitytextheadinglevel, foundation/nsattributedstring/key/accessibilityspeechipanotation, objectivec/nsobject-swift.class/accessibilityattributedlabel
- uikit/uiaccessibilitytextualcontext, objectivec/nsobject-swift.class/accessibilitytextualcontext, uikit/uiaccessibilitycontainerdatatable, uikit/uiaccessibilitycontainerdatatablecell, uikit/uiaccessibilitycontainertype, objectivec/nsobject-swift.class/accessibilitycontainertype
- objectivec/nsobject-swift.class/accessibilitynexttextnavigationelement (iOS 18), uikit/uiaccessibilitycustomaction/editcategory (iOS 18), uikit/uiaccessibilityelement, uikit/uiaccessibilityelement/accessibilityframeincontainerspace, objectivec/nsobject-swift.class/accessibilityelements, objectivec/nsobject-swift.class/accessibilityelementdidbecomefocused(), uikit/uiaccessibility/isvoiceoverrunning, uikit/uiaccessibility/voiceoverstatusdidchangenotification, uikit/uiaccessibility/isspeakscreenenabled, uikit/uiaccessibilitytraits, uikit/uiaccessibilitytraits/allowsdirectinteraction, uikit/uilargecontentvieweritem
- accessibility/axcustomcontent, accessibility/axcustomcontentprovider
- SDK header UIKit/UIAccessibility.h (reading content protocol comments, the UIAccessibilityTextNavigation category, accessibilityTextInputResponder iOS 18.1)

Speech and audio:
- avfaudio/avspeechsynthesizer, avfaudio/avspeechsynthesizer/usesapplicationaudiosession, avfaudio/avspeechsynthesizer/mixtotelephonyuplink, avfaudio/avspeechsynthesizer/pausespeaking(at:), avfaudio/avspeechsynthesizer/stopspeaking(at:), avfaudio/avspeechboundary, avfaudio/avspeechutterance, avfaudio/avspeechutterance/prefersassistivetechnologysettings, avfaudio/avspeechutterance/init(attributedstring:), avfaudio/avspeechsynthesizerdelegate and its willSpeakRangeOfSpeechString and willSpeak(marker) methods, avfaudio/avspeechsynthesisvoice, avfaudio/avspeechsynthesisvoice/init(language:), avfaudio/avspeechsynthesismarker, avfaudio/avspeechsynthesizer/write(_:tobuffercallback:tomarkercallback:), avfaudio/avspeechsynthesizer/requestpersonalvoiceauthorization(completionhandler:)
- avfaudio/avaudiosession/category-swift.struct/playback, avfaudio/avaudiosession/mode-swift.struct/spokenaudio, avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers, duckothers, interruptspokenaudioandmixwithothers, avfaudio/avaudiosession/setactiveoptions/notifyothersondeactivation, avfaudio/avaudiosession/setcategory(_:mode:options:)
- SDK header AVFAudio/AVSpeechSynthesis.h (availability of every property used below)

Images, selection, find, performance:
- imageio/cgimagesourcecreatethumbnailatindex(_:_:_:), imageio/kcgimagesourcethumbnailmaxpixelsize, imageio/kcgimagesourceshouldcacheimmediately, imageio/kcgimagesourcecreatethumbnailfromimagealways, imageio/cgimagesourcecopytypeidentifiers(), imageio/cgimagesourcecreatewithdata(_:_:), uikit/uiimage/init(data:)
- uikit/uitextinput, uikit/uitextinput/selectionrects(for:), uikit/uitextposition, uikit/uitextrange, uikit/uitextselectionrect, uikit/uitextinputtokenizer, uikit/uitextinputstringtokenizer, uikit/uitextinteraction, uikit/uitextinteractiondelegate, uikit/uitextselectiondisplayinteraction, uikit/uitextloupesession
- uikit/uifindinteraction, uikit/uifindinteractiondelegate, uikit/uifindsession, uikit/uifindsession/performsearch(query:options:), uikit/uitextsearchingfindsession, uikit/uitextsearching-3wkjv, uikit/uitextsearchaggregator-swift.struct, uikit/uitextsearchoptions, uikit/uitextsearchdocumentidentifier
- os/ossignposter, os/recording-performance-data

WWDC sessions (developer.apple.com/videos/play/...):
- wwdc2021/10061 Meet TextKit 2
- wwdc2022/10090 What's new in TextKit and text views
- wwdc2023/10058 What's new with text and text interactions
- wwdc2026/370 Elevate your app's text experience with TextKit
- wwdc2019/248 Creating an Accessible Reading Experience
- wwdc2020/10116 VoiceOver efficiency with custom rotors
- wwdc2021/10121 Tailor the VoiceOver experience in your data-rich apps
- wwdc2026/219 Enhance the accessibility of your reading app
- wwdc2020/10022 Create a seamless speech experience in your apps
- wwdc2023/10033 Extend Speech Synthesis with personal and custom voices
- wwdc2019/227 Font Management and Text Scaling
- wwdc2024/10074 Get started with Dynamic Type
- wwdc2022/10071 Adopt desktop-class editing interactions
- wwdc2025/243 What's new in UIKit (checked for text and accessibility changes; it has none)
- wwdc2018/219 Image and Graphics Best Practices is no longer served on Apple's video pages; the ImageIO reference pages above cover what this study needs from it.

Funston files read for the integration: Funston/UI/EPUBReaderController.swift, Funston/UI/PDFLineAccessibility.swift, Funston/UI/PDFReadingState.swift, Funston/Services/PlaybackController.swift, Funston/Services/SQLiteStore.swift (book_positions), Funston/Services/SettingsStore.swift (readingLayout), Docs/Roadmap.md section 4.

## 2. What it is and why it matters to Funston

Funston opens born-digital EPUBs through Readium 3.11 inside a WKWebView. Readium turns off pagination when VoiceOver is running because pages break the screen reader, maps Dynamic Type to a font-size multiple by hand, and stores positions as Readium Locator JSON. Camden has decided to replace it with a renderer Funston owns: a ZIP reader, an XHTML and CSS pass that produces attributed strings, TextKit 2 pagination, page views, VoiceOver elements modelled on the PDF reader's line elements, and read-aloud through AVSpeechSynthesizer. No WKWebView, no third-party code.

This study answers one question for the merged spec: what do Apple's frameworks give that renderer on iOS 18 and later, and where do they stop. The short version:

- TextKit 2 lays out a 200 KB chapter in about 70 ms (iOS 18.3) to 250 ms (iOS 27 simulator, first run) and about 13 MB of memory, and it can do that on a background thread. Pagination is a cut of the laid-out line fragments at page height. Drawing a page is under 3 ms. This is fast enough that nothing needs to be cached except page-break offsets.
- Core Text paginates the same chapter in 9 to 14 ms, ten times faster, but it has no attachments, lists, selection or hyphenation help, so it is the engine for the two things TextKit 2 cannot do on iOS: ruby annotations and vertical text. Both are out of scope for the first version.
- Foundation's XMLParser reads XHTML fine when it is well formed, but it stops dead at the first undeclared entity in a document without a DOCTYPE and at the first tag-soup error. The fix is a 0.5 ms entity pre-expansion pass and a fallback to libxml2's HTML parser, which the iOS SDK exposes to Swift as `import libxml2`.
- Apple's HTML importer for NSAttributedString is unusable: WebKit backed, main thread only (measured: a background call never returned), 0.7 to 1 s on the first call, and it discards the book's CSS.
- There is no public ZIP API. The Compression framework decodes ZIP entries directly because its zlib mode is raw DEFLATE, and zlib's crc32 is one import away. A minimal central-directory reader is about 150 lines and was verified against Finder, Info-ZIP, Python and Gutenberg archives.
- VoiceOver has a protocol made for exactly this, UIAccessibilityReadingContent, plus the causesPageTurn trait and accessibilityScroll for continuous reading across pages. Since iOS 18 there are also the text navigation element links that make per-paragraph elements read as one text for the Lines rotor, and Apple's WWDC26 guidance is to adopt UITextInput on custom-rendered text for character, word and line navigation and selection.
- AVSpeechSynthesizer gives per-paragraph voices, word-range callbacks for highlighting, pause at word boundaries, and a queue. Funston's PlaybackController owns the audio session, and it already has a hand-off method the reader can use.

Three findings change how to build this compared with the working assumption:

1. The pagination engine should be one TextKit 2 layout manager per chapter with an unbounded container, and pages are cut at line fragment boundaries by the reader, not by TextKit. The alternatives measured worse: TextKit 1's multiple-container pagination was 10 to 15 times slower (935 ms on iOS 18, 1,250 ms on iOS 27 for the 200 KB chapter), and a fresh layout manager per page cost 1.5 to 2.6 times more than one chapter-wide layout.
2. Natural alignment is not safe on iOS 18. On iOS 18.3 an Arabic paragraph with natural alignment and no explicit base writing direction was laid out against the left edge; on iOS 27 it was laid out against the right edge, because iOS 26 added `resolvesNaturalAlignmentWithBaseWritingDirection` with a default of true. The renderer must set the base writing direction on every paragraph itself. The documented helper `NSParagraphStyle.defaultWritingDirection(forLanguage:)` returned left-to-right for "ar" and "he" on every runtime tested, so it cannot be used for this.
3. The accessibility model should follow Apple's WWDC26 guidance rather than the PDF reader's per-line elements: one element per paragraph, linked with the iOS 18 text navigation element properties, the whole page adopting UITextInput so VoiceOver's Characters, Words and Lines rotors and Speak Screen work, plus the reading content protocol and causesPageTurn for read-all. Per-line elements remain the right model for OCR text, where lines are the unit of truth, but for reflowed text they fragment paragraphs.

## 3. Architecture in our words

The recommended pipeline, one stage per subsystem, with the alternatives rejected and why.

### 3.1 Container: a memory-mapped ZIP reader

Open the file with `Data(contentsOf:options:.alwaysMapped)`, find the end-of-central-directory record by scanning backwards, read the central directory once into an entry table, and extract entries on demand by seeking to the local header, skipping its name and extra fields, and inflating the compressed bytes with the Compression framework in `COMPRESSION_ZLIB` mode, which the documentation defines as raw DEFLATE (the same as `deflateInit2` with a window of -15). Verify every extracted entry with `zlib.crc32`. Measured on the Gutenberg EPUB: mapping 0.05 to 0.8 ms, central directory 0.3 ms, inflating all 625 KB of content 2.3 ms with Compression or 0.9 ms with zlib's inflate.

Rejected: `NSFileCoordinator` or Foundation archive APIs (there are none for ZIP on iOS); AppleArchive (not ZIP); extracting the whole book to disk at open (the Gutenberg file is 313 KB but Internet Archive EPUBs of scans run to hundreds of megabytes, and the reader only needs the chapter it is showing).

### 3.2 Package: container.xml, OPF, navigation

Parse `META-INF/container.xml`, then the OPF it points to, with Foundation's XMLParser in namespace-aware mode. Build the manifest (id, href, media type, properties), the spine (idrefs, linear flag, page progression direction), metadata (title, creators, language, identifier) and the navigation document or NCX. This is plain well-formed XML in every EPUB seen; the entity problems below are an XHTML content problem.

### 3.3 Content: XHTML to a DOM-like tree

Each spine item is parsed into a small element tree the renderer owns (tag, attributes, children, text). The parser is XMLParser with namespaces on and all external entity resolution off, fed a byte buffer that has been through two cheap repairs first: control characters stripped, and named HTML entities rewritten to numeric character references. If XMLParser still reports a fatal error, the chapter is re-parsed with libxml2's HTML parser (`htmlReadMemory` with the recover flag), which accepts tag soup and knows the HTML entity set, and a diagnostic is recorded for the chapter. Measured: 2.4 to 3.8 ms to parse the 62 KB chapter with XMLParser, 0.5 ms for the entity pre-pass.

Rejected: Apple's NSAttributedString HTML importer (section 10); libxml2 for everything (XMLParser is the supported Swift surface, and libxml2's own API is C with manual memory management; use it only as the recovery path); writing a tokenizer from scratch (XMLParser's error reporting and encoding detection are good and free).

### 3.4 Style: a CSS subset

There is no system CSS parser. The renderer tokenizes the book's style sheets and `style` attributes, matches a deliberately small selector grammar (type, class, id, descendant and child combinators, no pseudo-classes), applies the cascade by specificity and source order, inherits the font and text properties, and maps the result onto NSAttributedString attributes and NSParagraphStyle. Everything outside the subset in APL-13 is ignored and counted. User settings win over publisher styles for font family, size, alignment, line height and colours, exactly as Funston's Readium preferences do today (publisher styles off, text aligned to the start edge because justified text is harder to track with low vision).

### 3.5 Text model: one attributed string per chapter

The tree and the resolved styles become one NSAttributedString per spine item: fonts via UIFontDescriptor and UIFontMetrics, paragraph styles for alignment, indents, spacing, lists and tab stops, the `languageIdentifier` attribute for runs in another language, `link` for anchors, NSTextAttachment for images, and custom keys the accessibility and navigation layers read (heading level, element id, epub:type, alt text). The string is the single source of truth for layout, VoiceOver, selection, find and speech, so every offset the reader stores is a UTF-16 offset into this string.

### 3.6 Pagination: TextKit 2, one layout per chapter

NSTextContentStorage holding the chapter's NSTextStorage, one NSTextLayoutManager, one NSTextContainer of the page width and unlimited height. `ensureLayout(for: documentRange)` lays the whole chapter out, the reader enumerates the layout fragments and their line fragments into a flat line table, and pages are cut where a line would cross the page height. Layout runs on a serial background queue, then the line table crosses to the main actor.

Rejected: TextKit 1's `NSLayoutManager` with one `NSTextContainer` per page (the classic pagination design) because it was 10 to 15 times slower in the measurement and because TextKit 1 lacks the element model, attachment views and selection navigation; a fresh TextKit 2 layout manager per page (1.5 to 2.6 times slower, and it needs a substring per page which breaks hyphenation and indents at page boundaries); the viewport layout controller (it is for scrolling views and estimates layout outside the viewport, which pagination cannot accept); Core Text as the main engine (fastest, but no lists, attachments, hyphenation or selection support, and the reader would have to rebuild all of them).

### 3.7 Page views: custom UIView per page drawing line fragments

A page is a UIView that draws its range of line fragments from the chapter's layout with `NSTextLineFragment.draw(at:in:)`, offset so the page's first line sits at the top. Measured 0.5 to 3 ms per page at 2x. Images are NSTextAttachment images drawn by the fragment. Block images are attachments on their own paragraph. Pages live in a horizontal UICollectionView or a UIPageViewController; the choice is the merged spec's.

The page view adopts UITextInput with a `UITextInteraction(for: .nonEditable)` so selection, the edit menu, VoiceOver text navigation and Speak Screen work (section 7), and the page container adopts UIFindInteraction through a UITextSearching document that spans the book.

Rejected: one UITextView per page (its own layout would have to reproduce the chapter layout's line breaks across a page boundary that falls mid-paragraph or mid-hyphenated word, and it cannot be given a start location in the shared content storage); CALayer per fragment as in Apple's TextKit 2 sample (right for a scrolling editor, unnecessary for a static page); WKWebView.

A continuous-scroll mode is cheap to offer as well: one UITextView per chapter, created with `init(usingTextLayoutManager: true)`, non-editable, showing the chapter's attributed string. It gets VoiceOver text navigation, selection and find for free and is what Apple recommends whenever constraints allow. Funston already has a pages-or-continuous setting for PDFs, and the Readium reader switches to continuous for VoiceOver today. The merged spec should decide whether the first version ships both modes or only pages.

### 3.8 Accessibility: paragraph elements, linked, with the reading content protocol

Each page exposes one UIAccessibilityElement per paragraph (and per heading, image, list item, table), frames computed from the line table, traits for headings and links, attributed labels carrying `accessibilityTextHeadingLevel` and `accessibilitySpeechLanguage`, each element linked to its neighbours with `accessibilityNextTextNavigationElement` and `accessibilityPreviousTextNavigationElement` (iOS 18), the last element on the page carrying `causesPageTurn`, and the page view implementing `accessibilityScroll(_:)` with a "Page x of y" `pageScrolled` announcement. The page also implements UIAccessibilityReadingContent so VoiceOver's read-all and touch exploration work line by line. Custom rotors for headings, links and images. Section 7 has the detail and the verification list.

### 3.9 Speech: AVSpeechSynthesizer, one utterance per paragraph

Read-aloud enqueues paragraphs as utterances with the paragraph's language voice, `prefersAssistiveTechnologySettings` on, highlights the word being spoken from `willSpeakRangeOfSpeechString`, turns pages from the delegate's `didStart`, and keeps two paragraphs queued ahead across page and chapter boundaries. Before starting it asks PlaybackController to pause and deactivate, then configures the session as playback in spokenAudio mode.

## 4. Requirements

Each requirement has the statement, why, the Apple citation, edge cases, and how to test it. Identifiers are stable; do not renumber.

### ZIP container

APL-01 The container reader shall open the EPUB with `Data(contentsOf:options:.alwaysMapped)`, locate the end-of-central-directory record by scanning backwards from the end of the file for the signature 0x06054b50 over at most 65,557 bytes, validate the record by checking that its comment length matches the bytes remaining, and read the central directory from the offset and size in that record.
Why: ZIP is defined by its central directory; local headers can be incomplete (APL-04). Mapping avoids reading a large scanned EPUB into memory.
Citation: foundation/nsdata/readingoptions/alwaysmapped ("Hint to map the file in if possible. This takes precedence over mappedIfSafe"). The ZIP layout itself is not documented by Apple; it is PKWARE's APPNOTE, which the merged spec cites.
Edge cases: files shorter than 22 bytes; a comment containing the signature bytes (the comment-length check settles it); a central directory offset beyond the file (reject); more than 65,535 entries or sizes of 0xFFFFFFFF (APL-05); a file that is not a ZIP at all (mimetype check comes after, so the error is "not a ZIP", not "not an EPUB").
Test: open every fixture in section 9; open a truncated copy (drop the last 100 bytes) and expect the "no end record" error; open a 23-byte file; measured open cost on the Gutenberg file is under 1 ms.

APL-02 Deflated entries shall be decoded with the Compression framework (`compression_stream_init` with `COMPRESSION_STREAM_DECODE` and `COMPRESSION_ZLIB`, one `compression_stream_process` call with `COMPRESSION_STREAM_FINALIZE` over the whole entry) into a buffer of exactly the uncompressed size from the central directory, and the decode shall be accepted only when the status is `COMPRESSION_STATUS_END` and the destination is exactly full.
Why: ZIP entries are raw DEFLATE streams with no zlib header or Adler-32 trailer. Apple's documentation says COMPRESSION_ZLIB "encoded format is the raw DEFLATE format as described in rfc1951.txt" and that the decoder "supports decoding data compressed with any compression level". Measured: a zlib-wrapped stream is rejected, a raw stream decodes, a truncated stream is rejected, and a too-small output buffer is rejected.
Citation: compression/compression_zlib; compression/compression_stream_process(_:_:) ("When decoding, the function returns this status as soon as it reads the end-of-stream marker from the source"; "The decoder can't always detect corruption or truncation ... Setting COMPRESSION_STREAM_FINALIZE tells the decoder that no more input is coming").
Edge cases: stored entries (method 0) are a plain copy; any other method (1, 6, 9, 12, 14, 93 and so on) is "unsupported method" with the method number in the diagnostic; an entry whose uncompressed size is 0; entries over 2 GB (use UInt64 sizes, decode in a loop with a bounded output buffer rather than one allocation, and set a hard ceiling for anything the reader will hold in memory).
Test: the three synthetic streams above plus every entry of every fixture decoded and CRC-checked. zlib's `inflateInit2_` with windowBits -15 gives the same bytes and was 0.6 to 1.0 ms against Compression's 1.5 to 2.5 ms for the 625 KB corpus; either is acceptable, Compression is the Swift-friendly one.

APL-03 Every extracted entry shall be verified against the central directory's CRC-32 with zlib's `crc32` (`import zlib`), and a mismatch shall be a recorded error for that entry, not a silent success.
Why: a wrong CRC means a damaged or mis-inflated chapter; showing it would show garbage.
Citation: usr/include/zlib.modulemap in the SDK declares `module zlib`; `crc32` is a zlib function. Apple documents no CRC API of its own.
Edge cases: directory entries (names ending in "/") have CRC 0 and no data; an entry with a data descriptor has CRC 0 in the local header (APL-04).
Test: flip one byte in a compressed entry of a fixture copy and expect the CRC error on that entry only.

APL-04 Sizes, CRC and compression method shall always be taken from the central directory entry; the local file header shall be read only for its name length and extra length to find the data offset, and general-purpose flag bit 3 (data descriptor present) shall change nothing in how the entry is read.
Why: Finder's archives set bit 3 and write zero CRC and sizes in the local header (measured on the ditto fixture: "local crc 0, local sizes 0/0" on nine entries). Python's `force_zip64` entry had 0xFFFFFFFF sizes in the local header while the central directory had the real sizes.
Citation: observed in the fixtures; the PKWARE rule is in the merged spec.
Edge cases: a local header whose name differs from the central directory name (use the central directory); an extra field in the local header longer than in the central directory (skip by the local header's own length).
Test: the Finder and Python fixtures extract with matching CRCs.

APL-05 The reader shall support ZIP64: when the ZIP64 end-of-central-directory locator (0x07064b50) sits immediately before the end record, read the ZIP64 end record (0x06064b50) for entry count, directory size and offset; and in each central directory entry, when a size or offset field is 0xFFFFFFFF, read the real value from the 0x0001 extra field in the order uncompressed size, compressed size, local header offset, disk number, taking only the fields that were 0xFFFFFFFF.
Why: Info-ZIP's `-fz` produces this for any archive, and large scanned EPUBs can exceed 4 GB.
Citation: PKWARE APPNOTE via the merged spec; measured on the zip64 fixture ("zip64 end record: true", every entry "zip64extra=true", local sizes 0xFFFFFFFF, all CRCs good).
Edge cases: entry count 0xFFFF without a locator (reject with a diagnostic); an extra field shorter than the fields it should contain (reject).
Test: the zip64 fixture; a copy with the locator signature corrupted expects "zip64 end record missing".

APL-06 Entry names shall be decoded as UTF-8 when general-purpose flag bit 11 is set, otherwise as UTF-8 if valid and as CP437 (`CFStringEncodings.dosLatinUS`) if not; names shall be normalised to the manifest's href form (percent-decoding of hrefs happens on the manifest side, path separators are "/", "." and ".." components resolved, a leading "/" dropped); encrypted entries (flag bit 0) shall be reported as unsupported; directory entries and Finder's `__MACOSX/` resource-fork entries shall be ignored; and a `mimetype` entry that is missing, not first, not stored, or not exactly `application/epub+zip` shall produce a diagnostic but not stop the book from opening.
Why: the Info-ZIP, Finder and Python fixtures wrote the same UTF-8 name "sub/ünïcode name.txt" with and without bit 11 (Python set it, zip 3.0 and ditto did not), so the flag alone cannot be trusted. Finder's archive had the mimetype at position two with a data descriptor and a `__MACOSX` twin, and real EPUBs made by hand look like that.
Citation: fixtures; CP437 via CFStringEncodings.
Edge cases: duplicate names (last central directory entry wins, with a diagnostic); names with backslashes; a manifest href with "%20" against an entry name with a space.
Test: list the Finder fixture and expect five content entries, four directories and five `__MACOSX` entries skipped, mimetype diagnostic "not first entry".

APL-07 The ZIP reader shall have a fixture set with at least: an Info-ZIP archive, a Finder (ditto) archive with data descriptors, a forced ZIP64 archive, a Python zipfile archive with a stored first entry and a UTF-8 flagged name, the Gutenberg corpus EPUB, a truncated EPUB, an EPUB with one corrupted compressed byte, and an empty file.
Why: these are the writers Internet Archive books and user-supplied books come from.
Citation: section 9 lists how each was made.
Test: a test per fixture asserting entry count, method mix, flag bits and CRC results as recorded in section 9.

### XHTML and CSS

APL-08 Chapter, OPF, container and navigation documents shall be parsed with Foundation's XMLParser configured with `shouldProcessNamespaces = true`, `shouldReportNamespacePrefixes = false`, `shouldResolveExternalEntities = false` (the default) and `externalEntityResolvingPolicy = .never`, and the parser shall never be given a URL (always `init(data:)`).
Why: XMLParser is SAX, libxml2-backed, fast (2.4 to 3.8 ms for the 62 KB chapter, 573 elements, 2,259 delegate events) and correct on BOMs, declared encodings and namespaces (measured: UTF-8 BOM, UTF-16LE BOM, declared ISO-8859-1 and undeclared UTF-8 all delivered "café"). With namespaces on, `<section epub:type="chapter">` arrives with the element name "section", namespace URI of XHTML, and the attribute dictionary keyed "epub:type"; an inline SVG arrives with the SVG namespace URI. Resolving external entities would hit the network for the XHTML DTD every Gutenberg chapter points at.
Citation: foundation/xmlparser ("Unless used in a callback, the XMLParser is a thread-safe class as long as any given instance is only used in one thread"); foundation/xmlparser/shouldresolveexternalentities ("The default value is false. If you set this property to true, you may cause other I/O operations, either network-based or disk-based, to load the external DTD"); foundation/xmlparser/externalentityresolvingpolicy-swift.enum (never, noNetwork, sameOriginOnly, always).
Edge cases: whitespace-only text between block elements is delivered through `foundCharacters` (measured "\n  " between paragraphs), so the tree builder must apply the CSS white-space collapse rules itself; CDATA arrives through `foundCDATA` as Data; comments and processing instructions are ignored; attribute values arrive with entities already expanded ("a&amp;b&#8212;c" became "a&b—c").
Test: the 14 synthetic documents in section 9 with their recorded outcomes; the Gutenberg chapter parses with no error and 54,989 delivered characters.

APL-09 Before parsing, the chapter bytes shall pass through an entity pre-expansion that rewrites every `&name;` whose name is in the HTML named character reference table (the W3C table in the merged spec) to the numeric reference `&#NNNN;`, leaves `amp`, `lt`, `gt`, `quot` and `apos` alone, and rewrites an unknown name to U+FFFD while recording a diagnostic; the pre-expansion shall operate on the decoded string only after the encoding has been settled (APL-10).
Why: XMLParser's behaviour with undeclared entities depends on the DOCTYPE. Measured: without a DOCTYPE, `&nbsp;` is a fatal error (code 26, undeclaredEntityError) and parsing stops after the characters before it; with the XHTML 1.1 external DOCTYPE and default settings, parsing succeeds but the entity is silently dropped ("a&nbsp;b" delivers "a" then "b" with nothing between); the delegate's `resolveExternalEntityName` is called in both cases and returning replacement Data works only when a DOCTYPE with an external subset is present (it was ignored before the fatal error without one). An HTML5 `<!DOCTYPE html>` counts as no external subset and fails fatally. Gutenberg and many hand-made EPUBs use `&nbsp;`, `&mdash;` and friends. The regex pre-pass took 0.5 ms on the 62 KB chapter and produced the correct U+00A0 and U+2014 characters.
Citation: foundation/xmlparserdelegate/parser(_:resolveexternalentityname:systemid:) ("The delegate can resolve the external entity ... and provide the result to the parser object as an NSData object"); foundation/xmlparser/errorcode (undeclaredEntityError).
Edge cases: `&` followed by something that is not a reference (XMLParser fails with code 39, entityNotFinishedError; the HTML fallback in APL-11 handles it); references inside CDATA must not be rewritten; references inside attribute values must be rewritten the same way; `&#x...;` and `&#...;` pass through untouched; an internal DTD subset that declares its own entities (measured: declarations arrive through `foundInternalEntityDeclarationWithName` and expand correctly) must not be broken by the pre-pass, so the pre-pass skips names that the internal subset declares.
Test: the synthetic cases A, A2, B, B2, D, D2, E and T in section 9.

APL-10 Encoding shall be settled before any text pass: a BOM wins, then the XML declaration's encoding, then the `meta charset` or `http-equiv` in the first 1,024 bytes, then UTF-8; if the bytes do not decode under the chosen encoding, the chapter shall be decoded as Windows-1252 and a diagnostic recorded; and C0 control characters other than tab, line feed and carriage return shall be stripped before parsing.
Why: XMLParser aborts with invalidCharacterError (code 9) on an invalid UTF-8 byte and on U+0001 (measured, both cases), and everything after the error is lost.
Citation: foundation/xmlparser/errorcode (invalidCharacterError, unknownEncodingError, encodingNotSupportedError); the BOM and declaration behaviour was measured.
Edge cases: a UTF-16 document with a BOM (XMLParser handled it); a declaration that lies (bytes are Latin-1, declaration says UTF-8; the re-decode catches it); form feeds inside `<pre>`.
Test: cases F, G, H, H2, H3, N and N2 in section 9.

APL-11 When XMLParser reports a fatal error on a chapter, the reader shall re-parse the same bytes with libxml2's HTML parser (`htmlReadMemory` with `HTML_PARSE_RECOVER | HTML_PARSE_NONET | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING`), walk the resulting tree into the same element model, and record a "recovered as HTML" diagnostic with the XMLParser error code, line and column; the libxml2 document shall be freed with `xmlFreeDoc` on every path.
Why: XMLParser stops at the first error. Measured: an unclosed `<p>` fails with tagNameMismatchError (code 76) after delivering the earlier elements, `<p class=x>a & b</p>` fails immediately with code 39 and delivers nothing, a mismatched close tag fails with code 76. libxml2's HTML parser turned `<html><body><p>one<p>two</p><p>three<p class=x>a & b</body></html>` into four sibling paragraphs with the right text and knows `&nbsp;`, `&mdash;` and `&copy;` without a DOCTYPE. `import libxml2` resolves through the SDK's module map, the executable links `/usr/lib/libxml2.2.dylib` (libxml2 2.9.13 in the iOS 27 SDK), and the Xcode target needs `libxml2.tbd` in its linked libraries (`-lxml2`).
Citation: SDK usr/include/libxml2/module.modulemap; libxml2 is not documented on developer.apple.com beyond the XMLParser error code page's pointer to `<libxml/xmlerror.h>`.
Edge cases: the HTML parser adds `html`, `head` and `body` wrappers (pass `HTML_PARSE_NOIMPLIED` to suppress them, or accept them); it lowercases tag names; it does not know XML namespaces, so `epub:type` arrives as an attribute literally named "epub:type", which the model must accept from both paths; SVG inside recovered HTML loses its namespace.
Test: cases J, J2, J3 and R2 in section 9 produce the recorded trees through the fallback.

APL-12 The reader shall not use `NSAttributedString(data:options:documentAttributes:)` with the HTML document type, nor `loadFromHTML`, nor any WebKit view, for book content.
Why: documentation says "Don't call this method from a background thread if the options dictionary includes the documentType attribute with a value of html. If you do, the method tries to synchronize with the main thread, fails, and times out", and "The HTML import mechanism is meant for implementing something like markdown ... not for general HTML import". Measured on the 55 KB chapter: iOS 27 main thread 668 to 989 ms on the first call, 34 to 111 ms after; iOS 18.3 253 ms then 36 to 40 ms; a background-thread call never returned within 15 seconds on either runtime; the result ignored the book's CSS (every run was Times New Roman 12 pt with 18 pt bold headings). The document type page adds that Apple "discourages using this document type with the synchronous initWithHTML: initializers" in favour of the WebKit-based `loadFromHTML`, which brings WebKit back.
Citation: foundation/nsattributedstring/init(data:options:documentattributes:); foundation/nsattributedstring/documenttype/html.
Test: none needed beyond a lint rule that the symbol does not appear in the EPUB module.

APL-13 The renderer shall honour this CSS subset and ignore everything else with a counted diagnostic per property name: selectors of type, class, id, the descendant and child combinators, and the universal selector, with specificity and source order; properties `display` (none and block versus inline, plus `list-item`), `font-family` (matched against embedded fonts by family name, then system families, then the user's choice), `font-size` (px, pt, em, rem, %, and the keywords xx-small through xx-large and smaller and larger, all resolved against the user's base size), `font-weight` (normal, bold, 100 to 900), `font-style` (normal, italic, oblique), `font-variant` (small-caps, via the font descriptor's feature settings when the font has them, otherwise synthesised by uppercasing at 80% size), `text-align` (left, right, center, justify, start, end), `text-indent`, `margin` and `padding` (vertical values become paragraph spacing, horizontal values become head and tail indents, `auto` margins centre block images and tables), `line-height` (number, length or %), `text-decoration` (underline, line-through, none), `vertical-align` (sub and super become baseline offset and a smaller size), `white-space` (pre and pre-wrap keep line breaks and spaces), `color` and `background-color` (only when the user's theme is "publisher colours"), `width` and `height` on images and tables (px and %), `page-break-before` and `break-before` (always or page forces a page break before the element), `list-style-type` (the NSTextList marker formats), and the `hidden` attribute. Units resolve with 1 em equal to the computed font size and 1 rem equal to the user's base size; `vw`, `vh` and `calc()` are ignored.
Why: the Gutenberg CSS in the corpus uses exactly these (margins in em and percent, text-align, font-size in percent and keywords, font-style, font-variant small-caps, text-indent, display none for page references, borders and width on tables and images, page-break-before on h2) and nothing a native renderer can honour beyond them. There is no system CSS parser, so every property costs code and tests.
Citation: the Gutenberg style sheets pgepub.css, 0.css and 1.css in the corpus (section 9); NSParagraphStyle properties (uikit/nsparagraphstyle); NSAttributedString keys.
Edge cases: `!important` (honour it only for `display: none`, since a user setting must still override fonts and colours); `@import` and `@media` (import only when the file is in the manifest, media only `all` and `screen`); `@font-face` (section on fonts); a `font-size` of 0 or negative (clamp to the user's minimum); percentages that compound through nested elements (clamp the computed size to 0.5 to 3 times the base); `text-align: justify` when the user has chosen start alignment (user wins).
Test: a style sheet fixture per property with the expected attribute values on the resulting attributed string; the corpus CSS produces the expected paragraph styles for `.blockquot`, `.center`, `.smcap`, `p.c2` (200%) and `.pagenum` (display none).

### Text model

APL-14 Each spine item shall become exactly one NSAttributedString in which every paragraph ends in a single U+2029 or "\n" separator, block images are their own paragraph containing one NSTextAttachment character (U+FFFC), inline images are attachments inside the paragraph, headings carry the custom key for heading level 1 to 6, anchors with ids carry a custom key with the id at their first character, runs with an `xml:lang` or `lang` different from the chapter language carry `languageIdentifier`, links carry `.link` with the resolved URL, and every character has a `font` and a `paragraphStyle`.
Why: TextKit 2 builds one NSTextParagraph per paragraph separator and lays out attachments from their bounds; VoiceOver, speech and find all index this string, so it must be complete and stable for the life of the chapter's layout.
Citation: uikit/nstextcontentstorage (elements are generated per paragraph); uikit/nstextattachment; foundation/nsattributedstring/key/languageidentifier ("an NSString with the language identifier code in ISO 639 format", iOS 15).
Edge cases: empty paragraphs (keep one separator so anchors still resolve); a chapter whose body has no block elements at all (one paragraph); nested lists (NSParagraphStyle.textLists is an array from outermost to innermost, documentation says); a paragraph of only an inline image; a heading inside a link.
Test: a golden test per corpus chapter comparing the string's text with the HTML parser's text content, and an attribute-run dump for a fixture with every construct.

APL-15 Every paragraph style shall carry an explicit `baseWritingDirection` of `.leftToRight` or `.rightToLeft`, never `.natural`, resolved from the nearest `dir` attribute, then the nearest `lang` or `xml:lang` against a fixed list of right-to-left languages (ar, he, fa, ur, yi, ps, sd, ug, dv, syr, and their region variants), then the first strong directional character of the paragraph (Hebrew U+0590 to U+05FF, Arabic U+0600 to U+06FF, U+0750 to U+077F, U+08A0 to U+08FF, U+FB1D to U+FDFF, U+FE70 to U+FEFF, Syriac, Thaana, NKo), defaulting to left-to-right; alignment `.natural` is then safe, but `start` and `end` from CSS shall still be mapped by the renderer to left or right from the resolved direction.
Why: measured on iOS 18.3, an all-Arabic paragraph with `.natural` direction and alignment was laid out flush left (line x ranges 0 to 294); on iOS 27 the same text was flush right (5 to 300), because iOS 26 added `resolvesNaturalAlignmentWithBaseWritingDirection`, documented as "When set to true, the resolved visual alignment is determined by the resolved base writing direction; otherwise, it is using the user's preferred language. The default value is true". With `baseWritingDirection = .rightToLeft` set explicitly, iOS 18.3 laid the paragraph out flush right (9 to 304). The documented helper `NSParagraphStyle.defaultWritingDirection(forLanguage:)` returned leftToRight (raw value 1) for "ar" and "he" on macOS, iOS 18.3 and iOS 27, so it must not be used. Bidi inside a line works without help: in the mixed English, Arabic and Hebrew line, `locationForCharacter(at:)` returned x positions 0, 59, 202, 163, 216 for character indices 0, 8, 14, 20, 30 (visual reordering), and a 20-character selection crossing the direction change produced two selection rectangles.
Citation: uikit/nstextlayoutmanager/resolvesnaturalalignmentwithbasewritingdirection (iOS 26); uikit/nsparagraphstyle/basewritingdirection ("If the value of this property is natural, the receiver resolves the writing direction to either leftToRight or rightToLeft, depending on the direction for the user's language preference setting"); uikit/nsparagraphstyle/defaultwritingdirection(forlanguage:).
Edge cases: a paragraph that starts with a number or punctuation (skip weak characters when scanning for the first strong one); `dir="auto"`; a page progression direction of rtl in the spine, which affects page order not text direction.
Test: the bidi fixture in section 9 on an iOS 18 runtime must produce right-aligned lines for the Arabic paragraph; a unit test on the direction resolver with the three sources.

APL-16 Hyphenation shall be a user setting, off by default to match Funston's current start-aligned ragged text, implemented by setting `usesHyphenation` on the chapter's NSTextLayoutManager (iOS 15); paragraph-level `hyphenationFactor` shall not be relied on for the language because the documentation says the hyphenation language comes from the user's first preferred language, not from the text.
Why: measured, `usesHyphenation = true` reduced a German paragraph at 180 pt from 16 to 14 lines with correct breaks ("Donaudampfschiff-fahrtsgesellschaftska-pitänsmütze") and hyphenated English ("ex-traordinarily"); `hyphenationFactor = 1` on the paragraph style alone produced the same 14 lines, so both switches work in TextKit 2; adding `languageIdentifier` "de" or "en" changed nothing in the counts.
Citation: uikit/nstextlayoutmanager (usesHyphenation); uikit/nsparagraphstyle/hyphenationfactor ("This property detects the user-selected language by examining the first item in preferredLanguages"); uikit/nsparagraphstyle/usesdefaulthyphenation (iOS 15).
Edge cases: justified text without hyphenation opens the gaps Camden finds hard to track, so if the user turns on justification the setting screen should offer hyphenation next to it; `CFStringGetHyphenationLocationBeforeIndex` with `CFStringIsHyphenationAvailableForLocale` exists for a renderer that wants language-correct breaks on its own (Core Text path), with locale from the paragraph language.
Test: the German and English fixtures in section 9, asserting line counts on and off and that no line ends inside a word when off.

APL-17 HTML lists shall become NSTextList values on the paragraph style (`textLists`, outermost first) with marker formats decimal, lowercaseAlpha, uppercaseAlpha, lowercaseRoman, uppercaseRoman, disc, circle and square mapped from `list-style-type` and the element type, and `startingItemNumber` from the `start` attribute; and every offset computation on a line fragment of a list paragraph shall account for the synthesised marker prefix.
Why: TextKit 2 generates an NSTextListElement per list paragraph whose `attributedString` is the marker plus the content, measured as "\t1\tFirst item\n" (14 characters) for the 10-character content "First item" (so 3 characters of prefix and the separator), rendered as "1" with a tab, and continuation lines indented by 36 pt. `NSTextLineFragment.characterRange` is relative to that element string, not to the document, so document offset = element start offset + characterRange.location - prefix length, where prefix length is `attributedString.length - contents.length - separator length` or the location of `contents.string` inside `attributedString.string`. NSTextListElement exists from iOS 16; on iOS 15 the markers would not be synthesised, which is below the deployment target and so does not matter.
Citation: uikit/nstextlist; uikit/nstextlistelement (`attributedString` "taking into account markers and the indentation level", `contents` "without markers and formatting"); uikit/nstextcontentstorage/includestextlistmarkers (iOS 26: "When true, NSTextContentStorage assumes that a paragraph with an NSTextList includes the text list marker string"; the default is false, so TextKit synthesises markers; measured the same output with it true or false, and the element's attributedString carried the prefix in both cases).
Edge cases: a list item containing several paragraphs (only the first gets the marker; later ones get the indent via headIndent); definition lists (render as paragraphs with indents, no NSTextList); a `value` attribute on `li`; nested list markers (`prependEnclosingMarker` option).
Test: the list fixture in section 9; a unit test on the offset mapping for a wrapped item asserting that the second line's document range starts inside the item text.

APL-18 Embedded fonts shall be loaded from the ZIP entry bytes with `CTFontManagerCreateFontDescriptorsFromData`, kept in a per-book table keyed by the `@font-face` family name and the weight and style the rule declares, and used by creating CTFont objects (bridged to UIFont) from those descriptors with an explicit `kCTFontCascadeListAttribute` whose first fallback is the user's body font; no font shall be registered with the font manager; Dynamic Type shall be applied by passing the book font at the user's base size through `UIFontMetrics(forTextStyle: .body).scaledFont(for:compatibleWith:)`, never a font that was already scaled.
Why: measured on both iOS runtimes with Herculanum.ttf (a family the simulator does not have: `UIFont.familyNames` false, `UIFont(name:)` nil): the descriptor from data drew the text with the real font without any registration ("fonts actually used by Core Text runs: Herculanum"), in 0.03 to 0.19 ms. Documentation confirms: "The font descriptors are not available through font descriptor matching. As a result, you can't directly look for the fonts by name". The deprecated `CTFontManagerRegisterGraphicsFont` (deprecated iOS 18) did make the name findable, but the supported registration routes need a file URL (`CTFontManagerRegisterFontURLs`) or descriptors with a URL attribute, and registration is process-wide state with name collisions between books. The cascade list works: with `kCTFontCascadeListAttribute` set to HiraginoSans-W3, Japanese runs used Hiragino instead of the global PingFang fallback, and Arabic still fell through to GeezaPro from the global list. Dynamic Type: Georgia 17 scaled to 15, 17, 22, 26 and 48 pt for extra small, large, XXXL, accessibility medium and accessibility XXXL (the system body style gave 14, 17, 23, 28, 53), and `scaledFont(for:maximumPointSize:)` capped it; documentation warns "Do not specify a font that has already been scaled; doing so results in an exception".
Citation: coretext/ctfontmanagercreatefontdescriptorsfromdata(_:) (iOS 11, "the preferred function when the data contains a font collection"; "returns an empty array in the event of invalid or unsupported font data"); coretext/ctfontmanagerregistergraphicsfont(_:_:) (deprecated iOS 18); coretext/ctfontmanagerregisterfonturls(_:_:_:_:) and coretext/ctfontmanagerscope; coretext/kctfontcascadelistattribute; uikit/uifontmetrics/scaledfont(for:); WWDC19 227 (registered fonts "do not participate in font fallback").
Edge cases: obfuscated fonts (the IDPF and Adobe obfuscation algorithms XOR the first 1,040 or 1,024 bytes with a key from the unique identifier; de-obfuscate before creating descriptors; the merged spec owns the algorithm); a collection file returning several descriptors; invalid data (empty array; fall back to the user font with a diagnostic); a family name used by the book that matches a system family (prefer the embedded font when the book declares it); bold and italic requests for a family that only embedded the regular face (synthesise through `UIFontDescriptor.SymbolicTraits`, or fall back to the system family).
Test: load the Herculanum fixture from a ZIP entry and assert the run font name; assert `UIFont(name:)` stays nil; Dynamic Type table above.

APL-19 Images shall be decoded with ImageIO from the entry bytes through `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailFromImageAlways`, `kCGImageSourceShouldCacheImmediately`, `kCGImageSourceCreateThumbnailWithTransform` and `kCGImageSourceThumbnailMaxPixelSize` equal to the larger of the page width and height in points times the screen scale, on a background queue, and placed as NSTextAttachment values whose `bounds` are the CSS or intrinsic size scaled to fit the page width; the intrinsic size shall be read from `CGImageSourceCopyPropertiesAtIndex` without decoding; SVG images shall not be decoded (UIImage and ImageIO cannot read SVG data) and shall render as a placeholder carrying the `alt` text with a diagnostic.
Why: measured on a 4000 by 3000 JPEG (229 KB): reading the pixel size cost 0.6 to 1.4 ms with no decode; a full decode on first draw cost 19 to 24 ms and a 45 MB bitmap; a 720 px thumbnail cost 13 to 15 ms and 1.5 MB. `UIImage(data:)` with SVG returned nil on iOS 18.3 and iOS 27, `CGImageSourceCreateWithData` returned status -4 (unknown type) and `CGImageSourceCopyTypeIdentifiers` lists no SVG type; CoreSVG is private. Attachments draw inside `NSTextLayoutFragment.draw` without any view: the inline attachment raised its line to 25 pt and the block attachment produced a 190 pt fragment, both drawn in the rendered PNG.
Citation: imageio/cgimagesourcecreatethumbnailatindex(_:_:_:); imageio/kcgimagesourcethumbnailmaxpixelsize ("If this key is not specified, the width and height of a thumbnail is not limited"); imageio/kcgimagesourceshouldcacheimmediately ("The default value is kCFBooleanFalse, which causes decoding and caching to happen only when you render the image"); uikit/uiimage/init(data:) ("must be formatted to match the file format of one of the system's supported image types"); uikit/nstextattachment.
Edge cases: an image taller than the page (scale to fit the page height, never split); a cover image spine item (full-page attachment); animated GIF (first frame); an image whose `src` is not in the manifest or not in the ZIP (placeholder with alt text and a diagnostic); EXIF rotation (the transform option handles it); an image referenced from CSS `background-image` (ignored).
Test: the attachment fixture in section 9 (inline and block); the SVG probe asserting nil; a decode-size test asserting the thumbnail never exceeds the page in pixels.

APL-20 Ruby annotations and vertical writing shall be out of scope for the first version: `<rt>` text shall be rendered inline in parentheses after its base and `writing-mode: vertical-rl` shall be ignored, each with a diagnostic; a later version that needs them shall draw those paragraphs with Core Text (`kCTRubyAnnotationAttributeName`, `kCTVerticalFormsAttributeName` with `kCTFrameProgressionAttributeName` set to rightToLeft) inside a custom NSTextLayoutFragment, because TextKit 2 on iOS has neither.
Why: measured, TextKit 2 laid out a run carrying a CTRubyAnnotation at the same 20 pt height as without it and drew nothing above the base; Core Text's CTFrameDraw drew the furigana. Core Text with the rightToLeft progression produced three vertical lines with x origins 191, 164 and 137 from a 200 pt frame; TextKit 2 given the vertical forms attribute produced four horizontal lines. UIKit has no vertical layout orientation API for text containers (`NSTextLayoutOrientationProvider` is read-only and driven by the text view on macOS).
Citation: coretext/kctrubyannotationattributename (iOS 8); coretext/kctframeprogressionattributename ("This value determines the line-stacking behavior for a frame"); coretext/ctframeprogression ("Frames with a progression type that specifies vertical text rotate lines 90 degrees counterclockwise during drawing"); coretext/kctverticalformsattributename.
Test: the ruby and vertical fixtures in section 9 (the rendered PNGs are the evidence); a diagnostic count test on a fixture with both.

APL-21 Tables shall be rendered by the reader as a block attachment whose view provider lays out each cell with its own small NSTextLayoutManager in a grid the reader computes (column widths from content with the `automatic` rule, or from the first row with `fixed`), paginated as a block that moves whole to the next page when it does not fit and is split by rows when taller than a page; NSTextTable and NSTextTableBlock shall not be used for layout.
Why: measured on macOS 27.0.1, iOS 18.3 and iOS 27.0, a standalone NSTextLayoutManager ignored `textBlocks` entirely: the four cell paragraphs of a 2 by 2 table were laid out one under the other at x = 0, exactly like plain paragraphs. The TextKit 1 NSLayoutManager laid the same string out as a table on all three (cells at x = 5 and x = 155 on the same y). Apple's article says to assign the string to a UITextView to render tables, which (per WWDC22) is the TextKit 1 compatibility path, and UITextView is not the page renderer. The classes are marked available since iOS 6 in the iOS 27 SDK header, with per-edge width and colour methods new in iOS 27, so a renderer that wanted TextKit 1 for tables could use them, but one TextKit 1 layout inside a TextKit 2 page is exactly the mixed-engine arrangement WWDC22 warns about.
Citation: uikit/adding-tables-to-attributed-strings ("Assign the attributed string to a UITextView to render the table"); uikit/nstexttable; UIKit/NSTextTable.h availability marks; WWDC22 10090 (tables are among the attributes that switch a text view to TextKit 1).
Edge cases: `colspan` and `rowspan`; a table wider than the page (scale the grid or allow horizontal scrolling inside the attachment view); nested tables (flatten); tables used for layout by Gutenberg (the corpus has 16, all small, used for poetry alignment and title blocks); VoiceOver exposure as a data table (APL-34).
Test: the table fixture in section 9 asserting the grid geometry from the reader's own layout, and a pagination test with a table that spans a page boundary.

### Pagination and rendering

APL-22 The reader shall lay out each chapter with one NSTextContentStorage (its `textStorage` holding the chapter string), one NSTextLayoutManager added to it, and one NSTextContainer whose size is the page content width by 0 (meaning unlimited) with `lineFragmentPadding` 0; it shall call `ensureLayout(for: documentRange)` once, then enumerate every layout fragment with `enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout])` and each fragment's `textLineFragments` into an array of line records (document range, frame in container coordinates, fragment index, line index, and a reference to the NSTextLineFragment); and it shall cut pages where a line's bottom would exceed the page top plus the page height, so that a page is a contiguous range of line records and a vertical offset.
Why: measured for the 200 KB chapter (200,012 UTF-16 units, 4,998 lines, 190 pages at 360 by 640 pt with the 17 pt body font): ensureLayout 70 to 83 ms on iOS 18.3, 124 to 252 ms on iOS 27 (the 252 ms was the first run in a fresh process), 143 to 160 ms on macOS; collecting the lines 2 to 4 ms; cutting pages under 0.1 ms. A 60 KB chapter took 24 ms (iOS 18) to 47 ms (iOS 27). A container height of 0 laid out all 430 lines of a test paragraph exactly as a 10,000,000 pt container did. A bounded container stops layout at its bottom (13 of 1,225 fragments got `layoutAvailable` with a 640 pt container, in 1 ms), which is useful for measuring "does this fit" but not for pagination. The alternatives: one fresh layout manager and content storage per page from the page's first character took 186 ms (iOS 18) to 330 ms (iOS 27) for the same 190 pages, and TextKit 1 with successive containers took 935 ms (iOS 18) to 1,250 ms (iOS 27).
Citation: uikit/nstextcontainer/size ("A value of 0.0 or less means no limitation ... the system uses a default large size of (10000000.0, 10000000.0)"); uikit/nstextlayoutmanager (ensureLayout(for:), enumerateTextLayoutFragments); uikit/nstextlayoutfragment/enumerationoptions (ensuresLayout); uikit/nstextlinefragment/typographicbounds ("The origin value is offset from the beginning of the line fragment group belonging to the parent layout fragment"); WWDC21 10061 (forcing layout outside the viewport is expensive for large documents, which is why the chapter, not the book, is the unit).
Edge cases: a single line taller than a page (an image; give it its own page and scale it in APL-19); a paragraph with `page-break-before` (force a cut before its first line); widows and orphans (optional rule: never leave fewer than two lines of a paragraph on either side of a cut, moving the cut up by at most two lines); the last page of a chapter (shorter); a chapter with no text (one empty page); the extra line fragment TextKit synthesises after a trailing separator (skip zero-length lines at the end).
Test: the pagination test in section 9 reproduces the line and page counts above within the tolerance of font metrics (iOS counted 190 pages, macOS 174, because SF's line height is 20.29 pt on iOS and 20 pt on macOS); a property test that every character of the chapter belongs to exactly one page.

APL-23 A page view shall draw each of its line records with `NSTextLineFragment.draw(at:in:)` at the point (fragment frame minX + line typographicBounds minX, fragment frame minY + line typographicBounds minY - page top) in a context whose origin is top-left (UIKit's `draw(_:)` context already is); it shall not add `glyphOrigin` to that point; a fragment that lies wholly inside the page may instead be drawn with `NSTextLayoutFragment.draw(at:in:)` at its frame origin minus the page top.
Why: measured and verified by rendered PNGs: drawing every line at its fragment origin alone stacked the lines of multi-line paragraphs on top of each other; adding the typographic bounds origin produced the correct page; adding `glyphOrigin` on top shifted every line down by the baseline offset (16 pt) and clipped the last line. The documentation for `draw(at:in:)` describes the origin as the typographic bounds origin plus the glyph origin, which did not match; the measured convention is the one to use. Drawing cost at 2x: 0.5 to 3 ms per page after the first page, 3 to 13 ms for the first page of a process while glyph caches warm; whole-fragment drawing 0.6 to 0.8 ms.
Citation: uikit/nstextlinefragment/draw(at:in:); uikit/nstextlayoutfragment/draw(at:in:); uikit/nstextlayoutfragment/renderingsurfacebounds ("The coordinate system is vertically flipped from the layoutFragmentFrame origin ({0,0} is at the upper-left corner) ... The origin could be in the negative coordinate since the rendering could stretch out of layoutFragmentFrame").
Edge cases: glyphs that overhang the fragment frame (italics, Zapfino, as WWDC21 warns) at a page edge get clipped by the page bounds, which is acceptable; selection and highlight backgrounds must be drawn before the text; link underlines come from the rendering attributes (`NSTextLayoutManager.linkRenderingAttributes`).
Test: render page 1 and a middle page of the corpus chapter to PNG and compare with a golden image on the same runtime; a test that the union of a page's line frames equals the page's drawn extent.

APL-24 Chapter layout shall run on a serial background queue owned by the chapter's layout session, with the content storage, layout manager, container and line table confined to that queue until the table is complete and then handed to the main actor by value (the line records plus the fragment and line objects, which are immutable), and the main actor shall never touch the layout manager while a background pass is in progress.
Why: measured, the whole pipeline ran on a global queue (`isMainThread == false`) on both runtimes with the same results as on the main thread: 65 to 139 ms. Documentation for NSTextContainer says "You can access instances of the NSTextContainer, NSLayoutManager, and NSTextStorage classes from threads other than the main thread as long as the app guarantees access from only one thread at a time", and TextKit 2's `layoutQueue` property ("If non-nil, it performs layout in the specified queue") shows background layout is a supported design. There is no documentation saying NSTextLayoutManager is main-thread only.
Citation: uikit/nstextcontainer (threading note); uikit/nstextlayoutmanager/layoutqueue; uikit/nstextlayoutfragment/layoutqueue.
Edge cases: a relayout request (font change) arriving while a pass is running (cancel by generation number and drop the stale result); UIFont creation off the main thread (worked in the experiment; `UIFont.preferredFont` on a background thread is also what the measurement used); memory: each resident chapter layout costs about 13 MB (APL-46).
Test: the pagination experiment's background case; a stress test that paginates ten chapters on the queue while the main actor draws pages of the current chapter, with Thread Sanitizer on.

APL-25 Rectangles for a character range (selection, highlights, VoiceOver frames, find results) shall be obtained from `enumerateTextSegments(in:type:options:using:)` on the chapter layout manager with the `.standard`, `.selection` or `.highlight` segment type as appropriate, converting document offsets to locations with `location(_:offsetBy:)` from `documentRange.location` and back with `offset(from:to:)`; a line record lookup by y shall use binary search on the line table, and the fragment for a location shall come from `textLayoutFragment(for:)` when a line record is not at hand.
Why: measured per call: a 40-character segment enumeration 0.08 to 0.12 ms (200 calls in 16 to 24 ms, two rectangles each when a range wraps), `textLayoutFragment(for:)` about 2 microseconds, `location(_:offsetBy:)` from the document start under 1 microsecond. These are cheap enough to call per VoiceOver query but not cheap enough to call for every line of a page on every scroll, hence the line table.
Citation: uikit/nstextlayoutmanager/enumeratetextsegments(in:type:options:using:) ("A text segment is a logically and visually contiguous portion of the text content inside a line fragment ... The framework enumerates the segments visually from left to right"); uikit/nstextcontentstorage (location(_:offsetBy:), offset(from:to:)).
Edge cases: a range that spans a page boundary (clip to the page's line records); ranges inside list elements (APL-17 offset rule); zero-length ranges (caret rect, `.standard` with the range's location).
Test: the segment lookups in the pagination experiment; a test asserting that the selection rectangles for a range spanning a bidi boundary are two rectangles.

APL-26 The reader shall meet these budgets on an iPhone-class device, measured with signposts: chapter parse and style under 50 ms for a 60 KB chapter, chapter layout under 300 ms for a 200 KB chapter, page draw under 8 ms, VoiceOver line or frame query under 1 ms, chapter open to first page under 500 ms when the chapter is already parsed and under 1 s cold; and it shall emit `OSSignposter` intervals named zip.open, chapter.parse, chapter.style, chapter.layout, page.draw, find.search, a11y.query and speech.enqueue with the chapter href and byte size as metadata.
Why: the simulator numbers (parse 2.4 to 3.8 ms, layout 70 to 252 ms, draw under 3 ms) give headroom of three to ten times for a device; budgets make regressions visible.
Citation: os/ossignposter; os/recording-performance-data ("Use OSSignposter to create signposted intervals ... and then use Instruments' os_signposts instrument to record those intervals").
Edge cases: the first page of the first chapter after launch pays font and glyph cache warm-up (measured 3 to 13 ms for the first draw); counting the book's total pages requires laying out every chapter (190 chapters of 60 KB at 40 ms is 8 s), so it must run in the background and the UI must show "page x of y in this chapter" until the book total is known.
Test: XCTest performance tests (`measure`) on the corpus chapter for parse, layout and draw with baselines committed; a signpost presence test.

APL-27 Page breaks shall be cached per chapter under a layout key made of: page content size in points (rounded to 0.5), base font point size, font family name, the user's content size category, line height multiple, paragraph spacing, margins, alignment, hyphenation on or off, publisher styles on or off, theme (only if it changes fonts), the iOS major and minor version, and a hash of the embedded font set; the cached value is the array of UTF-16 offsets where each page starts plus the chapter's line count; a cache hit skips nothing in layout (layout is still needed to draw) but lets the reader show "page x of y" and jump to a position before layout finishes, and a miss simply recomputes.
Why: layout is cheap (APL-22) but book-wide page totals are not; offsets are small (190 integers per chapter); the key must include the OS version because the same text produced 190 pages on iOS and 174 on macOS from font metric differences, and a point release can change line breaking.
Citation: measured page counts; WWDC23 10058 (line height and line breaking changed by OS version and preferred language).
Edge cases: Dynamic Type changes mid-read (new key, recompute in background, keep the current reading offset and re-resolve its page); rotation and split view (new width, same rule); the cache can live in the existing `cache_entries` table with kind "epub-pages" and a lifetime of a year, or in memory only; a stale cache must never be trusted after a parse change (include the parser version in the key).
Test: a test that two layouts of the same chapter under the same key give identical offsets, and that changing the font size changes the key.

### Accessibility

APL-28 Each page shall expose, through `accessibilityElements` on the page view, one UIAccessibilityElement per block (paragraph, heading, list item, block image, table, code block) in reading order, each with: `accessibilityLabel` equal to the block's text as spoken (images use the `alt` text, or "image" with the file name when there is none), `accessibilityAttributedLabel` carrying `accessibilityTextHeadingLevel` 1 to 6 on headings and `accessibilitySpeechLanguage` on runs with a `languageIdentifier`, traits `.staticText` for text, `.header` for headings, `.link` for blocks that are entirely a link, `.image` for images, `accessibilityTextualContext = .narrative`, `accessibilityFrameInContainerSpace` computed from the block's line records on every read (never cached as screen coordinates), `accessibilityPreviousTextNavigationElement` and `accessibilityNextTextNavigationElement` pointing at the neighbouring blocks on the same page (iOS 18), and `accessibilityCustomActions` for links inside a paragraph ("Open link: text"); the last element on the page shall add the `causesPageTurn` trait.
Why: WWDC26 219 shows exactly this failure and fix: one text element per paragraph makes the VoiceOver Lines rotor stop at paragraph boundaries unless the elements are linked with the iOS 18 text navigation element properties, and the trait on the last paragraph is what lets read-all turn the page. Funston's PDF reader already computes frames on every read so zoom, scroll and rotation never need a re-layout. Heading levels in attributed labels feed the Headings rotor. Per-block elements, not per-line ones, keep a paragraph one swipe wide; per-line elements remain right for OCR, where a line is the unit.
Citation: objectivec/nsobject-swift.class/accessibilitynexttextnavigationelement ("Assistive technologies transition to these elements when navigating through text granularities, such as when using the VoiceOver Lines rotor", iOS 18); uikit/uiaccessibilitytraits/causespageturn; foundation/nsattributedstring/key/accessibilitytextheadinglevel ("a number in the range of 0 to 6"); foundation/nsattributedstring/key/accessibilityspeechlanguage (BCP 47); uikit/uiaccessibilitytextualcontext (narrative); uikit/uiaccessibilityelement/accessibilityframeincontainerspace; objectivec/nsobject-swift.class/accessibilityelements; WWDC26 219; Funston/UI/PDFLineAccessibility.swift (PDFRecognizedLineElement).
Edge cases: a paragraph split across two pages (two elements, one per page, each carrying its page's lines; the first one on the next page is not a heading); a block image with a caption (image element then caption element); an empty paragraph (no element); a link that is a whole paragraph (link trait on the element and the activate action opens it); footnote references (APL-35); the page's own chrome element (Funston's ReaderPageElement, which the PDF reader puts first in the elements array).
Test: the VoiceOver checklist (APL-37) on a device; an XCTest that walks `accessibilityElements` of a rendered corpus page and asserts count, order, traits, heading levels and that frames are inside the page and do not overlap.

APL-29 The page view shall implement UIAccessibilityReadingContent: `accessibilityLineNumber(for:)` returns the index in the page's line table of the line containing the screen point (converted into the page view, hit by y then x), or NSNotFound in empty space; `accessibilityAttributedContent(forLineNumber:)` returns that line's text with the speech language attributes and `accessibilityContent(forLineNumber:)` the plain text; `accessibilityFrame(forLineNumber:)` returns the line record's frame converted with `UIAccessibility.convertToScreenCoordinates(_:in:)`; `accessibilityAttributedPageContent()` returns the page's text with paragraph separators between blocks; and the page view shall implement `accessibilityScroll(_:)` turning to the next page for `.next`, `.left` and `.down` and to the previous for `.previous`, `.right` and `.up`, returning false at the book's ends and posting `pageScrolled` with "Page x of y" (chapter-relative until the book total is known) on success, matching the PDF reader.
Why: documentation: "To give VoiceOver users a superior, continuous reading experience, you can implement this protocol on an element that represents readable content, characterize it with the causesPageTurn trait, and use the next and previous constants to enable page turning", and for the trait "When VoiceOver finishes reading the content in the current page, it calls accessibilityScroll(_:) with next to scroll to the next content page. If VoiceOver detects that the new content doesn't differ from the previous content, it stops scrolling". The pageScrolled string is spoken, and "When an assistive app repeatedly receives the same scroll position string, it indicates to users that scrolling can't continue". WWDC19 248 demonstrates the four methods and the trait with read-all. WWDC26 219 says Speak Screen's read-all uses the same trait and scroll method.
Citation: uikit/uiaccessibilityreadingcontent and its methods (attributed variants tried first; frames "in screen coordinates"; line number "called only when point is within the bounds of the view or element"); objectivec/nsobject-swift.class/accessibilityscroll(_:) ("If the scrolling action fails, accessibilityScroll: is called on a parent view in the hierarchy"); uikit/uiaccessibility/notification/pagescrolled; UIKit/UIAccessibility.h ("Use in conjunction with UIAccessibilityTraitCausesPageTurn to provide a continuous reading experience with VoiceOver").
Edge cases: which object VoiceOver asks for lines when the page has child elements (the protocol is documented "on an element that represents readable content", so implement it on the page view and also forward from the block elements to the page's line table, then verify, APL-37); the left and right mapping above is the PDF reader's, which has been used under VoiceOver, while the WWDC19 sample's transcript reads the other way (left to the previous page), so confirm the three-finger swipe direction on a device; page turn direction when the spine's page progression is right-to-left (swap left and right); the first page of the next chapter (turn into it, with layout ready because the next chapter is pre-laid-out, APL-46).
Test: XCTest on `accessibilityLineNumber(for:)` for points inside each line and in the gutter; on the device, the read-all checklist.

APL-30 The page view (or the element VoiceOver focuses for text) shall adopt UITextInput in full with custom UITextPosition and UITextRange subclasses wrapping UTF-16 offsets, a UITextInputStringTokenizer subclass that implements line granularity from the line table, `selectionRects(for:)` and `firstRect(for:)` from `enumerateTextSegments` (.selection), `caretRect(for:)` from a zero-length segment, `closestPosition(to:)` and `characterRange(at:)` from the line record hit and `characterIndex(for:)` on the line fragment, `text(in:)` from the chapter string, `isEditable = false`, and `inputDelegate.selectionWillChange` and `selectionDidChange` calls around every selection change; it shall add a `UITextInteraction(for: .nonEditable)` with `textInput` set to itself.
Why: Apple's WWDC26 guidance for custom-rendered text: "Adopt the full UITextInput protocol on accessibility elements" to get "line-by-line touch exploration with VoiceOver, granular navigation with the VoiceOver rotor (characters, words, lines) and Speak Screen, text selection", and "The UITextInput protocol also works with causesPageTurn and the navigation element APIs". UITextInteraction gives the system selection handles, loupe and edit menu to a custom view. Custom rotors with text ranges also require a UITextInput target (WWDC20 10116: "targetElement must conform to UITextInput").
Citation: uikit/uitextinput; uikit/uitextposition and uikit/uitextrange ("If you adopt the UITextInput protocol, you must create a custom UITextRange subclass as well as a custom UITextPosition subclass"); uikit/uitextinputstringtokenizer ("the subclass needs a custom implementation of all methods for line granularity"); uikit/uitextinteraction (iOS 13); uikit/uitextselectionrect ("you should override and reimplement all properties ... do not call super"); WWDC26 219.
Edge cases: the geometry methods are called with positions on other pages (clamp to the page's range and return empty rectangles); `UITextSelectionDisplayInteraction` (iOS 17) can replace the interaction's drawing without its gestures if the page's own gestures conflict; copying a selection that spans pages (selection lives in the chapter's offsets; the edit menu's copy reads the chapter string).
Test: the VoiceOver checklist (Characters, Words, Lines rotors across a paragraph and across a page edge); an XCTest driving `tokenizer.position(from:toBoundary:inDirection:)` for `.line` across the line table.

APL-31 The page view shall provide `accessibilityCustomRotors` for headings (`init(systemType: .heading, ...)` and, when the book has more than one level, the per-level system types), links (`.link`) and images (`.image`), whose search closures walk the chapter's block list in reading order from the current element and, when the next match lies on another page, turn to that page and return the element there; and it shall provide a "Chapters" custom rotor from the navigation document.
Why: the rotor is how a VoiceOver user skims; WWDC20 10116: find the visually prominent categories, group items, sort them sensibly, return nil at the boundary.
Citation: uikit/uiaccessibilitycustomrotor; uikit/uiaccessibilitycustomrotor/systemrotortype-swift.enum (heading, headingLevel1 to 6, link, image, list, table); uikit/uiaccessibilitycustomrotorsearchpredicate (currentItem, searchDirection); uikit/uiaccessibilitycustomrotoritemresult (targetElement, targetRange).
Edge cases: the current item is nil (start from the page's first element); a match in the previous chapter (turn chapters only if the next chapter is laid out, else return nil and announce); duplicate headings.
Test: XCTest invoking the search closures with a predicate from each element; device checklist for the rotor's behaviour across pages.

APL-32 Runs with a `languageIdentifier` different from the chapter language shall appear in `accessibilityAttributedLabel` with `accessibilitySpeechLanguage` set to the same BCP 47 tag, and in read-aloud utterances as their own AVSpeechUtterance with a voice for that language (APL-39); a proper noun with an explicit pronunciation (EPUB 3 `ssml:ph`) may carry `accessibilitySpeechIPANotation`.
Why: documentation: the speech language key "rules for the specified language govern how to pronounce that string"; WWDC19 248 demonstrates both attributes on reading content.
Citation: foundation/nsattributedstring/key/accessibilityspeechlanguage; foundation/nsattributedstring/key/accessibilityspeechipanotation; foundation/nsattributedstring/key/languageidentifier.
Edge cases: a language tag VoiceOver has no voice for (VoiceOver falls back; no API to check); a whole chapter in another language (set it on every element, and the chapter's `dc:language` or `xml:lang` on `html` is the source).
Test: an XCTest asserting the attribute ranges on a mixed-language fixture; device check that VoiceOver switches voice.

APL-33 After a page turn the reader shall post `layoutChanged` with the new page's first block element as the argument (or, after a relayout caused by a font or size change, with the element that now contains the reading offset that was focused before), and after the chapter's first page appears it shall post `screenChanged` with the first element; while read-all is running it shall post nothing that would move focus.
Why: documentation for both notifications: "Optionally, include a parameter that contains the accessibility element for VoiceOver to move to after processing the notification". Funston's EPUB reader posts screenChanged on open and the PDF reader posts layoutChanged when lines arrive for a visible page. Posting during read-all restarts VoiceOver's reading, which is the Readium bug Camden saw (focus jumping to the end of the chapter).
Citation: uikit/uiaccessibility/notification/layoutchanged; uikit/uiaccessibility/notification/screenchanged; Funston/UI/EPUBReaderController.swift and PDFLineAccessibility.swift.
Edge cases: a page turn caused by VoiceOver's own `accessibilityScroll` (post pageScrolled, not layoutChanged, so read-all continues); Dynamic Type change while VoiceOver focus is on a paragraph (re-resolve by offset, APL-27).
Test: device checklist items for focus after manual turn, after read-all turn, and after a text size change.

APL-34 Tables (APL-21) shall expose a `UIAccessibilityContainerDataTable` whose cell elements implement `UIAccessibilityContainerDataTableCell` with row and column ranges and whose header elements come from `th` cells, and the table element shall set `accessibilityContainerType = .dataTable`; lists shall set `.list` on their container element.
Why: VoiceOver announces row and column position and headers for data tables, which is the only way a table reads sensibly.
Citation: uikit/uiaccessibilitycontainerdatatable (iOS 11); uikit/uiaccessibilitycontainerdatatablecell; uikit/uiaccessibilitycontainertype (dataTable, list, landmark, semanticGroup).
Edge cases: layout tables (Gutenberg's title blocks and poetry alignment; expose them as a semantic group of text elements instead, decided by a heuristic: no `th`, one column, or every row a single cell); spanning cells.
Test: the table fixture with an XCTest on row and column counts and header elements; device check of the announcement.

APL-35 Footnote and endnote references (`epub:type="noteref"`, or a link to an element with `epub:type` note, footnote, endnote or rearnote) shall be exposed as a custom action "Show note" on the containing paragraph element and as a link element inside it, and activating one shall present the note text in a sheet that VoiceOver focuses, instead of jumping the reading position to the note's page; the note content itself shall be exposed through `AXCustomContentProvider` on the reference element with importance `.default` (so it reads on request through the More Content rotor) when it is short enough.
Why: a jump to the notes page loses the reading position and breaks read-all; WWDC21 10121 is the mechanism for content read on request.
Citation: accessibility/axcustomcontent and accessibility/axcustomcontentprovider (iOS 14); uikit/uiaccessibilitycustomaction/editcategory for actions tied to selection (not used here).
Edge cases: notes in another spine item (resolve lazily when activated); a note that is itself a long passage.
Test: a fixture with noteref links; XCTest on custom actions and custom content; device check of the sheet's focus.

APL-36 When VoiceOver is running and the user has chosen pages, the reader shall still use pages (not switch to continuous scrolling as Readium does), because the model above is designed for read-all across pages; the continuous mode (one UITextView per chapter) shall remain available as a user choice through the existing readingLayout setting.
Why: Readium's switch was a workaround for a web view; Apple's reading content protocol exists for paged books. The continuous mode is nearly free (UITextView provides text navigation, selection and find) and is a useful comparison harness when a VoiceOver behaviour in the custom page is in doubt.
Citation: WWDC26 219 ("use them whenever the app's constraints allow", of the built-in text views); Funston/Services/SettingsStore.swift (readingLayout) and Funston/UI/EPUBReaderController.swift (scroll when continuous).
Test: device checklist runs in both modes.

APL-37 The following can only be verified by running VoiceOver on a device or simulator, and shall be checked before the reader is called done, with the ios-sim-voiceover tooling or on Camden's iPhone, after every change to the accessibility layer:
1. Touch exploration: dragging across a page speaks the line under the finger (reading content protocol) with no "tick" sound over margins and gutters.
2. Swipe right and left moves block by block in reading order, each paragraph one element, headings announced with "heading" and their level, images with their alt text and "image", links with "link".
3. Lines rotor: flick down from the first line of a paragraph continues into the next paragraph (text navigation element links) and from the last line of the page into the next page.
4. Characters and Words rotors work inside a paragraph (UITextInput adoption).
5. Read-all (two-finger swipe down) reads to the bottom of the page, turns the page (causesPageTurn and accessibilityScroll), announces "Page x of y", continues reading, and continues into the next chapter; stopping and restarting resumes at the paragraph that was being read.
6. Three-finger swipe turns pages and announces the page string; at the ends of the book the same string repeats and VoiceOver signals the boundary.
7. Focus after a manual page turn lands on the first block of the new page; focus after a text size change lands on the paragraph that was focused.
8. Headings, Links, Images and Chapters rotors move across pages.
9. Selection: double-tap and hold selects, the edit rotor offers Select and Copy, and the edit category custom action appears when provided.
10. Speak Screen (two-finger swipe down from the top with the feature on) reads the page and turns pages.
11. A braille display shows the focused paragraph's text and routing keys move the VoiceOver cursor within it (expected from UITextInput adoption; not documented, verify).
12. Mixed-language runs switch voice.
13. Accessibility Reader (iOS 26 and later, Settings > Accessibility > Read and Speak) opens the page's text when invoked from Control Center.
14. Nothing on the page is announced twice (the page's chrome element and the blocks do not overlap), and no off-page element is reachable.
Why: none of these is observable from code; ChatMarkdownKit and RelayGenUI each burned several rounds on VoiceOver features that were reasoned about and shipped unverified.
Citation: this study's experiments did not drive VoiceOver; WWDC19 248 and WWDC26 219 describe the expected behaviour.
Test: the list is the test.

APL-38 The reader shall keep the `ReaderPageElement` ("Reading page", adjustable, increment and decrement turn pages, magic tap toggles controls) that Funston's PDF and EPUB readers share, placed first in the page container's `accessibilityElements`, and it shall not duplicate the page's text in that element's label or value.
Why: it is the house convention, already verified under VoiceOver for PDFs, and it gives a page-turn affordance that does not depend on three-finger swipes.
Citation: Funston/UI/PDFLineAccessibility.swift (ReaderControls, ReaderPageElement).
Test: XCTest on `accessibilityElements.first` and on increment and decrement.

### Speech

APL-39 Read-aloud shall use one AVSpeechSynthesizer retained for the life of the reader screen, enqueueing one AVSpeechUtterance per block in reading order (paragraphs, headings, list items, image alt text prefixed "Image:", table cells row by row), built with `init(attributedString:)` so IPA attributes carry through, with `voice` from `AVSpeechSynthesisVoice(language:)` for the block's language (nil result falls back to the default voice), `prefersAssistiveTechnologySettings = true`, rate, pitch and volume from the reader's settings, and `postUtteranceDelay` of 0.3 s after paragraphs and 0.6 s after headings; it shall keep two utterances queued ahead of the one being spoken, across page and chapter boundaries, and shall turn to the page containing an utterance's block when the delegate reports `didStart` for it.
Why: documentation: the synthesizer "maintains a queue of utterances that it speaks" and "Split a body of text into multiple utterances if you want to apply different speech parameters"; `prefersAssistiveTechnologySettings` makes VoiceOver's voice and rate win when VoiceOver is on, which is what a VoiceOver user expects, and when it is off "the speech synthesizer uses the utterance property values"; `init(language:)` is documented to return "a voice for the specified language and locale code if the code is valid; otherwise, nil", so the fallback is needed; "The system doesn't automatically retain the speech synthesizer, so you need to manually retain it until speech concludes".
Citation: avfaudio/avspeechsynthesizer; avfaudio/avspeechutterance; avfaudio/avspeechutterance/prefersassistivetechnologysettings (iOS 14); avfaudio/avspeechsynthesisvoice/init(language:); avfaudio/avspeechutterance/init(attributedstring:); WWDC20 10022 (the assistive settings "override properties you set explicitly on the utterance").
Edge cases: Siri voices cannot be selected through the API (WWDC20: a fallback voice of the same language is used); a block longer than a few thousand characters (split at sentence boundaries so pause and highlight stay responsive); a chapter boundary where the next chapter is not laid out yet (enqueue from the parsed string anyway; the page turn waits for layout); an utterance whose block was removed by a relayout (ids are offsets in the chapter string, which relayout does not change).
Test: a unit test on the queue builder (ordering, language assignment, delays); a device test that speech continues across a chapter boundary.

APL-40 Word highlighting shall come from `speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)`, mapping the utterance's range to the chapter by adding the block's start offset, drawing the highlight with a rendering attribute (`addRenderingAttribute(.backgroundColor, ...)`) on the chapter's layout manager and redrawing the page; pause shall use `pauseSpeaking(at: .word)`, resume `continueSpeaking()`, and stop `stopSpeaking(at: .immediate)`, remembering that stop clears the queue and that a pause at a word boundary resumes "from the word that follows the last spoken word".
Why: the delegate method is documented as called "once for each unit of speech in the utterance's text, which is generally a word" and recommended for highlighting; the boundary semantics are documented on pauseSpeaking.
Citation: avfaudio/avspeechsynthesizerdelegate/speechsynthesizer(_:willspeakrangeofspeechstring:utterance:); avfaudio/avspeechsynthesizer/pausespeaking(at:); avfaudio/avspeechsynthesizer/stopspeaking(at:) ("removes all unspoken utterances from the synthesizer's queue").
Edge cases: the range refers to `speechString`, which for an attributed utterance is the plain string, so the block offset mapping must use the same plain string; `willSpeak(marker:)` (iOS 17) adds sentence and paragraph markers for a coarser highlight when a voice provides them; highlighting under VoiceOver is pointless and should be skipped when `isVoiceOverRunning`.
Test: a unit test on the range mapping including a list paragraph (APL-17); a device test of pause and resume at a word boundary.

APL-41 Before speech starts the reader shall call PlaybackController's `pauseAndDeactivate()` and proceed only if it returns true, then set the shared AVAudioSession category to `.playback`, mode `.spokenAudio`, options empty, activate it, leave `usesApplicationAudioSession` at its default of true, and observe `AVAudioSession.interruptionNotification` (pause at `.word` on began; on ended with `shouldResume`, continue) and `routeChangeNotification` (pause on `oldDeviceUnavailable`); when speech ends or the screen closes it shall deactivate with `notifyOthersOnDeactivation`.
Why: Funston's PlaybackController owns the session (category playback, mode default, activation serialised on a dedicated queue because "AVAudioSession activation performs synchronous interprocess work", deactivation with notifyOthersOnDeactivation, interruption and route handling, and a `pauseAndDeactivate()` hand-off that returns false if a new play intent arrived meanwhile). Two owners fighting over one session is the bug class Funston already guards against with its video ownership token. `spokenAudio` is documented as "appropriate for apps that play continuous spoken audio, such as podcasts or audio books" and makes the system pause rather than duck the reader when another app plays a short spoken prompt. `usesApplicationAudioSession = false` would make the system create "a separate audio session to automatically manage speech, interruptions, and mixing and ducking the speech with other audio sources", which is right for occasional prompts over music and wrong for an audiobook-length read that should stop the music instead. Playback category without `mixWithOthers` interrupts other apps' audio, as an audiobook should.
Citation: avfaudio/avspeechsynthesizer/usesapplicationaudiosession (iOS 13); avfaudio/avaudiosession/mode-swift.struct/spokenaudio; avfaudio/avaudiosession/category-swift.struct/playback ("By default, using this category implies that your app's audio is nonmixable"); avfaudio/avaudiosession/setactiveoptions/notifyothersondeactivation; Funston/Services/PlaybackController.swift (AudioSessionWorker, pauseAndDeactivate, configureAudioNotifications).
Edge cases: the user starts music playback from the mini-player while reading aloud (the reader must stop speech when PlaybackController activates; the merged spec should add an intent observer or have the reader hold an ownership token like `acquireVideoPlayback`); Now Playing and remote commands (PlaybackController registers them; read-aloud should either publish its own Now Playing info with play, pause and skip-paragraph commands or leave the lock screen alone, an open question); background: Funston already has the audio background mode, so speech continues with the screen locked.
Test: a unit test with PlaybackController's injected activator and deactivator closures asserting the order of calls; a device test with Music playing in another app.

APL-42 Read-aloud shall be usable with VoiceOver running (it is not a replacement for VoiceOver's read-all, which Apple says to keep separate), and it shall not post VoiceOver announcements while speaking.
Why: WWDC20 10022: AVSpeechSynthesizer is "not a replacement for VoiceOver. Make the app accessible with UIAccessibility APIs and use AVSpeechSynthesizer alongside them".
Citation: WWDC20 10022.
Test: device check that both can be started and that stopping one does not stop the other.

### Selection and find

APL-43 Selection shall be provided by the UITextInput adoption in APL-30 with the system `UITextInteraction(for: .nonEditable)`; the edit menu shall offer Copy, Share, Look Up and Speak (the last enqueuing the selection in the read-aloud synthesizer); and a highlight or note feature, if the merged spec wants one, shall store chapter offsets, never page coordinates.
Why: the interaction gives the native handles, loupe and menu, and VoiceOver's selection rotor (WWDC26 219 adds the edit category for custom actions on selections).
Citation: uikit/uitextinteraction; uikit/uitextselectiondisplayinteraction (iOS 17) and uikit/uitextloupesession (iOS 17) as alternatives when custom gestures are needed; WWDC23 10058.
Edge cases: selection across a page boundary (allowed in the chapter's offsets; the next page shows its part); selection inside a list paragraph (APL-17 offsets); the page's tap-to-show-controls gesture must `require(toFail:)` the interaction's gestures listed in `gesturesForFailureRequirements`.
Test: device check of select, copy and the menu; XCTest on `selectedTextRange` round trips.

APL-44 Find in book shall use UIFindInteraction on the page container with a UITextSearchingFindSession whose searchable object is the book document; `performTextSearch(queryString:options:resultAggregator:)` shall search every parsed chapter's plain text on a background queue (the aggregator is documented thread-safe by WWDC22) using `NSString.range(of:options:)` with `.caseInsensitive` and `.diacriticInsensitive` plus the session's `UITextSearchOptions.wordMatchMethod`, reporting `foundRange` with a document identifier per chapter; `decorate(foundTextRange:document:usingStyle:)` shall add rendering attributes on the chapter layout (yellow background for found, orange for highlighted) and `scrollRangeToVisible(_:inDocument:)` shall turn to the page containing the range, laying the chapter out first if needed; `compare` shall order by spine index then offset.
Why: the find panel, keyboard shortcuts (Command-F, Command-G) and result count come free; multi-document search is the documented pattern for conversations and fits chapters.
Citation: uikit/uifindinteraction; uikit/uifindinteractiondelegate; uikit/uitextsearchingfindsession ("The find session's reference to searchableObject is weakly held"); uikit/uitextsearching-3wkjv; uikit/uitextsearchaggregator-swift.struct (foundRange, invalidateFoundRange, finishedSearching); uikit/uitextsearchoptions; WWDC22 10071.
Edge cases: a chapter not yet parsed (parse on demand; the aggregator accepts late results until `finishedSearching`); thousands of matches (cap per chapter and report the cap); matches in list markers (not in the string, so none).
Test: XCTest driving `performTextSearch` with a stub aggregator across two corpus chapters; device check of the find panel and result navigation.

### Resources and availability

APL-45 Every TextKit, accessibility, speech and interaction API this study names that is newer than iOS 18.0 shall be guarded with `#available` and have a defined behaviour without it: `resolvesNaturalAlignmentWithBaseWritingDirection` and `includesTextListMarkers` (iOS 26; not needed when APL-15 and APL-17 are followed), `NSTextViewportRenderingSurface`, the viewport delegate's cache and retrieve rendering surface methods, the layout manager delegate's attachment view provider cache methods, `UITextView.register(_:forTextAttachmentViewProviderType:)`, `NSTextBlock` per-edge widths and colours, and `NSTextSelectionNavigation.convertInteractionPoint` (iOS 27; none are needed by the page renderer), `accessibilityTextInputResponder` (iOS 18.1), and SwiftUI's `accessibilityLinkedGroup` (iOS 27, SwiftUI only, not applicable to UIKit pages). APIs at or below the target that this design relies on: TextKit 2 classes (iOS 15), `NSTextListElement` (iOS 16), `UIFindInteraction` and `UITextSearching` (iOS 16), `textLineFragment(for:isUpstreamAffinity:)` and `textLineFragment(forVerticalOffset:requiresExactMatch:)` (iOS 17), `UITextSelectionDisplayInteraction` (iOS 17), `willSpeak(marker:)` and personal voices (iOS 17), text navigation elements and `UIAccessibilityCustomAction.editCategory` (iOS 18), `os_proc_available_memory` (iOS 13).
Why: the deployment target is iOS 18.0; the iOS 27 SDK header marks are the source for each of these.
Citation: the SDK headers listed in section 1 and the reference pages' availability lines.
Test: build with the deployment target and the strict availability warnings as errors.

APL-46 The reader shall keep at most three chapter layouts resident (the current chapter and its neighbours), pre-laying out the next chapter in the background when the user is within two pages of a chapter boundary, dropping layouts beyond that window, decoding images only at the size they are drawn (APL-19), and shedding every non-current layout and decoded image on a memory warning or when `os_proc_available_memory()` falls below 200 MB.
Why: measured, one 200 KB chapter's TextKit 2 layout added 12.5 MB (iOS 18.3), 13.1 MB (iOS 27) and 15.6 MB (macOS) to the process's physical footprint, the attributed string under 1 MB and the line table under 1 MB; three resident chapters are therefore about 40 MB, well inside an iPhone's budget, while a whole 190-chapter book laid out at once would be about 2.5 GB. A full-size decoded photo is 45 MB (4000 by 3000 by 4 bytes); a page-sized one is 1.5 MB. Apple publishes no per-app memory limit; `os_proc_available_memory` is the documented query.
Citation: os/proc.h (`os_proc_available_memory`, iOS 13); the footprint measurements.
Edge cases: a single chapter of several megabytes (Internet Archive OCR EPUBs sometimes have one spine item; split the attributed string into sections of at most 300 KB at paragraph boundaries and paginate each as a sub-chapter); the pre-layout racing with a user jump to a far chapter (cancel by generation).
Test: a memory test that paginates the corpus with three layouts resident and asserts the footprint delta; a test of the shed path.

APL-47 Every failure in the pipeline shall produce a typed diagnostic (chapter href, stage, code, message, count) collected per book and visible in a debug screen, and no failure in one chapter shall stop the book from opening; the only fatal errors are: not a ZIP, no readable container.xml, no readable OPF, and an empty spine.
Why: the house rule is that a render path fails loud into a diagnostic, never blank; Gutenberg and Internet Archive books are malformed in small ways constantly.
Citation: Funston's existing diagnostics convention (CLAUDE.md), section 8 below.
Test: each malformed fixture in section 9 opens with the expected diagnostic list.

## 5. Algorithms

### 5.1 Pagination

Input: the chapter attributed string, the page content size (width w, height h), the layout settings. Output: a line table and a page table.

1. Create NSTextContentStorage; set `textStorage = NSTextStorage(attributedString:)`. Create NSTextLayoutManager; set `usesHyphenation` from settings; `addTextLayoutManager`. Create NSTextContainer(size: CGSize(width: w, height: 0)); `lineFragmentPadding = 0`; assign it to the layout manager.
2. `ensureLayout(for: layoutManager.documentRange)`.
3. `enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout])`. For each fragment: elementStart = `offset(from: documentRange.location, to: fragment.rangeInElement.location)`; markerPrefix = 0, or for an NSTextListElement the location of `contents.string` in `attributedString.string`. For each line in `textLineFragments` with a non-empty `characterRange`: record (docStart = elementStart + characterRange.location - markerPrefix, length = characterRange.length, frame = fragment.layoutFragmentFrame.origin + line.typographicBounds, fragment reference, line reference). Skip the synthesised trailing empty line (characterRange.length 0 at the chapter end).
4. Page cut: pageTop = first line's minY; for each line in order, if line.maxY - pageTop > h + 0.01 and the line is not the page's first, close the page before it and set pageTop = line.minY. Optional widow and orphan rule: if the cut leaves a paragraph with a single line on either side, move the cut up by one line (at most twice).
5. A forced break (APL-13) closes the page before the first line of the element.
6. A line taller than h (block image) gets a page of its own; the image was already scaled to fit (APL-19), so this only happens for images exactly page-high.
7. Page record: first line index, last line index, pageTop, firstOffset = first line's docStart, endOffset = last line's docStart + length.

Position to page: binary search the page table by firstOffset. Point to line: binary search the page's lines by y, then check x against the line's frame for the reading content protocol.

Costs measured: step 2 is the whole cost (70 to 252 ms for 200 KB), steps 3 to 7 under 4 ms.

### 5.2 Drawing a page

In the page view's `draw(_:)` (UIKit hands a top-left-origin context): for each line record on the page, `line.draw(at: CGPoint(x: frame.minX, y: frame.minY - pageTop), in: context)` where frame is the record's frame from step 3 (fragment origin plus typographic bounds origin). Do not add `glyphOrigin`. Draw selection and highlight rectangles first, from `enumerateTextSegments` clipped to the page, with `frame.minY - pageTop` applied. For fragments wholly inside the page `fragment.draw(at: CGPoint(x: fragment.layoutFragmentFrame.minX, y: fragment.layoutFragmentFrame.minY - pageTop), in: context)` is equivalent and slightly cheaper.

### 5.3 Rectangles for a range

Given UTF-16 offsets a..<b in the chapter: start = `location(documentRange.location, offsetBy: a)`, end = `location(start, offsetBy: b - a)`, range = NSTextRange(location: start, end: end). `enumerateTextSegments(in: range, type: .selection, options: [])` yields (segmentRange, frame, baseline, container); frames are in container coordinates; subtract the page's pageTop and drop frames outside the page. For a caret use a zero-length range with `.standard`. For VoiceOver line frames prefer the line table (no enumeration needed).

### 5.4 Reading content protocol lookups

`accessibilityLineNumber(for point)`: convert the screen point into the page view with `UIAccessibility.convertToScreenCoordinates` inverted (convert the page's bounds to screen once per call and map proportionally, or use `window.convert`); binary search the page's lines by y; if x lies within the line's frame (expand to the content width for leading and trailing gutters inside the column) return its index in the page, else NSNotFound. `accessibilityFrame(forLineNumber:)`: the line's frame shifted by pageTop into the page view, converted to screen coordinates. `accessibilityAttributedContent(forLineNumber:)`: the chapter string's attributed substring for the line's document range, with `accessibilitySpeechLanguage` copied from `languageIdentifier` runs. `accessibilityAttributedPageContent()`: the concatenation of the page's blocks' text with "\n" between blocks.

### 5.5 Page turning for VoiceOver

`accessibilityScroll(direction)`: map `.next`, `.left`, `.down` to forward and `.previous`, `.right`, `.up` to backward (swap left and right for a right-to-left page progression); if there is no page in that direction return false (VoiceOver then asks the superview; the container returns false too, and VoiceOver announces the boundary because the pageScrolled string repeats); otherwise turn the page without animation when VoiceOver is running, post `pageScrolled` with "Page \(n) of \(total)", return true. Do not post layoutChanged in this path.

### 5.6 ZIP reading

1. Map the file. n = byte count. If n < 22 fail.
2. For o from n - 22 down to max(0, n - 22 - 65535): if u32(o) == 0x06054b50 and u16(o + 20) == n - 22 - o, this is the end record.
3. entries = u16(o + 10), cdSize = u32(o + 12), cdOffset = u32(o + 16). If o >= 20 and u32(o - 20) == 0x07064b50: z = u64(o - 12) (the record offset at locator + 8); require u32(z) == 0x06064b50; entries = u64(z + 32), cdSize = u64(z + 40), cdOffset = u64(z + 48). Else if any of the three is its all-ones value, fail.
4. p = cdOffset; repeat entries times: require u32(p) == 0x02014b50; flags = u16(p + 8), method = u16(p + 10), crc = u32(p + 16), csize = u32(p + 20), usize = u32(p + 24), nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32), local = u32(p + 42); name bytes at p + 46; walk extra fields (id u16, size u16) from p + 46 + nameLen; for id 0x0001 read u64 values in order for each of usize, csize, local that was all ones; p += 46 + nameLen + extraLen + commentLen.
5. To extract: o = local; require u32(o) == 0x04034b50; data = o + 30 + u16(o + 26) + u16(o + 28); require data + csize <= n. Method 0: copy. Method 8: inflate as in 5.7 into usize bytes. Verify crc32.

### 5.7 Inflate with the Compression framework

Allocate a `compression_stream`; `compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)` must return OK. Set `src_ptr` and `src_size` to the entry's compressed bytes (inside `withUnsafeBytes` on the mapped Data), `dst_ptr` and `dst_size` to a buffer of usize bytes. Call `compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))`. Accept only `COMPRESSION_STATUS_END` with `dst_size == 0`; `COMPRESSION_STATUS_OK` with `dst_size == 0` means more output than declared (corrupt); `COMPRESSION_STATUS_OK` with `src_size == 0` means truncated input; `COMPRESSION_STATUS_ERROR` means corrupt. `compression_stream_destroy`. For entries larger than a few megabytes, loop with a 1 MB destination window appended to the output instead of one allocation.

### 5.8 Entity pre-expansion

Regular expression `&([A-Za-z][A-Za-z0-9]*);` over the decoded chapter string, replacing from the end so ranges stay valid: skip amp, lt, gt, quot, apos and any name declared in the document's internal subset; for a name in the HTML table emit `&#` + decimal code point + `;` (two code points for the few entities that expand to two, emitted as two references); otherwise emit U+FFFD and count the name. Measured 0.5 to 0.65 ms on 62 KB.

### 5.9 Direction resolution

For each block: if a `dir` attribute is ltr or rtl on the element or an ancestor, use it; else if the element's effective language (nearest `xml:lang` or `lang`, else the chapter language) has a primary subtag in the right-to-left set, rtl; else scan the block's text for the first character whose code point is in the right-to-left blocks (APL-15), rtl if found before any Latin, Greek, Cyrillic, CJK or other left-to-right letter; else ltr. Set `baseWritingDirection` accordingly and map CSS start and end alignments.

### 5.10 Read-aloud queue

Keep an index into the chapter's block list. Build an utterance for the block at the index and the next two; call `speak` for each; on `didStart` for an utterance whose block is on another page, turn to that page (no animation under VoiceOver); on `didFinish`, build the block three ahead (crossing into the next chapter's parsed blocks when the current chapter ends); on `willSpeakRangeOfSpeechString`, highlight block.start + range. Pause: `pauseSpeaking(at: .word)`. Resume: `continueSpeaking()`. Jump to a different paragraph: `stopSpeaking(at: .immediate)` then rebuild from the new index.

## 6. Data model and persistence

### 6.1 Layout key

A value type with: contentWidth and contentHeight in points rounded to 0.5, basePointSize, fontFamily (or "system" and "serif" and so on), contentSizeCategory, lineHeightMultiple, paragraphSpacingFactor, hyphenation (Bool), publisherStyles (Bool), alignment, osVersion (major.minor), parserVersion (Int), embeddedFontsHash (SHA-256 of the sorted font entry CRCs). Its string form is the cache key.

### 6.2 Page table cache

Per (book identifier, file name, chapter href, layout key): `[Int]` of page start offsets (UTF-16 into the chapter string), the chapter's end offset, and a timestamp. Storage: the `cache_entries` table with kind "epub-pages" (a JSON array), or in-process only. Lifetime: a year; invalidated by parserVersion. Size: 190 entries for the largest corpus chapter.

### 6.3 Reading position

Today `book_positions` stores Readium Locator JSON (`locator TEXT NOT NULL`, keyed by identifier and file name). The native reader's position is a JSON object in the same column, distinguished by a `"version": 1` field, with: `href` (spine item href as in the OPF), `offset` (UTF-16 offset of the first character on the page being read, into the chapter string produced by the reader's parser), `anchor` (the id of the last element with an id at or before the offset, or null), `snippet` (the first 48 characters of the paragraph containing the offset, for re-resolution if the parser changes), `progression` (offset divided by chapter length, 0 to 1), `chapterIndex`, and `totalProgression` (fraction of the book's characters before this point, for the shelf). Resolution order when restoring: offset if the chapter length matches the stored length within 1%, else anchor, else snippet search, else progression. Migration from a Readium locator: use its `href` and `locations.progression`, and `text.highlight` or `text.before` as the snippet. The merged spec owns the final shape; this is the native side's minimum.

### 6.4 Diagnostics

Per book, in memory, mirrored to the log with OSLog: stage (zip, container, opf, nav, chapter.parse, chapter.recover, css, font, image, layout, a11y, speech), href, code (a short enum raw value), message, count.

### 6.5 Chapter session

The object that owns a chapter's parsed tree, attributed string, block list (start offset, end offset, kind, heading level, language, element id, alt text, link), layout objects, line table and page table. Confined to a serial queue during layout, main-actor afterwards. At most three alive (APL-46).

## 7. Accessibility

This section collects the VoiceOver model in one place; the requirements above have the citations.

### 7.1 What VoiceOver does with the reading content protocol

From the documentation and WWDC19 248: with the protocol implemented on an element that represents the readable content, touch exploration speaks and highlights the line under the finger (line number from the point, content and frame for the line), read-all speaks the page content and, when the element carries causesPageTurn, calls `accessibilityScroll(.next)` and continues on the new page until the content stops changing. The pageScrolled argument is spoken after each turn. The attributed variants are asked first, so speech language and IPA attributes per line work. The protocol has existed since iOS 5 and has not changed; the iOS 27 SDK header still says "Use in conjunction with UIAccessibilityTraitCausesPageTurn to provide a continuous reading experience with VoiceOver".

### 7.2 What VoiceOver does with linked text elements and UITextInput

From WWDC26 219 (UIKit APIs from iOS 18): without links, the Lines rotor is stuck inside each paragraph element; with `accessibilityNextTextNavigationElement` and the previous property set, VoiceOver moves across paragraphs by line, word and character; with the full UITextInput protocol on the element, VoiceOver gets line-by-line exploration, the Characters, Words and Lines rotors, selection with the edit rotor, and Speak Screen navigation. The session's custom view adopted UITextInput on a UIView, added a non-editable UITextInteraction, implemented `selectionRects(for:)` and `text(in:)`, a tokenizer subclass, and called the input delegate around selection changes. The trait and scroll method for page turns were applied to the last paragraph of each page.

### 7.3 How Funston's PDF reader exposes lines today, and what changes

PDFLineAccessibleView replaces PDFKit's page container with one UIAccessibilityElement per recognised line (static text trait, identifier "reader.line.page.line"), frames computed on every read from the page's normalised boxes, `accessibilityElementDidBecomeFocused` scrolling the line into view without changing zoom, elements kept for at most eight pages, a layoutChanged post when a visible page's lines arrive, `accessibilityScroll` turning pages and posting "Page x of y", and the shared ReaderPageElement first in the array. The EPUB page keeps the container shape, the page element, the page turn and announcement, and the compute-on-read frames, and changes the unit from line to block, adds the text navigation links, the reading content protocol and UITextInput. OCR lines stay lines because they are the truth of a scan; reflowed paragraphs are the truth of a book.

### 7.4 What a page looks like to VoiceOver

Elements array: [ReaderPageElement, block 1, block 2, ..., block n]. Block i: label is its text; attributed label adds heading level and speech languages; traits staticText plus header, link or image; value empty; hint empty; custom actions for inner links and notes; previous and next text navigation elements set to i - 1 and i + 1 (nil at the page ends; the Lines rotor then relies on causesPageTurn and read-all to cross pages, which is a point to verify); the last block carries causesPageTurn. Rotors: Headings (and levels), Links, Images, Chapters. Container: the page view, which implements the reading content protocol and UITextInput, with `accessibilityContainerType = .semanticGroup` and a label equal to the chapter title for the container announcement.

### 7.5 Braille, Speak Screen, Accessibility Reader

Braille output follows the VoiceOver cursor, so it shows the focused block's label; with UITextInput adoption the routing keys should move within the text (not documented; verify). Speak Screen reads the page's accessible text top to bottom and, per WWDC26 219, turns pages through the same causesPageTurn and accessibilityScroll path. Accessibility Reader (iOS 26) is a system reading mode with no API; the session says accessible text practices improve it. `UIAccessibility.isSpeakScreenEnabled` exists for diagnostics only.

### 7.6 Focus restoration

After a manual page turn: post layoutChanged with the first block. After relayout: find the block containing the previously focused block's start offset and post layoutChanged with it. After chapter change: screenChanged with the first block. Never post while read-all is running (detect from `accessibilityScroll` having been called by VoiceOver rather than the user).

### 7.7 Verification

APL-37 is the checklist. Use the ios-sim-voiceover skill on a simulator for the mechanics (focus order, rotor membership, read-all continuation) and Camden's device for voices, braille and Speak Screen.

## 8. Malformed input and failure behaviour

- Not a ZIP (no end record): fatal, "The file isn't a book this app can read" (the wording EPUBReaderController uses today).
- ZIP64 markers without a record, central directory outside the file, truncated entry data: fatal if container.xml or the OPF is affected, otherwise a per-entry diagnostic and the chapter shows "This chapter couldn't be read".
- CRC mismatch: the entry is treated as unreadable (diagnostic), never shown.
- Encrypted entry or unknown method: unreadable entry with the method number.
- Missing or wrong mimetype: diagnostic only.
- container.xml missing or unparseable: fatal. OPF missing or unparseable: fatal. Empty spine: fatal.
- Manifest item missing from the ZIP: the spine item shows a placeholder page with the href and a diagnostic.
- Navigation document missing: fall back to NCX, then to spine item titles, then "Section n".
- Chapter not well formed: XMLParser error (code, line, column) recorded; recovered through the libxml2 HTML parser (APL-11); if that also fails (it did not in any test), the chapter's text is extracted by stripping tags from the decoded string and rendered as one paragraph with a diagnostic.
- Undeclared entities: handled by pre-expansion; unknown names become U+FFFD and are counted.
- Invalid bytes for the declared encoding: re-decoded as Windows-1252 with a diagnostic; control characters stripped.
- Unsupported CSS: ignored and counted by property name.
- Font data invalid: `CTFontManagerCreateFontDescriptorsFromData` returns an empty array; fall back to the user font with a diagnostic.
- Image missing, undecodable, or SVG: alt text placeholder with a diagnostic.
- Image huge: decoded only at page size (APL-19), so no memory spike; a 4000 by 3000 image costs 1.5 MB.
- Chapter huge (megabytes): split into sections at paragraph boundaries (APL-46).
- Pathological text (bidi control floods, millions of combining marks): `limitsLayoutForSuspiciousContents` exists on NSTextLayoutManager, documented as "internal security analysis for malicious inputs" with the caveat that "a very long paragraph might result in an unexpected layout", and Core Text's `kCTTypesetterOptionAllowUnboundedLayout` defaults to false. Enable the TextKit 2 flag for books from untrusted sources only after the experiment in section 11 shows it does not change ordinary Gutenberg layout.
- Layout failure (no fragments for a non-empty chapter): the chapter is rendered as plain paragraphs with the system font, with a diagnostic; never a blank page.
- Speech: a voice not found falls back to the default; an audio session activation error shows the same "Audio is unavailable right now" phase PlaybackController uses.

## 9. Test fixtures and vectors

### 9.1 ZIP fixtures (how made, what to assert)

- ziptool.zip: `zip -q -r ziptool.zip mimetype a.txt b.txt sub` from a folder with mimetype (20 bytes), a.txt (99 bytes), b.txt (266,669 bytes of base64), sub/ünïcode name.txt. Assert 5 entries, mimetype first and stored, three deflated, flags 0 everywhere (name bytes are UTF-8 without bit 11), local header CRCs set.
- zipstream.zip: the same via `zip -q -r - ... > zipstream.zip`. Identical properties (Info-ZIP buffered, no data descriptors).
- zip64.zip: `zip -q -r -fz zip64.zip ...`. Assert the ZIP64 end record is used, every entry has the 0x0001 extra, local header sizes are 0xFFFFFFFF, CRCs good.
- finder.zip: `ditto -c -k --sequesterRsrc --keepParent src finder.zip`. Assert 14 entries: 5 directories, 5 `__MACOSX` entries, 4 files with flag 0x8 and zero local CRC and sizes, mimetype second, all CRCs good from central directory values.
- python.zip: zipfile with `mimetype` ZIP_STORED first, deflated a.txt and b.txt, `streamed.txt` written through `open(..., 'w', force_zip64=True)` (stored, local sizes 0xFFFFFFFF, central directory real sizes), and the Unicode name with flag 0x800. Assert exactly those.
- pg20512-images.epub: 23 entries, mimetype first stored, 21 deflated, 1 stored PNG, no descriptors, no ZIP64, extracted total 624,591 bytes, all CRCs good.
- Derived: a truncated copy (last 100 bytes removed), a copy with byte 1000 flipped, an empty file.

### 9.2 XHTML cases and recorded outcomes (XMLParser, defaults unless noted)

Identical outcomes on macOS 27.0.1, iOS 18.3.1 and iOS 27.0.

| Case | Input | Outcome |
| --- | --- | --- |
| A | `<p>a&nbsp;b<i>c</i>d</p>` | fatal, code 26 at column 11, text "a" delivered, resolveExternalEntityName called with "nbsp" |
| A2 | A with a delegate returning Data for nbsp | still fatal, code 26 |
| B | A wrapped in html with the XHTML 1.1 DOCTYPE | success; "a", "b" delivered with the entity dropped; two resolve callbacks (nbsp, mdash) |
| B2 | B with a delegate returning replacements | success; U+00A0 and U+2014 delivered where returned, unknown name dropped |
| C, C2, C3 | B with shouldResolveExternalEntities true, policy never, policy always | same as B; no network activity observed (0.02 ms) |
| D | internal subset declaring nbsp and mdash | success; declarations reported; characters delivered |
| D2 | internal subset and external DOCTYPE | success; declared entity expands, undeclared `&copy;` goes through the resolve callback |
| E | `<!DOCTYPE html>` and `&nbsp;` | fatal, code 26 |
| F, G, H, H3 | UTF-8 BOM; UTF-16LE BOM; declared ISO-8859-1 with byte 0xE9; undeclared UTF-8 | success; "café" |
| H2 | undeclared, byte 0xE9 | fatal, code 9 at column 7, "caf" delivered |
| I | namespaces off | element "section" with attribute "epub:type", svg with "xmlns" attribute |
| I2 | namespaces on, prefixes on | prefix mappings reported ('' to XHTML, 'epub', '' to SVG), namespace URIs on elements, qualified names |
| J | `<p>one<p>two</p><p>three</p>` | fatal, code 76 at column 48, after delivering nested p elements and "onetwothree" |
| J2 | `<p class=x>a & b</p>` | fatal, code 39 at column 10, nothing delivered |
| J3 | `<p><b>bold</p></b>` | fatal, code 76 at column 15 |
| K | CDATA, comment, PI | CDATA via foundCDATA, comment via foundComment, PI ignored by this delegate, "x" |
| L | `title="a&amp;b&#8212;c"`, `x&#x2014;y&#160;z` | attribute "a&b—c", text "x—y z" |
| M | whitespace between blocks | "\n  " delivered as characters between elements |
| N | U+0001 in text | fatal, code 9 |
| N2 | invalid UTF-8 byte mid-text | fatal, code 9 |
| O | corpus chapter 8 (61,918 bytes) | success, 573 elements, 2,259 events, 54,989 characters, 2.4 to 3.8 ms |
| P | O with `&nbsp;` and `&mdash;` injected after the first `<p>` | success; nbsp delivered as U+00A0 (because the DOCTYPE is present), mdash dropped |
| T | P after pre-expansion | success; both delivered, `&bogus;` became U+FFFD; pre-pass 0.5 to 0.65 ms |
| Q, Q2, Q3 | libxml2 xmlReadMemory with RECOVER on A, B, J | "abcd", "abcd", "onetwothree" (entities dropped, structure recovered) |
| R, R2 | libxml2 htmlReadMemory on A and on the J2-style soup | "a bcd — ©" with entities known; four sibling paragraphs |

### 9.3 Text and layout fixtures

- Pagination: the corpus chapter text concatenated to 200 KB (2,534 paragraphs pool), 17 pt system body font, paragraph spacing 8, container 360 pt wide, pages 640 pt high. Expect 4,998 lines and 190 pages on iOS (174 on macOS); the first page's PNG matches the golden image.
- Hyphenation: the German and English paragraphs in APL-16 at 180 and 260 pt.
- Lists: three decimal items (one wrapping) and one bullet; expect NSTextListElement, marker prefix 3, continuation indent 36 pt.
- Ruby: "漢字とひらがな" with a ruby annotation on the first two characters; expect no height change in TextKit 2 and visible furigana only in the Core Text render.
- Vertical: a Japanese sentence with vertical forms; expect 3 lines from Core Text with descending x origins and 4 horizontal lines from TextKit 2.
- Bidi: the mixed line and the Arabic paragraph of APL-15; expect two selection rectangles across the boundary and right-aligned Arabic once the direction is explicit.
- Attachments: a 40 by 25 inline image and a 300 by 187 block image; expect line heights 25 and 190 and the rendered PNG.
- Fonts: Herculanum.ttf bytes; expect the run font name from data and nil from `UIFont(name:)`.
- Dynamic Type: Georgia 17 at the five categories in APL-18.
- Images: a generated 4000 by 3000 JPEG; expect property read without decode, thumbnail 720 by 540 at 1.5 MB.
- Table: the 2 by 2 table in APL-21; expect sequential paragraphs from TextKit 2 (the reader's grid does the layout).
- HTML importer: the corpus chapter; expect the background call to time out (this is the test that proves APL-12 for a future SDK).

### 9.4 Accessibility fixtures

A synthetic chapter with: two heading levels, paragraphs in English with a French run, a block image with alt text, an image without alt, an ordered list, a link paragraph, a footnote reference, a table with headers, and enough text for three pages. The XCTest asserts the element tree described in 7.4; the device checklist runs against it.

## 10. Things to avoid

- Apple's HTML importer and `loadFromHTML`: main thread, WebKit, slow, CSS lost (measured and documented).
- TextKit 1 for pagination: 10 to 15 times slower than TextKit 2 on the same text, and it lacks the element model. Do not mix TextKit 1 and 2 on the same storage; WWDC22 says touching `layoutManager` switches a text view to TextKit 1 permanently.
- One layout manager per page, or one UITextView per page: slower, and page boundaries break hyphenation and indents.
- Natural alignment without an explicit base writing direction on iOS 18 to 25.
- `NSParagraphStyle.defaultWritingDirection(forLanguage:)` for deciding direction (returned left-to-right for Arabic and Hebrew).
- Adding `glyphOrigin` to the draw point of a line fragment (shifts text by the baseline).
- Trusting local file header sizes or CRCs, or the UTF-8 name flag alone.
- `COMPRESSION_ZLIB` on zlib-wrapped data (the gzip or zlib header makes it fail); conversely, do not expect zlib's `inflate` with positive windowBits to read a ZIP entry.
- `shouldResolveExternalEntities = true` or a policy other than never (network and disk access per chapter).
- Relying on `resolveExternalEntityName` to supply entities (works only with an external DOCTYPE).
- `CTFontManagerRegisterGraphicsFont` (deprecated iOS 18) and any persistent-scope registration; a book's fonts must not leak into the process or the system.
- `UIImage(data:)` for SVG, and private CoreSVG.
- Caching VoiceOver frames in screen coordinates; compute them on every read.
- One element per line for reflowed text (fragments paragraphs; keep it for OCR).
- Posting layoutChanged or screenChanged while VoiceOver read-all is running.
- `usesApplicationAudioSession = false` for book-length speech (ducks instead of stopping music, and bypasses PlaybackController's ownership).
- Pagination of the whole book at open (2.5 GB for a long book); keep three chapters.
- `try!`, force unwraps and `as!` on anything decoded from the book: ZIP fields, XML, CSS values, font data, image data, cached JSON.

## 11. Open questions for the merged spec

1. Which object VoiceOver sends the reading content protocol methods to when the page view has child block elements: the page view, or the focused block. The documentation says "an element that represents readable content"; WWDC26 applied causesPageTurn to the last paragraph element. Experiment: build the APL-28 page both ways in a test app and run read-all on a simulator with the ios-sim-voiceover skill.
2. Whether the Lines rotor crosses a page boundary when the last block's next navigation element is nil, or whether the page's blocks should link to the next page's first block (which would require that page to exist as elements). Experiment with the same app.
3. Whether UITextInput adoption on a UIView page gives braille routing and Speak Screen highlighting on a device.
4. Pages versus continuous for the first version. This study recommends pages for everyone with continuous as a setting; the merged spec decides.
5. The reading position shape and the migration from Readium locators (6.3), and whether `book_positions` gets a `version` column or the JSON carries it.
6. Whether `limitsLayoutForSuspiciousContents` changes any corpus page breaks; run the pagination fixture with it on and off.
7. Whether page breaks differ between iOS 18 and iOS 27 for the same text (the measurement counted 190 pages on both; line-level diffs were not compared). If they differ the cache key's OS version component is doing its job; if not it could be dropped.
8. Hyphenation language: whether TextKit 2 honours `languageIdentifier` for hyphenation on a device whose preferred language differs from the text (the simulator's preferred language was English and German still hyphenated).
9. Tables: the reader's own grid (APL-21) versus a TextKit 1 layout inside an attachment view, decided by how many real tables matter; the corpus has 16 layout tables and no data tables.
10. Now Playing and remote commands during read-aloud: a separate Now Playing session for speech, or none.
11. What happens to read-aloud when PlaybackController activates for music mid-read (an ownership token like the video one, or a notification).
12. The CSS subset boundary (APL-13): whether `font-variant: small-caps` and `vertical-align: super` are worth their code in version one.
13. Whether the continuous-mode UITextView's own line breaks match the paged layout closely enough that a position stored from one mode restores well in the other (offsets make it exact; the visual page differs).
14. Widow and orphan control: on or off by default.
15. Right-to-left page progression (`page-progression-direction="rtl"`): swap swipe and VoiceOver scroll directions, and verify the pageScrolled announcement.

## 12. Clean-room statement

This study was written from Apple's developer documentation, Apple's WWDC session pages, Apple's sample code pages (described, not copied), the iOS 27 SDK headers, Funston's own source files named in section 1, and experiments written for this study in a scratch directory outside the repository. No source code of Readium, foliate-js, epub.js, EPUBKit, FolioReaderKit or any other EPUB reader was opened or consulted, and no third-party write-up of an EPUB reader was read. The only non-Apple pages encountered were search results listing the WWDC sessions, which were not used beyond locating Apple's own pages. The experiment sources are not part of the repository; every number they produced is reported in this document with its setup.

# Study: Readium Swift Toolkit, EPUB navigator (presentation side)

Requirement ID prefix: RDN. Written 2026-10-14 for the clean-room EPUB reader spec. The implementer of that spec will not see the candidate's source; everything needed is in this document's words.

## Provenance

- Repository: https://github.com/readium/swift-toolkit
- Tag studied: 3.11.0, the version Funston links today
- Commit: d82f44f4f05d87add9e22a8b75abbd61dce745dd, committed 2026-07-17T10:23:25+02:00 ("3.11.0 (#862)")
- License: BSD 3-Clause (Copyright 2017, Readium). The bundled Readium CSS stylesheets carry the same license; the Hypothesis text-anchoring code vendored into the page scripts is BSD-2 (Hypothesis). Two accessibility fonts ship with their own licenses (AccessibleDfA, iA Writer Duospace) and OpenDyslexic ships as well; none of this matters to a clean-room renderer because we take no code and no assets.
- What was read: the navigator product in full (EPUB navigator controller, view model, pagination container, reflowable and fixed spread views, spread formation, viewport and location calculators, preferences, settings and editor, the Readium CSS bridge and property mapping, HTML injection, input observing, the directional navigation adapter, editing actions, the decoration API and its HTML templates, the TTS synthesizer, the AVFoundation engine and voice model), the page scripts the navigator injects into each document (reflowable, fixed, gestures, keyboard, selection, decorator, DOM helpers, rectangles, the vendored text anchoring), the three Readium CSS stylesheets and their read-me, the shared publication pieces the navigator depends on (locator model, locator service, positions service, HTML content iterator, publication content iterator, tokenizers, audio session manager, language helpers, metadata parser for reading direction, package document parser for spread hints), the navigator tests and UI test host, the navigator guides and the TTS and accessibility guides, the changelog, and the test app's EPUB reader and TTS view model for conventions. Nothing was built or run.
- Issue tracker: searched with the GitHub CLI on 2026-10-14 for VoiceOver, accessibility, a11y, screen reader, focus, continuous reading, scroll mode, restore location, rotation and font size. The pre-2022 navigator repository (r2-navigator-swift) is no longer searchable; its issues were migrated into swift-toolkit with their numbers (issue 124 is the migrated copy of 206, for example), so the numbers below are swift-toolkit numbers.
- Things named in the brief that are not what they were described as:
  - "Decoration styles: highlight, underline, sidemark." Only highlight and underline exist as built-in styles at 3.11.0. There is no sidemark style; the decoration guide shows a custom "page-list" margin label instead, which is the closest thing.
  - "partialCfi: which is tried first." The locator model exposes a partial CFI accessor, but nothing in the navigator reads it. CFI is never used for navigation. The order that is actually tried is text context, then fragment identifier, then progression (RDN-21).
  - "Advancing to the next resource when VoiceOver reaches the end" exists, but it is a single trait plus one override; there is no observation of VoiceOver focus and no announcement (RDN-40).
  - The HTTP server the roadmap mentions is gone. Resources are served to the web views through a custom URL scheme handler with an in-memory resource cache.

## What it is and why it matters to Funston

Readium's EPUB navigator is a UIKit view controller that renders a publication one spine item at a time, each in its own WKWebView, side by side in a horizontally paging container. Reflowable documents are paginated with CSS multi-column layout and user settings are applied by injecting the Readium CSS stylesheets plus a set of CSS custom properties into every document. The reading position is a Readium Locator derived from the scroll offset of the visible web view and the publication's position list. Text-to-speech is a separate object that walks the publication's text with a sentence tokenizer and speaks it with AVSpeechSynthesizer, synchronised with the navigator only through locators.

Funston uses this navigator today for born-digital EPUBs (Project Gutenberg files from archive.org), with text size driven by Dynamic Type, publisher styles off, leading-edge alignment and a light or dark theme that follows the system. Positions are saved as Locator JSON one second after the navigator reports that the location settled.

It matters for three reasons:

1. It is the behaviour Funston's users already have, so the native renderer must reproduce what works: the preference model, the locator model and its persistence, the navigation semantics, link and footnote handling, selection and highlights, read-aloud.
2. Its weak spot is exactly the part we are replacing. Under VoiceOver it forces continuous scroll because CSS pagination breaks the screen reader, then relies on WebKit's accessibility tree, which groups paragraphs unpredictably in continuous reading (issue 113), never moves VoiceOver focus after a jump (issue 124), and has no spoken feedback for page turns. A native text renderer owns its accessibility elements and can fix every one of these.
3. Its position restoration is percentage based. After a text size change or a rotation the reader lands on the same scroll fraction, not the same text, and the authors say so (issues 645, 344, 55). Camden cares about this more than anything except VoiceOver, and a native renderer with a real text model can anchor to text instead.

Readium renders with WKWebView and we will not. This study records the behaviours and the decisions, not the web mechanics, except where a web mechanic explains a bug we must avoid.

## Architecture in our words

Orientation only. Internal names appear here so a reader of the candidate's docs can map them; the requirements below use EPUB vocabulary.

- EPUBNavigatorViewController is the public view controller. It owns a PaginationView (a horizontal paging UIScrollView whose pages are "spreads"), a state machine for navigation (initializing, loading, idle, jumping, moving), the current location, the position list, the decoration groups, and the delegate. Its configuration carries initial preferences, defaults, editing actions, content insets per size class, the preload window (2 positions before, 6 after), the decoration templates, font family declarations, reading-system CSS properties and a debug flag.
- EPUBNavigatorViewModel holds the publication, the resolved settings, the Readium CSS bridge, the custom-scheme server that feeds the web views, and the VoiceOver observer that re-applies preferences when VoiceOver toggles. When preferences change it decides whether a full reload is needed (reading direction, language, vertical text, scroll, spread, fit, offset-first-page) or whether CSS properties can be pushed live into the loaded documents.
- EPUBSpread describes what one page of the container shows: one spine item (reflowable, or fixed layout without spreads) or two spine items (fixed layout with a left and right page). EPUBSpreadView is the UIView holding a WKWebView for a spread; EPUBReflowableSpreadView adds pagination, progression reporting, go-to logic and content insets; EPUBFixedSpreadView loads a wrapper page with one or two iframes and scales them.
- The page scripts (one bundle for reflowable, one for fixed) run inside every document. They report load, scroll progression, taps and pointer events, key events, selection changes and decoration activation to the native side over the WebKit message bridge, and expose functions the native side calls: scroll to a progression, to an element id, to a text locator, set CSS properties, register and manage decoration groups, find the first visible element.
- ReadiumCSS, CSSUserProperties, CSSRSProperties and CSSLayout translate settings into the stylesheet variant (default, rtl, cjk-horizontal, cjk-vertical), the three stylesheet links, the inline custom properties on the root element, and the dir and lang attributes. HTMLInjection does the string surgery on the served HTML.
- EPUBPreferences (what the app asks for), EPUBDefaults (app fallbacks), EPUBSettings (what is in effect, resolved against the publication metadata) and EPUBPreferencesEditor (ranges, steps, "is this setting effective right now") form the preferences API.
- EPUBViewportAndLocationCalculator and ViewportProgressionCalculator turn the visible progression range of the current spread plus the position list into the reported Locator and a NavigatorViewport (visible resources, position range, total progression range).
- DecorableNavigator, Decoration, HTMLDecorationTemplate, DiffableDecoration: the overlay API. The native side diffs groups by id and sends add/remove/update commands; the page script anchors each decoration to a DOM range and draws absolutely positioned boxes.
- PublicationSpeechSynthesizer walks a ContentIterator (PublicationContentIterator over HTMLResourceContentIterator per resource), tokenises text elements into sentence utterances, and drives a TTSEngine (AVTTSEngine) with its own state machine. AudioSession is a shared manager for the AVAudioSession.
- DirectionalNavigationAdapter is the optional helper that turns edge taps, clicks and arrow keys into page turns through the InputObservable API. EditingActionsController gates the text selection menu.
- Shared services used: DefaultLocatorService (locate a link or a total progression), EPUBPositionsService (1024-byte positions), the metadata parser (page-progression-direction), the package document parser (page-spread properties).

## Requirements

Each requirement is stated for the native renderer. "Readium" sentences describe what the candidate does, verified by reading the code unless marked "docs claim". Where the candidate's behaviour is a weakness, the requirement says what we do instead and why.

### Presentation

**RDN-01 Two presentation modes.** The reader shall offer a paginated mode and a scrolled mode for reflowable spine items, selectable by preference, with the same reading surface, the same locator model and the same navigation commands in both.
- Why: both exist in Readium and in every reading app; VoiceOver users get scrolled mode forced (RDN-06) so the two modes must stay feature-equal.
- Spec: none; EPUB 3.3 leaves presentation to the reading system. The rendition:flow property (EPUB 3.3 section 8.2.4) may hint paginated or scrolled; Readium ignores it and uses its own preference.
- Edge cases: a preference flip between modes is one of the changes that forces a full relayout and a restore of the current location (RDN-19, RDN-27).
- Test: open a book, flip the mode, confirm the same first visible text (RDN-36) and that locators saved in one mode restore in the other.

**RDN-02 How paginated pages are formed.** In paginated mode a spine item shall be laid out into a sequence of fixed-size pages whose size is the reading surface minus the content insets; text flows page to page in reading order, a page is never partially filled before the next begins except at the end of the spine item, and page turns move by exactly one page (or one two-page spread on wide surfaces).
- Readium: the root element gets a CSS multi-column layout of viewport height (100vh), column fill "auto" so each column fills before the next, column gap 0, column width floor 45em on narrow screens and 20em from a 60em-wide viewport (or a phone in landscape), column count 1 on narrow screens and 2 from 60em. The body is centred with a maximum line length of 40rem and a horizontal gutter of 20 px (30 px from 35em wide, 40 px from 45em, 50 px from 75em). When two columns are showing and the document has an odd number of columns, a zero-width trailing column is appended so the last spread does not half-fill; the script re-checks this on every resize.
- Why: this is what readers expect from "pages", and odd-count handling is a real lesson (changelog 2.x: turning pages with an odd number of columns was broken until the virtual column was added).
- Edge cases: a very large single spine item (hundreds of kilobytes) made WebKit's column balancing produce absurd column widths (issue 907, reported and closed in September 2026, after our tag). A native paginator must bound work per page and never lay out the whole item at once to find the page count.
- Test: Gutenberg pg20512-images.epub (Man and Maid) at default text size: every page full except chapter ends; last page of a chapter not blank; two-column on iPad landscape with no empty right column at chapter end.

**RDN-03 Scrolled mode.** In scrolled mode a spine item shall scroll vertically as one continuous surface; the content insets become scroll insets (RDN-05), horizontal page-turn gestures shall by default still move to the previous or next spine item, and the app shall be able to disable that horizontal crossing.
- Readium: scroll mode resets the columns, lets the root grow, keeps the 40rem line length, and enables the container's horizontal paging unless the configuration flag "disable page turns while scrolling" is set (default false). Issue 684 (open) asks for a single vertical surface across all spine items; a pull request (811) is open and the maintainer agrees in principle. Issue 700 confirms that in scroll mode "previous" lands at the end of the previous item (closed as expected). Issue 686 (open): rapid horizontal swipes in scroll mode can stop between two items.
- Why: Funston's VoiceOver users live in this mode (RDN-06). Whether we implement one continuous surface across spine items is an open question (section 11); Readium does not, and its per-item surfaces are what make "next" jump a whole chapter under VoiceOver.
- Test: in scrolled mode, scrolling to the bottom of a chapter and continuing reads into the next chapter with one deliberate gesture; a stray horizontal drag during vertical scrolling does not change chapter.

**RDN-04 Column count policy.** The reader shall choose one column on compact widths and allow two columns only when the reading surface is at least 60em wide at the current root font size (or a phone in landscape), and shall let the user force one or two columns only in that wide case; a forced single column keeps the 40rem line-length cap, a forced double column removes the column width floor.
- Readium: verified in the pagination stylesheet and the column count user module. The user preference is auto, 1 or 2; the editor marks it effective only for reflowable items in paginated mode. Issue 554 asked which width triggers two columns; the answer is this media query.
- Why: predictable, and it avoids three or four columns on large iPads.
- Edge cases: at 175% text size a 20em column floor flips an iPad back to one column; that is intended ("columns are responsive even if column width is set in pixels" is the authors' stated design).
- Test: iPad landscape default size shows two columns; iPad with text at 200% shows one.

**RDN-05 Content insets.** Reflowable pages shall keep a vertical margin that includes the window safe area: 34 pt top and bottom in a compact vertical size class and 62 pt in a regular one (Readium's defaults, merged with the window safe area by taking the larger of the two per edge). In paginated mode the page box itself shrinks by these insets so no text is drawn under the chrome; in scrolled mode they are scroll insets so content scrolls under the chrome. The app may supply its own insets; they must be stable across status bar changes.
- Readium: verified. The navigator reads the window's safe area, not the view's, so only the notch and status bar count, not the app's bars. Changelog 3.7 and 3.8: insets now include the safe area; a delegate hook exists because status bar toggling otherwise shifts content (issue 373: Larger Text display zoom pushed text when the bar appeared, closed 2026-07-17). Issue 112 (closed 2026-09-18, after our tag): swiping in the inset strip below the page turned chapters instead of pages because the strip belonged to the outer container, not the page.
- Why: the inset strip must belong to the page for gestures, and must be stable so hiding the chrome never scrolls the text.
- Test: toggle chrome with the magic tap; the first visible line does not move.

**RDN-06 Scrolled mode under VoiceOver.** When VoiceOver is running the reader shall present reflowable items in scrolled mode regardless of the stored preference, shall switch live when VoiceOver starts or stops, and shall keep the user's paginated preference untouched for when VoiceOver is off. (See section 7 for why we may relax this in the native renderer.)
- Readium: verified in two places. Settings resolution overrides scroll to true whenever VoiceOver is on; the view model observes VoiceOver status changes (ignoring duplicate notifications) and re-applies preferences, which flips the scroll setting and therefore reloads every spread at the current location (RDN-27). Each spread view also observes the change and re-applies its paging flag. The stated reason in code: pagination breaks the screen reader. Issue 207 (2018) was closed by this forcing in 2019 with the note that focus then follows the voice except inside a paragraph taller than the screen, where WebKit scrolls only at the next paragraph. Issue 257 (toggling VoiceOver froze the app on iOS 16, 2022) was closed on 2026-07-17 without a linked fix.
- Also forced: vertical text (CJK vertical writing) always uses scrolled mode because CSS columns do not support it (changelog 2.6, discussion 370).
- Why: Readium needs this because WebKit pagination and VoiceOver do not mix. A native renderer that exposes each paragraph as an element with a real frame does not need scrolled mode for VoiceOver to work; it still needs the "VoiceOver reached the end of the page" hook (RDN-40). Decide in the merged spec.
- Test: with VoiceOver on and paginated preference stored, open a book: continuous reading proceeds through the whole chapter without a page gesture; turn VoiceOver off: pages return and the position is the same text.

**RDN-07 Reading direction resolution.** The reading direction (left-to-right or right-to-left progression across pages and spine items) shall be resolved in this order: an explicit user preference; the direction implied by a user language preference; the package document's page-progression-direction; the direction implied by the publication's first language; the app default; the direction implied by the app default language; else left-to-right.
- Readium: verified in settings resolution and covered by its tests (RTL preference beats LTR metadata, LTR metadata beats RTL default, language metadata beats default direction, and so on). "Implied by language" means Arabic, Farsi, Hebrew, zh-Hant and zh-TW are right-to-left; everything else left-to-right. Vertical text is implied when the resolved language is CJK (ja, ko, any zh) and the resolved direction is right-to-left; the user can force it either way.
- Spec: EPUB 3.3 section 6.3.3, spine page-progression-direction (ltr, rtl, default). Readium maps "default" and anything else to auto and then falls through to language, which is a sensible real-world deviation.
- Edge cases: in fixed layout, spread pairing uses the publication's own direction, not the user override, or the page-spread hints come out backwards (RDN-66).
- Test: a Hebrew Gutenberg EPUB with no page-progression-direction opens right-to-left; a user preference of left-to-right overrides it.

**RDN-08 Layout variant from language.** The reader shall pick one of four typographic variants from the resolved language and direction: default (left-to-right), right-to-left, CJK horizontal, CJK vertical; shall set the document direction to match (never for CJK vertical); and shall inject the resolved language onto the document when the document declares none (copying a body-level language to the root if the body has one).
- Readium: verified. Any dir attribute already on html or body is stripped and replaced; lang is injected on html and body only if html has no lang or xml:lang. The Readium CSS read-me documents which user settings each variant disables (RDN-17).
- Spec: EPUB 3.3 section 6.1.1 (xml:lang on content documents), HTML dir attribute. Stripping an author's dir attribute is a deviation; the authors do it because the stylesheet variant must agree with the direction. Keep it, but only when the publication-level direction is known.
- Test: Readium's own tests cover: lang injected on both elements when absent; copied from body to html when only body has it; not injected when html has it; dir replaced when already present.

**RDN-09 Page turn direction, left and right.** "Forward" shall mean the next page in reading progression and "backward" the previous; "left" and "right" shall be mapped through the direction (left is backward in left-to-right books and forward in right-to-left books). In right-to-left books the sequence of spine items in the container shall run right to left too.
- Readium: verified in the navigator and in the container, which reverses page offsets for right-to-left. Issue 70 (closed, 2.x) fixed restoring position in RTL books.
- Test: an RTL book: swipe right-to-left goes backward; the first spine item sits at the right end.

### Preferences to presentation

**RDN-10 Settings resolution and defaults.** Preferences shall be optional values; the reader shall resolve each against the publication metadata and app defaults into an effective setting, and shall expose which settings are effective (and why not) so a settings screen can grey them out. Effective defaults, verified in the settings code and the editor:

| Setting | Default | Range or values | Step | Effective when |
| --- | --- | --- | --- | --- |
| fontSize (scale) | 1.0 | 0.1 to 5.0 | 0.1 | reflowable |
| fontWeight (scale of 400) | 1.0 | 0.0 to 2.5 | 0.25 | reflowable, set |
| fontFamily | publisher's | any family name | | reflowable |
| publisherStyles | true | | | reflowable |
| textAlign | publisher's | start, left, right, justify | | reflowable, publisher styles off, default or RTL variant, set |
| lineHeight | 1.2 (editor), publisher's otherwise | 1.0 to 2.0 | 0.1 | reflowable, publisher styles off, set |
| paragraphSpacing (rem) | 0.0 | 0.0 to 2.0 | 0.1 | reflowable, publisher styles off, set |
| paragraphIndent (rem) | 0.0 | 0.0 to 3.0 | 0.2 | reflowable, publisher styles off, default or RTL variant, set |
| wordSpacing (rem) | 0.0 | 0.0 to 1.0 | 0.1 | reflowable, publisher styles off, default variant, set |
| letterSpacing (rem, halved on output) | 0.0 | 0.0 to 1.0 | 0.1 | reflowable, publisher styles off, default variant, set |
| hyphens | follows justify | | | reflowable, publisher styles off, default variant |
| ligatures | false | | | reflowable, publisher styles off, RTL variant |
| typeScale | 1.2 | 1.0 to 2.0 | steps 1.0, 1.067, 1.125, 1.2, 1.25, 1.333, 1.414, 1.5, 1.618 | reflowable, publisher styles off, set |
| pageMargins (factor) | 1.0 | 0.0 to 4.0 | 0.3 | reflowable |
| columnCount | auto | auto, 1, 2 | | reflowable, paginated |
| scroll | false | | | reflowable, not vertical text |
| theme | light | light, dark, sepia | | reflowable |
| textColor, backgroundColor | theme's | packed RGB | | reflowable, set |
| imageFilter | none | none, darken, invert | | theme dark |
| textNormalization | false | | | reflowable |
| language | metadata's | | | always |
| readingProgression | resolved (RDN-07) | ltr, rtl | | always |
| verticalText | derived (RDN-07) | | | reflowable |
| spread | auto | auto, never, always (preference accepts only never, always or unset) | | fixed layout |
| fit | auto | auto, page, width | | fixed layout |
| offsetFirstPage | metadata's | | | fixed layout, spread not never |

Negative numbers are clamped to zero on input; font weight is clamped to 0 to 2.5.
- Why: Funston submits four of these (fontSize from Dynamic Type, publisherStyles false, textAlign start, theme) plus scroll from its own layout setting, and the merged spec needs the full table to know what the preference screen may someday offer.
- Test: unit tests of the resolver with the precedence cases Readium tests (listed under RDN-07) plus one per clamp.

**RDN-11 Font size.** The font size preference shall be a scale factor applied to the document's root font size (1.0 = the book's own 100%), so that every em- and rem-based measure in the book scales with it; it shall not be a point size. Funston maps Dynamic Type's body size divided by 17 pt to this scale.
- Readium: the scale becomes a percentage on the root element with highest priority. When publisher styles are off, body copy (p, li, div, pre, dd) is pinned to 1rem, so the scale is the body size exactly; when they are on, the publisher's own body size (often 0.9em or 1.1em) multiplies it. Readium notes that very large sizes "could break the pagination" (editor doc comment).
- Why: a scale keeps publisher-designed proportions; Dynamic Type gives the base.
- Edge cases: at scale 5.0 a single word may exceed a column; the native layout must wrap mid-word or clip rather than overflow silently (section 8).
- Test: body text at Dynamic Type default measures 17 pt; at the largest accessibility size it measures the scaled value; headings scale with it.

**RDN-12 Publisher styles off.** When publisher styles are off the reader shall normalise type sizes: body copy to the base size; headings to a type scale (h1 = scale cubed, h2 = scale squared, h3 = scale, h4 to h6 = base; scale default 1.2); small as "smaller"; sub and sup at 67.5%; and shall only then honour the typography settings marked "publisher styles off" in RDN-10. Everything else the publisher declared (fonts, colours, margins, indents, alignment) shall stay unless its own setting overrides it.
- Readium: verified in the "advanced settings" flag and the font-size normalise module. Note the asymmetry: turning publisher styles off changes sizes immediately even if no other setting is touched. Funston runs with publisher styles off always, so its users see normalised sizes and leading-edge alignment in every book.
- Why: accessibility settings are meaningless if the publisher's fixed sizes win; the authors' name for the flag ("advanced settings") reflects that these overrides are a package.
- Test: a book whose stylesheet sets p { font-size: 0.8em }: with publisher styles on, body text is 80% of base; off, it is 100%.

**RDN-13 Text alignment.** The alignment setting shall apply to body copy (the body, paragraphs not inside blockquote or figcaption, and list items), forcing the last line of a justified paragraph to align naturally; "start" shall resolve to the document direction; "justify" shall turn on automatic hyphenation of the body and "left" or "right" shall turn it off, unless the hyphens setting says otherwise; in right-to-left documents a request for "left" shall become right.
- Readium: verified. Headings, captions and quotations keep the publisher's alignment on purpose. Hyphenation is capped at three consecutive hyphenated lines and disabled in headings, captions, code and addresses by the base stylesheet.
- Why: Camden's reason for start alignment is on record in Funston: justified lines open uneven gaps that are harder to track with low vision. A native renderer should offer the same four values and the same scope.
- Spec: none; CSS text-align semantics.
- Test: a justified publisher paragraph renders ragged with "start"; a blockquote inside it keeps the publisher's alignment.

**RDN-14 Themes and colours.** The reader shall offer light, dark and sepia themes with these colours (verified in the theme code and stylesheets): light text #121212 on #FFFFFF; dark text #FEFEFE on #000000 with links #63caff and visited #0099E5; sepia text #121212 on #faf4e8 with default link colours (#0000EE, visited #551A8B). In dark and sepia every element except links shall inherit the theme text colour and lose its background; in dark, borders shall use the text colour and SVG text shall be filled with it. A custom text or background colour shall behave like a theme (all non-heading, non-preformatted elements inherit the text colour; all backgrounds cleared). Selection colour #b4d8fe.
- Readium: verified. Funston passes dark or light from the system style; the navigator's own view background is set to the effective background colour so the page edges match.
- Why: dark mode in EPUBs fails exactly when a publisher's inline colours survive; the forced inheritance is the lesson.
- Edge cases: publisher-coloured text (for example red stage directions) is lost in dark and sepia; that is the accepted trade.
- Test: a book with inline style color on a span renders in #FEFEFE in dark; links remain blue.

**RDN-15 Font family.** A user font family shall replace the publisher's on body copy (body, p, li, div, dt, dd) and on phrasing elements (i, em, cite, b, strong, span) that carry no language attribute, leaving elements in another language on the publisher's font; headings and code shall keep the publisher's font unless text normalisation is on. The reader shall ship accessibility fonts (Readium: AccessibleDfA, iA Writer Duospace, OpenDyslexic in regular, italic, bold, bold italic) and allow the app to register further font files with weights and styles; registered fonts shall be preloadable.
- Readium: verified. A font override flag gates the change; AccessibleDfA and iA Writer get fixed fallback stacks and a line-height compensation of 1.167; text normalisation additionally forces normal weight and style, removes text decoration and small caps, and puts sub and sup on the baseline at 1rem. Changelog 3.10.1: app-declared fonts never loaded until a CORS issue was fixed; irrelevant to us but a reminder that embedded fonts must be tested with a real font file.
- Spec: EPUB 3.3 section 6.4 (embedded fonts via @font-face) for the publisher side.
- Test: a Gutenberg book with an embedded serif: with no override the embedded font shows; with OpenDyslexic selected, body text changes and a Greek span with lang="el" keeps the embedded font.

**RDN-16 Leading, paragraph spacing, indent, word and letter spacing.** Line height shall be a unitless multiplier applied to the root and inherited by body copy; paragraph spacing shall set paragraph top and bottom margins in rem; paragraph indent shall set paragraph text indent in rem and zero it on inline-block descendants; word spacing shall apply to headings, paragraphs, list items and divs in rem; letter spacing likewise, with the stored value halved on output (a stored 0.5 becomes 0.25rem) and font-variant turned off.
- Readium: verified in the user modules and the bridge. The default line height when nothing is set comes from a formula on the font's x-height and zero width: (1em + (2ex - 1ch) - ((1rem - 16px) × 0.1667)) × compensation, with 1.6 as a fallback; headings use "normal".
- Why: these are the settings a low-vision reader actually uses; the units matter because they must scale with font size.
- Test: paragraph spacing 1.0 at 17 pt body = 17 pt gap; letter spacing 1.0 = 0.5rem.

**RDN-17 Settings disabled by variant.** The reader shall disable word spacing, letter spacing and hyphenation in the right-to-left variant and add Arabic ligatures; shall disable text alignment, hyphenation, paragraph indent, word spacing and letter spacing in the CJK variants; and shall also disable column count in the vertical CJK variant.
- Readium: docs claim (the Readium CSS read-me) matching the editor's effectiveness rules, verified.
- Why: these settings damage those scripts.
- Test: with language "ja", the editor reports text alignment as not effective.

**RDN-18 Page margins.** The page margins preference shall be a factor applied to the horizontal gutter (Readium: body padding = gutter × factor), default 1.0, range 0.0 to 4.0.
- Test: factor 0 brings text to the surface edge; factor 2 doubles the gutter.

**RDN-19 Which preference changes relayout.** Changing reading direction, language, vertical text, scroll mode, spread policy, fit or offset-first-page shall relayout from scratch and restore the current location (RDN-27). Every other setting (size, weight, family, theme, colours, alignment, spacing, margins, columns, filters, normalisation) shall be applied live to the loaded content without a reload.
- Readium: verified. Live changes are pushed as CSS custom properties with highest priority into every loaded document; the server's cached HTML is evicted so later-loaded documents get the new values inline for their first layout (changelog 3.9.1: previously loaded resources reverted to old preferences after rotation until this was fixed). Theme is a live change, which is why issue 839's app-side bug (restoring position on a theme change) was unnecessary.
- What happens to the position after a live change: nothing is restored. The web view keeps its pixel scroll offset, the script snaps to the nearest page boundary, and the new progression is reported. Issue 645 (open) reports exactly this: change size on page 5, turn two pages, change back, land on a different page; the maintainer calls it "percent-based positioning, a common issue" and suggests text snippets. Issue 55 (2022) was the same report. RDN-36 is our requirement.
- Test: change text size; the first visible paragraph before the change is the first visible paragraph after.

**RDN-20 Type scale.** With publisher styles off the heading scale shall default to 1.2 and accept the steps in RDN-10; Readium's default stylesheet for unstyled books uses 1.125 and the user override replaces it.

### Reading progression and spreads

See RDN-07 and RDN-09 for direction; RDN-66 for fixed-layout spreads. For reflowable books Readium never pairs two spine items; "two pages" on an iPad means two columns of one spine item (RDN-04).

### Navigation semantics

**RDN-21 Go to a locator.** Given a locator, the reader shall: normalise its href (strip a legacy leading slash; for a remote publication relativise against the base); find the spine item by href (an exact match on the normalised URL first, then a match with the query and fragment removed); reject the request if the item is not in the reading order; move the container to that item; then, inside the item, resolve the target in this order and stop at the first that succeeds:
1. If the locator has text context (a highlight string), find that text in the document, within the element named by the locator's cssSelector if present and found, else within the whole body, using exact match first and approximate match with prefix and suffix scoring second (RDN-52); scroll to the match.
2. Else if the locator has at least one non-empty fragment, find the element with that id (the first fragment only) and scroll to it.
3. Else scroll to the locator's progression (0.0 to 1.0 of the item's scroll extent), defaulting to 0.
- Readium: verified. Three deviations from what a reader would expect, all worth fixing in ours:
  - If step 1 or 2 fails (text not found, id missing), Readium does not fall through to progression. The request completes "successfully" without moving, so a fresh load lands at the start of the item. Ours shall fall through: text, then fragment, then cssSelector alone, then progression.
  - A locator with only a cssSelector and no text is not resolved by navigation at all (the selector is only used to scope a text search and by decorations). Ours shall treat cssSelector as a target in its own right, after fragments.
  - The partial CFI location is never read. We will not implement CFI navigation in version one either, but the data model must round-trip it (section 6).
- Spec: EPUB 3.3 section 6.2 (fragment identifiers in content documents); Readium Locator model (readium.org/architecture/models/locators); HTML locator extensions (cssSelector, partialCfi, domRange).
- Edge cases: a fragment that names a tiny inline element (a footnote superscript) must put the page containing the element's start on screen, not the page where the largest visible part lands (issue 133, fixed 2021). A locator whose href names a non-linear item not in the reading order is rejected; Readium's answer (changelog 2.5) is to open a second navigator with a custom reading order of just that item.
- Test: three locators for the same paragraph (text only, fragment only, progression only) all land with that paragraph's first line visible; a locator with a wrong fragment but a valid progression lands at the progression.

**RDN-22 Go to a link.** A link (table of contents entry, landmark, page list entry) shall become a locator with the link's fragment as its single fragment and no progression, or with progression 0 and no fragment when the link has none; the title shall come from the spine item's own title if any, else the link's.
- Readium: verified in the locator service. The resulting navigation therefore uses rule 2 or 3 of RDN-21.
- Spec: EPUB 3.3 section 7.3 (navigation document) for the links' origin.
- Test: Funston's contents sheet entry for a chapter with href chapter.xhtml#ch2 scrolls to the element with id ch2.

**RDN-23 Target placement.** In scrolled mode the target's top edge shall be placed at the top of the visible area (the 3.11 page script does this; issue 328 reported centred placement, which made an endnote ambiguous among its neighbours, and was closed in 2023). In paginated mode the page containing the target's start shall be shown, snapped to a page boundary; a page shall never be left half-turned (issue 541: iPad split view resize left two half pages until a resize handler re-snapped; issue 686 open: fast swipes can stop between items).
- Why: a predictable landing lets the reader (and VoiceOver, RDN-41) find the target.
- Test: follow a footnote link in scrolled mode: the note's first line is the first visible line.

**RDN-24 Forward and backward.** Forward shall move one page within the current spine item in paginated mode; at the item's last page it shall move to the next item's first page. Backward shall mirror this and enter the previous item at its last page. In scrolled mode Readium's forward and backward do not scroll by a screen; they jump to the next item's start or the previous item's end, because the page view reports that it cannot move. Ours shall scroll by one visible height in scrolled mode and cross items only at the ends. Both shall return false (and move nothing) at the first page of the first item and the last page of the last item.
- Readium: verified. The in-item move is a relative scroll by one viewport width, rejected when the target offset would leave the content range; cross-item moves go through the container with a slide animation when adjacent (0.3 s, or a 0.1 s pause when not animated, with a snapshot of the outgoing page to hide WebKit flicker, issue 737) and a fade (0.15 s out, 0.15 s in) when further away. Animations are skipped under Reduce Motion.
- Why for the scrolled-mode change: Funston's "Reading page" adjustable element calls forward and backward on increment and decrement. Under VoiceOver (scrolled mode forced) that currently jumps a chapter per swipe, which is not what "adjust" means to a VoiceOver user.
- Test: in scrolled mode, increment advances one screen; at the chapter end it enters the next chapter at the top; at the book end it does nothing and the element's value does not change.

**RDN-25 One navigation at a time.** The reader shall serialise navigation: a jump or page turn requested while another is in flight shall be either rejected with a false result (Readium) or queued; it shall never interleave. While loading or moving, user interaction with the page shall be disabled. Readium rejects; ours shall queue the latest request (last wins) because Funston's contents sheet and VoiceOver actions fire while loads are still settling and a silently dropped jump looks like a bug.
- Readium: verified in the state machine (initializing, loading, idle, jumping, moving). A spread relayout (load) is always allowed and cancels anything in flight; everything else needs idle. Note that "loading" ends as soon as the relayout is scheduled, not when the web view finishes, so most jumps are accepted and then deferred by the spread view until its document loads (last pending location wins).
- Test: tap a contents entry twice quickly; the second target is where the reader ends up.

**RDN-26 Resource preloading and release.** The reader shall load the current spine item first, then following items until at least six positions (RDN-33) are covered, then preceding items until at least two positions are covered; items outside that window shall be unloaded and their renderers released. Preloaded following items shall be positioned at their start and preceding items at their end so that an immediate page turn is instant. When the publication has no positions, only the current item shall be loaded.
- Readium: verified; the counts come from the navigator configuration defaults (2 before, 6 after) and are counts of positions, not items. With 1024-byte positions (RDN-33) a chapter of 30 KB counts 30, so in practice one item each side is loaded. Loading order within the queue: current, next ones, then previous ones. A web view is destroyed when its index leaves the window and recreated when it returns; message handlers are detached on removal to break reference cycles (the UI tests check deallocation and a rapid random-jump stress test for cancellation races).
- Why: WKWebViews are heavy; a native renderer can afford a wider window but must still bound memory on 16 GB hosts and 4 GB phones.
- Test: a memory test that opens, jumps to 20 random positions and closes without growth.

**RDN-27 Relayout and restore.** On rotation, size class change, VoiceOver toggle or any preference in RDN-19's first group, the reader shall relayout every loaded item and restore the current location. Readium restores by progression within the item (percentage of scroll extent), which drifts backwards a little on every relayout; the authors acknowledge this (issue 344: "we restore the web view progression instead of an exact location"). Ours shall restore by anchor (RDN-36) and fall back to progression.
- Readium's sequence, verified: capture the current locator (which during a pending load is the pending locator, not a computed one); rebuild the spread list; reload the container at the item index with the locator; each spread view waits for its document's load event plus one animation frame, then 0.2 s more "for pagination to settle", then applies the target, then waits a further 0.3 s before revealing the page if the target is not the item's start (an explicit fudge for slow rendering). Rotation also triggers relayout for reflowable books because the "spread auto" flag flips between portrait and landscape even though reflowable items never pair; and rotating twice quickly used to lose the position entirely (issue 344, fixed in PR 347; in the 3.11 code the current location returns the pending locator while a load is in flight, which is what protects the capture).
- While the app is inactive, relayout is deferred until it becomes active again because a background reload resets the web view to the start (issue 309, closed; changelog 3.7.3 fixed the same loss after WebKit's process was killed in the background). On web process termination the spreads reload at the current location.
- Test: rotate four times; the first visible paragraph is unchanged each time.

**RDN-28 Locations while inactive.** The reader shall not adopt a current location computed while the app is inactive (issue 841, open, proposed by the author of issue 839 after finding that app-switcher snapshot passes and backgrounded relayouts produce transient positions that get saved). Pending updates shall be deferred and recomputed once active.
- Test: background the app during a chapter; a memory warning while backgrounded; foreground: the saved locator still points at the text that was on screen.

**RDN-29 Jumps versus turns.** The reader shall tell the app when it jumped (go to locator or link, internal link tap) as distinct from a page turn, so the app can keep a navigation history; Readium calls this "did jump to" only when the jump succeeded.

### Current location

**RDN-30 What the reported locator contains.** The current location shall carry: the spine item href and media type; the title of the table-of-contents entry for that item if any; progression (the fraction of the item's scroll extent at the top or leading edge of the visible area, 0.0 to 1.0); totalProgression (interpolated within the item's share of the whole book, RDN-32); position (the 1-based position number whose slice the visible area has entered, RDN-33). Readium's reported locator carries no text context and no cssSelector; ours shall add a cssSelector and a short text context for the first visible block so that RDN-36 can anchor (Readium only computes those on demand, RDN-34).
- Readium: verified in the location calculator. The title map is built from the navigation document (all levels), keyed by the entry's href including fragment, and looked up by the item's href without fragment, so only entries that point at a whole item produce a title; sub-section entries give none (issue 799 asked for the current child chapter and was closed).
- Position rule: position index = ceil(progression × (count - 1)) so the position advances as soon as the reader enters it; the last position of an item is only reported when progression is exactly 1.0 (tests confirm "ceil(0.9999 × 3) - 1 = 2").
- Test: at the top of chapter 3 of a book whose chapter 3 has 40 positions starting at 120: position 120, progression 0, totalProgression = 119 / total.

**RDN-31 When the location fires.** Location updates shall be driven by the content's own scroll and layout events (not polled), coalesced to at most one per animation frame, settled for 0.3 s after the last change before being reported, deferred while a navigation is in flight (Readium polls every 0.1 s for idle), fired once after the initial restore, and suppressed when equal to the last reported locator.
- Readium: verified. Equality is on the full locator, so almost every scroll produces a report. Funston then waits a further 1 s before writing. Two lessons: the first report after opening can carry progression 0 if it is computed before the document's first scroll event arrives (issue 135 observed exactly this ordering in 2.x and the 3.11 code still allows it), so a saver must debounce or ignore a leading progression-0 report that is immediately followed by the restored one; and reports computed while inactive must be dropped (RDN-28).
- Test: scroll continuously for 5 s: at most one report every 0.3 s after motion stops; open a book at a saved position and kill the app 2 s later: the saved position is unchanged.

**RDN-32 Viewport report.** The reader shall also expose the visible range: the visible items with each item's visible progression range, the visible position range, and the total-progression range (lower bound = top of the visible area, upper = bottom), computed by linear interpolation of each item's progression within its window [first position's totalProgression, next item's first position's totalProgression or 1.0].
- Readium: verified, with tests for start (0.0), item boundary (0.5 for the first of two equal items), end (1.0), and two-item fixed-layout spreads spanning both windows.

**RDN-33 Positions.** Positions shall be computed per spine item as ceil(archive entry length in bytes / 1024), at least 1, numbered 1-based across the book; a fixed-layout item is one position; each position's progression within its item is (index - 1) / count and its totalProgression is (number - 1) / total count. Without a container (a streamed manifest) there are no positions and the reported locator falls back to the item's start with the actual progression.
- Readium: verified in the positions service; the authors cite the Adobe RMSDK convention. Entry length is the stored or compressed length as the archive reports it, so compressed and uncompressed books of the same text have different counts; that is accepted.
- Spec: none (Readium positions best practice, readium.org/architecture/models/locators/positions).
- Why: positions are what the "page x of y" display and the preload window use. They are stable across font sizes, which is their whole point.
- Test: a 3-item book with entries of 2048, 100 and 5000 bytes has positions 2, 1 and 5; item 2's single position has totalProgression 2/8.

**RDN-34 First visible element.** The reader shall be able to return a locator for the first block element visible on screen, even if it starts on a previous page: its cssSelector plus its full text as the highlight. Readium computes this on demand by walking visible block-level children depth-first and ignoring non-block or zero-opacity elements (changelog 2.6: "returns the first block element that is visible on the screen, even if it starts on previous pages", used so TTS does not skip context). Issue 242 (closed) reported it missing the first element; issue 839's author documents the "floor to element start" bias: restoring to such a locator lands on the page where the element begins, one page back when the visible page starts mid-element.
- Why: this is the hook TTS start and position anchoring use.
- Test: with a paragraph spanning pages 4 and 5 and page 5 visible, the locator names that paragraph.

### Restoring a location

**RDN-35 Initial location.** When opened with a saved locator the reader shall report that same locator as the current location until the layout settles, shall load the item it names first, resolve the target by RDN-21 once the item is laid out, and only then reveal the page; if the href is not in the reading order it shall open at the beginning and tell the app.
- Readium: verified; the current location property is seeded with the initial locator, and the restore sequence is the one in RDN-27 with its 0.2 s and 0.3 s waits. The locator's progression is used, since saved locators have no text (RDN-30). A saved locator that carried a fragment would resolve by fragment instead and land at the section start rather than where the user scrolled to; Readium's reported locator (what Funston saves) never carries fragments, so this cannot happen today, and ours must likewise strip navigation-only fragments before saving.
- Test: open at a saved mid-chapter position: the first visible line matches the one saved; the first location report equals the saved locator.

**RDN-36 Restore after text size change, rotation and mode change (anchor restore).** Before any relayout the reader shall capture the first visible block (RDN-34) with its text context and after the relayout shall scroll so that block's first line is the first visible line (scrolled mode) or shows the page containing that line (paginated mode), falling back to progression when the block cannot be found. Readium does not do this (RDN-19, RDN-27), the maintainer says it should (issue 645), and the capture/restore idiom apps use today lands one page early when the page began mid-element (issue 839). The anchor shall therefore be the first visible line's position within the block, not the block's start.
- Why: this is the behaviour Camden cares about most after VoiceOver.
- Test: on page 5 change size to 200% and back; land on page 5 with the same first line; repeat with rotation and with the scrolled/paginated flip.

**RDN-37 Saved locator shape and compatibility.** The persisted position shall remain Readium Locator JSON: href (relative URL inside the package, no leading slash), type (media type, required), optional title, locations {fragments?, progression?, totalProgression?, position?, cssSelector?, partialCfi?, domRange?, other keys preserved}, text {before?, highlight?, after?}. Readers of old rows shall accept a legacy "fragment" string, a leading slash on href, and percent-encoding differences (Readium 3's migration helpers exist for this; Funston's rows were written by 3.x and need no migration).
- Spec: readium.org/architecture/models/locators; section 6 below.
- Test: every locator Funston has saved to date parses and restores.

### VoiceOver and accessibility

**RDN-38 Accessibility elements for text.** The native renderer shall expose text through its own accessibility elements, in reading order, with frames tethered to real glyph bounds, following the house style of the PDF reader (one element per recognised line there; for EPUB, one element per block element such as a paragraph, heading, list item, table cell or figure caption, with headings carrying the header trait and level). WebKit's tree is what Readium gets for free and it is the source of issues 113, 124 and 207; a native tree is the reason this project exists.
- Why: see section 7.
- Test: under VoiceOver, swipe right through a chapter: every paragraph is one element, in order, with no empty stops.

**RDN-39 Scrolled mode under VoiceOver** is RDN-06; what it implies for page-turn commands is in RDN-24.

**RDN-40 Reaching the end of the visible content.** The reader's surface shall declare that it causes a page turn so that VoiceOver asks it to scroll when continuous reading or a three-finger scroll reaches the end, and shall answer next or down with forward, previous or up with backward, and left or right through the direction mapping (RDN-09). Unlike Readium it shall return false when there was nothing to move to, and it shall post a page-scrolled announcement naming the new page or chapter after a successful move.
- Readium: verified; the trait is set on the navigator's root view, the override always returns true, moves are non-animated, and nothing is announced. Changelog 2.6.1 (PR 349, merged 2023-10-31): "automatically moves to the next resource when VoiceOver reaches the end of the current one". Issue 165 (open) records why: the web view does not tell VoiceOver it reached the end, so the test app once used dummy previous/next buttons at the bottom that VoiceOver would focus to trigger a chapter change, and a screen reader user reported their touch targets as unusable. Funston's PDF reader already announces "Page n of m" on accessibility scroll; match it.
- Test: with VoiceOver continuous reading from a chapter's last paragraph, reading continues into the next chapter with an announcement; at the book's end VoiceOver plays its boundary sound rather than silence.

**RDN-41 Focus after navigation.** After a jump (contents, link, footnote, search result, restore) the reader shall move VoiceOver focus to the first element of the target and announce the screen or layout change; Readium never does (issue 124, open since 2018 under its original number 206: "the VoiceOver focus stays at the previous place until the user taps the screen"; issue 181, closed in 2025 as the app's responsibility). Funston's reader posts a screen-changed notification once when the book opens, which is the right pattern to extend.
- Test: activate a contents entry under VoiceOver: the next swipe reads the first line of that chapter.

**RDN-42 Paragraph granularity in continuous reading.** Each block shall be its own element so that VoiceOver's continuous reading and "next item" swipe stop at the next block. Issue 113 (open since 2021): in WKWebView, continuous reading groups visually adjacent paragraphs into one block, so "next item" jumps to the end of the chapter; the reporter's workaround is forcing at least 1em paragraph spacing so WebKit splits the blocks, which Readium exposes as the paragraph spacing setting but never applies automatically. Funston runs with publisher styles off and paragraph spacing unset, so the workaround is not in effect today.
- Test: Moby Dick (Gutenberg 2701) under continuous reading, pause, swipe right: the next paragraph, not the chapter end.

**RDN-43 Highlights and decorations must be accessible.** User highlights, search hits and the spoken-utterance marker shall be exposed to VoiceOver (as a trait or value on the text element they cover, plus a custom action to open them), not as separate elements and not invisibly. Readium's decorations are absolutely positioned overlay boxes with pointer events off; they are invisible to the accessibility tree and not activatable by a screen reader (kotlin-toolkit issue 352, open, same design; the maintainer proposes inline marker spans as a compromise).
- Test: under VoiceOver a highlighted sentence reads with a "highlighted" value and offers "Remove highlight".

**RDN-44 System speech features.** Speak Selection, Speak Screen and the accessibility editing actions shall work on the selection; Readium had to whitelist every selector prefixed with the accessibility prefix because its menu gating disabled them (issue 502, fixed in PR 505, 2024-11-15).
- Test: with Speak Selection on, select a sentence and tap Speak: it is spoken.

**RDN-45 Reduce Motion.** Page turn and fade animations shall be disabled under Reduce Motion; Readium does this in the container (verified) and Funston already follows it for chrome.

**RDN-46 Zoom.** Readium disables pinch zoom in reflowable documents (user-scalable=no, maximum-scale=1) and removes the double-tap-to-zoom gesture; the native renderer shall likewise not pinch-zoom reflowable text (size comes from Dynamic Type and the size setting) but must not interfere with system Zoom.

**RDN-47 Images under VoiceOver.** Each image shall be an element whose label is, in order: alt text; title; an SVG title then desc; a surrounding figure's caption; else "image" (Readium's image tap API uses this order, verified in the gesture script; its content iterator only reads alt). An image with alt="" is decorative and shall be hidden. Fixed-layout bitmap pages shall carry the resource title as alt.

### Selection and decorations

**RDN-48 Selection as a locator.** The current selection shall be exposed as a locator carrying the selected text as highlight with up to 200 characters of context before and after taken from the document's text content and trimmed at word boundaries, plus the selection's frame in the reader's coordinates; it shall be reported after a short settle (Readium debounces 50 ms), cleared when the user starts scrolling, and clearable by the app. Ours shall additionally carry the selection's own cssSelector and progression; Readium's selection locator copies the page's current location (so its progression and position are the page's, not the selection's) and carries no selector.
- Readium: verified. Issue 363 (closed): WebKit's text content lacks the newlines between block elements, so "before" context can run a heading into the next paragraph ("Chapter OneMY FATHER..."); issue 362 (open): a drop-cap in its own span shifted decoration and context offsets by one character. A native text model with explicit block boundaries avoids both.
- Spec: Readium Locator text object.
- Test: select "rainy" in a paragraph following a heading; before ends with the heading text plus a newline.

**RDN-49 Selection menu.** The default selection actions shall be copy, share, look up and translate; the app shall be able to add custom actions (Funston: highlight) and to veto the menu or individual actions per selection; share shall be withheld for protected publications and copy shall ask the publication's rights (Readium reports a copy-forbidden error to the app when DRM refuses). Readium removes the system "Learn" item (it opened a text-replacement screen that allowed copying) and the "Copy Link with Highlight" and Writing Tools items on newer systems (issue 509).
- Test: with a highlight action registered, selecting a word shows Highlight; the action receives the selection locator.

**RDN-50 Decoration API.** The reader shall render decorations: an id (unique within its group), a locator, a style (built-in highlight and underline with an optional tint and an active flag; app-defined styles with their own config), and opaque app data. Decorations shall be declared in named groups, each call replacing the group's whole state; the reader shall diff by id and apply only inserts, removals and updates (an update is remove then add). The app shall be able to ask whether a style is supported and to observe activation per group, receiving the decoration, group, its bounding rect and the activation point. Applying while a previous apply for the same group is still running shall cancel the previous one (changelog 3.9.1 fixed duplicate highlights from this race).
- Readium: verified; the built-in highlight is a tinted box at 30% alpha with 1 px horizontal padding and 3 px corners, the underline a 2 px bottom border (left or right border in vertical writing), and an active highlight shows both.
- Spec: Readium Decorator API proposal 008.
- Test: apply 300 search decorations then an empty list; none remain; apply the same list twice; the second apply sends nothing.

**RDN-51 Decoration anchoring and relayout.** A decoration shall be anchored to a text range resolved from its locator: text context first (RDN-52), then a cssSelector element, then the first matching fragment id; unresolvable decorations shall be skipped with a logged diagnostic, never drawn at a wrong place. Boxes shall be computed per line rectangle of the range, merging rectangles that touch within 1 px (never merging horizontally adjacent ones in horizontal writing), dropping rectangles contained in others and those under 2 × 2 px, splitting overlaps; a "bounds" layout draws one box over the union. Decorations shall be re-laid out from their ranges whenever the content's size changes (font size, rotation), so they survive relayout without being re-sent. Width options: wrap the text, fill the union's width, fill the page column, fill the whole viewport (for margin markers). Decorations shall not intercept taps meant for links beneath them; activation shall be a fallback hit test (Readium tests groups' items in reverse insertion order with 1 px tolerance).
- Readium: verified in the decorator script. Issue 721 (fixed 3.9.1): paragraph indent shifted decoration boxes. In a native renderer the "range" is a text range in our own model and the boxes come from the layout manager; the merging rules still apply.
- Test: highlight a sentence that wraps three lines: three boxes, none overlapping; change text size: boxes follow the text.

**RDN-52 Text anchoring algorithm.** Finding a text locator in a document shall: search the document's rendered text (line breaks as spaces) for the exact highlight; if there is no exact match, search approximately allowing up to min(256, length / 2) edit errors; score each candidate as 50% similarity of the matched text, 20% similarity of the preceding text to the stored "before", 20% similarity of the following text to "after", and 2% proximity to a hinted offset; pick the best; fail (no scroll, no decoration) if there is none. Context lengths in play: 32 characters when Readium creates an anchor from a range, 200 for selections, 50 for TTS utterances; the scorer uses whatever is stored.
- Readium: verified in the vendored anchoring code (Hypothesis). This is behaviour we re-derive, not code we take; the weights are design constants to keep.
- Test: a highlight saved from an earlier edition of a Gutenberg file (minor punctuation edits) still anchors; a highlight whose text was removed is reported as unresolvable.

### Links

**RDN-53 Link activation.** Activating a link shall: classify it as internal when it resolves inside the publication, else external; external links shall go to the app (default: open in the system browser); internal links shall be checked for a note reference (RDN-54), then the app shall be asked whether to follow (default yes), then the reader shall navigate by RDN-22 and report a jump (RDN-29). A tap that dismisses an active selection shall not activate a link. External links shall be ignored while a navigation is in flight.
- Readium: verified. The web view's navigation policy intercepts link activations; internal is "relativisable against the publication base URL". The note check depends on the last click's target element captured by the page script, which was broken until 3.10 (changelog: "footnotes never being detected when tapped").
- Spec: EPUB 3.3 section 6.2 (hyperlinks), HTML a element.
- Test: tap a Gutenberg cross-reference to another chapter: lands at the id, jump reported; tap an https link: handed to the app.

**RDN-54 Note references.** When the activated anchor is an EPUB 3 note reference (epub:type containing "noteref") whose href points at a fragment, the reader shall fetch the target document, extract the element with that id (any element, not only aside), and offer the app the note's content and the link's own content as a referrer; the app shall return whether to navigate instead (Readium's test app shows the note in a sheet titled by the referrer when the referrer has at least two letters, and returns false). The reader shall sanitise note content before display.
- Readium: verified. Only epub:type is recognised; EPUB 2 books and Gutenberg's EPUB 3 conversions mostly mark footnotes with class names and backlinks, not epub:type, so they get no popup. The merged spec should decide whether to add heuristics (section 11).
- Spec: EPUB 3.3 structural semantics vocabulary (noteref, footnote, endnote, rearnote), EPUB 3.3 section 6.2.
- Test: an EPUB 3 sample with aside epub:type="footnote": tapping the reference shows the note without leaving the page; a Gutenberg footnote link navigates to the note and back.

**RDN-55 Interactive elements.** Taps on links, buttons, form controls, audio and video, details, labels, canvas and editable regions shall be handled by the content, not treated as reader taps (so they never toggle chrome or turn pages); media shall never autoplay. Readium's list of interactive tags is: a, audio, button, canvas, details, input, label, option, select, submit, textarea, video, plus any contenteditable element, checked up the ancestor chain.

### Read-aloud

**RDN-56 Content model for speech.** The reader shall produce, per spine item, an ordered list of content elements: text elements (one per block, with segments split where the language attribute changes, whitespace collapsed, leading and trailing whitespace trimmed per element, line breaks ending a segment), image elements (with alt as the accessibility label), audio and video elements (skipping their fallback children); each element carries a locator with the nearest block ancestor's cssSelector, text context (the element's raw text as highlight, up to 50 characters of preceding raw text as before), progression = element index / element count within the item, and totalProgression interpolated in the item's position window.
- Readium: verified in the HTML content iterator (SwiftSoup parse, block detection, language inheritance from lang and xml:lang). Changelog 3.9.0: selector generation was quadratic and is now linear; the lesson is that selectors are computed for every block, so compute them lazily or cheaply. Changelog 2.6: empty resources once caused a stack overflow when skipping them (issue 459).
- Test: a paragraph containing a span with lang="fr" yields two segments with different languages.

**RDN-57 Utterances.** Text elements shall be split into sentence utterances with the system natural-language tokenizer for the segment's language (segment language, else the configured default, else the publication language), trimming whitespace and dropping empty tokens; each utterance keeps up to 50 characters of context on each side within its segment; utterances with no letter or digit (pure punctuation) shall be dropped; an utterance's language shall be omitted when it equals the publication language so the app's default language can override it. Images and other elements shall produce an utterance from their text label when present.
- Readium: verified; the tokenizer is the NaturalLanguage sentence tokenizer. Changelog 3.9.0 notes PDF sentence segmentation is "not yet ready", which is a hint that segmentation quality is where effort goes.
- Test: "Mr. Darcy came in. He sat." yields two utterances, not three.

**RDN-58 Playback control and state.** The synthesizer shall expose start(from locator), stop, pause, resume, pause-or-resume, next and previous; states stopped, paused(utterance) and playing(utterance, spoken range); and a delegate for state changes and errors. Start resolution: the locator's cssSelector picks the starting block (Readium strips a ":root > " prefix some selector generators add); else a progression strictly between 0 and 1 picks the last element whose progression is below it; progression 1.0 picks the last element; else the first. Pause shall cancel the engine and remember the utterance; resume shall speak that utterance again from its start (Readium does not resume mid-sentence). Next and previous shall step through the utterance list and load the next or previous element, crossing spine items (entering a previous item at its end), skipping items with no speakable content, and stopping at the publication's ends. An engine error shall leave the synthesizer paused on the failing utterance and report the error.
- Readium: verified. Changelog 2.6.x fixed "TTS starting from the beginning of the chapter instead of the current position" and a crash when closing without stopping; the fix for the latter is that stop must be idempotent and the audio session released on deinit.
- Test: pause mid-sentence, resume: the sentence restarts; next at a chapter's last sentence speaks the next chapter's first.

**RDN-59 Voices.** The app shall be able to set a voice by stable identifier; the voice shall be used only when its base language matches the utterance's base language (or the utterance has none); otherwise the system default voice for the utterance language (falling back to the configured default, the publication language, then the device locale) shall be used. The available voice list shall exclude novelty and personal voices, the Eloquence voices and the classic legacy voices; each voice shall carry language with region, name, gender and a quality rank; the list shall be filterable by language (exact when a region is given, base otherwise) and sortable by language, region (device regions first, then a default region per language, then alphabetical), quality (high to low), gender (female, male, unspecified) and name.
- Readium: verified; the per-language default regions follow a published recommended-voices list. Readium does not expose rate or pitch (the code is disabled); Funston's music player conventions suggest exposing rate at least.
- Test: with voice "en-GB Daniel" selected and a French utterance, a French system voice speaks it.

**RDN-60 Speech engine discipline.** The engine wrapper shall never submit a new utterance to AVSpeechSynthesizer before it has received the start or finish callback for the previous one, and shall stop at the immediate boundary and queue at most one pending utterance; Readium documents an iOS 15 deadlock when this rule is broken and runs a four-state machine (stopped, starting, playing, stopping with an optional queued task) to enforce it. Word ranges shall be delivered from the will-speak-range callback and mapped back into the utterance's locator text (narrowing highlight and growing before and after).
- Test: tap next five times quickly: speech resumes with the fifth utterance and no stall.

**RDN-61 Audio session.** Read-aloud shall configure the session as playback, spoken-audio mode, long-form route sharing (Readium's defaults), activate it when speech starts, deactivate it when the app enters the background while not speaking, and end it when the synthesizer is released. On interruption end Readium reactivates the session but its synthesizer's resume hook is a no-op, so TTS does not auto-resume after a phone call; ours shall resume when the system says it should. Funston shares the session with its music player (not a Readium component), so the merged spec must own one session arbiter: starting read-aloud pauses music and vice versa; neither may deactivate the other's active session.
- Readium: verified in the shared audio session manager; starting one Readium audio user ends the previous one's session.
- Test: start read-aloud while music plays: music pauses, speech plays; a phone call: speech resumes after.

**RDN-62 Synchronising speech with the page.** The current utterance shall be marked with a decoration (Readium's test app: a highlight group "tts" replaced per utterance), and the page shall follow the spoken word range, throttled (test app: at most once per second, dropping updates while a move is in flight), scrolling only when the spoken range is off screen. Readium's go-to-locator with text puts the match at the top of the screen on every call, so following word by word scrolls constantly; do not copy that.
- Test: during speech the page turns only when the spoken sentence leaves the screen.

**RDN-63 Lock Screen and remote commands** are the app's job (the test app registers toggle play/pause and Now Playing info); the merged spec should route them through Funston's existing remote command handling.

### Input

**RDN-64 Taps, edge zones and chrome.** Taps that the content did not handle (RDN-55) shall reach the app in reader coordinates; an optional adapter shall turn taps in the leading or trailing edge zone into page turns, where the zone width is the larger of 80 pt and 30% of the reader width (vertical zones optional, same rule on height), ignored in scrolled mode by default; left zone goes left and right zone goes right (direction-mapped, RDN-09); mouse clicks count as taps; animated by app choice. The app's own tap handler (Funston: toggle chrome unless a selection exists, and never under VoiceOver) shall run only when nothing else consumed the tap. Readium recognises a tap as one pointer down and up with movement under 1 pt and no other pointer; a second pointer or a drag cancels it; taps during text selection are reported as cancelled.
- Readium: verified; the test app binds the adapter first, then an activation observer that toggles the navigation bar.
- Test: tap 40 pt from the right edge on a phone: next page; tap centre: chrome toggles; under VoiceOver a double-tap on the page does nothing to chrome and the magic tap toggles it.

**RDN-65 Keyboard.** With a hardware keyboard, arrow up and down shall go backward and forward, arrow left and right left and right (direction-mapped), space forward, all without modifiers; keys pressed while a form control in the content has focus shall go to the content; key repeat shall be ignored; keys shall be identified by physical code, not by the character the layout produces. The reader shall be first responder when visible so it receives presses.
- Readium: verified in the keyboard script and the adapter.

### Fixed layout

**RDN-66 Fixed-layout rendering (decision input).** If supported, fixed-layout items shall be rendered at their declared page size (the content document's viewport meta width and height; for a bitmap item, the image's natural size; else the available area), scaled to fit the page within the available area (fit "page" and "auto": the smaller of the width and height ratios; fit "width": the width ratio with vertical scrolling), centred, with pinch zoom; two items shall be paired into a spread when the spread policy allows (auto = landscape only) and the items' page-spread hints pair (left then right in a left-to-right book, right then left in a right-to-left book, hints defaulting to left/right by position), with the first item shown alone and centred unless it has an explicit hint or the app says otherwise; a spread's locator shall span both items, each always 0.0 to 1.0, one position per item; go-to inside an item shall be a no-op because the whole page is visible.
- Readium: verified in the spread formation (with tests for every pairing case), the wrapper page and its script. Readium's fixed-layout spreads use the publication's own direction to read hints, not the user's.
- Spec: EPUB 3.3 section 8.2 (fixed layouts, rendition:spread and page-spread properties), EPUB 3.3 section 8.2.3 (viewport meta).
- Recommendation: exclude fixed layout from version one. Project Gutenberg has none; Internet Archive's OCR EPUBs are excluded by policy; fixed layout needs a different renderer (an image-like page view with its own zoom and spread logic) and VoiceOver on a fixed-layout page is reading a picture of text. Keep the data model able to detect it (rendition:layout) so the app can say "this book's layout is not supported" rather than render it wrong.

### Images, SVG and embedded fonts

**RDN-67 Media sizing.** Images, SVG, audio and video shall be constrained to the content width (max-width 100%) and to 95% of the viewport height, preserving aspect ratio (contain), with automatic width and height, and shall never be split across pages; divs shall also be capped at the content width; tables shall be capped at the content width with border-box sizing. Readium's reason for 95vh: leave room for a caption.
- Readium: verified in the safeguards module.
- Test: a full-page illustration in a Gutenberg book sits on one page with its caption; a wide table scrolls or shrinks rather than overflowing the column.

**RDN-68 Fonts** are RDN-15; add: a publisher's embedded fonts (EPUB 3.3 section 6.4, with obfuscation per section 6.4.2) shall be honoured when no user family is set. Readium serves them like any resource; obfuscated fonts are deobfuscated by the streamer, outside this study.

**RDN-69 Images in dark and sepia.** In the dark theme the reader shall automatically invert images marked as gaiji (class contains "gaiji") and a lone image inside a title page element (epub:type titlepage), and shall offer darken (80% brightness) and invert filters for all images; in sepia, images shall blend multiplicatively with the page colour. Under the system's inverted-colours setting the automatic inversions shall be cancelled so images are not double-inverted.
- Readium: verified in the night and sepia modules and the OS accessibility module.

### Errors

**RDN-70 Error surfaces.** The reader shall surface, distinctly: the publication cannot be opened by this renderer (Readium throws when the publication is restricted by DRM; the app shows an error); a spine item failed to load (Readium: a delegate callback with the href and the read error, plus a spinner that gives up after 2 s if loading never began, issue 396); copy refused by rights (Readium: a presented error); and navigation refused (Readium: a false return, silent). Everything else (script errors, unresolvable decorations, unknown links) is logged. See section 8 for what the app does with each.

## Algorithms

Written from the behaviour, not from the source's shape.

### Resolving the effective settings

Inputs: user preferences (all optional), app defaults (all optional), publication metadata (languages, reading direction, layout). Output: one fully resolved settings value.

1. language = preference, else the publication's first language, else the default.
2. direction = the first non-empty of: preference; direction implied by the preferred language; publication direction if ltr or rtl; direction implied by the publication language; default; direction implied by the default language; ltr.
3. verticalText = preference, else (language is CJK and direction is rtl), else false.
4. scroll = preference, else default, else false; then forced true if verticalText; then forced true if VoiceOver is running.
5. Every other setting = preference, else default, else the fixed default in RDN-10; theme defaults to light with no app default.
6. The stylesheet variant = cjk-vertical if verticalText, else cjk-horizontal if the language is CJK, else rtl if direction is rtl, else default.
7. Record which settings are effective using RDN-10's last column, so the UI can grey out the rest.

### Pushing settings into a document (web mechanics, for the record only)

Three stylesheets are linked around the author's: a "before" sheet prepended to the head (base fonts per language, day colours, fragmentation rules, hyphenation limits, numeral variants, media safeguards), a "default" sheet appended only when the document has no author styles at all (detected by the absence of a link element, a style attribute and a style end tag anywhere in the markup), and an "after" sheet appended last (pagination, scroll, themes, the user-setting modules). The resolved settings become CSS custom properties with highest priority on the root element, written inline so the very first layout uses them; later changes are set by script with the same priority. The native renderer replaces all of this with a style resolver that takes the author's CSS and the settings and produces attributed text, but the precedence is the same: author styles win over base styles; user settings win over author styles only where RDN-12 to RDN-18 say they do.

### Forming pages (paginated reflowable)

1. Available page size = reader bounds minus content insets (RDN-05).
2. Column count = 1, or 2 when the width is at least 60 × root font size (or phone landscape), or the user's forced count in that case.
3. Column width = (available width - gutters) / count; line length capped at 40 × root font size with the text block centred.
4. Lay the item out as a sequence of columns of the available height; every column is filled before the next starts; headings avoid a break after them; headings, figures, images, table rows and definition terms avoid a break inside; widows and orphans at least 2 (1 in captions and table cells).
5. If count is 2 and the number of columns is odd, append an empty column so the last spread is complete.
6. A page is one column (count 1) or two adjacent columns starting at an even index (count 2).

### Resolving a go-to inside an item

```
resolve(target, item):
  if target.text.highlight:
     root = element(target.cssSelector) or item.body
     match = findQuote(root, highlight, before, after)      // RDN-52
     if match: return rangeStart(match)
  if target.fragments non-empty:
     el = elementById(first non-empty fragment)
     if el: return startOf(el)
  if target.cssSelector:                                    // our addition
     el = element(cssSelector)
     if el: return startOf(el)
  return offsetForProgression(target.progression or 0)
```
Then: scrolled mode scrolls so the resolved point is at the top of the visible area (clamped to the item's extent, accounting for insets at the two ends); paginated mode shows the page whose range contains the point (snap to the page start; never show a partial page).

### Reporting the current location

```
onScroll (coalesced per frame):
   first = leadingEdgeOffset / extent
   last  = (leadingEdgeOffset + visibleLength) / extent      // clamp both to 0...1
   remember (first, last); schedule settle in 0.3 s (reset on each scroll)
onSettle, when no navigation is in flight (else retry every 0.1 s):
   if (first, last) unchanged since last report: return
   idx = ceil(first × (positions.count - 1))
   lastIdx = last == 1 ? positions.count - 1 : max(idx, ceil(last × (positions.count - 1)) - 1)
   locator = positions[idx] with title = tocTitle(item), progression = first,
             totalProgression = window.start + first × (window.end - window.start)
   viewport = { item: first...last, positions: positions[idx].number ... positions[lastIdx].number,
                totalProgression: interpolate(first) ... interpolate(last) }
   if locator != lastReported: report; lastReported = locator
```
where window.start = the item's first position's totalProgression and window.end = the next item's first position's totalProgression or 1.0.

### Restoring across a relayout (ours; Readium's is "reload at progression")

```
beforeRelayout:
   anchor = firstVisibleLine()   // block cssSelector + text context + line index within the block
   fallback = currentLocator.progression
afterRelayout (once layout for that item is complete):
   point = resolve(anchor) ?? offsetForProgression(fallback)
   show point per RDN-23; suppress location reports until shown; then report once
```

### Resource window

```
schedule(current at target); then items after current until coveredPositions >= 6;
then items before current until coveredPositions >= 2 (each at its end);
unload any loaded item outside [firstScheduled, lastScheduled];
load in that order; after each load, apply its pending target; after the queue drains, report location
```

### Decoration diff

```
apply(group, newList):
   cancel any running apply for group
   wait until the reader is initialised
   old = state[group]; state[group] = newList
   if newList empty: for each loaded item: clear(group); return
   for each id in old not in new: remove(id) in its item
   for each id in new not in old: add(decoration) in its item (if loaded)
   for each id in both whose decoration changed: remove then add
when an item loads: add every decoration of every group whose href is that item
```

### Read-aloud loop

```
start(from):
   iterator = content(from); utterances = []; speakNext(forward)
speakNext(dir):
   u = utterances.step(dir)
   while u is nil:
       el = iterator.step(dir) ?? (state = stopped; return)
       utterances = tokenise(el) filtered to speakable; cursor at start (forward) or end (backward)
       u = utterances.step(dir)
   state = playing(u, nil)
   result = engine.speak(u.text, voiceOrLanguage(u), onRange: state = playing(u, narrowed range))
   if cancelled: return
   if success: speakNext(forward) else state = paused(u); report error
pause: cancel engine; state = paused(current)
resume: engine.speak(current) again
next/previous: cancel; speakNext(forward/backward)
```

### Text quote matching

See RDN-52. Exact search first (all occurrences); else approximate search with the error budget; score = (50 × quoteSimilarity + 20 × prefixSimilarity + 20 × suffixSimilarity + 2 × positionProximity) / 92; similarity of a context = 1 - errors / length of the stored context when matched against the same number of characters adjacent to the candidate; best score wins; no match means failure.

## Data model and persistence

### Locator (persisted by Funston, one row per book file)

```json
{
  "href": "OEBPS/chapter-03.xhtml",
  "type": "application/xhtml+xml",
  "title": "Chapter III",
  "locations": {
    "fragments": ["ch3"],
    "progression": 0.4137,
    "totalProgression": 0.2271,
    "position": 143,
    "cssSelector": "#ch3 > p:nth-child(7)",
    "partialCfi": "/4/2[ch3]/14/1:0",
    "domRange": { "start": { "cssSelector": "...", "textNodeIndex": 0, "offset": 12 }, "end": { "..." : "..." } }
  },
  "text": { "before": "...the last fifty characters ", "highlight": "the exact sentence", "after": " and the next fifty" }
}
```
Rules, verified in the model: href and type are required and parsing fails without them; href must be a valid URL (relative, no leading slash; Readium 3 normalises a leading slash away for packaged books); a legacy "fragment" string is accepted and appended to fragments; unknown keys under locations are preserved (that is where cssSelector, partialCfi and domRange live); position is non-negative; text fields are independent optionals; empty locations and text serialise as absent. Funston's book_positions table stores this JSON as text with a timestamp, keyed by item identifier and file name; nothing in the schema needs to change for the native renderer, but RDN-30 adds cssSelector and text to what gets written, and RDN-35 requires stripping navigation-only fragments before saving.

What Readium writes today (and therefore what Funston's existing rows contain): href, type, title (sometimes), progression, totalProgression, position. No text, no selector. Rows restore by progression only.

### Positions

A list per spine item of locators with progression and position (and, after the total is known, totalProgression), computed once per publication and cached in memory. Not persisted by the app; recomputed on open from the archive entry lengths (cheap).

### Preferences

A JSON-codable set of optionals (RDN-10). Readium separates "shared" preferences (everything except language, offsetFirstPage, readingProgression, spread, verticalText) from "publication" preferences (those five), so an app can store one global set plus a per-book override. Funston keeps text size in Dynamic Type and layout in its settings store; if per-book overrides come later, that split is the model to copy. Readium can also import its 2.x UserDefaults keys (font size percent, family index, appearance, alignment and so on), irrelevant to Funston.

### Viewport

Visible items with progression ranges, position range, total-progression range (RDN-32). Transient.

### Decorations and selection

Decoration: id, locator, style id plus style config (hashable), user info. Selection: locator with text, frame. Both transient; the app persists highlights as its own records holding the locator.

### Content elements (speech)

Text (role: heading with level, body, footnote, quote, list item, caption; segments with text, locator, language), image (locator, embedded link, caption, accessibility label), audio and video (locator, embedded link with alternates). Transient.

## Accessibility

What Readium does, in full, verified in the code:

1. Forces scrolled mode while VoiceOver runs and switches live (RDN-06). Everything else about reading under VoiceOver is WebKit's accessibility tree.
2. Marks the root view as causing page turns and answers VoiceOver's scroll request with forward and backward, always claiming success, with no announcement (RDN-40).
3. Skips animations under Reduce Motion (RDN-45).
4. Lets the accessibility editing actions (Speak Selection) through its menu gating (RDN-44).
5. The test app hides its page-number label from VoiceOver so continuous reading does not stop on it.

What it does not do, and the issues that record it:

| Issue | Status | What it teaches |
| --- | --- | --- |
| 113 [VoiceOver] Unable to move to correct next item during continuous reading | open, 2021, accessibility label | WebKit groups visually tight paragraphs into one block; "next item" jumps to the chapter end; 1em paragraph spacing splits them; never applied automatically. Native fix: one element per block (RDN-38, RDN-42). |
| 124 [a11y] Navigation between internal hyperlinks (migrated from 206) | open, 2018 | Following a link moves the page, not VoiceOver focus; needs a screen-changed notification (RDN-41). |
| 165 [a11y] Accessibility of Next/Previous navigator buttons | open, 2020 | The web view does not tell VoiceOver when it reaches the end; dummy buttons were the hack; three-finger scroll should map to pages (RDN-40). A screen reader user explains why TTS is not a substitute for screen reader navigation at different granularities. |
| 207 [a11y] Focus on continuous reading | closed 2019 | Fixed by forcing scrolled mode; remaining gap: WebKit scrolls only at paragraph boundaries inside a paragraph taller than the screen (a native renderer scrolls per line). |
| 257 Toggling VoiceOver freezes the app (iOS 16) | closed 2026-07-17, no fix linked | The VoiceOver toggle triggers a full reload of every web view; on iOS 16 that hung. Our toggle must be cheap (RDN-06). |
| 181 TOC navigation does not focus the target; 177 TOC levels not conveyed | closed 2025 as the app's job | Funston's contents list indents levels visually only; VoiceOver should hear the level. |
| 166 Unlabeled navigator buttons | closed | Label every control. |
| 502 Speak Selection does nothing | closed 2024, PR 505 | System speech actions must bypass the menu gate (RDN-44). |
| 349 (PR) Improve VoiceOver support | merged 2023-10-31 | Added auto-advance at the end of a resource and fixed scroll forcing. |
| kotlin-toolkit 352 Epub decorators are not accessible | open, 2023 | Overlay highlights are invisible to screen readers on both platforms (RDN-43). |
| 684 Vertical continuous scroll mode | open, PR 811 open | Per-item scroll surfaces make "next" a chapter jump; the maintainers want one continuous surface. |
| 700 Swiping backward in scroll mode goes to the end of the previous chapter | closed as expected | Confirms RDN-24's scrolled-mode behaviour. |
| 112 Swiping over the inset strip turned chapters | closed 2026-09 | Inset strips must belong to the page. |
| 373 Larger Text display zoom: bar pushes text | closed 2026-07 | Stable insets. |

Position restoration issues, since they decide the second-most important requirement:

| Issue | Status | What it teaches |
| --- | --- | --- |
| 645 Improve position restoration after changing the font size | open, 2025 | Percent-based restore loses the page; maintainer: use text snippets (RDN-36). |
| 55 Font size change causes a progression shift | closed 2025-04-23 without a linked fix | Same report in 2022; the maintainer proposed text context or freezing the locator across repeated setting changes. |
| 344 Wrong position after rotation | closed, PR 347 | Progression restore drifts backward on every rotation (accepted limitation); rotating twice fast lost the position (fixed by capturing the pending locator). |
| 839 Paginated EPUB resumes one column back after background | closed with correction | The app's own capture/restore on a theme change caused it; theme changes are layout-neutral; the first-visible-element restore lands one page early when the page starts mid-element. |
| 841 currentLocation adopts a position computed while inactive | open | Drop or defer reports while inactive (RDN-28). |
| 309 Reader reloads and loses position from background | fixed in 2.6 per the changelog, closed 2025 | Defer relayouts to the foreground. |
| 135 Restoring last read position occasionally fails | closed 2021 | A progression-0 report can precede the restored one (RDN-31). |
| 471 Progress does not change after changing text size | closed, PR 474 | Location must be recomputed after a live setting change. |
| 36 Toggling scroll mode loses position | closed 2025 | Apply the layout change before scrolling to the target. |
| 133 Incorrect page snapping after going to an HTML id | closed 2021 | Tiny targets must select the page containing their start. |
| 328 Locator with anchor placed mid-screen in scroll mode | closed 2023 | Put the target at the top. |

What the native renderer must do (the merged spec's accessibility section should take these as its baseline, with the PDF reader's line elements as the house style):

- One accessibility element per block with a real frame, static text trait, header trait and level for headings, link trait on links as their own elements, image elements with labels (RDN-38, RDN-47). Elements off screen are not exposed; elements partially on screen are exposed with their visible frame. Lists and tables are containers with start and end announcements.
- Three-finger scroll and continuous reading turn pages through the page-turn trait, with "Page n of m, Chapter title" (or "Chapter title" in scrolled mode) announced (RDN-40).
- After any jump, focus the first element of the target and announce (RDN-41).
- Highlights and the spoken utterance are values and actions on the text element (RDN-43).
- Funston's existing "Reading page" adjustable element (increment and decrement turn pages, magic tap toggles chrome, custom action shows or hides controls) stays; under VoiceOver it must turn pages, not chapters (RDN-24).
- Verification is under VoiceOver on a simulator or device, never by reading code (house rule).

## Malformed input and failure behaviour

What Readium does when things go wrong, verified unless marked, and what the app can do:

- Publication restricted (DRM not unlocked): the navigator refuses to initialise with a specific error. App: show "protected" and do not retry. Not applicable to Gutenberg.
- Spine item fails to load (missing entry, decode error, server refusal): the app gets the href and the read error through a delegate; the page stays blank behind a spinner that stops after 2 s. App: show a per-chapter error with a skip action. Ours shall render a placeholder page that says the chapter could not be loaded and still allow forward and backward.
- Web content process killed (memory pressure): Readium reloads every spread at the current location, silently. Ours has no web process; a native renderer must instead bound its own memory (RDN-26) and handle a decode failure of a single item as above.
- Locator href not in the reading order: go-to returns false; the initial location falls back to the beginning. App: Funston logs nothing today; it should surface "position not found, starting at the beginning" once.
- Locator text not found, fragment missing: Readium stays put (RDN-21 explains); ours falls through to the next resolution step and finally progression, and reports "approximate" when it had to.
- Progression outside 0 to 1: Readium logs and refuses to scroll. Ours clamps.
- Decoration whose locator cannot be anchored: skipped with a log. Ours: skipped, counted in a diagnostics structure the app can read (the gen-UI rule: fail loud into diagnostics, never silently blank).
- Decoration with an unregistered style: skipped with a log.
- Script error inside a document: logged with file and line; the page keeps working. Not applicable.
- Selection message malformed: selection cleared and a warning logged.
- Copy refused by rights: error presented to the app; nothing copied.
- Document with a dir attribute already: replaced (after a 2.x "attribute redefined" bug). Document with an existing lang: respected.
- Document with no author styles: the default stylesheet is added (unstyled Gutenberg-like files get sane headings and lists).
- Reflowable item with vertical text and the user's paginated preference: scrolled mode forced; the preference is not changed.
- An item declared as HTML with a bitmap fallback (or the reverse) in the manifest: the image is preferred as the primary resource (changelog 3.7). A spine of only bitmaps becomes a fixed-layout image book.
- Huge single spine item: CSS column balancing produced garbage widths (issue 907, closed after our tag). Ours: paginate incrementally with a bounded-work guard; if an item exceeds a size threshold, still render, but compute page count lazily.
- Odd column count in two-column mode: trailing empty column (RDN-02).
- Rapid navigation during loads: a stress test randomises jumps to catch cancellation races; Readium cancels in-flight resource loads per item. Ours: cancellation of layout work when the target changes.
- Rotating while inactive, backgrounding mid-load: deferred (RDN-27, RDN-28).
- Audio session activation failure: logged; speech still attempted. Ours: report to the app so it can show "cannot start audio".
- Voice not available for a language: AVFoundation falls back to the default voice; Readium's engine returns an unsupported-language error type but the AV engine never raises it. Ours: fall back and tell the app once.
- Empty or non-text spine items during read-aloud: skipped; an all-empty book stops immediately (issue 459's stack overflow is the thing to avoid: skip iteratively, not recursively).

## Test fixtures and vectors

Public-domain books to use (by URL, not copied):

- Project Gutenberg, Man and Maid, pg20512-images.epub (archive.org item manandmaid20512gut): the Funston canonical fixture; EPUB 3 conversion with Gutenberg's class-based footnotes, a cover image, chapters as separate spine items.
- Project Gutenberg, Moby Dick, https://www.gutenberg.org/ebooks/2701.epub3.images: long chapters, tight paragraph spacing (issue 113's reproduction case).
- Project Gutenberg, Little Women, https://www.gutenberg.org/ebooks/514.epub3.images: the chapter issue 113's reporter used.
- Standard Ebooks, any title (https://standardebooks.org): EPUB 3 with proper epub:type noteref and footnote semantics, embedded fonts, section ids; for RDN-54 and RDN-15.
- IDPF epub3-samples (https://github.com/IDPF/epub3-samples): accessible_epub_3 (noterefs, landmarks), page-blanche (fixed layout, French), kusamakura-japanese-vertical-writing (CJK vertical), regime-anticancer-arabe (RTL Arabic), cc-shared-culture (media overlays, video), wasteland (embedded fonts, page list).
- W3C epub-tests (https://github.com/w3c/epub-tests): the reading-system tests for page-progression-direction, rendition:layout, rendition:spread, viewport meta, and fragment identifiers; run the ones that apply to presentation and record pass or fail in the merged spec's conformance table.

What Readium's own tests cover (so we know what is proven there and what is not):

- Settings resolution: language to variant mapping (en default; ar, fa, he rtl; ja, ko, zh, zh-HK, zh-Hans cjk-horizontal; zh-Hant, zh-TW cjk-vertical with rtl); every precedence pair for reading direction; forced vertical text on and off.
- CSS injection: stylesheet set with and without author styles; variant folders; lang injection in four situations; dir replacement; the audio element fix.
- Property serialisation: empty, full and overridden user and reading-system property sets; inline property generation.
- Spread formation: empty reading order; one spread per item for reflowable; every fixed-layout pairing case for LTR and RTL; first page centred by default; offset-first-page on and off; odd page counts.
- Location calculator: resource list and progression ranges; total progression at start, boundary, end and mid-resource; position via ceil; title lookup; viewport position ranges including the "near 1.0 stops one short" rule; fallback when positions are absent.
- Total progression interpolation: partial scroll, ranges, two-resource spreads, last resource window end 1.0, publication start and end, nil when positions are empty or the href is unknown.
- Editing actions: custom action shown, suppressed by the app, denied per action, shown during the async selection window, native actions gated.
- Voices: filtering by base and exact language, sorting by language, region priorities (device, default, alphabetical), quality, gender, name, stable order.
- UI tests: rapid random navigation does not crash (cancellation races); the navigator deallocates after closing, including before it is ready.

Not covered by any Readium test, and therefore where our vectors must be written from the spec: go-to resolution order and fallthrough; page turn at item boundaries; restore after relayout; location report cadence; selection context; decoration anchoring and relayout; noteref detection; everything under VoiceOver.

Vectors to write for our implementation (from the specs, not from Readium):

1. Direction: package with page-progression-direction rtl and language en yields rtl; no attribute and language he yields rtl; attribute ltr and language ar yields ltr; preference rtl over everything.
2. Fragment navigation: href "ch.xhtml#id" where id exists yields that element's page; id missing but progression 0.3 given yields 30%; neither yields start.
3. Text navigation: highlight present with before/after; same with a one-character edit in the book; same with the sentence deleted (fails to progression).
4. Positions: items of 1, 1023, 1024, 1025 and 5000 bytes yields 1, 1, 1, 2, 5 positions; totalProgression of the last position = (total - 1) / total.
5. Location at page boundaries: progression 0, 0.5, 0.9999 and 1.0 in a 4-position item yields positions 1, 3, 3, 4 (per the ceil rule and the exact-1.0 rule).
6. Cadence: 50 scroll events in 1 s yields one report 0.3 s after the last; a report during a jump yields deferred.
7. Restore: size change at page 5 of a 12-page chapter, twice, lands on the same first line; rotation likewise; scroll flip likewise.
8. Selection: a word after a heading yields "before" contains the heading text, a line break, then the paragraph start.
9. Decorations: apply A, B; apply B, C yields one remove (A), one add (C); apply B (changed colour), C yields one remove and one add for B.
10. Noteref: EPUB 3 sample noteref yields note content offered; Gutenberg class-based footnote yields ordinary navigation.
11. Utterances: a paragraph with "Dr. Watson arrived. He sat." yields two utterances; a paragraph of only "***" yields none; a span with lang="fr" yields an utterance with language fr.
12. Fixed layout detection: rendition:layout pre-paginated yields reported as unsupported in version one with the title shown.

## Things to avoid

- Restoring a position by scroll fraction. It is the root of issues 645, 55, 344 and 839. Anchor to text (RDN-36).
- Leaning on the system's accessibility tree for a document view. Every open accessibility issue (113, 124, 165) is WebKit's tree doing something the navigator cannot see or correct. Own the elements.
- Forcing a different presentation for VoiceOver users as a substitute for fixing pagination. Keep it as an option, not a requirement (RDN-06).
- Answering an accessibility scroll request with "handled" when nothing moved, and never announcing (RDN-40).
- Rejecting navigation requests while busy instead of queuing the latest (RDN-25).
- Dropping a go-to silently when text or fragment resolution fails (RDN-21).
- Reporting a location before the restore has settled, and adopting locations computed while the app is inactive (RDN-28, RDN-31).
- Fixed waits as synchronisation (0.2 s after load, 0.3 s before reveal, 0.8 s scroll safety net, 2 s spinner timeout, 0.1 s state polling). A native renderer knows when layout finished; use that.
- Overlay highlights with pointer events off and no accessibility representation (RDN-43).
- Scrolling the page to put the spoken word at the top on every word (RDN-62).
- Auto-detecting "has author styles" by substring search for a link tag or a style attribute; parse the document.
- Stripping an author's dir attribute without knowing the publication direction.
- Letting a user font override apply to elements in another language (Readium gets this right; keep it).
- Shipping with no diagnostics for skipped decorations, unresolvable locators or chapters that failed to load.
- Relying on 1024-byte positions as "pages" in the UI without saying what they are; they are stable, not visual.
- Treating "spread auto" as applying to reflowable books: Readium's rotation reload is a side effect of that; reflowable books relayout on rotation for a real reason (page size changed), so decide the trigger explicitly.
- Growing the preference surface beyond what the reader can prove works (RDN-10 is the ceiling, not the floor, and Funston uses five of them).

## Open questions for the merged spec

1. Scrolled mode under VoiceOver: keep Readium's forcing as the default for parity, or trust the native paginated tree? Proposal: paginated by default with the page-turn trait and announcements, scrolled available; verify with Camden on device before deciding.
2. One continuous scroll surface across spine items (issue 684) versus per-item surfaces with explicit crossing. Per-item is simpler and matches saved locators; continuous reads better. The parser study's view on resource size and lazy loading should decide.
3. Accessibility element granularity: block (paragraph) versus line, given the PDF reader exposes lines. Proposal: block elements, with VoiceOver's own text navigation (character, word, line rotor) working inside each; lines only for poetry and preformatted text if testing shows block elements too long.
4. Footnote popups for Gutenberg's class-based footnotes: add heuristics (an anchor whose target is inside an element with a footnote-like class or role, or a short block ending with a backlink), or navigate like Readium does?
5. Whether to save text context in the locator (RDN-30) given rows are shared with the current Readium reader during the transition; the extra keys are harmless to Readium (preserved as other locations), so yes unless size matters.
6. Fixed layout: confirm exclusion from version one (RDN-66) and what the app shows instead.
7. Audio session ownership between read-aloud and the music player (RDN-61): one arbiter in Funston, with explicit rules for interruption resume and for background behaviour.
8. Rate and pitch for read-aloud (Readium has none): expose rate with Funston's existing playback-speed conventions?
9. Should the column count policy use the 60em threshold or Funston's size classes? Size classes are the native idiom; the em threshold adapts to text size, which matters for low vision.
10. Which EPUB CFI support, if any, lands in version one; nothing here needs it, and no Readium behaviour depends on it.

## Clean-room statement

This document was written from reading the Readium Swift Toolkit at the commit named in Provenance, its bundled stylesheets and page scripts, the shared services it depends on, its documentation, changelog and tests, and the project's GitHub issues. No source code, comment, docstring, CSS, JavaScript, test data, fixture or README text from the candidate has been copied into this document; the algorithms in section 5 are written from the behaviour as understood, in our own structure, and the constants quoted (insets, preload counts, ranges, steps, debounce and wait times, colours, stylesheet thresholds, anchoring weights) are facts about the behaviour, each attributed to where it was observed. The candidate's code was read in a scratch directory outside the Funston repository, was not built or run, and no file from it was copied into the worktree. Fixtures are referenced by public URL; no candidate fixture or expected-output table was reproduced. Internal type names appear only in "Architecture in our words" as orientation for readers of the candidate's documentation.

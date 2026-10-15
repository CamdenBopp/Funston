# W3C epub-tests conformance run, 2026-10-15

Spec 21.3 over the 206 publications of https://w3c.github.io/epub-tests/opds/opds.json (catalogue of 2026-06-25), run by EPUBConformanceTests on the iPhone 17 Pro simulator from branch claude/sad-darwin-0e6cc1. Expected is the standards study's column (P pass, D degrade with a diagnostic, N not applicable, P (as error) must refuse). Outcome words: pass, degraded (opened as the study expects, with the named diagnostic where one exists), fail, n/a. The JSON beside this file is the W3C result format: true for pass, false for fail and degraded, "n/a" otherwise.

Known failures: css-epub-text-align-last (not implemented; open question 24), pkg-dir_but_not_content and pkg-lang_but_not_content (the package language is inherited as the speech language for content that declares none, by design, so VoiceOver reads a French book in French; Spec 23 row added), pub-cmt-svg (SVG renders as its description in Phase A, Spec 23).

Outcomes: degraded 74, fail 4, n/a 54, pass 72

| Test | Expected | Outcome | Evidence |
| --- | --- | --- | --- |
| cnt-css-fonts_ot | P | pass | embedded fonts registered without a font diagnostic; codes:  |
| cnt-css-fonts_tt | P | pass | embedded fonts registered without a font diagnostic; codes:  |
| cnt-css-fonts_woff | P | pass | embedded fonts registered without a font diagnostic; codes:  |
| cnt-css-fonts_woff2 | P | pass | embedded fonts registered without a font diagnostic; codes:  |
| cnt-mathml-support | D | degraded | opens with math.textFallback; codes: math.textFallback |
| cnt-svg-css | D | degraded | SVG shown as its description; codes: image.placeholder |
| cnt-svg-css-inclusion | D | degraded | SVG shown as its description; codes: css.ignoredProperty image.placeholder |
| cnt-svg-css-reference | D | degraded | SVG shown as its description; codes: image.placeholder |
| cnt-svg-embedded | D | degraded | SVG shown as its description; codes: css.ignoredProperty image.placeholder |
| cnt-svg-support | D | degraded | SVG shown as its description; codes: image.placeholder |
| cnt-xhtml-support | P | pass | opens and renders; codes:  |
| css-epub-hyphens | P | pass | hyphens is accepted by the cascade; codes:  |
| css-epub-line-break | D | degraded | line-break is recorded as not honoured |
| css-epub-text-align-last | P | fail | text-align-last is reported ignored; codes: css.ignoredProperty |
| css-epub-text-combine-horizontal | N | n/a | opens; codes: css.ignoredProperty |
| css-epub-text-emphasis | N | n/a | opens; codes: css.ignoredProperty nav.synthetic |
| css-epub-text-orientation | N | n/a | opens; codes: css.ignoredProperty nav.synthetic |
| css-epub-text-transform | D | degraded | text-transform is recorded as not honoured |
| css-epub-text-underline-position | N | n/a | opens; codes: css.ignoredProperty nav.synthetic |
| css-epub-word-break | D | degraded | word-break is recorded as not honoured |
| css-epub-writing-mode | N | n/a | opens; codes: nav.synthetic |
| fxl-layout-duplication | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.duplicate rendition.fixedLayout |
| fxl-page-spread-break | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| fxl-page-spread-center | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| fxl-spine-overrides_behave-as-global | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout rendition.itemrefOverride |
| fxl-spine-overrides_behave-as-global-bis | D | degraded | opens as reflowable; no package-level pre-paginated declaration; codes: css.ignoredProperty rendition.itemrefOverride |
| fxl-spine-overrides_duplicate | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout rendition.itemrefOverride |
| lay-fxl-layout-default | D | degraded | opens as reflowable; no package-level pre-paginated declaration; codes:  |
| lay-fxl-layout-pre-paginated | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-layout-pre-paginated-spreads | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-orientation-default | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-orientation-landscape | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-page-spread-combined | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-page-spread-left | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-page-spread-right | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-spread-auto | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-spread-both | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-spread-default | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-spread-landscape | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-spread-none | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-svg-icb_multi | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty image.placeholder rendition.fixedLayout |
| lay-fxl-xhtml-icb | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-xhtml-icb_device_sizes | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-xhtml-icb_invalid_meta | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-xhtml-icb_multi | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-xhtml-icb_multi_declarations | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-xhtml-icb_repeated-in-meta | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-fxl-xhtml-icb_units | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-page-layout-both | N | n/a | opens; codes: css.ignoredProperty rendition.fixedLayout rendition.itemrefOverride |
| lay-page-layout-both-spread | N | n/a | opens; codes: css.ignoredProperty rendition.fixedLayout rendition.itemrefOverride |
| lay-pkg-flow-paginated | D | degraded | opens; rendition:flow paginated is read and the user's layout setting wins; codes:  |
| lay-pkg-flow-scrolled-continuous | D | degraded | opens; rendition:flow scrolledContinuous is read and the user's layout setting wins; codes:  |
| lay-pkg-flow-scrolled-doc | D | degraded | opens; rendition:flow scrolledDoc is read and the user's layout setting wins; codes:  |
| lay-pp-embedded-images | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-pp-embedded-images-svg | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty image.placeholder rendition.fixedLayout |
| lay-pp-images-in-spine | D | degraded | opens flowing with rendition.fixedLayout; codes: rendition.fixedLayout |
| lay-pp-images-mixed | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-pp-layout-default | D | degraded | opens as reflowable; no package-level pre-paginated declaration; codes:  |
| lay-pp-layout-duplication | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.duplicate rendition.fixedLayout |
| lay-pp-layout-pre-paginated | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-pp-layout-pre-paginated-spreads | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-pp-page-spread-combined | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-pp-page-spread-left | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-pp-page-spread-right | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-pp-spine-overrides_behave-as-global | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout rendition.itemrefOverride |
| lay-pp-spine-overrides_behave-as-global-bis | D | degraded | opens as reflowable; no package-level pre-paginated declaration; codes: css.ignoredProperty rendition.itemrefOverride |
| lay-pp-spine-overrides_image-only-pp | D | degraded | opens flowing with rendition.fixedLayout; codes: rendition.fixedLayout rendition.itemrefOverride |
| lay-pp-spine-overrides_image-only-reflow | D | degraded | opens as reflowable; no package-level pre-paginated declaration; codes: rendition.itemrefOverride |
| lay-pp-spine-overrides_image-spine-pp | D | degraded | opens flowing with rendition.fixedLayout; codes: nav.synthetic nav.unresolvedTarget rendition.fixedLayout rendition.itemrefOverride |
| lay-pp-spine-overrides_image-spine-reflow | D | degraded | opens as reflowable; no package-level pre-paginated declaration; codes: rendition.itemrefOverride |
| lay-pp-spread-none | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-pp-xhtml-icb | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-pp-xhtml-icb_invalid_meta | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-pp-xhtml-icb_multi | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-pp-xhtml-icb_multi_declarations | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-pp-xhtml-icb_repeated-in-meta | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-pp-xhtml-icb_units | D | degraded | opens flowing with rendition.fixedLayout; codes: css.ignoredProperty rendition.fixedLayout |
| lay-reflow-align-x-center | N | n/a | opens; codes: nav.synthetic |
| lay-rendition-flow-pre-pag | P | pass | opens and renders; codes: css.ignoredProperty font.missing nav.synthetic rendition.itemrefOverride |
| lay-roll-embedded-images | D | degraded | opens as reflowable; no package-level pre-paginated declaration; codes: css.ignoredProperty |
| lay-roll-embedded-images-svg | D | degraded | opens as reflowable; no package-level pre-paginated declaration; codes: css.ignoredProperty image.placeholder |
| lay-roll-images-in-spine | D | degraded | opens as reflowable; no package-level pre-paginated declaration; codes:  |
| lay-roll-images-mixed | D | degraded | opens as reflowable; no package-level pre-paginated declaration; codes: css.ignoredProperty |
| lay-viewport-meta-prop | P | pass | opens and renders; codes: css.ignoredProperty rendition.fixedLayout |
| mol-audio | N | n/a | opens; codes: mediaOverlay.detected |
| mol-audio-exceeding-clipend | N | n/a | opens; codes: mediaOverlay.detected |
| mol-audio-no-clipbegin | N | n/a | opens; codes: mediaOverlay.detected |
| mol-audio-no-clipend | N | n/a | opens; codes: mediaOverlay.detected |
| mol-css | N | n/a | opens; codes: mediaOverlay.detected |
| mol-ignore | P | pass | opens as text; overlays detected and ignored; codes: mediaOverlay.detected |
| mol-navigation | N | n/a | opens; codes: mediaOverlay.detected |
| mol-support_xhtml | N | n/a | opens; codes: mediaOverlay.detected |
| mol-support_xhtml-fxl | N | n/a | opens; codes: mediaOverlay.detected rendition.fixedLayout |
| mol-support_xhtml-load | N | n/a | opens; codes: mediaOverlay.detected |
| mol-support_xhtml-load-fxl | N | n/a | opens; codes: mediaOverlay.detected rendition.fixedLayout |
| mol-support_xhtml-load-next | N | n/a | opens; codes: mediaOverlay.detected |
| mol-support_xhtml-load-next-fxl | N | n/a | opens; codes: mediaOverlay.detected rendition.fixedLayout |
| mol-timing-synchronization | N | n/a | opens; codes: mediaOverlay.detected |
| mol-timing-synchronization_fxl | N | n/a | opens; codes: css.ignoredProperty mediaOverlay.detected rendition.fixedLayout |
| mol-timing-synchronization_multiple_audio | N | n/a | opens; codes: mediaOverlay.detected |
| mol-timing-synchronization_multiple_audio-fxl | N | n/a | opens; codes: mediaOverlay.detected rendition.fixedLayout |
| mol-timing-synchronization_svg | N | n/a | opens; codes: image.placeholder mediaOverlay.detected |
| mol-timing-synchronization_svg-fxl | N | n/a | opens; codes: image.placeholder mediaOverlay.detected rendition.fixedLayout |
| mol-tts_multi | N | n/a | opens; codes: mediaOverlay.detected |
| mol-tts_single | N | n/a | opens; codes: mediaOverlay.detected |
| nav-access | P | pass | 1 contents entries; "Test passes if you can see this link" resolves to spine 0; source navigationDocument |
| nav-activation | P | pass | 2 contents entries; "1st content document" resolves to spine 1; source navigationDocument |
| nav-non-text_img | P | pass | labels ["Start page", "Description of the Abbey of Sénanque"] |
| nav-non-text_img_title | P | pass | labels ["Start page", "Description of the Abbey of Sénanque"] |
| nav-spine_in-spine | P | pass | 2 contents entries; "Test passes if you can see two links (first link)" resolves to spine 1; source navigationDocument |
| nav-spine_in-spine-hidden-toc-css | P | pass | 2 contents entries; "The first link" resolves to spine 1; source navigationDocument |
| nav-spine_in-spine-hidden-toc-html | P | pass | 2 contents entries; "The first link" resolves to spine 1; source navigationDocument |
| nav-spine_in-spine-no-list-style | P | pass | labels without markers: ["Test passes if you can see two links: the first link", "the second link"] |
| nav-spine_not-in-spine | P | pass | 2 contents entries; "Test passes if you can see two links (first link)" resolves to spine 0; source navigationDocument |
| ocf-font_obfuscation | P | pass | embedded fonts registered without a font diagnostic; codes:  |
| ocf-font_obfuscation-bis | N | n/a | not downloaded: XCTSkip(skippedTestContext: <XCTSkippedTestContext: 0x114c97580>, errorCode: 106) |
| ocf-metainf-inc | P | pass | opens and renders; codes:  |
| ocf-metainf-manifest | P | pass | opens; spine has 1 items from the package only; codes:  |
| ocf-package_arbitrary | P | pass | opens and renders; codes:  |
| ocf-package_multiple | P | pass | first rootfile used; codes: container.rootfile.multiple |
| ocf-url_link-leaking-relative | P | pass | every reference resolved; codes: href.leakingRelative |
| ocf-url_link-path-absolute | P | pass | every reference resolved; codes: href.pathAbsolute |
| ocf-url_link-relative | P | pass | every reference resolved; codes:  |
| ocf-url_manifest | P | pass | every reference resolved; codes:  |
| ocf-url_origin | N | n/a | opens; codes:  |
| ocf-url_parse-leaking-relative | N | n/a | opens; codes:  |
| ocf-url_parse-path-absolute | N | n/a | opens; codes:  |
| ocf-url_relative | P | pass | every reference resolved; codes:  |
| ocf-zip-comp | P (as error) | n/a | the published archive has no non-Deflate entry; the reader's own test covers method 12 (EPUBZipReaderTests); codes:  |
| ocf-zip-mult | P (as error) | n/a | the published archive is not split; codes:  |
| pkg-collections-unknown | P | pass | opens and renders; codes:  |
| pkg-creator-order | P | pass | creators in document order: ["Dave Cramer", "Wendy Reid", "Dan Lazin", "Ivan Herman", "Brady Duga"] |
| pkg-dir-auto_root-rtl | P | pass | opens; main title "CSS: مغامرة جديدة!" dir=auto; codes:  |
| pkg-dir-auto_root-unset | P | pass | opens; main title "CSS: הרפתקה חדשה!" dir=auto; codes:  |
| pkg-dir_but_not_content | P | fail | content declares no lang or dir; the package language he is inherited as the speech language (gap: Spec 8.3 inherits the package language only as a last resort) |
| pkg-dir_creator-rtl | P | pass | opens; main title "pkg-dir_creator-rtl" dir=unset; codes:  |
| pkg-dir_rtl-root-ltr | P | pass | opens; main title "CSS: הרפתקה חדשה!" dir=rtl; codes:  |
| pkg-dir_rtl-root-unset | P | pass | opens; main title "CSS: הרפתקה חדשה!" dir=rtl; codes:  |
| pkg-dir_unset-root-rtl | P | pass | opens; main title "CSS: مغامرة جديدة!" dir=rtl; codes:  |
| pkg-dir_unset-root-unset | P | pass | opens; main title "CSS: مغامرة جديدة!" dir=unset; codes:  |
| pkg-lang_but_not_content | P | fail | content declares no lang or dir; the package language fr is inherited as the speech language (gap: Spec 8.3 inherits the package language only as a last resort) |
| pkg-linked-records | P | pass | title "Package metadata title!" and creators ["Matthew Chan"] from the package |
| pkg-manifest-unknown | P | pass | opens and renders; codes:  |
| pkg-manifest-unlisted-resource | D | degraded | opens; the unlisted image is shown and no diagnostic names it (STD-09 as adopted; recorded gap); codes:  |
| pkg-meta-unknown | P | pass | opens and renders; codes:  |
| pkg-meta-whitespace | P | pass | title "pkg-meta-whitespace" and creators ["Dave Cramer"] collapsed |
| pkg-spine-duplicate-item-hyperlink | P | pass | the duplicate itemref is two spine positions: ["content_001", "content_002", "content_002", "content_002"] |
| pkg-spine-duplicate-item-rendering | P | pass | the duplicate itemref is two spine positions: ["content_001", "content_002", "content_002", "content_002"] |
| pkg-spine-duplicate-item-ui | P | pass | the duplicate itemref is two spine positions: ["content_001", "content_002", "content_002", "content_002"] |
| pkg-spine-nonlinear-activation | P | pass | non-linear items [1] are reachable through a link; codes:  |
| pkg-spine-order | P | pass | spine order ["d-content_001", "c-content_002", "b-content_003", "a-content_004"] differs from manifest order ["b-content_003", "a-content_004", "c-content_002", "d-content_001"] and is what the reader follows |
| pkg-spine-order-svg | D | degraded | opens; spine kinds image,image,image,image; codes: image.placeholder |
| pkg-spine-progression-default | P | pass | language ar, declared default, pages right to left: true |
| pkg-spine-progression-pre-paginated | N | n/a | opens; codes: css.ignoredProperty rendition.fixedLayout |
| pkg-spine-progression_ltr | P | pass | progression ltr |
| pkg-spine-progression_rtl | P | pass | progression rtl |
| pkg-spine-unknown | P | pass | opens and renders; codes:  |
| pkg-title-order | P | pass | main title is the first dc:title: ["pkg-title-order", "This title must not display first", "Also, this title must not display first", "This title also must not display first", "This title must also not display first", "This title must not display first, also"] |
| pkg-unique-id | P | pass | opens as pkg-unique-id (pkg-unique-id); codes:  |
| pkg-version-backward | P | pass | opens and renders; codes:  |
| pss-support | P | pass | 1 note reference(s) detected from epub:type, opened in a sheet |
| pss-support_ignore-title | P | pass | 2 note reference(s) from epub:type; the sheet shows the note body, not the title attribute |
| pub-cmt-avif | D | degraded | opens; codes:  |
| pub-cmt-gif | P | pass | 1 image(s) decode; sizes ["600x400"] |
| pub-cmt-jpeg | P | pass | 1 image(s) decode; sizes ["600x400"] |
| pub-cmt-jxl | D | degraded | opens; codes:  |
| pub-cmt-mp3 | N | n/a | opens; codes:  |
| pub-cmt-mp4 | N | n/a | opens; codes:  |
| pub-cmt-opus | N | n/a | opens; codes:  |
| pub-cmt-png | P | pass | 1 image(s) decode; sizes ["600x400"] |
| pub-cmt-svg | P | fail | SVG renders as its description, not as a picture (STD-26 deviation, Spec 23); codes: image.placeholder |
| pub-cmt-webp | P | pass | 1 image(s) decode; sizes ["600x400"] |
| pub-data-urls_browsing-context | P | pass | the data: image is shown inline; codes:  |
| pub-data-urls_top-level-content | N | n/a | opens; codes: css.ignoredProperty image.placeholder rendition.fixedLayout |
| pub-external-links | P | pass | 1 external link(s) resolved; the reader asks before leaving the app |
| pub-external-links_consent | P | pass | 1 external link(s) resolved; the reader asks before leaving the app |
| pub-file-urls | P | pass | opens; file: references are never fetched (media elements render as placeholders); codes: media.placeholder |
| pub-foreign_bad-fallback | D | degraded | refused: The book's file looks damaged. Try downloading it again. |
| pub-foreign_image | P | pass | every reference resolved; codes:  |
| pub-foreign_json-spine | P | pass | the foreign spine item fell back to a renderable document; kinds ["document"]; codes: nav.synthetic nav.unresolvedTarget |
| pub-foreign_xml-spine | P | pass | the foreign spine item fell back to a renderable document; kinds ["document"]; codes: nav.synthetic nav.unresolvedTarget |
| pub-foreign_xml-suffix-spine | P | pass | the foreign spine item fell back to a renderable document; kinds ["document"]; codes: nav.synthetic nav.unresolvedTarget |
| pub-xml-external-id | P | pass | opens; external entities are never resolved (XMLParser policy never); codes: chapter.parse.unknownEntity |
| pub-xml-names | D | degraded | XMLParser accepted the invalid element name and the text renders; no diagnostic (recorded gap); codes:  |
| pub-xml-non-validating_comment | P | pass | spine has 2 item(s); a commented-out itemref is not among them |
| pub-xml-non-validating_unclosed | D | degraded | opens with xml.tagsoup; codes: xml.tagsoup |
| scr-not-support_ccscript-modify-host | N | n/a | opens; codes: media.placeholder |
| scr-not-support_ccscript-modify-size | N | n/a | opens; codes: media.placeholder |
| scr-readingsystem-features | N | n/a | opens; codes:  |
| scr-readingsystem-support | N | n/a | opens; codes:  |
| scr-readingsystem-support_iframe | N | n/a | opens; codes: media.placeholder |
| scr-readingsystem-support_iframe_svg | N | n/a | opens; codes: media.placeholder |
| scr-readingsystem-support_svg | N | n/a | opens; codes: image.placeholder |
| scr-storage-delete | N | n/a | opens; codes:  |
| scr-support | N | n/a | opens; codes:  |
| scr-support-fallback | P | pass | opens and renders; codes:  |
| scr-support_iframe | N | n/a | opens; codes: media.placeholder |
| scr-support_origin | N | n/a | opens; codes:  |
| scr-support_origin_unique | N | n/a | opens; codes:  |
| scr-support_scrolled-continuous | N | n/a | opens; codes:  |
| scr-support_scrolled-doc | N | n/a | opens; codes:  |
| scr-support_svg | N | n/a | opens; codes: image.placeholder |
| sec-untrusted-consent_network | P | pass | opens; nothing remote is fetched and no script runs; codes: css.sheetMissing image.placeholder media.placeholder |
| sec-untrusted-consent_scripting | P | pass | opens; nothing remote is fetched and no script runs; codes: media.placeholder |

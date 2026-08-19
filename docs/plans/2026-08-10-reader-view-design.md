# Reader View Design

Date: 2026-08-10
Status: draft
Branch: `feat/reader-view` (proposed)

## Problem

Phi has no reader view. The only distraction-free reading surface today is the
`show-page-reader-mode` agent skill, which injects a Mozilla Readability
overlay through Kensington. It is unreachable without invoking the agent,
unavailable when AI is off, and structurally limited to what a content script
can see.

Three quality problems are common to that skill and to every shipping reader
mode, including Safari, Firefox, and Chrome:

1. **Truncated articles.** Extraction returns part of the page and reports
   success.
2. **No usable PDF reading.** Readability requires a DOM, so PDFs get nothing.
3. **Narrow site coverage with no way to fix a specific site.** Rules are
   compiled into the product and ship on the release train.

These have different root causes and are addressed separately below.

### Why extraction fails today

Readability scores candidate nodes primarily by regular expressions over
`class` and `id` names. That assumption held when markup carried
human-authored semantic names. It does not hold for utility-class CSS, CSS
modules, or hashed build output, where no signal remains. Coverage therefore
degrades as the web modernises, and cannot be recovered by tuning the
expressions.

Truncation is a separate defect and is not an extraction bug. In
`third_party/readability/modded_src/Readability.js`, the success test is
absolute:

```js
var textLength = this._getInnerText(articleContent, true).length;
if (textLength < this._charThreshold) {   // DEFAULT_CHAR_THRESHOLD = 500
```

A retry ladder exists — drop `FLAG_STRIP_UNLIKELYS`, then
`FLAG_WEIGHT_CLASSES`, then `FLAG_CLEAN_CONDITIONALLY`, then take the longest
attempt — but it only runs when the result is under 500 characters. A long
article that extracted 600 characters is reported as a success and the
algorithm never learns it failed.

## Product Decisions

- Reader View is a first-class browser feature. It works with AI disabled, in
  Guest Mode, offline, and with Phi extensions disabled.
- Entering Reader View does not navigate the tab. The address bar, history,
  bookmarks, and sharing continue to reflect the original page.
- **Framework changes are held to a minimum.** Logic that can live in Swift
  lives in Swift. The Chromium surface is limited to what is provably
  unreachable from the client, and each addition is a generic primitive with
  no Reader View policy in it.
- Reader View is available for HTML articles and, in a later phase, for PDFs.
- Per-site extraction rules are data, not code, and are updatable without a
  browser build or an app release.
- Extraction quality is measured against the page, not against a fixed floor.
  An implausibly small extraction escalates rather than rendering.
- The existing `show-page-reader-mode` skill is re-pointed at the native
  toggle once this ships. Two implementations of the same user-visible concept
  must not coexist.

## Architecture Overview

Reader View is a Swift feature that reaches into the page over the app's
existing DevTools channel. The framework contributes one identifier in phase
one and one accessibility primitive in phase two.

`AppDevToolsPageSession` already provides an app-owned CDP client. It opens a
`socketpair()`, hands one end to the DevTools server through
`attachDevToolsConnectionWithFD:`, and speaks CDP as the client. There is no
listener, no port, and no consent prompt, and both ends live and die inside
the app and browser pair. `AgentSpaceRouter+Credentials` already uses it to
run `Runtime.evaluate` against a page and read structured results back.

That channel gives Swift everything the HTML path needs: run the preparation
step, apply site rules, run extraction, and measure coverage, all inside the
page, with the result returned as JSON.

| Concern | Home |
| --- | --- |
| Extraction policy, ladder, coverage gate | Swift `States` |
| In-page preparation and extraction script | `Resources/`, run via CDP |
| Site rules (data) | Sentinel remote config, bundled baseline |
| Article rendering | `WKWebView`, JS disabled |
| Button, menu, shortcut, preference | Swift `UserInterface` |
| CDP target identity | Framework, one readonly property |
| PDF accessibility tree | Framework, one method (phase two) |

### Why not a content script

Extraction is driven from the app rather than from a bundled extension
because `shouldEnablePhiExtensions` disables those when AI is off. Hosting
Reader View there would reproduce the availability failure this design exists
to remove. The CDP channel is owned by the app and is unaffected by the AI
toggle.

## Framework Surface

This is the complete list of Chromium-side changes. Everything else is Swift.

### Phase one: one property

`WebContentWrapper` gains a readonly target identifier so Swift can open a
session on a tab:

```objc
@property(nonatomic, copy, readonly, nullable) NSString *devToolsTargetId;
```

Backed by `content::DevToolsAgentHost::GetOrCreateFor(web_contents)->GetId()`.
The bridge currently exposes no target id, and without it Swift cannot map a
tab to a CDP endpoint. This is the only thing blocking the HTML path.

### Phase two: one method for PDFs

PDF structure cannot be obtained over CDP, and this is not a limitation that
can be worked around from Swift.
`RenderAccessibilityManager::SetMode` creates `RenderAccessibilityImpl` only
when the browser pushes an `AXMode` containing `kWebContents`. CDP's
accessibility domain builds a Blink-side `AXContext` instead
(`inspector_accessibility_agent.cc` creates `AXContext(*document,
ui::kAXModeComplete)`), which never sets `RenderAccessibility`. With it null,
`PdfAccessibilityTree::UpdateDependentObjects` returns false,
`LoadOrReloadAccessibility` is never called, and the plugin subtree is empty.
`RequestAXTreeSnapshot` fails for the same reason.

So one async method holds a browser-side scoped mode for the duration of
extraction and returns the tree as a dictionary:

```cpp
auto scoped_mode =
    content::BrowserAccessibilityState::GetInstance()
        ->CreateScopedModeForWebContents(web_contents,
                                         ui::kAXModeWebContentsOnly);
```

No screen reader is required. `kAXModeWebContentsOnly` is
`kWebContents | kInlineTextBoxes | kExtendedProperties` and deliberately
excludes `kNativeAPIs`. The mode is released as soon as the tree is
serialised.

The method is a pipe. It contains no scoring, no rules, and no Reader View
policy; all interpretation happens in Swift.

### Optional one-line change

`chrome_pdf::features::kPdfTags` is disabled by default, so every PDF uses the
heuristic builder, which infers headings from per-page median font size
multiplied by 1.2 and never infers a heading level. Enabling it restores real
tagged-PDF semantics including heading levels, tables, and figures. This is a
default flip and the highest quality-per-effort item in the design.

### Deliberately not added

- No `reader_proxy` sub-proxy.
- No `DomDistillerService` integration or `ViewRequestDelegate`.
- No `--enable-dom-distiller` or `--enable-distillability-service` switches.
- No `DistillabilityObserver` eligibility plumbing.
- No article payload crossing the bridge.

An earlier revision of this design placed all of the above in the fork. The
CDP channel makes them unnecessary for the HTML path, and the eligibility
signal is replaced as described under User Interface.

`PhiChromiumBridgeHeader.h` exists in three copies. The Chromium and
`phibrowser-mac` copies must change together. The `phibrowser-mac-x64` copy is
already behind by 51 lines, and nothing catches the drift at build time: the
framework ships with no `Headers/` directory and the Xcode embed step uses
`RemoveHeadersOnCopy`.

## Extraction Pipeline

Swift opens a session on the active tab's target, evaluates one bundled
script, and applies the resulting policy decisions itself. The script is
authored in `Resources/` and iterates at Swift build speed.

The script receives the matching site rule as a parameter and returns a
structured result, including the measurements Swift needs to judge it:

```
{ ok, title, byline, siteName, lang, contentHTML,
  extractedLength, visibleTextLength, linkDensity, rung }
```

### Ladder

Rungs are attempted in order, and each is accepted only if it passes the
coverage gate.

1. **Site rule**, when one matches. Deterministic and fastest.
2. **Readability**, bundled into the script, run against the live DOM.
3. **Structural fallback**: score candidate containers by text length and link
   density without relying on class or id names, which is the signal
   Readability loses on modern markup.

The accessibility tree is not used on the HTML path. It is reserved for PDFs,
where it is the only option. This avoids a second framework primitive for a
case the DOM already covers.

### Coverage gate

Extracted text length is compared against the page's total visible text,
using `document.body.innerText.length` as the denominator. A ratio below the
configured floor is a failure and escalates to the next rung rather than
rendering a truncated article.

When every rung has run, the best result by coverage is used, not the first
that cleared a threshold. This single change addresses the dominant
truncation mode described under Problem.

### Page preparation

The script prepares the page before extracting. This step is the largest
single quality lever and is absent from every shipping reader mode.

- Expand `<details>` elements.
- Activate expansion affordances named by the site rule.
- Scroll to trigger lazy loading and wait for network quiet, bounded by a
  timeout.
- Follow `rel="next"` and concatenate, bounded by the site rule's page limit.

Readability has no pagination support and no concept of content absent from
the DOM, so none of this is available by default.

Preparation mutates the live page. The script must restore scroll position on
completion, and must not run on pages the user has partially interacted with
in ways preparation would disturb. Failures leave the page untouched.

## PDF

PDFs are extracted from the accessibility tree returned by the phase-two
method. Chromium's own Reading Mode reaches the same conclusion: it forces the
accessibility path whenever the document is a PDF.

The tree provides paragraphs, headings, links, images, per-page regions,
reading order, word boundaries, and document language. Swift walks it using
`kRegion` with `kIsPageBreakingObject` for page boundaries, then assembles the
same article model the HTML path produces, so presentation is shared.

Two known gaps:

- **Copy-protected documents.** `LoadAccessibility` requires copy or
  copy-accessible permission and returns nothing otherwise. These fall back to
  `pdf::PDFDocumentHelper::GetPageText`, which yields text without structure.
- **Timing.** The committed origin is unreliable immediately after load;
  Reading Mode waits approximately one second after `DidStopLoading`.

OCR for scanned PDFs depends on the Screen AI model, which is not shipped in
the framework and is delivered by component updater. It is out of scope.

## Site Rules

Rules are versioned data delivered at runtime. Baking them into the browser or
into an extension bundle reproduces the release-train coupling this design
exists to remove.

The rule shape follows `phi_url_router`, which is already proven in
production: three host tiers (exact, `*.suffix`, `*contains*`), an optional
path prefix requiring a `/` boundary so `/foo` does not match `/foobar`, a
specificity tuple for tie-breaking, and atomic whole-table replacement rather
than diffing.

```
host, pathPrefix
content:   [selectors]   # multiple roots, concatenated
strip:     [selectors]
expand:    [selectors]   # activated during page preparation
title | byline: selector
forceRung: rule | readability | structural
```

Pagination across a multi-page article and per-site date extraction were part
of the original shape and are not shipped. The schema rejects both rather than
accepting fields the extraction script never reads, which would let a
contributor write a rule that silently does nothing.

Multiple content roots are required. Single-root selection is a direct cause
of truncation on articles split across sibling containers.

`metadata.phi_sites` is not reused. It is a skill-visibility gate matching
exact lowercase hostnames with no wildcards or paths, and its documentation
states it is not a security boundary.

### Delivery

Because extraction is now Swift-driven, rules are consumed by the client
directly and phi-agent is not involved. This removes the last AI-stack
dependency from the feature.

The corpus lives in its own public repository,
[phibrowser/phi-reader-rules](https://github.com/phibrowser/phi-reader-rules),
one JSON file per site. CI validates every file against
`schema/rule.schema.json`, compiles the directory into a single table, and
publishes it to GitHub Pages:

- `v1/manifest.json` — SHA-256, byte count, and rule count of the table
- `v1/rules.json` — the table, carrying no build timestamp so its digest moves
  only when a rule moves

`ReaderSiteRuleStore` resolves the corpus from the newest of three sources:
the table it last downloaded and verified, in Application Support; the
baseline bundled in `Resources/ReaderSiteRules.json`; or nothing, which costs
only the first rung of the ladder. It checks the manifest at launch, and
before entering Reader View if the last check is over six hours old, so a
browser left running for days does not go stale. Replacement is whole-table,
never a merge, so a rule deleted upstream because it broke actually
disappears.

Sentinel remote config was the obvious candidate and is the wrong one.
PhiBrowser is explicitly out of scope as a v1 consumer, the poll cycle is
skipped entirely when no user is authenticated, and the payload is a PostHog
feature-flag value, which is not where a growing corpus of site rules belongs.
Reader View has to work in Guest Mode and signed out, which rules the
mechanism out on its own.

A public repository also buys the thing that motivated this section: anyone
who reads a site every day can fix it themselves, and the fix reaches every
install without a release. Rules are CC0.

## Article Rendering

The article renders as HTML because article content is HTML-shaped — figures,
tables, blockquotes, code, footnotes, math, RTL. Reimplementing a usable
subset in AppKit or SwiftUI would be a large effort with a worse result.

The surface is a `WKWebView`, not a Chromium `WebContents`. `loadHTMLString`
requires nothing from the framework, and `ExtensionDialogViewController`
already establishes the pattern in this codebase.

**JavaScript is disabled** on the reader web view via
`defaultWebpagePreferences.allowsContentJavaScript = false`. Article content
needs no scripting, and rendering untrusted extracted HTML with scripting off
removes a whole class of injection risk. This is materially easier to
guarantee here than in a Chromium tab.

Swift assembles the final document from the shell, the article model, and
theme custom properties written from `ThemeManager`. Shell, CSS, and article
serialisation all live in `Resources/` and iterate at Swift build speed.

The shell owns typography, font size, theme, and width controls, persisted as
ordinary Phi preferences.

## State and Ownership

`WebContentViewController.ContentMode` gains a `.reader` case alongside
`.nativeNtp`, `.webContent`, and `.groupOverview`. Mounting follows
`showGroupOverview(token:browserState:)`, which is approximately twenty lines,
and must reproduce its split-pane branch, its `view.window == nil` guard, and
its deferred-update retry.

`Tab` gains one in-memory `@Published` property:

```swift
@Published var isReaderViewActive: Bool = false
```

Reader state is per tab and is not persisted, so no `TabDataModel` schema
version is required. Leaving Reader View restores `.webContent` with the
underlying `WebContents` untouched, since it was never navigated.

Window-level toggle behaviour lives in a new `BrowserState+Reader.swift`,
mirroring the existing `BrowserState+ToggleAI.swift`.

Sessions are opened on user intent and closed immediately after extraction.
No long-lived CDP session is held per tab.

## User Interface

Phi has three layout modes and two independent address-bar implementations. A
button added to only one appears in only one of three layouts.

- `.performance`: AppKit `SideAddressBar`. Follow `copyURLButton` —
  `HoverableButtonNSView` with `HoverableButtonConfig`, a 24×24 SnapKit
  constraint, a tooltip, and Combine-driven `isHidden`.
- `.balanced` and `.comfortable`: SwiftUI `WebContentAddressBarView`. Follow
  `copyURLButton` in the trailing `HStack`.

Visibility joins the existing decision point in
`WebContentHeader.updateLayoutVisibility()`, which already handles placeholder
mode, group overview, and split partners.

### Eligibility

The button (and only the button) gates on eligibility; the menu, shortcut,
and context menu stay unconditional, with extraction's own refusal as the
authority. Three signals decide it, cheapest first — see
`ReaderExtractionService.isReaderWorthOffering`:

1. a site rule matches (`ReaderSiteRuleStore`);
2. Chromium's native distillability verdict is positive. The framework-side
   `DistillabilityObserver` — dropped in phase one, restored once the
   per-navigation probe cost was real — subscribes in
   `PhiWebContentsObserver` and pushes upstream DOM Distiller's AdaBoost
   verdict (computed in Blink during layout, after parse and again after
   load) to the KVO property `WebContentWrapper.isDistillable`. It is
   positive-only: upstream suppresses short articles and non-HTTPS pages,
   so NO falls through rather than concluding anything. A rising edge also
   re-judges the button (`Tab.setupObservers`), which covers articles that
   hydrate after the load-settle probe and its one-shot retry gave up;
3. `isProbablyReaderable` (plus Phi's supplements) over CDP, as before —
   now reached only when neither cheaper signal answered, so article pages
   normally pay no probe at all.

The renderer-side agent is enabled by forcing
`--enable-distillability-service` for Phi in
`ChromeContentBrowserClient::AppendExtraCommandLineSwitches`, the same way
Android does.

### Menu and shortcut

A View menu item is added in `AppController+Menu.swift` with a unique private
tag, a handler, and a `validateUserInterfaceItem` branch supplying the
checkmark and disabling the command in placeholder mode and on internal pages.

The shortcut is `PHI_TOGGLE_READER = 90021` in `Shortcuts.CommandWrapper`
(90020 is currently the highest), with a default binding and an entry in
`CommandDispatcher.phiInterceptedCommands` so it is handled natively before
Chromium sees it. It is remappable through the existing shortcuts settings.

A toggle is added to `PhiPreferences.GeneralSettings` and surfaced in
`BrowsingSectionView` of `GeneralSettingView.swift`.

## Localization

All user-facing strings use explicit keys with `value:` and `comment:`, added
to `Resources/Localizable.xcstrings` in English only. Translations arrive
through the phi-i18n synchronisation workflow and must not be authored here.
Proposed key prefixes: `browser.webContentAddressBar.readerView.*`,
`sidebar.addressBar.readerView.*`, `app.viewMenu.toggleReaderView`,
`settings.general.readerView.*`.

## Privacy and Security

Extraction is local. Page content is never sent to phi-agent or to Phi Cloud
as part of Reader View.

The reader web view runs with scripting disabled, so extracted markup cannot
execute. Remote subresources referenced by the article are still loaded;
whether to proxy or block them is an open question below.

Remote-config payloads are client-visible and must never carry secrets.

Rule synthesis, if adopted, operates on a DOM skeleton — tags, roles, and
class names with text removed — and uploads only the resulting selectors,
never page content.

## Testing

Automated tests cover the coverage-gate ratio policy and escalation ordering,
rule matching and specificity tie-breaking, article-model assembly from both
the DOM result and a PDF tree fixture, HTML serialisation and escaping,
eligibility and failure reporting, and `ContentMode` enter and exit including
the split-pane branch.

Rule matching is the highest-risk area. Two hand-mirrored copies of the
`phi_url_router` matcher already exist in C++ and Swift with no automated
drift detection, and the Swift test suite is the only thing pinning the shared
semantics. A third copy must not be added without tests pinning it.

The extraction script is tested in isolation against a fixture corpus of saved
pages covering utility-class CSS, single-page applications, paginated
articles, and tagged and untagged PDFs. The corpus backs a coverage regression
report so extraction quality is measured rather than asserted.

CDP transport needs explicit coverage for large payloads: a long article
returned through `Runtime.evaluate` with `returnByValue` must survive
WebSocket frame fragmentation in `AppDevToolsPageSession`, and the timeout
must accommodate the preparation step's scroll-and-wait.

Final verification follows the project-required external Xcode
`build-for-testing` and focused `test-without-building` workflow, and Canary
is used for all manual testing.

## Build Order

1. Add the coverage gate and page preparation to the existing skill. No new
   infrastructure, and it measures how much of the truncation problem is
   recoverable before anything else is built.
2. Add `devToolsTargetId` to the bridge. This is the only phase-one framework
   change.
3. Build the Swift extraction service over CDP: script, ladder, coverage gate.
4. Add the `.reader` `ContentMode` with the `WKWebView` shell.
5. Add the address-bar buttons, View menu item, shortcut, and preference.
6. Add the site-rule schema, the bundled baseline, and runtime delivery from
   the phi-reader-rules repository.
7. Flip `kPdfTags`, add the phase-two accessibility method, and extend the
   article model to PDFs.
8. Re-point `show-page-reader-mode` at the native toggle.

Steps 1 and 2 are cheap and de-risk everything after them. Steps 3 through 6
require no framework rebuild at all.

## Out of Scope

- OCR for scanned PDFs.
- A reading list or any save-for-later surface. Phi deliberately filters
  Safari's Reading List out of the share menu, and that decision stands.
- Text-to-speech.
- Persisting reader state across sessions.
- Reader View on internal pages and `file://`.
- Replacing Chromium's own Reading Mode side panel.

## Open Questions

- **Remote subresources.** Article images load from their origin inside the
  reader web view, which leaks a request the user may not expect from a
  reading surface. Proxying, blocking, or accepting this needs a decision.
- **Preparation side effects.** Scrolling and activating expansion controls
  mutates the live page. The restore contract needs to be pinned down,
  particularly for pages with infinite scroll.
- **Per-site stickiness.** "Always open this site in Reader View" is what
  drives sustained use, but it needs a preference store and interacts with
  `CrossDomainNewTabNavigationThrottle`. Deferred until the core feature is
  proven.
- **Rule synthesis.** When extraction fails on a domain with no rule, a model
  could propose one from the DOM skeleton, apply it immediately, and submit it
  as a candidate for review and promotion. This depends on a failure signal
  that only exists once the coverage gate ships.
- **Coverage floor.** The ratio that separates a truncated extraction from a
  short article must be derived from the fixture corpus, not guessed.

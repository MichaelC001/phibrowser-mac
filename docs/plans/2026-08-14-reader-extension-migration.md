# Reader View as a Phi Extension — Migration Plan

Date: 2026-08-14
Status: implemented, including Phase 5 retirement and the extraction move
(2026-08-17). The extension owns the whole DOM pipeline — probing, site
rules, the extraction ladder and its accept policy — and is the canonical
home of the extraction scripts (phibrowser-mac's `Resources/*.js`, the rule
store, downloader, and bundled rules are deleted). The app reaches that
pipeline over the `reader.extract` bridge RPC: `ReaderExtractionService` is
now a thin facade that relays to the extension and falls back to the native
accessibility-tree path (still framework-only) for markup-defeating pages,
serving the agent API (`agentSpace.readerArticle` / `readerDocument`).
Button offerability is the URL gate + Chromium's distillability verdict +
the extension's probe push; the native CDP probe is gone. Consequences
accepted: without the extension loaded there is no reader surface and no
agent DOM extraction (only the accessibility fallback never triggers —
`reader.extract` times out to `transport_unavailable`), and Debug runs need
`--load-extension` or the embedded copy (`--phi-no-embed-extensions`
removed from the launcher).

What shipped beyond the v1 scaffold:

- **Extraction parity**: the extension vendors the native extraction stack
  byte-identical (`Readability.js`, `Readability-readerable.js`,
  `ReaderProbe.js`, `ReaderExtract.js` from `Resources/`, executed via
  `chrome.scripting.executeScript({files})`), and ports the accept policy
  (coverage floor 0.15, rule exemption, ladder order) from
  `ReaderExtractionService.article(from:)`.
- **Site rules**: the extension mirrors the published phi-reader-rules table
  (same GitHub Pages endpoint, digest short-circuit, 6h/15m staleness) with a
  TS port of `URLPatternMatcher` ranking; a match forces the offer and feeds
  the rule rung.
- **Style sync**: `PhiPreferences.Reader` stays the source of truth via
  `reader.getStyle` / `reader.setStyle` / `reader.styleChanged`
  (`ReaderExtensionBridge`); `chrome.storage.local` is the out-of-shell
  fallback. Full style panel in the reader HUD (theme/typeface/width/
  line-height/spacing/images/links/reset).
- **Read-aloud**: native passage model on `chrome.tts` (highlight + scroll
  sync, play/pause/resume, passage skip, rate cycle). Runtime audio behavior
  not yet manually verified.
- **Failure toasts**: `reader.state` carries the refusal reason; Swift shows
  the native reader's toast strings.
- Known gaps: no lazy-content settle pass (the surface navigates away, so
  there is nothing to settle behind), no PDF path (native-only by design),
  update-server enrollment for the reader CRX still unwired.

## Goal

Move Reader View from the native Swift stack (`ReaderExtractionService`,
`ReaderDocumentBuilder`, `ReaderViewController`, `ReaderStyle`,
`ReaderSpeaker`, `ReaderSiteRuleStore`) into a Phi browser extension living in
`phi-ai/ai-extension/`, shipped and updated like Sidecar/Kensington/Lexington/
Mirage. Native entry points (toolbar button, menu item, keyboard shortcut,
context menu) stay in Swift and drive the extension over the existing
`phinomenonPrivate` message channel.

Why: reader improvements ship via the extension update server without a
browser release; the CDP probe disappears (in-page content script instead);
the reader surface ports for free to the Linux effort; rendering moves into
the real tab (proper history/back semantics) instead of a native WKWebView
overlay.

## Working name

Package `@phi-ai/reader` at `ai-extension/reader/`, embedded resources dir
`phi_reader`, display name "Phi Reader". Rename is trivial before Phase 1
lands if a codename in the kensington/lexington family is preferred.

## Architecture summary

- **Offerability**: MV3 content script (http/https, `document_idle`) runs
  `isProbablyReaderable` (from `@mozilla/readability`, already a dependency of
  Kensington) after load and again on debounced SPA mutations; reports
  `phinomenonPrivate.sendMessageToApp("reader.offerable", {offerable})`.
  Swift ORs this with the existing native signals (Chromium
  `DistillabilityObserver` KVO fast path stays — it feeds the button either
  way). Site rules from `phi-reader-rules` are bundled into the extension and
  force-offer on match.
- **Activation**: Swift broadcasts `reader.open` `{tabId}` via
  `ExtensionMessaging.broadcast` → extension background receives `onAppMessage`
  → `chrome.scripting.executeScript` runs Readability in the page → article
  cached in `chrome.storage.session` keyed by tabId → tab navigates to
  `chrome-extension://<id>/reader.html#<tabId>`. Exit = history back or
  `reader.close` broadcast.
- **Rendering**: `reader.html` ports `ReaderDocumentBuilder`'s HTML/CSS
  (typeface, theme, column width, line height, letter spacing, images toggle,
  font size on the 15–39 step-2 grid). Font size becomes plain CSS instead of
  `pageZoom`. Window theming via the `@phi-ai/window-theme` library (same as
  Mirage).
- **Preferences**: `PhiPreferences.Reader` (native) remains the source of
  truth initially; synced to the extension through `getNativeSettings` /
  `onNativeSettingsChanged`, writes flow back as `reader.setPref` messages.
  Ownership can move to `chrome.storage` later if the native menu no longer
  needs the values.

## Phase 1 — Scaffold (phi-ai)

1. New workspace package `ai-extension/reader/` modeled on Mirage: Vite +
   `@crxjs/vite-plugin`, `crx3` packaging, `tsx scripts/build.ts`,
   `manifest.config.ts` reading `deployment/env/<env>/reader.env`.
2. Generate a signing key (like `kensington/key.pem`) → fixed `key` in the
   manifest → stable extension ID. Add `reader.env` for dev/prod with
   `UPDATE_SERVER_URL` and version wiring.
3. Manifest: MV3; permissions `storage`, `activeTab`, `scripting`, `tabs`,
   `phinomenonPrivate`; `host_permissions: <all_urls>`; content script with
   `exclude_globs: ["chrome-extension://*"]` (M150 sandbox lesson from
   Mirage); `reader.html` as an extension page.
4. Wire into `pnpm-workspace.yaml`, turbo, `scripts/build-all.mjs` (currently
   builds four packages), `ai-extension/README.md`, root `AGENTS.md`
   ownership table. Run the repo's parity checks (`pnpm type-check`, eslint,
   prettier) per its AGENTS.md.

Deliverable: empty-but-loadable extension; `pnpm dev` + `--phi-no-embed-extensions`
+ load-unpacked works in Canary.

## Phase 2 — Feature port (phi-ai)

1. Content-script probe + `reader.offerable` reporting (replaces the CDP
   probe; covers late SPA hydration natively via MutationObserver, replacing
   the 2.5 s retry).
2. Background extraction with Readability; port the sanitization and
   metadata (title, byline, hero image, reading time) currently in
   `ReaderExtractionService` / `ReaderDocumentBuilder`.
3. `reader.html` renderer: port builder CSS, font-size HUD (15–39 pt, step
   2), theme/typeface/width/line-height/letter-spacing/images controls,
   window-theme integration, keyboard handling.
4. Bundle `phi-reader-rules` (build-time import) and apply before the probe.
5. TTS: port `ReaderSpeaker` onto `chrome.tts` with word/sentence event
   highlighting. This is the highest-risk parity item — if event granularity
   on macOS voices is insufficient, ship the extension reader without TTS
   behind the flag and keep the native reader available until resolved.

## Phase 3 — Native integration (phibrowser-mac)

1. Register `reader.offerable` (and `reader.setPref`, `reader.state`) in
   `ExtensionMessageRouter`; validate `senderId` against the reader
   extension's ID.
2. Developer-settings flag "Extension Reader View": routes the
   button/menu/shortcut to `reader.open` broadcast instead of presenting
   `ReaderViewController`. Both paths share the existing `isReaderOfferable`
   state; the extension signal ORs in alongside the native ones.
3. Keep `agentSpace.readerArticle` / `agentSpace.readerDocument` working:
   agents consume native extraction today. Re-route these handlers to request
   extraction from the reader extension background (`reader.extract`
   round-trip) once it is authoritative; until then they keep using the
   native service.
4. Prefs sync plumbing: push `PhiPreferences.Reader` changes through
   `onNativeSettingsChanged` (pattern: `WindowThemeMessageRouter`).

## Phase 4 — Packaging & embedding

1. `pnpm build:all` → `reader-<version>.crx` aggregated in
   `ai-extension/crx/`; register the extension with
   `extension-update-server` / `extension-updater` (verify how IDs are
   enrolled there — likely env/config on the worker).
2. Embed in the framework: `python3 tools/phi/generate_extension_grdp.py
   reader <crx>` → `chrome/browser/resources/phi_reader/` + grdp; add
   `IDR_PHI_READER_MANIFEST` include to `browser_resources.grd`; add the
   `Add(...)` entry in `ComponentLoader::AddPhiExtensions()`
   (`component_loader.cc:393`). Rebuild `Phi Framework.framework`.

## Phase 5 — Verification & retirement

1. Build both repos; manual matrix on Canary: long articles, short articles
   (probe-only), site-rule pages, hydrating SPAs, back/forward, tab restore
   with reader open, pinned tabs, incognito, theme switching, font prefs
   persistence across native/extension boundary.
2. Session-restore hardening: `reader.html` restored after browser restart
   has no cached article — it must redirect to the source URL embedded in its
   fragment (same failure mode Chrome's `chrome-distiller://` handles).
3. Bake behind the flag on Canary; flip default; after a stable cycle delete
   the native stack (`ReaderViewController`, `ReaderDocumentBuilder`,
   `ReaderStyle`, `ReaderSpeaker`, CDP probe in `ReaderExtractionService`,
   `ReaderSiteRuleStore`) and the reader mocks in tests. The Chromium
   `DistillabilityObserver` bridge stays.

## Open decisions

- Final extension name/codename.
- TTS: `chrome.tts` port vs. temporary feature drop vs. keeping a slim native
  speaker driven by messaging.
- Long-term prefs ownership (native vs. `chrome.storage`).
- Whether `reader.html` should also be reachable without native chrome
  (extension action button) for Linux parity testing.

## Out of scope

- PDFs and `file://` pages (unchanged: not offered).
- Any change to the Chromium-side distillability signal shipped in
  151c1ba395a.

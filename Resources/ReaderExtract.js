// Reader View in-page extraction.
//
// Evaluated in the target page through the app-owned CDP session. Readability
// is concatenated ahead of this file by ReaderExtractionService, so
// `Readability` is in scope here.
//
// Returns a Promise so the preparation step can wait for lazy content. The
// caller evaluates with awaitPromise + returnByValue, so everything returned
// must be JSON-serialisable.
//
// The contract with Swift: never throw. Every failure path resolves to
// { ok: false, reason }, because a rejected promise loses the reason.

(function () {
  "use strict";

  var MIN_TEXT_LENGTH = 200;
  // A rule names the content explicitly, so the bar it has to clear is much
  // lower: the 200 above protects the generic rungs from serving a nav column
  // as an article, and a rule needs no such protection — it is already a
  // person's assertion about one site, which is the same reason a rule is
  // exempt from the coverage floor. A Notion page holding a short to-do table
  // is 191 characters, and refusing it taught nobody anything.
  var MIN_RULE_TEXT_LENGTH = 40;
  var SCROLL_SETTLE_MS = 120;
  var CONTENT_POLL_MS = 100;
  var LADDER_RETRY_MS = 700;
  var LADDER_RETRIES = 2;
  var MAX_SCROLL_STEPS = 12;
  var HIDDEN_MARK = "data-phi-reader-hidden";
  var SPACER_MARK = "data-phi-reader-spacer";

  function nowMs() {
    return new Date().getTime();
  }

  function sleep(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  // A PDF renders through the plugin, so there is no article DOM to score.
  // Swift reads this and goes straight to the accessibility path.
  function isPDFViewer() {
    try {
      if ((document.contentType || "").toLowerCase() === "application/pdf") {
        return true;
      }
      return !!document.querySelector(
        'embed[type="application/pdf"], object[type="application/pdf"]');
    } catch (e) {
      return false;
    }
  }

  // The denominator of every rung's coverage: the text a reader can actually
  // see. `innerText` on the live body is layout-aware, so hidden text is
  // already excluded here — it is the numerator that has to be made to match,
  // which `markHiddenElements` does.
  function visibleTextLength() {
    var body = document.body;
    if (!body) {
      return 0;
    }
    var text = body.innerText || "";
    return text.replace(/\s+/g, " ").trim().length;
  }

  function innerTextLength(node) {
    if (!node) {
      return 0;
    }
    var text = node.innerText || node.textContent || "";
    return text.replace(/\s+/g, " ").trim().length;
  }

  function linkDensity(node) {
    var total = innerTextLength(node);
    if (total === 0) {
      return 1;
    }
    var linked = 0;
    var anchors = node.querySelectorAll("a");
    for (var i = 0; i < anchors.length; i++) {
      linked += innerTextLength(anchors[i]);
    }
    return Math.min(1, linked / total);
  }

  // --- Preparation ----------------------------------------------------------
  // Runs against the live page, so anything moved must be put back. Scroll
  // position is captured before and restored in a finally.

  function expandDetails() {
    var opened = 0;
    var items = document.querySelectorAll("details:not([open])");
    for (var i = 0; i < items.length; i++) {
      try {
        items[i].open = true;
        opened++;
      } catch (e) {
        /* element refused; skip */
      }
    }
    return opened;
  }

  function activateExpanders(selectors) {
    if (!selectors || !selectors.length) {
      return 0;
    }
    var clicked = 0;
    for (var i = 0; i < selectors.length; i++) {
      var nodes;
      try {
        nodes = document.querySelectorAll(selectors[i]);
      } catch (e) {
        continue; // invalid selector in a rule must not abort preparation
      }
      for (var j = 0; j < nodes.length; j++) {
        try {
          nodes[j].click();
          clicked++;
        } catch (e) {
          /* not clickable; skip */
        }
      }
    }
    return clicked;
  }

  // Walks down the page a viewport at a time rather than jumping straight to
  // the bottom. Nearly every lazy-loader is driven by IntersectionObserver,
  // and an element that is skipped over never intersects, so a single jump
  // leaves the middle of a long article holding placeholder images.
  //
  // This is the one part of preparation the user can see, and the only part
  // that needs the page to be rendering: it works by making content intersect
  // the viewport, and a hidden page runs no lifecycle updates for an
  // IntersectionObserver to fire from. Measured on a Medium post: walking it
  // while visible takes it from 5 images to 30; walking it while it is a
  // background tab changes nothing at all.
  //
  // So the reader opens on a first pass that skips this, and the walk runs
  // afterwards on the second pass, with the page deliberately left mounted
  // (and therefore rendering) behind the reader surface. See
  // BrowserState.settleLazyContent(for:).
  function settleLazyContent(deadlineMs) {
    var step = 0;
    var offset = 0;
    var viewport = Math.max(window.innerHeight || 0, 400);

    function iterate() {
      var height = document.documentElement.scrollHeight;
      if (step >= MAX_SCROLL_STEPS || nowMs() > deadlineMs || offset >= height) {
        return Promise.resolve();
      }
      step++;
      offset += viewport;
      window.scrollTo(0, Math.min(offset, height));
      return sleep(SCROLL_SETTLE_MS).then(iterate);
    }

    return iterate();
  }

  // The reader button is reachable the instant a page paints, long before the
  // page's own lazy-loader has swapped its placeholder images for real ones
  // and, on a slow site, before the article is even in the DOM. Extracting at
  // that moment yields a truncated article full of placeholders, and the
  // truncation then falls under the coverage floor, which sends the request
  // down the accessibility fallback: several more seconds, and figures that
  // render as captions instead of images. Waiting for load costs far less
  // than any of that, and costs nothing at all on a page already loaded.
  function awaitLoadEvent(budgetMs) {
    if (document.readyState === "complete" || budgetMs <= 0) {
      return Promise.resolve(document.readyState);
    }
    return new Promise(function (resolve) {
      var settled = false;
      function finish() {
        if (settled) {
          return;
        }
        settled = true;
        window.removeEventListener("load", finish);
        resolve(document.readyState);
      }
      window.addEventListener("load", finish);
      setTimeout(finish, budgetMs);
    });
  }

  // `load` means the initial document and its subresources are done, which on
  // a client-rendered page happens before the article exists. Extracting then
  // reads a shell, every rung declines, and the caller falls through to the
  // accessibility tree — which on an HTML page returns a handful of captions.
  //
  // This only catches a document that is still completely empty. A shell with
  // chrome in it clears any plausible threshold — Medium's nav, tag row and
  // sign-in prompts do on their own — and waiting for the text to stop growing
  // does not help either, because a shell that pauses before mounting reads as
  // settled. The case where the chrome is present but the article is not is
  // handled after the fact, by retrying the ladder (see extractNow).
  function awaitContent(deadlineMs) {
    // Only asking whether the document is still empty, so `textContent` is
    // both cheaper than the layout-aware measure and the right question.
    var length = (document.body.textContent || "").trim().length;
    if (length >= MIN_TEXT_LENGTH || nowMs() >= deadlineMs) {
      return Promise.resolve();
    }
    return sleep(CONTENT_POLL_MS).then(function () {
      return awaitContent(deadlineMs);
    });
  }

  // Hidden text is the numerator's half of the coverage problem.
  //
  // A rung measures its own output on a detached container, where `innerText`
  // has no layout to consult and counts text the page never showed: collapsed
  // Stack Overflow answers, `display:none` menus, screen-reader-only labels.
  // The denominator counts only visible text, so the ratio was between two
  // different quantities — a Stack Overflow question scored 3.4, more text
  // than the page was credited with having, and a rung that swallowed hidden
  // content outscored one that isolated the article.
  //
  // Marking hidden elements here, before any rung clones the document, lets
  // the clones carry the mark so `finishInto` can drop them. That makes the
  // numerator visible-only, and takes text out of the reader that was never
  // on the page to begin with.
  //
  // Reads are done before any write: setting an attribute dirties layout, so
  // interleaving would force a reflow per element.
  function markHiddenElements() {
    var hidden = [];
    // `querySelectorAll` stops at a shadow boundary, but the extraction does
    // not: shadow content is inlined into the clone, so it has to be examined
    // here too or its hidden parts count toward the numerator and not the
    // denominator.
    var all = [];
    var roots = [document.body];
    while (roots.length) {
      var root = roots.pop();
      var found = root.querySelectorAll("*");
      for (var f = 0; f < found.length; f++) {
        all.push(found[f]);
        if (found[f].shadowRoot) {
          roots.push(found[f].shadowRoot);
        }
      }
    }
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      if (el.getClientRects().length !== 0) {
        continue;
      }
      // `display: contents` produces no box of its own while its children
      // render normally. Removing one would take visible content with it.
      var rendersThroughChildren = false;
      for (var c = 0; c < el.children.length; c++) {
        if (el.children[c].getClientRects().length !== 0) {
          rendersThroughChildren = true;
          break;
        }
      }
      if (!rendersThroughChildren) {
        hidden.push(el);
      }
    }
    for (var j = 0; j < hidden.length; j++) {
      hidden[j].setAttribute(HIDDEN_MARK, "");
    }
    return hidden;
  }

  // A lazy-loader paints a stand-in until it swaps in the real file, and the
  // stand-in is not always recognisable from its URL. `isPlaceholderSrc` reads
  // a data: URI as one only when it is short, on the reasoning that a 1x1 GIF
  // is about seventy characters — but WeChat inlines a 475-character SVG that
  // declares itself 1px by 1px, so twelve of fourteen images on an article
  // came through as blanks with their real URLs sitting unread in data-src.
  //
  // What is unambiguous is the decoded size: a stand-in is a pixel or two.
  // That can only be measured on the live element, because a detached clone
  // never loads, so it is marked here and read back after cloning.
  function markSpacerImages() {
    var marked = [];
    var images = document.querySelectorAll("img");
    for (var i = 0; i < images.length; i++) {
      var image = images[i];
      // naturalWidth is 0 while an image is still loading or broken, which is
      // not evidence either way; only a decoded pixel or two is.
      if (image.naturalWidth > 0 && image.naturalWidth <= 2 &&
          image.naturalHeight > 0 && image.naturalHeight <= 2) {
        image.setAttribute(SPACER_MARK, "");
        marked.push(image);
      }
    }
    return marked;
  }

  function unmarkSpacerImages(marked) {
    for (var i = 0; i < marked.length; i++) {
      marked[i].removeAttribute(SPACER_MARK);
    }
  }

  function unmarkHiddenElements(marked) {
    for (var i = 0; i < marked.length; i++) {
      marked[i].removeAttribute(HIDDEN_MARK);
    }
  }

  // `settleLazy` is what separates the two passes. Expanding sections and
  // clicking a rule's expanders are instant and invisible, so they happen on
  // every pass; walking the page is neither, so it is opt-in.
  function prepare(rule, deadlineMs, settleLazy) {
    var originalX = window.scrollX;
    var originalY = window.scrollY;
    var report = { detailsOpened: 0, expandersClicked: 0, settledLazy: !!settleLazy };
    try {
      report.detailsOpened = expandDetails();
      report.expandersClicked = activateExpanders(rule && rule.expand);
    } catch (e) {
      /* preparation is best effort */
    }
    if (!settleLazy) {
      return Promise.resolve(report);
    }
    return settleLazyContent(deadlineMs)
      .catch(function () {
        /* ignore */
      })
      .then(function () {
        window.scrollTo(originalX, originalY);
        return report;
      });
  }

  // --- Cloning --------------------------------------------------------------

  // `cloneNode` does not copy a shadow root, so a component that renders its
  // content in one clones as an empty tag and the content is silently lost.
  // MDN puts every code sample in an `<mdn-code-example>` whose light DOM is
  // empty, so a reference page came out with all twelve samples missing and
  // nothing to indicate anything had gone.
  //
  // Only components whose light DOM is empty are inlined. A shadow tree that
  // projects light content through `<slot>` would otherwise have that content
  // counted twice — once where it really is, once where the slot placed it —
  // and an empty light DOM rules that out by construction.
  function cloneWithShadowContent(source) {
    var clone = source.cloneNode(true);
    inlineShadowRoots(source, clone);
    return clone;
  }

  function inlineShadowRoots(source, clone) {
    var sources = [source];
    var clones = [clone];

    while (sources.length) {
      var s = sources.pop();
      var c = clones.pop();
      if (!s || !c) {
        continue;
      }
      if (s.shadowRoot && s.children.length === 0 &&
          !(s.textContent || "").trim()) {
        var shadowChildren = s.shadowRoot.children;
        for (var i = 0; i < shadowChildren.length; i++) {
          try {
            c.appendChild(cloneWithShadowContent(shadowChildren[i]));
          } catch (e) {
            /* a component that refuses to clone is skipped, not fatal */
          }
        }
        continue;
      }
      // cloneNode produces a structurally identical tree, so children line up
      // by index.
      var sourceChildren = s.children;
      var cloneChildren = c.children;
      for (var j = 0; j < sourceChildren.length && j < cloneChildren.length; j++) {
        sources.push(sourceChildren[j]);
        clones.push(cloneChildren[j]);
      }
    }
  }

  // --- Sanitising -----------------------------------------------------------
  // The reader web view runs with scripting disabled, so this is defence in
  // depth rather than the only barrier.

  var STRIP_TAGS = ["script", "style", "noscript", "iframe", "object", "embed", "form", "input", "button"];

  // An icon the page has already declared is not content: `aria-hidden` means
  // a screen reader skips it, and the reader is in the same position. Notion
  // hangs three of them off a plain table for adding rows and columns.
  //
  // Size-gated, because `aria-hidden` alone would take real content with it:
  // MathJax marks the SVG of every formula hidden and puts the accessible
  // copy in a sibling element, so an unqualified sweep would delete the
  // equations from a paper. An icon's viewBox is a small square; a rendered
  // formula's is hundreds of units wide.
  var MAX_ICON_VIEWBOX = 64;

  function isDecorativeIcon(svg) {
    if (svg.getAttribute("aria-hidden") !== "true" &&
        svg.getAttribute("role") !== "presentation") {
      return false;
    }
    var box = (svg.getAttribute("viewBox") || "").split(/[\s,]+/);
    if (box.length !== 4) {
      // No viewBox to judge by. An icon is the overwhelmingly common case for
      // an inline SVG the page has hidden from assistive technology.
      return true;
    }
    return parseFloat(box[2]) <= MAX_ICON_VIEWBOX &&
           parseFloat(box[3]) <= MAX_ICON_VIEWBOX;
  }

  // An inline SVG with a viewBox and no width or height has no intrinsic size:
  // on the page a stylesheet gives it one, and the reader does not load the
  // page's stylesheet, so it expands to the full width of its column. A 16×16
  // plus icon arrived as a plus the size of the article. The viewBox already
  // says how big it means to be, so use that.
  function sizeUnboundedSVGs(container) {
    var svgs = container.querySelectorAll("svg");
    for (var i = 0; i < svgs.length; i++) {
      var svg = svgs[i];
      if (svg.hasAttribute("width") || svg.hasAttribute("height")) {
        continue;
      }
      var box = (svg.getAttribute("viewBox") || "").split(/[\s,]+/);
      if (box.length !== 4) {
        continue;
      }
      var width = parseFloat(box[2]);
      var height = parseFloat(box[3]);
      if (!(width > 0) || !(height > 0)) {
        continue;
      }
      svg.setAttribute("width", String(width));
      svg.setAttribute("height", String(height));
    }
    return container;
  }

  function sanitizeInto(container) {
    for (var i = 0; i < STRIP_TAGS.length; i++) {
      var nodes = container.querySelectorAll(STRIP_TAGS[i]);
      for (var j = 0; j < nodes.length; j++) {
        nodes[j].parentNode && nodes[j].parentNode.removeChild(nodes[j]);
      }
    }
    var icons = container.querySelectorAll("svg");
    for (var n = icons.length - 1; n >= 0; n--) {
      if (isDecorativeIcon(icons[n]) && icons[n].parentNode) {
        icons[n].parentNode.removeChild(icons[n]);
      }
    }
    sizeUnboundedSVGs(container);
    var all = container.querySelectorAll("*");
    for (var k = 0; k < all.length; k++) {
      var el = all[k];
      var attrs = el.attributes;
      for (var a = attrs.length - 1; a >= 0; a--) {
        var name = attrs[a].name;
        var value = attrs[a].value || "";
        if (name.slice(0, 2).toLowerCase() === "on") {
          el.removeAttribute(name);
          continue;
        }
        // The reader re-presents content in its own typography, so the site's
        // inline styling is not just redundant, it actively fights it: a
        // Notion table cell carries `border: 1px solid var(--c-borPri)`, and
        // that variable does not exist here, so every border resolves to
        // nothing and the table renders as drifting columns. The same styles
        // pin widths, positions and colours to a layout the reader has thrown
        // away. Meaning that lives in a tag — strong, em, headings, lists —
        // survives untouched; only the appearance goes.
        if (name === "style") {
          el.removeAttribute(name);
          continue;
        }
        if ((name === "href" || name === "src") &&
            value.replace(/\s/g, "").slice(0, 11).toLowerCase() === "javascript:") {
          el.removeAttribute(name);
        }
      }
    }
    return container;
  }

  var LAZY_SRC_ATTRIBUTES = [
    "data-src", "data-original", "data-lazy-src", "data-lazy",
    "data-echo", "data-hi-res-src", "data-full-src",
  ];
  var LAZY_SRCSET_ATTRIBUTES = ["data-srcset", "data-lazy-srcset", "srcset"];

  var PLACEHOLDER_NAME_PATTERN =
    /\b(blank|spacer|placeholder|transparent|lazy|loading|dummy|grey|gray)[-_.]?\w*\.(gif|png|jpe?g|svg|webp)/i;

  // A lazy-loader paints a stand-in until it swaps in the real file, so an
  // untouched `src` is not evidence of a usable image. The stand-in is either
  // a tiny inline data URI or a file named for the job. Real inline images
  // exist too — MathJax output, small diagrams — so length, not the `data:`
  // scheme, is what separates them: a 1x1 GIF is about 70 characters.
  function isPlaceholderSrc(src) {
    if (!src) {
      return true;
    }
    if (src.slice(0, 5).toLowerCase() === "data:") {
      return src.length < 256;
    }
    return PLACEHOLDER_NAME_PATTERN.test(src);
  }

  // Picks the widest candidate. The reader throws the page's responsive
  // layout away, so there is nothing left to select against.
  function largestFromSrcSet(value) {
    if (!value) {
      return null;
    }
    var best = null;
    var bestWidth = -1;
    var candidates = value.split(",");
    for (var i = 0; i < candidates.length; i++) {
      var parts = candidates[i].trim().split(/\s+/);
      if (!parts[0]) {
        continue;
      }
      var width = 0;
      var descriptor = parts[1] ? /^(\d+(?:\.\d+)?)([wx])$/.exec(parts[1]) : null;
      if (descriptor) {
        // Density descriptors have no pixel width; scale them so a 2x beats a
        // 1x without ever outranking a real width.
        width = parseFloat(descriptor[1]) * (descriptor[2] === "x" ? 100 : 1);
      }
      if (width >= bestWidth) {
        bestWidth = width;
        best = parts[0];
      }
    }
    return best;
  }

  function realSourceFor(element) {
    for (var i = 0; i < LAZY_SRC_ATTRIBUTES.length; i++) {
      var value = element.getAttribute(LAZY_SRC_ATTRIBUTES[i]);
      if (value && !isPlaceholderSrc(value)) {
        return value;
      }
    }
    for (var j = 0; j < LAZY_SRCSET_ATTRIBUTES.length; j++) {
      var best = largestFromSrcSet(element.getAttribute(LAZY_SRCSET_ATTRIBUTES[j]));
      if (best && !isPlaceholderSrc(best)) {
        return best;
      }
    }
    return null;
  }

  // Resolves relative URLs against the document so the reader document, which
  // has a different base, still loads images and links correctly.
  function absolutizeInto(container) {
    // <picture> keeps its real candidates on <source>, which is useless once
    // the layout is gone. Fold the best one onto the <img> and drop the rest.
    var pictures = container.querySelectorAll("picture");
    for (var p = 0; p < pictures.length; p++) {
      var picture = pictures[p];
      var pictureImg = picture.querySelector("img");
      var sources = picture.querySelectorAll("source");
      if (pictureImg && !realSourceFor(pictureImg) &&
          isPlaceholderSrc(pictureImg.getAttribute("src"))) {
        for (var s = 0; s < sources.length; s++) {
          var candidate = realSourceFor(sources[s]);
          if (candidate) {
            pictureImg.setAttribute("src", candidate);
            break;
          }
        }
      }
      for (var r = sources.length - 1; r >= 0; r--) {
        sources[r].parentNode && sources[r].parentNode.removeChild(sources[r]);
      }
    }

    var images = container.querySelectorAll("img");
    for (var i = 0; i < images.length; i++) {
      var img = images[i];
      // Set on the live DOM before any rung cloned; see markSpacerImages.
      var isSpacer = img.hasAttribute(SPACER_MARK);
      img.removeAttribute(SPACER_MARK);
      var src = img.getAttribute("src");
      if (isSpacer || isPlaceholderSrc(src)) {
        var real = realSourceFor(img);
        if (real) {
          src = real;
          isSpacer = false;
        }
      }
      // `srcset` does not survive the move to a document with a different
      // base and no scripting, and keeps the browser guessing after src is
      // settled.
      img.removeAttribute("srcset");
      // The reader document refetches every image through WebKit's network
      // stack, which shares nothing with the copy Chromium already has, so an
      // image-heavy article pays for the whole set again. Deferring the ones
      // below the fold turns that back into the handful actually on screen.
      // Native lazy loading needs no scripting, so it works in this document.
      img.setAttribute("loading", "lazy");
      if (isSpacer || isPlaceholderSrc(src)) {
        // Nothing usable. A broken-image glyph reads worse than no figure,
        // and a stand-in with no real source behind it is a tracking pixel.
        img.parentNode && img.parentNode.removeChild(img);
        continue;
      }
      try {
        img.setAttribute("src", new URL(src, document.baseURI).href);
      } catch (e) {
        img.parentNode && img.parentNode.removeChild(img);
      }
    }
    var links = container.querySelectorAll("a[href]");
    for (var j = 0; j < links.length; j++) {
      try {
        links[j].setAttribute(
          "href", new URL(links[j].getAttribute("href"), document.baseURI).href);
      } catch (e) {
        links[j].removeAttribute("href");
      }
    }
    return container;
  }

  // Page furniture that is never part of the article, even when a scoring pass
  // has already swept it into the content root.
  //
  // Landmarks and ARIA roles first, because those survive on modern markup
  // where class names carry no meaning. Comment threads and article-to-article
  // navigation are the exception: they are still conventionally named, and
  // they are the boilerplate most likely to sit *inside* the content
  // container rather than beside it.
  var BOILERPLATE_SELECTORS = [
    "nav", "aside", "footer",
    "[role=navigation]", "[role=complementary]", "[role=contentinfo]",
    "[role=banner]", "[role=search]", "[role=form]",
  ];

  // Split out from the pattern below because on a thread it is not
  // boilerplate at all — it is the content. Reddit names the element holding a
  // comment's text `…-comment-rtjson-content`, so stripping by name deleted
  // every comment body on the page and left a column of bylines.
  var DISCUSSION_NAME_PATTERN =
    /(^|[-_\s])(comments?|commentlist|disqus|respond|trackback|pingback)([-_\s]|$)/i;

  var BOILERPLATE_NAME_PATTERN =
    /(^|[-_\s])(breadcrumbs?|pagination|prev-?next|post-?nav|nav-?(links?|below|above)|related(-?posts?)?|recirc|share|social|sidebar)([-_\s]|$)/i;

  function stripBoilerplate(container, keepDiscussion) {
    for (var i = 0; i < BOILERPLATE_SELECTORS.length; i++) {
      var matches;
      try {
        matches = container.querySelectorAll(BOILERPLATE_SELECTORS[i]);
      } catch (e) {
        continue;
      }
      for (var j = 0; j < matches.length; j++) {
        matches[j].parentNode && matches[j].parentNode.removeChild(matches[j]);
      }
    }

    var all = container.querySelectorAll("[id], [class]");
    for (var k = 0; k < all.length; k++) {
      var el = all[k];
      // className is not a string on SVG elements.
      var name = (el.id || "") + " " +
        (typeof el.className === "string" ? el.className : "");
      if (BOILERPLATE_NAME_PATTERN.test(name) ||
          (!keepDiscussion && DISCUSSION_NAME_PATTERN.test(name))) {
        el.parentNode && el.parentNode.removeChild(el);
      }
    }
    return container;
  }

  // Notion builds a database view out of divs, the same way it builds code
  // blocks, so a table arrives as a run of text: "待办事项 New Name Tags Created
  // time 20天足跟血 March 13, 2023 20:07 …" with the columns gone. Reissuing it
  // as a real table restores the grid and picks up the table styling the
  // reader already has, including the horizontal scroll a wide one needs.
  //
  // Only the header cells and the row cells are carried over, which also drops
  // the view's toolbar — the "New" button was being read as content.
  //
  // Columns without rows still count as a table. A database that has been set
  // up but not filled in has header cells and nothing else, and bailing on it
  // left the reader showing the chrome as a sentence: "New Name Number
  // Checkbox New page", the toolbar button and the add-row button either side
  // of the column names. An empty grid says what the page says.
  function reissueNotionTables(container) {
    var blocks = container.querySelectorAll(".notion-collection_view-block");
    for (var i = 0; i < blocks.length; i++) {
      var block = blocks[i];
      var rows = block.querySelectorAll(".notion-table-view-row");
      var headers = block.querySelectorAll(".notion-table-view-header-cell");
      if ((!rows.length && !headers.length) || !block.parentNode) {
        continue;
      }
      var doc = block.ownerDocument;
      var table = doc.createElement("table");

      if (headers.length) {
        var head = doc.createElement("thead");
        var headRow = doc.createElement("tr");
        for (var h = 0; h < headers.length; h++) {
          var th = doc.createElement("th");
          th.textContent = (headers[h].textContent || "").trim();
          headRow.appendChild(th);
        }
        head.appendChild(headRow);
        table.appendChild(head);
      }

      var body = doc.createElement("tbody");
      for (var r = 0; r < rows.length; r++) {
        var cells = rows[r].querySelectorAll("[data-col-index]");
        if (!cells.length) {
          continue;
        }
        var row = doc.createElement("tr");
        for (var c = 0; c < cells.length; c++) {
          var td = doc.createElement("td");
          td.textContent = (cells[c].textContent || "").trim();
          row.appendChild(td);
        }
        body.appendChild(row);
      }
      if (body.childNodes.length) {
        table.appendChild(body);
      }
      // Nothing recognisable inside: leave the block alone rather than
      // replacing it with an empty element.
      if (!table.childNodes.length) {
        continue;
      }
      block.parentNode.replaceChild(table, block);
    }
    return container;
  }

  // --- Legacy markup ----------------------------------------------------------
  // Pre-CSS pages write an article as one run of text: paragraphs separated by
  // `<br><br>` rather than marked as paragraphs, and typography set with
  // `<font>` rather than a stylesheet. Readability normalises both before it
  // scores a page, so only its own rung ever benefited — a rule or structural
  // extraction handed the reader the raw markup.
  //
  // That looked close enough while reading, which is why it went unnoticed:
  // `<br><br>` leaves a gap where a paragraph break belongs. But the article
  // had no block structure at all, and everything that thinks in blocks then
  // had one block to think about. Reading paulgraham.com aloud found a single
  // passage — the title — and stopped there, with thirteen thousand characters
  // of essay below it in no element of their own.

  // Elements that hold text without being a block of their own. A run of these
  // between two paragraph breaks is what becomes a paragraph.
  var INLINE_TAGS = {
    A: 1, ABBR: 1, B: 1, BDI: 1, BDO: 1, BIG: 1, BR: 1, CITE: 1, CODE: 1,
    DATA: 1, DEL: 1, DFN: 1, EM: 1, FONT: 1, I: 1, IMG: 1, INS: 1, KBD: 1,
    LABEL: 1, MARK: 1, NOBR: 1, Q: 1, RUBY: 1, S: 1, SAMP: 1, SMALL: 1,
    SPAN: 1, STRIKE: 1, STRONG: 1, SUB: 1, SUP: 1, TIME: 1, TT: 1, U: 1,
    VAR: 1, WBR: 1
  };

  // Inline only if everything inside it is too: a link wrapping a card is a
  // block whatever the tag says, and wrapping it in a paragraph would put a
  // block inside a `p` for the reader's parser to tear apart again.
  function isInlineNode(node) {
    if (node.nodeType !== 1) {
      // Text, and comments, which carry nothing and so end nothing.
      return true;
    }
    if (!INLINE_TAGS[node.tagName]) {
      return false;
    }
    for (var i = 0; i < node.childNodes.length; i++) {
      if (!isInlineNode(node.childNodes[i])) {
        return false;
      }
    }
    return true;
  }

  function isBlankText(node) {
    return node.nodeType === 3 && !/\S/.test(node.nodeValue || "");
  }

  function depthOf(node) {
    var depth = 0;
    while (node) {
      node = node.parentNode;
      depth++;
    }
    return depth;
  }

  function hasSpeakableContent(nodes) {
    for (var i = 0; i < nodes.length; i++) {
      if (!isBlankText(nodes[i]) && nodes[i].nodeName !== "BR") {
        return true;
      }
    }
    return false;
  }

  // Rewrites one element's children, making every run of two or more `<br>` a
  // paragraph boundary. A lone `<br>` is left where it is: that is a line
  // break inside a paragraph — an address, a verse — not the end of one.
  function paragraphizeChildren(parent) {
    var doc = parent.ownerDocument;
    var source = [];
    for (var i = 0; i < parent.childNodes.length; i++) {
      source.push(parent.childNodes[i]);
    }

    var output = [];       // paragraphs, as arrays of nodes, and passed-through blocks
    var buffer = [];       // the paragraph being gathered
    var run = [];          // the break candidates seen since the last real node
    var breaks = 0;        // how many of them were `<br>`
    var boundaries = 0;    // runs that turned out to be paragraph breaks

    function flush() {
      if (!hasSpeakableContent(buffer)) {
        buffer = [];
        return;
      }
      output.push(buffer);
      buffer = [];
    }

    // A run of two or more breaks ends the paragraph and is dropped with it;
    // anything shorter was never a boundary, so it belongs to the text.
    function resolveRun() {
      if (breaks >= 2) {
        boundaries++;
        flush();
      } else {
        buffer = buffer.concat(run);
      }
      run = [];
      breaks = 0;
    }

    for (var s = 0; s < source.length; s++) {
      var node = source[s];
      if (node.nodeName === "BR") {
        run.push(node);
        breaks++;
        continue;
      }
      // Whitespace between two breaks is part of the gap, not of the text.
      if (run.length && isBlankText(node)) {
        run.push(node);
        continue;
      }
      resolveRun();
      if (isInlineNode(node)) {
        buffer.push(node);
        continue;
      }
      flush();
      output.push(node);
    }
    resolveRun();
    flush();

    // Nothing here was a paragraph break — the breaks are all line breaks
    // inside one. Leave the markup as the page wrote it.
    if (!boundaries) {
      return;
    }
    // Appending moves each node out of the parent, so what is left behind
    // afterwards is exactly the breaks and the whitespace around them.
    var rebuilt = doc.createDocumentFragment();
    for (var o = 0; o < output.length; o++) {
      if (!Array.isArray(output[o])) {
        rebuilt.appendChild(output[o]);
        continue;
      }
      var block = doc.createElement("p");
      for (var n = 0; n < output[o].length; n++) {
        block.appendChild(output[o][n]);
      }
      rebuilt.appendChild(block);
    }

    // A paragraph that turns out to hold several is *replaced* by them rather
    // than filled with them. `p` inside `p` does not survive the round trip
    // through the reader's parser, and nesting divisions instead would leave
    // the text in an element nothing downstream treats as prose — read aloud
    // would skip the whole passage, which is the bug this pass exists to fix.
    if (parent.tagName === "P" && parent.parentNode) {
      parent.parentNode.replaceChild(rebuilt, parent);
      return;
    }
    while (parent.firstChild) {
      parent.removeChild(parent.firstChild);
    }
    parent.appendChild(rebuilt);
  }

  function normalizeLegacyMarkup(container) {
    // Collected before anything moves: paragraphizing rewrites the children of
    // each parent, which invalidates a live list part way through.
    var brs = container.querySelectorAll("br");
    var parents = [];
    for (var i = 0; i < brs.length; i++) {
      var parent = brs[i].parentNode;
      // Preformatted text keeps its own line breaks. Nothing in it is a
      // paragraph boundary.
      if (!parent || parents.indexOf(parent) >= 0 || parent.closest("pre")) {
        continue;
      }
      parents.push(parent);
    }
    // Innermost first. A `<font>` full of `<br><br>` is inline until its own
    // paragraphs exist; grouped the other way round, the enclosing cell would
    // wrap the whole essay in one paragraph and then fill it with more,
    // leaving `p` inside `p` for the reader's parser to pull apart again.
    parents.sort(function (a, b) { return depthOf(b) - depthOf(a); });
    for (var p = 0; p < parents.length; p++) {
      paragraphizeChildren(parents[p]);
    }

    // `<font>` is a stylesheet written into the markup, and the reader has its
    // own — the same reason `style` attributes go in `sanitizeInto`. Left in
    // place it wins over both reading-style controls on these pages: the essay
    // stayed 13px Verdana whatever typeface or text size was chosen.
    var fonts = container.querySelectorAll("font");
    for (var f = 0; f < fonts.length; f++) {
      var font = fonts[f];
      var span = container.ownerDocument.createElement("span");
      while (font.firstChild) {
        span.appendChild(font.firstChild);
      }
      font.parentNode && font.parentNode.replaceChild(span, font);
    }
    return container;
  }

  // Mutates the container into its final form. Callers measure it *after*
  // this rather than before: boilerplate stripping, script removal and
  // sanitising all take text out, so a length taken first counts words the
  // reader will never show and inflates the rung's coverage against the other
  // rungs and against the floor.
  function finishInto(container, keepDiscussion) {
    var hidden = container.querySelectorAll("[" + HIDDEN_MARK + "]");
    for (var h = 0; h < hidden.length; h++) {
      hidden[h].parentNode && hidden[h].parentNode.removeChild(hidden[h]);
    }
    // Before boilerplate stripping, so the grid is a table by the time
    // anything else looks at it.
    reissueNotionTables(container);
    stripBoilerplate(container, keepDiscussion);
    // After stripping, so furniture is gone before the prose is grouped, and
    // before sanitising, which scrubs attributes off whatever shape is left.
    normalizeLegacyMarkup(container);
    absolutizeInto(container);
    sanitizeInto(container);
    return container;
  }

  // Indexes the code blocks and returns their text, so the reader can offer a
  // copy control for each one.
  //
  // The text has to be taken here, from a DOM, rather than recovered from the
  // markup later: syntax highlighting shreds a sample into dozens of nested
  // spans, and reconstructing it by stripping tags and decoding entities would
  // put subtly wrong code on the clipboard, which is worse than offering no
  // button. `textContent` is exactly the sample as written.
  // `pre` is how nearly every article marks a code block, but not the only
  // way. These cover the conventions that appear without one: a block-level
  // `code`, and the wrapper classes the common highlighters emit. A wrapper
  // that does contain a `pre` is left to the `pre`, so a block never gets two
  // controls.
  var CODE_BLOCK_SELECTORS = [
    "pre",
    "code",
    ".highlight", ".codehilite", ".code-block", ".sourceCode",
    // Notion writes every code block as plain divs — the page carries no
    // `pre` and no `code` element at all — so nothing above would find one.
    ".notion-code-block",
    // Feishu/Lark, likewise divs, with the lines split further still.
    ".docx-code-block",
    "[class*=\"language-\"]", "[class*=\"lang-\"]",
  ];

  // An editor may give every line of a block its own element and put no
  // newline anywhere in the text. Feishu writes one `.code-line-wrapper` per
  // line, so `textContent` returns a whole `args.gn` listing as a single
  // run-on line — which fails the line-break test below, and would reach the
  // clipboard as one line if it did not.
  var CODE_LINE_SELECTOR = ".code-line-wrapper";

  // The sample as written, with its lines intact whichever way the page
  // records them.
  function codeBlockText(element) {
    var lines = element.querySelectorAll(CODE_LINE_SELECTOR);
    if (!lines.length) {
      return element.textContent || "";
    }
    var out = [];
    for (var i = 0; i < lines.length; i++) {
      // Feishu terminates each line with a zero-width marker. It is invisible
      // on the page and would be invisible on the clipboard too, where it
      // silently breaks a pasted command.
      out.push((lines[i].textContent || "").replace(/[\u200b\ufeff]/g, ""));
    }
    return out.join("\n");
  }

  function isCodeBlockCandidate(element) {
    var text = codeBlockText(element);
    if (!text.trim()) {
      return false;
    }
    if (element.tagName === "PRE") {
      return true;
    }
    // Anything inside a `pre` is that block's content, not a block.
    if (element.closest("pre")) {
      return false;
    }
    // A wrapper around a `pre` defers to it.
    if (element.querySelector("pre")) {
      return false;
    }
    // Without `pre` semantics the only reliable evidence is a line break.
    //
    // Length is not evidence: technical writing is full of long inline code —
    // `.spec.strategy.rollingUpdate.maxUnavailable` sits mid-sentence in the
    // Kubernetes docs — and a length rule put a floating copy control over
    // five ordinary sentences there while finding no real block. Missing a
    // one-line block that skipped `pre` is the cheaper mistake.
    return text.indexOf("\n") >= 0;
  }

  function indexCodeBlocks(container) {
    var candidates = [];
    var seen = [];
    for (var s = 0; s < CODE_BLOCK_SELECTORS.length; s++) {
      var found;
      try {
        found = container.querySelectorAll(CODE_BLOCK_SELECTORS[s]);
      } catch (e) {
        continue;
      }
      for (var f = 0; f < found.length; f++) {
        if (seen.indexOf(found[f]) < 0 && isCodeBlockCandidate(found[f])) {
          seen.push(found[f]);
          candidates.push(found[f]);
        }
      }
    }

    // Keep the innermost of any nested pair: a highlighter wrapper and the
    // element it wraps are one block to the reader, and the inner one is the
    // code without the toolbar.
    var blocks = candidates.filter(function (element) {
      for (var i = 0; i < candidates.length; i++) {
        if (candidates[i] !== element && element.contains(candidates[i])) {
          return false;
        }
      }
      return true;
    });

    // Back into document order: the selector passes above ran tag by tag.
    blocks.sort(function (a, b) {
      var relation = a.compareDocumentPosition(b);
      if (relation & Node.DOCUMENT_POSITION_FOLLOWING) { return -1; }
      if (relation & Node.DOCUMENT_POSITION_PRECEDING) { return 1; }
      return 0;
    });

    var texts = [];
    for (var i = 0; i < blocks.length; i++) {
      var text = codeBlockText(blocks[i]);
      // A highlighter's line-number gutter is a sibling block of pure digits.
      // Copying it would put "1 2 3 4" on the clipboard.
      if (isLineNumberGutter(text)) {
        continue;
      }
      // Wrapped here rather than by string surgery in Swift: the wrapper is
      // the positioning context for the copy control, and only the DOM can
      // close it correctly around a block whose tag is not known in advance.
      var block = blocks[i];
      var parent = block.parentNode;
      if (!parent) {
        continue;
      }
      // A block that is not a `pre` keeps its line breaks only as long as
      // something preserves whitespace, and in the reader nothing does: a div
      // of code arrives as one run-on line in the body font. Reissuing it as a
      // `pre` restores the lines and picks up the monospace styling the reader
      // already has for every other block. The text is taken verbatim, so what
      // the copy control puts on the clipboard is what is on screen.
      if (block.tagName !== "PRE") {
        var reissued = block.ownerDocument.createElement("pre");
        reissued.textContent = text;
        parent.replaceChild(reissued, block);
        block = reissued;
      }
      var wrapper = block.ownerDocument.createElement("div");
      wrapper.className = "phi-code";
      wrapper.setAttribute("data-phi-code", String(texts.length));
      parent.insertBefore(wrapper, block);
      wrapper.appendChild(block);
      texts.push(text);
    }
    return texts;
  }

  function isLineNumberGutter(text) {
    var lines = text.trim().split("\n");
    if (lines.length < 2) {
      return false;
    }
    for (var i = 0; i < lines.length; i++) {
      if (!/^\s*\d+\s*$/.test(lines[i])) {
        return false;
      }
    }
    return true;
  }

  // --- Threads --------------------------------------------------------------

  // A question-and-answer page or a comment thread is not one article, it is
  // many short ones by different people. Concatenating them the way the rule
  // rung concatenates a split article produces a wall of text in which there
  // is no way to tell where one answer ends and the next begins, or who wrote
  // either — which is most of what a reader needs from a thread.
  //
  // So a rule may declare `thread`, and each node its `content` selects is
  // then rendered as its own post with a byline. The reader styles them as
  // separated, optionally indented, cards.

  var MAX_THREAD_DEPTH = 5;

  // A thread field is either a selector to run inside the post, or `@name` to
  // read an attribute off the post itself. The attribute form is not a
  // convenience: Reddit hangs the author, score and nesting depth of every
  // comment on the `shreddit-comment` element as attributes, and there is no
  // element inside the comment carrying any of them.
  function threadValue(post, spec) {
    if (!spec) {
      return null;
    }
    if (spec.charAt(0) === "@") {
      var attribute = post.getAttribute(spec.slice(1));
      return attribute ? attribute.trim() : null;
    }
    var nodes;
    try {
      nodes = post.querySelectorAll(spec);
    } catch (e) {
      return null;
    }
    // The first match is not always the one with the text: Quora puts the
    // avatar and the name in two links to the same profile, and the avatar
    // comes first and holds nothing but an image. Taking the first non-empty
    // match spares every such rule a selector contortion.
    for (var i = 0; i < nodes.length; i++) {
      var text = (nodes[i].innerText || nodes[i].textContent || "")
        .replace(/\s+/g, " ").trim();
      if (text) {
        return text;
      }
    }
    return null;
  }

  // Returns the post as a `<section>`, or null when it holds no text — a
  // Reddit link post has no body at all, and an empty card is worse than no
  // card. A `body` selector that matches nothing therefore drops the post,
  // which is deliberate: if a site changes and the selector stops matching,
  // every post drops, the rung declines, and the generic ladder takes over
  // rather than the reader showing a column of vote widgets.
  function buildThreadPost(post, thread, postSelector) {
    var section = document.createElement("section");
    section.className = "phi-post";

    var depth = parseInt(threadValue(post, thread.depth), 10);
    if (depth > 0) {
      section.setAttribute("data-depth",
                           String(Math.min(depth, MAX_THREAD_DEPTH)));
    }

    // Author and meta are separate elements rather than one line of text so
    // the reader can weight them differently: a thread is read by scanning for
    // who is speaking, and a name in the same muted caption grey as the score
    // reads as a footnote instead of a speaker.
    var author = threadValue(post, thread.author);
    var meta = threadValue(post, thread.meta);
    if (author || meta) {
      var byline = document.createElement("p");
      byline.className = "phi-post-by";
      if (author) {
        var authorSpan = document.createElement("span");
        authorSpan.className = "phi-post-author";
        authorSpan.textContent = author;
        byline.appendChild(authorSpan);
      }
      if (meta) {
        var metaSpan = document.createElement("span");
        metaSpan.className = "phi-post-meta";
        metaSpan.textContent = meta;
        byline.appendChild(metaSpan);
      }
      section.appendChild(byline);
    }

    var bodies = [];
    if (thread.body) {
      try {
        bodies = post.querySelectorAll(thread.body);
      } catch (e) {
        bodies = [];
      }
    } else {
      bodies = [post];
    }
    var taken = [];
    for (var i = 0; i < bodies.length; i++) {
      // A comment tree nests: Reddit puts a reply inside the comment it
      // answers, so a parent's body selector also matches every descendant's
      // body. Without this the top comment's card repeats the entire subtree
      // and every reply then appears again in its own card.
      if (postSelector && bodies[i].closest) {
        var owner = null;
        try {
          owner = bodies[i].closest(postSelector);
        } catch (e) {
          owner = null;
        }
        if (owner && owner !== post) {
          continue;
        }
      }
      // A body can also match inside another body: Reddit wraps a post's text
      // in a <shreddit-post-text-body> that carries the same slot as the div
      // inside it, so taking both printed the post twice. The outermost match
      // already contains the rest of them.
      var nested = false;
      for (var k = 0; k < taken.length; k++) {
        if (taken[k].contains(bodies[i])) {
          nested = true;
          break;
        }
      }
      if (nested) {
        continue;
      }
      taken.push(bodies[i]);
      section.appendChild(cloneWithShadowContent(bodies[i]));
    }
    return innerTextLength(section) > 0 ? section : null;
  }

  // --- Google Docs ----------------------------------------------------------

  // Google Docs draws the document into a <canvas>. There is no text in the
  // DOM to select — no paragraphs, no lines, nothing a rule could name — so
  // every rung of the ladder correctly finds nothing, and the accessibility
  // tree only carries the editor chrome unless the user has turned on screen
  // reader support. What the document does have is the export endpoint the
  // Docs UI itself uses, which returns the whole thing as clean HTML.
  //
  // Fetching it here rather than in Swift is what makes it work: the request
  // has to carry the user's session, and only the page has those cookies. It
  // is the document's own origin and the same bytes "File > Download > Web
  // page" produces, so this reads nothing the user could not already save.

  var GOOGLE_DOC_SOURCE = "googleDocsExport";
  var GOOGLE_DOC_PATH = /^\/document\/d\/([^/]+)/;
  var trustedHTMLPolicy;

  // Which sites this applies to is a rule's decision, not this file's; what a
  // rule cannot do is name a URL of its own to fetch. Rules are downloaded
  // from a public repository, and selecting elements already on the page is a
  // far smaller privilege than issuing a credentialed request from it.
  function googleDocumentId(rule) {
    if (!rule || rule.source !== GOOGLE_DOC_SOURCE) {
      return null;
    }
    var match = GOOGLE_DOC_PATH.exec(location.pathname);
    // The /d/e/ form is a document published to the web, which is already
    // plain HTML that the ordinary ladder reads perfectly well. A rule scoped
    // with pathContains cannot exclude it, so it is excluded here.
    return match && match[1] !== "e" ? match[1] : null;
  }

  // Docs enforces Trusted Types, which refuses innerHTML and DOMParser a bare
  // string. Minting a policy is the sanctioned way through and the page's CSP
  // permits it; where it does not, the assignment is attempted unwrapped so a
  // page without enforcement still works.
  function parseDocument(html) {
    var doc = document.implementation.createHTMLDocument("");
    var payload = html;
    if (window.trustedTypes && window.trustedTypes.createPolicy) {
      try {
        if (!trustedHTMLPolicy) {
          trustedHTMLPolicy = window.trustedTypes.createPolicy("phi-reader", {
            createHTML: function (value) { return value; }
          });
        }
        payload = trustedHTMLPolicy.createHTML(html);
      } catch (e) {
        /* no policy available; try the raw string below */
      }
    }
    doc.body.innerHTML = payload;
    return doc;
  }

  function extractGoogleDocument(id) {
    return fetch("/document/d/" + id + "/export?format=html", {
      credentials: "include"
    }).then(function (response) {
      // A view-only document with downloading disabled answers 403. There is
      // nothing else to read on the page, so the caller falls back to the
      // ladder and the reader declines, which is the honest outcome.
      return response.ok ? response.text() : null;
    }).then(function (html) {
      if (!html) {
        return null;
      }
      var exported = parseDocument(html);
      var container = document.createElement("div");
      var children = exported.body.childNodes;
      for (var i = 0; i < children.length; i++) {
        container.appendChild(document.importNode(children[i], true));
      }
      finishInto(container);
      var codeBlocks = indexCodeBlocks(container);
      var length = innerTextLength(container);
      if (length < MIN_RULE_TEXT_LENGTH) {
        return null;
      }
      return {
        rung: "export",
        codeBlocks: codeBlocks,
        // The tab title is the document name with the product appended.
        title: (document.title || "").replace(/\s+-\s+Google Docs$/, ""),
        byline: null,
        contentHTML: container.innerHTML,
        extractedLength: length,
        // The page shows none of this text, so measuring the extraction
        // against it says nothing. The export is the whole document by
        // definition.
        coverage: 1
      };
    }).catch(function () {
      return null;
    });
  }

  // --- Rungs ----------------------------------------------------------------

  // Rung 1: explicit selectors from a site rule. Multiple content roots are
  // concatenated, which is what makes articles split across sibling containers
  // come out whole — and, with `thread`, what makes a question and its answers
  // come out as a readable sequence rather than one run-on page.
  function extractByRule(rule) {
    if (!rule || !rule.content || !rule.content.length) {
      return null;
    }
    var container = document.createElement("div");
    var matched = 0;
    // Every selector that can name a post, so a body can be attributed to the
    // innermost post containing it rather than to an ancestor.
    var postSelector = rule.thread ? rule.content.join(", ") : null;
    for (var i = 0; i < rule.content.length; i++) {
      var roots;
      try {
        roots = document.querySelectorAll(rule.content[i]);
      } catch (e) {
        continue;
      }
      for (var j = 0; j < roots.length; j++) {
        if (rule.thread) {
          var section = buildThreadPost(roots[j], rule.thread, postSelector);
          if (section) {
            container.appendChild(section);
            matched++;
          }
          continue;
        }
        container.appendChild(cloneWithShadowContent(roots[j]));
        matched++;
      }
    }
    if (!matched) {
      return null;
    }
    if (rule.strip && rule.strip.length) {
      for (var s = 0; s < rule.strip.length; s++) {
        var junk;
        try {
          junk = container.querySelectorAll(rule.strip[s]);
        } catch (e) {
          continue;
        }
        for (var t = 0; t < junk.length; t++) {
          junk[t].parentNode && junk[t].parentNode.removeChild(junk[t]);
        }
      }
    }
    // Never sweep by discussion name under a rule. The name is a guess, the
    // rule is an assertion, and the guess has now destroyed content on two
    // sites: Reddit calls a comment's body `…-comment-rtjson-content`, and
    // Feishu wraps every commentable block — its tables and images included —
    // in `block-comment`, so the sweep deleted the article and left 18% of it.
    // A rule that does want a thread gone has `strip` to say so. The furniture
    // pattern still runs: share bars and related-post rails are named that way
    // precisely because they are furniture, and they do not wrap the article.
    finishInto(container, true);
    var codeBlocks = indexCodeBlocks(container);
    var length = innerTextLength(container);
    if (length < MIN_RULE_TEXT_LENGTH) {
      return null;
    }
    return {
      rung: "rule",
      codeBlocks: codeBlocks,
      title: textForSelector(rule.title) || document.title || "",
      byline: textForSelector(rule.byline),
      contentHTML: container.innerHTML,
      extractedLength: length
    };
  }

  function textForSelector(selector) {
    if (!selector) {
      return null;
    }
    try {
      var node = document.querySelector(selector);
      return node ? (node.innerText || node.textContent || "").trim() : null;
    } catch (e) {
      return null;
    }
  }

  // Rung 2: Readability against a clone of the live DOM.
  function extractByReadability() {
    if (typeof Readability !== "function") {
      return null;
    }
    var article;
    try {
      var docClone = document.cloneNode(true);
      // Readability scores a whole-document clone, which loses shadow content
      // the same way any other clone does.
      if (document.documentElement && docClone.documentElement) {
        inlineShadowRoots(document.documentElement, docClone.documentElement);
      }
      article = new Readability(docClone, { keepClasses: false }).parse();
    } catch (e) {
      return null;
    }
    if (!article || !article.content) {
      return null;
    }
    var container = document.createElement("div");
    container.innerHTML = article.content;
    finishInto(container);
    var codeBlocks = indexCodeBlocks(container);
    var length = innerTextLength(container);
    if (length < MIN_TEXT_LENGTH) {
      return null;
    }
    return {
      rung: "readability",
      codeBlocks: codeBlocks,
      title: (article.title || document.title || "").trim(),
      byline: article.byline || null,
      siteName: article.siteName || null,
      lang: article.lang || null,
      contentHTML: container.innerHTML,
      extractedLength: length
    };
  }

  // Rung 3: structural scoring that never looks at class or id names — the
  // signal Readability loses on utility-class and hashed-class markup.
  function extractByStructure() {
    var candidates = document.querySelectorAll(
      "article, main, section, div, td");
    var best = null;
    var bestScore = 0;
    for (var i = 0; i < candidates.length; i++) {
      var node = candidates[i];
      var length = innerTextLength(node);
      if (length < MIN_TEXT_LENGTH) {
        continue;
      }
      var paragraphs = node.querySelectorAll("p").length;
      if (paragraphs < 2) {
        continue;
      }
      // Prefer dense prose: long text, many paragraphs, few links.
      var score = length * (1 - linkDensity(node)) * Math.min(paragraphs, 40);
      // Penalise ancestors so the tightest container that still holds the
      // prose wins over <body>.
      if (best && best.contains(node)) {
        score *= 1.15;
      }
      if (score > bestScore) {
        bestScore = score;
        best = node;
      }
    }
    if (!best) {
      return null;
    }
    var container = document.createElement("div");
    container.appendChild(cloneWithShadowContent(best));
    finishInto(container);
    var codeBlocks = indexCodeBlocks(container);
    var finalLength = innerTextLength(container);
    if (finalLength < MIN_TEXT_LENGTH) {
      return null;
    }
    return {
      rung: "structural",
      codeBlocks: codeBlocks,
      title: document.title || "",
      byline: null,
      contentHTML: container.innerHTML,
      extractedLength: finalLength
    };
  }

  // --- Session-scoped images --------------------------------------------------

  // The reader renders in a web view with its own cookie store, so it is a
  // stranger to every site it shows. That is fine for an image on a public
  // CDN and fatal for one behind the session: Notion serves illustrations from
  // its own origin with the viewer's userId and spaceId in the query, and they
  // answer 401 to anyone else — the reader drew a broken-image box where the
  // diagram should be.
  //
  // Only the site's own images are carried across. A third-party CDN is what
  // nearly every site uses for pictures and needs no session, so inlining
  // those would cost bandwidth and megabytes of base64 for nothing.
  //
  // The test is the site, not the origin, because a private image is
  // routinely served from a sibling host: a Feishu doc renders its pictures
  // from internal-api-drive-stream.feishu.cn while the page is on
  // fydeinnovations.feishu.cn, and an origin test skipped every one of them.
  var MAX_INLINE_IMAGES = 20;
  var MAX_INLINE_IMAGE_BYTES = 1500000;
  var MAX_INLINE_TOTAL_BYTES = 5000000;

  // Registry labels that are themselves suffixes, so the registrable domain
  // takes one label more: bbc.co.uk, example.com.cn.
  var REGISTRY_LABEL_PATTERN = /^(com|co|net|org|gov|edu|ac|or|ne)$/;

  // The registrable domain, approximated without a public-suffix list. Being
  // wrong here costs a wasted fetch of a picture that did not need one, and
  // the caps below bound how many of those there can be.
  function siteOfHost(host) {
    var labels = String(host || "").toLowerCase().split(".");
    if (labels.length < 3) {
      return labels.join(".");
    }
    var depth = REGISTRY_LABEL_PATTERN.test(labels[labels.length - 2]) ? 3 : 2;
    return labels.slice(-depth).join(".");
  }

  function sessionImageSources(attempts) {
    var site = siteOfHost(location.hostname);
    var urls = [];
    for (var i = 0; i < attempts.length; i++) {
      var pattern = /<img[^>]+src="([^"]+)"/g;
      var match;
      while ((match = pattern.exec(attempts[i].contentHTML)) !== null) {
        var host;
        try {
          // Already inlined, or not fetchable: `data:` has no hostname, so it
          // falls out here rather than needing a case of its own.
          host = new URL(match[1], document.baseURI).hostname;
        } catch (e) {
          continue;
        }
        if (host && siteOfHost(host) === site && urls.indexOf(match[1]) < 0) {
          urls.push(match[1]);
        }
      }
    }
    return urls.slice(0, MAX_INLINE_IMAGES);
  }

  // Sent with credentials first, because that is what a session-scoped image
  // needs. It is also what a redirect to a public bucket cannot satisfy: the
  // hop answers with a wildcard origin, which a credentialed request is not
  // allowed to accept, and the fetch throws rather than returning a status.
  // Notion's images take exactly that route, so the uncredentialed retry is
  // not a fallback for rare cases — it is the one that succeeds.
  function fetchImageBlob(url) {
    return fetch(url, { credentials: "include" }).then(function (response) {
      return response.ok ? response.blob() : null;
    }).catch(function () {
      return fetch(url, { credentials: "omit" }).then(function (response) {
        return response.ok ? response.blob() : null;
      }).catch(function () {
        return null;
      });
    });
  }

  function inlineSessionImages(attempts) {
    var urls = sessionImageSources(attempts);
    if (!urls.length) {
      return Promise.resolve(attempts);
    }
    var replacements = {};
    var used = 0;
    var chain = Promise.resolve();

    urls.forEach(function (url) {
      chain = chain.then(function () {
        if (used >= MAX_INLINE_TOTAL_BYTES) {
          return null;
        }
        // The URL as it appears in the markup is not the URL to request:
        // serialising to innerHTML escapes the ampersands, so every query
        // separator arrives as &amp; and the server sees parameters named
        // "amp;id" and "amp;spaceId". The raw string stays the replacement key.
        return fetchImageBlob(url.replace(/&amp;/g, "&")).then(function (blob) {
          // A picture too large to carry keeps its URL and simply fails to
          // load, which is what it did before.
          if (!blob || blob.size > MAX_INLINE_IMAGE_BYTES) {
            return null;
          }
          used += blob.size;
          return new Promise(function (resolve) {
            var reader = new FileReader();
            reader.onloadend = function () {
              if (typeof reader.result === "string") {
                replacements[url] = reader.result;
              }
              resolve(null);
            };
            reader.onerror = function () { resolve(null); };
            reader.readAsDataURL(blob);
          });
        }).catch(function () {
          return null;
        });
      });
    });

    return chain.then(function () {
      for (var i = 0; i < attempts.length; i++) {
        for (var url in replacements) {
          if (!Object.prototype.hasOwnProperty.call(replacements, url)) {
            continue;
          }
          attempts[i].contentHTML = attempts[i].contentHTML
            .split("src=\"" + url + "\"")
            .join("src=\"" + replacements[url] + "\"");
        }
      }
      return attempts;
    });
  }

  // --- Entry point ----------------------------------------------------------

  window.__phiReaderExtract = function (config) {
    var cfg = config || {};
    var rule = cfg.rule || null;
    var readyBudget = cfg.readyBudgetMs === undefined ? 3000 : cfg.readyBudgetMs;

    try {
      // What this document *is* is decided after `load`, never before: a page
      // whose <body> had not been parsed became a flat refusal, and a tab
      // still showing the previous document was judged as that document — an
      // HTML page mistaken for a PDF goes down the accessibility path and
      // comes back as a handful of captions, the worst output the reader can
      // produce.
      var readyDeadline = nowMs() + readyBudget;
      return awaitLoadEvent(readyBudget).then(function (readyState) {
        if (isPDFViewer()) {
          // Nothing here to distill; the caller switches to the accessibility
          // tree, which is the only route to the plugin's text. Returning now
          // also keeps a PDF, which never has body text, out of the content
          // wait below.
          return { ok: false, reason: "pdf_document", readyState: readyState };
        }
        if (!document.body) {
          return { ok: false, reason: "no_document", readyState: readyState };
        }
        // A canvas-rendered document is tried first, because the ladder cannot
        // read one at all and the export endpoint reads all of it.
        var googleDoc = googleDocumentId(rule);
        if (googleDoc) {
          return extractGoogleDocument(googleDoc).then(function (attempt) {
            if (attempt) {
              return {
                ok: true,
                url: document.location.href,
                lang: document.documentElement.getAttribute("lang") || null,
                visibleTextLength: visibleTextLength(),
                readyState: readyState,
                visibilityState: document.visibilityState,
                prepared: { detailsOpened: 0, expandersClicked: 0, settledLazy: false },
                attempts: [attempt]
              };
            }
            return awaitContent(readyDeadline).then(function () {
              return extractNow(readyState, LADDER_RETRIES);
            });
          });
        }
        return awaitContent(readyDeadline).then(function () {
          return extractNow(readyState, LADDER_RETRIES);
        });
      }).catch(function (e) {
        return { ok: false, reason: "extraction_failed", detail: String(e) };
      });

      // A client-rendered page can pass every readiness check and still have
      // no article in it: the shell is loaded, its chrome is text, and React
      // has not mounted the body yet. There is no in-page signal that
      // separates "mounting" from "mounted" — a pause before the mount reads
      // as settled however it is measured — so the reliable answer is to look
      // for the article, and if the ladder finds nothing, look again a moment
      // later. Only the empty-handed case retries, so a page that extracted
      // pays nothing.
      function extractNow(readyState, attemptsLeft) {
        return runLadder(readyState).then(function (result) {
          if (result.ok || !attemptsLeft ||
              result.reason !== "no_article_detected") {
            return result;
          }
          return sleep(LADDER_RETRY_MS).then(function () {
            return extractNow(readyState, attemptsLeft - 1);
          });
        });
      }

      function runLadder(readyState) {
        // Started only once the page has settled, so a slow load does not eat
        // the preparation budget.
        var deadline = nowMs() + (cfg.prepareBudgetMs || 1500);
        var prepared = prepare(rule, deadline, !cfg.skipLazySettle);

        return prepared.then(function (prepareReport) {
          // Measured before marking, so it reflects the page as rendered, and
          // marked before any rung clones, so every clone carries the marks.
          var totalVisible = visibleTextLength();
          var marked = [];
          var spacers = [];
          try {
            marked = markHiddenElements();
          } catch (e) {
            /* the ladder still works, it just measures hidden text again */
          }
          try {
            spacers = markSpacerImages();
          } catch (e) {
            /* the ladder still works, it just keeps the stand-ins */
          }
          var forced = rule && rule.forceRung;
          var attempts = [];
          try {
            runRungs();
          } finally {
            // The marks are ours, not the page's, and every rung has taken
            // its copy by now. Restoring in a finally keeps the contract that
            // preparation leaves the live page as it found it, even if a rung
            // fails in a way its own guard does not catch.
            unmarkHiddenElements(marked);
            unmarkSpacerImages(spacers);
          }

          function attempt(fn) {
            try {
              var result = fn();
              if (result) {
                attempts.push(result);
              }
            } catch (e) {
              /* a failing rung must not abort the ladder */
            }
          }

          function runRungs() {
            if (!forced || forced === "rule") {
              attempt(function () { return extractByRule(rule); });
            }
            if (!forced || forced === "readability") {
              attempt(extractByReadability);
            }
            if (!forced || forced === "structural") {
              attempt(extractByStructure);
            }
          }

          if (!attempts.length) {
            return {
              ok: false,
              reason: "no_article_detected",
              visibleTextLength: totalVisible
            };
          }

          // Swift owns the accept/reject policy; every attempt and its coverage
          // is reported so the gate is applied in one place.
          for (var i = 0; i < attempts.length; i++) {
            attempts[i].coverage = totalVisible > 0
              ? attempts[i].extractedLength / totalVisible
              : 0;
          }

          return inlineSessionImages(attempts).then(function () {
          return {
            ok: true,
            url: document.location.href,
            lang: document.documentElement.getAttribute("lang") || null,
            visibleTextLength: totalVisible,
            readyState: readyState,
            // Reported because the walk in `prepare` silently does nothing on
            // a hidden page, which is otherwise indistinguishable from a page
            // that simply had no deferred content.
            visibilityState: document.visibilityState,
            prepared: prepareReport,
            attempts: attempts
          };
          });
        });
      }
    } catch (e) {
      return Promise.resolve({ ok: false, reason: "extraction_failed", detail: String(e) });
    }
  };
})();

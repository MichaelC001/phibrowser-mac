// Phi's answer to "should the address bar offer the reader here?".
//
// Concatenated after Readability-readerable.js inside one closure, so
// `isProbablyReaderable`, `isNodeVisible` and `REGEXPS` from that file are in
// scope. Mozilla's heuristic predicts whether *Readability* will succeed, but
// Phi's ladder reads strictly more than Readability does — site rules, the
// structural rung, and legacy-markup normalisation — so the stock answer
// under-reports what pressing the button would actually deliver. The two
// supplements below cover exactly the extra ground Phi is known to read well;
// they deliberately do not try to predict the structural rung in general,
// which can extract almost any page whether or not the result is worth
// offering.
//
// Kept in Mozilla's shape on purpose: the same visibility test, the same
// class/id suspicion regexes, the same sqrt scoring, so a future reader of
// either file can compare them line by line.

// A run of text broken by <br><br> is a paragraph the page never marked up.
// Mozilla only credits these inside <div>; pre-CSS pages write them under
// <font>, <td>, <center>, or body itself — paulgraham.com puts a whole essay
// as one such run inside a <font> — and the extraction ladder normalises
// exactly this shape, so the button should light for it.
function __phiLegacyMarkupPasses(doc) {
  var parents = new Set();
  doc.querySelectorAll("br").forEach(function (br) {
    if (br.parentElement) {
      parents.add(br.parentElement);
    }
  });

  var score = 0;
  var passed = false;
  parents.forEach(function (node) {
    if (passed) {
      return;
    }
    // Outermost holders only: a <td> holding a <font> holding the runs would
    // otherwise count the same essay twice.
    for (var a = node.parentElement; a; a = a.parentElement) {
      if (parents.has(a)) {
        return;
      }
    }
    if (!isNodeVisible(node)) {
      return;
    }
    var matchString = node.className + " " + node.id;
    if (
      REGEXPS.unlikelyCandidates.test(matchString) &&
      !REGEXPS.okMaybeItsACandidate.test(matchString)
    ) {
      return;
    }
    var textContentLength = node.textContent.trim().length;
    if (textContentLength < 140) {
      return;
    }
    score += Math.sqrt(textContentLength - 140);
    if (score > 20) {
      passed = true;
    }
  });
  return passed;
}

// A short article never reaches Mozilla's score of 20 — one 400-character
// post is worth sqrt(260) ≈ 16 — but Phi's acceptance gate is coverage
// against the page, not an absolute count, and it reads such a page fine.
// Mirror that: when the marked-up text IS most of a small page, offer the
// reader. Capped at small pages both because long pages that fail the stock
// score are not paragraph-shaped, and because this pass reads layout-forced
// innerText, which must stay cheap.
function __phiShortArticleDominatesPage(doc) {
  if (!doc.body) {
    return false;
  }
  var total = doc.body.innerText.trim().length;
  if (total < 200 || total > 5000) {
    return false;
  }
  var qualifying = 0;
  doc.querySelectorAll("p, pre, blockquote, article").forEach(function (node) {
    // Outermost only, or an <article> and its own <p>s count twice and the
    // ratio can pass 1 on a page that is mostly navigation.
    if (
      node.parentElement &&
      node.parentElement.closest("p, pre, blockquote, article")
    ) {
      return;
    }
    if (!isNodeVisible(node)) {
      return;
    }
    var matchString = node.className + " " + node.id;
    if (
      REGEXPS.unlikelyCandidates.test(matchString) &&
      !REGEXPS.okMaybeItsACandidate.test(matchString)
    ) {
      return;
    }
    qualifying += (node.innerText || "").trim().length;
  });
  return qualifying >= 150 && qualifying / total >= 0.6;
}

function __phiIsProbablyReaderable(doc) {
  return (
    isProbablyReaderable(doc) ||
    __phiLegacyMarkupPasses(doc) ||
    __phiShortArticleDominatesPage(doc)
  );
}

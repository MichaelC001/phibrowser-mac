// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// `credentials.*` handlers — the agent-facing credential surface. An agent
/// connected over `/phi-agent` (or the CDP tunnel) can check provider readiness
/// and, after an explicit user approval, fetch a credential for a site (TOTP is
/// deliberately out for now — see `handleCredentialsGetTotp`). Every
/// secret-returning call goes through `CredentialAccessCoordinator`
/// (approve/deny, optional 10-minute remember) and is recorded, values-free, by
/// `CredentialAuditLog`. Credentials resolve through `BitwardenService`, so the
/// surface is provider-agnostic.
///
/// Which routes release a secret TO the agent is deliberate: `credentials.get`
/// serves only the modes whose secret inherently crosses to the agent —
/// `reveal` (into the agent's context) and `run` (into a command's env). A page
/// `fill`, whose contract is that the secret must NOT reach the agent, is served
/// exclusively by `credentials.autofill`: Phi performs the fill itself over an
/// app-owned DevTools session (`AppDevToolsPageSession` — value app → page,
/// origin-bound to the credential's site); `credentials.get` refuses
/// `mode:"fill"` so a fill can never be satisfied by quietly revealing the
/// plaintext instead.
///
/// These register via `registerUserSpaceManaged`, so the Developer ▸ Agent
/// permissions master gate turns the whole family off in one switch.
/// Independently, the user's Bitwarden enable toggle is checked here per
/// request: while off, the routes refuse before any prompt fires, so no
/// standing grant — including a persistent "Always Allow" — can release a
/// credential from a disabled provider.
extension AgentSpaceRouter {

    /// The Settings ▸ Phi & AI master Bitwarden toggle. Enforced at the route
    /// level (not in the settings view, whose toggle handler only locks the
    /// vault and drops session grants) so every credential path shares the one
    /// gate.
    private static var credentialProviderEnabled: Bool {
        PhiPreferences.PasswordManagerSettings.bitwardenEnabled.loadValue()
    }

    /// `credentials.status` — provider readiness. No secret, no approval.
    static func handleCredentialsStatus(context: ExtensionMessageContext) -> String? {
        // A disabled provider answers directly — and never spawns the helper.
        guard credentialProviderEnabled else {
            return credJSON(["ok": true, "status": "disabled", "ready": false])
        }
        let requestId = context.requestId
        Task {
            let status = await BitwardenService.shared.status()
            let reply = credJSON([
                "ok": true,
                "status": statusWireString(status),
                "ready": status.isReady,
            ])
            await ExtensionMessaging.shared.sendResponse(reply, requestId: requestId)
        }
        return nil
    }

    /// `credentials.get` — full credential for a query, after user approval.
    static func handleCredentialsGet(context: ExtensionMessageContext) -> String? {
        handleCredentialFetch(context: context)
    }

    /// `credentials.getTotp` — TOTP is deliberately out of the agent surface
    /// for now: releasing a live 2FA code to an agent collapses both factors
    /// behind one approval prompt. Kept registered so agents get a clean,
    /// detectable error instead of an unknown-method failure.
    static func handleCredentialsGetTotp(context: ExtensionMessageContext) -> String? {
        "{\"ok\":false,\"error\":\"totp_not_supported\"}"
    }

    /// `credentials.autofill` — the ONLY fill path, and the only way a `fill`
    /// request is honored (`credentials.get` refuses `mode:"fill"`, see
    /// `handleCredentialFetch`). The value goes app → page and never crosses to
    /// the agent: Phi opens its own DevTools session on the page
    /// (`AppDevToolsPageSession`), looks the credential up, and sets the field
    /// itself, returning only `{filled:true}` — never the secret.
    ///
    /// Contract with the skill's `fillCredential`: the caller resolves the
    /// element with its own machinery and stamps it with a one-time
    /// `data-phi-autofill="<token>"` marker, then sends `{query, field, token,
    /// targetId}`. The app finds the marker (top document + same-origin
    /// frames), so no selector/ref scheme crosses the boundary. The page's
    /// host comes from `Target.getTargetInfo` — browser truth, not an
    /// agent-supplied claim — and the fill is refused with `origin_mismatch`
    /// when it doesn't belong to the credential's site. `allowCrossOrigin`
    /// overrides that ONLY through a destination-qualified approval scope
    /// ("site → page-host"), which a standing same-site grant never covers —
    /// a redirected fill always faces its own prompt naming both sides.
    static func handleCredentialsAutofill(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload), let query = parseCredentialQuery(obj),
              let token = obj["token"] as? String, isSafeFillToken(token),
              let targetId = obj["targetId"] as? String, isSafeTargetId(targetId) else {
            return invalid()
        }
        let field = obj["field"] as? String ?? "password"
        guard field == "password" || field == "username" else { return invalid() }
        let allowCrossOrigin = obj["allowCrossOrigin"] as? Bool ?? false
        let purpose = (obj["purpose"] as? String).flatMap { p -> String? in
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
        }
        let requestId = context.requestId
        let agent = context.agentName.isEmpty ? "An agent" : context.agentName
        let scope = credentialScopeLabel(query)
        guard credentialProviderEnabled else {
            CredentialAuditLog.shared.record(.requested, agent: agent, scope: scope)
            CredentialAuditLog.shared.record(.denied, agent: agent, scope: scope,
                                             detail: "provider_disabled")
            return credJSON(["ok": false, "error": "not_ready", "status": "disabled"])
        }

        Task { @MainActor in
            CredentialAuditLog.shared.record(.requested, agent: agent, scope: scope)
            let reply = await performAutofill(
                query: query, field: field, token: token, targetId: targetId,
                allowCrossOrigin: allowCrossOrigin, purpose: purpose,
                agent: agent, scope: scope)
            ExtensionMessaging.shared.sendResponse(reply, requestId: requestId)
        }
        return nil
    }

    /// The autofill flow proper: dial the page, learn its real host, clear the
    /// approval gate, resolve the credential, enforce the origin binding, and
    /// set the field in-page. Returns the wire reply; the secret appears only
    /// in the page-bound JS, never in the reply.
    @MainActor
    private static func performAutofill(query: CredentialQuery, field: String,
                                        token: String, targetId: String,
                                        allowCrossOrigin: Bool, purpose: String?,
                                        agent: String, scope: String) async -> String {
        // Dial the page FIRST: the destination host drives the origin check and
        // the prompt wording, and it must come from the browser, not the agent.
        let session: AppDevToolsPageSession
        do {
            session = try await AppDevToolsPageSession.open(targetId: targetId)
        } catch AppDevToolsPageSession.SessionError.upgradeFailed {
            CredentialAuditLog.shared.record(.error, agent: agent, scope: scope,
                                             detail: "page_not_found")
            return credJSON(["ok": false, "error": "page_not_found"])
        } catch {
            CredentialAuditLog.shared.record(.error, agent: agent, scope: scope,
                                             detail: "autofill_not_available")
            return credJSON(["ok": false, "error": "autofill_not_available"])
        }
        defer { session.close() }

        guard let info = try? await session.command("Target.getTargetInfo"),
              let url = (info["targetInfo"] as? [String: Any])?["url"] as? String,
              let pageHost = hostOfURI(url) else {
            CredentialAuditLog.shared.record(.error, agent: agent, scope: scope,
                                             detail: "page_not_found")
            return credJSON(["ok": false, "error": "page_not_found"])
        }

        // Origin pre-check for domain queries — before any prompt, so a
        // misdirected fill costs no approval. id/search queries are checked
        // against the item's own site after lookup.
        var queryDomain: String?
        if case .domain(let d, _) = query { queryDomain = d }
        if let d = queryDomain, !allowCrossOrigin, !credHostMatches(pageHost, d) {
            CredentialAuditLog.shared.record(.denied, agent: agent, scope: scope,
                                             detail: "origin_mismatch page=\(pageHost)")
            return credJSON(["ok": false, "error": "origin_mismatch", "pageHost": pageHost])
        }

        // A cross-origin fill approves (and remembers) under a scope naming the
        // destination, so a plain same-site grant can never silently cover a
        // redirected fill — the prompt always shows where the login is going.
        let grantScope = allowCrossOrigin
            ? "\(credentialGrantScope(query)) → \(pageHost)"
            : credentialGrantScope(query)
        guard CredentialAccessCoordinator.shared.requestApproval(
            agentName: agent, scope: grantScope, kind: .fill, purpose: purpose) else {
            CredentialAuditLog.shared.record(.denied, agent: agent, scope: scope)
            return "{\"ok\":false,\"error\":\"user_denied\"}"
        }
        CredentialAuditLog.shared.record(.approved, agent: agent, scope: scope)

        await ensureVaultUnlocked(agent: agent, scope: scope)

        let item: CredentialItem
        let matches: Int
        do {
            switch try await BitwardenService.shared.lookup(query) {
            case .found(let found, let n):
                item = found
                matches = n
            case .ambiguous(let candidates):
                CredentialAuditLog.shared.record(.denied, agent: agent, scope: scope,
                                                 detail: "ambiguous (\(candidates.count) matches)")
                return ambiguousReply(candidates)
            case .notFound:
                return "{\"ok\":false,\"error\":\"not_found\"}"
            case .notReady(let status):
                return credJSON(["ok": false, "error": "not_ready",
                                 "status": statusWireString(status)])
            }
        } catch {
            CredentialAuditLog.shared.record(.error, agent: agent, scope: scope,
                                             detail: error.localizedDescription)
            return "{\"ok\":false,\"error\":\"provider_error\"}"
        }

        // Fills serve logins only: the approval said "fill your login", and
        // only a login has an origin to bind the fill to. A note/card/
        // identity/SSH key resolved by an id or search query is refused, not
        // silently poured into a form field.
        if let type = item.type, type != "login" {
            CredentialAuditLog.shared.record(.denied, agent: agent, scope: scope,
                                             detail: "not_a_login (\(type))")
            return credJSON(["ok": false, "error": "not_a_login", "type": type])
        }

        // Origin enforcement against the item's own site (the load-bearing
        // check for id/search queries; defense in depth for domain queries).
        // An item that names no site at all can't be origin-bound — refuse it
        // rather than fill blind.
        if !allowCrossOrigin {
            let itemHost = item.domain ?? item.uri.flatMap(hostOfURI) ?? queryDomain
            guard let itemHost, credHostMatches(pageHost, itemHost) else {
                CredentialAuditLog.shared.record(.denied, agent: agent, scope: scope,
                                                 detail: "origin_mismatch page=\(pageHost)")
                return credJSON(["ok": false, "error": "origin_mismatch",
                                 "pageHost": pageHost])
            }
        }

        let value = field == "password" ? item.password?.reveal() : item.username
        guard let value, !value.isEmpty else {
            return credJSON(["ok": false, "error": "field_unavailable", "field": field])
        }

        do {
            let result = try await session.command(
                "Runtime.evaluate",
                params: ["expression": fillExpression(token: token, field: field, value: value),
                         "returnByValue": true])
            guard result["exceptionDetails"] == nil,
                  let outcome = (result["result"] as? [String: Any])?["value"] as? [String: Any]
            else {
                CredentialAuditLog.shared.record(.error, agent: agent, scope: scope,
                                                 detail: "fill_eval_failed")
                return "{\"ok\":false,\"error\":\"fill_failed\"}"
            }
            guard outcome["ok"] as? Bool == true else {
                let err = outcome["err"] as? String ?? "fill_failed"
                CredentialAuditLog.shared.record(.error, agent: agent, scope: scope,
                                                 detail: err)
                return credJSON(["ok": false, "error": err])
            }
        } catch {
            CredentialAuditLog.shared.record(.error, agent: agent, scope: scope,
                                             detail: "fill_transport_failed")
            return "{\"ok\":false,\"error\":\"fill_failed\"}"
        }

        CredentialAuditLog.shared.record(
            .served, agent: agent, scope: scope,
            fields: CredentialFieldSet(username: field == "username",
                                       password: field == "password"),
            detail: "filled \(field) on \(pageHost)")
        return credJSON(["ok": true, "filled": true, "field": field, "matches": matches])
    }

    // MARK: - Shared fetch path

    private static func handleCredentialFetch(context: ExtensionMessageContext) -> String? {
        guard let obj = json(context.payload), let query = parseCredentialQuery(obj) else {
            return invalid()
        }
        let requestId = context.requestId
        let agent = context.agentName.isEmpty ? "An agent" : context.agentName
        let scope = credentialScopeLabel(query)
        // Refuse a disabled provider before the approval and unlock prompts:
        // with the toggle off nothing may be served, whatever grants exist.
        guard credentialProviderEnabled else {
            CredentialAuditLog.shared.record(.requested, agent: agent, scope: scope)
            CredentialAuditLog.shared.record(.denied, agent: agent, scope: scope,
                                             detail: "provider_disabled")
            return credJSON(["ok": false, "error": "not_ready", "status": "disabled"])
        }
        let grantScope = credentialGrantScope(query)
        let requestedFields = (obj["fields"] as? [String]).map(Set.init)
        // Free-text context for the approval prompt ("fill the password field on
        // github.com") — display-only, never part of the query or the grant key.
        let purpose = (obj["purpose"] as? String).flatMap { p -> String? in
            let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(200))
        }
        // How the secret will be used, declared by the runner's helper (the
        // skill's runWithCredential/getCredential): drives the prompt wording
        // and what kind of grant an approval records. Absent or unknown reads as
        // `reveal` — the widest, most-warned kind.
        let kind = (obj["mode"] as? String)
            .flatMap(CredentialAccessKind.init(rawValue:)) ?? .reveal

        // A `fill` is NEVER served here. `credentials.get` returns the secret to
        // the agent — the opposite of a fill, whose whole point is that the
        // secret stays out of the agent. A page fill is performed in-app by
        // `credentials.autofill` (the value goes app → page, never to the
        // agent); until that Chromium-side dispatch lands, a fill request is
        // refused rather than silently downgraded to a reveal that leaks the
        // plaintext. `run` and `reveal` cross to the agent by their nature and
        // are served below.
        if kind == .fill {
            CredentialAuditLog.shared.record(.requested, agent: agent, scope: scope)
            CredentialAuditLog.shared.record(.denied, agent: agent, scope: scope,
                                             detail: "fill_requires_autofill")
            return credJSON(["ok": false, "error": "fill_requires_autofill"])
        }

        Task { @MainActor in
            CredentialAuditLog.shared.record(.requested, agent: agent, scope: scope)

            guard CredentialAccessCoordinator.shared.requestApproval(
                agentName: agent, scope: grantScope, kind: kind,
                purpose: purpose) else {
                CredentialAuditLog.shared.record(.denied, agent: agent, scope: scope)
                ExtensionMessaging.shared.sendError("user_denied", requestId: requestId)
                return
            }
            CredentialAuditLog.shared.record(.approved, agent: agent, scope: scope)

            // If the session-timeout policy left the vault locked, unlock it
            // in-flow (master password → helper). If the user cancels, the serve
            // step below reports `not_ready: locked` cleanly.
            await ensureVaultUnlocked(agent: agent, scope: scope)

            do {
                try await serveCredential(query: query, fields: requestedFields,
                                          agent: agent, scope: scope, requestId: requestId)
            } catch {
                CredentialAuditLog.shared.record(.error, agent: agent, scope: scope,
                                                 detail: error.localizedDescription)
                ExtensionMessaging.shared.sendError("provider_error", requestId: requestId)
            }
        }
        return nil
    }

    /// Ensures the vault is unlocked before a lookup. When it is `locked`, prompts
    /// for the master password and unlocks via the helper (the app never stores
    /// it). Other not-ready states (logged out / not installed) can't be resolved
    /// here — the caller's lookup then returns `not_ready` unchanged.
    @MainActor
    private static func ensureVaultUnlocked(agent: String, scope: String) async {
        guard case .locked = await BitwardenService.shared.status() else { return }
        guard let password = CredentialAccessCoordinator.shared.promptForUnlock(
            agentName: agent, scope: scope) else { return }
        // No 2FA code in this flow: for a 2FA account the helper replays its
        // remember token; without one the unlock fails and the lookup reports
        // `not_ready: locked` — the user then unlocks via Settings, where the
        // sheet offers the code field.
        try? await BitwardenService.shared.unlock(secret: password)
    }

    @MainActor
    private static func serveCredential(query: CredentialQuery, fields: Set<String>?,
                                        agent: String, scope: String, requestId: String) async throws {
        switch try await BitwardenService.shared.lookup(query) {
        case .found(let item, let matches):
            CredentialAuditLog.shared.record(.served, agent: agent, scope: scope,
                                             fields: item.fieldPresence)
            ExtensionMessaging.shared.sendResponse(
                buildCredentialReply(item, fields: fields, matches: matches),
                requestId: requestId)
        case .ambiguous(let candidates):
            // The provider refused to pick among several matching accounts —
            // no secret was released. The reply carries the candidates'
            // non-secret identities so the agent can narrow with
            // {domain, username} or {id}.
            CredentialAuditLog.shared.record(.denied, agent: agent, scope: scope,
                                             detail: "ambiguous (\(candidates.count) matches)")
            ExtensionMessaging.shared.sendResponse(ambiguousReply(candidates),
                                                   requestId: requestId)
        case .notFound:
            ExtensionMessaging.shared.sendResponse("{\"ok\":false,\"error\":\"not_found\"}",
                                                   requestId: requestId)
        case .notReady(let status):
            ExtensionMessaging.shared.sendResponse(
                credJSON(["ok": false, "error": "not_ready", "status": statusWireString(status)]),
                requestId: requestId)
        }
    }

    // MARK: - Autofill helpers

    /// The marker token is skill-generated (a UUID). Constraining its charset
    /// keeps it inert inside the selector/JS the app builds around it.
    private static func isSafeFillToken(_ s: String) -> Bool {
        (8...64).contains(s.count) && s.allSatisfy {
            $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-"
        }
    }

    /// DevTools target ids are hex strings; accept a safe superset so the id
    /// can be embedded in the upgrade request path.
    private static func isSafeTargetId(_ s: String) -> Bool {
        (4...128).contains(s.count) && s.allSatisfy {
            $0.isLetter && $0.isASCII || $0.isNumber || $0 == "-" || $0 == "_"
        }
    }

    /// Lowercased host of a URI, tolerating a missing scheme; nil when
    /// unparsable. This value feeds the origin check, so the parse must not be
    /// spoofable: the authority is isolated BEFORE userinfo is stripped —
    /// stripping at an `@` first would let "https://evil.com/x@github.com"
    /// read as github.com. Mirrors the skill's `hostOfUri`.
    static func hostOfURI(_ uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A well-formed URL (the page URL from Target.getTargetInfo always is)
        // parses directly.
        if let host = URLComponents(string: trimmed)?.host, !host.isEmpty {
            return host.lowercased()
        }
        // Vault URIs are often scheme-less ("github.com/login"): take the
        // authority — everything before the first path/query/fragment
        // delimiter — then strip userinfo and port within it.
        let afterScheme = trimmed.range(of: "://").map { String(trimmed[$0.upperBound...]) }
            ?? trimmed
        guard let authority = afterScheme
            .split(whereSeparator: { "/?#".contains($0) }).first else { return nil }
        let afterUserinfo = authority.lastIndex(of: "@").map {
            authority[authority.index(after: $0)...]
        } ?? authority[...]
        let host = afterUserinfo.split(separator: ":").first.map { $0.lowercased() }
        return (host?.isEmpty == false) ? host : nil
    }

    /// Whether the page's host and a credential's host belong together: equal,
    /// or one a subdomain of the other, with the parent required to carry at
    /// least two labels so a bare public suffix ("com") never passes as the
    /// parent of every host under it. Mirrors the skill's `credHostMatches`
    /// and the Rust helper's `host_matches`.
    static func credHostMatches(_ pageHost: String, _ credHost: String) -> Bool {
        let a = pageHost.lowercased(), b = credHost.lowercased()
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        return (b.contains(".") && a.hasSuffix("." + b))
            || (a.contains(".") && b.hasSuffix("." + a))
    }

    /// A JS string literal for `s` (a JSON-encoded string is one).
    private static func jsLiteral(_ s: String) -> String {
        (try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    /// The in-page fill: find the skill-stamped marker in the top document or
    /// a same-origin frame, consume it, insist the element really is the kind
    /// of field the approval named, then set the value through the native
    /// setter + input/change events (the same deterministic path the skill's
    /// own fillInput uses, so framework-bound forms update). Runs via the
    /// app's own DevTools session — this expression is the only place the
    /// secret meets the page.
    private static func fillExpression(token: String, field: String, value: String) -> String {
        """
        (function (token, field, value) {
          var docs = [document]
          var collect = function (win) {
            for (var i = 0; i < win.frames.length; i++) {
              try {
                var d = win.frames[i].document
                if (d) { docs.push(d); collect(win.frames[i]) }
              } catch (e) {}
            }
          }
          try { collect(window) } catch (e) {}
          var el = null
          for (var i = 0; i < docs.length && !el; i++) {
            try { el = docs[i].querySelector('input[data-phi-autofill="' + token + '"]') } catch (e) {}
          }
          if (!el) return { ok: false, err: 'target_not_found' }
          el.removeAttribute('data-phi-autofill')
          var type = (el.getAttribute('type') || 'text').toLowerCase()
          if (field === 'password' && type !== 'password') {
            return { ok: false, err: 'not_password_field' }
          }
          if (field === 'username' && ['text', 'email', 'tel'].indexOf(type) < 0) {
            return { ok: false, err: 'not_username_field' }
          }
          try { el.focus() } catch (e) {}
          var win = el.ownerDocument.defaultView || window
          var setter = Object.getOwnPropertyDescriptor(win.HTMLInputElement.prototype, 'value').set
          setter.call(el, value)
          el.dispatchEvent(new Event('input', { bubbles: true }))
          el.dispatchEvent(new Event('change', { bubbles: true }))
          return { ok: true }
        })(\(jsLiteral(token)), \(jsLiteral(field)), \(jsLiteral(value)))
        """
    }

    // MARK: - Wire helpers

    private static func parseCredentialQuery(_ obj: [String: Any]) -> CredentialQuery? {
        if let q = obj["query"] as? [String: Any] {
            if let d = q["domain"] as? String {
                return .domain(d, username: q["username"] as? String)
            }
            if let id = q["id"] as? String { return .itemId(id) }
            if let s = q["search"] as? String { return .search(s) }
            return nil
        }
        // Convenience: a bare {"domain": "..."} is also accepted.
        if let d = obj["domain"] as? String { return .domain(d, username: nil) }
        return nil
    }

    private static func credentialScopeLabel(_ query: CredentialQuery) -> String {
        switch query {
        case .domain(let d, let username):
            guard let username, !username.isEmpty else { return d }
            return "\(d) (\(username))"
        case .itemId(let id): return "item \(id)"
        case .search(let s): return "“\(s)”"
        }
    }

    /// The scope a grant is keyed and checked by. Unlike the audit label, a
    /// domain query ignores the username filter: narrowing to one account
    /// doesn't reach different secrets than the site-wide query, so one
    /// approval for the site must cover both.
    private static func credentialGrantScope(_ query: CredentialQuery) -> String {
        switch query {
        case .domain(let d, _): return d
        case .itemId(let id): return "item \(id)"
        case .search(let s): return "“\(s)”"
        }
    }

    private static func statusWireString(_ status: CredentialProviderStatus) -> String {
        switch status {
        case .notInstalled: return "not_installed"
        case .unavailable: return "unavailable"
        case .loggedOut: return "logged_out"
        case .locked: return "locked"
        case .ready: return "ready"
        }
    }

    /// Builds the reply, revealing only the requested fields. The default set
    /// follows the item type: a login serves username/password/uri/domain
    /// (its notes require an explicit ask), a secure note serves its notes —
    /// they ARE the item — and a card / identity / SSH key serves its
    /// type-specific fields. `type` and `name` always ride along (non-secret
    /// identity, like `matches`); the totp seed is never released, TOTP
    /// support is out for now. A served credential is always the query's
    /// unique match (`matches` stays for wire compatibility and is 1);
    /// several matches come back as the `ambiguous` error instead — see
    /// `ambiguousReply`.
    private static func buildCredentialReply(_ item: CredentialItem, fields: Set<String>?,
                                             matches: Int) -> String {
        let defaults: Set<String>
        switch item.type {
        case "note": defaults = ["notes"]
        case "card", "identity", "sshKey": defaults = Set(item.typed.keys)
        default: defaults = ["username", "password", "uri", "domain"]
        }
        let requested = fields ?? defaults
        var cred: [String: Any] = [:]
        if let v = item.type { cred["type"] = v }
        if let v = item.name { cred["name"] = v }
        if requested.contains("username"), let v = item.username { cred["username"] = v }
        if requested.contains("password"), let v = item.password { cred["password"] = v.reveal() }
        if requested.contains("uri"), let v = item.uri { cred["uri"] = v }
        if requested.contains("domain"), let v = item.domain { cred["domain"] = v }
        if requested.contains("notes"), let v = item.notes { cred["notes"] = v.reveal() }
        if requested.contains("credentialId"), let v = item.credentialId { cred["credentialId"] = v }
        for (key, value) in item.typed where requested.contains(key) {
            cred[key] = value.reveal()
        }
        return credJSON(["ok": true, "credential": cred, "matches": matches])
    }

    /// Reply for a lookup several vault items fit: an error (no credential
    /// key exists, so nothing downstream can mistake it for a serve) carrying
    /// the candidates' non-secret identities. The agent narrows with
    /// {domain, username} or {id} and asks again.
    private static func ambiguousReply(_ candidates: [CredentialLookupCandidate]) -> String {
        credJSON([
            "ok": false, "error": "ambiguous", "matches": candidates.count,
            "candidates": candidates.map { c -> [String: Any] in
                var entry: [String: Any] = [:]
                if let v = c.credentialId { entry["credentialId"] = v }
                if let v = c.type { entry["type"] = v }
                if let v = c.name { entry["name"] = v }
                if let v = c.username { entry["username"] = v }
                if let v = c.uri { entry["uri"] = v }
                if let v = c.domain { entry["domain"] = v }
                return entry
            },
        ])
    }

    private static func credJSON(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"encode_failed\"}"
        }
        return s
    }
}

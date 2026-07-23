// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Foundation

/// One remembered credential approval: which agent (nil = every agent) may
/// fetch credentials for which site (nil = every site), until when (nil =
/// until revoked). Timed grants live for the session only; "always" grants
/// persist across restarts and are reviewable/revocable from Settings ▸
/// Phi & AI ▸ Agent approvals. The (agent: nil, scope: nil, expires: nil)
/// grant is the "access all passwords" master switch.
struct CredentialGrant: Codable, Identifiable, Equatable {
    var id: UUID
    /// Grantee agent name; nil means the grant applies to all agents.
    var agent: String?
    /// The site the approval was asked for (e.g. "github.com"); nil = every site.
    var scope: String?
    /// Access kind the approval was given for (`CredentialAccessKind` raw
    /// value). nil (grants from before kinds existed) reads as `reveal` — they
    /// were approved under the full-disclosure wording, the widest kind.
    var kind: String?
    /// Expiry; nil = never expires (Always Allow).
    var expires: Date?
    var grantedAt: Date

    /// The all-agents / all-sites / never-expiring master grant.
    var isUniversal: Bool { agent == nil && scope == nil && expires == nil }

    var accessKind: CredentialAccessKind {
        kind.flatMap(CredentialAccessKind.init(rawValue:)) ?? .reveal
    }
}

/// What an approved request lets happen with the secret, ordered by exposure.
/// This shapes the prompt wording and the grant recorded — and for `fill` it is
/// enforced at the boundary, not merely trusted:
///
/// - `fill`: Phi performs the fill in-app (`credentials.autofill`) — the value
///   goes app → page and the agent never receives it. `credentials.get` REFUSES
///   `mode:"fill"`, so a fill can never be satisfied by revealing the plaintext
///   instead; the containment is enforced, not left to a cooperating runner.
///   (Least exposure.)
/// - `run`: the value is returned to the agent to inject into a command's
///   environment. It crosses into the agent's process (the command it spawns
///   receives it), so this is agent-level exposure the app cannot claw back —
///   the prompt says so plainly.
/// - `reveal`: the raw value goes into the agent's own context, which may record
///   it. (Widest exposure.)
///
/// A `reveal` grant covers the weaker kinds; a weaker grant never covers a
/// stronger request.
enum CredentialAccessKind: String {
    case fill
    case run
    case reveal

    /// Whether a grant of this kind satisfies a request of `requested` kind.
    func covers(_ requested: CredentialAccessKind) -> Bool {
        self == .reveal || self == requested
    }
}

/// Owns the remembered approvals. `@Published` so the settings sheet lists
/// them live; only never-expiring grants are persisted (timed ones are
/// session-scoped by design, matching the old in-memory 10-minute cache).
@MainActor
final class CredentialGrantStore: ObservableObject {
    static let shared = CredentialGrantStore()

    @Published private(set) var grants: [CredentialGrant] = []

    private let defaultsKey = "phi.credentials.approvalGrants"

    private init() {
        load()
    }

    /// Whether a live grant lets `agent` make a `kind` request for `scope`.
    ///
    /// `agent` is the connecting identity, which for an unsigned CLI agent is
    /// derived from `argv[0]`/script path and is therefore spoofable by a
    /// same-user process (see `AgentPeerIdentity` — an identification aid, not a
    /// boundary). A matching grant here suppresses the prompt, so a spoofed
    /// identity reuses that agent's standing grant silently. This is accepted
    /// residual risk (docs §7.5): the same-uid gate and the revocable, scoped
    /// grants are the mitigation, which is why grants stay keyed to a specific
    /// scope and default to timed rather than permanent.
    func covers(agent: String, scope: String, kind: CredentialAccessKind) -> Bool {
        pruneExpired()
        return grants.contains { g in
            (g.scope == nil || g.scope == scope) && (g.agent == nil || g.agent == agent)
                && g.accessKind.covers(kind)
        }
    }

    /// Whether the "access all passwords" master grant is on.
    var hasUniversalGrant: Bool {
        grants.contains { $0.isUniversal }
    }

    /// Records a grant, superseding every existing grant it fully covers so
    /// the list never shows stale duplicates (the universal grant therefore
    /// replaces the whole list). A grant only supersedes kinds it covers — a
    /// new fill-only grant leaves an existing reveal grant alone.
    func add(agent: String?, scope: String?, kind: CredentialAccessKind, expires: Date?) {
        grants.removeAll { g in
            (agent == nil || g.agent == agent) && (scope == nil || g.scope == scope)
                && kind.covers(g.accessKind)
        }
        grants.append(CredentialGrant(
            id: UUID(), agent: agent, scope: scope, kind: kind.rawValue,
            expires: expires, grantedAt: Date()))
        persist()
    }

    /// Flips the "access all passwords" master grant (reveal-kind: it stands
    /// in for approving anything, per its warning dialog).
    func setUniversalGrant(_ on: Bool) {
        if on {
            add(agent: nil, scope: nil, kind: .reveal, expires: nil)
        } else {
            grants.removeAll { $0.agent == nil && $0.scope == nil }
            persist()
        }
    }

    func revoke(_ id: UUID) {
        grants.removeAll { $0.id == id }
        persist()
    }

    func revokeAll() {
        grants.removeAll()
        persist()
    }

    /// Drops session-scoped (timed) grants, keeping "always" grants — those
    /// are standing user policy until revoked from the approvals list.
    func clearTimed() {
        grants.removeAll { $0.expires != nil }
    }

    private func pruneExpired() {
        let now = Date()
        grants.removeAll { ($0.expires ?? .distantFuture) <= now }
    }

    private func persist() {
        let persistent = grants.filter { $0.expires == nil }
        if let data = try? JSONEncoder().encode(persistent) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([CredentialGrant].self, from: data) else {
            return
        }
        grants = decoded.filter { $0.expires == nil }
    }
}

/// User mediation for agent credential requests. Every `credentials.get`
/// from an agent must clear this gate before any secret leaves the app,
/// mirroring the approve/deny step on Bitwarden Agent Access's trusted
/// device: a modal prompt that names the agent and the target, with grant
/// options from one-shot up to a persistent Always Allow (optionally for all
/// agents), so repeated requests don't nag while every standing grant stays
/// reviewable in Settings.
///
/// Main-actor isolated: it presents an `NSAlert` and owns the approval flow.
@MainActor
final class CredentialAccessCoordinator {
    static let shared = CredentialAccessCoordinator()
    private init() {}

    private enum Decision {
        case denied
        case once
        case remember(allAgents: Bool)
        case always(allAgents: Bool)
    }

    /// How long a "remember" grant suppresses re-prompting for the same
    /// (agent, scope) pair. Matches the 10-minute auto-approve window used by
    /// `ap-cli`'s listener.
    private let rememberWindow: TimeInterval = 600

    /// Presents the approval prompt (or honors a live grant) and returns
    /// whether the request may proceed. `kind` is what the approval permits —
    /// a browser fill, a command-env injection, or revealing the raw value to
    /// the agent — and is what any remembering grant records. `purpose` is an
    /// optional agent-supplied context line ("fill the password field on
    /// github.com") shown in the prompt — display-only: it does not key any
    /// grant, so it can never widen or narrow one.
    func requestApproval(agentName: String, scope: String, kind: CredentialAccessKind,
                         purpose: String? = nil) -> Bool {
        if CredentialGrantStore.shared.covers(agent: agentName, scope: scope, kind: kind) {
            return true
        }
        switch prompt(agentName: agentName, scope: scope, kind: kind, purpose: purpose) {
        case .denied:
            return false
        case .once:
            return true
        case .remember(let allAgents):
            CredentialGrantStore.shared.add(
                agent: allAgents ? nil : agentName, scope: scope, kind: kind,
                expires: Date().addingTimeInterval(rememberWindow))
            return true
        case .always(let allAgents):
            CredentialGrantStore.shared.add(
                agent: allAgents ? nil : agentName, scope: scope, kind: kind, expires: nil)
            return true
        }
    }

    /// Drops the session-scoped grants (e.g. when the provider locks or is
    /// disabled). "Always" grants persist until revoked from the approvals
    /// list in Settings.
    func clearGrants() {
        CredentialGrantStore.shared.clearTimed()
    }

    /// Prompts for the master password to unlock a locked vault in-flow (when an
    /// agent needs a credential but the session-timeout policy left the vault
    /// locked). Returns the entered password, or `nil` if cancelled / timed out.
    /// The password is handed straight to the helper by the caller and never
    /// stored by the app — keeping the "browser holds no secrets" boundary.
    func promptForUnlock(agentName: String, scope: String) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = NSLocalizedString("Unlock Bitwarden to continue", comment: "Credential unlock - title")
        alert.informativeText = String(
            format: NSLocalizedString(
                "“%@” needs a credential for %@, but your vault is locked. Enter your master password to unlock.",
                comment: "Credential unlock - body"),
            agentName, scope)

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        alert.accessoryView = field

        alert.addButton(withTitle: NSLocalizedString("Unlock", comment: "Credential unlock - unlock button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Credential unlock - cancel button"))

        // Auto-cancel if unattended, matching the approval prompt. A run-loop
        // timer, NOT DispatchQueue.main.asyncAfter: this runs inside a
        // main-actor dispatch block, and the main queue cannot drain further
        // blocks while one is executing — a queued work item would wait out
        // the modal it is supposed to end. runModal's nested run loop DOES
        // fire common-modes timers.
        let timeout = Timer(timeInterval: 60, repeats: false) { _ in NSApp.abortModal() }
        RunLoop.main.add(timeout, forMode: .common)
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        timeout.invalidate()

        guard response == .alertFirstButtonReturn else { return nil }
        let password = field.stringValue
        return password.isEmpty ? nil : password
    }

    private func prompt(agentName: String, scope: String, kind: CredentialAccessKind,
                        purpose: String?) -> Decision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch kind {
        case .fill:
            alert.messageText = String(
                format: NSLocalizedString("“%@” wants to fill your %@ login", comment: "Credential approval - fill title"),
                agentName, scope)
            alert.informativeText = NSLocalizedString(
                "Phi fills the saved login into the page itself. The agent triggers the fill but never receives the username or password.",
                comment: "Credential approval - fill body")
        case .run:
            alert.messageText = String(
                format: NSLocalizedString("“%@” wants to use your %@ credential in a command", comment: "Credential approval - run title"),
                agentName, scope)
            alert.informativeText = NSLocalizedString(
                "Phi releases the saved value to the agent so the command it runs can use it. A trustworthy agent uses it only for that, but Phi can’t stop it from keeping the value — only approve for agents and sites you trust.",
                comment: "Credential approval - run body")
        case .reveal:
            alert.messageText = String(
                format: NSLocalizedString("“%@” wants your %@ credential", comment: "Credential approval - reveal title"),
                agentName, scope)
            alert.informativeText = NSLocalizedString(
                "Approving shares the username and password with the agent, which may record them in its context. Only approve for agents and sites you trust.",
                comment: "Credential approval - reveal body")
        }
        if let purpose {
            // Agent-supplied context. Labeled as the agent's own words so a
            // misleading purpose reads as a claim, not as app UI.
            alert.informativeText += "\n\n" + String(
                format: NSLocalizedString("The agent says it needs this to: %@",
                                          comment: "Credential approval - purpose line"),
                purpose)
        }
        // The suppression checkbox widens whichever remembering grant is
        // chosen to every agent; it has no effect on Approve Once / Deny.
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = NSLocalizedString(
            "Apply to all agents, not just this one",
            comment: "Credential approval - all-agents checkbox")
        alert.addButton(withTitle: NSLocalizedString("Approve Once", comment: "Credential approval - approve once"))
        alert.addButton(withTitle: NSLocalizedString("Approve for 10 min", comment: "Credential approval - approve and remember"))
        alert.addButton(withTitle: NSLocalizedString("Always Allow", comment: "Credential approval - approve permanently"))
        alert.addButton(withTitle: NSLocalizedString("Deny", comment: "Credential approval - deny"))
        // Auto-deny if the user doesn't respond, so an agent request can't hang
        // indefinitely on an unattended prompt. A run-loop timer, NOT
        // DispatchQueue.main.asyncAfter — see promptForUnlock for why (a
        // queued main-queue block cannot run while this one is inside
        // runModal, so the deadline would never fire).
        let timeout = Timer(timeInterval: 60, repeats: false) { _ in NSApp.abortModal() }
        RunLoop.main.add(timeout, forMode: .common)
        let response = alert.runModal()
        timeout.invalidate()
        let allAgents = alert.suppressionButton?.state == .on
        switch response {
        case .alertFirstButtonReturn: return .once
        case .alertSecondButtonReturn: return .remember(allAgents: allAgents)
        case .alertThirdButtonReturn: return .always(allAgents: allAgents)
        default: return .denied   // deny button, or the auto-deny timeout
        }
    }
}

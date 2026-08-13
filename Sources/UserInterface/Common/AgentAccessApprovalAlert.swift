// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// How long a refusal should stand, as picked in the agent access alert.
///
/// Only refusals are scoped in *time*. Widening either answer to every agent is
/// the alert's one shared switch instead, so the asymmetry that remains is a
/// deliberate one: a widened refusal only ever turns agents away, while a
/// widened grant hands the browser to any same-user process without a prompt,
/// which is why the latter gets no timed middle ground and a warning of its own.
enum AgentAccessDenyScope: CaseIterable {
    /// Refuse this connection; the next one asks again.
    case thisTime
    case thirtyMinutes
    case forever

    var segmentTitle: String {
        switch self {
        case .thisTime:
            return NSLocalizedString("agentControl.connectionApproval.denyScope.thisTime", value: "Just this time", comment: "CDP consent - deny scope segment: refuse this connection only")
        case .thirtyMinutes:
            return NSLocalizedString("agentControl.connectionApproval.denyScope.thirtyMinutes", value: "For 30 min", comment: "CDP consent - deny scope segment: refuse without asking again for thirty minutes")
        case .forever:
            return NSLocalizedString("agentControl.connectionApproval.denyScope.forever", value: "Never ask again", comment: "CDP consent - deny scope segment: refuse permanently")
        }
    }

    /// When a refusal of this scope lapses — nil for a permanent one. A
    /// `.thisTime` refusal records nothing at all, so it has no deadline.
    var expiry: Date? {
        switch self {
        case .thisTime, .forever: return nil
        case .thirtyMinutes: return Date().addingTimeInterval(30 * 60)
        }
    }

    /// Whether choosing this scope records anything the user can later review.
    var isRemembered: Bool { self != .thisTime }
}

/// Outcome of the agent access alert, handed back to `AgentCDPListener`.
enum AgentAccessChoice: Equatable {
    /// Let the connection through. `remembered` is the difference between
    /// "Allow Once" (this app session) and "Always Allow" (persisted);
    /// `allAgents` widens the grant from the asking agent to every agent.
    case allow(remembered: Bool, allAgents: Bool)
    case deny(scope: AgentAccessDenyScope, allAgents: Bool)
}

/// The agent browser-control consent dialog (`PhiAlert` styling), replacing the
/// old three-button `NSAlert`. The alert raised when an agent reaches Phi's
/// socket: it names the connecting process, states plainly what CDP access
/// lets it do, and — because the socket answers whether or not the feature is
/// switched on — says so when allowing would also turn it on.
///
/// Deny carries the time-scope picker rather than the allow side: a user who is
/// being asked by something they don't recognise wants to stop being asked,
/// and sending them to Settings to arrange that is the failure this replaces.
/// That picker is a second step, revealed by pressing Deny, so the first screen
/// asks one question — allow this agent or not — and how long a refusal stands
/// is only put to a user who has already refused.
///
/// "Apply to all agents" is one switch across both steps, not one per answer:
/// it scopes *who* the decision covers, which is the same question whichever
/// button is pressed, and a copy under each would ask it twice and leave the
/// user to notice they mean different things.
struct AgentAccessApprovalAlert: View {
    let agentName: String
    /// Signing summary for the identity row, e.g. "Team 87DQ3HMK5G · verified".
    let identityDetail: String
    /// True when allowing also switches Developer mode and agent CDP access on.
    let opensGates: Bool
    let onChoice: (AgentAccessChoice) -> Void

    @State private var denyScope = AgentAccessDenyScope.thisTime
    @State private var allAgents = false
    /// Second step: the user pressed Deny and is now picking how long it holds.
    @State private var isChoosingDenyScope = false
    @State private var hasChosen = false

    @Environment(\.phiAppearance) private var appearance

    var body: some View {
        PhiAlert(title: title) {
            Image(systemName: "sparkles")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(appearance.isLight ? Color.black : Color.white)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                summaryCard
                // The banners answer "should I allow this?", which the second
                // step has already settled — the scope question takes their
                // place rather than stacking under them, so the alert doesn't
                // outgrow the height it was sized to at presentation.
                if isChoosingDenyScope {
                    denySection
                } else {
                    controlBanner
                    if opensGates {
                        enablesFeatureNote
                    }
                }
                allAgentsSection
            }
        } actions: {
            if isChoosingDenyScope {
                denyScopeActions
            } else {
                decisionActions
            }
        }
    }

    /// First step: allow this agent, or move on to scoping a refusal.
    private var decisionActions: some View {
        PhiAlertActions {
            PhiAlertButton(
                NSLocalizedString("agentControl.connectionApproval.denyButton", value: "Deny", comment: "CDP consent - deny")
            ) {
                withAnimation(.easeOut(duration: 0.18)) { isChoosingDenyScope = true }
            }
            .keyboardShortcut(.cancelAction)
        } secondaryAction: {
            PhiAlertButton(
                NSLocalizedString("agentControl.connectionApproval.allowOnceButton", value: "Allow Once", comment: "CDP consent - allow for this session")
            ) {
                choose(.allow(remembered: false, allAgents: allAgents))
            }
        } primaryAction: {
            PhiAlertButton(
                NSLocalizedString("agentControl.connectionApproval.alwaysAllowButton", value: "Always Allow", comment: "CDP consent - allow and remember"),
                role: .primary
            ) {
                choose(.allow(remembered: true, allAgents: allAgents))
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    /// Second step. Back deliberately takes no `.cancelAction`: Escape already
    /// reaches here from the first step, and binding it to Back as well would
    /// leave Escape flipping between the two steps with no way out. Escape then
    /// Return is the whole keyboard path to "deny, just this time".
    private var denyScopeActions: some View {
        PhiAlertActions {
            PhiAlertButton(
                NSLocalizedString("agentControl.connectionApproval.backButton", value: "Back", comment: "CDP consent - return from the deny scope step to the allow-or-deny decision")
            ) {
                withAnimation(.easeOut(duration: 0.18)) { isChoosingDenyScope = false }
            }
        } primaryAction: {
            PhiAlertButton(
                NSLocalizedString("agentControl.connectionApproval.denyButton", value: "Deny", comment: "CDP consent - deny"),
                role: .primary
            ) {
                // A "Just this time" refusal records nothing, so there is
                // nothing for the switch to widen.
                choose(.deny(scope: denyScope, allAgents: allAgents && denyScope.isRemembered))
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func choose(_ choice: AgentAccessChoice) {
        guard !hasChosen else { return }
        hasChosen = true
        onChoice(choice)
    }

    private var title: String {
        String(
            format: NSLocalizedString("agentControl.connectionApproval.title", value: "“%@” wants to control Phi Browser",
                                      comment: "CDP consent - title"),
            agentName)
    }

    // MARK: - Summary card

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow(
                label: NSLocalizedString("agentControl.connectionApproval.agentLabel", value: "Agent", comment: "CDP consent - agent row label"),
                value: agentName
            ) {
                CredentialAgentIcon(agentName: agentName, size: 12, weight: .medium)
                    .themedForeground(.textSecondary)
            }
            Divider()
                .padding(.leading, 12)
            summaryRow(
                label: NSLocalizedString("agentControl.connectionApproval.identityLabel", value: "Identity", comment: "CDP consent - code signing identity row label"),
                value: identityDetail
            ) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 12, weight: .medium))
                    .themedForeground(.textSecondary)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(appearance.isLight ? Color.black.opacity(0.045) : Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(appearance.isLight ? Color.black.opacity(0.06) : Color.white.opacity(0.08))
        )
    }

    private func summaryRow(label: String, value: String,
                            @ViewBuilder icon: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon()
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .themedForeground(.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Banners

    private var controlBanner: some View {
        banner(
            symbol: "hand.raised.fill",
            color: Color(nsColor: .systemOrange),
            headline: NSLocalizedString("agentControl.connectionApproval.control.headline", value: "Full control of this browser",
                                        comment: "CDP consent - headline naming what agent access grants"),
            detail: NSLocalizedString("agentControl.connectionApproval.message", value: "An agent is asking to drive Phi Browser over the DevTools Protocol — opening pages, reading content, and acting on your behalf. Only allow agents you trust.",
                                      comment: "CDP consent - body"))
    }

    private var enablesFeatureNote: some View {
        banner(
            symbol: "switch.2",
            color: Color(nsColor: .systemBlue),
            headline: NSLocalizedString("agentControl.connectionApproval.enablesFeature.headline", value: "Agent control is currently off",
                                        comment: "CDP consent - headline shown when allowing will also enable the feature"),
            detail: NSLocalizedString("agentControl.connectionApproval.enablesFeatureNote", value: "Allowing also turns on Developer mode and “Allow agents to control Phi (CDP)” in Settings; you can switch them back off there at any time.",
                                      comment: "CDP consent - body of the banner shown when allowing will also enable the developer mode and agent control settings"))
    }

    private func banner(symbol: String, color: Color,
                        headline: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                Text(detail)
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(appearance.isLight ? 0.09 : 0.15))
        )
    }

    // MARK: - All-agents scope

    /// Widens whichever button is pressed from the asking agent to every agent,
    /// so it stands across both steps. On the first it must stay live whatever
    /// the eventual answer; on the second the answer is known, so it follows the
    /// deny scope and goes inert for "Just this time", which records nothing to
    /// widen.
    ///
    /// The warning is one-sided on purpose, and belongs to the first step only:
    /// widening a refusal merely turns more agents away, while widening a grant
    /// is the single answer here that stops the prompt appearing at all.
    private var allAgentsSection: some View {
        let isInert = isChoosingDenyScope && !denyScope.isRemembered
        return VStack(alignment: .leading, spacing: 8) {
            allAgentsRow
                .disabled(isInert)
                .opacity(isInert ? 0.4 : 1)
            if allAgents, !isChoosingDenyScope {
                Text(NSLocalizedString("agentControl.connectionApproval.allAgentsScope.allowWarning", value: "If you allow, every agent that connects gets full control without asking you. Reverse it anytime in Settings ▸ Developer.",
                                       comment: "CDP consent - warning shown when the answer is widened to every agent, naming what that means on the allow side"))
                    .font(.system(size: 11))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeOut(duration: 0.15), value: allAgents)
        .animation(.easeOut(duration: 0.15), value: isInert)
    }

    private var allAgentsRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 13, weight: .medium))
                .themedForeground(.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("agentControl.connectionApproval.allAgentsScope.title", value: "Apply to all agents",
                                       comment: "CDP consent - title of the switch that widens the answer from the asking agent to every agent"))
                    .font(.system(size: 12, weight: .medium))
                    .themedForeground(.textPrimary)
                Text(String(
                    format: NSLocalizedString("agentControl.connectionApproval.allAgentsScope.description", value: "Your answer covers every agent, not just “%@”.",
                                              comment: "CDP consent - explanation of the all-agents switch; %@ is the name of the agent asking for access"),
                    agentName))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $allAgents)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .themedTint(.themeColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(appearance.isLight ? Color.black.opacity(0.045) : Color.white.opacity(0.06))
        )
    }

    // MARK: - Deny scope

    private var denySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("agentControl.connectionApproval.denyScope.label", value: "How long should Phi refuse?",
                                   comment: "CDP consent - label over the picker that scopes the refusal, shown after the user presses Deny"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
            PhiAlertSegmentedPicker(
                options: AgentAccessDenyScope.allCases,
                selection: $denyScope,
                title: \.segmentTitle)
            if denyScope == .forever {
                Text(NSLocalizedString("agentControl.connectionApproval.denyScope.reviewHint", value: "Blocked agents can be unblocked anytime in Settings ▸ Developer.",
                                       comment: "CDP consent - hint shown when the permanent deny scope is selected"))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
            }
        }
        .animation(.easeOut(duration: 0.15), value: denyScope)
    }

}

#if DEBUG
#Preview("Agent access — feature already on") {
    AgentAccessApprovalAlert(
        agentName: "claude-code",
        identityDetail: "Team Q6L2SF6YDW · verified",
        opensGates: false
    ) { _ in }
        .padding(40)
        .background(Color(nsColor: .underPageBackgroundColor))
}

#Preview("Agent access — allowing turns it on") {
    AgentAccessApprovalAlert(
        agentName: "pi",
        identityDetail: "unsigned",
        opensGates: true
    ) { _ in }
        .preferredColorScheme(.dark)
        .padding(40)
        .background(Color(nsColor: .underPageBackgroundColor))
}
#endif

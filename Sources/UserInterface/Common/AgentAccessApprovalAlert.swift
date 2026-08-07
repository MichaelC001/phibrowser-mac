// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// How long a refusal should stand, as picked in the agent access alert.
///
/// Only the deny side is scoped. Allowing stays a straight two-way choice
/// (this session / remembered) because widening a *grant* to every agent
/// would hand any same-user process the browser without a prompt, while
/// widening a *refusal* only ever turns agents away.
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
    case allowOnce
    case allowAlways
    case deny(scope: AgentAccessDenyScope, allAgents: Bool)
}

/// The agent browser-control consent dialog (`PhiAlert` styling), replacing the
/// old three-button `NSAlert`. The alert raised when an agent reaches Phi's
/// socket: it names the connecting process, states plainly what CDP access
/// lets it do, and — because the socket answers whether or not the feature is
/// switched on — says so when allowing would also turn it on.
///
/// Deny carries the scope picker rather than the allow side: a user who is
/// being asked by something they don't recognise wants to stop being asked,
/// and sending them to Settings to arrange that is the failure this replaces.
struct AgentAccessApprovalAlert: View {
    let agentName: String
    /// Signing summary for the identity row, e.g. "Team 87DQ3HMK5G · verified".
    let identityDetail: String
    /// True when allowing also switches Developer mode and agent CDP access on.
    let opensGates: Bool
    let onChoice: (AgentAccessChoice) -> Void

    @State private var denyScope = AgentAccessDenyScope.thisTime
    @State private var allAgents = false
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
                controlBanner
                if opensGates {
                    enablesFeatureNote
                }
                denySection
            }
        } actions: {
            PhiAlertActions {
                PhiAlertButton(
                    NSLocalizedString("agentControl.connectionApproval.denyButton", value: "Deny", comment: "CDP consent - deny")
                ) {
                    choose(.deny(scope: denyScope, allAgents: allAgents && denyScope.isRemembered))
                }
                .keyboardShortcut(.cancelAction)
            } secondaryAction: {
                PhiAlertButton(
                    NSLocalizedString("agentControl.connectionApproval.allowOnceButton", value: "Allow Once", comment: "CDP consent - allow for this session")
                ) {
                    choose(.allowOnce)
                }
            } primaryAction: {
                PhiAlertButton(
                    NSLocalizedString("agentControl.connectionApproval.alwaysAllowButton", value: "Always Allow", comment: "CDP consent - allow and remember"),
                    role: .primary
                ) {
                    choose(.allowAlways)
                }
                .keyboardShortcut(.defaultAction)
            }
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

    // MARK: - Deny scope

    private var denySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("agentControl.connectionApproval.denyScope.label", value: "If you deny:",
                                   comment: "CDP consent - label over the picker that scopes the Deny button"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
            PhiAlertSegmentedPicker(
                options: AgentAccessDenyScope.allCases,
                selection: $denyScope,
                title: \.segmentTitle)
            allAgentsRow
            if denyScope == .forever {
                Text(NSLocalizedString("agentControl.connectionApproval.denyScope.reviewHint", value: "Blocked agents can be unblocked anytime in Settings ▸ Developer.",
                                       comment: "CDP consent - hint shown when the permanent deny scope is selected"))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
            }
        }
        .animation(.easeOut(duration: 0.15), value: denyScope)
    }

    /// Widens the refusal from the asking agent to every agent. Inert while
    /// "Just this time" is selected, which remembers nothing to widen.
    private var allAgentsRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "nosign")
                .font(.system(size: 13, weight: .medium))
                .themedForeground(.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("agentControl.connectionApproval.denyScope.allAgentsTitle", value: "Apply to all agents",
                                       comment: "CDP consent - all-agents deny row title"))
                    .font(.system(size: 12, weight: .medium))
                    .themedForeground(.textPrimary)
                Text(String(
                    format: NSLocalizedString("agentControl.connectionApproval.denyScope.allAgentsDescription", value: "Turn away every agent, not just “%@”.",
                                              comment: "CDP consent - all-agents deny row explanation"),
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
        .disabled(!denyScope.isRemembered)
        .opacity(denyScope.isRemembered ? 1 : 0.4)
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

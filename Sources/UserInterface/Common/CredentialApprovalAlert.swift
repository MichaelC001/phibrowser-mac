// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

/// How long an approval should stand, as picked in the approval alert.
enum CredentialApprovalDuration: CaseIterable {
    case once
    case tenMinutes
    case always

    var segmentTitle: String {
        switch self {
        case .once:
            return NSLocalizedString("common.credentialApproval.durationSegment.onlyOnce", value: "Only once", comment: "Credential approval - duration segment")
        case .tenMinutes:
            return NSLocalizedString("common.credentialApproval.durationSegment.for10Min", value: "For 10 min", comment: "Credential approval - duration segment")
        case .always:
            return NSLocalizedString("common.credentialApproval.durationSegment.always", value: "Always", comment: "Credential approval - duration segment")
        }
    }

}

/// Outcome of the approval alert, handed back to the coordinator.
enum CredentialApprovalChoice {
    case deny
    case allow(duration: CredentialApprovalDuration, allAgents: Bool)
}

/// The agent credential approval dialog (`PhiAlert` styling). One decision —
/// Deny or Approve — with the approval's lifetime picked separately, replacing
/// the old four-button `NSAlert` row. The exposure banner is the load-bearing
/// element: it states, color-coded by severity, whether the secret stays
/// inside Phi (fill), crosses into a command's environment (run), or is
/// handed to the agent outright (reveal).
struct CredentialApprovalAlert: View {
    let agentName: String
    let scope: String
    let kind: CredentialAccessKind
    let purpose: String?
    let onChoice: (CredentialApprovalChoice) -> Void

    /// Auto-deny deadline, so an agent request can't hang on an unattended
    /// prompt. Shown as a live countdown rather than expiring silently.
    static let timeoutSeconds = 60

    @State private var duration = CredentialApprovalDuration.once
    @State private var allAgents = false
    @State private var secondsRemaining = CredentialApprovalAlert.timeoutSeconds
    @State private var hasChosen = false

    @Environment(\.phiAppearance) private var appearance

    private let countdown = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        PhiAlert(title: title) {
            Image(systemName: "key.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(appearance.isLight ? Color.black : Color.white)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                summaryCard
                exposureBanner
                if let purpose {
                    purposeView(purpose)
                }
                durationSection
                countdownFootnote
            }
        } actions: {
            PhiAlertActions {
                PhiAlertButton(
                    NSLocalizedString("common.credentialApproval.deny", value: "Deny", comment: "Credential approval - deny")
                ) {
                    choose(.deny)
                }
                .keyboardShortcut(.cancelAction)
            } primaryAction: {
                PhiAlertButton(
                    NSLocalizedString("common.credentialApproval.approve", value: "Approve", comment: "Credential approval - approve"),
                    role: .primary
                ) {
                    choose(.allow(duration: duration, allAgents: allAgents))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .onReceive(countdown) { _ in
            guard !hasChosen else { return }
            secondsRemaining -= 1
            if secondsRemaining <= 0 {
                choose(.deny)
            }
        }
    }

    private func choose(_ choice: CredentialApprovalChoice) {
        guard !hasChosen else { return }
        hasChosen = true
        onChoice(choice)
    }

    private var title: String {
        switch kind {
        case .fill:
            return String(
                format: NSLocalizedString("common.credentialApproval.autofillRequest.title", value: "Autofill request from “%@”",
                                          comment: "Credential approval - fill title"),
                agentName)
        case .run, .reveal:
            return String(
                format: NSLocalizedString("common.credentialApproval.valueRequest.title", value: "Credential request from “%@”",
                                          comment: "Credential approval - title"),
                agentName)
        }
    }

    // MARK: - Summary card

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow(label: NSLocalizedString("common.credentialApproval.agentLabel", value: "Agent", comment: "Credential approval - agent row"),
                       value: agentName) {
                CredentialAgentIcon(agentName: agentName, size: 12, weight: .medium)
                    .themedForeground(.textSecondary)
            }
            Divider()
                .padding(.leading, 12)
            summaryRow(icon: scopeIcon, label: scopeLabel, value: scope)
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

    private func summaryRow(icon: String, label: String, value: String) -> some View {
        summaryRow(label: label, value: value) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .themedForeground(.textSecondary)
        }
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

    private var scopeLabel: String {
        kind == .fill
            ? NSLocalizedString("common.credentialApproval.siteLabel", value: "Site", comment: "Credential approval - site row")
            : NSLocalizedString("common.credentialApproval.credentialLabel", value: "Credential", comment: "Credential approval - credential row")
    }

    private var scopeIcon: String {
        scope.contains(".") && !scope.hasPrefix("item ") ? "globe" : "key.fill"
    }

    // MARK: - Exposure banner

    private var exposureBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: exposure.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(exposure.color)
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(exposure.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(exposure.color)
                Text(exposure.detail)
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(exposure.color.opacity(appearance.isLight ? 0.09 : 0.15))
        )
    }

    private var exposure: (symbol: String, color: Color, headline: String, detail: String) {
        switch kind {
        case .fill:
            return (
                "checkmark.shield.fill",
                Color(nsColor: .systemGreen),
                NSLocalizedString("common.credentialApproval.autofillRequest.headline", value: "Autofill only — the secret stays in Phi",
                                  comment: "Credential approval - fill headline"),
                NSLocalizedString("common.credentialApproval.autofillRequest.explanation", value: "Phi fills the saved login into the page itself. The agent triggers the fill but never receives the username or password.",
                    comment: "Credential approval - fill body")
            )
        case .run:
            return (
                "terminal.fill",
                Color(nsColor: .systemOrange),
                NSLocalizedString("common.credentialApproval.commandUseRequest.headline", value: "Released into a command",
                                  comment: "Credential approval - run headline"),
                NSLocalizedString("common.credentialApproval.valueRequest.loginExplanation", value: "Phi releases the saved value to the agent so the command it runs can use it. Phi can’t stop the agent from keeping the value — only approve for agents and sites you trust.",
                    comment: "Credential approval - run body")
            )
        case .reveal:
            return (
                "eye.fill",
                Color(nsColor: .systemRed),
                NSLocalizedString("common.credentialApproval.fullAccessRequest.headline", value: "Revealed to the agent",
                                  comment: "Credential approval - reveal headline"),
                NSLocalizedString("common.credentialApproval.valueRequest.sensitiveItemExplanation", value: "The saved item — a password, note, card, identity, or key — is shared with the agent, which may record it in its context. Only approve for agents and items you trust.",
                    comment: "Credential approval - reveal body")
            )
        }
    }

    // MARK: - Purpose

    /// Agent-supplied context, framed as the agent's own words so a misleading
    /// purpose reads as a claim, not as app UI.
    private func purposeView(_ purpose: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("common.credentialApproval.reasonLabel", value: "The agent says it needs this to:",
                                   comment: "Credential approval - purpose label"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
            Text(purpose)
                .font(.system(size: 12).italic())
                .themedForeground(.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 11)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .themedFill(.separator)
                        .frame(width: 3)
                }
        }
    }

    // MARK: - Duration

    private var durationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            CredentialDurationPicker(selection: $duration)
            allAgentsRow
            if duration == .always {
                Text(NSLocalizedString("common.credentialApproval.securityHint", value: "Standing approvals can be reviewed and revoked anytime in Settings.",
                    comment: "Credential approval - always hint"))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
            }
        }
        .animation(.easeOut(duration: 0.15), value: duration)
    }

    /// Widens the grantee from the requesting agent to every agent: a card
    /// row in the summary card's visual language — glyph, titled explanation,
    /// switch — instead of a bare checkbox. Inert (dimmed, switch disabled)
    /// while "Only once" is selected, since a one-shot approval names no
    /// grantee at all.
    private var allAgentsRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .themedForeground(.textSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("common.credentialApproval.scope.allAgentsTitle", value: "Apply to all agents",
                                       comment: "Credential approval - all-agents row title"))
                    .font(.system(size: 12, weight: .medium))
                    .themedForeground(.textPrimary)
                Text(String(
                    format: NSLocalizedString("common.credentialApproval.allAgentsDescription", value: "Any agent may use this approval, not just “%@”.",
                        comment: "Credential approval - all-agents row explanation"),
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
        .disabled(duration == .once)
        .opacity(duration == .once ? 0.4 : 1)
    }

    private var countdownFootnote: some View {
        Text(String(
            format: NSLocalizedString("common.credentialApproval.autoDenyCountdown", value: "Auto-denies in %d s",
                                      comment: "Credential approval - auto-deny countdown"),
            max(secondsRemaining, 0)))
            .font(.system(size: 11))
            .monospacedDigit()
            .themedForeground(.textTertiary)
    }
}

/// Segmented Once / 10 min / Always control matching the alert's rounded
/// styling (a native segmented control would fight the material surface).
private struct CredentialDurationPicker: View {
    @Binding var selection: CredentialApprovalDuration

    @Environment(\.phiAppearance) private var appearance
    @Namespace private var segmentNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CredentialApprovalDuration.allCases, id: \.self) { option in
                segment(option)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(appearance.isLight ? Color.black.opacity(0.05) : Color.white.opacity(0.08))
        )
    }

    private func segment(_ option: CredentialApprovalDuration) -> some View {
        let isSelected = selection == option
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                selection = option
            }
        } label: {
            Text(option.segmentTitle)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .themedForeground(.textPrimary)
                .lineLimit(1)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(appearance.isLight ? Color.white : Color.white.opacity(0.22))
                    .shadow(color: .black.opacity(appearance.isLight ? 0.12 : 0.3),
                            radius: 1.5, y: 0.5)
                    .matchedGeometryEffect(id: "selectedSegment", in: segmentNamespace)
            }
        }
    }
}

/// The requesting agent's icon in credential approval UI: the bundled brand
/// glyph when the name maps to a known agent (same mapping as the Space
/// control pill), else the generic sparkles agent symbol. `size` is the
/// SF-symbol point size to optically match; the brand asset's canvas is
/// widened by `assetInkRatio` so its ink — not its padded canvas — fills
/// that size. Renders template-style, so it inherits the foreground color of
/// the row it sits in.
struct CredentialAgentIcon: View {
    /// nil (or empty) means "all agents" / an unidentified agent — always the
    /// generic glyph.
    let agentName: String?
    let size: CGFloat
    var weight: Font.Weight = .regular

    var body: some View {
        if let asset = badgeAsset {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size / AgentDriverBadge.assetInkRatio,
                       height: size / AgentDriverBadge.assetInkRatio)
                .alignmentGuide(.firstTextBaseline) { d in
                    // Rest the glyph's ink — inset from the canvas edge by the
                    // normalized padding — on the text baseline.
                    d[.bottom] - d.height * (1 - AgentDriverBadge.assetInkRatio) / 2
                }
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: size, weight: weight))
        }
    }

    private var badgeAsset: String? {
        guard let agentName, !agentName.isEmpty else { return nil }
        return AgentDriverBadge.make(agentName: agentName, origin: .cdp).assetName
    }
}

/// The in-flow vault unlock prompt (`PhiAlert` styling): shown when an agent
/// needs a credential but the session-timeout policy left the vault locked.
/// The entered password goes straight to the caller and is never stored.
struct CredentialUnlockAlert: View {
    let agentName: String
    let scope: String
    /// Called exactly once: the entered master password, or nil on cancel /
    /// timeout.
    let onSubmit: (String?) -> Void

    @State private var password = ""
    @State private var secondsRemaining = CredentialApprovalAlert.timeoutSeconds
    @State private var hasSubmitted = false
    @FocusState private var passwordFocused: Bool

    @Environment(\.phiAppearance) private var appearance

    private let countdown = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        PhiAlert(title: NSLocalizedString("common.credentialUnlock.title", value: "Unlock Bitwarden to continue",
                                          comment: "Credential unlock - title")) {
            Image(systemName: "lock.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(appearance.isLight ? Color.black : Color.white)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(
                    format: NSLocalizedString("common.credentialUnlock.message", value: "“%@” needs a credential for %@, but your vault is locked. Enter your master password to unlock.",
                        comment: "Credential unlock - body"),
                    agentName, scope))
                    .fixedSize(horizontal: false, vertical: true)
                SecureField(NSLocalizedString("common.credentialUnlock.masterPasswordPlaceholder", value: "Master password",
                                              comment: "Credential unlock - field placeholder"),
                            text: $password)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                    .focused($passwordFocused)
                    .onSubmit(submit)
                Text(String(
                    format: NSLocalizedString("common.credentialUnlock.autoCancelCountdown", value: "Auto-cancels in %d s",
                                              comment: "Credential unlock - auto-cancel countdown"),
                    max(secondsRemaining, 0)))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .themedForeground(.textTertiary)
            }
        } actions: {
            PhiAlertActions {
                PhiAlertButton(
                    NSLocalizedString("common.credentialUnlock.cancelButton", value: "Cancel", comment: "Credential unlock - cancel button")
                ) {
                    finish(nil)
                }
                .keyboardShortcut(.cancelAction)
            } primaryAction: {
                PhiAlertButton(
                    NSLocalizedString("common.credentialUnlock.unlockButton", value: "Unlock", comment: "Credential unlock - unlock button"),
                    role: .primary,
                    action: submit
                )
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
                .opacity(password.isEmpty ? 0.5 : 1)
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                passwordFocused = true
            }
        }
        .onReceive(countdown) { _ in
            guard !hasSubmitted else { return }
            secondsRemaining -= 1
            if secondsRemaining <= 0 {
                finish(nil)
            }
        }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        finish(password)
    }

    private func finish(_ value: String?) {
        guard !hasSubmitted else { return }
        hasSubmitted = true
        onSubmit(value)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Fill") {
    CredentialApprovalAlert(
        agentName: "claude",
        scope: "github.com",
        kind: .fill,
        purpose: "fill the password field on the GitHub sign-in page",
        onChoice: { _ in }
    )
    .padding(40)
    .background(Color(nsColor: .underPageBackgroundColor))
}

#Preview("Run - Dark") {
    CredentialApprovalAlert(
        agentName: "deploy-bot",
        scope: "registry.npmjs.org",
        kind: .run,
        purpose: "publish the package with npm publish",
        onChoice: { _ in }
    )
    .environment(\.phiAppearance, .dark)
    .preferredColorScheme(.dark)
    .padding(40)
    .background(Color(nsColor: .underPageBackgroundColor))
}

#Preview("Reveal - No Purpose") {
    CredentialApprovalAlert(
        agentName: "An agent",
        scope: "item 3f2a09aa-91c2-4de1-b8f0-1a2b3c4d5e6f",
        kind: .reveal,
        purpose: nil,
        onChoice: { _ in }
    )
    .padding(40)
    .background(Color(nsColor: .underPageBackgroundColor))
}

#Preview("Unlock") {
    CredentialUnlockAlert(
        agentName: "claude",
        scope: "github.com",
        onSubmit: { _ in }
    )
    .padding(40)
    .background(Color(nsColor: .underPageBackgroundColor))
}
#endif

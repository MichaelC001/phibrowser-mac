// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Developer-pane section for the Bitwarden credential provider, always
/// visible in the pane (not behind the CDP gate — vault login and session
/// settings stay reachable while agent access is off). A master
/// toggle enables Bitwarden (persists the OOBE-mirrored `bitwardenEnabled`
/// pref; when the extension is missing it suggests a Chrome Web Store install
/// and only installs on consent); when on, a status row driven by
/// `BitwardenService.currentStatus` shows whether the vault is signed out,
/// locked, or ready, with the matching sign-in / unlock / sign-out action,
/// followed by the session-timeout policy rows.
///
/// Visual language matches the settings panes by reusing `settingsCardChrome()`
/// and the section-title styling.
struct PasswordManagerSectionView: View {
    @ObservedObject private var bitwarden = BitwardenService.shared

    @AppStorage(PhiPreferences.PasswordManagerSettings.bitwardenEnabled.rawValue)
    private var bitwardenEnabled: Bool = PhiPreferences.PasswordManagerSettings.bitwardenEnabled.defaultValue

    @State private var loginSheetMode: BitwardenLoginSheet.Mode?
    @State private var showInstallExtensionPrompt = false
    @State private var showApprovalList = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(NSLocalizedString("Agent Password Manager", comment: "Phi & AI settings - Agent Password Manager section title"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)

            VStack(spacing: 10) {
                // The provider: account state and session policy — all
                // Bitwarden settings live in this one card.
                VStack(spacing: 0) {
                    enableRow
                    if bitwardenEnabled {
                        Divider()
                        statusRow
                        Divider()
                        BitwardenSessionTimeoutRows()
                    }
                }
                .padding(.horizontal, 12)
                .settingsCardChrome()

                // What agents may do with the vault — its own card.
                if bitwardenEnabled {
                    VStack(spacing: 0) {
                        approvalsRow
                    }
                    .padding(.horizontal, 12)
                    .settingsCardChrome()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showApprovalList) {
            CredentialApprovalListSheet()
        }
        .task {
            await bitwarden.refreshStatus()
            // Make sure a running helper reflects the current timeout policy.
            await bitwarden.applyTimeoutPolicy()
        }
        .sheet(item: $loginSheetMode) { mode in
            BitwardenLoginSheet(mode: mode) {
                Task { await bitwarden.refreshStatus() }
            }
        }
        .alert(
            NSLocalizedString("Install Bitwarden Extension?", comment: "Phi & AI settings - Alert title suggesting the Bitwarden browser extension install"),
            isPresented: $showInstallExtensionPrompt
        ) {
            Button(NSLocalizedString("Install", comment: "Phi & AI settings - Button that installs the Bitwarden browser extension")) {
                installBitwardenExtension()
            }
            Button(NSLocalizedString("Not Now", comment: "Phi & AI settings - Button that dismisses the Bitwarden extension install suggestion"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("The Bitwarden browser extension autofills your vault logins on web pages. Phi can install it from the Chrome Web Store now.", comment: "Phi & AI settings - Alert message explaining the suggested Bitwarden extension install"))
        }
    }

    // MARK: - Rows

    private var enableRow: some View {
        HStack(spacing: 12) {
            Image(.bitwardenIcon)
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(NSLocalizedString("Bitwarden password manager", comment: "Phi & AI settings - Bitwarden toggle title"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Text(NSLocalizedString("Logins for Phi and agent requests, held by a separate helper — passwords never touch the browser process.", comment: "Phi & AI settings - Bitwarden toggle explanation"))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { bitwardenEnabled },
                set: { newValue in
                    bitwardenEnabled = newValue
                    handleToggle(newValue)
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .themedTint(.themeColor)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            SettingsIconChip(systemName: statusSymbol, color: statusColor)
            Text(statusText)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            actionButtons
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Entry point to the remembered-approvals list: which agents may fetch
    /// which site's credentials without being asked again. A whole-row
    /// disclosure like the Spaces pane's "URL Rules…" row.
    private var approvalsRow: some View {
        Button {
            showApprovalList = true
        } label: {
            HStack(spacing: 12) {
                SettingsIconChip(systemName: "key.fill", color: .indigo)
                Text(NSLocalizedString("Agent Credential Approvals\u{2026}", comment: "Phi & AI settings - approvals row title"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .themedForeground(.textSecondary)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Review and revoke which agents may use your saved logins without asking",
                                comment: "Phi & AI settings - tooltip for the approvals row"))
    }

    // MARK: - Status → text/color/action

    private var statusColor: Color {
        switch bitwarden.currentStatus {
        case .ready: return .green
        case .locked: return .orange
        case .loggedOut: return .gray
        case .notInstalled, .unavailable: return .red
        }
    }

    private var statusSymbol: String {
        switch bitwarden.currentStatus {
        case .ready: return "checkmark"
        case .locked: return "lock.fill"
        case .loggedOut: return "person.fill"
        case .notInstalled, .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    private var statusText: String {
        switch bitwarden.currentStatus {
        case .ready(let account):
            if let account, !account.isEmpty {
                return String(format: NSLocalizedString("Signed in as %@", comment: "Phi & AI settings - Bitwarden ready status with account"), account)
            }
            return NSLocalizedString("Signed in", comment: "Phi & AI settings - Bitwarden ready status")
        case .locked:
            return NSLocalizedString("Locked", comment: "Phi & AI settings - Bitwarden locked status")
        case .loggedOut:
            return NSLocalizedString("Not signed in", comment: "Phi & AI settings - Bitwarden signed-out status")
        case .notInstalled:
            return NSLocalizedString("Bitwarden helper not available", comment: "Phi & AI settings - Bitwarden helper missing status")
        case .unavailable(let reason):
            return reason
        }
    }

    /// Explicit Log In / Unlock / Log Out controls, shown per state:
    /// signed out → Log In; locked → Unlock + Log Out; signed in → Log Out.
    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 8) {
            switch bitwarden.currentStatus {
            case .loggedOut:
                logInButton
            case .locked:
                unlockButton
                logOutButton
            case .ready:
                logOutButton
            case .notInstalled, .unavailable:
                EmptyView()
            }
        }
    }

    private var logInButton: some View {
        Button(NSLocalizedString("Log In\u{2026}", comment: "Phi & AI settings - Bitwarden log in action")) {
            loginSheetMode = .login
        }
        .controlSize(.small)
    }

    private var unlockButton: some View {
        Button(NSLocalizedString("Unlock\u{2026}", comment: "Phi & AI settings - Bitwarden unlock action")) {
            loginSheetMode = .unlock
        }
        .controlSize(.small)
    }

    private var logOutButton: some View {
        Button(NSLocalizedString("Log Out", comment: "Phi & AI settings - Bitwarden log out action")) {
            Task {
                try? await BitwardenService.shared.logout()
                await bitwarden.refreshStatus()
            }
        }
        .controlSize(.small)
    }

    // MARK: - Toggle handling

    private func handleToggle(_ enabled: Bool) {
        if enabled {
            suggestExtensionInstallIfNeeded()
            Task { await bitwarden.refreshStatus() }
        } else {
            // Leave the account authenticated on disk but lock the in-memory
            // vault so a disabled provider holds no live key, and drop the
            // session-scoped agent approvals. "Always" grants stay for a later
            // re-enable but are inert meanwhile: the credentials.* routes check
            // the toggle and refuse every request while it is off.
            CredentialAccessCoordinator.shared.clearGrants()
            Task { await BitwardenService.shared.lock() }
        }
    }

    /// Enabling the provider never installs the extension silently: when it is
    /// missing (or its presence can't be determined), suggest the install and
    /// let the user decide.
    private func suggestExtensionInstallIfNeeded() {
        guard let windowId = MainBrowserWindowControllersManager.shared.getFirstAvailableWindowId() else {
            showInstallExtensionPrompt = true
            return
        }
        ChromiumLauncher.sharedInstance().bridge?.getAllExtensions(completion: { infos in
            let installed = (infos as? [[String: Any]])?
                .contains { $0["id"] as? String == PhiExtensionID.bitwarden } ?? false
            if !installed {
                DispatchQueue.main.async { showInstallExtensionPrompt = true }
            }
        }, windowId: Int64(windowId))
    }

    private func installBitwardenExtension() {
        guard let windowId = MainBrowserWindowControllersManager.shared.getFirstAvailableWindowId() else {
            AppLogWarn("[PasswordManager] No available window ID for Bitwarden extension install")
            return
        }
        ChromiumLauncher.sharedInstance().bridge?.installExtensions(
            withIds: [PhiExtensionID.bitwarden],
            windowId: Int64(windowId)
        )
        AppLogInfo("[PasswordManager] Requested install of Bitwarden extension")
    }
}

/// System-Settings-style leading icon: a white glyph on a small colored
/// rounded square. Gives every row of the Agent Password Manager section one
/// aligned 24pt gutter, whatever the row is about.
struct SettingsIconChip: View {
    let systemName: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(color.gradient)
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

/// Lets `BitwardenLoginSheet.Mode` drive a `.sheet(item:)` presentation.
extension BitwardenLoginSheet.Mode: Identifiable {
    var id: Int {
        switch self {
        case .login: return 0
        case .unlock: return 1
        }
    }
}

/// The remembered-approvals list: every live credential grant — who (an agent
/// or all agents), for which site, for how long — each revocable, with a
/// revoke-all. Backed live by `CredentialGrantStore`, so a grant added by an
/// approval prompt while the sheet is open appears immediately.
struct CredentialApprovalListSheet: View {
    @ObservedObject private var store = CredentialGrantStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAllAccessConfirm = false

    /// The per-site grants shown as rows; the universal grant is represented
    /// by the toggle above the list instead.
    private var listedGrants: [CredentialGrant] {
        store.grants.filter { !$0.isUniversal }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Agent Credential Approvals", comment: "Approvals sheet - title"))
                .font(.system(size: 15, weight: .semibold))
                .themedForeground(.textPrimary)
            Text(NSLocalizedString("These grants let agents use your saved logins without asking each time. “Always” grants persist until you revoke them here.", comment: "Approvals sheet - explanation"))
                .font(.system(size: 11))
                .themedForeground(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            allAccessRow

            if listedGrants.isEmpty {
                Text(NSLocalizedString("No remembered approvals.", comment: "Approvals sheet - empty state"))
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(listedGrants) { grant in
                            grantRow(grant)
                            if grant.id != listedGrants.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(minHeight: 120, maxHeight: 280)
                .settingsCardChrome()
            }

            HStack {
                Button(NSLocalizedString("Revoke All", comment: "Approvals sheet - revoke all button")) {
                    store.revokeAll()
                }
                .controlSize(.small)
                .disabled(store.grants.isEmpty)
                Spacer()
                Button(NSLocalizedString("Done", comment: "Approvals sheet - done button")) {
                    dismiss()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .alert(
            NSLocalizedString("Allow agents to access all passwords?", comment: "Approvals sheet - all-access confirm title"),
            isPresented: $showAllAccessConfirm
        ) {
            Button(NSLocalizedString("Allow All", comment: "Approvals sheet - all-access confirm button"), role: .destructive) {
                store.setUniversalGrant(true)
            }
            Button(NSLocalizedString("Cancel", comment: "Approvals sheet - all-access cancel button"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("Every agent will be able to use any login in your vault without asking you first. A misled agent could fill or reveal a password anywhere. You can turn this off here at any time.", comment: "Approvals sheet - all-access confirm message"))
        }
    }

    /// Master switch: the (all agents, all sites, never expires) grant.
    private var allAccessRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Allow access to all passwords", comment: "Approvals sheet - all-access toggle title"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Text(NSLocalizedString("Any agent may use any saved login without asking. The per-site grants below are unnecessary while this is on.", comment: "Approvals sheet - all-access toggle explanation"))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { store.hasUniversalGrant },
                set: { on in
                    if on {
                        showAllAccessConfirm = true
                    } else {
                        store.setUniversalGrant(false)
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .themedTint(.themeColor)
        }
        .padding(12)
        .settingsCardChrome()
    }

    private func grantRow(_ grant: CredentialGrant) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(grant.scope
                        ?? NSLocalizedString("All sites", comment: "Approvals sheet - all-sites scope"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    kindTag(grant.accessKind)
                }
                Text(grantDetail(grant))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Button(NSLocalizedString("Revoke", comment: "Approvals sheet - revoke one button")) {
                store.revoke(grant.id)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The access kind as a colored pill: green = the agent never sees the
    /// value, orange = a command receives it, red = the agent receives it.
    private func kindTag(_ kind: CredentialAccessKind) -> some View {
        let label: String
        let color: Color
        switch kind {
        case .fill:
            label = NSLocalizedString("Fill only", comment: "Approvals sheet - fill-kind tag")
            color = .green
        case .run:
            label = NSLocalizedString("Command env", comment: "Approvals sheet - run-kind tag")
            color = .orange
        case .reveal:
            label = NSLocalizedString("Full access", comment: "Approvals sheet - reveal-kind tag")
            color = .red
        }
        return Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    private func grantDetail(_ grant: CredentialGrant) -> String {
        let agent = grant.agent
            ?? NSLocalizedString("All agents", comment: "Approvals sheet - all-agents grantee")
        let duration: String
        if let expires = grant.expires {
            duration = String(
                format: NSLocalizedString("until %@", comment: "Approvals sheet - timed grant expiry"),
                expires.formatted(date: .omitted, time: .shortened))
        } else {
            duration = NSLocalizedString("Always", comment: "Approvals sheet - permanent grant")
        }
        let granted = grant.grantedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(agent) · \(duration) · \(granted)"
    }
}

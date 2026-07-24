// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Settings pane content for developer tooling, moved out of the General pane
/// into its own tab. The "Allow agents to control Phi (CDP)" switch is the
/// Agent control section's master gate: while it is off only that card shows;
/// turning it on reveals the phi-browser skill installer, the allowed-agent
/// list, and the agent permission cards right under it, all in the one
/// section. The password manager (agent credential provider) section is
/// always visible — vault settings stay reachable with agent access off.
/// Both sections share one visual language: grouped `settingsCardChrome()`
/// cards whose rows lead with a `SettingsIconChip` in a 24pt gutter, matching
/// the Agent Password Manager section.
struct DeveloperSettingsView: View {
    // Master switch state lives here (not in the agent-control section) so
    // sibling sections can gate on it too.
    @State private var agentAccessEnabled: Bool =
        PhiPreferences.AgentSpaces.cdpAgentAccessEnabled

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                AgentControlSectionView(agentAccessEnabled: $agentAccessEnabled)
                // Deliberately outside the CDP gate: vault login and session
                // settings stay reachable while agent access is off.
                PasswordManagerSectionView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
            .animation(.easeInOut(duration: 0.2), value: agentAccessEnabled)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
    }
}

/// Section title + content stack, matching the General pane's section layout.
private struct DeveloperSectionView<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Agent control (CDP access, skill install, grants, permissions)

private struct AgentControlSectionView: View {
    // Live master switch for agent CDP access over the app-owned Unix socket.
    // Flipping it starts/stops the listener immediately — no relaunch.
    @Binding var agentAccessEnabled: Bool
    // Agents currently allowed to connect (persisted "Always Allow" plus this
    // session's "Allow Once"). Read live from the listener on appear.
    @State private var allowedGrants: [AgentGrant] =
        AgentCDPListener.shared.allowedGrants()
    @State private var userSpaceOperationsEnabled: Bool =
        PhiPreferences.AgentSpaces.userSpaceOperationsEnabled
    @ObservedObject private var profileManager = ProfileManager.shared
    // Profiles the agent may NOT create Spaces in (blocklist mirror; empty =
    // all allowed). Kept in @State for toggle reactivity, written through to
    // the pref on each change.
    @State private var disallowedProfileIds: Set<String> =
        PhiPreferences.AgentSpaces.disallowedAgentProfileIds

    var body: some View {
        DeveloperSectionView(title: NSLocalizedString("Agent control", comment: "Developer settings - Agent control section title")) {
            VStack(alignment: .leading, spacing: 10) {
                accessCard
                if agentAccessEnabled {
                    allowedAgentsCard
                    permissionsCard
                }
            }
        }
        .onAppear {
            allowedGrants = AgentCDPListener.shared.allowedGrants()
            profileManager.refresh()
        }
    }

    // MARK: Access card — the master gate, with the skill installer under it.

    private var accessCard: some View {
        VStack(spacing: 0) {
            cdpRow
            if agentAccessEnabled {
                Divider()
                SkillInstallRowView()
            }
        }
        .padding(.horizontal, 12)
        .settingsCardChrome()
    }

    private var cdpRow: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIconChip(systemName: "sparkles", color: .indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Allow agents to control Phi (CDP)", comment: "Developer settings - Toggle title for the Chrome DevTools Protocol endpoint"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Text(NSLocalizedString("Lets agent tools (Claude Code, Codex) drive Phi over the DevTools Protocol through a private socket only this Mac’s processes can reach. Each agent asks for your approval the first time it connects. Applies immediately.", comment: "Developer settings - Security note for the agent CDP toggle"))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { agentAccessEnabled },
                set: { newValue in
                    agentAccessEnabled = newValue
                    AgentCDPListener.shared.setEnabled(newValue)
                    // Turning off clears the session grants; reflect it.
                    allowedGrants = AgentCDPListener.shared.allowedGrants()
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

    // MARK: Allowed agents card

    private var allowedAgentsCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIconChip(systemName: "checkmark.seal.fill", color: .green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Allowed agents", comment: "Developer settings - Title for the allowed CDP agent list"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(NSLocalizedString("Processes you’ve approved to control Phi. Removing one makes it ask again next time it connects.", comment: "Developer settings - Explanation for the allowed CDP agent list"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if allowedGrants.isEmpty {
                emptyGrantsState
            } else {
                ForEach(allowedGrants) { grant in
                    grantRow(grant)
                    if grant.id != allowedGrants.last?.id {
                        Divider().padding(.leading, 36)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .settingsCardChrome()
    }

    private var emptyGrantsState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 18, weight: .medium))
                .themedForeground(.textTertiary)
            Text(NSLocalizedString("No agents approved yet. The first time one connects, Phi asks for your approval.", comment: "Developer settings - Empty state for the allowed CDP agent list"))
                .font(.system(size: 11))
                .themedForeground(.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func grantRow(_ grant: AgentGrant) -> some View {
        HStack(spacing: 12) {
            AgentBrandIcon(assetName: Self.brandAsset(for: grant))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(grant.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    grantScopePill(remembered: grant.remembered)
                }
                grantSubtitle(grant)
            }
            Spacer(minLength: 12)
            Button(NSLocalizedString("Remove", comment: "Developer settings - Revoke an allowed CDP agent")) {
                AgentCDPListener.shared.forgetGrant(key: grant.key)
                allowedGrants = AgentCDPListener.shared.allowedGrants()
            }
            .controlSize(.small)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func grantScopePill(remembered: Bool) -> some View {
        let label = remembered
            ? NSLocalizedString("Always", comment: "Developer settings - persisted CDP grant pill")
            : NSLocalizedString("This session", comment: "Developer settings - session-only CDP grant pill")
        let color: Color = remembered ? .indigo : .gray
        return Text(label)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
    }

    /// Second line: the code-signing identity when there is one — a signed
    /// agent names its team, an unsigned one says so plainly.
    @ViewBuilder
    private func grantSubtitle(_ grant: AgentGrant) -> some View {
        if let teamId = grant.teamId, !teamId.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 9))
                Text(String(format: NSLocalizedString("Signed · Team %@", comment: "Developer settings - CDP grant signing team"), teamId))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11))
            .themedForeground(.textTertiary)
        } else {
            Text(NSLocalizedString("Unsigned", comment: "Developer settings - CDP grant with no code signature"))
                .font(.system(size: 11))
                .themedForeground(.textTertiary)
        }
    }

    /// The bundled brand icon for a grant whose display name identifies a
    /// known agent, nil for anything else (shown with a generic glyph).
    private static func brandAsset(for grant: AgentGrant) -> String? {
        let name = grant.displayName.lowercased()
        if name.contains("claude") { return "agent-claude" }
        if name.contains("codex") || name.contains("openai") { return "agent-openai" }
        if name.contains("cursor") { return "agent-cursor" }
        if name.contains("hermes") { return "agent-hermes" }
        if name.contains("openclaw") { return "agent-openclaw" }
        if name == "pi" { return "agent-pi" }
        return nil
    }

    // MARK: Permissions card — what approved agents may touch.

    private var permissionsCard: some View {
        VStack(spacing: 0) {
            operateSpacesRow
            Divider()
            profilesRows
        }
        .padding(.horizontal, 12)
        .settingsCardChrome()
    }

    private var operateSpacesRow: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIconChip(systemName: "square.grid.2x2.fill", color: .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Allow agents to operate your Spaces", comment: "Developer settings - Toggle title for agent user-space operations"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Text(NSLocalizedString("Lets agent tooling manage your own browsing data — Spaces, profiles, URL rules, pinned tabs, bookmarks, and the tab layout of your windows. When off, agents can only work inside their own agent Spaces. Applies immediately.", comment: "Developer settings - Explanation for the agent user-space operations toggle"))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { userSpaceOperationsEnabled },
                set: { newValue in
                    userSpaceOperationsEnabled = newValue
                    PhiPreferences.AgentSpaces.userSpaceOperationsEnabled = newValue
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

    private var profilesRows: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                SettingsIconChip(systemName: "person.2.fill", color: .blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Profiles agents can use", comment: "Developer settings - Title for the per-profile agent-Space allowlist"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(NSLocalizedString("Choose which profiles agents may create their own Spaces in. Turning a profile off stops agents from opening any new Space bound to it; existing Spaces are unaffected.", comment: "Developer settings - Explanation for the per-profile agent-Space allowlist"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            if profileManager.userAssignableProfiles.isEmpty {
                Text(NSLocalizedString("No profiles found.", comment: "Developer settings - Empty state when no browser profiles exist"))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .padding(.leading, 36)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(profileManager.userAssignableProfiles) { profile in
                    HStack(spacing: 12) {
                        Text(profile.displayName)
                            .font(.system(size: 13))
                            .themedForeground(.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 12)
                        Toggle("", isOn: Binding(
                            get: { !disallowedProfileIds.contains(profile.profileId) },
                            set: { allowed in
                                if allowed {
                                    disallowedProfileIds.remove(profile.profileId)
                                } else {
                                    disallowedProfileIds.insert(profile.profileId)
                                }
                                PhiPreferences.AgentSpaces.disallowedAgentProfileIds =
                                    disallowedProfileIds
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .themedTint(.themeColor)
                    }
                    .padding(.leading, 36)
                    .padding(.vertical, 6)
                }
                Color.clear.frame(height: 6)
            }
        }
    }
}

/// 24pt gutter icon for an allowed-agent row: the agent's brand glyph on a
/// neutral rounded square, or a generic terminal glyph for unrecognized
/// processes. Template brand assets take the text color; Hermes's colored
/// artwork renders as-is.
private struct AgentBrandIcon: View {
    let assetName: String?

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.gray.opacity(0.16))
            .frame(width: 24, height: 24)
            .overlay {
                if let assetName {
                    Image(assetName)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                        .themedForeground(.textPrimary)
                } else {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .themedForeground(.textSecondary)
                }
            }
    }
}

// MARK: - phi-browser skill installer

private struct SkillInstallRowView: View {
    // A coding agent that loads skills from a folder.
    // "Install" links this app's bundled phi-browser skill into
    // <skillsDirectory>/phi-browser so the agent can drive Phi over CDP.
    private struct SkillTarget: Identifiable {
        let id: String
        let name: String
        /// Bundled brand icon (imageset under Assets ▸ agents). Rendering
        /// follows the asset's own intent: the monochrome brand glyphs are
        /// template, Hermes's favicon artwork renders in original color.
        let iconAsset: String
        let skillsDirectory: URL
        /// Pi alone exposes a supported in-process message API. Its companion
        /// extension wakes idle sessions when Agent Transcript receives input.
        let companionExtensionDirectory: URL?

        init(id: String, name: String, iconAsset: String, skillsDirectory: URL,
             companionExtensionDirectory: URL? = nil) {
            self.id = id
            self.name = name
            self.iconAsset = iconAsset
            self.skillsDirectory = skillsDirectory
            self.companionExtensionDirectory = companionExtensionDirectory
        }

        var linkURL: URL {
            skillsDirectory.appendingPathComponent("phi-browser", isDirectory: true)
        }

        var companionExtensionLinkURL: URL? {
            companionExtensionDirectory?
                .appendingPathComponent("phi-browser", isDirectory: true)
        }
    }

    private static let skillTargets: [SkillTarget] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            SkillTarget(id: "claude", name: "Claude Code", iconAsset: "agent-claude",
                        skillsDirectory: home.appendingPathComponent(".claude/skills", isDirectory: true)),
            SkillTarget(id: "codex", name: "Codex", iconAsset: "agent-openai",
                        skillsDirectory: home.appendingPathComponent(".codex/skills", isDirectory: true)),
            SkillTarget(id: "cursor", name: "Cursor", iconAsset: "agent-cursor",
                        skillsDirectory: home.appendingPathComponent(".cursor/skills", isDirectory: true)),
            SkillTarget(id: "hermes", name: "Hermes", iconAsset: "agent-hermes",
                        skillsDirectory: home.appendingPathComponent(".hermes/skills", isDirectory: true)),
            SkillTarget(id: "openclaw", name: "OpenClaw", iconAsset: "agent-openclaw",
                        skillsDirectory: home.appendingPathComponent(".openclaw/skills", isDirectory: true)),
            SkillTarget(
                id: "pi", name: "Pi", iconAsset: "agent-pi",
                skillsDirectory: home.appendingPathComponent(".pi/agent/skills", isDirectory: true),
                companionExtensionDirectory: home.appendingPathComponent(
                    ".pi/agent/extensions", isDirectory: true)),
        ]
    }()

    // The skill tree is bundled at Contents/Resources/phi-browser-skill.
    private static var bundledSkillURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("phi-browser-skill", isDirectory: true)
    }

    private static var bundledPiExtensionURL: URL? {
        bundledSkillURL?
            .appendingPathComponent("extensions/pi", isDirectory: true)
    }

    // IDs of agents whose skills folder already links to *this* app's bundle.
    @State private var installedTargets: Set<String> = SkillInstallRowView.installedTargetIDs()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIconChip(systemName: "puzzlepiece.extension.fill", color: .teal)
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Install the phi-browser skill", comment: "Developer settings - Title for installing the phi-browser agent skill"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Text(NSLocalizedString("Links the skill bundled in this app into an AI coding agent’s skills folder so it can drive Phi over the DevTools Protocol. Pi also gets a companion extension that wakes idle sessions from Agent Transcript commands. Requires Node 22+.", comment: "Developer settings - Explanation for the phi-browser skill installer"))
                    .font(.system(size: 11))
                    .themedForeground(.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Menu {
                Button(NSLocalizedString("All agents", comment: "Developer settings - Menu item installing the skill for every agent")) {
                    installAll()
                }
                Divider()
                ForEach(Self.skillTargets) { target in
                    Button {
                        installSkill(for: target)
                    } label: {
                        // The agent's brand icon leads each row; a
                        // trailing ✓ marks agents whose skills folder
                        // already links to THIS app's bundle (picking
                        // one again reinstalls / refreshes the link).
                        Label {
                            Text("\(target.name)  \(Self.displayPath(target.skillsDirectory))"
                                 + (installedTargets.contains(target.id) ? "  ✓" : ""))
                        } icon: {
                            Image(target.iconAsset)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 15, height: 15)
                        }
                    }
                }
            } label: {
                Text(NSLocalizedString("Add skill to…", comment: "Developer settings - Dropdown button installing the phi-browser skill for an agent"))
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Installs for every known agent, reporting one aggregate alert instead
    /// of one per target.
    private func installAll() {
        var succeeded: [String] = []
        var failed: [(String, String)] = []
        for target in Self.skillTargets {
            switch performInstall(for: target) {
            case .success: succeeded.append(target.name)
            case .cancelled: continue
            case .failure(let message): failed.append((target.name, message))
            }
        }
        if failed.isEmpty, succeeded.isEmpty { return }
        if failed.isEmpty {
            presentSkillAlert(
                title: NSLocalizedString("Skill installed", comment: "Developer settings - Skill install success title"),
                body: String(
                    format: NSLocalizedString("%@ can now use the phi-browser skill. Restart newly configured agents; in Pi, /reload is enough.", comment: "Developer settings - Skill install success body; %@ is the agent name"),
                    succeeded.joined(separator: ", ")))
        } else {
            presentSkillAlert(
                title: NSLocalizedString("Couldn’t install the skill", comment: "Developer settings - Skill install error title"),
                body: failed.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
        }
    }

    private static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = url.path
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }

    static func installedTargetIDs() -> Set<String> {
        guard let bundled = bundledSkillURL else { return [] }
        return Set(skillTargets.filter { target in
            guard isLinked(target.linkURL, to: bundled) else { return false }
            guard let companionLink = target.companionExtensionLinkURL else { return true }
            guard let companion = bundledPiExtensionURL else { return false }
            return isLinked(companionLink, to: companion)
        }.map(\.id))
    }

    // True only when linkURL is a symlink resolving to *this* app's bundled
    // skill, so a link left by another build (or a stale target) reads as
    // "Install" rather than already-installed.
    private static func isLinked(_ link: URL, to bundled: URL) -> Bool {
        guard let dest = try? FileManager.default
            .destinationOfSymbolicLink(atPath: link.path) else { return false }
        let resolved = dest.hasPrefix("/")
            ? dest
            : link.deletingLastPathComponent().appendingPathComponent(dest).path
        return URL(fileURLWithPath: resolved).standardizedFileURL.path
            == bundled.standardizedFileURL.path
    }

    private enum InstallOutcome {
        case success
        case cancelled          // the user declined the overwrite prompt
        case failure(String)
    }

    /// Links the bundled skill into `target`'s skills folder. Silent apart
    /// from the overwrite confirmation (a non-symlink already in place must
    /// never be clobbered without asking) — callers present the outcome, so
    /// "All agents" can aggregate into one alert.
    private func performInstall(for target: SkillTarget) -> InstallOutcome {
        let fm = FileManager.default
        guard let bundled = Self.bundledSkillURL,
              fm.fileExists(atPath: bundled.path) else {
            return .failure(NSLocalizedString("This build doesn’t include the phi-browser skill resources. Rebuild Phi Browser and try again.", comment: "Developer settings - Skill install failure body when the resource is missing"))
        }

        var installs: [(link: URL, source: URL)] = [(target.linkURL, bundled)]
        if let companionLink = target.companionExtensionLinkURL {
            guard let companion = Self.bundledPiExtensionURL,
                  fm.fileExists(atPath: companion.path) else {
                return .failure(NSLocalizedString(
                    "This build doesn’t include the Pi companion extension. Rebuild Phi Browser and try again.",
                    comment: "Developer settings - Pi companion extension missing"))
            }
            installs.append((companionLink, companion))
        }

        do {
            // Ask about every real destination before changing any of them, so
            // declining the Pi extension replacement cannot leave a partial install.
            for install in installs {
                try fm.createDirectory(
                    at: install.link.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                let isSymlink = (try? fm.destinationOfSymbolicLink(
                    atPath: install.link.path)) != nil
                if !isSymlink, fm.fileExists(atPath: install.link.path),
                   !confirmSkillOverwrite(at: install.link.path) {
                    return .cancelled
                }
            }

            for install in installs {
                if (try? fm.destinationOfSymbolicLink(atPath: install.link.path)) != nil
                    || fm.fileExists(atPath: install.link.path) {
                    try fm.removeItem(at: install.link)
                }
                try fm.createSymbolicLink(
                    at: install.link, withDestinationURL: install.source)
            }
            installedTargets.insert(target.id)
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func installSkill(for target: SkillTarget) {
        switch performInstall(for: target) {
        case .success:
            presentSkillAlert(
                title: NSLocalizedString("Skill installed", comment: "Developer settings - Skill install success title"),
                body: String(
                    format: NSLocalizedString("%@ can now use the phi-browser skill. Restart newly configured agents; in Pi, /reload is enough.", comment: "Developer settings - Skill install success body; %@ is the agent name"),
                    target.name))
        case .cancelled:
            break
        case .failure(let message):
            presentSkillAlert(
                title: NSLocalizedString("Couldn’t install the skill", comment: "Developer settings - Skill install error title"),
                body: message)
        }
    }

    private func confirmSkillOverwrite(at path: String) -> Bool {
        let response = NSApp.runPhiAlert(PhiAlertAppKitConfiguration(
            title: NSLocalizedString("Replace the existing skill?", comment: "Developer settings - Skill overwrite prompt title"),
            message: String(
                format: NSLocalizedString("“%@” already exists and isn’t a link created by Phi Browser. Replace it with a link to this app’s bundled skill?", comment: "Developer settings - Skill overwrite prompt body"),
                path),
            secondaryAction: PhiAlertAppKitAction(
                NSLocalizedString("Cancel", comment: "Developer settings - Skill overwrite cancel button"),
                response: .alertSecondButtonReturn),
            primaryAction: PhiAlertAppKitAction(
                NSLocalizedString("Replace", comment: "Developer settings - Skill overwrite confirm button"),
                role: .primary,
                response: .alertFirstButtonReturn)))
        return response == .alertFirstButtonReturn
    }

    private func presentSkillAlert(title: String, body: String) {
        _ = NSApp.runPhiAlert(PhiAlertAppKitConfiguration(
            title: title,
            message: body,
            icon: .phiAlertIcon,
            primaryAction: PhiAlertAppKitAction(
                NSLocalizedString("OK", comment: "Developer settings - Alert dismiss button"),
                role: .primary,
                response: .alertFirstButtonReturn)))
    }
}

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Settings pane content for developer tooling, moved out of the General pane
/// into its own tab: the remote-debugging (CDP) toggle, the phi-browser skill
/// installer, and the agent user-space permissions toggle. Sections use the
/// shared `SettingsDetailCard` chrome so the pane reads like General's cards.
/// The localized strings keep their original keys from the General pane so
/// existing translations carry over.
struct DeveloperSettingsView: View {
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                RemoteDebuggingSectionView()
                SkillInstallSectionView()
                AgentPermissionsSectionView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
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

// MARK: - Remote debugging (CDP)

private struct RemoteDebuggingSectionView: View {
    // Live master switch for agent CDP access over the app-owned Unix socket.
    // Flipping it starts/stops the listener immediately — no relaunch.
    @State private var agentAccessEnabled: Bool =
        PhiPreferences.AgentSpaces.cdpAgentAccessEnabled
    // Agents currently allowed to connect (persisted "Always Allow" plus this
    // session's "Allow Once"). Read live from the listener on appear.
    @State private var allowedGrants: [AgentGrant] =
        AgentCDPListener.shared.allowedGrants()

    var body: some View {
        DeveloperSectionView(title: NSLocalizedString("Remote debugging", comment: "Developer settings - Remote debugging section title")) {
            VStack(alignment: .leading, spacing: 16) {
                enableCard
                if agentAccessEnabled || !allowedGrants.isEmpty {
                    grantsCard
                }
            }
        }
        .onAppear { allowedGrants = AgentCDPListener.shared.allowedGrants() }
    }

    private var enableCard: some View {
        SettingsDetailCard {
            HStack(alignment: .top, spacing: 12) {
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
    }

    private var grantsCard: some View {
        SettingsDetailCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Allowed agents", comment: "Developer settings - Title for the allowed CDP agent list"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(NSLocalizedString("Processes you’ve approved to control Phi. Removing one makes it ask again next time it connects.", comment: "Developer settings - Explanation for the allowed CDP agent list"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if allowedGrants.isEmpty {
                    Text(NSLocalizedString("No agents approved yet. The first time one connects, Phi asks for your approval.", comment: "Developer settings - Empty state for the allowed CDP agent list"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(allowedGrants) { grant in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(grant.displayName)
                                    .font(.system(size: 13))
                                    .themedForeground(.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(Self.subtitle(for: grant))
                                    .font(.system(size: 11))
                                    .themedForeground(.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 12)
                            Button(NSLocalizedString("Remove", comment: "Developer settings - Revoke an allowed CDP agent")) {
                                AgentCDPListener.shared.forgetGrant(key: grant.key)
                                allowedGrants = AgentCDPListener.shared.allowedGrants()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Second line: how the grant was given, and its team when known.
    private static func subtitle(for grant: AgentGrant) -> String {
        let scope = grant.remembered
            ? NSLocalizedString("Always allowed", comment: "Developer settings - persisted CDP grant")
            : NSLocalizedString("Allowed this session", comment: "Developer settings - session-only CDP grant")
        if let teamId = grant.teamId, !teamId.isEmpty {
            return String(format: NSLocalizedString("%@ · Team %@", comment: "Developer settings - CDP grant scope and team"), scope, teamId)
        }
        return scope
    }
}

// MARK: - Agent permissions

private struct AgentPermissionsSectionView: View {
    @State private var userSpaceOperationsEnabled: Bool =
        PhiPreferences.AgentSpaces.userSpaceOperationsEnabled
    @ObservedObject private var profileManager = ProfileManager.shared
    // Profiles the agent may NOT create Spaces in (blocklist mirror; empty =
    // all allowed). Kept in @State for toggle reactivity, written through to
    // the pref on each change.
    @State private var disallowedProfileIds: Set<String> =
        PhiPreferences.AgentSpaces.disallowedAgentProfileIds

    var body: some View {
        DeveloperSectionView(title: NSLocalizedString("Agent permissions", comment: "Developer settings - Agent permissions section title")) {
            VStack(alignment: .leading, spacing: 16) {
                operateSpacesCard
                agentProfilesCard
            }
        }
        .onAppear { profileManager.refresh() }
    }

    private var operateSpacesCard: some View {
        SettingsDetailCard {
            HStack(alignment: .top, spacing: 12) {
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
    }

    private var agentProfilesCard: some View {
        SettingsDetailCard {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Profiles agents can use", comment: "Developer settings - Title for the per-profile agent-Space allowlist"))
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                    Text(NSLocalizedString("Choose which profiles agents may create their own Spaces in. Turning a profile off stops agents from opening any new Space bound to it; existing Spaces are unaffected.", comment: "Developer settings - Explanation for the per-profile agent-Space allowlist"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if profileManager.userAssignableProfiles.isEmpty {
                    Text(NSLocalizedString("No profiles found.", comment: "Developer settings - Empty state when no browser profiles exist"))
                        .font(.system(size: 11))
                        .themedForeground(.textTertiary)
                } else {
                    ForEach(profileManager.userAssignableProfiles) { profile in
                        HStack(spacing: 12) {
                            Text(profile.displayName)
                                .font(.system(size: 13))
                                .themedForeground(.textPrimary)
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
                    }
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - phi-browser skill installer

private struct SkillInstallSectionView: View {
    // A Claude-Code-style coding agent that loads skills from a folder.
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

        var linkURL: URL {
            skillsDirectory.appendingPathComponent("phi-browser", isDirectory: true)
        }
    }

    private static let skillTargets: [SkillTarget] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            SkillTarget(id: "claude", name: "Claude Code", iconAsset: "agent-claude",
                        skillsDirectory: home.appendingPathComponent(".claude/skills", isDirectory: true)),
            SkillTarget(id: "codex", name: "Codex", iconAsset: "agent-openai",
                        skillsDirectory: home.appendingPathComponent(".codex/skills", isDirectory: true)),
            SkillTarget(id: "hermes", name: "Hermes", iconAsset: "agent-hermes",
                        skillsDirectory: home.appendingPathComponent(".hermes/skills", isDirectory: true)),
            SkillTarget(id: "openclaw", name: "OpenClaw", iconAsset: "agent-openclaw",
                        skillsDirectory: home.appendingPathComponent(".openclaw/skills", isDirectory: true)),
            SkillTarget(id: "pi", name: "Pi", iconAsset: "agent-pi",
                        skillsDirectory: home.appendingPathComponent(".pi/agent/skills", isDirectory: true)),
        ]
    }()

    // The skill tree is bundled at Contents/Resources/claude-skill/phi-browser.
    private static var bundledSkillURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("claude-skill/phi-browser", isDirectory: true)
    }

    // IDs of agents whose skills folder already links to *this* app's bundle.
    @State private var installedTargets: Set<String> = SkillInstallSectionView.installedTargetIDs()

    var body: some View {
        DeveloperSectionView(title: NSLocalizedString("Agent skill", comment: "Developer settings - phi-browser skill section title")) {
            SettingsDetailCard {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("Install the phi-browser skill", comment: "Developer settings - Title for installing the phi-browser agent skill"))
                            .font(.system(size: 13))
                            .themedForeground(.textPrimary)
                        Text(NSLocalizedString("Links the skill bundled in this app into an AI coding agent’s skills folder so it can drive Phi over the DevTools Protocol. Requires Node 22+; enable remote debugging above so it can connect.", comment: "Developer settings - Explanation for the phi-browser skill installer"))
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
        }
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
                    format: NSLocalizedString("%@ can now use the phi-browser skill. If it isn’t already on, enable remote debugging above and relaunch so the skill can connect.", comment: "Developer settings - Skill install success body; %@ is the agent name"),
                    succeeded.joined(separator: ", ")),
                style: .informational)
        } else {
            presentSkillAlert(
                title: NSLocalizedString("Couldn’t install the skill", comment: "Developer settings - Skill install error title"),
                body: failed.map { "\($0.0): \($0.1)" }.joined(separator: "\n"),
                style: .warning)
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
        return Set(skillTargets.filter { isLinked($0.linkURL, to: bundled) }.map(\.id))
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

        let link = target.linkURL
        do {
            try fm.createDirectory(at: target.skillsDirectory, withIntermediateDirectories: true)

            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil {
                // An existing symlink (ours, another build's, or broken) — replace it.
                try fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                // A real file/directory the user placed — don't clobber without asking.
                guard confirmSkillOverwrite(at: link.path) else { return .cancelled }
                try fm.removeItem(at: link)
            }

            try fm.createSymbolicLink(at: link, withDestinationURL: bundled)
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
                    format: NSLocalizedString("%@ can now use the phi-browser skill. If it isn’t already on, enable remote debugging above and relaunch so the skill can connect.", comment: "Developer settings - Skill install success body; %@ is the agent name"),
                    target.name),
                style: .informational)
        case .cancelled:
            break
        case .failure(let message):
            presentSkillAlert(
                title: NSLocalizedString("Couldn’t install the skill", comment: "Developer settings - Skill install error title"),
                body: message,
                style: .warning)
        }
    }

    private func confirmSkillOverwrite(at path: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("Replace the existing skill?", comment: "Developer settings - Skill overwrite prompt title")
        alert.informativeText = String(
            format: NSLocalizedString("“%@” already exists and isn’t a link created by Phi Browser. Replace it with a link to this app’s bundled skill?", comment: "Developer settings - Skill overwrite prompt body"),
            path)
        alert.addButton(withTitle: NSLocalizedString("Replace", comment: "Developer settings - Skill overwrite confirm button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Developer settings - Skill overwrite cancel button"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func presentSkillAlert(title: String, body: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: NSLocalizedString("OK", comment: "Developer settings - Alert dismiss button"))
        alert.runModal()
    }
}

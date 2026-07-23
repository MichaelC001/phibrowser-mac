// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI
import AppKit

/// Settings pane content for managing Chromium profiles, laid out master-detail:
/// the profile list on the left (with a +/−/✎ toolbar) and the selected
/// profile's per-profile browser settings on the right (search engine, download
/// location, a password-manager row that shows each detected manager
/// extension's icon and offers to install one, and quick links into that
/// profile's data & settings pages).
/// Profile lifecycle routes through `ProfileManager`; `SpaceManager` is observed
/// for each profile's Space count and the delete guard. The per-profile settings
/// round-trip to Chromium via `ProfileManager`'s bridge accessors and may load
/// the profile on first access.
struct ProfilesSettingsView: View {
    @ObservedObject private var spaceManager = SpaceManager.shared
    @ObservedObject private var profileManager = ProfileManager.shared

    @State private var selectedProfileId: String?
    @State private var searchEngines: [SearchEngineInfo] = []
    @State private var defaultEngineId: String = ""
    @State private var downloadPath: String = ""
    @State private var isLoadingDetail: Bool = false
    @State private var profileExtensions: [ProfileExtensionInfo] = []
    @State private var installingManagerIds: Set<String> = []

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            profileListPanel
                // Fixed, and narrower than the Spaces pane's 280 list: profile
                // rows carry less content, and the detail column needs the room.
                .frame(width: 240)
                .frame(maxHeight: .infinity)
            detailPanel
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 36)
        .onAppear {
            profileManager.refresh()
            if selectedProfileId == nil { selectInitialProfile() }
        }
        // Keep the selection valid as the profile list changes (create/delete).
        .onChange(of: profileManager.profiles.map(\.profileId)) { ids in
            if let sel = selectedProfileId, ids.contains(sel) { return }
            selectInitialProfile()
        }
    }

    // MARK: - Left: profile list

    private var profileListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(NSLocalizedString("Your Profiles", comment: "Profiles settings - list header"))
                    .font(.system(size: 12))
                    .themedForeground(.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            SettingsRowDivider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(profileManager.profiles) { profile in
                        profileListRow(profile)
                    }
                }
                .padding(6)
            }

            SettingsRowDivider()

            HStack(spacing: 0) {
                toolbarButton(systemName: "plus",
                              help: NSLocalizedString("New profile", comment: "Profiles settings - new profile tooltip"),
                              action: newProfile)
                toolbarDivider
                toolbarButton(systemName: "minus",
                              help: NSLocalizedString("Delete selected profile", comment: "Profiles settings - delete profile tooltip"),
                              disabled: !canDeleteSelected,
                              action: deleteSelected)
                toolbarDivider
                toolbarButton(systemName: "pencil",
                              help: NSLocalizedString("Rename selected profile", comment: "Profiles settings - rename profile tooltip"),
                              disabled: selectedProfile == nil,
                              action: renameSelected)
                Spacer()
            }
            .frame(height: 34)
        }
        .settingsCardChrome()
    }

    private func profileListRow(_ profile: PhiBrowserProfile) -> some View {
        let isSelected = profile.profileId == selectedProfileId
        let isDefault = profile.profileId == LocalStore.defaultProfileId
        let count = spaceManager.spaces.filter { $0.profileId == profile.profileId }.count
        return Button {
            select(profile.profileId)
        } label: {
            HStack(spacing: 6) {
                Text(profile.displayName)
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                    .lineLimit(1)
                if isDefault {
                    SettingsDefaultBadge()
                }
                Spacer(minLength: 4)
                Text(count == 0
                     ? NSLocalizedString("Not used", comment: "Profiles settings - tag for a profile with no Spaces")
                     : spaceCountLabel(count))
                    .font(.system(size: 11))
                    .themedForeground(.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toolbarButton(systemName: String,
                               help: String,
                               disabled: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(disabled ? Color.secondary.opacity(0.4) : Color.primary.opacity(0.7))
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color(.separatorColor))
            .frame(width: 1, height: 20)
    }

    // MARK: - Right: per-profile settings

    @ViewBuilder
    private var detailPanel: some View {
        if let profileId = selectedProfileId {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsDetailCard {
                        SettingsDetailRow(NSLocalizedString("Search engine", comment: "Profiles settings - search engine row label"),
                                          systemImage: "magnifyingglass") {
                            searchEngineControl(profileId: profileId)
                        }
                        SettingsRowDivider()
                        SettingsDetailRow(NSLocalizedString("Download location", comment: "Profiles settings - download location row label"),
                                          systemImage: "arrow.down.to.line") {
                            downloadLocationControl(profileId: profileId)
                        }
                        SettingsRowDivider()
                        SettingsDetailRow(NSLocalizedString("Password Manager", comment: "Profiles settings - password manager row label"),
                                          systemImage: "key.fill") {
                            installPasswordManagerMenu(profileId: profileId)
                        }
                        if !detectedPasswordManagers.isEmpty || !installingPasswordManagers.isEmpty {
                            installedPasswordManagersLine
                        }
                    }
                    dataAndSettingsSection(profileId: profileId)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(NSLocalizedString("Select a profile to view its settings.",
                                   comment: "Profiles settings - empty detail placeholder"))
                .font(.system(size: 13))
                .themedForeground(.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Uniform chrome for the detail card's trailing controls (search engine,
    /// download location, password-manager install): one fixed-width pill so
    /// the three read as a single aligned control column. Content lays out
    /// leading-to-trailing inside the fixed width — put a Spacer before any
    /// trailing chevron.
    private func trailingControlPill<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6, content: content)
            .frame(width: Self.trailingPillInnerWidth)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private static let trailingPillInnerWidth: CGFloat = 110

    @ViewBuilder
    private func searchEngineControl(profileId: String) -> some View {
        if isLoadingDetail {
            ProgressView().controlSize(.small)
        } else if searchEngines.isEmpty {
            Text(NSLocalizedString("Unavailable", comment: "Profiles settings - search engine list unavailable"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
        } else {
            // Custom pill matching the download-location control (and the Spaces
            // pane's themeControl) so the rows' selectors share one size,
            // style, and trailing edge instead of the native picker's taller,
            // differently-inset bezel.
            Menu {
                Picker("", selection: searchBinding(profileId)) {
                    ForEach(searchEngines) { engine in
                        Text(engine.name).tag(engine.id)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                trailingControlPill {
                    Text(selectedEngineName)
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .themedForeground(.textSecondary)
                }
            }
            // .button + .plain renders the label exactly as given (like the
            // download Button's pill); .borderlessButton would impose a native
            // popup look instead, dropping the pill and its trailing chevron.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var selectedEngineName: String {
        searchEngines.first(where: { $0.id == defaultEngineId })?.name ?? ""
    }

    @ViewBuilder
    private func downloadLocationControl(profileId: String) -> some View {
        if isLoadingDetail {
            ProgressView().controlSize(.small)
        } else {
            Button {
                chooseDownloadLocation(profileId: profileId)
            } label: {
                trailingControlPill {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .themedForeground(.textSecondary)
                    Text(downloadFolderName)
                        .font(.system(size: 13))
                        .themedForeground(.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var downloadFolderName: String {
        guard !downloadPath.isEmpty else {
            return NSLocalizedString("Choose…", comment: "Profiles settings - download location not set")
        }
        return (downloadPath as NSString).lastPathComponent
    }

    // MARK: - Your Data and Settings links

    private struct DataLink: Identifiable {
        let page: String
        let title: String
        let systemImage: String
        var id: String { page }
    }

    private var dataLinks: [DataLink] {
        [
            DataLink(page: "privacy",
                     title: NSLocalizedString("Privacy and Security", comment: "Profiles settings - data link to privacy settings"),
                     systemImage: "lock.shield"),
            DataLink(page: "passwords",
                     title: NSLocalizedString("Passwords", comment: "Profiles settings - data link to saved passwords"),
                     systemImage: "key"),
            DataLink(page: "payments",
                     title: NSLocalizedString("Credit Cards", comment: "Profiles settings - data link to payment methods"),
                     systemImage: "creditcard"),
            DataLink(page: "notifications",
                     title: NSLocalizedString("Notifications", comment: "Profiles settings - data link to notification settings"),
                     systemImage: "bell"),
            DataLink(page: "clearBrowserData",
                     title: NSLocalizedString("Clear Browsing Data", comment: "Profiles settings - data link to clear browsing data"),
                     systemImage: "trash"),
        ]
    }

    @ViewBuilder
    private func dataAndSettingsSection(profileId: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(NSLocalizedString("Your Data and Settings", comment: "Profiles settings - data & settings section header"))
                .font(.system(size: 12))
                .themedForeground(.textSecondary)
                .padding(.leading, 2)
            SettingsDetailCard {
                ForEach(Array(dataLinks.enumerated()), id: \.element.page) { index, link in
                    if index > 0 { SettingsRowDivider() }
                    dataLinkRow(link, profileId: profileId)
                }
            }
        }
    }

    private func dataLinkRow(_ link: DataLink, profileId: String) -> some View {
        Button {
            profileManager.openDataPage(link.page, forProfile: profileId)
        } label: {
            SettingsDetailRow(link.title, systemImage: link.systemImage) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Password manager

    /// A well-known password-manager extension the pane can recognize in a
    /// profile and offer to install. Names are product brands — not localized.
    /// `installable: false` marks superseded store listings kept only so
    /// existing installs are still recognized.
    private struct PasswordManagerEntry: Identifiable {
        let id: String
        let name: String
        var installable: Bool = true
    }

    private static let knownPasswordManagers: [PasswordManagerEntry] = [
        PasswordManagerEntry(id: PhiExtensionID.icloudPasswords, name: "iCloud Passwords"),
        PasswordManagerEntry(id: PhiExtensionID.onePassword, name: "1Password"),
        PasswordManagerEntry(id: PhiExtensionID.bitwarden, name: "Bitwarden"),
        PasswordManagerEntry(id: PhiExtensionID.lastPass, name: "LastPass"),
        PasswordManagerEntry(id: PhiExtensionID.dashlane, name: "Dashlane"),
        PasswordManagerEntry(id: PhiExtensionID.protonPass, name: "Proton Pass"),
        PasswordManagerEntry(id: PhiExtensionID.nordPass, name: "NordPass"),
        PasswordManagerEntry(id: PhiExtensionID.nordPassLegacy, name: "NordPass", installable: false),
        PasswordManagerEntry(id: PhiExtensionID.keeper, name: "Keeper"),
        PasswordManagerEntry(id: PhiExtensionID.keePassXC, name: "KeePassXC-Browser"),
    ]

    /// Known password managers the selected profile has enabled, in catalog
    /// order. Multiple entries are expected — users do run more than one.
    private var detectedPasswordManagers: [PasswordManagerEntry] {
        let enabledIds = Set(profileExtensions.filter(\.enabled).map(\.id))
        return Self.knownPasswordManagers.filter { enabledIds.contains($0.id) }
    }

    /// What the install menu offers: current store listings not installed in
    /// any state (a disabled install would make a re-install a silent no-op)
    /// and not already mid-install.
    private var installablePasswordManagers: [PasswordManagerEntry] {
        let installedIds = Set(profileExtensions.map(\.id))
        return Self.knownPasswordManagers.filter {
            $0.installable && !installedIds.contains($0.id)
                && !installingManagerIds.contains($0.id)
        }
    }

    /// In-flight installs still shown with a spinner; an id drops out the
    /// moment the poll sees it enabled (it re-enters as a detected row).
    private var installingPasswordManagers: [PasswordManagerEntry] {
        let enabledIds = Set(profileExtensions.filter(\.enabled).map(\.id))
        return Self.knownPasswordManagers.filter {
            installingManagerIds.contains($0.id) && !enabledIds.contains($0.id)
        }
    }

    /// The Password Manager row's second line: the already-installed managers'
    /// icons (tooltip names each) plus a spinner per in-flight install,
    /// right-aligned under the install menu. Only shown when non-empty, so the
    /// row stays single-line until a manager is detected.
    private var installedPasswordManagersLine: some View {
        HStack(spacing: 8) {
            ForEach(detectedPasswordManagers) { manager in
                passwordManagerIcon(manager)
            }
            ForEach(installingPasswordManagers) { manager in
                ProgressView()
                    .controlSize(.small)
                    .help(String(format: NSLocalizedString("Installing %@", comment: "Profiles settings - tooltip on the spinner of a password manager mid-install"),
                                 manager.name))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.bottom, 12)
    }

    /// The manager's real extension icon, falling back to a key glyph when the
    /// icon hasn't arrived (or couldn't be read). Hover reveals the name.
    @ViewBuilder
    private func passwordManagerIcon(_ manager: PasswordManagerEntry) -> some View {
        Group {
            if let icon = profileExtensions.first(where: { $0.id == manager.id })?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "key.fill")
                    .font(.system(size: 14))
                    .themedForeground(.textSecondary)
            }
        }
        .frame(width: 20, height: 20)
        .help(manager.name)
    }

    private func installPasswordManagerMenu(profileId: String) -> some View {
        Menu {
            ForEach(installablePasswordManagers) { manager in
                Button(manager.name) {
                    installPasswordManager(manager, profileId: profileId)
                }
            }
        } label: {
            trailingControlPill {
                Text(NSLocalizedString("Install\u{2026}", comment: "Profiles settings - install password manager menu label"))
                    .font(.system(size: 13))
                    .themedForeground(.textPrimary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .themedForeground(.textSecondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(installablePasswordManagers.isEmpty)
        .help(NSLocalizedString("Install a password manager", comment: "Profiles settings - tooltip on the install password manager menu"))
    }

    /// Triggers a silent Chrome Web Store install into the profile and starts
    /// polling for it to land. Install results only surface through a global
    /// delegate today, so the pane re-reads the profile's extension list
    /// rather than plumbing a new event path for one row's spinner.
    private func installPasswordManager(_ manager: PasswordManagerEntry, profileId: String) {
        installingManagerIds.insert(manager.id)
        profileManager.installExtensions([manager.id], forProfile: profileId)
        pollForPasswordManagerInstall(manager.id, profileId: profileId)
    }

    /// Re-reads the profile's extensions every couple of seconds until the
    /// just-installed manager is enabled, giving up quietly after ~30s — the
    /// row then folds back into the install menu. Guards on the still-selected
    /// profile like `loadDetail`; a profile switch clears `installingManagerIds`,
    /// which also stops the poll.
    private func pollForPasswordManagerInstall(_ extensionId: String,
                                               profileId: String,
                                               attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard selectedProfileId == profileId,
                  installingManagerIds.contains(extensionId) else { return }
            profileManager.extensions(forProfile: profileId) { extensions in
                guard selectedProfileId == profileId,
                      installingManagerIds.contains(extensionId) else { return }
                profileExtensions = extensions
                let landed = extensions.contains { $0.id == extensionId && $0.enabled }
                if landed || attempt >= 14 {
                    installingManagerIds.remove(extensionId)
                } else {
                    pollForPasswordManagerInstall(extensionId,
                                                  profileId: profileId,
                                                  attempt: attempt + 1)
                }
            }
        }
    }

    // MARK: - Selection + detail loading

    private var selectedProfile: PhiBrowserProfile? {
        guard let id = selectedProfileId else { return nil }
        return profileManager.profiles.first(where: { $0.profileId == id })
    }

    private var canDeleteSelected: Bool {
        guard let profile = selectedProfile,
              profile.profileId != LocalStore.defaultProfileId else { return false }
        return spaceManager.spaces.allSatisfy { $0.profileId != profile.profileId }
    }

    private func selectInitialProfile() {
        let preferred = profileManager.profiles.first(where: { $0.profileId == LocalStore.defaultProfileId })
            ?? profileManager.profiles.first
        if let profile = preferred {
            select(profile.profileId)
        } else {
            selectedProfileId = nil
        }
    }

    private func select(_ profileId: String) {
        selectedProfileId = profileId
        // In-flight install spinners are per-profile UI state; dropping them
        // also stops their polls. The installs themselves keep running and
        // show up as detected rows on the next visit.
        installingManagerIds = []
        loadDetail(profileId)
    }

    /// Loads the selected profile's search engines and download location and
    /// swaps the new values in place. The previously shown controls stay put
    /// until the new data arrives — no clear-and-spinner on switch — so changing
    /// profiles doesn't flash: the bridge always answers a runloop later, which
    /// used to make the wiped, mid-load state briefly visible. Only the first
    /// load, when there's nothing cached to keep, shows the loading placeholder.
    ///
    /// Both round-trips guard on the still-selected profile so a fast profile
    /// switch can't let a slow off-profile load clobber the newer selection.
    private func loadDetail(_ profileId: String) {
        // Keep whatever's on screen; only show the loading state when there's
        // nothing cached to keep (first load).
        isLoadingDetail = searchEngines.isEmpty
        profileManager.searchEngines(forProfile: profileId) { engines in
            guard selectedProfileId == profileId else { return }
            searchEngines = engines
            defaultEngineId = engines.first(where: { $0.isDefault })?.id ?? engines.first?.id ?? ""
            isLoadingDetail = false
        }
        profileManager.downloadLocation(forProfile: profileId) { path in
            guard selectedProfileId == profileId else { return }
            downloadPath = path ?? ""
        }
        profileManager.extensions(forProfile: profileId) { extensions in
            guard selectedProfileId == profileId else { return }
            profileExtensions = extensions
        }
    }

    private func searchBinding(_ profileId: String) -> Binding<String> {
        Binding(
            get: { defaultEngineId },
            set: { newId in
                guard newId != defaultEngineId else { return }
                let previous = defaultEngineId
                defaultEngineId = newId
                profileManager.setDefaultSearchEngine(newId, forProfile: profileId) { success, _ in
                    if !success, selectedProfileId == profileId { defaultEngineId = previous }
                }
            }
        )
    }

    private func chooseDownloadLocation(profileId: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("Choose", comment: "Profiles settings - download folder picker confirm button")
        panel.message = NSLocalizedString("Choose a download location for this profile.",
                                          comment: "Profiles settings - download folder picker message")
        if !downloadPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: downloadPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let newPath = url.path
        let previous = downloadPath
        downloadPath = newPath
        profileManager.setDownloadLocation(newPath, forProfile: profileId) { success, _ in
            if !success, selectedProfileId == profileId { downloadPath = previous }
        }
    }

    // MARK: - Helpers

    private func spaceCountLabel(_ count: Int) -> String {
        String(format: NSLocalizedString("%d Spaces", comment: "Profiles settings - Count of Spaces bound to a profile"), count)
    }

    // MARK: - Actions

    private func deleteSelected() {
        guard let profile = selectedProfile else { return }
        deleteProfile(profile)
    }

    private func renameSelected() {
        guard let profile = selectedProfile else { return }
        renameProfile(profile)
    }

    private func newProfile() {
        guard let name = ProfileNameFieldValidator.present(.create) else { return }
        profileManager.createProfile(displayName: name) { newId in
            if let newId { select(newId) }
        }
    }

    private func renameProfile(_ profile: PhiBrowserProfile) {
        guard let trimmed = ProfileNameFieldValidator.present(
            .rename(currentName: profile.displayName, profileId: profile.profileId)) else { return }
        guard trimmed != profile.displayName else { return }
        profileManager.renameProfile(profile.profileId, to: trimmed) { success, error in
            if !success {
                let errAlert = NSAlert()
                errAlert.messageText = NSLocalizedString("Couldn't rename profile", comment: "Title of the profile-rename error")
                errAlert.informativeText = error ?? NSLocalizedString("Unknown error", comment: "Fallback profile-rename error reason")
                errAlert.runModal()
            }
        }
    }

    private func deleteProfile(_ profile: PhiBrowserProfile) {
        guard profile.profileId != LocalStore.defaultProfileId else { return }
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Delete profile \u{201C}%@\u{201D}?", comment: "Title of the delete-profile confirmation"),
            profile.displayName
        )
        alert.informativeText = NSLocalizedString(
            "All cookies, history, extensions, and saved data on this profile will be permanently removed. This cannot be undone.",
            comment: "Body of the delete-profile confirmation"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Delete", comment: "Destructive button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        profileManager.deleteProfile(profile.profileId) { success, error in
            if !success {
                let errAlert = NSAlert()
                errAlert.messageText = NSLocalizedString("Couldn't delete profile", comment: "Title of the profile-delete error")
                errAlert.informativeText = error ?? NSLocalizedString("Unknown error", comment: "Fallback profile-delete error reason")
                errAlert.runModal()
            }
        }
    }
}

/// Live validator for a profile-name field inside an `NSAlert`. Owns the field
/// and a vertical accessory (field above, an inline red message below) and keeps
/// the alert's confirm button greyed out until the trimmed name is non-empty and
/// unique. Replaces the old dismiss-and-re-present-on-error loop: errors now
/// appear inline without the alert flickering. Shared by the create (Phi menu /
/// Profiles settings / create-Space) and rename prompts; pass `excludingProfileId`
/// when renaming so a profile's own name isn't treated as a clash. An empty field
/// just disables confirm — no red message until the user types a duplicate.
///
/// The caller must keep the instance alive for the modal's lifetime; a local
/// `let` across `runModal()` suffices (`NSTextField.delegate` is weak).
final class ProfileNameFieldValidator: NSObject, NSTextFieldDelegate {
    let field = NSTextField(frame: NSRect(x: 0, y: 20, width: 240, height: 24))
    let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 44))
    private let errorLabel = NSTextField(labelWithString: "")
    private weak var confirmButton: NSButton?
    private let excludingProfileId: String?

    init(confirmButton: NSButton,
         excludingProfileId: String?,
         placeholder: String,
         initialValue: String = "") {
        self.confirmButton = confirmButton
        self.excludingProfileId = excludingProfileId
        super.init()
        field.placeholderString = placeholder
        field.stringValue = initialValue
        field.delegate = self
        field.autoresizingMask = [.width]
        errorLabel.frame = NSRect(x: 0, y: 0, width: 240, height: 16)
        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.autoresizingMask = [.width]
        accessory.addSubview(field)
        accessory.addSubview(errorLabel)
        revalidate()
    }

    /// The field's trimmed contents — what the caller should persist.
    var trimmedValue: String {
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Which prompt to present — `create` for a brand-new profile, `rename` for
    /// an existing one (its own name is excluded from the duplicate check and
    /// pre-filled for editing).
    enum Mode {
        case create
        case rename(currentName: String, profileId: String)
    }

    /// Presents the shared create/rename name alert modally and returns the
    /// confirmed, trimmed name — or nil if the user cancelled. Centralizes the
    /// `NSAlert` + field wiring that every create entry point and rename would
    /// otherwise duplicate. The live validator greys out the confirm button on an
    /// empty/duplicate name; `ProfileManager` re-checks uniqueness at submit time.
    static func present(_ mode: Mode) -> String? {
        // Pull the latest profile list before the live validator reads it: the
        // singleton can still be empty if it was first touched before the
        // Chromium bridge came up, which would let an existing name pass the
        // inline check and then fail silently at submit time. refresh() is sync.
        ProfileManager.shared.refresh()
        let alert = NSAlert()
        let validator: ProfileNameFieldValidator
        switch mode {
        case .create:
            alert.messageText = NSLocalizedString("New Profile", comment: "Title of the create-profile dialog")
            alert.informativeText = NSLocalizedString(
                "Enter a name for the new profile. Each profile has its own cookies, history, and extensions.",
                comment: "Body of the create-profile dialog")
            alert.addButton(withTitle: NSLocalizedString("Create", comment: "Create button"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
            validator = ProfileNameFieldValidator(
                confirmButton: alert.buttons[0],
                excludingProfileId: nil,
                placeholder: NSLocalizedString("Profile name", comment: "Placeholder for the profile-name field"))
        case let .rename(currentName, profileId):
            alert.messageText = NSLocalizedString("Rename Profile", comment: "Title of the rename-profile dialog")
            alert.informativeText = NSLocalizedString("Enter a new name for this profile.", comment: "Body of the rename-profile dialog")
            alert.addButton(withTitle: NSLocalizedString("Rename", comment: "Rename button"))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Cancel button"))
            validator = ProfileNameFieldValidator(
                confirmButton: alert.buttons[0],
                excludingProfileId: profileId,
                placeholder: currentName,
                initialValue: currentName)
        }
        alert.accessoryView = validator.accessory
        DispatchQueue.main.async {
            validator.field.window?.makeFirstResponder(validator.field)
            if case .rename = mode { validator.field.selectText(nil) }
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return validator.trimmedValue
    }

    /// Greys out the confirm button unless the name is non-empty and unique, and
    /// shows the inline red message only on a duplicate.
    private func revalidate() {
        let trimmed = trimmedValue
        if trimmed.isEmpty {
            errorLabel.stringValue = ""
            confirmButton?.isEnabled = false
        } else if ProfileManager.shared.displayNameExists(trimmed, excluding: excludingProfileId) {
            errorLabel.stringValue = NSLocalizedString("A profile with this name already exists.",
                comment: "Validation shown when a new or renamed profile name duplicates an existing profile")
            confirmButton?.isEnabled = false
        } else {
            errorLabel.stringValue = ""
            confirmButton?.isEnabled = true
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        revalidate()
    }
}

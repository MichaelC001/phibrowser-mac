// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

/// Rich "Create a Space" panel. Replaces the bare name-only NSAlert that used
/// to back both the File menu and the Spaces picker's "New Space" row. Lets the
/// user name the Space, bind it to a profile, and pick its theme (or Follow
/// Global) before committing.
///
/// Self-contained: the only side effect is `manager.createSpace(...)` on
/// confirm. Presented in a chrome-light floating window via `present(...)`,
/// which both entry points call so the window setup lives in one place.
struct CreateSpacePanel: View {
    enum Style {
        /// Floating window — used in the horizontal (Comfortable) layout and
        /// whenever no usable sidebar is available.
        case window
        /// Fills the sidebar in vertical (Performance / Balanced) layouts.
        case sidebar
    }

    var style: Style = .window
    @ObservedObject var manager: SpaceManager
    @ObservedObject var profileManager: ProfileManager
    /// Profile the picker opens on — the active Space's profile when reached
    /// from the sidebar, or the menu's active-window profile.
    let initialProfileId: String?
    let onClose: () -> Void

    @State private var name: String = ""
    /// Icon/emoji pinned to the new Space, chosen from the same picker the
    /// Spaces settings pane uses. Defaults to the picker's first Phi icon.
    @State private var selectedIcon: IconPickerSelection = .defaultSelection
    @State private var selectedProfileId: String = ""
    /// Theme pinned to the new Space, or `nil` to follow the global theme via
    /// the "Follow Global" toggle above the swatches. `onAppear` pre-selects a
    /// random built-in theme; the user can switch to Follow Global or another.
    @State private var selectedThemeId: String? = nil
    @FocusState private var nameFocused: Bool

    @Environment(\.phiAppearance) private var appearance

    private static let accentColor = Color(hexString: "#3AA4D5")

    var body: some View {
        styledContent
            .onAppear {
                selectedProfileId = resolvedInitialProfileId
                // Give every new Space a fresh random look out of the box — a
                // random Phi icon and a random built-in theme — so Spaces are
                // visually distinct instead of all defaulting to the same first
                // icon and the inherited theme. The user can still override both
                // before creating: a pinned theme, or "Follow Global" to track
                // the global theme instead of pinning one.
                selectedIcon = .phiIcon(id: PhiIconCatalog.allIds.randomElement() ?? PhiIconCatalog.allIds[0])
                selectedThemeId = Theme.builtInThemes.randomElement()?.id ?? Theme.default.id
                DispatchQueue.main.async { nameFocused = true }
            }
    }

    @ViewBuilder
    private var styledContent: some View {
        switch style {
        case .window:
            formStack
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(width: formMaxWidth + 40)
        case .sidebar:
            // Transparent so the themed visual-effect backdrop installed by
            // `SidebarViewController.showCreateSpaceOverlay` shows through —
            // the form then sits on the active Space's overlay color and
            // opacity instead of an opaque card that ignores the Space theme.
            // Vertically centered when the form is shorter than the sidebar, but
            // still scrolls when the embedded icon grid makes it taller than a
            // short sidebar so the create button stays reachable: pinning a
            // `minHeight` of the container expands the content frame to the
            // sidebar height (SwiftUI centers within it by default) while letting
            // it grow past that height to drive the ScrollView.
            //
            // A vertical ScrollView proposes its content's *ideal* width rather
            // than its own, so the bounded column renders at full width and
            // clips in a narrow sidebar — and never reflows when the divider is
            // dragged. Read the live container width from an outer GeometryReader
            // (which tracks the hosting view's bounds across resizes) and pin the
            // scroll content to it so the form follows the sidebar width.
            GeometryReader { geo in
                ScrollView {
                    formStack
                        .padding(.horizontal, 10)
                        .padding(.vertical, 20)
                        .frame(width: geo.size.width)
                        .frame(minHeight: geo.size.height)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(Rectangle())
            }
        }
    }

    private var formStack: some View {
        VStack(spacing: 28) {
            header
            form
            actions
        }
        // One bounded, centered column so every element shares a width and the
        // form never stretches across a wide sidebar. In a narrower sidebar it
        // shrinks to fit; the icon grid reflows to match.
        .frame(maxWidth: formMaxWidth)
    }

    /// Bounded column width. The floating popup uses a comfortable dialog width;
    /// the sidebar overlay fills the sidebar (minus its slim padding) up to the
    /// same width, so only an unusually wide sidebar leaves margins.
    private var formMaxWidth: CGFloat {
        style == .window ? Self.windowContentWidth : Self.sidebarContentWidth
    }

    private static let sidebarContentWidth: CGFloat = 320
    private static let windowContentWidth: CGFloat = 280

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            Text(NSLocalizedString("Create a Space",
                comment: "Title of the create-Space panel"))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.85))
            Text(NSLocalizedString("Each space has its own independent bookmarks",
                comment: "Subtitle of the create-Space panel"))
                .font(.system(size: 14))
                .foregroundStyle(Color.primary.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var form: some View {
        VStack(spacing: 4) {
            nameField
            profileRow
            iconBlock
            colorBlock
        }
    }

    /// Inline icon/emoji picker, mirroring the Spaces settings pane so creating a
    /// Space offers the same chooser as editing one. A greedy `GeometryReader`
    /// reports the real column width so the picker fills it exactly (a plain
    /// `.frame(maxWidth:.infinity)` leaves the adaptive grid at its 1-column
    /// minimum, centered).
    private var iconBlock: some View {
        GeometryReader { geo in
            IconPicker(
                selected: selectedIcon,
                showsGroups: true,
                width: geo.size.width,
                onSelect: { selectedIcon = $0 }
            )
        }
        .frame(height: IconPicker.preferredHeight)
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var nameField: some View {
        TextField(
            NSLocalizedString("Space name", comment: "Placeholder for the Space-name field"),
            text: $name
        )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($nameFocused)
            .onSubmit(create)
            .frame(height: 32)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var profileRow: some View {
        HStack(spacing: 8) {
            Text(NSLocalizedString("Profile",
                comment: "Label for the profile picker in the create-Space panel"))
                .font(.system(size: 13))
                .foregroundStyle(Color.primary.opacity(0.85))
            Spacer(minLength: 0)
            profilePill
        }
        .frame(height: 32)
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var profilePill: some View {
        Menu {
            ForEach(profileManager.userAssignableProfiles, id: \.profileId) { profile in
                Button(profile.displayName) { selectedProfileId = profile.profileId }
            }
            Divider()
            Button {
                promptCreateProfile()
            } label: {
                Label(NSLocalizedString("New Profile\u{2026}",
                    comment: "Profile picker item to create a new profile"),
                    systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedProfileName)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.5))
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 20)
            .background(Color.primary.opacity(0.06))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private static let themeColumns = 4
    private static let themeColumnSpacing: CGFloat = 8
    private static let themeRowSpacing: CGFloat = 12
    private static let themeDotRing: CGFloat = 30
    private static let followGlobalToggleHeight: CGFloat = 30

    private var colorBlock: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: Self.themeColumnSpacing),
            count: Self.themeColumns
        )
        return VStack(spacing: 14) {
            // A "Follow Global" toggle above the swatches: it and the theme dots
            // form one selection group, so the new Space either follows the
            // global theme or pins one of the eight built-ins. A GeometryReader
            // gives the row width so the toggle insets its ends to line up with
            // the first/last dot rather than the wider grid bounds.
            GeometryReader { geo in
                followGlobalToggle
                    .padding(.horizontal, followGlobalToggleInset(forWidth: geo.size.width))
            }
            .frame(height: Self.followGlobalToggleHeight)
            // Lay the eight built-in themes out as two rows of four rather than a
            // single cramped strip, so each swatch is big enough to read its hue
            // and tap comfortably. Flexible columns spread the swatches evenly
            // across the bounded column and shrink with the sidebar.
            LazyVGrid(columns: columns, spacing: Self.themeRowSpacing) {
                ForEach(Theme.builtInThemes, id: \.id) { theme in
                    themeDot(theme, ringDiameter: Self.themeDotRing)
                }
            }
            // The current theme's name, as a plain muted caption beneath the
            // swatches.
            Text(selectedThemeName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .animation(.easeInOut(duration: 0.15), value: selectedThemeId)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Horizontal inset that lines the full-width toggle up with the swatch row:
    /// each flexible column centers a `themeDotRing`-wide dot, leaving half the
    /// leftover column width as slack between the outer dots and the row's edges.
    /// Matching that slack puts the toggle's ends under the first/last dot.
    private func followGlobalToggleInset(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        let gaps = Self.themeColumnSpacing * CGFloat(Self.themeColumns - 1)
        let column = (width - gaps) / CGFloat(Self.themeColumns)
        return max(0, (column - Self.themeDotRing) / 2)
    }

    /// Full-width "Follow Global" toggle above the swatch grid. It and the theme
    /// dots form one selection group: tapping it clears the pin
    /// (`selectedThemeId = nil`) so the new Space tracks the global theme, and a
    /// checkmark marks it active — matching the dots' selected read. A leading
    /// dot previews the current global theme color.
    private var followGlobalToggle: some View {
        let globalTheme = ThemeManager.shared.currentTheme
        let isPure = globalTheme == .pure
        let globalAccent = Color(globalTheme.color(for: .themeColor, appearance: appearance))
        let isSelected = selectedThemeId == nil
        return Button {
            selectedThemeId = nil
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(isPure ? Color.white : globalAccent)
                    .frame(width: 14, height: 14)
                    .overlay {
                        Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5)
                    }
                Text(NSLocalizedString("Follow Global",
                    comment: "Create-Space panel — toggle so the new Space follows the global theme"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Self.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.followGlobalToggleHeight)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Self.accentColor.opacity(0.14) : Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Self.accentColor : Color.clear, lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Follow Global",
            comment: "Create-Space panel — toggle so the new Space follows the global theme"))
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    /// One picker dot for a built-in theme. The colored dot keeps a 3pt margin
    /// inside the ring; the selected swatch carries a check for an unmistakable
    /// read that the ring alone can't give against a same-hue dot.
    @ViewBuilder
    private func themeDot(_ theme: Theme, ringDiameter: CGFloat) -> some View {
        let isPure = theme == .pure
        let accent = Color(theme.color(for: .themeColor, appearance: appearance))
        let isSelected = selectedThemeId == theme.id
        let dot = max(ringDiameter - 6, 0)
        Button {
            selectedThemeId = theme.id
        } label: {
            Circle()
                .fill(isPure ? Color.white : accent)
                .frame(width: dot, height: dot)
                .frame(width: ringDiameter, height: ringDiameter)
                .overlay {
                    Circle()
                        .stroke(Color.black.opacity(isPure ? 0.12 : 0), lineWidth: 0.5)
                        .frame(width: dot, height: dot)
                }
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: max(dot * 0.5, 8), weight: .bold))
                            .foregroundStyle(isPure ? Color.black.opacity(0.55) : Color.white)
                    }
                }
                .overlay {
                    Circle()
                        .stroke(isSelected ? accent : Color.clear, lineWidth: 2)
                }
                .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(theme.name)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    /// Caption under the swatches: the pinned theme's name, or "Follow Global"
    /// when no theme is pinned.
    private var selectedThemeName: String {
        if selectedThemeId == nil {
            return NSLocalizedString("Follow Global",
                comment: "Create-Space panel — toggle so the new Space follows the global theme")
        }
        return effectiveTheme().name
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button(action: create) {
                Text(NSLocalizedString("Create Space",
                    comment: "Confirm button in the create-Space panel"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Self.accentColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Text(NSLocalizedString("Cancel", comment: "Cancel button"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.85))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Color math

    /// The theme id used to resolve the swatch fill, caption, and derived
    /// `colorHex`. Follow-Global (`nil`) resolves to the current global theme so
    /// those track whatever the global theme is.
    private var effectiveThemeId: String {
        selectedThemeId ?? ThemeManager.shared.currentTheme.id
    }

    /// The Space's stored `colorHex` (which drives the sidebar tint) is derived
    /// from the resolved theme's overlay color, so the tint matches the Space's
    /// pinned theme — or the global theme when it follows global.
    private func resolvedColorHex() -> String {
        effectiveTheme().color(for: .windowOverlayBackground, appearance: appearance).hexRGBString
    }

    /// The theme backing the new Space, resolved from the selection (or the
    /// global theme when following global).
    private func effectiveTheme() -> Theme {
        ThemeManager.shared.registeredThemes[effectiveThemeId]
            ?? Theme.builtInThemes.first(where: { $0.id == effectiveThemeId })
            ?? ThemeManager.shared.currentTheme
    }

    // MARK: - Profiles

    private var resolvedInitialProfileId: String {
        if let id = initialProfileId,
           profileManager.userAssignableProfiles.contains(where: { $0.profileId == id }) {
            return id
        }
        return profileManager.userAssignableProfiles.first?.profileId ?? LocalStore.defaultProfileId
    }

    private var selectedProfileName: String {
        profileManager.profile(for: selectedProfileId)?.displayName ?? selectedProfileId
    }

    /// Prompts for a name and creates a new profile, selecting it for this
    /// Space once the bridge reports the new id. Mirrors the menu's
    /// `newProfile` flow so both entry points behave identically.
    private func promptCreateProfile() {
        guard let name = ProfileNameFieldValidator.present(.create) else { return }
        profileManager.createProfile(displayName: name) { newId in
            if let newId { selectedProfileId = newId }
        }
    }

    // MARK: - Commit

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty
            ? String(format: NSLocalizedString("Space %d",
                comment: "Default name for a newly created Space"),
                manager.spaces.count + 1)
            : trimmed
        let profileId = selectedProfileId.isEmpty ? resolvedInitialProfileId : selectedProfileId
        let newSpaceId = manager.createSpace(
            name: finalName,
            colorHex: resolvedColorHex(),
            iconName: selectedIcon.storageValue,
            profileId: profileId
        )
        // Apply the chosen theme to the new Space: a pinned id pins it, `nil`
        // (Follow Global) clears the override so it tracks the global theme.
        // Persisted now; applied when its window spawns in activateInFocusedWindow.
        if let newSpaceId {
            manager.setTheme(forSpaceId: newSpaceId, themeId: selectedThemeId)
        }
        onClose()
        // Bring the freshly created Space to the front of the active window.
        // `createSpace` only records it as the persisted default, so without
        // this the current window would stay on the Space we created from — in
        // both the sidebar (vertical) and floating-panel (horizontal) flows.
        // Runs after `onClose` so the overlay / panel is torn down first and the
        // switch animation plays over the revealed sidebar rather than under it.
        if let newSpaceId {
            manager.activateInFocusedWindow(spaceId: newSpaceId)
        }
    }
}

// MARK: - Presentation

extension CreateSpacePanel {
    private static let windowIdentifier = "Phi Create Space"

    /// Single entry point for "New Space" from the menu or the Spaces picker.
    /// Vertical layouts (Performance / Balanced) show the form inline in the
    /// sidebar surface — the docked sidebar, or the floating panel while the
    /// sidebar is collapsed and the panel is up. The horizontal layout
    /// (Comfortable) — or any window without a usable sidebar surface —
    /// falls back to the standalone window.
    static func requestCreation(initialProfileId: String?) {
        if let wc = MainBrowserWindowControllersManager.shared.activeWindowController,
           !wc.browserState.layoutMode.isTraditional {
            if !wc.browserState.sidebarCollapsed {
                let sidebar = wc.mainSplitViewController.sidebarViewController
                if sidebar.isViewLoaded, sidebar.view.window != nil, sidebar.view.bounds.width > 120 {
                    sidebar.showCreateSpaceOverlay(initialProfileId: initialProfileId)
                    return
                }
            } else {
                // Collapsed sidebar: the docked sidebar still passes
                // window/width checks (the split item keeps the view parked
                // at its last width), but it's invisible — the form must not
                // mount there. The floating panel is the sidebar surface
                // then: host the form inline in the open panel (which pins
                // itself open while the form is up). No open panel — e.g.
                // the menu's "New Space" without hovering — falls through
                // to the standalone window.
                let webContent = wc.mainSplitViewController.webContentContainerViewController
                if let floating = webContent.floatingSidebarViewController,
                   webContent.floatingSidebarContainerView?.isHidden == false,
                   floating.isViewLoaded, floating.view.bounds.width > 120 {
                    floating.showCreateSpaceOverlay(initialProfileId: initialProfileId)
                    return
                }
            }
        }
        present(manager: .shared, initialProfileId: initialProfileId)
    }

    /// Brings up the create-Space panel in a single shared, chrome-light
    /// window. Reuses an already-open window so repeated invocations from the
    /// menu or the picker don't stack duplicates.
    @discardableResult
    static func present(manager: SpaceManager,
                        profileManager: ProfileManager = .shared,
                        initialProfileId: String?) -> NSWindow {
        if let existing = NSApp.windows.first(where: {
            $0.identifier?.rawValue == windowIdentifier
        }) {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return existing
        }

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(windowIdentifier)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let panel = CreateSpacePanel(
            manager: manager,
            profileManager: profileManager,
            initialProfileId: initialProfileId
        ) { [weak window] in
            window?.close()
        }
        let hosting = ThemedHostingController(rootView: panel)
        window.contentViewController = hosting
        window.setContentSize(hosting.view.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }
}

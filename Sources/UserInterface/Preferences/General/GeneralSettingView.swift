// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import SwiftUI

enum NewTabBehaviour: String, CaseIterable, Identifiable {
    case newTabPage
    case omnibox
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .newTabPage:
            return NSLocalizedString("New Tab Page", comment: "General settings - Option to open New Tab Page when pressing ⌘+T")
        case .omnibox:
            return NSLocalizedString("Omnibox", comment: "General settings - Option to open Omnibox search when pressing ⌘+T")
        }
    }
}

struct GeneralSettingView: View {
    @ObservedObject private var settingsPresentation = SettingsPresentationState.shared

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 24) {
                if !settingsPresentation.openedFromIncognito {
                    ThemeSectionView()
                }
                AppearanceSectionView()
                BrowsingSectionView()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 36)
            .padding(.horizontal, 36)
        }
        .themedBackground(PhiPreferences.fixedWindowBackground)
        .frame(width: 680, height: 561)
    }
}

private struct ThemeSectionView: View {
    @ObservedObject private var spaceManager = SpaceManager.shared

    @State private var selectedThemeId: String = ThemeManager.shared.currentTheme.id
    @State private var sliderValue: Double = OverlayOpacityScale.sliderValue(
        forOpacityPercent: ThemeManager.shared.currentTheme.windowOverlayOpacity(for: ThemeManager.shared.currentAppearance) * 100
    )

    @AppStorage(PhiPreferences.ThemeSettings.selectionTintEnabled.rawValue)
    private var selectionTintEnabled: Bool = true

    @Environment(\.phiAppearance) private var appearance

    private var themes: [Theme] {
        ThemeManager.shared.orderedThemes
    }

    private var selectedTheme: Theme {
        themes.first(where: { $0.id == selectedThemeId }) ?? ThemeManager.shared.currentTheme
    }

    private var sliderTrackColor: NSColor {
        selectedTheme.color(for: .windowOverlayBackground, appearance: appearance)
    }

    private var sliderBorderColor: NSColor {
        ThemedColor.border.resolve(theme: selectedTheme, appearance: appearance)
    }

    /// These controls edit the DEFAULT Space. With a single Space that is
    /// the whole browser; once more Spaces exist, each one carries its own
    /// color and opacity, so the rows lock and defer to the Spaces pane.
    private var themeEditingLocked: Bool {
        spaceManager.userSpaces.count > 1
    }

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("Theme", comment: "General settings - Theme section title")) {
            GeneralContainerView {
                VStack(spacing: 0) {
                    Group {
                        HStack(alignment: .top, spacing: 12) {
                            Text(NSLocalizedString("Color", comment: "General settings - Theme color row title"))
                                .font(.system(size: 13))
                                .themedForeground(.textPrimary)

                            Spacer(minLength: 12)

                            HStack(alignment: .top, spacing: 13) {
                                ForEach(themes, id: \.id) { theme in
                                    ThemeColorItemView(
                                        theme: theme,
                                        selected: selectedThemeId == theme.id,
                                        action: { selectTheme(theme) }
                                    )
                                }
                            }
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Divider()

                        GeneralRowView(title: NSLocalizedString("Opacity", comment: "General settings - Theme opacity row title for adjusting the selected theme overlay transparency")) {
                            ThemeOpacitySliderView(
                                value: Binding(
                                    get: { sliderValue },
                                    set: { newValue in
                                        sliderValue = newValue
                                        handleSliderValueChanged(newValue)
                                    }
                                ),
                                trackColor: sliderTrackColor,
                                borderColor: sliderBorderColor
                            )
                            .frame(width: 324, height: 20)
                        }
                    }
                    .disabled(themeEditingLocked)
                    .opacity(themeEditingLocked ? 0.4 : 1.0)

                    if themeEditingLocked {
                        Divider()
                        editInSpacesHintRow
                    }

                    Divider()

                    GeneralRowView(title: NSLocalizedString("Apply theme to text selection on web pages", comment: "General settings - Toggle title for tinting ::selection on third-party pages with the window theme accent")) {
                        Toggle("", isOn: $selectionTintEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .themedTint(.themeColor)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .themeDidChange)) { _ in
            syncThemeControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appearanceDidChange)) { _ in
            syncSliderValue()
        }
        .onReceive(NotificationCenter.default.publisher(for: .spaceThemeDidChange)) { _ in
            syncThemeControls()
        }
        .onAppear {
            syncThemeControls()
        }
    }

    /// Shown while the color/opacity rows are locked: says why and jumps
    /// to the pane where per-Space themes are edited.
    private var editInSpacesHintRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(NSLocalizedString("You have more than one Space, so each Space sets its own color and opacity.", comment: "General settings - Hint shown when the theme color/opacity rows are locked because multiple Spaces exist"))
                .font(.system(size: 11))
                .themedForeground(.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button {
                AppController.shared?.showSettings(pane: .spaces)
            } label: {
                Text(NSLocalizedString("Edit in Spaces settings\u{2026}", comment: "General settings - Link that jumps to the Spaces settings pane"))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectTheme(_ theme: Theme) {
        guard selectedThemeId != theme.id else { return }

        selectedThemeId = theme.id
        // This control edits the default Space; SpaceManager also switches
        // the global theme to it so non-browser chrome and pre-Space
        // fallbacks stay in step.
        SpaceManager.shared.setTheme(forSpaceId: LocalStore.defaultSpaceId, themeId: theme.id)
        syncSliderValue()
    }

    private func handleSliderValueChanged(_ newSliderValue: Double) {
        // Always resolve the appearance through the manager. The Binding stored in
        // ThemeOpacitySliderView.Coordinator is created once and captures a stale
        // `self`, so reading the View's @Environment here would target the wrong
        // appearance after a light/dark switch.
        let opacityPercent = OverlayOpacityScale.opacityPercent(forSlider: newSliderValue)
        let alpha = CGFloat(opacityPercent / 100)
        AppLogDebug("[OverlayOpacity] slider→opacity slider=\(newSliderValue) percent=\(opacityPercent) alpha=\(alpha) appearance=\(ThemeManager.shared.currentAppearance) theme=\(ThemeManager.shared.currentTheme.id)")
        // Persist on the default Space first so its window's resolver reads
        // the new value when the registry rewrite below publishes.
        SpaceManager.shared.setOverlayOpacity(
            alpha,
            forSpaceId: LocalStore.defaultSpaceId,
            appearance: ThemeManager.shared.currentAppearance
        )
        // Keep the registry rewrite: it is what future Spaces (and the
        // create panel's previews) inherit as their default alpha. Only
        // reachable with a single user Space, so it can't bleed across
        // other Spaces' custom opacities.
        ThemeManager.shared.updateCurrentThemeOverlayOpacity(alpha)
    }

    private func syncThemeControls() {
        selectedThemeId = SpaceManager.shared.resolvedThemeId(forSpaceId: LocalStore.defaultSpaceId)
        syncSliderValue()
    }

    private func syncSliderValue() {
        let appearance = ThemeManager.shared.currentAppearance
        let alpha = SpaceManager.shared.effectiveOverlayOpacity(forSpaceId: LocalStore.defaultSpaceId, appearance: appearance)
        let opacityPercent = alpha * 100
        let newSliderValue = OverlayOpacityScale.sliderValue(forOpacityPercent: opacityPercent)
        AppLogDebug("[OverlayOpacity] sync appearance=\(appearance) theme=\(ThemeManager.shared.currentTheme.id) alpha=\(alpha) percent=\(opacityPercent) slider=\(newSliderValue) (was=\(sliderValue))")
        sliderValue = newSliderValue
    }
}

private struct AppearanceSectionView: View {
    @AppStorage(PhiPreferences.GeneralSettings.layoutModeKey)
    private var layoutModeRawValue: String = PhiPreferences.GeneralSettings.loadLayoutMode().rawValue

    @State private var selectedAppearance: UserAppearanceChoice = ThemeManager.shared.userAppearanceChoice

    private var selectedLayoutMode: Binding<LayoutMode> {
        Binding(
            get: { LayoutMode(rawValue: layoutModeRawValue) ?? PhiPreferences.GeneralSettings.loadLayoutMode() },
            set: { mode in
                layoutModeRawValue = mode.rawValue
                PhiPreferences.GeneralSettings.saveLayoutMode(mode)
            }
        )
    }

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("Appearance", comment: "General settings - Appearance section title")) {
            GeneralContainerView {
                GeneralRowView(title: NSLocalizedString("Layout mode", comment: "General settings - Layout mode row title"), alignment: .top) {
                    HStack(spacing: 16) {
                        ForEach(LayoutMode.allCases) { mode in
                            GeneralSttingCardView(
                                image: Image(layoutImageResource(for: mode)),
                                action: { selectedLayoutMode.wrappedValue = mode },
                                selected: selectedLayoutMode.wrappedValue == mode,
                                title: mode.displayName
                            )
                        }
                    }
                }

                Divider()

                GeneralRowView(title: NSLocalizedString("Color appearance", comment: "General settings - Color appearance row title"), alignment: .top) {
                    HStack(spacing: 16) {
                        ForEach(UserAppearanceChoice.allCases, id: \.self) { choice in
                            GeneralSttingCardView(
                                image: Image(appearanceImageName(for: choice)),
                                action: {
                                    selectedAppearance = choice
                                    ThemeManager.shared.setUserAppearanceChoice(choice)
                                },
                                selected: selectedAppearance == choice,
                                title: choice.localizedName
                            )
                        }
                    }
                }
            }
        }
    }

    private func layoutImageResource(for mode: LayoutMode) -> ImageResource {
        switch mode {
        case .performance:
            return .tabLayoutPerformance
        case .balanced:
            return .tabLayoutBalanced
        case .comfortable:
            return .tabLayoutComfortable
        }
    }

    private func appearanceImageName(for choice: UserAppearanceChoice) -> String {
        switch choice {
        case .system:
            return "appearance-system"
        case .light:
            return "appearance-light"
        case .dark:
            return "appearance-dark"
        }
    }
}

private struct BrowsingSectionView: View {
    @AppStorage(PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.rawValue)
    private var openNewTabPageOnCmdT: Bool = PhiPreferences.GeneralSettings.openNewTabPageOnCmdT.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.alwaysShowURLPath.rawValue)
    private var alwaysShowURLPath: Bool = PhiPreferences.GeneralSettings.alwaysShowURLPath.defaultValue

    @AppStorage(PhiPreferences.AISettings.phiAIEnabled.rawValue)
    private var phiAIEnabled: Bool = PhiPreferences.AISettings.phiAIEnabled.defaultValue

    @AppStorage(PhiPreferences.GeneralSettings.autoPictureInPictureModeKey)
    private var autoPictureInPictureModeRawValue: String = PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode().rawValue

    private var selectedBehavior: Binding<NewTabBehaviour> {
        Binding(
            get: { openNewTabPageOnCmdT ? .newTabPage : .omnibox },
            set: { openNewTabPageOnCmdT = ($0 == .newTabPage) }
        )
    }

    private var selectedAutoPipMode: Binding<AutoPictureInPictureMode> {
        Binding(
            get: {
                AutoPictureInPictureMode(rawValue: autoPictureInPictureModeRawValue)
                    ?? PhiPreferences.GeneralSettings.loadAutoPictureInPictureMode()
            },
            set: { mode in
                autoPictureInPictureModeRawValue = mode.rawValue
                PhiPreferences.GeneralSettings.saveAutoPictureInPictureMode(mode)
            }
        )
    }

    var body: some View {
        GeneralSectionView(title: NSLocalizedString("Browsing", comment: "General settings - Browsing section title")) {
            VStack(alignment: .leading, spacing: 8) {
                GeneralContainerView {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("New tab behavior", comment: "General settings - Row title for configuring new tab behavior"))
                                .font(.system(size: 13))
                                .themedForeground(.textPrimary)
                            if !phiAIEnabled {
                                Text(NSLocalizedString("New Tab Page requires Phi AI to be enabled", comment: "General settings - Hint shown when Phi AI is disabled explaining New Tab Page requires it"))
                                    .font(.system(size: 11))
                                    .themedForeground(.textTertiary)
                            }
                        }
                        Spacer(minLength: 12)
                        HStack(spacing: 16) {
                            ForEach(NewTabBehaviour.allCases) { behavior in
                                GeneralSttingCardView(
                                    image: Image(newTabImageName(for: behavior)),
                                    action: {
                                        if behavior == .newTabPage && !phiAIEnabled { return }
                                        selectedBehavior.wrappedValue = behavior
                                    },
                                    selected: selectedBehavior.wrappedValue == behavior,
                                    title: behavior.displayName
                                )
                                .opacity(behavior == .newTabPage && !phiAIEnabled ? 0.4 : 1.0)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    GeneralRowView(title: NSLocalizedString("Always show full URL", comment: "General settings - Toggle title for always showing full URL in address bar")) {
                        Toggle("", isOn: $alwaysShowURLPath)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .themedTint(.themeColor)
                    }

                    Divider()

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("Auto picture-in-picture", comment: "General settings - Row title for the three-state auto picture-in-picture mode"))
                                .font(.system(size: 13))
                                .themedForeground(.textPrimary)
                            Text(autoPipModeHint(for: selectedAutoPipMode.wrappedValue))
                                .font(.system(size: 11))
                                .themedForeground(.textTertiary)
                        }
                        Spacer(minLength: 12)
                        Picker("", selection: selectedAutoPipMode) {
                            ForEach(AutoPictureInPictureMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()
                    
                    Button(action: handleAdditionalBrowserSettingsTap) {
                        GeneralRowView(title: NSLocalizedString("Additional browser settings", comment: "General settings - Title for always more settings")) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .themedForeground(.textSecondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func newTabImageName(for behavior: NewTabBehaviour) -> String {
        switch behavior {
        case .newTabPage:
            return "newtab-ntp"
        case .omnibox:
            return "newtab-omibar"
        }
    }

    private func autoPipModeHint(for mode: AutoPictureInPictureMode) -> String {
        switch mode {
        case .off:
            return NSLocalizedString("Never pop out automatically; manual picture-in-picture still works", comment: "General settings - Hint for the Off auto picture-in-picture mode")
        case .normal:
            return NSLocalizedString("Pop out playing video when you switch tabs or apps", comment: "General settings - Hint for the Normal auto picture-in-picture mode")
        case .parked:
            return NSLocalizedString("Pop out playing video, parked at the screen edge until you click it", comment: "General settings - Hint for the Park at edge auto picture-in-picture mode")
        }
    }

    private func handleAdditionalBrowserSettingsTap() {
        MainBrowserWindowControllersManager
            .shared
            .activeWindowController?
            .browserState
            .createTab("chrome://settings")
    }
}

private struct GeneralSectionView<Content: View>: View {
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

private struct GeneralContainerView<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 12)
        .themedBackground(.settingItemBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .themedStroke(.border)
        }
    }
}

private struct GeneralRowView<Accessory: View>: View {
    let title: String
    var alignment: VerticalAlignment = .center
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .themedForeground(.textPrimary)
            Spacer(minLength: 12)
            accessory
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ThemeColorItemView: View {
    let theme: Theme
    let selected: Bool
    let action: () -> Void

    @Environment(\.phiAppearance) private var appearance

    private var swatchColor: Color {
        if theme == .pure {
            return .white
        }
        return Color(theme.color(for: .themeColor, appearance: appearance))
    }

    var body: some View {
        ThemeSwatchView(
            fillColor: swatchColor,
            ringColor: Color(theme.color(for: .themeColor, appearance: appearance)),
            selected: selected,
            title: theme.name,
            showsContrastBorder: theme == .pure,
            action: action
        )
        .frame(width: 30)
    }
}

#Preview {
    GeneralSettingView()
}

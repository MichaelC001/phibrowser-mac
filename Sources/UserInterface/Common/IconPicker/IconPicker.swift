// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import SwiftUI

struct IconPicker: View {
    let selected: IconPickerSelection?
    let showsGroups: Bool
    /// Explicit width for the picker. Nil keeps the fixed default (262pt / 8
    /// columns) used by popovers and the settings pane. When set, the picker
    /// fills exactly that width and the grid reflows to as many columns as fit —
    /// the create-Space form measures its container and passes the width in.
    let width: CGFloat?
    let onSelect: (IconPickerSelection) -> Void

    private let emojiCatalog: EmojiCatalog

    @State private var selectedTab: IconPickerTab
    @State private var iconSearchText = ""
    @State private var emojiSearchText = ""

    /// Fixed height callers can use to size a container around the picker.
    static let preferredHeight: CGFloat = IconPickerMetrics.height

    init(selected: IconPickerSelection?,
         showsGroups: Bool,
         width: CGFloat? = nil,
         emojiCatalog: EmojiCatalog = .shared,
         onSelect: @escaping (IconPickerSelection) -> Void) {
        self.selected = selected
        self.showsGroups = showsGroups
        self.width = width
        self.emojiCatalog = emojiCatalog
        self.onSelect = onSelect
        _selectedTab = State(initialValue: selected?.isEmoji == true ? .emoji : .icon)
    }

    private var resolvedWidth: CGFloat { width ?? IconPickerMetrics.width }

    var body: some View {
        pickerBody
            .frame(width: resolvedWidth, height: IconPickerMetrics.height)
    }

    private var pickerBody: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Icon").tag(IconPickerTab.icon)
                Text("Emoji").tag(IconPickerTab.emoji)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .themedTint(.themeColor)
            .controlSize(.small)
            .frame(width: IconPickerMetrics.segmentWidth, height: IconPickerMetrics.segmentHeight)

            IconPickerSearchField(
                text: activeSearchText,
                placeholder: searchPlaceholder
            )
            .padding(.top, IconPickerMetrics.segmentToSearchSpacing)
            .padding(.horizontal, searchHorizontalPadding)

            Group {
                switch selectedTab {
                case .icon:
                    phiIconGrid
                case .emoji:
                    emojiGrid
                }
            }
            .padding(.top, IconPickerMetrics.searchToGridSpacing)
        }
        .padding(.top, IconPickerMetrics.topPadding)
        .padding(.bottom, IconPickerMetrics.bottomPadding)
    }

    private var activeSearchText: Binding<String> {
        switch selectedTab {
        case .icon:
            $iconSearchText
        case .emoji:
            $emojiSearchText
        }
    }

    private var activeSearchQuery: String {
        switch selectedTab {
        case .icon:
            iconSearchText
        case .emoji:
            emojiSearchText
        }
    }

    private var searchPlaceholder: String {
        switch selectedTab {
        case .icon:
            NSLocalizedString(
                "Search icons",
                comment: "Icon picker - Search field placeholder for Phi icons"
            )
        case .emoji:
            NSLocalizedString(
                "Search emoji",
                comment: "Icon picker - Search field placeholder for emoji"
            )
        }
    }

    private var searchHorizontalPadding: CGFloat {
        guard width == nil else { return IconPickerMetrics.gridHorizontalPadding }
        return (resolvedWidth - IconPickerMetrics.fixedGridContentWidth) / 2
    }

    /// As many columns as fit `resolvedWidth` when an explicit width was given,
    /// else the fixed 8-column layout. The reflow path packs the *most* icons a
    /// row can hold at their natural size and lets flexible columns share the
    /// leftover, so the row fills the box edge-to-edge. Sizing each column to a
    /// full item+gap unit instead fits one fewer column and leaves the whole grid
    /// centered with wide left/right margins that read as stray padding in a
    /// narrow sidebar. The column `spacing` here is the horizontal gap only — the
    /// `LazyVGrid`'s own `spacing:` controls row spacing — so a tight reflow gap
    /// doesn't change the vertical rhythm.
    private static let reflowColumnSpacing: CGFloat = 2

    private var gridColumns: [GridItem] {
        guard width != nil else { return IconPickerMetrics.columns }
        let usable = resolvedWidth - 2 * IconPickerMetrics.gridHorizontalPadding
        let count = max(1, Int(usable / IconPickerMetrics.itemSize))
        return Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: Self.reflowColumnSpacing),
            count: count
        )
    }

    private var phiIconGrid: some View {
        ScrollView {
            Group {
                if filteredPhiIcons.isEmpty {
                    emptySearchResults
                } else {
                    LazyVGrid(columns: gridColumns, spacing: IconPickerMetrics.rowSpacing) {
                        ForEach(filteredPhiIcons) { icon in
                            IconPickerGridButton(
                                isSelected: selected == .phiIcon(id: icon.assetName),
                                help: icon.name,
                                action: { onSelect(.phiIcon(id: icon.assetName)) }
                            ) {
                                Image(icon.assetName)
                                    .resizable()
                                    .renderingMode(.original)
                                    .scaledToFit()
                                    .frame(width: IconPickerMetrics.iconSize, height: IconPickerMetrics.iconSize)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, IconPickerMetrics.gridHorizontalPadding)
            .padding(.vertical, IconPickerMetrics.gridVerticalPadding)
        }
        .frame(height: IconPickerMetrics.gridHeight)
    }

    private var filteredPhiIcons: [PhiIconCatalog.Icon] {
        IconPickerSearch.phiIcons(matching: activeSearchQuery)
    }

    private var emojiGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if showsGroups {
                    if filteredEmojiGroups.isEmpty {
                        emptySearchResults
                    } else {
                        ForEach(filteredEmojiGroups) { group in
                            emojiGroup(group)
                        }
                    }
                } else {
                    if filteredEmojiItems.isEmpty {
                        emptySearchResults
                    } else {
                        emojiItemsGrid(filteredEmojiItems)
                    }
                }
            }
            .padding(.horizontal, IconPickerMetrics.gridHorizontalPadding)
            .padding(.vertical, IconPickerMetrics.gridVerticalPadding)
        }
        .frame(height: IconPickerMetrics.gridHeight)
    }

    private var filteredEmojiGroups: [EmojiCatalog.Group] {
        IconPickerSearch.emojiGroups(in: emojiCatalog, matching: activeSearchQuery)
    }

    private var filteredEmojiItems: [EmojiItem] {
        IconPickerSearch.emojiItems(in: emojiCatalog, matching: activeSearchQuery)
    }

    private var emptySearchResults: some View {
        Text(NSLocalizedString(
            "No results",
            comment: "Icon picker - Empty state when search has no matching icons"
        ))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(
            minHeight: IconPickerMetrics.gridHeight
                - 2 * IconPickerMetrics.gridVerticalPadding
        )
    }

    private func emojiGroup(_ group: EmojiCatalog.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
            emojiItemsGrid(group.items)
        }
    }

    private func emojiItemsGrid(_ items: [EmojiItem]) -> some View {
        LazyVGrid(columns: gridColumns, spacing: IconPickerMetrics.rowSpacing) {
            ForEach(items) { item in
                EmojiPickerGridButton(
                    item: item,
                    selectedEmojiId: selectedEmojiId,
                    onSelect: onSelect
                )
            }
        }
    }

    private var selectedEmojiId: String? {
        guard case .emoji(let id, _) = selected else { return nil }
        return id
    }
}

struct IconPickerSelectionView: View {
    let selection: IconPickerSelection?
    var size: CGFloat = 18

    var body: some View {
        switch selection ?? .defaultSelection {
        case .phiIcon(let id):
            Image(PhiIconCatalog.canonicalId(for: id) ?? id)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .frame(width: size, height: size)
        case .emoji(_, let text):
            Text(text)
                .font(.system(size: size))
                .frame(width: size, height: size)
        }
    }
}

private enum IconPickerTab: Hashable {
    case icon
    case emoji
}

enum IconPickerSearch {
    static func phiIcons(matching query: String) -> [PhiIconCatalog.Icon] {
        guard let query = preparedQuery(query) else { return PhiIconCatalog.all }
        return PhiIconCatalog.all.filter { icon in
            matches(query, candidates: [icon.name, icon.assetName])
        }
    }

    static func emojiGroups(in catalog: EmojiCatalog,
                            matching query: String) -> [EmojiCatalog.Group] {
        guard let query = preparedQuery(query) else { return catalog.groups }

        return catalog.groups.compactMap { group in
            if matches(query, candidates: [group.name]) {
                return group
            }

            let items = group.items.filter { item in
                matches(query, candidates: emojiKeywords(for: item))
            }
            guard !items.isEmpty else { return nil }
            return EmojiCatalog.Group(name: group.name, items: items)
        }
    }

    static func emojiItems(in catalog: EmojiCatalog,
                           matching query: String) -> [EmojiItem] {
        emojiGroups(in: catalog, matching: query).flatMap(\.items)
    }

    private static func emojiKeywords(for item: EmojiItem) -> [String] {
        [item.text, item.name, item.subgroup]
            + item.skinVariants.flatMap { [$0.text, $0.name] }
    }

    private static func preparedQuery(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func matches(_ query: String, candidates: [String]) -> Bool {
        let normalizedQuery = normalizedWords(in: query)
        return candidates.contains { candidate in
            if candidate.localizedStandardContains(query) {
                return true
            }

            guard !normalizedQuery.isEmpty else { return false }
            return normalizedWords(in: candidate)
                .localizedStandardContains(normalizedQuery)
        }
    }

    private static func normalizedWords(in value: String) -> String {
        value.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private enum IconPickerMetrics {
    static let width: CGFloat = 262
    static let height: CGFloat = 280
    static let topPadding: CGFloat = 8
    static let bottomPadding: CGFloat = 8
    static let segmentWidth: CGFloat = 128
    static let segmentHeight: CGFloat = 26
    static let segmentToSearchSpacing: CGFloat = 8
    static let searchHeight: CGFloat = 24
    static let searchToGridSpacing: CGFloat = 4
    static let gridHeight: CGFloat = 202
    static let gridHorizontalPadding: CGFloat = 8
    static let gridVerticalPadding: CGFloat = 8
    static let itemSize: CGFloat = 26
    static let iconSize: CGFloat = 16
    static let emojiFontSize: CGFloat = 16
    static let skinVariantEmojiFontSize: CGFloat = 16
    static let emojiVerticalOffset: CGFloat = -1
    static let itemCornerRadius: CGFloat = 8
    static let rowSpacing: CGFloat = 4
    static let fixedColumnCount = 8
    static let fixedColumnSpacing: CGFloat = 4
    static var fixedGridContentWidth: CGFloat {
        CGFloat(fixedColumnCount) * itemSize
            + CGFloat(fixedColumnCount - 1) * fixedColumnSpacing
    }
    static let columns = Array(
        repeating: GridItem(.fixed(itemSize), spacing: fixedColumnSpacing),
        count: fixedColumnCount
    )
}

private struct IconPickerSearchField: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))

            if !text.isEmpty {
                Button(action: clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(NSLocalizedString(
                    "Clear search",
                    comment: "Icon picker - Accessibility label for clearing search"
                )))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: IconPickerMetrics.searchHeight)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 999))
    }

    private func clearSearch() {
        text = ""
    }
}

private struct IconPickerGridButton<Content: View>: View {
    let isSelected: Bool
    let help: String
    let action: () -> Void
    let content: () -> Content

    @Environment(\.phiTheme) private var theme
    @Environment(\.phiAppearance) private var appearance
    @State private var isHovering = false

    init(isSelected: Bool,
         help: String,
         action: @escaping () -> Void,
         @ViewBuilder content: @escaping () -> Content) {
        self.isSelected = isSelected
        self.help = help
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) {
            content()
                .frame(width: IconPickerMetrics.itemSize, height: IconPickerMetrics.itemSize)
                .background(background)
                .contentShape(RoundedRectangle(cornerRadius: IconPickerMetrics.itemCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    @ViewBuilder
    private var background: some View {
        let hoverColor = ThemedColor.themeColorOnHover.swiftUIColor(theme: theme, appearance: appearance)
        let accent = ThemedColor.themeColor.swiftUIColor(theme: theme, appearance: appearance)
        let shape = RoundedRectangle(cornerRadius: IconPickerMetrics.itemCornerRadius, style: .continuous)

        shape
            .fill(
                isSelected
                    ? hoverColor.opacity(0.5)
                    : (isHovering ? hoverColor.opacity(0.24) : Color.clear)
            )
            // A crisp accent border marks the selected cell. The low-opacity fill
            // alone vanishes when the picker sits on the Space's themed sidebar
            // backdrop (a same-hue tint); the saturated, full-opacity border keeps
            // a visible edge on any background.
            .overlay {
                shape.strokeBorder(isSelected ? accent : Color.clear, lineWidth: 1.5)
            }
    }
}

private struct EmojiPickerGridButton: View {
    let item: EmojiItem
    let selectedEmojiId: String?
    let onSelect: (IconPickerSelection) -> Void

    @State private var showsSkinPicker = false

    private var isSelected: Bool {
        selectedEmojiId == item.id
            || item.skinVariants.contains(where: { $0.id == selectedEmojiId })
    }

    var body: some View {
        IconPickerGridButton(
            isSelected: isSelected,
            help: item.name,
            action: selectOrShowSkinPicker
        ) {
            Text(item.text)
                .font(.system(size: IconPickerMetrics.emojiFontSize))
                .offset(y: IconPickerMetrics.emojiVerticalOffset)
        }
        .popover(isPresented: $showsSkinPicker, arrowEdge: .top) {
            EmojiSkinVariantPicker(
                item: item,
                selectedEmojiId: selectedEmojiId,
                onSelect: { selection in
                    showsSkinPicker = false
                    onSelect(selection)
                }
            )
        }
    }

    private func selectOrShowSkinPicker() {
        if item.hasSkinVariants {
            showsSkinPicker = true
        } else {
            onSelect(.emoji(id: item.id, text: item.text))
        }
    }
}

private struct EmojiSkinVariantPicker: View {
    let item: EmojiItem
    let selectedEmojiId: String?
    let onSelect: (IconPickerSelection) -> Void

    private var options: [EmojiVariant] {
        [EmojiVariant(id: item.id, text: item.text, name: item.name)] + item.skinVariants
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                IconPickerGridButton(
                    isSelected: selectedEmojiId == option.id,
                    help: option.name,
                    action: { onSelect(.emoji(id: option.id, text: option.text)) }
                ) {
                    Text(option.text)
                        .font(.system(size: IconPickerMetrics.skinVariantEmojiFontSize))
                        .offset(y: IconPickerMetrics.emojiVerticalOffset)
                }
            }
        }
        .padding(10)
    }
}

#Preview("IconPicker") {
    IconPickerPreviewHost()
}

private struct IconPickerPreviewHost: View {
    @State private var selection: IconPickerSelection? = .phiIcon(id: "phi-icon-rss")

    var body: some View {
        IconPicker(
            selected: selection,
            showsGroups: true,
            onSelect: { selection = $0 }
        )
    }
}

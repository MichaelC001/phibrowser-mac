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
    /// When true the picker stretches vertically with its container instead of
    /// the fixed popover height, letting the grid show as many rows as fit —
    /// the Spaces settings pane fills its detail column with the picker.
    let fillsAvailableHeight: Bool
    let onSelect: (IconPickerSelection) -> Void

    private let emojiCatalog: EmojiCatalog

    @State private var selectedTab: IconPickerTab
    @State private var iconSearchText = ""
    @State private var emojiSearchText = ""
    /// The selection last made by clicking a cell inside the picker. Such a
    /// cell is already visible, so the grids skip the reveal-scroll for it
    /// instead of shifting the grid under the cursor.
    @State private var internallyPickedSelection: IconPickerSelection?

    /// Fixed height callers can use to size a container around the picker.
    static let preferredHeight: CGFloat = IconPickerMetrics.height

    init(selected: IconPickerSelection?,
         showsGroups: Bool,
         width: CGFloat? = nil,
         fillsAvailableHeight: Bool = false,
         emojiCatalog: EmojiCatalog = .shared,
         onSelect: @escaping (IconPickerSelection) -> Void) {
        self.selected = selected
        self.showsGroups = showsGroups
        self.width = width
        self.fillsAvailableHeight = fillsAvailableHeight
        self.emojiCatalog = emojiCatalog
        self.onSelect = onSelect
        _selectedTab = State(initialValue: selected?.isEmoji == true ? .emoji : .icon)
    }

    private var resolvedWidth: CGFloat { width ?? IconPickerMetrics.width }

    var body: some View {
        if fillsAvailableHeight {
            pickerBody
                .frame(width: resolvedWidth)
                .frame(maxHeight: .infinity)
        } else {
            pickerBody
                .frame(width: resolvedWidth, height: IconPickerMetrics.height)
        }
    }

    private var pickerBody: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("Icon").tag(IconPickerTab.icon)
                Text("Emoji").tag(IconPickerTab.emoji)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // System accent, not the Space theme: selection chrome in the
            // picker follows the system focus color.
            .tint(Color.accentColor)
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
        // Follow selection changes made from outside (switching Spaces in the
        // settings pane): land on the tab holding the new selection, whose grid
        // then reveals it on appear.
        .onChange(of: selected) { newSelection in
            guard let newSelection else { return }
            selectedTab = newSelection.isEmoji ? .emoji : .icon
        }
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
            NSLocalizedString("common.iconPicker.iconsSearchPlaceholder", value: "Search icons",
                comment: "Icon picker - Search field placeholder for Phi icons"
            )
        case .emoji:
            NSLocalizedString("common.iconPicker.emojiSearchPlaceholder", value: "Search emoji",
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
        ScrollViewReader { proxy in
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
                                    action: {
                                        internallyPickedSelection = .phiIcon(id: icon.assetName)
                                        onSelect(.phiIcon(id: icon.assetName))
                                    }
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
            .frame(height: fillsAvailableHeight ? nil : IconPickerMetrics.gridHeight)
            .onAppear { revealSelection(proxy) }
            .onChange(of: selected) { handleSelectionChange($0, proxy: proxy) }
        }
    }

    private var filteredPhiIcons: [PhiIconCatalog.Icon] {
        IconPickerSearch.phiIcons(matching: activeSearchQuery)
    }

    private var emojiGrid: some View {
        ScrollViewReader { proxy in
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
            .frame(height: fillsAvailableHeight ? nil : IconPickerMetrics.gridHeight)
            .onAppear { revealSelection(proxy) }
            .onChange(of: selected) { handleSelectionChange($0, proxy: proxy) }
        }
    }

    private var filteredEmojiGroups: [EmojiCatalog.Group] {
        IconPickerSearch.emojiGroups(in: emojiCatalog, matching: activeSearchQuery)
    }

    private var filteredEmojiItems: [EmojiItem] {
        IconPickerSearch.emojiItems(in: emojiCatalog, matching: activeSearchQuery)
    }

    private var emptySearchResults: some View {
        Text(NSLocalizedString("common.iconPicker.searchEmptyMessage", value: "No results",
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
                    onSelect: { selection in
                        internallyPickedSelection = selection
                        onSelect(selection)
                    }
                )
            }
        }
    }

    private var selectedEmojiId: String? {
        guard case .emoji(let id, _) = selected else { return nil }
        return id
    }

    /// Reveals a selection change in the active grid unless it came from a
    /// click inside the picker — that cell is already visible, and re-anchoring
    /// would shift the grid under the cursor.
    private func handleSelectionChange(_ newSelection: IconPickerSelection?,
                                       proxy: ScrollViewProxy) {
        let wasInternal = newSelection != nil && newSelection == internallyPickedSelection
        internallyPickedSelection = nil
        guard !wasInternal else { return }
        revealSelection(proxy)
    }

    /// Scrolls the active grid so the current selection sits in the viewport.
    /// Runs when a grid appears and when the selection changes from outside
    /// (switching Spaces in settings). The explicit anchor matters: an
    /// anchorless scrollTo needs the target cell's current position, which the
    /// lazy grid can't provide for cells it hasn't materialized, so off-screen
    /// targets silently no-op.
    ///
    /// The reveal is staged. The grouped emoji grid nests per-group LazyVGrids
    /// inside a LazyVStack, and an emoji id inside a group that was never built
    /// is unknown to the proxy entirely — so the first hop targets the group
    /// (a direct child of the outer lazy stack), which materializes the inner
    /// grid; the later hops then land on the cell itself and correct the offset
    /// once it exists. Icons skip the group hop: the single flat LazyVGrid can
    /// estimate any cell's position from its data.
    private func revealSelection(_ proxy: ScrollViewProxy) {
        guard let targetId = selectionScrollTargetId else { return }
        let groupId = selectionScrollGroupId
        DispatchQueue.main.async {
            if let groupId {
                proxy.scrollTo(groupId, anchor: .top)
            } else {
                proxy.scrollTo(targetId, anchor: .center)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                proxy.scrollTo(targetId, anchor: .center)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    proxy.scrollTo(targetId, anchor: .center)
                }
            }
        }
    }

    /// The grid item id holding the current selection: the phi-icon asset name,
    /// or the base emoji whose cell also represents its selected skin variant.
    /// Nil when nothing is selected or the active search filters it out.
    private var selectionScrollTargetId: String? {
        switch selected {
        case .phiIcon(let id):
            return filteredPhiIcons.first(where: { $0.assetName == id })?.id
        case .emoji(let id, _):
            let items = showsGroups ? filteredEmojiGroups.flatMap(\.items) : filteredEmojiItems
            return items.first(where: { item in
                item.id == id || item.skinVariants.contains(where: { $0.id == id })
            })?.id
        case nil:
            return nil
        }
    }

    /// The id of the emoji group containing the current selection — the first
    /// hop of the staged reveal. Nil for icons and the ungrouped emoji grid,
    /// which are single flat LazyVGrids that need no intermediate hop.
    private var selectionScrollGroupId: String? {
        guard showsGroups, case .emoji(let id, _) = selected else { return nil }
        return filteredEmojiGroups.first(where: { group in
            group.items.contains(where: { item in
                item.id == id || item.skinVariants.contains(where: { $0.id == id })
            })
        })?.id
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
    static let iconSize: CGFloat = 20
    static let emojiFontSize: CGFloat = 14
    static let skinVariantEmojiFontSize: CGFloat = 14
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
                .accessibilityLabel(Text(NSLocalizedString("common.iconPicker.clearSearchButtonAccessibilityLabel", value: "Clear search",
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

    private var background: some View {
        // Neutral rounded chip for the selected cell (no theme-colored fill or
        // ring). Being luminance-based rather than a same-hue tint, it stays
        // visible on the Space's themed sidebar backdrop too.
        RoundedRectangle(cornerRadius: IconPickerMetrics.itemCornerRadius, style: .continuous)
            .fill(
                isSelected
                    ? Color.primary.opacity(0.16)
                    : (isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
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

// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI

enum TabPreviewTargetID: Hashable {
    case tab(String)
    case bookmark(String)
}

enum TabPreviewTarget {
    case tab(Tab)
    case bookmark(Bookmark)

    var logicalID: TabPreviewTargetID {
        switch self {
        case .tab(let tab):
            let identifier = tab.guidInLocalDB.flatMap { $0.isEmpty ? nil : $0 }
                ?? (tab.guid >= 0
                    ? String(tab.guid)
                    : String(describing: ObjectIdentifier(tab)))
            return .tab(identifier)
        case .bookmark(let bookmark):
            return .bookmark(bookmark.guid)
        }
    }
}

struct TabPreviewContent {
    let id: TabPreviewTargetID
    let title: String
    let url: String
    let image: NSImage
    let imageSource: TabPreviewImageSource
}

enum TabPreviewImageSource: Equatable {
    struct PlaceholderIdentity: Equatable {
        let targetID: TabPreviewTargetID
        let title: String
        let url: String
        let faviconData: Data?
    }

    case thumbnail(tabID: Int64)
    case livePlaceholder(tabID: Int64, identity: PlaceholderIdentity)
    case placeholder(PlaceholderIdentity)
}

@MainActor
struct TabPreviewContentResolver {
    typealias ThumbnailProvider = @MainActor (Int64) -> Data?

    private let thumbnailProvider: ThumbnailProvider

    init(thumbnailProvider: @escaping ThumbnailProvider = { tabID in
        ChromiumLauncher.sharedInstance().bridge?.thumbnail(forTab: tabID)
    }) {
        self.thumbnailProvider = thumbnailProvider
    }

    func isEligible(_ target: TabPreviewTarget, in browserState: BrowserState) -> Bool {
        resolvedTarget(for: target, in: browserState) != nil
    }

    func resolve(
        _ target: TabPreviewTarget,
        in browserState: BrowserState,
        reusing cachedContent: TabPreviewContent? = nil
    ) -> TabPreviewContent? {
        guard let resolved = resolvedTarget(for: target, in: browserState) else { return nil }
        let placeholderIdentity = TabPreviewImageSource.PlaceholderIdentity(
            targetID: resolved.id,
            title: resolved.title,
            url: resolved.url,
            faviconData: resolved.faviconData
        )
        let resolvedImage = image(
            liveTab: resolved.liveTab,
            placeholderIdentity: placeholderIdentity,
            cachedContent: cachedContent
        )
        return TabPreviewContent(
            id: resolved.id,
            title: resolved.title.isEmpty ? resolved.url : resolved.title,
            url: resolved.url,
            image: resolvedImage.image,
            imageSource: resolvedImage.source
        )
    }

    func liveTab(for target: TabPreviewTarget, in browserState: BrowserState) -> Tab? {
        switch target {
        case .tab(let tab):
            return liveTab(for: tab, in: browserState)
        case .bookmark(let bookmark):
            return liveTab(for: bookmark, in: browserState)
        }
    }

    private struct ResolvedTarget {
        let id: TabPreviewTargetID
        let liveTab: Tab?
        let title: String
        let url: String
        let faviconData: Data?
    }

    private func resolvedTarget(
        for target: TabPreviewTarget,
        in browserState: BrowserState
    ) -> ResolvedTarget? {
        switch target {
        case .tab(let tab):
            return resolvedTabTarget(tab, in: browserState)
        case .bookmark(let bookmark):
            return resolvedBookmarkTarget(bookmark, in: browserState)
        }
    }

    private func resolvedTabTarget(_ tab: Tab, in browserState: BrowserState) -> ResolvedTarget? {
        let liveTab = liveTab(for: tab, in: browserState)
        if liveTab == nil {
            guard let persistentID = tab.guidInLocalDB, !persistentID.isEmpty,
                  browserState.pinnedTabs.contains(where: {
                      $0 === tab || $0.guidInLocalDB == persistentID
                  }) else {
                return nil
            }
        }
        guard !hasSplitMembership(tab: tab, liveTab: liveTab, in: browserState) else { return nil }
        guard !isForeground(tab: tab, liveTab: liveTab, in: browserState) else { return nil }

        let displayTab = liveTab ?? tab
        let url = displayTab.url ?? displayTab.pinnedUrl ?? tab.url ?? tab.pinnedUrl ?? ""
        let title = displayTab.title.isEmpty ? tab.title : displayTab.title
        return ResolvedTarget(
            id: TabPreviewTarget.tab(tab).logicalID,
            liveTab: liveTab,
            title: title,
            url: url,
            faviconData: displayTab.liveFaviconData
                ?? displayTab.cachedFaviconData
                ?? tab.liveFaviconData
                ?? tab.cachedFaviconData
        )
    }

    private func resolvedBookmarkTarget(
        _ bookmark: Bookmark,
        in browserState: BrowserState
    ) -> ResolvedTarget? {
        guard !bookmark.isFolder,
              !bookmark.isEditing,
              bookmark.secondaryUrl?.isEmpty != false,
              browserState.splitBookmarkBindings[bookmark.guid] == nil else {
            return nil
        }

        let liveTab = liveTab(for: bookmark, in: browserState)
        if let liveTab,
           hasSplitMembership(tab: liveTab, liveTab: liveTab, in: browserState) {
            return nil
        }
        guard !bookmark.isActive,
              !isForeground(tab: liveTab, persistentID: bookmark.guid, in: browserState) else {
            return nil
        }

        let url = liveTab?.url ?? bookmark.url ?? ""
        let liveTitle = liveTab?.title ?? ""
        let title = liveTitle.isEmpty ? bookmark.title : liveTitle
        return ResolvedTarget(
            id: .bookmark(bookmark.guid),
            liveTab: liveTab,
            title: title,
            url: url,
            faviconData: liveTab?.liveFaviconData
                ?? liveTab?.cachedFaviconData
                ?? bookmark.liveFaviconData
                ?? bookmark.cachedFaviconData
        )
    }

    private func liveTab(for tab: Tab, in browserState: BrowserState) -> Tab? {
        if let persistentID = tab.guidInLocalDB, !persistentID.isEmpty,
           let persisted = browserState.tabs.first(where: { $0.guidInLocalDB == persistentID }) {
            return persisted
        }
        if tab.guidInLocalDB?.isEmpty == false {
            return nil
        }
        if tab.guid >= 0,
           let exact = browserState.tabs.first(where: { $0.guid == tab.guid }) {
            return exact
        }
        return nil
    }

    private func liveTab(for bookmark: Bookmark, in browserState: BrowserState) -> Tab? {
        if bookmark.isOpened,
           bookmark.chromiumTabGuid >= 0,
           let exact = browserState.tabs.first(where: {
               $0.guid == bookmark.chromiumTabGuid
                   && $0.guidInLocalDB == bookmark.guid
           }) {
            return exact
        }
        guard bookmark.isOpened else { return nil }
        return browserState.tabs.first(where: { $0.guidInLocalDB == bookmark.guid })
    }

    private func hasSplitMembership(
        tab: Tab,
        liveTab: Tab?,
        in browserState: BrowserState
    ) -> Bool {
        if browserState.splitGroup(forTabId: tab.guid) != nil { return true }
        if let liveTab,
           browserState.splitGroup(forTabId: liveTab.guid) != nil {
            return true
        }
        if browserState.splitMembership(forCellTab: tab) != nil { return true }
        if let liveTab,
           liveTab !== tab,
           browserState.splitMembership(forCellTab: liveTab) != nil {
            return true
        }
        guard tab.isPinned || tab.guidInLocalDB?.isEmpty == false else { return false }
        return tab.splitPartnerGuid?.isEmpty == false
            || browserState.pinnedTabs.contains { candidate in
                guard let tabPersistentID = tab.guidInLocalDB, !tabPersistentID.isEmpty else {
                    return false
                }
                return candidate.splitPartnerGuid == tabPersistentID
            }
    }

    private func isForeground(tab: Tab, liveTab: Tab?, in browserState: BrowserState) -> Bool {
        if tab.isActive || liveTab?.isActive == true { return true }
        guard let focusingTab = browserState.focusingTab else { return false }
        if tab.guid >= 0, focusingTab.guid == tab.guid { return true }
        if let liveTab, focusingTab.guid == liveTab.guid { return true }
        guard let persistentID = tab.guidInLocalDB, !persistentID.isEmpty else { return false }
        return focusingTab.guidInLocalDB == persistentID
    }

    private func isForeground(
        tab: Tab?,
        persistentID: String,
        in browserState: BrowserState
    ) -> Bool {
        if tab?.isActive == true { return true }
        guard let focusingTab = browserState.focusingTab else { return false }
        if let tab, focusingTab.guid == tab.guid { return true }
        return focusingTab.guidInLocalDB == persistentID
    }

    private func thumbnailImage(for tab: Tab) -> NSImage? {
        guard tab.guid >= 0,
              let data = thumbnailProvider(Int64(tab.guid)) else {
            return nil
        }
        return NSImage(data: data)
    }

    private func image(
        liveTab: Tab?,
        placeholderIdentity: TabPreviewImageSource.PlaceholderIdentity,
        cachedContent: TabPreviewContent?
    ) -> (image: NSImage, source: TabPreviewImageSource) {
        guard let liveTab, liveTab.guid >= 0 else {
            let source = TabPreviewImageSource.placeholder(placeholderIdentity)
            if cachedContent?.imageSource == source, let cachedContent {
                return (cachedContent.image, source)
            }
            return (
                placeholderImage(identity: placeholderIdentity),
                source
            )
        }

        let tabID = Int64(liveTab.guid)
        let thumbnailSource = TabPreviewImageSource.thumbnail(tabID: tabID)
        if cachedContent?.imageSource == thumbnailSource, let cachedContent {
            return (cachedContent.image, thumbnailSource)
        }

        if let cachedContent,
           case .livePlaceholder(let cachedTabID, _) = cachedContent.imageSource,
           cachedTabID == tabID {
            let source = TabPreviewImageSource.livePlaceholder(
                tabID: tabID,
                identity: placeholderIdentity
            )
            if cachedContent.imageSource == source {
                return (cachedContent.image, source)
            }
            return (placeholderImage(identity: placeholderIdentity), source)
        }

        if let thumbnail = thumbnailImage(for: liveTab) {
            return (thumbnail, thumbnailSource)
        }
        let source = TabPreviewImageSource.livePlaceholder(
            tabID: tabID,
            identity: placeholderIdentity
        )
        return (placeholderImage(identity: placeholderIdentity), source)
    }

    private func placeholderImage(
        identity: TabPreviewImageSource.PlaceholderIdentity
    ) -> NSImage {
        placeholderImage(
            faviconData: identity.faviconData,
            title: identity.title,
            url: identity.url
        )
    }

    private func placeholderImage(faviconData: Data?, title: String, url: String) -> NSImage {
        let favicon = faviconData.flatMap(NSImage.init(data:))
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
            ?? NSImage()
        let displayTitle = title.isEmpty ? url : title
        return TabDraggingSession.makeTabPlaceholderSnapshot(
            favicon: favicon,
            title: displayTitle,
            needBorder: false
        )
    }
}

@MainActor
final class TabPreviewViewModel: ObservableObject {
    @Published private(set) var content: TabPreviewContent?

    func update(_ content: TabPreviewContent) {
        self.content = content
    }
}

private struct TabPreviewView: View {
    @ObservedObject var viewModel: TabPreviewViewModel

    private enum Metrics {
        static let width: CGFloat = 280
        static let imageHeight: CGFloat = width * 10 / 16
        static let cornerRadius: CGFloat = 12
    }

    var body: some View {
        if let content = viewModel.content {
            VStack(spacing: 0) {
                Image(nsImage: content.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Metrics.width, height: Metrics.imageHeight)
                    .clipped()

                VStack(alignment: .leading, spacing: 4) {
                    Text(content.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(content.url)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(width: Metrics.width)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12))
            }
            .fixedSize()
        }
    }
}

@MainActor
final class TabPreviewController {
    private static let showDelay: TimeInterval = 0.5
    private static let handoffDelay: TimeInterval = 0.15
    private static let handoffFrameAnimationDuration: TimeInterval = 0.18

    private weak var window: NSWindow?
    private let resolver: TabPreviewContentResolver
    private let viewModel = TabPreviewViewModel()
    private lazy var previewView = AnyView(TabPreviewView(viewModel: viewModel))

    init(window: NSWindow) {
        self.window = window
        resolver = TabPreviewContentResolver()
    }

    init(window: NSWindow, resolver: TabPreviewContentResolver) {
        self.window = window
        self.resolver = resolver
    }

    func pointerEntered(
        ownerID: UUID,
        anchorView: NSView,
        target: TabPreviewTarget,
        browserState: BrowserState,
        placement: CustomTooltipPlacement
    ) {
        guard let window,
              anchorView.window === window,
              resolver.isEligible(target, in: browserState) else {
            window?.customTooltipController.dismiss(ownerID: ownerID)
            return
        }
        window.customTooltipController.pointerEntered(
            ownerID: ownerID,
            anchorView: anchorView,
            content: previewView,
            configuration: configuration(placement: placement),
            prepareForPresentation: preparation(
                anchorView: anchorView,
                target: target,
                browserState: browserState,
                reuseCurrentImage: false
            )
        )
    }

    func update(
        ownerID: UUID,
        anchorView: NSView,
        target: TabPreviewTarget,
        browserState: BrowserState,
        placement: CustomTooltipPlacement
    ) {
        guard let window,
              anchorView.window === window,
              resolver.isEligible(target, in: browserState) else {
            dismiss(ownerID: ownerID)
            return
        }
        let tooltipController = window.customTooltipController
        let isActiveOwner = tooltipController.activeOwnerID == ownerID
        if isActiveOwner || tooltipController.pendingOwnerID == ownerID {
            tooltipController.update(
                ownerID: ownerID,
                anchorView: anchorView,
                content: previewView,
                configuration: configuration(placement: placement),
                prepareForPresentation: preparation(
                    anchorView: anchorView,
                    target: target,
                    browserState: browserState,
                    reuseCurrentImage: isActiveOwner
                )
            )
        } else {
            tooltipController.pointerEntered(
                ownerID: ownerID,
                anchorView: anchorView,
                content: previewView,
                configuration: configuration(placement: placement),
                prepareForPresentation: preparation(
                    anchorView: anchorView,
                    target: target,
                    browserState: browserState,
                    reuseCurrentImage: false
                )
            )
        }
    }

    func pointerExited(ownerID: UUID) {
        window?.customTooltipController.pointerExited(ownerID: ownerID)
    }

    func dismiss(ownerID: UUID) {
        window?.customTooltipController.dismiss(ownerID: ownerID)
    }

    private func configuration(placement: CustomTooltipPlacement) -> CustomTooltipConfiguration {
        CustomTooltipConfiguration(
            showDelay: Self.showDelay,
            displayDuration: nil,
            placement: placement,
            handoffDelay: Self.handoffDelay,
            handoffGroup: .tabPreview,
            handoffFrameAnimationDuration: Self.handoffFrameAnimationDuration
        )
    }

    private func preparation(
        anchorView: NSView,
        target: TabPreviewTarget,
        browserState: BrowserState,
        reuseCurrentImage: Bool
    ) -> CustomTooltipPresentationPreparation {
        { [weak self, weak anchorView, weak browserState] in
            guard let self,
                  let window = self.window,
                  anchorView?.window === window,
                  let browserState else {
                return false
            }
            let reusableContent = reuseCurrentImage ? self.viewModel.content : nil
            guard let content = self.resolver.resolve(
                target,
                in: browserState,
                reusing: reusableContent
            ) else {
                return false
            }
            self.viewModel.update(content)
            return true
        }
    }
}

@MainActor
final class TabPreviewRegistration {
    let ownerID = UUID()
    var onEligibilityChanged: ((Bool) -> Void)?

    private weak var anchorView: NSView?
    private weak var browserState: BrowserState?
    private weak var activeController: TabPreviewController?
    private var target: TabPreviewTarget?
    private var targetID: TabPreviewTargetID?
    private var placement: CustomTooltipPlacement = .below
    private var isHovering = false
    private var isDragging = false
    private var targetCancellables = Set<AnyCancellable>()
    private var liveTabCancellables = Set<AnyCancellable>()
    private var hoverStateCancellables = Set<AnyCancellable>()
    private weak var observedLiveTab: Tab?
    private let resolver = TabPreviewContentResolver()

    func configure(
        anchorView: NSView,
        target: TabPreviewTarget,
        browserState: BrowserState,
        placement: CustomTooltipPlacement
    ) {
        let nextTargetID = target.logicalID
        let sameTarget = targetID == nextTargetID
            && self.browserState === browserState
        let sameWindow = self.anchorView?.window === anchorView.window
        let canRebindVisibleSurface = isHovering && sameWindow
        if !sameTarget && !canRebindVisibleSurface {
            dismissImmediately()
        }
        self.anchorView = anchorView
        self.target = target
        targetID = nextTargetID
        self.browserState = browserState
        self.placement = placement
        isDragging = browserState.tabDraggingSession.snapshot.isDragging
        subscribe(to: target)
        if isHovering {
            subscribeToHoveredState(browserState)
        }
        guard updateEligibility() else {
            dismissImmediately()
            return
        }
        if isHovering {
            if sameTarget {
                refreshIfHovering()
            } else {
                present()
            }
        }
    }

    func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        if hovering {
            guard let browserState else { return }
            isDragging = browserState.tabDraggingSession.snapshot.isDragging
            subscribeToResolvedLiveTab()
            subscribeToHoveredState(browserState)
            guard updateEligibility() else {
                dismissImmediately()
                return
            }
            present()
        } else {
            hoverStateCancellables.removeAll()
            isDragging = false
            activeController?.pointerExited(ownerID: ownerID)
        }
    }

    func cancelForInteraction() {
        isHovering = false
        hoverStateCancellables.removeAll()
        isDragging = false
        dismissImmediately()
    }

    func invalidate() {
        isHovering = false
        dismissImmediately()
        targetCancellables.removeAll()
        liveTabCancellables.removeAll()
        hoverStateCancellables.removeAll()
        anchorView = nil
        browserState = nil
        target = nil
        targetID = nil
        observedLiveTab = nil
        isDragging = false
        onEligibilityChanged?(false)
    }

    private func present() {
        guard isHovering,
              !isDragging,
              let anchorView,
              let window = anchorView.window,
              let target,
              let browserState else { return }
        let controller = window.tabPreviewController
        if activeController !== controller {
            activeController?.dismiss(ownerID: ownerID)
            activeController = controller
        }
        controller.pointerEntered(
            ownerID: ownerID,
            anchorView: anchorView,
            target: target,
            browserState: browserState,
            placement: placement
        )
    }

    private func refreshIfHovering() {
        guard updateEligibility() else {
            dismissImmediately()
            return
        }
        guard isHovering,
              let anchorView,
              let target,
              let browserState else { return }
        guard let controller = activeController ?? anchorView.window?.tabPreviewController else {
            return
        }
        activeController = controller
        controller.update(
            ownerID: ownerID,
            anchorView: anchorView,
            target: target,
            browserState: browserState,
            placement: placement
        )
    }

    private func dismissImmediately() {
        activeController?.dismiss(ownerID: ownerID)
        activeController = nil
    }

    @discardableResult
    private func updateEligibility() -> Bool {
        guard let target, let browserState else {
            onEligibilityChanged?(false)
            return false
        }
        let isCurrentlyDragging = isDragging
            || browserState.tabDraggingSession.snapshot.isDragging
        let isEligible = !isCurrentlyDragging
            && resolver.isEligible(target, in: browserState)
        onEligibilityChanged?(isEligible)
        return isEligible
    }

    private func subscribeToHoveredState(_ browserState: BrowserState) {
        hoverStateCancellables.removeAll()
        browserState.$focusingTab
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &hoverStateCancellables)
        browserState.$splits
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &hoverStateCancellables)
        browserState.$tabs
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.liveTabSetChanged() }
            .store(in: &hoverStateCancellables)
        browserState.$pinnedTabs
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &hoverStateCancellables)
        browserState.tabDraggingSession.isDraggingPublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isDragging in
                guard let self else { return }
                self.isDragging = isDragging
                if isDragging {
                    self.updateEligibility()
                    self.dismissImmediately()
                } else {
                    self.refreshIfHovering()
                }
            }
            .store(in: &hoverStateCancellables)
    }

    private func subscribe(to target: TabPreviewTarget) {
        targetCancellables.removeAll()
        liveTabCancellables.removeAll()
        observedLiveTab = nil

        switch target {
        case .tab(let tab):
            tab.$title
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshIfHovering() }
                .store(in: &targetCancellables)
            tab.$url
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshIfHovering() }
                .store(in: &targetCancellables)
            tab.$isActive
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshIfHovering() }
                .store(in: &targetCancellables)
            tab.$cachedFaviconData
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshIfHovering() }
                .store(in: &targetCancellables)
            tab.$liveFaviconData
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshIfHovering() }
                .store(in: &targetCancellables)
        case .bookmark(let bookmark):
            bookmark.$title
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshIfHovering() }
                .store(in: &targetCancellables)
            bookmark.$url
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshIfHovering() }
                .store(in: &targetCancellables)
            bookmark.$isActive
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshIfHovering() }
                .store(in: &targetCancellables)
            bookmark.$isOpened
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.liveTabBindingChanged() }
                .store(in: &targetCancellables)
            bookmark.$secondaryUrl
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshIfHovering() }
                .store(in: &targetCancellables)
            bookmark.$isEditing
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshIfHovering() }
                .store(in: &targetCancellables)
            bookmark.$cachedFaviconData
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshIfHovering() }
                .store(in: &targetCancellables)
            bookmark.$liveFaviconData
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshIfHovering() }
                .store(in: &targetCancellables)
        }

        subscribeToResolvedLiveTab()
    }

    private func liveTabSetChanged() {
        subscribeToResolvedLiveTab()
        refreshIfHovering()
    }

    private func liveTabBindingChanged() {
        subscribeToResolvedLiveTab()
        refreshIfHovering()
    }

    private func subscribeToResolvedLiveTab() {
        guard let target, let browserState else {
            liveTabCancellables.removeAll()
            observedLiveTab = nil
            return
        }
        let nextLiveTab = resolver.liveTab(for: target, in: browserState)
        if let observedLiveTab, observedLiveTab === nextLiveTab {
            return
        }
        if observedLiveTab == nil,
           nextLiveTab == nil,
           liveTabCancellables.isEmpty {
            return
        }

        liveTabCancellables.removeAll()
        observedLiveTab = nextLiveTab
        guard let nextLiveTab else { return }
        if case .tab(let targetTab) = target, targetTab === nextLiveTab {
            return
        }

        nextLiveTab.$title
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &liveTabCancellables)
        nextLiveTab.$url
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &liveTabCancellables)
        nextLiveTab.$isActive
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &liveTabCancellables)
        nextLiveTab.$cachedFaviconData
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &liveTabCancellables)
        nextLiveTab.$liveFaviconData
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshIfHovering() }
            .store(in: &liveTabCancellables)
    }
}

@MainActor
protocol TabPreviewInteractionCancelling: AnyObject {
    func cancelTabPreviewForInteraction()
}

private var tabPreviewControllerKey: UInt8 = 0

@MainActor
extension NSWindow {
    var tabPreviewController: TabPreviewController {
        if let controller = objc_getAssociatedObject(
            self,
            &tabPreviewControllerKey
        ) as? TabPreviewController {
            return controller
        }

        let controller = TabPreviewController(window: self)
        objc_setAssociatedObject(
            self,
            &tabPreviewControllerKey,
            controller,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return controller
    }
}

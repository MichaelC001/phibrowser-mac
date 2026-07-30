// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit

/// Container view for the active WebContent area that also accepts a tab drag
/// dropped on its left or right third to start a new vertical split:
///
/// - Left third  → dragged tab becomes the **left** (primary) pane, focused
///                 tab becomes the right (secondary) pane.
/// - Right third → dragged tab becomes the **right** (secondary) pane,
///                 focused tab becomes the left (primary) pane.
///
/// The drop is only accepted when:
/// - the drag comes from the same window (cross-window drops fall through to
///   the existing new-window tear-off flow);
/// - the focused tab exists and is not the dragged tab;
/// - the focused tab is not already part of a split (per user requirement —
///   "When you drag a tab to a splitview page, remain the old logic");
/// - the cursor sits in the left third or right third of the container.
///
/// Visual hint: while a valid drag is hovering anywhere over the page area
/// (including the dead middle band), both "Add Left Split" / "Add Right
/// Split" hint cards are shown with a dashed border so the user can see
/// both potential targets at once. The middle band itself is a no-drop
/// area — drops only land in the left/right thirds.
///
/// Mouse events are not affected: `contentContainer` does not override
/// `hitTest`, so children (the Chromium native view) continue to receive
/// clicks as before.
final class SplitTabDropContainer: NSView {

    /// Fraction of the container's width that counts as a "drop here to
    /// split" zone, measured from each side edge.
    private static let edgeDropZoneFraction: CGFloat = 1.0 / 3.0

    /// Insets the visible drop hint inwards from the zone rectangle so it
    /// reads as a card rather than a hard fill that runs into the rounded
    /// page background. Fractional so the card scales with window size —
    /// fixed-pt insets shrink the relative padding on a wide window, and
    /// the Figma's cards keep a consistent ~10/9% breathing room.
    private static let dropHintHorizontalInsetFraction: CGFloat = 0.10
    private static let dropHintVerticalInsetFraction: CGFloat = 0.09
    /// Floor so the padding doesn't collapse on a narrow window.
    private static let dropHintHorizontalInsetMinimum: CGFloat = 24
    private static let dropHintVerticalInsetMinimum: CGFloat = 24
    private static let dropHintCornerRadius: CGFloat = 32
    private static let dropHintLineWidth: CGFloat = 2
    private static let dropHintLineDashPattern: [NSNumber] = [8, 6]
    /// Overall opacity of the frosted-glass card. Kept at 1.0 so the
    /// material's own translucency carries the see-through effect —
    /// `NSGlassEffectView` and `.fullScreenUI` already let page content
    /// bleed through; dropping `alphaValue` further makes the card read
    /// as thin film rather than a solid glass panel.
    private static let dropHintGlassOpacity: CGFloat = 1.0

    /// Supplies the actual web-page area (in this view's coordinate space)
    /// so the highlight and trigger zones avoid covering the URL bar and
    /// bookmark bar above it. Returns nil if no page is currently mounted,
    /// in which case the full bounds are used as a fallback.
    var pageAreaProvider: (() -> CGRect?)?

    enum DropZone {
        case left
        case right

        var labelText: String {
            switch self {
            case .left:  return NSLocalizedString("browser.splitDropHint.leftThird", value: "Add Left Split", comment: "Drop-zone hint shown when dragging a tab over the left third of the page")
            case .right: return NSLocalizedString("browser.splitDropHint.rightThird", value: "Add Right Split", comment: "Drop-zone hint shown when dragging a tab over the right third of the page")
            }
        }
    }

    /// What a drop will do, decided by whether the focused tab is a split.
    /// `create` (focused tab not a split): the existing left/right-thirds flow
    /// that forms a new vertical split. `replace` (focused tab is a split):
    /// per-pane drop zones that swap the dragged tab into one pane; the
    /// evicted pane moves right next to the split (joining its tab group),
    /// or closes if it was an empty new-tab page.
    private enum Mode: Equatable {
        case create
        case replace(splitId: String)
    }

    weak var browserState: BrowserState?

    private let leftGlassView: NSView = SplitTabDropContainer.makeGlassView()
    private let rightGlassView: NSView = SplitTabDropContainer.makeGlassView()
    private let leftGlassHighlight = SplitTabDropContainer.makeHighlightGradient()
    private let rightGlassHighlight = SplitTabDropContainer.makeHighlightGradient()
    private let leftActiveMaskLayer = SplitTabDropContainer.makeActiveMaskLayer()
    private let rightActiveMaskLayer = SplitTabDropContainer.makeActiveMaskLayer()
    private let leftBorderLayer = SplitTabDropContainer.makeBorderLayer()
    private let rightBorderLayer = SplitTabDropContainer.makeBorderLayer()
    private let leftDropLabel = SplitTabDropContainer.makeDropLabel()
    private let rightDropLabel = SplitTabDropContainer.makeDropLabel()

    /// macOS 26+ exposes `NSGlassEffectView` (Apple's Liquid Glass) which
    /// already renders with its own blur, refraction, and edge highlight
    /// — exactly the look we were faking with NSVisualEffectView + white
    /// fill + gradient. On older systems we keep the
    /// ColoredVisualEffectView fallback used by the floating sidebar
    /// (`WebContentContainerViewController+FloatingSidebar.swift:91`) so
    /// the drop hint stays consistent with the rest of the app's chrome.
    private static func makeGlassView() -> NSView {
        let view: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = dropHintCornerRadius
            // `NSGlassEffectView` requires a contentView; an empty layer-
            // backed view is fine since the label and dashed border are
            // siblings of the glass (drawn directly by the container) and
            // the highlight gradient is added to `glass.layer` below.
            let content = NSView()
            content.wantsLayer = true
            glass.contentView = content
            view = glass
        } else {
            let fx = ColoredVisualEffectView()
            fx.backgroundColor = NSColor.white.withAlphaComponent(0.85)
            fx.material = .fullScreenUI
            fx.blendingMode = .withinWindow
            fx.state = .active
            view = fx
        }
        view.alphaValue = dropHintGlassOpacity
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.cornerRadius = dropHintCornerRadius
        view.layer?.masksToBounds = true
        // The Chromium content view is added to the SplitTabDropContainer
        // *after* these subviews, so without an explicit zPosition the
        // freshly-added Chromium view's backing layer (zPosition 0, higher
        // sublayer index) renders on top of the glass card. Sit just under
        // the dashed border (zPosition 10_000) so the layer-tree compositor
        // floats both the card and the stroke above Chromium content.
        view.layer?.zPosition = 9_999
        view.isHidden = true
        return view
    }

    /// Subtle white-to-transparent gradient sublayer that fakes the
    /// top-edge "glass shine" from the Figma. NSVisualEffectView alone
    /// can't render an inner highlight, so we paint one ourselves and
    /// clip it to the card's rounded shape via the glass view's layer.
    /// Gradient unit space: (0,0) bottom-left, (1,1) top-right — so a
    /// `(0.5, 1) → (0.5, 0.5)` axis lights the top half and fades out
    /// to clear by mid-card.
    private static func makeHighlightGradient() -> CAGradientLayer {
        // NSGlassEffectView on macOS 26+ already ships with its own edge
        // shine; on the NSVisualEffectView fallback path this gradient
        // does the "top glass highlight" by itself. Keep the alpha modest
        // so both paths read consistently — the Liquid Glass effect won't
        // be doubled up by a strong overlay.
        let gradient = CAGradientLayer()
        gradient.colors = [
            NSColor.white.withAlphaComponent(0.25).cgColor,
            NSColor.white.withAlphaComponent(0.0).cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0.5, y: 1.0)
        gradient.endPoint = CGPoint(x: 0.5, y: 0.4)
        return gradient
    }

    /// Darkening scrim layered over whichever card the cursor is currently
    /// resolving to as the drop target, so the user can tell the two hint
    /// cards apart at a glance (Figma shows the active card tinted grey
    /// against the sibling's plain glass). A flat black alpha reads
    /// consistently on both the light glass fill and arbitrary page content
    /// behind it, unlike a literal light-grey fill which would wash out in
    /// dark mode — same reasoning as `applyThemeColors`' stroke color.
    ///
    /// A `CAShapeLayer` sibling of the border layer (added to the
    /// container's own layer, not the glass view's) rather than a sublayer
    /// of the glass: `NSGlassEffectView` composites its Liquid Glass content
    /// over its own layer's sublayers on macOS 26+, so anything added there
    /// (like the highlight gradient above) sits invisibly underneath it.
    /// Reuses the border's exact rounded-rect path so the mask's shape never
    /// drifts from the card it covers.
    private static func makeActiveMaskLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = NSColor.black.withAlphaComponent(0.06).cgColor
        layer.strokeColor = nil
        layer.isHidden = true
        // Sits above the glass view (9_999) and below the dashed border
        // (10_000) so the scrim darkens the card without dulling the stroke.
        layer.zPosition = 9_999.5
        return layer
    }

    private static func makeBorderLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.fillColor = nil
        layer.lineWidth = dropHintLineWidth
        layer.lineDashPattern = dropHintLineDashPattern
        layer.lineCap = .round
        layer.isHidden = true
        // Sits above the glass view (zPosition 0) and below the label
        // (zPosition 10_001) so the dashed stroke rides on top of the
        // frosted card without painting over the text.
        layer.zPosition = 10_000
        return layer
    }

    private static func makeDropLabel() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 15, weight: .semibold)
        field.alignment = .center
        field.translatesAutoresizingMaskIntoConstraints = true
        field.isHidden = true
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.isBordered = false
        field.wantsLayer = true
        return field
    }

    /// True while both drop-hint cards are visible (a valid drag is hovering
    /// the page area). Tracked separately from the per-cursor landing zone so
    /// the hints stay visible while the cursor is in the dead middle band.
    private var hintsVisible = false

    /// Mode the currently-visible hint cards were laid out for. Set before
    /// `showHighlights()` on each drag update so the card geometry and labels
    /// match the create/replace decision. Read by `updateDropHintFrames`.
    private var activeMode: Mode = .create

    /// Which hint card, if any, the cursor is currently resolving to as the
    /// drop target — nil while hovering the dead middle band in create mode.
    /// Drives the darkening mask that marks the card that would receive the
    /// drop right now.
    private var activeDropZone: DropZone?

    private var themeObservation: AnyObject?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Order: glass cards (bottom) → dashed border (middle, via
        // zPosition) → labels (top, via zPosition). NSView subview backing
        // layers and direct `addSublayer` calls share the same sublayer
        // list, so zPosition sorts them all together.
        addSubview(leftGlassView)
        addSubview(rightGlassView)
        leftGlassView.layer?.addSublayer(leftGlassHighlight)
        rightGlassView.layer?.addSublayer(rightGlassHighlight)
        layer?.addSublayer(leftActiveMaskLayer)
        layer?.addSublayer(rightActiveMaskLayer)
        layer?.addSublayer(leftBorderLayer)
        layer?.addSublayer(rightBorderLayer)
        addSubview(leftDropLabel)
        addSubview(rightDropLabel)
        leftDropLabel.layer?.zPosition = 10_001
        rightDropLabel.layer?.zPosition = 10_001
        leftDropLabel.stringValue = DropZone.left.labelText
        rightDropLabel.stringValue = DropZone.right.labelText
        registerForDraggedTypes([.normalTab, .pinnedTab, .phiBookmark])
        themeObservation = subscribe { [weak self] _, _ in
            self?.applyThemeColors()
        }
        applyThemeColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        if hintsVisible {
            updateDropHintFrames()
        }
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        evaluate(sender).operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        evaluate(sender).operation
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideHighlights()
    }

    // MARK: - External drag drivers (TabStrip, comfortable layout)
    //
    // The horizontal-tab TabStrip drives drags with raw mouse events instead
    // of an NSDraggingSession, so its drag doesn't flow through the
    // NSDraggingDestination methods above. These hooks let the strip query
    // the split zone for a screen point and show/hide the same highlight UI
    // while the user is dragging a tab.

    /// Returns the split zone the given screen point falls into, or `nil` if
    /// the point is outside the drop area or no drop is allowed right now.
    /// Multi-tab drags are intentionally not split candidates.
    /// In create mode (focused tab not a split) only the left/right thirds
    /// land; in replace mode (focused tab is a split) the whole page splits
    /// into left/right halves over the two panes.
    ///
    /// Note: in create mode, dragging the focused tab onto itself is allowed —
    /// the drop creates a fresh new-tab-page as the partner pane.
    func splitZoneForScreenPoint(_ screenPoint: CGPoint,
                                 draggedTabId: Int,
                                 draggedTabCount: Int = 1) -> DropZone? {
        guard draggedTabCount == 1,
              let mode = resolveMode(draggedTabId: draggedTabId),
              let pointInSelf = pointInSelfForScreenPoint(screenPoint) else { return nil }
        let area = pageAreaProvider?() ?? bounds
        return zone(forPoint: pointInSelf, mode: mode, area: area)
    }

    /// True when a single-tab drag from the same window is hovering anywhere over
    /// the page area and would be a valid split candidate. Used by the
    /// horizontal TabStrip's manual drag flow to keep both hint cards
    /// visible while the cursor is in the dead middle band — the drop
    /// landing decision still uses `splitZoneForScreenPoint`.
    func isSplitDragContextValid(at screenPoint: CGPoint,
                                 draggedTabId: Int,
                                 draggedTabCount: Int = 1) -> Bool {
        guard draggedTabCount == 1,
              resolveMode(draggedTabId: draggedTabId) != nil,
              let pointInSelf = pointInSelfForScreenPoint(screenPoint) else { return false }
        let area = pageAreaProvider?() ?? bounds
        return area.contains(pointInSelf)
    }

    private func pointInSelfForScreenPoint(_ screenPoint: CGPoint) -> CGPoint? {
        guard let window else { return nil }
        let pointInWindow = window.convertPoint(fromScreen: NSPoint(x: screenPoint.x, y: screenPoint.y))
        return convert(pointInWindow, from: nil)
    }

    /// Shows both split-drop hint cards laid out for the drag's mode. Hides
    /// any existing hint if the drag isn't a valid split candidate. `at`
    /// re-resolves the zone under the cursor on every call so the active
    /// card's mask tracks the mouse as it moves between hint cards.
    func showSplitDropHints(draggedTabId: Int, draggedTabCount: Int = 1, at screenPoint: CGPoint? = nil) {
        guard draggedTabCount == 1,
              let mode = resolveMode(draggedTabId: draggedTabId) else {
            hideHighlights()
            return
        }
        activeMode = mode
        applyHintLabels(for: mode)
        showHighlights()
        if let screenPoint {
            setActiveDropZone(splitZoneForScreenPoint(screenPoint, draggedTabId: draggedTabId, draggedTabCount: draggedTabCount))
        }
    }

    /// Hides both split-drop hint cards.
    func hideSplitDropHints() {
        hideHighlights()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let result = evaluate(sender)
        defer { hideHighlights() }
        guard result.operation != [], let zone = result.zone,
              let state = browserState,
              let pasteboardItem = sender.draggingPasteboard.pasteboardItems?.first,
              let source = parseDragSource(pasteboardItem) else { return false }
        commitSplitDrop(state: state, source: source, zone: zone)
        return true
    }

    /// Commits a split drop, choosing create vs replace from the focused tab.
    /// Shared by the NSDraggingDestination path and the TabStrip manual drag
    /// so both entry points behave identically.
    func commitSplitDrop(state: BrowserState, source: DragSource, zone: DropZone) {
        guard let mode = resolveMode(for: source, state: state) else { return }
        switch mode {
        case .create:
            guard let focusedTabId = state.focusingTab?.guid else { return }
            performSplitDrop(state: state,
                             source: source,
                             focusedTabId: focusedTabId,
                             zone: zone)
        case .replace(let splitId):
            performPaneReplace(state: state, source: source, splitId: splitId, zone: zone)
        }
    }

    /// Routes a split *create* drop based on the drag's source kind. Three
    /// paths converge here: a normal tab in the strip, a pinned tab in the
    /// favorites grid, or a (non-split) bookmark. The normal-tab and bookmark
    /// paths produce a split whose two panes are entries in the **normal
    /// opened tab list**; the pinned path keeps the dragged tab pinned and
    /// pins the focused tab next to it so the result is a pinned split.
    private func performSplitDrop(state: BrowserState,
                                  source: DragSource,
                                  focusedTabId: Int,
                                  zone: DropZone) {
        switch source {
        case .normalTab(let tabId):
            // Normalize the focused tab (the split partner) into the opened
            // tab list, otherwise the resulting split would inherit its
            // pinned-ness or bookmark binding — contrary to user intent.
            state.makeTabNormalOpened(tabId: focusedTabId)
            performSplitDropFromNormalTab(state: state,
                                          draggedTabId: tabId,
                                          focusedTabId: focusedTabId,
                                          zone: zone)
        case .pinnedTab(let dbGuid):
            // Pinned source preserves pinned status: the live-pinned subpath
            // pins the focused tab itself rather than unpinning the dragged
            // pane. Normalization is handled inside the helper for the
            // closed-pinned fallback only.
            performSplitDropFromPinned(state: state,
                                       pinnedDBGuid: dbGuid,
                                       focusedTabId: focusedTabId,
                                       zone: zone)
        case .bookmark(let bookmarkGuid):
            // Focused-tab normalization is deferred into the helper so it
            // only runs after the bookmark record+URL guard succeeds —
            // otherwise a bookmark deleted mid-drag or with an empty URL
            // would silently unpin/unbind the focused tab for nothing.
            performSplitDropFromBookmark(state: state,
                                         bookmarkGuid: bookmarkGuid,
                                         focusedTabId: focusedTabId,
                                         zone: zone)
        }
    }

    private func performSplitDropFromNormalTab(state: BrowserState,
                                               draggedTabId: Int,
                                               focusedTabId: Int,
                                               zone: DropZone) {
        if draggedTabId == focusedTabId {
            // Dragged = focused → open a new tab as the partner. The new
            // tab takes the slot opposite the one the user dropped on,
            // since the "dragged" tab visually lands in the dropped slot.
            switch zone {
            case .left:
                state.openNewTabAsSplit(partnerTabId: focusedTabId, newTabSlot: .right)
            case .right:
                state.openNewTabAsSplit(partnerTabId: focusedTabId, newTabSlot: .left)
            }
            return
        }
        switch zone {
        case .left:
            state.createSplit(leftTabId: draggedTabId,
                              rightTabId: focusedTabId,
                              layout: .vertical)
        case .right:
            state.createSplit(leftTabId: focusedTabId,
                              rightTabId: draggedTabId,
                              layout: .vertical)
        }
    }

    private func performSplitDropFromPinned(state: BrowserState,
                                            pinnedDBGuid: String,
                                            focusedTabId: Int,
                                            zone: DropZone) {
        if let liveTab = state.tabs.first(where: { $0.guidInLocalDB == pinnedDBGuid }),
           liveTab.guid != focusedTabId {
            // Live pinned tab distinct from focused. Splits never live in
            // the pinned strip: demote the dragged pinned tab into the
            // normal list (leaving an unopened pinned placeholder at the
            // original slot), normalize the focused partner, and form a
            // normal split. Mirrors the right-click "Open as Split" path
            // so every entry point behaves identically.
            state.demotePinnedTabLeavingPlaceholder(forTabId: liveTab.guid)
            state.makeTabNormalOpened(tabId: focusedTabId)
            switch zone {
            case .left:
                state.createSplit(leftTabId: liveTab.guid,
                                  rightTabId: focusedTabId,
                                  layout: .vertical)
            case .right:
                state.createSplit(leftTabId: focusedTabId,
                                  rightTabId: liveTab.guid,
                                  layout: .vertical)
            }
            return
        }
        // Closed pinned tab (no live representation) or pinned tab whose
        // live representation IS the focused pane: open a fresh tab on the
        // pinned URL as the new pane. The pinned record itself is left
        // intact so the slot still exists for next time. The new partner
        // pane is a normal tab, so normalize the focused tab — but only
        // after the URL guard succeeds, otherwise a pinned record with no
        // saved URL would silently unpin/unbind the focused tab for nothing.
        guard let pinned = state.pinnedTabs.first(where: { $0.guidInLocalDB == pinnedDBGuid }),
              let url = pinned.url, !url.isEmpty else { return }
        state.makeTabNormalOpened(tabId: focusedTabId)
        let newTabSlot: SplitSlot = (zone == .left) ? .left : .right
        state.openNewTabAsSplit(partnerTabId: focusedTabId,
                                newTabSlot: newTabSlot,
                                partnerNavigateURL: URLProcessor.processUserInput(url))
    }

    private func performSplitDropFromBookmark(state: BrowserState,
                                              bookmarkGuid: String,
                                              focusedTabId: Int,
                                              zone: DropZone) {
        // Single shared implementation on BrowserState — same path the
        // bookmark "Open as Split" menu and any future entry point use.
        let newTabSlot: SplitSlot = (zone == .left) ? .left : .right
        state.formSplitFromBookmark(bookmarkGuid: bookmarkGuid,
                                    partnerTabId: focusedTabId,
                                    newTabSlot: newTabSlot)
    }

    // MARK: - Replace a pane (focused tab is a split)

    /// Replaces one pane of the focused split with the dragged item. The
    /// hovered half maps to a slot (left → 0 = primary, right → 1 =
    /// secondary). The evicted pane moves right next to the split, joining
    /// its tab group if any (`swap: true`). Normal tabs swap synchronously;
    /// bookmarks and closed-pinned entries open a fresh tab first and swap
    /// once Chromium echoes it back.
    private func performPaneReplace(state: BrowserState,
                                    source: DragSource,
                                    splitId: String,
                                    zone: DropZone) {
        let slotIndex = (zone == .left) ? 0 : 1
        // Keep the evicted pane as a standalone tab, unless it's an empty
        // new-tab page — then close it (`swap: false`) instead of littering
        // the strip.
        let keepEvicted = state.splitPaneReplacementKeepsEvicted(splitId: splitId, slotIndex: slotIndex)
        switch source {
        case .normalTab(let tabId):
            state.swapTabInSplit(splitId, slotIndex: slotIndex, withTabId: tabId, swap: keepEvicted)
        case .pinnedTab(let dbGuid):
            // Live pinned tab distinct from the split's panes: demote it into
            // the normal list (leaving a pinned placeholder at its slot), then
            // swap it into the pane — splits never live in the pinned strip.
            if let liveTab = state.tabs.first(where: { $0.guidInLocalDB == dbGuid }),
               state.splitGroup(forId: splitId)?.contains(tabId: liveTab.guid) != true {
                state.demotePinnedTabLeavingPlaceholder(forTabId: liveTab.guid)
                state.swapTabInSplit(splitId, slotIndex: slotIndex, withTabId: liveTab.guid, swap: keepEvicted)
                return
            }
            // Closed pinned (no live representation): open a fresh tab on the
            // pinned URL and swap it in once it arrives. The pinned record is
            // left intact so the slot still exists.
            guard let pinned = state.pinnedTabs.first(where: { $0.guidInLocalDB == dbGuid }),
                  let url = pinned.url, !url.isEmpty else { return }
            state.openTabAsPaneReplacement(splitId: splitId,
                                           slotIndex: slotIndex,
                                           url: URLProcessor.processUserInput(url))
        case .bookmark(let bookmarkGuid):
            guard let bookmark = state.bookmarkManager.bookmark(withGuid: bookmarkGuid),
                  !bookmark.isFolder, let url = bookmark.url, !url.isEmpty else { return }
            // Bookmark with an attached live tab (not in any split): detach
            // it into the normal list, then swap it into the pane directly —
            // the user keeps the open page instead of getting a fresh
            // duplicate. Mirrors `formSplitFromBookmark`'s attached-and-
            // distinct path; `makeTabNormalOpened` clears the binding so the
            // bookmark cell stops rendering as opened.
            if let attachedLiveTab = state.tabs.first(where: { $0.guidInLocalDB == bookmarkGuid }),
               state.splitGroup(forTabId: attachedLiveTab.guid) == nil {
                state.makeTabNormalOpened(tabId: attachedLiveTab.guid)
                state.swapTabInSplit(splitId, slotIndex: slotIndex, withTabId: attachedLiveTab.guid, swap: keepEvicted)
                return
            }
            // No live representation (or it's a pane of another split, which
            // matches create mode's fall-through): open a fresh tab on the
            // bookmark URL and swap it in once Chromium echoes it back.
            state.openTabAsPaneReplacement(splitId: splitId,
                                           slotIndex: slotIndex,
                                           url: URLProcessor.processUserInput(url))
        }
    }

    // MARK: - Mode + zone resolution

    /// Decides what a drop will do given the drag's source. Returns nil when
    /// no drop is allowed. `create` when the focused tab is not a split;
    /// `replace` when it is — but only if the split isn't pinned and the
    /// dragged item isn't already a pane of that split.
    private func resolveMode(for source: DragSource, state: BrowserState) -> Mode? {
        guard let focusedTab = state.focusingTab else { return nil }
        guard let group = state.splitGroup(forTabId: focusedTab.guid) else {
            return .create
        }
        // Pinned splits render as one combined cell in the pinned grid and
        // persist as a DB-guid pair (`persistPinnedSplitPair`). Swapping a
        // pane would strand that pair — the evicted tab stays flagged pinned
        // while the incoming one isn't. No drop allowed.
        guard !group.isPinned else { return nil }
        switch source {
        case .normalTab(let tabId):
            if group.contains(tabId: tabId) { return nil }
        case .pinnedTab(let dbGuid):
            if let liveTab = state.tabs.first(where: { $0.guidInLocalDB == dbGuid }),
               group.contains(tabId: liveTab.guid) { return nil }
        case .bookmark(let bookmarkGuid):
            // A bookmark whose attached live tab is already a pane of this
            // split would replace a pane with itself (or its sibling) —
            // same rule as the pinned case above.
            if let liveTab = state.tabs.first(where: { $0.guidInLocalDB == bookmarkGuid }),
               group.contains(tabId: liveTab.guid) { return nil }
        }
        return .replace(splitId: group.id)
    }

    /// Screen-point variant used by the TabStrip manual-drag flow, which only
    /// drags normal tabs. Rejects a dragged tab that is itself a split.
    private func resolveMode(draggedTabId: Int) -> Mode? {
        guard let state = browserState,
              state.splitGroup(forTabId: draggedTabId) == nil else { return nil }
        return resolveMode(for: .normalTab(tabId: draggedTabId), state: state)
    }

    /// Maps a point to a drop zone for the given mode. Create mode lands only
    /// in the left/right thirds (nil in the dead middle band); replace mode
    /// mirrors the split's own panes so each zone covers the pane it replaces
    /// and every point inside the page lands on one of them.
    private func zone(forPoint pointInSelf: CGPoint, mode: Mode, area: CGRect) -> DropZone? {
        guard area.contains(pointInSelf) else { return nil }
        switch mode {
        case .create:
            let rects = zoneRects(mode: mode, area: area)
            if rects.left.contains(pointInSelf) { return .left }
            if rects.right.contains(pointInSelf) { return .right }
            return nil
        case .replace(let splitId):
            return replaceZone(forPoint: pointInSelf, splitId: splitId, area: area)
        }
    }

    /// Left/right zone rectangles for the given mode. Create mode uses fixed
    /// edge thirds; replace mode mirrors the split's pane frames so each card
    /// matches the pane it will replace.
    private func zoneRects(mode: Mode, area: CGRect) -> (left: CGRect, right: CGRect) {
        switch mode {
        case .create:
            let w = area.width * Self.edgeDropZoneFraction
            return (CGRect(x: area.minX, y: area.minY, width: w, height: area.height),
                    CGRect(x: area.maxX - w, y: area.minY, width: w, height: area.height))
        case .replace(let splitId):
            return replacePaneRects(splitId: splitId, area: area)
        }
    }

    /// Pane rectangles mirroring `SplitPaneHostView.layout()` so the replace
    /// hint cards line up with the real panes. `.left` is always the primary
    /// pane (slot 0) — left for a vertical split, top for a horizontal one.
    private func replacePaneRects(splitId: String, area: CGRect) -> (left: CGRect, right: CGRect) {
        let dividerThickness = SplitPaneHostView.dividerThickness
        let paneInset = SplitPaneHostView.paneInset
        let group = browserState?.splitGroup(forId: splitId)
        let ratio = CGFloat(min(max(group?.ratio ?? 0.5, 0), 1))
        let total = area.insetBy(dx: paneInset, dy: paneInset)
        switch group?.layout ?? .vertical {
        case .vertical:
            let primaryWidth = max(0, (total.width - dividerThickness) * ratio)
            let secondaryWidth = max(0, total.width - dividerThickness - primaryWidth)
            return (
                CGRect(x: total.minX, y: total.minY, width: primaryWidth, height: total.height),
                CGRect(x: total.minX + primaryWidth + dividerThickness, y: total.minY, width: secondaryWidth, height: total.height)
            )
        case .horizontal:
            let primaryHeight = max(0, (total.height - dividerThickness) * ratio)
            let secondaryHeight = max(0, total.height - dividerThickness - primaryHeight)
            // y=0 is the bottom in AppKit; primary (slot 0) sits on top.
            return (
                CGRect(x: total.minX, y: total.minY + secondaryHeight + dividerThickness, width: total.width, height: primaryHeight),
                CGRect(x: total.minX, y: total.minY, width: total.width, height: secondaryHeight)
            )
        }
    }

    /// Replace-mode hit test: picks the pane the point sits over, splitting at
    /// the divider midline so the gap resolves to the nearer pane.
    private func replaceZone(forPoint pointInSelf: CGPoint, splitId: String, area: CGRect) -> DropZone {
        let rects = replacePaneRects(splitId: splitId, area: area)
        if browserState?.splitGroup(forId: splitId)?.layout == .horizontal {
            let mid = (rects.right.maxY + rects.left.minY) / 2
            return pointInSelf.y >= mid ? .left : .right
        }
        let mid = (rects.left.maxX + rects.right.minX) / 2
        return pointInSelf.x <= mid ? .left : .right
    }

    // MARK: - Drop validation

    private struct Evaluation {
        let operation: NSDragOperation
        let zone: DropZone?
    }

    private func evaluate(_ sender: NSDraggingInfo) -> Evaluation {
        guard let state = browserState,
              let pasteboardItem = sender.draggingPasteboard.pasteboardItems?.first,
              isSameWindowDrag(pasteboardItem, sender: sender, state: state),
              sender.draggingPasteboard.phiNormalTabIds().count <= 1,
              let source = parseDragSource(pasteboardItem),
              !isSourceASplit(source, state: state),
              let mode = resolveMode(for: source, state: state) else {
            hideHighlights()
            return Evaluation(operation: [], zone: nil)
        }
        let pointInSelf = convert(sender.draggingLocation, from: nil)
        let area = pageAreaProvider?() ?? bounds
        guard area.contains(pointInSelf) else {
            hideHighlights()
            return Evaluation(operation: [], zone: nil)
        }
        // Drag is contextually valid and the cursor is over the page area:
        // show both hint cards so the user can see where they can land.
        activeMode = mode
        applyHintLabels(for: mode)
        showHighlights()
        guard let zone = zone(forPoint: pointInSelf, mode: mode, area: area) else {
            // Create mode, cursor in the dead middle band — hints stay visible
            // but no drop will land here. (Replace mode always returns a zone.)
            setActiveDropZone(nil)
            return Evaluation(operation: [], zone: nil)
        }
        setActiveDropZone(zone)
        return Evaluation(operation: .move, zone: zone)
    }

    /// Kinds of drags the page-workspace split drop accepts. The drag
    /// originates from one of three sidebar sections; each path produces a
    /// split whose two panes are normal opened tabs.
    enum DragSource {
        case normalTab(tabId: Int)
        case pinnedTab(dbGuid: String)
        case bookmark(guid: String)
    }

    /// Classifies the pasteboard item by drag source. Pinned drags carry
    /// both `.pinnedTab` and `.normalTab`; check `.pinnedTab` first so the
    /// pinned-aware path runs.
    private func parseDragSource(_ pasteboardItem: NSPasteboardItem) -> DragSource? {
        if let dbGuid = pasteboardItem.string(forType: .pinnedTab), !dbGuid.isEmpty {
            return .pinnedTab(dbGuid: dbGuid)
        }
        if let bookmarkGuid = pasteboardItem.string(forType: .phiBookmark), !bookmarkGuid.isEmpty {
            return .bookmark(guid: bookmarkGuid)
        }
        if let tabIdString = pasteboardItem.string(forType: .normalTab),
           let tabId = Int(tabIdString) {
            return .normalTab(tabId: tabId)
        }
        return nil
    }

    /// True when the drag source itself represents a split — those drops are
    /// rejected outright so the page workspace doesn't try to nest a split
    /// inside a split. Detects live splits via `splitGroup`, persisted pinned
    /// splits via `Tab.splitPartnerGuid` (covers the closed-pinned-split case
    /// where the pinned leftTab carries `guid == -1` and the live lookup
    /// misses), and split-view bookmarks via `secondaryUrl`. Folder bookmarks
    /// are also rejected — they can't be a split pane.
    private func isSourceASplit(_ source: DragSource, state: BrowserState) -> Bool {
        switch source {
        case .normalTab(let tabId):
            return state.splitGroup(forTabId: tabId) != nil
        case .pinnedTab(let dbGuid):
            if let liveTab = state.tabs.first(where: { $0.guidInLocalDB == dbGuid }),
               state.splitGroup(forTabId: liveTab.guid) != nil {
                return true
            }
            if let pinned = state.pinnedTabs.first(where: { $0.guidInLocalDB == dbGuid }),
               let partner = pinned.splitPartnerGuid, !partner.isEmpty {
                return true
            }
            return false
        case .bookmark(let bookmarkGuid):
            guard let bookmark = state.bookmarkManager.bookmark(withGuid: bookmarkGuid) else {
                return true
            }
            if bookmark.isFolder { return true }
            if let secondary = bookmark.secondaryUrl, !secondary.isEmpty { return true }
            return false
        }
    }

    private func isSameWindowDrag(_ pasteboardItem: NSPasteboardItem,
                                  sender: NSDraggingInfo,
                                  state: BrowserState) -> Bool {
        guard let sourceIdString = pasteboardItem.string(forType: .sourceWindowId),
              let sourceId = Int(sourceIdString),
              sourceId == state.windowId else { return false }
        // Belt-and-braces: a pasteboard-only check trusts the source view to
        // have stamped the right windowId. Cross-check that `draggingSource`
        // is owned by this window so a forged pasteboard from a sibling
        // window can't masquerade as same-window. Non-NSView sources
        // (external drags) wouldn't have set `sourceWindowId` anyway and are
        // already rejected by the check above.
        if let sourceView = sender.draggingSource as? NSView,
           sourceView.window !== self.window {
            return false
        }
        return true
    }

    // MARK: - Visual feedback

    private func applyThemeColors() {
        // Glass tint is owned by `NSVisualEffectView`'s material. Only the
        // dashed stroke and label text are painted by us. `tertiaryLabelColor`
        // adapts to light/dark and stays visible over arbitrary page content
        // — the theme's `border` color is tuned for chrome separators and
        // fades to invisible against a busy web page.
        let stroke = NSColor.tertiaryLabelColor
        let text = ThemedColor.textPrimary.resolve(in: self)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leftBorderLayer.strokeColor = stroke.cgColor
        rightBorderLayer.strokeColor = stroke.cgColor
        CATransaction.commit()
        leftDropLabel.textColor = text
        rightDropLabel.textColor = text
    }

    private func showHighlights() {
        if !hintsVisible {
            hintsVisible = true
            updateDropHintFrames()
        }
        // Suppress implicit fade so the cards snap on rather than fade in.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leftBorderLayer.isHidden = false
        rightBorderLayer.isHidden = false
        CATransaction.commit()
        leftGlassView.isHidden = false
        rightGlassView.isHidden = false
        leftDropLabel.isHidden = false
        rightDropLabel.isHidden = false
    }

    private func hideHighlights() {
        hintsVisible = false
        setActiveDropZone(nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leftBorderLayer.isHidden = true
        rightBorderLayer.isHidden = true
        CATransaction.commit()
        leftGlassView.isHidden = true
        rightGlassView.isHidden = true
        leftDropLabel.isHidden = true
        rightDropLabel.isHidden = true
    }

    /// Updates which hint card shows the active-target mask. No-ops when the
    /// zone hasn't changed so drag updates (which fire on every mouse move)
    /// don't churn the layer tree.
    private func setActiveDropZone(_ zone: DropZone?) {
        guard zone != activeDropZone else { return }
        activeDropZone = zone
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        leftActiveMaskLayer.isHidden = zone != .left
        rightActiveMaskLayer.isHidden = zone != .right
        CATransaction.commit()
    }

    private func applyHintLabels(for mode: Mode) {
        leftDropLabel.stringValue = labelText(for: .left, mode: mode)
        rightDropLabel.stringValue = labelText(for: .right, mode: mode)
    }

    private func labelText(for zone: DropZone, mode: Mode) -> String {
        switch mode {
        case .create:
            return zone.labelText
        case .replace(let splitId):
            // `.left` is always the primary pane (slot 0) — left for a
            // vertical split, top for a horizontal one — so the wording has
            // to follow the layout.
            let layout = browserState?.splitGroup(forId: splitId)?.layout ?? .vertical
            switch (layout, zone) {
            case (.vertical, .left):    return NSLocalizedString("browser.splitDropHint.leftHalf", value: "Replace Left", comment: "Drop-zone hint shown when dragging a tab over the left/primary pane of a vertical split to replace it")
            case (.vertical, .right):   return NSLocalizedString("browser.splitDropHint.rightHalf", value: "Replace Right", comment: "Drop-zone hint shown when dragging a tab over the right/secondary pane of a vertical split to replace it")
            case (.horizontal, .left):  return NSLocalizedString("browser.splitDropHint.top", value: "Replace Top", comment: "Drop-zone hint shown when dragging a tab over the top/primary pane of a horizontal split to replace it")
            case (.horizontal, .right): return NSLocalizedString("browser.splitDropHint.bottom", value: "Replace Bottom", comment: "Drop-zone hint shown when dragging a tab over the bottom/secondary pane of a horizontal split to replace it")
            }
        }
    }

    private func updateDropHintFrames() {
        let area = pageAreaProvider?() ?? bounds
        // Create mode shows narrow edge cards in the left/right thirds; replace
        // mode sizes each card to the actual split pane it sits over.
        let rects = zoneRects(mode: activeMode, area: area)
        updateDropHintFrame(
            glass: leftGlassView,
            highlight: leftGlassHighlight,
            mask: leftActiveMaskLayer,
            border: leftBorderLayer,
            label: leftDropLabel,
            zoneRect: rects.left
        )
        updateDropHintFrame(
            glass: rightGlassView,
            highlight: rightGlassHighlight,
            mask: rightActiveMaskLayer,
            border: rightBorderLayer,
            label: rightDropLabel,
            zoneRect: rects.right
        )
    }

    /// Corner radius the hint card should draw for the given mode. Create-mode
    /// cards float inside the page with their own rounded look; replace-mode
    /// cards cover a pane edge-to-edge, so they must trace the pane's own
    /// radius (`SplitPaneHostView`'s pane container) instead of bulging past
    /// its rounded corners.
    private func hintCornerRadius(for mode: Mode) -> CGFloat {
        switch mode {
        case .create:
            return Self.dropHintCornerRadius
        case .replace:
            return LiquidGlassCompatible.webContentInnerComponentsCornerRadius
        }
    }

    /// Applies the corner radius to both the backing layer and, on macOS 26+,
    /// the `NSGlassEffectView`'s own `cornerRadius` (which clips the Liquid
    /// Glass material independently of the layer).
    private func applyHintCornerRadius(_ radius: CGFloat, to glass: NSView) {
        if #available(macOS 26.0, *), let glassEffect = glass as? NSGlassEffectView {
            glassEffect.cornerRadius = radius
        }
        glass.layer?.cornerRadius = radius
    }

    private func updateDropHintFrame(glass: NSView,
                                     highlight: CAGradientLayer,
                                     mask: CAShapeLayer,
                                     border: CAShapeLayer,
                                     label: NSTextField,
                                     zoneRect: NSRect) {
        let horizontalInset: CGFloat
        let verticalInset: CGFloat
        switch activeMode {
        case .create:
            // Narrow edge cards float inside the left/right thirds.
            horizontalInset = max(Self.dropHintHorizontalInsetMinimum,
                                  zoneRect.width * Self.dropHintHorizontalInsetFraction)
            verticalInset = max(Self.dropHintVerticalInsetMinimum,
                                zoneRect.height * Self.dropHintVerticalInsetFraction)
        case .replace:
            // The zone rect already mirrors the real pane frame
            // (`replacePaneRects`); cover it edge-to-edge so the card reads
            // as "this pane gets replaced", not a smaller floating card.
            horizontalInset = 0
            verticalInset = 0
        }
        let hintRect = NSRect(
            x: zoneRect.minX + horizontalInset,
            y: zoneRect.minY + verticalInset,
            width: max(0, zoneRect.width - horizontalInset * 2),
            height: max(0, zoneRect.height - verticalInset * 2)
        )
        let cornerRadius = hintCornerRadius(for: activeMode)
        glass.frame = hintRect
        applyHintCornerRadius(cornerRadius, to: glass)
        let path = CGPath(
            roundedRect: hintRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Highlight is a sublayer of the glass view's layer, so its frame
        // lives in the glass view's local coordinate space (origin (0,0),
        // size = hintRect.size). Disable implicit animations so it snaps
        // with the glass frame rather than tweening.
        highlight.frame = CGRect(origin: .zero, size: hintRect.size)
        // Mask is a sibling of border on the container's own layer (see
        // `makeActiveMaskLayer`), so it shares the border's absolute path
        // rather than a glass-local frame.
        mask.path = path
        border.path = path
        CATransaction.commit()

        let labelSize = label.intrinsicContentSize
        label.frame = NSRect(
            x: hintRect.midX - labelSize.width / 2,
            y: hintRect.midY - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height
        )
    }
}

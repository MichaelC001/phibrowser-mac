// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SnapKit
import SwiftUI

/// Where the agent console lives on screen — the same choices DevTools
/// offers, picked from the console header's placement menu and persisted
/// across launches.
enum AgentTranscriptPlacement: String, CaseIterable, Identifiable {
    /// Docked as a right sidebar of the frontmost browser window.
    case right
    /// Docked along the bottom of the frontmost browser window.
    case bottom
    /// A regular standalone window.
    case window

    var id: String { rawValue }

    var isDocked: Bool { self == .right || self == .bottom }

    var dockEdge: AgentTranscriptDockEdge? {
        switch self {
        case .right: return .right
        case .bottom: return .bottom
        case .window: return nil
        }
    }

    var title: String {
        switch self {
        case .right:
            return NSLocalizedString(
                "Dock to Right", comment: "Agent console placement - right sidebar")
        case .bottom:
            return NSLocalizedString(
                "Dock to Bottom", comment: "Agent console placement - bottom dock")
        case .window:
            return NSLocalizedString(
                "Separate Window", comment: "Agent console placement - standalone window")
        }
    }

    var symbol: String {
        switch self {
        case .right: return "rectangle.trailinghalf.inset.filled"
        case .bottom: return "rectangle.bottomhalf.inset.filled"
        case .window: return "macwindow"
        }
    }
}

/// Console mirroring the driving code agent's session: the live transcript
/// (actions, narration, rounds, lifecycle) plus a prompt where the user can
/// type commands back to the agent. Like DevTools it can dock to the right
/// or bottom of the browser window, or live in its own window — one console
/// instance re-homed between those placements.
///
/// Opened from View ▸ Agent Transcript, an agent pip's context menu, or
/// automatically at task start while Agent Autoview is enabled.
@MainActor
final class AgentTranscriptPanelController: NSObject {
    static let shared = AgentTranscriptPanelController()

    private static let placementDefaultsKey = "PhiAgentTranscriptPlacement"
    private static let windowAutosaveName = "AgentTranscriptWindow"

    private var window: NSWindow?
    private var dockView: AgentTranscriptDockView?
    private weak var dockHost: WebContentContainerViewController?
    /// Docked placement counts as "shown" even while its host window is
    /// briefly gone (closed, Space swap in flight) — the next browser window
    /// to become key takes the dock back in.
    private var dockActive = false
    /// Set while a placement switch or programmatic teardown closes a
    /// window, so `windowWillClose` doesn't treat the re-host as the user
    /// closing the console.
    private var isRehosting = false
    /// Space of the last slot-visible key window, so a key change can be
    /// told apart as "switched Spaces" vs "same Space refocused" — only a
    /// real switch may steal the feed filter.
    private var lastKeySpaceId: String?

    private let model = AgentTranscriptPanelModel()
    /// One hosting view shared by every placement — moving it between hosts
    /// keeps the feed scroll position and a half-typed prompt across
    /// re-docks.
    private var hostingView: NSHostingView<AgentTranscriptPanelView>?

    private(set) var placement: AgentTranscriptPlacement {
        didSet { model.placement = placement }
    }

    override private init() {
        placement = UserDefaults.standard.string(forKey: Self.placementDefaultsKey)
            .flatMap(AgentTranscriptPlacement.init(rawValue:)) ?? .right
        super.init()
        model.placement = placement
        // A docked console follows the frontmost browser window: a Space
        // switch swaps NSWindows behind one visual "window", so the dock
        // must re-host to keep that illusion intact.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    var isVisible: Bool {
        window?.isVisible == true || (dockActive && dockView?.window != nil)
    }

    func toggle() {
        if isVisible {
            dismiss()
        } else {
            show()
        }
    }

    /// Surfaces the console. `focusTaskId` preselects that task in the feed
    /// filter (the pip context menu passes it). Without one, opening inside
    /// an agent Space focuses that Space's own task; elsewhere the current
    /// filter stays — "all tasks" by default.
    func show(focusTaskId: String? = nil) {
        if let focusTaskId {
            model.taskFilter = focusTaskId
        } else if let taskId = activeSpaceTaskId() {
            model.taskFilter = taskId
        }
        healStaleFilter()
        present()
    }

    /// The live task bound to the Space the user is currently looking at,
    /// or nil when that Space isn't an agent Space.
    private func activeSpaceTaskId() -> String? {
        guard let spaceId = SpaceManager.shared.activeSpaceId else { return nil }
        return AgentSpaceManager.shared.tasksBySpaceId[spaceId]?.taskId
    }

    /// Moves the console to a new home, keeping it up if it was up.
    func setPlacement(_ new: AgentTranscriptPlacement) {
        guard new != placement else { return }
        let wasVisible = isVisible || dockActive
        tearDownPresentation()
        placement = new
        UserDefaults.standard.set(new.rawValue, forKey: Self.placementDefaultsKey)
        if wasVisible { present() }
    }

    func dismiss() {
        tearDownPresentation()
        reapEndedBuffers()
    }

    // MARK: - Presentation

    private func present() {
        switch placement {
        case .window: presentWindow()
        case .right, .bottom: presentDock()
        }
    }

    private func sharedHostingView() -> NSHostingView<AgentTranscriptPanelView> {
        if let hostingView { return hostingView }
        let view = NSHostingView(rootView: AgentTranscriptPanelView(model: model))
        // The browser window is full-size-content, so its title-bar safe area
        // reaches into the docked console's frame and NSHostingView would pad
        // the layout down by it — a blank strip above the header. The console
        // draws its own chrome; opt out of safe-area handling entirely.
        view.safeAreaRegions = []
        hostingView = view
        return view
    }

    private func presentWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = NSLocalizedString(
            "Agent Transcript", comment: "Agent console panel - window title")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 320, height: 300)
        window.contentView = sharedHostingView()
        window.delegate = self
        if !window.setFrameUsingName(Self.windowAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.windowAutosaveName)
        // orderFrontRegardless too: an auto-view show can land while Phi is
        // in the background, where makeKeyAndOrderFront alone leaves the
        // console behind the browser window.
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
    }

    private func presentDock() {
        guard let edge = placement.dockEdge else { return }
        if dockActive, let dockView, dockView.window != nil, dockView.edge == edge { return }
        guard let container = frontmostContainer() else { return }
        let dock = AgentTranscriptDockView(edge: edge, content: sharedHostingView())
        dockHost?.detachTranscriptDock()
        container.attachTranscriptDock(dock, edge: edge)
        dockView = dock
        dockHost = container
        dockActive = true
    }

    private func tearDownPresentation() {
        isRehosting = true
        defer { isRehosting = false }
        if let window {
            window.contentView = NSView()
            window.close()
            self.window = nil
        }
        if dockActive || dockView != nil {
            hostingView?.removeFromSuperview()
            dockHost?.detachTranscriptDock()
            dockHost = nil
            dockView = nil
            dockActive = false
        }
    }

    /// The container of the browser window a dock should live in right now.
    /// Slot `visibleController`s only — NSApp.keyWindow can be the hidden
    /// agent-Space window during task start (Chromium keys it briefly before
    /// the slot pushes it back out), and a dock installed there is invisible.
    private func frontmostContainer() -> WebContentContainerViewController? {
        let controller = SpaceManager.shared.keySlot?.visibleController
            ?? SpaceManager.shared.slots.first?.visibleController
        return controller?.mainSplitViewController.webContentContainerViewController
    }

    /// Reacts to a different browser window coming to the front — a Space
    /// switch swapping windows, or the user moving between two real windows.
    /// The work runs one runloop turn later against SpaceManager state: this
    /// observer can fire BEFORE the slot's own didBecomeKey observer (added
    /// later) has repointed `visibleController`, and acting on the stale
    /// value strands the dock in the window that just went off screen.
    @objc private nonisolated func handleWindowDidBecomeKey(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard (notification.object as? NSWindow)?.windowController
                    is MainBrowserWindowController else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AgentTranscriptPanelController.shared.reconcileFrontWindow()
                }
            }
        }
    }

    /// Aligns the console with the browser window the user is now looking
    /// at: switching INTO an agent Space pulls the feed filter onto the task
    /// that Space is bound to, and an active dock re-homes into the front
    /// window (a Space switch swaps NSWindows behind one visual "window").
    private func reconcileFrontWindow() {
        guard let controller = SpaceManager.shared.keySlot?.visibleController
            ?? SpaceManager.shared.slots.first?.visibleController else { return }

        // Filter refocus only on a real Space change — a re-focus of the
        // same Space must not undo a filter the user picked by hand.
        let spaceChanged = controller.spaceId != lastKeySpaceId
        lastKeySpaceId = controller.spaceId
        if spaceChanged, isVisible,
           let task = AgentSpaceManager.shared.tasksBySpaceId[controller.spaceId] {
            model.taskFilter = task.taskId
        }

        guard dockActive, let edge = placement.dockEdge else { return }
        let container = controller.mainSplitViewController.webContentContainerViewController
        guard container !== dockHost, let dock = dockView else { return }
        dockHost?.detachTranscriptDock()
        container.attachTranscriptDock(dock, edge: edge)
        dockHost = container
    }

    /// Reaps buffers of tasks that already ended — the open console was the
    /// only reason they were retained.
    private func reapEndedBuffers() {
        let live = Set(AgentSpaceManager.shared.tasksBySpaceId.values.map(\.taskId))
        AgentTranscriptStore.shared.clearAll(except: live)
    }

    /// A new task started while the console is up: steal the filter from a
    /// task that is no longer live so the feed keeps showing something real —
    /// never from a live one the user chose to watch. Without this, a filter
    /// left on an ended task blanks the feed while the new task streams
    /// unseen behind it.
    func refocusIfStale(onto taskId: String) {
        guard isVisible, let filter = model.taskFilter, filter != taskId else { return }
        let live = AgentSpaceManager.shared.tasksBySpaceId.values
            .contains { $0.taskId == filter }
        if !live { model.taskFilter = taskId }
    }

    /// Drops a filter pointing at a task with neither a live record nor a
    /// buffer (e.g. reopened after its buffers were reaped) — the all-tasks
    /// feed is always better than a permanently empty one.
    private func healStaleFilter() {
        guard let filter = model.taskFilter else { return }
        let live = AgentSpaceManager.shared.tasksBySpaceId.values
            .contains { $0.taskId == filter }
        let buffered = AgentTranscriptStore.shared.entriesByTaskId[filter] != nil
        if !live && !buffered { model.taskFilter = nil }
    }
}

extension AgentTranscriptPanelController: NSWindowDelegate {
    /// The user closed the console via the title-bar button: drop the
    /// window and reap ended tasks' buffers. Placement switches close the
    /// same windows programmatically but flag `isRehosting` first.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !isRehosting else { return }
            if let closing = notification.object as? NSWindow, closing === window {
                window = nil
            }
            reapEndedBuffers()
        }
    }
}

/// View state that outlives panel open/close: the feed's task filter.
@MainActor
final class AgentTranscriptPanelModel: ObservableObject {
    /// nil = all tasks interleaved; else only this taskId's lines.
    @Published var taskFilter: String?
    /// Mirrors the controller's placement for the header's placement menu.
    @Published var placement: AgentTranscriptPlacement = .right
}

// MARK: - Dock chrome

/// Which browser-window edge a docked console occupies.
enum AgentTranscriptDockEdge {
    case right
    case bottom

    var sizeDefaultsKey: String {
        switch self {
        case .right: return "PhiAgentTranscriptDockWidth"
        case .bottom: return "PhiAgentTranscriptDockHeight"
        }
    }
}

/// Chrome for a docked console: the console wrapped in the same rounded
/// panel geometry as the page area, plus an invisible drag divider on the
/// content-facing edge for resizing. Installed into a browser window by
/// `WebContentContainerViewController.attachTranscriptDock`.
final class AgentTranscriptDockView: NSView {
    let edge: AgentTranscriptDockEdge

    private static let defaultWidth: CGFloat = 360
    private static let defaultHeight: CGFloat = 220
    private static let minWidth: CGFloat = 280
    private static let minHeight: CGFloat = 150
    /// Room a resize must always leave for the page content.
    private static let contentReserve: CGFloat = 400

    private var sizeConstraint: NSLayoutConstraint!
    /// Bottom dock only: the wrapper's leading inset, kept in sync with the
    /// page panel's leading inset so both panels share one left edge. See
    /// `updateLeadingInset`.
    private var wrapperLeadingConstraint: Constraint?

    init(edge: AgentTranscriptDockEdge, content: NSView) {
        self.edge = edge
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Same panel treatment as the page area (rounded corners, inset from
        // the window edge) so the console reads as a sibling panel. The page
        // side needs no inset here — the page panel's own 8pt edge inset
        // provides the gap between the two panels.
        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.cornerCurve = .continuous
        wrapper.layer?.cornerRadius = LiquidGlassCompatible.webContentContainerCornerRadius
        wrapper.layer?.masksToBounds = true
        addSubview(wrapper)
        wrapper.snp.makeConstraints { make in
            make.top.equalToSuperview()
            switch edge {
            case .right:
                make.leading.equalToSuperview()
                make.trailing.bottom.equalToSuperview().inset(WebContentConstant.edgesSpacing)
            case .bottom:
                wrapperLeadingConstraint = make.leading.equalToSuperview()
                    .inset(WebContentConstant.edgesSpacing).constraint
                make.trailing.bottom.equalToSuperview()
                    .inset(WebContentConstant.edgesSpacing)
            }
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(content)
        content.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        let divider = DividerView(edge: edge)
        divider.currentSize = { [weak self] in self?.sizeConstraint.constant ?? 0 }
        divider.onDrag = { [weak self] proposed in
            guard let self else { return }
            self.sizeConstraint.constant = self.clamped(proposed)
        }
        divider.onDragEnded = { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(Double(self.sizeConstraint.constant),
                                      forKey: self.edge.sizeDefaultsKey)
        }
        addSubview(divider)
        divider.snp.makeConstraints { make in
            switch edge {
            case .right:
                make.leading.top.bottom.equalToSuperview()
                make.width.equalTo(6)
            case .bottom:
                make.top.leading.trailing.equalToSuperview()
                make.height.equalTo(6)
            }
        }

        let stored = CGFloat(UserDefaults.standard.double(forKey: edge.sizeDefaultsKey))
        let initial = stored > 0 ? stored
            : (edge == .right ? Self.defaultWidth : Self.defaultHeight)
        sizeConstraint = edge == .right
            ? widthAnchor.constraint(equalToConstant: initial)
            : heightAnchor.constraint(equalToConstant: initial)
        // Below-required so an extreme window shrink compresses the dock
        // instead of raising an unsatisfiable-constraints exception.
        sizeConstraint.priority = NSLayoutConstraint.Priority(999)
        sizeConstraint.isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Aligns a bottom dock's left edge with the page panel, whose leading
    /// inset varies with layout mode and sidebar state. Driven by
    /// `WebContentContainerViewController`, the only layer that knows that
    /// inset. No-op for a right dock (its leading edge faces the page).
    func updateLeadingInset(_ inset: CGFloat) {
        wrapperLeadingConstraint?.update(inset: inset)
    }

    private func clamped(_ proposed: CGFloat) -> CGFloat {
        let minSize = edge == .right ? Self.minWidth : Self.minHeight
        var maxSize = CGFloat.greatestFiniteMagnitude
        if let superview {
            maxSize = (edge == .right ? superview.bounds.width : superview.bounds.height)
                - Self.contentReserve
        }
        return min(max(proposed, minSize), max(minSize, maxSize))
    }

    /// The drag strip along the dock's content-facing edge.
    private final class DividerView: NSView {
        let edge: AgentTranscriptDockEdge
        var onDrag: ((CGFloat) -> Void)?
        var onDragEnded: (() -> Void)?
        var currentSize: (() -> CGFloat)?
        private var dragOrigin: NSPoint = .zero
        private var originalSize: CGFloat = 0

        init(edge: AgentTranscriptDockEdge) {
            self.edge = edge
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: edge == .right ? .resizeLeftRight : .resizeUpDown)
        }

        override func mouseDown(with event: NSEvent) {
            dragOrigin = event.locationInWindow
            originalSize = currentSize?() ?? 0
        }

        override func mouseDragged(with event: NSEvent) {
            let location = event.locationInWindow
            // Right dock widens as the divider moves left; bottom dock grows
            // as it moves up (window coordinates are y-up).
            let delta = edge == .right
                ? dragOrigin.x - location.x
                : location.y - dragOrigin.y
            onDrag?(originalSize + delta)
        }

        override func mouseUp(with event: NSEvent) {
            onDragEnded?()
        }
    }
}

// MARK: - Console view

/// The console: terminal-styled transcript feed + command prompt. The
/// palette follows the system (and per-window) light/dark appearance — a
/// paper-light console in light mode, the terminal-dark one in dark mode.
struct AgentTranscriptPanelView: View {
    @ObservedObject var model: AgentTranscriptPanelModel
    @ObservedObject private var store = AgentTranscriptStore.shared
    @ObservedObject private var manager = AgentSpaceManager.shared

    @State private var draft = ""
    @State private var feedHovered = false
    @FocusState private var promptFocused: Bool

    private enum Palette {
        static let background = adaptive(
            light: NSColor(red: 0.965, green: 0.965, blue: 0.975, alpha: 1),
            dark: NSColor(red: 0.075, green: 0.08, blue: 0.10, alpha: 1))
        static let chrome = adaptive(
            light: NSColor(red: 0.915, green: 0.92, blue: 0.935, alpha: 1),
            dark: NSColor(red: 0.12, green: 0.125, blue: 0.155, alpha: 1))
        static let text = adaptive(
            light: NSColor.black.withAlphaComponent(0.85),
            dark: NSColor.white.withAlphaComponent(0.92))
        static let dim = adaptive(
            light: NSColor.black.withAlphaComponent(0.55),
            dark: NSColor.white.withAlphaComponent(0.55))
        static let faint = adaptive(
            light: NSColor.black.withAlphaComponent(0.32),
            dark: NSColor.white.withAlphaComponent(0.35))
        static let prompt = adaptive(
            light: NSColor(red: 0.05, green: 0.5, blue: 0.24, alpha: 1),
            dark: NSColor(red: 0.42, green: 0.85, blue: 0.55, alpha: 1))
        static let error = adaptive(
            light: NSColor(red: 0.8, green: 0.22, blue: 0.17, alpha: 1),
            dark: NSColor(red: 1.0, green: 0.48, blue: 0.42, alpha: 1))
        /// Transcript content is monospaced; the chrome around it (header,
        /// status pill, hints) uses the UI font so controls read as controls,
        /// not as more console output.
        static let font = Font.system(size: 11.5, design: .monospaced)
        static let fontSmall = Font.system(size: 10, design: .monospaced)
        static let fontUI = Font.system(size: 11)
        static let fontUISmall = Font.system(size: 10)

        /// Appearance-tracking color (`ThemedColor.dynamicColor`) so the
        /// console re-renders when the system or window theme flips.
        private static func adaptive(light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: ThemedColor(light: light, dark: dark).dynamicColor())
        }
    }

    /// Live tasks by taskId, for R-tags, the filter menu, and prompt targeting.
    private var liveTasks: [String: AgentTask] {
        Dictionary(uniqueKeysWithValues:
            manager.tasksBySpaceId.values.map { ($0.taskId, $0) })
    }

    /// Merged feed, filtered then ordered by authored time (append sequence
    /// breaks ties) — so mirrored prose backfilled after the heredoc it
    /// describes still lands in its true chronological place.
    private var entries: [AgentTranscriptEntry] {
        let buffers: [[AgentTranscriptEntry]]
        if let filter = model.taskFilter {
            buffers = [store.entriesByTaskId[filter] ?? []]
        } else {
            buffers = Array(store.entriesByTaskId.values)
        }
        return buffers.flatMap { $0 }.sorted {
            $0.timestamp == $1.timestamp ? $0.seq < $1.seq : $0.timestamp < $1.timestamp
        }
    }

    /// Where a typed command goes: the filtered task if it is live, else the
    /// lowest-numbered live task (the pip order the user already knows).
    private var promptTarget: AgentTask? {
        if let filter = model.taskFilter, let task = liveTasks[filter] {
            return task
        }
        return liveTasks.values.min(by: { $0.number < $1.number })
    }

    private var showTaskTags: Bool { liveTasks.count > 1 && model.taskFilter == nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.faint.opacity(0.4))
            feed
            Divider().overlay(Palette.faint.opacity(0.4))
            promptRow
        }
        .background(Palette.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            // The title is the one element allowed to give way: it truncates
            // (no .fixedSize) so the fixed-size pill and buttons after it can
            // never be squeezed into wrapping.
            Menu {
                Button {
                    model.taskFilter = nil
                } label: {
                    Label(NSLocalizedString(
                        "All tasks", comment: "Agent console - feed filter: every task"),
                          systemImage: "list.bullet")
                }
                ForEach(filterChoices, id: \.taskId) { choice in
                    Button {
                        model.taskFilter = choice.taskId
                    } label: {
                        Label { Text(choice.label) } icon: { badgeIcon(for: choice.taskId) }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    if let filter = model.taskFilter {
                        badgeIcon(for: filter)
                    } else {
                        Image(systemName: "list.bullet")
                    }
                    Text(filterLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                }
                .font(Palette.fontUI.weight(.medium))
                .foregroundStyle(Palette.dim)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)

            Spacer(minLength: 8)

            statusPill

            Button {
                if let filter = model.taskFilter {
                    AgentTranscriptStore.shared.clear(taskId: filter)
                } else {
                    AgentTranscriptStore.shared.clearAll(except: [])
                }
            } label: {
                headerIcon("trash")
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Clear", comment: "Agent console - clear the feed"))

            // DevTools-style placement switcher: dock right/bottom, float,
            // or break out into a separate window.
            Menu {
                Picker("", selection: placementBinding) {
                    ForEach(AgentTranscriptPlacement.allCases) { choice in
                        Label(choice.title, systemImage: choice.symbol).tag(choice)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                headerIcon(model.placement.symbol)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            // Docked chrome has no title bar, so it carries its own close.
            if model.placement.isDocked {
                Button {
                    AgentTranscriptPanelController.shared.dismiss()
                } label: {
                    headerIcon("xmark")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        // Fixed bar height instead of vertical padding: the borderless-button
        // Menu reports a tall ideal height in some states, and padding around
        // it lets the whole bar balloon — the clamp keeps the title row to
        // exactly one line no matter what the controls ask for.
        .frame(height: 32)
        .background(Palette.chrome)
    }

    private func headerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.dim)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }

    /// Compact live/running indicator: a status dot plus the running count,
    /// fixed-size so it can never wrap; the full "N live · N running" phrase
    /// lives in its tooltip.
    @ViewBuilder
    private var statusPill: some View {
        if !liveTasks.isEmpty {
            HStack(spacing: 5) {
                Circle()
                    .fill(runningCount > 0 ? Palette.prompt : Palette.faint)
                    .frame(width: 6, height: 6)
                Text(statusPillLabel)
                    .font(Palette.fontUISmall)
                    .foregroundStyle(Palette.dim)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Palette.faint.opacity(0.12), in: Capsule())
            .fixedSize()
            .help(runningSummary)
        }
    }

    private var statusPillLabel: String {
        guard runningCount > 0 else {
            return NSLocalizedString(
                "idle", comment: "Agent console - status pill when no task is actively running")
        }
        return String(
            format: NSLocalizedString(
                "%d running",
                comment: "Agent console - status pill with the actively running task count"),
            runningCount)
    }

    private var placementBinding: Binding<AgentTranscriptPlacement> {
        Binding(get: { model.placement },
                set: { AgentTranscriptPanelController.shared.setPlacement($0) })
    }

    private struct FilterChoice {
        let taskId: String
        let label: String
    }

    /// One choice per buffered task, labeled by its pip ordinal while live
    /// ("R1 · research-x") and marked ended once its record is gone (its
    /// buffer survives while the panel stays open).
    private var filterChoices: [FilterChoice] {
        store.entriesByTaskId.keys.sorted().map { taskId in
            FilterChoice(taskId: taskId, label: taskLabel(taskId))
        }
    }

    private var filterLabel: String {
        guard let filter = model.taskFilter else {
            return NSLocalizedString(
                "All tasks", comment: "Agent console - feed filter: every task")
        }
        return taskLabel(filter)
    }

    private func taskLabel(_ taskId: String) -> String {
        if let task = liveTasks[taskId] {
            return "\(AgentSpaceManager.agentSpaceName(task.number)) · \(taskId)"
        }
        return taskId + NSLocalizedString(
            " · ended", comment: "Agent console - filter label suffix for a finished task")
    }

    /// The driving-agent badge for a task. Ended tasks (no live record) keep
    /// only their buffer, not their identity, so they fall back to the generic
    /// code-agent glyph.
    private func badge(for taskId: String) -> AgentDriverBadge {
        if let task = liveTasks[taskId] {
            return AgentDriverBadge.make(agentName: task.agentName, origin: task.origin)
        }
        return AgentDriverBadge.make(agentName: "", origin: .cdp)
    }

    /// The driving agent's icon — a bundled brand imageset (template) when the
    /// agent is recognized, else the SF Symbol fallback.
    @ViewBuilder
    private func badgeIcon(for taskId: String) -> some View {
        let b = badge(for: taskId)
        if let asset = b.assetName {
            // Widened for the asset's internal padding (see `assetInkRatio`)
            // so the visible glyph matches a 12pt symbol.
            Image(asset).renderingMode(.template).resizable().scaledToFit()
                .frame(width: 12 / AgentDriverBadge.assetInkRatio,
                       height: 12 / AgentDriverBadge.assetInkRatio)
        } else {
            Image(systemName: b.symbol)
        }
    }

    private var runningCount: Int {
        manager.tasksBySpaceId.values.filter { $0.status == .running }.count
    }

    private var runningSummary: String {
        guard !liveTasks.isEmpty else {
            return NSLocalizedString(
                "no active tasks", comment: "Agent console - footer with no live agent task")
        }
        return String(
            format: NSLocalizedString(
                "%d live · %d running",
                comment: "Agent console - live vs actively running agent task counts"),
            liveTasks.count, runningCount)
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if entries.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 18))
                                .foregroundStyle(Palette.faint)
                            Text(NSLocalizedString(
                                "Nothing yet — agent activity appears here live.",
                                comment: "Agent console - empty feed placeholder"))
                                .font(Palette.fontUISmall)
                                .foregroundStyle(Palette.faint)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    }
                    ForEach(entries) { entry in
                        entryRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(12)
            }
            .onHover { feedHovered = $0 }
            .onChange(of: entries.last?.id) { lastId in
                // Stick to the tail unless the user is reading (pointer in
                // the feed) — then the pill below jumps on demand.
                guard let lastId, !feedHovered else { return }
                proxy.scrollTo(lastId, anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                if feedHovered, let lastId = entries.last?.id {
                    Button {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    } label: {
                        Text(NSLocalizedString(
                            "Jump to latest", comment: "Agent console - scroll to newest line"))
                            .font(Palette.fontUISmall)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Palette.chrome, in: Capsule())
                            .overlay(Capsule().strokeBorder(Palette.faint.opacity(0.3),
                                                            lineWidth: 1))
                            .foregroundStyle(Palette.dim)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: AgentTranscriptEntry) -> some View {
        switch entry.kind {
        case .round:
            HStack(spacing: 6) {
                Rectangle().fill(Palette.faint.opacity(0.4)).frame(height: 1)
                Text(entry.text)
                    .font(Palette.fontUISmall)
                    .foregroundStyle(Palette.faint)
                    .fixedSize()
                Rectangle().fill(Palette.faint.opacity(0.4)).frame(height: 1)
            }
            .padding(.vertical, 4)
        case .user:
            // A user command opens a turn: the tinted block is the visual
            // boundary the eye scans for, so the command itself stays in the
            // plain text color rather than shouting in green too.
            HStack(alignment: .top, spacing: 6) {
                if showTaskTags { taskTag(entry.taskNumber) }
                Text("❯")
                    .font(Palette.font.weight(.bold))
                    .foregroundStyle(Palette.prompt)
                markdownBlock(entry.text, baseColor: Palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Palette.prompt.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.top, 6)
            .textSelection(.enabled)
        case .assistant, .narration:
            // Mirrored conversation — render markdown (headings, bullets,
            // **bold**, `code`) so a structured reply reads like the agent's
            // own transcript instead of a wall of literal markup.
            HStack(alignment: .top, spacing: 6) {
                if showTaskTags { taskTag(entry.taskNumber) }
                markdownBlock(entry.text, baseColor: color(for: entry.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
        case .action, .status, .error:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if showTaskTags { taskTag(entry.taskNumber) }
                if let glyph = glyph(for: entry.kind) {
                    Text(glyph.symbol)
                        .font(Palette.font)
                        .foregroundStyle(glyph.color)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.text)
                        .font(Palette.font)
                        .foregroundStyle(color(for: entry.kind))
                        .fixedSize(horizontal: false, vertical: true)
                    // Detail hangs under its own line inside the column, so
                    // it stays aligned whether or not task tags are shown.
                    if let detail = entry.detail {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("⎿")
                                .font(Palette.fontSmall)
                                .foregroundStyle(Palette.faint)
                            Text(detail)
                                .font(Palette.fontSmall)
                                .foregroundStyle(Palette.faint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    private func taskTag(_ number: Int) -> some View {
        Text(AgentSpaceManager.agentSpaceName(number))
            .font(Palette.fontUISmall.weight(.medium))
            .foregroundStyle(Palette.dim)
            .padding(.horizontal, 4)
            .padding(.vertical, 0.5)
            .background(Palette.faint.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    // MARK: - Markdown

    private enum MDBlock {
        case blank
        case heading(Int, String)
        case bullet(String)
        case numbered(String, String)
        case code(String)
        case paragraph(String)
        /// A GFM table; first row is the header (the separator row that
        /// declared it a table is consumed by the parser, not stored).
        case table([[String]])
    }

    /// Renders a markdown string as a stack of styled lines. Kept monospaced
    /// to match the console, but with block structure (headings, lists, code)
    /// and inline emphasis so a structured reply is scannable.
    @ViewBuilder
    private func markdownBlock(_ text: String, baseColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(parseMarkdown(text).enumerated()), id: \.offset) { _, block in
                blockView(block, baseColor: baseColor)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock, baseColor: Color) -> some View {
        switch block {
        case .blank:
            Color.clear.frame(height: 3)
        case .heading(let level, let text):
            inlineText(text)
                .font(.system(size: level <= 1 ? 13 : 12.5, weight: .bold,
                              design: .monospaced))
                .foregroundStyle(Palette.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        case .bullet(let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•").font(Palette.font).foregroundStyle(Palette.dim)
                inlineText(text).font(Palette.font).foregroundStyle(baseColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .numbered(let marker, let text):
            HStack(alignment: .top, spacing: 6) {
                Text(marker).font(Palette.font).foregroundStyle(Palette.dim)
                inlineText(text).font(Palette.font).foregroundStyle(baseColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let line):
            Text(line)
                .font(Palette.fontSmall)
                .foregroundStyle(Palette.dim)
                .padding(.leading, 8)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            inlineText(text).font(Palette.font).foregroundStyle(baseColor)
                .fixedSize(horizontal: false, vertical: true)
        case .table(let rows):
            tableView(rows, baseColor: baseColor)
        }
    }

    /// A markdown table as a real grid: bold header, hairline under it, cells
    /// wrapping within their columns so a wide table compresses instead of
    /// overflowing the narrow console.
    @ViewBuilder
    private func tableView(_ rows: [[String]], baseColor: Color) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 3) {
            if let header = rows.first {
                GridRow {
                    ForEach(0..<columns, id: \.self) { col in
                        inlineText(col < header.count ? header[col] : "")
                            .font(Palette.font.weight(.semibold))
                            .foregroundStyle(Palette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider().overlay(Palette.faint)
            }
            ForEach(Array(rows.dropFirst().enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { col in
                        inlineText(col < row.count ? row[col] : "")
                            .font(Palette.font)
                            .foregroundStyle(baseColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Inline markdown (bold/italic/`code`/links) → styled Text; bold and
    /// italic runs render even against the monospaced base font. Falls back to
    /// the raw string if it doesn't parse.
    private func inlineText(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(s)
    }

    private func parseMarkdown(_ text: String) -> [MDBlock] {
        var out: [MDBlock] = []
        var inCode = false
        let lines = text.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let raw = lines[index]
            index += 1
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); continue }  // drop fence lines
            if inCode { out.append(.code(raw)); continue }
            if trimmed.isEmpty { out.append(.blank); continue }
            // GFM table: a pipe row whose NEXT line is the |---|---| separator
            // starts one; body rows are the following pipe rows. Without the
            // separator, pipe-bearing lines stay ordinary paragraphs.
            if trimmed.contains("|"), index < lines.count,
               Self.isTableSeparator(lines[index].trimmingCharacters(in: .whitespaces)) {
                var rows = [Self.tableCells(trimmed)]
                index += 1  // consume the separator line
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.contains("|"), !row.isEmpty else { break }
                    rows.append(Self.tableCells(row))
                    index += 1
                }
                out.append(.table(rows))
                continue
            }
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" })
                if hashes.count <= 6,
                   trimmed.dropFirst(hashes.count).first == " " {
                    out.append(.heading(hashes.count,
                        trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            if let r = trimmed.range(of: "^[-*+][ \t]+", options: .regularExpression) {
                out.append(.bullet(String(trimmed[r.upperBound...])))
                continue
            }
            if let r = trimmed.range(of: "^[0-9]+\\.[ \t]+", options: .regularExpression) {
                out.append(.numbered(
                    String(trimmed[trimmed.startIndex..<r.upperBound])
                        .trimmingCharacters(in: .whitespaces),
                    String(trimmed[r.upperBound...])))
                continue
            }
            out.append(.paragraph(raw))
        }
        return out
    }

    /// `| --- | :---: |` and friends — dashes with optional alignment colons,
    /// pipes and spaces, nothing else.
    private static func isTableSeparator(_ s: String) -> Bool {
        guard s.contains("-"), s.contains("|") else { return false }
        return s.range(of: #"^\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?$"#,
                       options: .regularExpression) != nil
    }

    /// Splits a pipe row into trimmed cells, dropping the empty edges a
    /// leading/trailing pipe produces.
    private static func tableCells(_ s: String) -> [String] {
        var cells = s.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    /// Leading glyph of a terse line — accent-colored so the glyph column,
    /// not the text, carries the row's role.
    private func glyph(for kind: AgentTranscriptEntry.Kind) -> (symbol: String, color: Color)? {
        switch kind {
        case .action: return ("⏺", Palette.prompt)
        case .error: return ("✗", Palette.error)
        case .user, .assistant, .narration, .status, .round: return nil
        }
    }

    private func color(for kind: AgentTranscriptEntry.Kind) -> Color {
        switch kind {
        case .action: return Palette.dim
        case .assistant: return Palette.text
        case .narration: return Palette.text
        case .user: return Palette.prompt
        case .status: return Palette.dim
        case .error: return Palette.error
        case .round: return Palette.faint
        }
    }

    private var promptRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("❯")
                    .font(Palette.font.weight(.bold))
                    .foregroundStyle(promptTarget == nil ? Palette.faint : Palette.prompt)
                TextField(promptPlaceholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(Palette.font)
                    .foregroundStyle(Palette.text)
                    .focused($promptFocused)
                    .disabled(promptTarget == nil)
                    .onSubmit(sendDraft)
                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Palette.prompt)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Palette.background,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(promptFocused ? Palette.prompt.opacity(0.5)
                                                : Palette.faint.opacity(0.35),
                                  lineWidth: 1)
            )
            if let target = promptTarget, target.status != .running {
                Text(NSLocalizedString(
                    "agent idle — commands are queued until its next round",
                    comment: "Agent console - hint that a command waits for the next agent round"))
                    .font(Palette.fontUISmall)
                    .foregroundStyle(Palette.faint)
                    .padding(.leading, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Palette.chrome)
    }

    private var promptPlaceholder: String {
        guard let target = promptTarget else {
            return NSLocalizedString(
                "No active agent task", comment: "Agent console - prompt disabled placeholder")
        }
        return String(
            format: NSLocalizedString(
                "Message the agent (→ %@)",
                comment: "Agent console - prompt placeholder naming the target task's Space"),
            AgentSpaceManager.agentSpaceName(target.number))
    }

    private func sendDraft() {
        guard let target = promptTarget else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        AgentSpaceManager.shared.sendUserMessage(taskId: target.taskId, text: text)
        draft = ""
    }
}

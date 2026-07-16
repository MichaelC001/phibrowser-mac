// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Combine
import SwiftUI

/// Floating console mirroring the driving code agent's session: the live
/// transcript (actions, narration, rounds, lifecycle) plus a prompt where the
/// user can type commands back to the agent. Follows the handoff-prompt
/// pattern (single panel instance + dismiss) but titled, resizable, and
/// long-lived — the user opens it deliberately and it stays up across Space
/// switches and task turnover.
///
/// Opened from View ▸ Agent Transcript, an agent pip's context menu, or
/// automatically at task start while Agent Autoview is enabled.
@MainActor
final class AgentTranscriptPanelController: NSObject {
    static let shared = AgentTranscriptPanelController()

    private var panel: NSPanel?
    private let model = AgentTranscriptPanelModel()
    private static let frameAutosaveName = "AgentTranscriptPanel"

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible {
            dismiss()
        } else {
            show()
        }
    }

    /// Surfaces the console. `focusTaskId` preselects that task in the feed
    /// filter (the pip context menu passes it); nil keeps the current filter —
    /// "all tasks" by default.
    func show(focusTaskId: String? = nil) {
        if let focusTaskId {
            model.taskFilter = focusTaskId
        }
        healStaleFilter()
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let hosting = NSHostingView(rootView: AgentTranscriptPanelView(model: model))
        let panel = AgentTranscriptPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = NSLocalizedString(
            "Agent Transcript", comment: "Agent console panel - window title")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentMinSize = NSSize(width: 300, height: 280)
        panel.contentView = hosting
        panel.delegate = self

        // A remembered frame wins; the first open lands bottom-trailing of
        // the browser window the user is looking at — a console's corner,
        // not an alert's dead center.
        if !panel.setFrameUsingName(Self.frameAutosaveName) {
            let slot = SpaceManager.shared.keySlot ?? SpaceManager.shared.slots.first
            let anchor = slot?.visibleController?.window?.frame
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: anchor.maxX - size.width - 16,
                                         y: anchor.minY + 16))
        }
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.close()
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
    /// Covers both `dismiss()` and the title-bar close button: drop the
    /// panel and reap the buffers of tasks that already ended — the open
    /// console was the only reason they were retained.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            panel = nil
            let live = Set(AgentSpaceManager.shared.tasksBySpaceId.values.map(\.taskId))
            AgentTranscriptStore.shared.clearAll(except: live)
        }
    }
}

/// `canBecomeKey` so the command prompt's text field can take focus despite
/// the non-activating utility style.
private final class AgentTranscriptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// View state that outlives panel open/close: the feed's task filter.
@MainActor
final class AgentTranscriptPanelModel: ObservableObject {
    /// nil = all tasks interleaved; else only this taskId's lines.
    @Published var taskFilter: String?
}

// MARK: - Console view

/// The console: terminal-styled transcript feed + command prompt. Rendered
/// dark in both themes on purpose — it mirrors the code agent's own medium,
/// a terminal session.
struct AgentTranscriptPanelView: View {
    @ObservedObject var model: AgentTranscriptPanelModel
    @ObservedObject private var store = AgentTranscriptStore.shared
    @ObservedObject private var manager = AgentSpaceManager.shared

    @State private var draft = ""
    @State private var feedHovered = false
    @FocusState private var promptFocused: Bool

    private enum Palette {
        static let background = Color(red: 0.075, green: 0.08, blue: 0.10)
        static let chrome = Color(red: 0.12, green: 0.125, blue: 0.155)
        static let text = Color.white.opacity(0.92)
        static let dim = Color.white.opacity(0.55)
        static let faint = Color.white.opacity(0.35)
        static let prompt = Color(red: 0.42, green: 0.85, blue: 0.55)
        static let error = Color(red: 1.0, green: 0.48, blue: 0.42)
        static let font = Font.system(size: 11.5, design: .monospaced)
        static let fontSmall = Font.system(size: 10, design: .monospaced)
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
                Label {
                    Text(filterLabel)
                } icon: {
                    if let filter = model.taskFilter {
                        badgeIcon(for: filter)
                    } else {
                        Image(systemName: "list.bullet")
                    }
                }
                .font(Palette.fontSmall)
                .foregroundStyle(Palette.dim)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Text(runningSummary)
                .font(Palette.fontSmall)
                .foregroundStyle(Palette.faint)

            Button(NSLocalizedString("Clear", comment: "Agent console - clear the feed")) {
                if let filter = model.taskFilter {
                    AgentTranscriptStore.shared.clear(taskId: filter)
                } else {
                    AgentTranscriptStore.shared.clearAll(except: [])
                }
            }
            .buttonStyle(.plain)
            .font(Palette.fontSmall)
            .foregroundStyle(Palette.dim)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.chrome)
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

    private var runningSummary: String {
        let running = manager.tasksBySpaceId.values.filter { $0.status == .running }.count
        guard !liveTasks.isEmpty else {
            return NSLocalizedString(
                "no active tasks", comment: "Agent console - footer with no live agent task")
        }
        return String(
            format: NSLocalizedString(
                "%d live · %d running",
                comment: "Agent console - live vs actively running agent task counts"),
            liveTasks.count, running)
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if entries.isEmpty {
                        Text(NSLocalizedString(
                            "Nothing yet — agent activity appears here live.",
                            comment: "Agent console - empty feed placeholder"))
                            .font(Palette.font)
                            .foregroundStyle(Palette.faint)
                            .padding(.top, 12)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(entries) { entry in
                        entryRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(10)
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
                            .font(Palette.fontSmall)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Palette.chrome, in: Capsule())
                            .foregroundStyle(Palette.dim)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    /// Prose kinds carry the mirrored conversation and may hold markdown; the
    /// terse kinds are single plain lines.
    private func isProse(_ kind: AgentTranscriptEntry.Kind) -> Bool {
        kind == .assistant || kind == .narration || kind == .user
    }

    @ViewBuilder
    private func entryRow(_ entry: AgentTranscriptEntry) -> some View {
        if entry.kind == .round {
            HStack(spacing: 6) {
                Rectangle().fill(Palette.faint.opacity(0.4)).frame(height: 1)
                Text(entry.text)
                    .font(Palette.fontSmall)
                    .foregroundStyle(Palette.faint)
                    .fixedSize()
                Rectangle().fill(Palette.faint.opacity(0.4)).frame(height: 1)
            }
            .padding(.vertical, 3)
        } else if isProse(entry.kind) {
            // Mirrored conversation — render markdown (headings, bullets,
            // **bold**, `code`) so a structured reply reads like the agent's
            // own transcript instead of a wall of literal markup.
            HStack(alignment: .top, spacing: 6) {
                if showTaskTags {
                    Text(AgentSpaceManager.agentSpaceName(entry.taskNumber))
                        .font(Palette.fontSmall)
                        .foregroundStyle(Palette.faint)
                }
                if entry.kind == .user {
                    Text("❯").font(Palette.font).foregroundStyle(Palette.prompt)
                }
                markdownBlock(entry.text, baseColor: color(for: entry.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .textSelection(.enabled)
        } else {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if showTaskTags {
                        Text(AgentSpaceManager.agentSpaceName(entry.taskNumber))
                            .font(Palette.fontSmall)
                            .foregroundStyle(Palette.faint)
                    }
                    Text(prefix(for: entry.kind) + entry.text)
                        .font(Palette.font)
                        .foregroundStyle(color(for: entry.kind))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail = entry.detail {
                    Text(detail)
                        .font(Palette.fontSmall)
                        .foregroundStyle(Palette.faint)
                        .padding(.leading, showTaskTags ? 40 : 16)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
        }
    }

    // MARK: - Markdown

    private enum MDBlock {
        case blank
        case heading(Int, String)
        case bullet(String)
        case numbered(String, String)
        case code(String)
        case paragraph(String)
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
        }
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
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCode.toggle(); continue }  // drop fence lines
            if inCode { out.append(.code(raw)); continue }
            if trimmed.isEmpty { out.append(.blank); continue }
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

    private func prefix(for kind: AgentTranscriptEntry.Kind) -> String {
        switch kind {
        case .action: return "⏺ "
        case .user: return "❯ "
        case .error: return "✗ "
        case .assistant, .narration, .status, .round: return ""
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
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("❯")
                    .font(Palette.font)
                    .foregroundStyle(promptTarget == nil ? Palette.faint : Palette.prompt)
                TextField(promptPlaceholder, text: $draft)
                    .textFieldStyle(.plain)
                    .font(Palette.font)
                    .foregroundStyle(Palette.text)
                    .focused($promptFocused)
                    .disabled(promptTarget == nil)
                    .onSubmit(sendDraft)
            }
            if let target = promptTarget, target.status != .running {
                Text(NSLocalizedString(
                    "agent idle — commands are queued until its next round",
                    comment: "Agent console - hint that a command waits for the next agent round"))
                    .font(Palette.fontSmall)
                    .foregroundStyle(Palette.faint)
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

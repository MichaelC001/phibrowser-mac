// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// One line of an agent task's live transcript — the session console a user
/// can open from View ▸ Agent Transcript or an agent pip's context menu.
/// Entries are display-only: the durable session lives with the driver (the
/// code agent's own conversation); this is its mirror in the browser.
struct AgentTranscriptEntry: Identifiable, Equatable {
    enum Kind: String {
        /// Automatic primitive log from the skill ("goto example.com").
        case action
        /// Agent-authored caption (`setStatus` / `narrate`) — the agent
        /// telling the watching user what it is doing.
        case narration
        /// Round separator ("round started" / "round ended").
        case round
        /// Lifecycle: task started/completed, ownership flips.
        case status
        /// `markError` / failed completion.
        case error
        /// A command the user typed into the console — echoed at enqueue
        /// time, delivered to the driver via `agentSpace.readUserMessages`.
        case user
        /// The driving code agent's conversational prose, mirrored from its
        /// session (the Claude Code / Codex reply text), so the console reads
        /// like the agent's own transcript — not just the browser steps.
        case assistant
    }

    let id: UUID
    let timestamp: Date
    /// Global append order, so the merged multi-task feed sorts exactly by
    /// arrival — wall-clock timestamps can collide within a millisecond.
    let seq: Int
    let kind: Kind
    let text: String
    /// Optional dimmed second line (a URL, char count, js preview).
    let detail: String?
    /// The task's pip ordinal at append time, so the merged feed can tag
    /// lines "R1"/"R2" when several tasks are live without re-resolving
    /// tasks that have since completed.
    let taskNumber: Int
}

/// Bounded per-task transcript buffers, separate from `AgentTask` on purpose:
/// the task dict republishes on every cursor move, and a growing array inside
/// it would make each cursor update an O(entries) copy — the same reasoning
/// that keeps `AgentEffect` out of `tasksBySpaceId`. Keyed by taskId, not
/// spaceId: entries arrive taskId-first and must survive a persistent task's
/// Space re-bind.
@MainActor
final class AgentTranscriptStore: ObservableObject {
    static let shared = AgentTranscriptStore()

    /// Ring cap per task: old lines fall off, ids stay stable for SwiftUI
    /// diffing. 500 lines ≈ a long session; the authoritative record is the
    /// driver's own transcript, not this mirror.
    static let maxEntriesPerTask = 500
    /// Terse single-line entries (actions, status, rounds) are capped short;
    /// mirrored conversation (assistant prose, user prompts) keeps its shape
    /// up to a much larger bound so a paragraph isn't guillotined.
    static let maxTerseChars = 300
    static let maxProseChars = 4000
    static let maxDetailChars = 500

    @Published private(set) var entriesByTaskId: [String: [AgentTranscriptEntry]] = [:]

    private var nextSeq = 0

    private init() {}

    /// `timestamp` is when the line was authored — usually now, but a mirrored
    /// session line passes the source event's real time so backfilled prose
    /// (forwarded after the heredoc it describes) still sorts into its true
    /// place in the feed rather than after the actions it introduced.
    func append(taskId: String, kind: AgentTranscriptEntry.Kind,
                text: String, detail: String? = nil, taskNumber: Int,
                timestamp: Date = Date()) {
        nextSeq += 1
        // Conversation lines keep their paragraph shape; terse lines collapse
        // to one line.
        let multiline = kind == .assistant || kind == .user || kind == .narration
        let entry = AgentTranscriptEntry(
            id: UUID(),
            timestamp: timestamp,
            seq: nextSeq,
            kind: kind,
            text: Self.sanitize(text, cap: multiline ? Self.maxProseChars : Self.maxTerseChars,
                                keepBreaks: multiline),
            detail: detail.map { Self.sanitize($0, cap: Self.maxDetailChars, keepBreaks: false) },
            taskNumber: taskNumber)
        var entries = entriesByTaskId[taskId] ?? []
        entries.append(entry)
        if entries.count > Self.maxEntriesPerTask {
            entries.removeFirst(entries.count - Self.maxEntriesPerTask)
        }
        entriesByTaskId[taskId] = entries
    }

    func clear(taskId: String) {
        entriesByTaskId[taskId] = nil
    }

    /// Frees buffers of tasks no longer alive — called when the console
    /// closes, so an open panel can keep showing how a task ended but nothing
    /// outlives the last reader.
    func clearAll(except liveTaskIds: Set<String>) {
        entriesByTaskId = entriesByTaskId.filter { liveTaskIds.contains($0.key) }
    }

    /// Strips control characters (both senders are freeform / LLM-authored)
    /// and caps the length. `keepBreaks` keeps newlines and tabs so mirrored
    /// prose wraps as paragraphs; otherwise everything collapses to one line.
    private static func sanitize(_ text: String, cap: Int, keepBreaks: Bool) -> String {
        var s = String(text.map { ch -> Character in
            if ch == "\n" || ch == "\t" { return keepBreaks ? ch : " " }
            if ch.unicodeScalars.count == 1,
               CharacterSet.controlCharacters.contains(ch.unicodeScalars.first!) {
                return " "
            }
            return ch
        })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > cap {
            s = String(s.prefix(cap)) + "…"
        }
        return s
    }
}

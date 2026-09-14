// Copyright 2026 Phinomenon Inc.
// Use of this source code is governed by an Apache license in the LICENSE file.

import Foundation

/// Trusted packaged Sidecar UI commands, not the external-agent automation API.
/// The bridge proves extension identity, NOT the caller's Profile; the declared
/// profile is checked for consistency only. See docs/sidecar-travel-back.md.
enum TravelBackMessageHandler {
    static let messageTypes = ["sidecar.travelBack.snapshot", "sidecar.travelBack.restore", "sidecar.travelBack.closeSource"]

    struct Request: Decodable {
        let profileId: String
        let windowId: Int
        let boundTabId: Int?
        let snapshot: TravelBackScene?
        let sourceSidebar: TravelBackSidebar?
        let destinationSidebar: TravelBackSidebar?
    }

    @MainActor
    static func handle(_ context: ExtensionMessageContext) async -> String {
        do {
            guard context.senderId == SidecarAIOutputStateStore.extensionId else {
                throw TravelBackFailure.unauthorizedSender
            }
            guard context.payload.utf8.count <= 65536,
                  let data = context.payload.data(using: .utf8),
                  let request = try? JSONDecoder().decode(Request.self, from: data),
                  !request.profileId.isEmpty else { throw TravelBackFailure.invalidSnapshot }
            let manager = MainBrowserWindowControllersManager.shared
            guard let source = manager.getBrowserState(for: request.windowId),
                  source.profileId == request.profileId, source.travelBackAllowed else {
                throw TravelBackFailure.unavailable
            }
            let binding = source.travelBackSource(boundTabId: request.boundTabId)
            switch context.type {
            case "sidecar.travelBack.snapshot":
                return try encode(source.travelBackScene(for: binding.tab))
            case "sidecar.travelBack.closeSource":
                guard let original = request.sourceSidebar,
                      original.windowId == source.windowId,
                      let destination = request.destinationSidebar,
                      let destinationState = manager.getBrowserState(for: destination.windowId),
                      destinationState.profileId == request.profileId,
                      destinationState.travelBackAllowed,
                      destinationState.aiChatTabs.values.contains(where: { $0.guid == destination.chatTabId }) else {
                    throw TravelBackFailure.targetChanged
                }
                try source.closeTravelBackSource(original, destination: destination)
                return "{\"ok\":true,\"result\":{}}"
            case "sidecar.travelBack.restore":
                guard let snapshot = request.snapshot,
                      let page = snapshot.page, page.isReopenable else { throw TravelBackFailure.invalidSnapshot }
                // Validate all recorded layout data before any mutation.
                _ = try snapshot.layout?.splitView?.validated(for: page)
                guard !source.travelBackRunning else { throw TravelBackFailure.busy }
                let candidates = manager.getAllWindows().compactMap(\.browserState).filter {
                    $0.profileId == request.profileId && $0.travelBackAllowed
                }
                let current = request.boundTabId == nil ? nil : binding.tab.map {
                    TravelBackTabRef(tabId: $0.guid, windowId: source.windowId, url: $0.url ?? "")
                }
                let anchorRef = TravelBackTabRef.anchor(for: snapshot, current: current,
                    openTabs: candidates.flatMap { state in
                        state.tabs.map { TravelBackTabRef(tabId: $0.guid, windowId: state.windowId, url: $0.url ?? "") }
                    })
                let target = anchorRef.flatMap { manager.getBrowserState(for: $0.windowId) } ?? source
                let anchor = anchorRef.flatMap { target.resolveTab($0.tabId) }
                guard target === source || !target.travelBackRunning else { throw TravelBackFailure.busy }
                source.travelBackRunning = true
                target.travelBackRunning = true
                defer {
                    source.travelBackRunning = false
                    target.travelBackRunning = false
                }
                let result = try await target.restoreTravelBack(snapshot, anchor: anchor,
                    sourceSidebar: request.boundTabId == nil ? nil : binding.sidebar,
                    deadline: ProcessInfo.processInfo.systemUptime + 8)
                return try encode(result)
            default:
                throw TravelBackFailure.unavailable
            }
        } catch {
            let code = (error as? TravelBackFailure)?.rawValue ?? "unavailable"
            AppLogWarn("[TravelBack] request failed type=\(context.type) code=\(code)")
            return "{\"ok\":false,\"error\":\"\(code)\"}"
        }
    }

    private struct Reply<T: Encodable>: Encodable {
        let ok = true
        let result: T
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(Reply(result: value))
        guard let text = String(data: data, encoding: .utf8) else { throw TravelBackFailure.unavailable }
        return text
    }
}

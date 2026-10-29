// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class NotificationCardManagerTests: XCTestCase {
    private final class TestMessenger: ExtensionMessagingProtocol {
        var responses: [(response: String, requestId: String)] = []
        var errors: [(error: String, requestId: String)] = []
        var broadcasts: [(type: String, payload: String)] = []
        var agentEvents: [(type: String, payload: String, principalId: String)] = []

        func sendResponse(_ response: String, requestId: String) {
            responses.append((response, requestId))
        }

        func sendError(_ error: String, requestId: String) {
            errors.append((error, requestId))
        }

        func broadcast(type: String, payload: String) {
            broadcasts.append((type, payload))
        }

        func broadcastToAgent(type: String, payload: String, principalId: String) {
            agentEvents.append((type, payload, principalId))
        }
    }

    func testDedupesByTaskId() {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 5, now: { 1000 }, messenger: messenger)
        _ = manager.enqueueCard(
            envelope: makeEnvelope(
                taskID: "t1",
                expiresAt: "2000"
            ),
            correlationId: "req-1"
        )
        _ = manager.enqueueCard(
            envelope: makeEnvelope(
                taskID: "t1",
                expiresAt: "3000"
            ),
            correlationId: "req-2"
        )
        XCTAssertEqual(manager.count, 1)
    }

    func testEvictsOldestOnOverflow() {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 1, now: { 1000 }, messenger: messenger)
        _ = manager.enqueueCard(
            envelope: makeEnvelope(taskID: "a", expiresAt: "2000"),
            correlationId: "r1"
        )
        _ = manager.enqueueCard(
            envelope: makeEnvelope(taskID: "b", expiresAt: "3000"),
            correlationId: "r2"
        )
        XCTAssertEqual(manager.count, 1)
        XCTAssertEqual(manager.oldestTaskId, "b")
        XCTAssertTrue(messenger.responses.isEmpty)
        XCTAssertEqual(messenger.broadcasts.count, 1)
        XCTAssertEqual(messenger.broadcasts.first?.type, "notification")
        let broadcastJSON = messenger.broadcasts[0].payload.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let inner = broadcastJSON?["payload"] as? [String: Any]
        XCTAssertEqual(inner?["decision"] as? String, "timeout")
        XCTAssertEqual(inner?["task_id"] as? String, "a")
    }

    func testPreservesCustomButtonTitleFromPayload() {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 5, now: { 1000 }, messenger: messenger)

        _ = manager.enqueueCard(
            envelope: makeEnvelope(
                taskID: "custom-button",
                expiresAt: "2000",
                buttonTitle: "Open Chat"
            ),
            correlationId: "req-1"
        )

        let card = expectation(description: "card published")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.latestCard?.buttonTitle, "Open Chat")
            card.fulfill()
        }
        wait(for: [card], timeout: 1.0)
    }

    func testFallsBackToRunWhenButtonTitleMissingOrEmpty() {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 5, now: { 1000 }, messenger: messenger)

        _ = manager.enqueueCard(
            envelope: makeEnvelope(taskID: "missing-button", expiresAt: "2000"),
            correlationId: "req-1"
        )
        _ = manager.enqueueCard(
            envelope: makeEnvelope(
                taskID: "empty-button",
                expiresAt: "3000",
                buttonTitle: ""
            ),
            correlationId: "req-2"
        )

        let cards = expectation(description: "cards published")
        DispatchQueue.main.async {
            let missingButtonCard = manager.allCards.first { $0.taskId == "missing-button" }
            let emptyButtonCard = manager.allCards.first { $0.taskId == "empty-button" }
            XCTAssertEqual(missingButtonCard?.buttonTitle, "Run")
            XCTAssertEqual(emptyButtonCard?.buttonTitle, "Run")
            cards.fulfill()
        }
        wait(for: [cards], timeout: 1.0)
    }

    func testAgentNotificationRequiresAuthenticatedDirectSession() {
        let manager = NotificationCardManager()
        for context in [
            agentContext(principalId: nil),
            agentContext(principalId: ""),
            agentContext(senderId: "extension"),
        ] {
            XCTAssertEqual(manager.handleAgentRequest(context: context),
                           #"{"ok":false,"error":"agent_session_required"}"#)
        }
        XCTAssertEqual(manager.count, 0)
        XCTAssertEqual(ExtensionMessageRouter.shared.handle(
            type: "notification.show", payload: "{}", requestId: "test", senderId: "cdp"),
            #"{"ok":false,"error":"agent_session_required"}"#)
    }

    func testAgentNotificationRejectsInvalidPayloads() {
        let manager = NotificationCardManager()
        for payload in [
            "not json", "{}",
            #"{"title":" ","message":"Body"}"#,
            #"{"title":"Title","message":""}"#,
            #"{"title":"Title","message":"Body","buttonTitle":1}"#,
            #"{"title":"Title","message":"Body","expiresInSeconds":0}"#,
            #"{"title":"Title","message":"Body","expiresInSeconds":86401}"#,
            #"{"title":"Title","message":"Body","expiresInSeconds":1.5}"#,
        ] {
            XCTAssertEqual(manager.handleAgentRequest(context: agentContext(payload: payload)),
                           #"{"ok":false,"error":"invalid_params"}"#)
        }
        XCTAssertEqual(manager.count, 0)
    }

    func testAgentNotificationAcknowledgesAndRoutesDecisionOnlyToOwner() throws {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(now: { 1000 }, messenger: messenger)
        let reply = manager.handleAgentRequest(context: agentContext(payload:
            #"{"title":"Ready","message":"Review the result","buttonTitle":"Review","expiresInSeconds":60}"#))
        let id = try XCTUnwrap(decode(reply)?["notificationId"] as? String)
        XCTAssertEqual(manager.latestTaskId, id)
        XCTAssertTrue(messenger.agentEvents.isEmpty)

        let published = expectation(description: "agent card published")
        DispatchQueue.main.async {
            guard let card = manager.latestCard else {
                XCTFail("Expected an agent card")
                published.fulfill()
                return
            }
            XCTAssertEqual(card.title, "Ready")
            XCTAssertEqual(card.message, "Review the result")
            XCTAssertEqual(card.buttonTitle, "Review")
            XCTAssertEqual(card.expiresAt, 61_000)
            manager.decide(card: card, decision: .accept)
            manager.decide(card: card, decision: .reject)
            XCTAssertEqual(messenger.agentEvents.count, 1)
            XCTAssertEqual(messenger.agentEvents.first?.principalId, "agent-a")
            XCTAssertEqual(messenger.agentEvents.first?.type, "notification.response")
            XCTAssertEqual(self.decode(messenger.agentEvents[0].payload)?["notificationId"] as? String, id)
            XCTAssertEqual(self.decode(messenger.agentEvents[0].payload)?["decision"] as? String, "accept")
            XCTAssertTrue(messenger.broadcasts.isEmpty)
            XCTAssertEqual(manager.count, 0)
            published.fulfill()
        }
        wait(for: [published], timeout: 1)
    }

    func testAgentNotificationsHaveUniqueIDsAndEvictionNotifiesOriginalOwner() throws {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 1, now: { 1000 }, messenger: messenger)
        let first = manager.handleAgentRequest(context: agentContext())
        let second = manager.handleAgentRequest(context: agentContext(principalId: "agent-b"))
        let firstId = try XCTUnwrap(decode(first)?["notificationId"] as? String)
        let secondId = try XCTUnwrap(decode(second)?["notificationId"] as? String)
        XCTAssertNotEqual(firstId, secondId)
        XCTAssertEqual(manager.latestTaskId, secondId)
        XCTAssertEqual(messenger.agentEvents.count, 1)
        XCTAssertEqual(messenger.agentEvents.first?.principalId, "agent-a")
        XCTAssertEqual(decode(messenger.agentEvents[0].payload)?["notificationId"] as? String, firstId)
        XCTAssertEqual(decode(messenger.agentEvents[0].payload)?["decision"] as? String, "timeout")
        XCTAssertTrue(messenger.broadcasts.isEmpty)
    }

    func testHidingAgentCardDoesNotDecideAndRejectUsesScopedEvent() {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(now: { 1000 }, messenger: messenger)
        _ = manager.handleAgentRequest(context: agentContext())
        let published = expectation(description: "agent card published")
        DispatchQueue.main.async {
            guard let card = manager.latestCard else {
                XCTFail("Expected an agent card")
                published.fulfill()
                return
            }
            XCTAssertEqual(card.buttonTitle, "Run")
            XCTAssertEqual(card.expiresAt, 301_000)
            manager.hideCard()
            XCTAssertTrue(messenger.agentEvents.isEmpty)
            XCTAssertEqual(manager.count, 1)
            manager.decide(card: card, decision: .reject)
            XCTAssertEqual(messenger.agentEvents.count, 1)
            XCTAssertEqual(self.decode(messenger.agentEvents[0].payload)?["decision"] as? String, "reject")
            XCTAssertTrue(messenger.broadcasts.isEmpty)
            published.fulfill()
        }
        wait(for: [published], timeout: 1)
    }

    func testWorkingCardHasNoButtonAndUnknownKindFallsBackToAction() {
        let manager = NotificationCardManager(maxQueueSize: 5, now: { 1000 }, messenger: TestMessenger())
        manager.enqueueCard(
            envelope: makeCardEnvelope(taskID: "working", kind: "working", buttonTitle: "Ignored"),
            correlationId: nil)
        manager.enqueueCard(
            envelope: makeCardEnvelope(taskID: "unknown", kind: "celebration"),
            correlationId: nil)

        let published = expectation(description: "cards published")
        DispatchQueue.main.async {
            let working = manager.allCards.first { $0.taskId == "working" }
            let unknown = manager.allCards.first { $0.taskId == "unknown" }
            XCTAssertEqual(working?.kind, .working)
            XCTAssertNil(working?.buttonTitle)
            XCTAssertEqual(unknown?.kind, .action)
            XCTAssertEqual(unknown?.buttonTitle, "Run")
            published.fulfill()
        }
        wait(for: [published], timeout: 1)
    }

    func testWorkingCardUpdatesInPlace() {
        let manager = NotificationCardManager(maxQueueSize: 5, now: { 1000 }, messenger: TestMessenger())
        manager.enqueueCard(
            envelope: makeCardEnvelope(taskID: "w", kind: "working", description: "Opening"),
            correlationId: nil)
        manager.enqueueCard(envelope: makeCardEnvelope(taskID: "a"), correlationId: nil)
        manager.enqueueCard(
            envelope: makeCardEnvelope(taskID: "w", kind: "working", description: "Reading"),
            correlationId: nil)

        XCTAssertEqual(manager.count, 2)
        XCTAssertEqual(manager.latestTaskId, "a")
        let published = expectation(description: "cards published")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.allCards.map(\.taskId), ["a", "w"])
            XCTAssertEqual(manager.allCards.last?.message, "Reading")
            published.fulfill()
        }
        wait(for: [published], timeout: 1)
    }

    func testResultCardReplacesWorkingCardAtTheFront() {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 5, now: { 1000 }, messenger: messenger)
        manager.enqueueCard(envelope: makeCardEnvelope(taskID: "w", kind: "working"), correlationId: nil)
        manager.enqueueCard(envelope: makeCardEnvelope(taskID: "a"), correlationId: nil)
        manager.enqueueCard(
            envelope: makeCardEnvelope(taskID: "w", buttonTitle: "View details"),
            correlationId: nil)

        XCTAssertEqual(manager.count, 2)
        XCTAssertEqual(manager.latestTaskId, "w")
        XCTAssertTrue(messenger.broadcasts.isEmpty)
        let published = expectation(description: "cards published")
        DispatchQueue.main.async {
            XCTAssertEqual(manager.latestCard?.kind, .action)
            XCTAssertEqual(manager.latestCard?.buttonTitle, "View details")
            published.fulfill()
        }
        wait(for: [published], timeout: 1)
    }

    func testRevokeTakesDownCardWithoutDecision() {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 5, now: { 1000 }, messenger: messenger)
        manager.enqueueCard(envelope: makeCardEnvelope(taskID: "w", kind: "working"), correlationId: nil)
        manager.enqueueCard(envelope: makeCardEnvelope(taskID: "a"), correlationId: nil)

        manager.handleRequest(context: revokeContext(messageId: "message-w"))
        manager.handleRequest(context: revokeContext(messageId: "message-missing"))

        XCTAssertEqual(manager.count, 1)
        XCTAssertEqual(manager.latestTaskId, "a")
        XCTAssertTrue(messenger.broadcasts.isEmpty)
        XCTAssertEqual(messenger.responses.map(\.response), ["message-w", ""])
    }

    func testConversationCardShownInPanelTellsSenderItOpened() throws {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 5, now: { 1000 }, messenger: messenger)
        manager.enqueueCard(
            envelope: makeCardEnvelope(taskID: "chat-1", taskType: "task-report", buttonTitle: "View details"),
            correlationId: nil)
        let card = try XCTUnwrap(cardSnapshot(manager))
        var asked: [String] = []

        manager.accept(card) { conversationId in
            asked.append(conversationId)
            return true
        }
        XCTAssertEqual(manager.count, 0)
        waitForDecision(messenger)

        XCTAssertEqual(asked, ["chat-1"])
        let inner = try XCTUnwrap(decisionPayload(messenger))
        XCTAssertEqual(inner["decision"] as? String, "accept")
        XCTAssertEqual(inner["task_id"] as? String, "chat-1")
        XCTAssertEqual(inner["opened_in"] as? String, "sidebar")
    }

    func testConversationCardNotShownLeavesOpeningToSender() throws {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 5, now: { 1000 }, messenger: messenger)
        manager.enqueueCard(
            envelope: makeCardEnvelope(taskID: "chat-1", taskType: "task-report"), correlationId: nil)
        let card = try XCTUnwrap(cardSnapshot(manager))

        manager.accept(card) { _ in false }
        waitForDecision(messenger)

        let inner = try XCTUnwrap(decisionPayload(messenger))
        XCTAssertEqual(inner["decision"] as? String, "accept")
        XCTAssertNil(inner["opened_in"])
    }

    func testOtherCardsAcceptAtOnceWithoutAskingThePanel() throws {
        let messenger = TestMessenger()
        let manager = NotificationCardManager(maxQueueSize: 5, now: { 1000 }, messenger: messenger)
        manager.enqueueCard(
            envelope: makeCardEnvelope(taskID: "t1", taskType: "research"), correlationId: nil)
        let card = try XCTUnwrap(cardSnapshot(manager))

        manager.accept(card) { _ in
            XCTFail("only conversation cards open in the panel")
            return true
        }

        let inner = try XCTUnwrap(decisionPayload(messenger))
        XCTAssertEqual(inner["decision"] as? String, "accept")
        XCTAssertNil(inner["opened_in"])
    }

    private func cardSnapshot(_ manager: NotificationCardManager) -> NotificationCardManager.Card? {
        let published = expectation(description: "card published")
        var card: NotificationCardManager.Card?
        DispatchQueue.main.async {
            card = manager.latestCard
            published.fulfill()
        }
        wait(for: [published], timeout: 1)
        return card
    }

    private func waitForDecision(_ messenger: TestMessenger) {
        let deadline = Date().addingTimeInterval(2)
        while messenger.broadcasts.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func decisionPayload(_ messenger: TestMessenger) -> [String: Any]? {
        guard messenger.broadcasts.count == 1, messenger.broadcasts[0].type == "notification" else { return nil }
        return decode(messenger.broadcasts[0].payload)?["payload"] as? [String: Any]
    }

    private func revokeContext(messageId: String) -> ExtensionMessageContext {
        let payload = #"{"action":"notification.card.revoke","messageId":"\#(messageId)"}"#
        return ExtensionMessageContext(type: "notification", payload: payload,
                                       requestId: "revoke-\(messageId)", senderId: "extension")
    }

    private func makeCardEnvelope(
        taskID: String,
        kind: String? = nil,
        taskType: String? = nil,
        description: String = "Body",
        buttonTitle: String? = nil
    ) -> [String: AnyCodable] {
        var payload: [String: AnyCodable] = [
            "task_id": .string(taskID),
            "title": .string("Title"),
            "description": .string(description),
            "expires_at": .string("5000"),
        ]
        if let kind {
            payload["kind"] = .string(kind)
        }
        if let taskType {
            payload["task_type"] = .string(taskType)
        }
        if let buttonTitle {
            payload["button_title"] = .string(buttonTitle)
        }
        return [
            "action": .string("notification.card.request"),
            "messageId": .string("message-\(taskID)"),
            "payload": .init(payload),
        ]
    }

    private func agentContext(
        payload: String = #"{"title":"Title","message":"Body"}"#,
        senderId: String = "cdp",
        principalId: String? = "agent-a"
    ) -> ExtensionMessageContext {
        ExtensionMessageContext(type: "notification.show", payload: payload,
                                requestId: "agent-test", senderId: senderId,
                                driverPrincipalId: principalId)
    }

    private func decode(_ json: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    private func makeEnvelope(
        taskID: String,
        expiresAt: String,
        buttonTitle: String? = nil
    ) -> [String: AnyCodable] {
        var payload: [String: AnyCodable] = [
            "task_id": .string(taskID),
            "expires_at": .string(expiresAt)
        ]
        if let buttonTitle {
            payload["button_title"] = .string(buttonTitle)
        }

        return [
            "messageId": .string("message-\(taskID)"),
            "payload": .init(payload)
        ]
    }
}

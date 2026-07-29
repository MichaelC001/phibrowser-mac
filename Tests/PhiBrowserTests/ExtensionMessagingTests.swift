// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

final class ExtensionMessagingTests: XCTestCase {
    func testDriverSessionCapabilityResolvesTheSamePrincipal() {
        let identity = AgentIdentity(
            key: "test:agent-a",
            displayName: "Agent A",
            teamId: "test",
            verified: true,
            executablePath: "/test/agent-a",
            pid: ProcessInfo.processInfo.processIdentifier)
        let issued = AgentDriverSessionRegistry.shared.session(for: identity)
        let reconnected = AgentDriverSessionRegistry.shared.session(for: identity)
        let delegated = AgentDriverSessionRegistry.shared
            .session(forCapability: issued.capability)

        XCTAssertEqual(reconnected.principalId, issued.principalId)
        XCTAssertEqual(delegated?.principalId, issued.principalId)
    }

    func testDistinctProcessIdentityGetsDistinctPrincipal() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let first = AgentDriverSessionRegistry.shared.session(for: AgentIdentity(
            key: "test:agent-one",
            displayName: "Agent One",
            teamId: "test",
            verified: true,
            executablePath: "/test/agent-one",
            pid: pid))
        let second = AgentDriverSessionRegistry.shared.session(for: AgentIdentity(
            key: "test:agent-two",
            displayName: "Agent Two",
            teamId: "test",
            verified: true,
            executablePath: "/test/agent-two",
            pid: pid))

        XCTAssertNotEqual(first.principalId, second.principalId)
    }

    func testCDPTaskAllowsItsOwningPrincipal() {
        XCTAssertTrue(AgentTaskAccessPolicy.allows(
            taskOrigin: .cdp,
            taskPrincipalId: "agent-a",
            callerOrigin: .cdp,
            callerPrincipalId: "agent-a"))
    }

    func testCDPTaskRejectsAnotherApprovedPrincipal() {
        XCTAssertFalse(AgentTaskAccessPolicy.allows(
            taskOrigin: .cdp,
            taskPrincipalId: "agent-a",
            callerOrigin: .cdp,
            callerPrincipalId: "agent-b"))
    }

    func testCDPTaskRejectsUnprincipalledLegacyTunnel() {
        XCTAssertFalse(AgentTaskAccessPolicy.allows(
            taskOrigin: .cdp,
            taskPrincipalId: "agent-a",
            callerOrigin: .cdp,
            callerPrincipalId: nil))
    }

    func testOriginsRemainIsolated() {
        XCTAssertFalse(AgentTaskAccessPolicy.allows(
            taskOrigin: .phiAgent,
            taskPrincipalId: nil,
            callerOrigin: .cdp,
            callerPrincipalId: "agent-a"))
        XCTAssertFalse(AgentTaskAccessPolicy.allows(
            taskOrigin: .cdp,
            taskPrincipalId: "agent-a",
            callerOrigin: .phiAgent,
            callerPrincipalId: nil))
    }

    func testPhiAgentTaskStillUsesBackendOriginBoundary() {
        XCTAssertTrue(AgentTaskAccessPolicy.allows(
            taskOrigin: .phiAgent,
            taskPrincipalId: nil,
            callerOrigin: .phiAgent,
            callerPrincipalId: nil))
    }
}

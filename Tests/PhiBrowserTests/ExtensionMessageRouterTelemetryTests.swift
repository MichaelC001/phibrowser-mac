// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// Pins which managed message types are exempt from the
/// `agent_user_space_command` capture. The exempt set is the machine-loop
/// surface (CDP heartbeat, shadow keep-alive, read-only listings); every
/// mutating command must stay counted.
final class ExtensionMessageRouterTelemetryTests: XCTestCase {
    func testReadAndLivenessCommandsAreUntracked() {
        let expected: Set<String> = [
            "agentSpace.bookmarks.list",
            "agentSpace.pinnedTabs.list",
            "agentSpace.shadow.list",
            "agentSpace.shadow.ping",
            "agentSpace.spaces.list",
            "agentSpace.spaces.listTabs",
            "agentSpace.urlRules.list",
            "credentials.status",
        ]
        XCTAssertEqual(ExtensionMessageRouter.untrackedUserSpaceCommands, expected)
    }

    func testMutatingAndSecretReadingCommandsStayTracked() {
        for command in [
            "agentSpace.spaces.create",
            "agentSpace.spaces.openTab",
            "agentSpace.spaces.activate",
            "agentSpace.shadow.create",
            "agentSpace.bookmarks.add",
            "agentSpace.urlRules.delete",
            "credentials.get",
            "credentials.getTotp",
            "credentials.autofill",
        ] {
            XCTAssertFalse(
                ExtensionMessageRouter.untrackedUserSpaceCommands.contains(command),
                "\(command) must still be counted as agent_user_space_command"
            )
        }
    }
}

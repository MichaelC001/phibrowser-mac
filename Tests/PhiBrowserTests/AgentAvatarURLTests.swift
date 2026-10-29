// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import XCTest
@testable import Phi

/// phi-agent returns custom and generated avatars as host-less paths; those
/// must be fetched over the phi-agent transport rather than as plain URLs.
final class AgentAvatarURLTests: XCTestCase {
    func testRelativeFilePathIsFetchedFromPhiAgent() {
        XCTAssertEqual(
            APIClient.agentAvatarFilePath("/api/v1/files/abc123?v=2"),
            "/api/v1/files/abc123?v=2"
        )
    }

    func testDataAndAbsoluteURLsAreNotPhiAgentPaths() {
        XCTAssertNil(APIClient.agentAvatarFilePath("data:image/svg+xml;charset=utf-8,%3Csvg%2F%3E"))
        XCTAssertNil(APIClient.agentAvatarFilePath("https://cdn.example.com/avatar.png"))
        XCTAssertNil(APIClient.agentAvatarFilePath("//cdn.example.com/avatar.png"))
    }
}

#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/phi-agent-avatar.XXXXXX")"
python3 - "$repo" "$build" <<'PY'
from pathlib import Path
import sys
root, build = map(Path, sys.argv[1:])
source = (root / 'Sources/Networking/APIClient.swift').read_text()
models = source[source.index('struct AgentAvatarResponse'):source.index('/// `POST /api/video-gist')]
methods = source[source.index('    func getAgentAvatarImageData()'):source.index('    // MARK: - Invitation APIs')]
stubs = '''
class APIClient {
    static let shared = APIClient()
    var avatarURL = ""
    var paths: [String] = []
    var token = "fixture-token"
    func getAgentAvatar() async throws -> AgentAvatarResponse {
        AgentAvatarResponse(url: avatarURL, source: .custom, mimeType: "image/png", filename: "test.png", updatedAt: nil)
    }
    func sendPhiAgentRequest(path: String) async throws -> (statusCode: Int, body: Data) {
        paths.append(path)
        return (200, Data("image".utf8))
    }
'''
(build / 'API.swift').write_text('import Foundation\n' + models + '\nenum APIError: Error { case invalidResponse; case httpError(statusCode: Int) }\n' + stubs + methods + '\n}')
view = (root / 'Sources/UserInterface/Notifications/NotificationMessageCardView.swift').read_text()
view = view[view.index('private struct NotificationCardAgentAvatarView'):view.index('\n// MARK: - Working Card')].replace('private struct NotificationCardAgentAvatarView', 'struct NotificationCardAgentAvatarView')
manager = (root / 'Sources/Notifications/MessageCard/NotificationCardManager.swift').read_text()
load = manager[manager.index('    /// Fetches avatar bytes and decodes them'):manager.index("    /// Drops the account's avatar from memory and disk.")]
store = '@MainActor enum AgentAvatarStore {\n    static func cachedImage() -> NSImage? { nil }\n    static func refresh() async -> NSImage? { nil }\n' + load + '}\n'
(build / 'AvatarView.swift').write_text('import SwiftUI\nimport AppKit\nfunc AppLogError(_ message: String) {}\nfunc AppLogWarn(_ message: String) {}\n' + store + view)
PY
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$build/modules" "$build/API.swift" "$build/AvatarView.swift" "$repo/Tests/AgentAvatar/main.swift" -o "$build/tests"
"$build/tests"

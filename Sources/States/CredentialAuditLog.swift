// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Foundation

/// Append-only record of agent credential activity. Records WHAT happened
/// (requested / approved / denied / served / error), WHO asked, and WHICH scope
/// — plus, for a served credential, which fields were released as booleans only.
/// It never records credential values, mirroring `ap-client`'s `AuditLog` +
/// `CredentialFieldSet` (presence flags, never secrets).
///
/// Thread-safe via a private serial queue; callable from any context.
final class CredentialAuditLog: @unchecked Sendable {
    static let shared = CredentialAuditLog()

    enum Event: String {
        case requested
        case approved
        case denied
        case served
        case error
    }

    private let queue = DispatchQueue(label: "com.phibrowser.credential-audit")
    private let fileURL: URL?

    private init() {
        let dir = FileSystemUtils.applicationSupportDirctory()
        fileURL = (dir as NSString?)
            .map { URL(fileURLWithPath: $0.appendingPathComponent("credential-audit.log")) }
    }

    func record(_ event: Event,
                agent: String,
                scope: String,
                fields: CredentialFieldSet? = nil,
                detail: String? = nil) {
        // Build a compact, value-free summary for the app log immediately.
        AppLogInfo("[Credentials] \(event.rawValue) agent=\(agent) scope=\(scope)"
            + (detail.map { " detail=\($0)" } ?? ""))

        guard let fileURL else { return }
        var entry: [String: Any] = [
            "event": event.rawValue,
            "agent": agent,
            "scope": scope,
        ]
        if let fields {
            entry["fields"] = [
                "username": fields.username,
                "password": fields.password,
                "totp": fields.totp,
                "uri": fields.uri,
                "notes": fields.notes,
            ]
        }
        if let detail { entry["detail"] = detail }

        queue.async {
            // Timestamp is stamped on the writer queue so ordering matches append order.
            var stamped = entry
            stamped["timestamp"] = ISO8601DateFormatter().string(from: Date())
            guard let data = try? JSONSerialization.data(withJSONObject: stamped),
                  var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            guard let lineData = line.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: lineData)
            } else {
                try? lineData.write(to: fileURL, options: .atomic)
            }
        }
    }
}

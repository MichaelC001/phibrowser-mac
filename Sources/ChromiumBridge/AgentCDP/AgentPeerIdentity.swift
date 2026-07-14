// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import Darwin
import Foundation
import Security

/// Who is on the other end of an agent CDP connection. Resolved from the
/// connected socket's peer pid: we walk the process ancestry to the
/// "responsible" process (the agent, not the `node`/shell that launched it),
/// verify its code signature, and reduce it to a stable identity the user can
/// grant once and have remembered.
///
/// This is an *identification* aid for the consent prompt, not a security
/// boundary — the boundary is the same-uid check plus the user's decision.
/// A same-user process can always launch a genuinely-signed agent to inherit
/// its grant; the prompt and the revocable grants list are the mitigation.
struct AgentIdentity: Equatable {
    /// Stable key for remembering a grant: "teamId:signingId" when the
    /// responsible process is validly signed, else "unsigned:<path>".
    let key: String
    /// Human-readable name for the consent prompt (signing identifier or
    /// process name).
    let displayName: String
    /// Team identifier from the code signature, nil when unsigned.
    let teamId: String?
    /// True when the responsible process carries a valid code signature.
    let verified: Bool
    /// Absolute path of the responsible process's executable.
    let executablePath: String

    /// Secondary line for the prompt, e.g. "Team 87DQ3HMK5G · verified".
    var detail: String {
        let trust = verified
            ? NSLocalizedString("verified", comment: "CDP consent - signature verified")
            : NSLocalizedString("unsigned", comment: "CDP consent - no valid signature")
        if let teamId, !teamId.isEmpty {
            return String(
                format: NSLocalizedString("Team %@ · %@",
                                          comment: "CDP consent - team and trust"),
                teamId, trust)
        }
        return trust
    }
}

/// One entry in the Developer settings "Allowed agents" list: an identity the
/// user has granted CDP access, either persisted ("Always Allow") or for this
/// session only ("Allow Once").
struct AgentGrant: Identifiable {
    let key: String
    let remembered: Bool
    var id: String { key }

    /// Signing identifier, or the executable name for an unsigned peer.
    var displayName: String {
        if key.hasPrefix("unsigned:") {
            let path = String(key.dropFirst("unsigned:".count))
            return (path as NSString).lastPathComponent
        }
        if let range = key.range(of: ":") {
            return String(key[range.upperBound...])
        }
        return key
    }

    /// Team identifier when the key encodes one ("teamId:signingId").
    var teamId: String? {
        guard !key.hasPrefix("unsigned:"), !key.hasPrefix("signed:"),
              let range = key.range(of: ":") else { return nil }
        return String(key[..<range.lowerBound])
    }
}

enum AgentPeerIdentity {
    /// Interpreters and shells that merely *host* an agent — never the
    /// identity we present. The walk skips past these to the real launcher.
    private static let passthroughNames: Set<String> = [
        "node", "deno", "bun", "npm", "npx", "pnpm", "yarn", "corepack",
        "tsx", "ts-node", "uv", "uvx",
        "python", "python2", "python3", "ruby", "perl", "php",
        "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh",
        "env", "login", "sudo", "xargs", "timeout",
    ]

    /// Resolves the identity of the process connected on `socketFD`, or nil
    /// when the peer pid can't be read. Runs synchronous filesystem and
    /// Security calls — call it off the main thread.
    static func resolve(socketFD: Int32) -> AgentIdentity? {
        guard let peerPID = peerProcessID(socketFD: socketFD) else { return nil }
        let responsible = responsiblePID(startingAt: peerPID)
        let path = executablePath(responsible) ?? "pid-\(responsible)"
        return signingIdentity(pid: responsible, executablePath: path)
    }

    /// True when the socket peer runs under the same uid as this process. The
    /// coarse gate that keeps other local users out before any consent logic.
    static func peerIsSameUser(socketFD: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(socketFD, &uid, &gid) == 0 else { return false }
        return uid == getuid()
    }

    // MARK: - Peer credentials

    private static func peerProcessID(socketFD: Int32) -> pid_t? {
        var pid: pid_t = -1
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let rc = getsockopt(socketFD, SOL_LOCAL, LOCAL_PEERPID, &pid, &len)
        guard rc == 0, pid > 0 else { return nil }
        return pid
    }

    // MARK: - Ancestry walk

    /// The responsible process is the nearest ancestor (starting at the peer)
    /// that is either a signed `.app` bundle or a non-interpreter binary — the
    /// launcher (agent CLI, its app, or the terminal running it), not the
    /// `node`/shell plumbing in between. Falls back to the peer itself.
    private static func responsiblePID(startingAt peerPID: pid_t) -> pid_t {
        var pid = peerPID
        var guardCount = 0
        while pid > 1 && guardCount < 32 {
            guardCount += 1
            let path = executablePath(pid)
            if isResponsible(pid: pid, executablePath: path) {
                return pid
            }
            guard let parent = parentPID(pid), parent != pid else { break }
            pid = parent
        }
        return peerPID
    }

    private static func isResponsible(pid: pid_t, executablePath path: String?) -> Bool {
        guard let path else { return false }
        // A signed application bundle is a strong, verifiable identity.
        if path.contains(".app/Contents/MacOS/") { return true }
        let name = (path as NSString).lastPathComponent
        return !passthroughNames.contains(name)
    }

    private static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard rc == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Code signature

    private static func signingIdentity(pid: pid_t,
                                        executablePath path: String) -> AgentIdentity {
        let fallbackName = (path as NSString).lastPathComponent
        let unsigned = AgentIdentity(
            key: "unsigned:\(path)",
            displayName: fallbackName,
            teamId: nil,
            verified: false,
            executablePath: path)

        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            return unsigned
        }
        // Reject an invalid/broken signature; an unsigned-but-running binary
        // also lands here and is reported as unsigned.
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
            return unsigned
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return unsigned
        }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else {
            return unsigned
        }

        let signingId = info[kSecCodeInfoIdentifier as String] as? String
        let teamId = info[kSecCodeInfoTeamIdentifier as String] as? String
        let key: String
        if let teamId, !teamId.isEmpty, let signingId, !signingId.isEmpty {
            key = "\(teamId):\(signingId)"
        } else if let signingId, !signingId.isEmpty {
            key = "signed:\(signingId)"
        } else {
            return unsigned
        }
        return AgentIdentity(
            key: key,
            displayName: signingId ?? fallbackName,
            teamId: teamId,
            verified: true,
            executablePath: path)
    }
}

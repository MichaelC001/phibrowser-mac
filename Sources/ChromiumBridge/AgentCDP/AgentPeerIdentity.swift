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
    /// Pid of the responsible/branded agent process, nil when the identity is
    /// a fallback with no real agent behind it. Echoed to `/phi-agent` clients
    /// (see AgentDirectConnection) so a SANDBOXED skill round — which cannot
    /// walk its own ancestry (Codex's seatbelt denies the sysctls `ps` needs)
    /// — still learns the agent pid to record for its detached daemon and
    /// watchers to claim.
    let pid: pid_t?

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

    /// Signing identifier, or a friendly name derived from the path for an
    /// unsigned/script peer (e.g. a `node` CLI agent named by the script it
    /// runs, not the interpreter binary).
    var displayName: String {
        if key.hasPrefix("unsigned:") {
            let path = String(key.dropFirst("unsigned:".count))
            return AgentPeerIdentity.deriveAgentName(fromPath: path)
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

    /// The subset of `passthroughNames` that run a SCRIPT as their first real
    /// argument. When the responsible process is one of these (a bare CLI agent
    /// with no signed-app ancestor), we name it by the script it runs rather
    /// than by the interpreter's meaningless ad-hoc signing id ("node-<cdhash>").
    private static let scriptInterpreters: Set<String> = [
        "node", "deno", "bun", "tsx", "ts-node",
        "python", "python2", "python3", "ruby", "perl", "php", "uv", "uvx",
    ]

    /// Resolves the identity of the process connected on `socketFD`, or nil
    /// when the peer pid can't be read. Runs synchronous filesystem and
    /// Security calls — call it off the main thread.
    static func resolve(socketFD: Int32) -> AgentIdentity? {
        guard let peerPID = peerProcessID(socketFD: socketFD) else { return nil }
        return resolve(pid: peerPID)
    }

    /// Identity of a process the connecting client CLAIMS to act for. A
    /// client whose ancestry no longer reaches its driving agent — the
    /// skill's detached mirror daemon, a hand-back watcher orphaned by a
    /// backgrounding shell — names the agent's pid in the request instead
    /// (an `agentPid` query or `X-Phi-Agent-Pid` header, on any route).
    /// Honored only for a live process of the same user; a claim is an
    /// identification aid exactly like argv[0] branding (see the header
    /// note), not a security boundary.
    static func resolveClaimed(pid: pid_t) -> AgentIdentity? {
        guard pid > 0, processUID(pid) == getuid() else { return nil }
        return resolve(pid: pid, claimed: true)
    }

    /// Identity of an arbitrary same-user process — the socket peer, or a
    /// pid the peer claims to act for (`claimed`).
    private static func resolve(pid peerPID: pid_t, claimed: Bool = false) -> AgentIdentity? {
        let responsible = responsiblePID(startingAt: peerPID)
        let path = executablePath(responsible) ?? "pid-\(responsible)"
        let signed = signingIdentity(pid: responsible, executablePath: path)
        // A bare interpreter (e.g. a `node` CLI agent with no signed-app
        // ancestor) resolves to a per-build ad-hoc id like "node-<cdhash>",
        // which is meaningless and brittle. Name it by its argv[0] brand or
        // the script it runs.
        let exeName = (path as NSString).lastPathComponent
        if scriptInterpreters.contains(exeName),
           let scripted = scriptIdentity(startingAt: peerPID) {
            return scripted
        }
        // Pi running under a launcher (herdr, tmux, a supervisor daemon) the
        // responsible-process walk stops on, masking pi behind the launcher's
        // identity. Recover pi SPECIFICALLY from its self-brand, so this can
        // only ever yield pi — never override another agent's signed grant.
        if let pi = piIdentity(startingAt: peerPID, claimed: claimed) {
            return pi
        }
        return signed
    }

    /// Pi identity when this connection belongs to a pi coding-agent session
    /// masked by a non-passthrough launcher, else nil. Pi self-identifies two
    /// ways, and which is visible depends on the process being resolved:
    ///   • It exports PI_CODING_AGENT=true, then spawns its tools — so every
    ///     child that connects (the mirror heredoc, the tool shell, the
    ///     detached daemon) inherits the marker at exec. But pi's OWN environ
    ///     snapshot lacks it: pi sets it at runtime, after exec, and
    ///     KERN_PROCARGS2 reflects only the exec-time environment. So the
    ///     marker proves a pi session from the CONNECTING PEER, never from pi.
    ///   • It rewrites argv[0] to its app name ("pi"), visible on the pi
    ///     process itself — how we locate pi in the ancestry, and how we accept
    ///     a detached daemon's claim of pi's pid (`claimed`, its own environ
    ///     carrying the marker but out of reach behind the pid).
    /// Requiring the "pi" brand on the located process keeps an unrelated
    /// process that merely inherited the marker from being taken for pi.
    private static func piIdentity(startingAt peerPID: pid_t,
                                   claimed: Bool) -> AgentIdentity? {
        guard let piPid = piBrandedAncestor(startingAt: peerPID),
              environHasPiMarker(peerPID) || (claimed && piPid == peerPID) else {
            return nil
        }
        return unsignedIdentity(name: "pi", path: "pi",
                                exe: executablePath(piPid) ?? "pi", pid: piPid)
    }

    /// The nearest ancestor (from the peer up) that is a pi process — a script
    /// interpreter branded argv[0]=="pi" — or nil.
    private static func piBrandedAncestor(startingAt peerPID: pid_t) -> pid_t? {
        var pid = peerPID
        var guardCount = 0
        while pid > 1 && guardCount < 32 {
            guardCount += 1
            if isPiBranded(pid) { return pid }
            guard let parent = parentPID(pid), parent != pid else { break }
            pid = parent
        }
        return nil
    }

    /// Walks the ancestry for the nearest interpreter that identifies a real
    /// agent — either by a custom `argv[0]` (an agent that runs `node` but
    /// renames itself "pi") or by the script it runs — skipping this skill's
    /// own plumbing. So a `node`-based agent shows as "pi" rather than
    /// "node". When only the skill's own scripts are found (a detached
    /// mirror daemon whose spawning session's ancestry is gone), identifies
    /// the skill itself, stably keyed by its directory, rather than the
    /// interpreter's meaningless ad-hoc id. Returns nil when nothing better
    /// than the interpreter is found.
    private static func scriptIdentity(startingAt peerPID: pid_t) -> AgentIdentity? {
        var pid = peerPID
        var guardCount = 0
        var ownPlumbingExe: String?
        while pid > 1 && guardCount < 32 {
            guardCount += 1
            if let exe = executablePath(pid),
               scriptInterpreters.contains((exe as NSString).lastPathComponent),
               let argv = processArgv(pid) {
                if let identity = interpreterIdentity(argv: argv, exe: exe, pid: pid) {
                    return identity
                }
                if ownPlumbingExe == nil, isOwnPlumbing(argv: argv) {
                    ownPlumbingExe = exe
                }
            }
            guard let parent = parentPID(pid), parent != pid else { break }
            pid = parent
        }
        guard let ownPlumbingExe else { return nil }
        // The skill's own plumbing is not an agent — no pid to echo back.
        return unsignedIdentity(name: "phi-browser", path: "phi-browser",
                                exe: ownPlumbingExe, pid: nil)
    }

    /// Identity of one interpreter process: prefers a custom `argv[0]` the
    /// agent branded itself with (e.g. Pi launches `node` with argv[0]="pi"),
    /// else the script file it runs. Returns nil for a plain interpreter or
    /// this skill's own plumbing, so the walk keeps looking upward.
    private static func interpreterIdentity(argv: [String], exe: String,
                                            pid: pid_t) -> AgentIdentity? {
        guard let arg0 = argv.first else { return nil }
        if isOwnPlumbing(argv: argv) { return nil }
        let interpreterName = (exe as NSString).lastPathComponent
        let arg0Name = (arg0 as NSString).lastPathComponent
        // (1) Custom argv[0] branding: a bare name (not a path) that isn't the
        //     interpreter's own — the agent's self-declared identity.
        if !arg0.contains("/"), !arg0Name.isEmpty, arg0Name != interpreterName,
           !scriptInterpreters.contains(arg0Name) {
            return unsignedIdentity(name: arg0Name, path: arg0Name, exe: exe, pid: pid)
        }
        // (2) Otherwise the script it runs.
        if let script = scriptArgument(in: argv) {
            return unsignedIdentity(
                name: deriveAgentName(fromPath: script), path: script, exe: exe, pid: pid)
        }
        return nil
    }

    /// This skill's own plumbing is never presented as the agent. The heredoc
    /// runner is recognized by the script it runs; the mirror-tailer daemon
    /// by its argv[0] brand — its `process.title` rewrite overwrites the argv
    /// block, so the script path is unreadable for it.
    private static func isOwnPlumbing(argv: [String]) -> Bool {
        if let arg0 = argv.first,
           ownBrandNames.contains((arg0 as NSString).lastPathComponent) {
            return true
        }
        if let script = scriptArgument(in: argv) { return isOwnRunner(script) }
        return false
    }

    /// argv[0] brands used by the skill's own daemons (see mirror-tailer.mjs).
    private static let ownBrandNames: Set<String> = ["phi-mirror-tailer"]

    /// The script an interpreter runs: its first existing non-flag argument.
    private static func scriptArgument(in argv: [String]) -> String? {
        for arg in argv.dropFirst() {
            if arg.hasPrefix("-") { continue }
            if FileManager.default.fileExists(atPath: arg) { return arg }
        }
        return nil
    }

    private static func unsignedIdentity(name: String, path: String,
                                         exe: String, pid: pid_t?) -> AgentIdentity {
        AgentIdentity(key: "unsigned:\(path)", displayName: name,
                      teamId: nil, verified: false, executablePath: exe, pid: pid)
    }

    /// This skill's own plumbing (heredoc runner, mirror-tailer daemon) —
    /// skipped when walking for the agent so we identify the launcher above
    /// it, not our own scripts. Matches both the installed skill directory
    /// ("phi-browser") and a repo checkout ("phi-browser-skill"), which Node
    /// exposes via realpath when the install is a symlink.
    private static func isOwnRunner(_ scriptPath: String) -> Bool {
        scriptPath.contains("/phi-browser/scripts/")
            || scriptPath.contains("/phi-browser-skill/scripts/")
    }

    /// A readable agent name from a script/executable path: the npm package
    /// name when under `node_modules`, else a meaningful file stem, else the
    /// nearest meaningful parent directory. `.../pi/cli.js` → "pi".
    static func deriveAgentName(fromPath path: String) -> String {
        if let r = path.range(of: "/node_modules/") {
            let comps = path[r.upperBound...].split(separator: "/").map(String.init)
            if let first = comps.first {
                if first.hasPrefix("@"), comps.count >= 2 { return comps[1] }
                return first
            }
        }
        let generic: Set<String> = [
            "cli", "index", "main", "bin", "dist", "build", "src", "lib",
            "run", "start", "runner", "server", "app", "out", "node_modules",
        ]
        let base = (path as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        if !stem.isEmpty, !generic.contains(stem.lowercased()) { return stem }
        var dir = (path as NSString).deletingLastPathComponent
        for _ in 0..<5 {
            let comp = (dir as NSString).lastPathComponent
            if comp.isEmpty { break }
            let bare = comp.hasPrefix(".") ? String(comp.dropFirst()) : comp
            if !bare.isEmpty, !generic.contains(bare.lowercased()) { return bare }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return stem.isEmpty ? base : stem
    }

    /// A process's argv (see processArgsAndEnv).
    private static func processArgv(_ pid: pid_t) -> [String]? {
        processArgsAndEnv(pid)?.argv
    }

    /// True when `pid`'s exec-time environment carries pi's session marker
    /// (`PI_CODING_AGENT=true`). Pi sets it at runtime, so it is ABSENT from
    /// pi's own snapshot but inherited by every child pi spawns — read it from
    /// the connecting peer, not from pi (see piIdentity).
    private static func environHasPiMarker(_ pid: pid_t) -> Bool {
        processArgsAndEnv(pid)?.env.contains("PI_CODING_AGENT=true") ?? false
    }

    /// True when `pid` is a pi process: a script interpreter that rewrote its
    /// argv[0] to the bare name "pi" (pi's `process.title = APP_NAME`, whose
    /// default is "pi"). The brand is visible on pi itself, so this identifies
    /// the pi pid a detached daemon claims, where the env marker is not (see
    /// piIdentity).
    private static func isPiBranded(_ pid: pid_t) -> Bool {
        guard let exe = executablePath(pid),
              scriptInterpreters.contains((exe as NSString).lastPathComponent),
              let arg0 = processArgsAndEnv(pid)?.argv.first,
              !arg0.contains("/") else { return false }
        return (arg0 as NSString).lastPathComponent == "pi"
    }

    /// A process's argv and environment via `KERN_PROCARGS2` (same-uid
    /// processes only, which the ancestry always is). Layout: Int32 argc,
    /// exec_path, null padding, argc null-terminated argv strings, then the
    /// null-terminated environment strings ("KEY=VALUE"). The environment is
    /// the EXEC-time one: a variable a process sets on itself after exec is
    /// absent, but everything it inherited (and hands to its children) is
    /// present. Nil when unreadable — a process that exited, or a sandboxed
    /// peer whose seatbelt denies the sysctl.
    private static func processArgsAndEnv(_ pid: pid_t) -> (argv: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 4 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            buffer.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<4]))
            }
        }
        var pos = MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard pos < size else { return nil }
            let start = pos
            while pos < size && buffer[pos] != 0 { pos += 1 }
            let s = String(decoding: buffer[start..<pos], as: UTF8.self)
            pos += 1  // skip the null terminator
            return s
        }
        _ = nextString()                                  // exec_path
        while pos < size && buffer[pos] == 0 { pos += 1 } // padding before argv[0]
        var args: [String] = []
        for _ in 0..<Int(argc) {
            guard let s = nextString() else { break }
            args.append(s)
        }
        var env: [String] = []
        while let s = nextString() {
            if !s.isEmpty { env.append(s) }
        }
        return (args, env)
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

    /// Effective uid of a process, nil when it can't be read (process gone).
    private static func processUID(_ pid: pid_t) -> uid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size)
        }
        guard rc == size else { return nil }
        return uid_t(info.pbi_uid)
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
            executablePath: path,
            pid: pid)

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
            executablePath: path,
            pid: pid)
    }
}

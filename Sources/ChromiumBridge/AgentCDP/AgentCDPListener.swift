// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import AppKit
import Darwin
import Foundation

/// Owns the Unix-domain socket that agent tooling (Claude Code, Codex, the
/// phi-browser skill) uses to reach the browser's DevTools/CDP endpoint.
///
/// The browser process listens on nothing: this app owns the listener,
/// authenticates every connecting process, prompts for the user's consent the
/// first time an agent appears, and hands each approved connection to Chromium
/// as a bare file descriptor via `attachDevToolsConnectionWithFD:`. Because the
/// app owns the socket, the whole feature toggles at runtime — no relaunch — and
/// access can be revoked instantly (`closeAllDevToolsConnections`).
///
/// Threading: the accept loop runs on `ioQueue`; each connection is
/// authenticated on the serial `authQueue` (which also serializes consent
/// prompts and caches their result, so the skill's back-to-back HTTP + WebSocket
/// connections prompt at most once); the bridge hand-off and the modal prompt
/// hop to the main thread.
final class AgentCDPListener {
    static let shared = AgentCDPListener()

    private let ioQueue = DispatchQueue(label: "com.phibrowser.cdp.listener")
    private let authQueue = DispatchQueue(label: "com.phibrowser.cdp.auth")

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var socketPath: String?
    private var pointerFilePath: String?
    private var running = false

    // "Allow once" decisions for this app session, keyed by AgentIdentity.key.
    // Persisted grants live in PhiPreferences.rememberedAgentGrants.
    private var sessionGrants = Set<String>()
    private let grantsLock = NSLock()

    private init() {}

    // MARK: - Lifecycle

    /// Starts the listener when agent CDP access is enabled. Call at launch.
    func startIfEnabled() {
        if PhiPreferences.AgentSpaces.cdpAgentAccessEnabled {
            start()
        }
    }

    /// Flips the preference and applies it live: starts or stops the listener
    /// now, with no relaunch. Call from the Settings toggle. Also refreshes
    /// the main menu, whose View ▸ Agent Autoview / Agent Transcript items
    /// are gated on this switch.
    func setEnabled(_ enabled: Bool) {
        PhiPreferences.AgentSpaces.cdpAgentAccessEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
        DispatchQueue.main.async {
            AppController.shared?.refreshPrefGatedMenuItems()
            // No agent can drive with the switch off, so an open transcript
            // panel is a dead surface — take it down with the menu items.
            if !enabled {
                AgentTranscriptPanelController.shared.dismiss()
            }
        }
    }

    func start() {
        ioQueue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        ioQueue.async { [weak self] in self?.stopOnQueue() }
    }

    /// Forgets an agent grant (Settings ▸ revoke): drops it from both the
    /// remembered set and this session's cache, so the identity must pass the
    /// consent prompt again on its next connection. Already-attached
    /// connections persist until they close (flip the master toggle to sever
    /// everything at once).
    func forgetGrant(key: String) {
        var remembered = PhiPreferences.AgentSpaces.rememberedAgentGrants
        remembered.remove(key)
        PhiPreferences.AgentSpaces.rememberedAgentGrants = remembered
        grantsLock.lock()
        sessionGrants.remove(key)
        grantsLock.unlock()
    }

    /// Every agent currently allowed to connect: the persisted "Always Allow"
    /// grants plus this session's "Allow Once" grants. Backs the Developer
    /// settings list. Safe to call from the main thread.
    func allowedGrants() -> [AgentGrant] {
        let remembered = PhiPreferences.AgentSpaces.rememberedAgentGrants
        grantsLock.lock()
        let session = sessionGrants
        grantsLock.unlock()

        var grants: [AgentGrant] = remembered.sorted().map {
            AgentGrant(key: $0, remembered: true)
        }
        for key in session.subtracting(remembered).sorted() {
            grants.append(AgentGrant(key: key, remembered: false))
        }
        return grants
    }

    // MARK: - Socket setup (ioQueue)

    private func startOnQueue() {
        guard !running else { return }

        guard let paths = Self.resolveSocketPaths() else {
            AppLogError("[AgentCDP] could not resolve a socket path")
            return
        }

        Self.sweepOrphanedSocketDirs(
            keeping: (paths.socket as NSString).deletingLastPathComponent)
        guard Self.prepareSocketDirectory(for: paths.socket) else { return }
        unlink(paths.socket)  // clear a stale socket from a previous run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            AppLogError("[AgentCDP] socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        guard Self.bind(fd: fd, to: paths.socket) else {
            close(fd)
            return
        }
        chmod(paths.socket, 0o600)

        guard listen(fd, 16) == 0 else {
            AppLogError("[AgentCDP] listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            unlink(paths.socket)
            return
        }
        Self.setNonBlocking(fd)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.resume()

        listenFD = fd
        acceptSource = source
        socketPath = paths.socket
        pointerFilePath = paths.pointer
        running = true

        // Publish the socket path for the skill's discovery (the file may live
        // at a long path; only bind() is bound by sun_path's ~104-byte limit).
        try? (paths.socket + "\n").write(toFile: paths.pointer, atomically: true, encoding: .utf8)

        AppLogInfo("[AgentCDP] listening at \(paths.socket)")
    }

    private func stopOnQueue() {
        guard running else { return }
        running = false

        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        if let socketPath { unlink(socketPath) }
        if let pointerFilePath { unlink(pointerFilePath) }
        socketPath = nil
        pointerFilePath = nil

        grantsLock.lock()
        sessionGrants.removeAll()
        grantsLock.unlock()

        // Sever both transports: connections handed to Chromium and the
        // app-served /phi-agent channels (revoke is immediate).
        AgentDirectChannelRegistry.shared.closeAll()
        DispatchQueue.main.async {
            ChromiumLauncher.sharedInstance().bridge?.closeAllDevToolsConnections()
        }
        AppLogInfo("[AgentCDP] stopped")
    }

    // MARK: - Accept loop (ioQueue)

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                // Drained the backlog (EAGAIN/EWOULDBLOCK) or a transient error.
                break
            }
            Self.setNonBlocking(fd)
            authQueue.async { [weak self] in self?.authenticateAndDispatch(fd) }
        }
    }

    // MARK: - Authentication (authQueue, serial)

    private func authenticateAndDispatch(_ fd: Int32) {
        guard AgentPeerIdentity.peerIsSameUser(socketFD: fd) else {
            AppLogWarn("[AgentCDP] rejecting connection from another user")
            Self.denyAndClose(fd)
            return
        }

        // Peek (never consume) the request head up front: the first line
        // routes the connection, and any request may carry the agent-session
        // pid claim used for the consent identity below.
        // A connection that never sent a request — a port probe, a liveness
        // check, a peer that hung up immediately — must not reach consent
        // evaluation: an unidentifiable zero-byte peer would pop an "Unknown
        // process" prompt and, on this serial queue, wedge every legitimate
        // connection behind it. Close it quietly.
        guard let requestHead = Self.peekRequestHead(fd) else {
            close(fd)
            return
        }
        let requestLine = requestHead
            .split(separator: "\r\n", maxSplits: 1).first
            .map(String.init)
        let isPhiAgent = requestLine?.hasPrefix("GET /phi-agent") ?? false

        // Resolve the actual peer ancestry first. A direct `/phi-agent`
        // connection may present an app-issued capability from an earlier
        // connection; that is the proof that a detached/sandboxed helper was
        // delegated this logical agent session. The caller-supplied pid stays
        // an identification aid for stock Chromium connections, but is never
        // sufficient to join an existing Swift task principal.
        let peerIdentity = AgentPeerIdentity.resolve(socketFD: fd)
            ?? AgentIdentity(key: "unknown", displayName: "Unknown process",
                             teamId: nil, verified: false, executablePath: "",
                             pid: nil)

        // Route by the request line: a `/phi-agent` upgrade is an agentSpace.*
        // channel served in the app; everything else (/json, /devtools) is
        // stock CDP handed to Chromium with the fd intact (the peek never
        // consumed it).
        if isPhiAgent {
            let session: AgentDriverSession
            if Self.hasAgentCapabilityHeader(inRequestHead: requestHead) {
                guard let capability = Self.claimedAgentCapability(
                        inRequestHead: requestHead),
                      let delegated = AgentDriverSessionRegistry.shared
                        .session(forCapability: capability) else {
                    AppLogWarn("[AgentCDP] rejected invalid agent-session capability")
                    Self.denyAndClose(fd)
                    return
                }
                session = delegated
                guard evaluate(session.identity) else {
                    AppLogInfo("[AgentCDP] denied delegated access to \(session.identity.displayName)")
                    Self.denyAndClose(fd)
                    return
                }
            } else {
                guard evaluate(peerIdentity) else {
                    AppLogInfo("[AgentCDP] denied access to \(peerIdentity.displayName)")
                    Self.denyAndClose(fd)
                    return
                }
                session = AgentDriverSessionRegistry.shared.session(for: peerIdentity)
            }
            AgentDirectConnection(
                fd: fd,
                agentName: session.identity.displayName,
                agentPid: session.identity.pid,
                driverPrincipalId: session.principalId,
                agentCapability: session.capability
            ).start()
            return
        }

        var identity = peerIdentity
        if let claimedPid = Self.claimedAgentPid(inRequestHead: requestHead),
           let claimed = AgentPeerIdentity.resolveClaimed(pid: claimedPid) {
            AppLogInfo("[AgentCDP] peer \(identity.displayName) acts for agent pid "
                       + "\(claimedPid) (\(claimed.displayName))")
            identity = claimed
        }

        guard evaluate(identity) else {
            AppLogInfo("[AgentCDP] denied access to \(identity.displayName)")
            Self.denyAndClose(fd)
            return
        }

        // Hand the raw fd to Chromium, which owns it from here (closed by the
        // browser whether or not the injection transport is live).
        DispatchQueue.main.async {
            let attached = ChromiumLauncher.sharedInstance().bridge?
                .attachDevToolsConnection(withFD: fd) ?? false
            if !attached {
                AppLogWarn("[AgentCDP] injection transport unavailable; connection dropped")
            }
        }
    }

    /// Peeks (without consuming) at the start of the HTTP request — enough to
    /// cover the request line and the early headers that may carry the agent
    /// claim (the skill puts X-Phi-Agent-Pid right after Host). Non-consuming
    /// so a Chromium-bound fd stays pristine for its HTTP server to read from
    /// the start.
    private static func peekRequestHead(_ fd: Int32) -> String? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&pfd, 1, 2000)  // up to 2s for the request to arrive
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = recv(fd, &buf, buf.count, Int32(MSG_PEEK))
        guard n > 0 else { return nil }
        return String(decoding: buf[0..<n], as: UTF8.self)
    }

    /// The agent-session pid a request claims to act for: an `agentPid` query
    /// value on the request line (e.g. "GET /phi-agent?agentPid=123
    /// HTTP/1.1") or an `X-Phi-Agent-Pid` header on any route.
    private static func claimedAgentPid(inRequestHead head: String) -> pid_t? {
        let lines = head.components(separatedBy: "\r\n")
        guard let line = lines.first else { return nil }
        let parts = line.split(separator: " ")
        if parts.count >= 2,
           let query = parts[1].split(separator: "?").dropFirst().first {
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "agentPid", let pid = pid_t(kv[1]) {
                    return pid
                }
            }
        }
        for header in lines.dropFirst() {
            if header.isEmpty { break }  // end of headers
            guard let colon = header.firstIndex(of: ":") else { continue }
            guard header[..<colon].lowercased() == "x-phi-agent-pid" else { continue }
            let value = header[header.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            return pid_t(value)
        }
        return nil
    }

    /// App-issued bearer capability proving that this connection belongs to
    /// an already-established logical driver session. Kept in a dedicated
    /// header so stock Chromium simply ignores it on its own connections.
    private static func claimedAgentCapability(inRequestHead head: String) -> String? {
        for header in head.components(separatedBy: "\r\n").dropFirst() {
            if header.isEmpty { break }
            guard let colon = header.firstIndex(of: ":"),
                  header[..<colon].lowercased() == "x-phi-agent-capability" else {
                continue
            }
            let value = header[header.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard value.count >= 32, value.count <= 128,
                  value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
                return nil
            }
            return value
        }
        return nil
    }

    private static func hasAgentCapabilityHeader(inRequestHead head: String) -> Bool {
        head.components(separatedBy: "\r\n").dropFirst().contains { header in
            guard let colon = header.firstIndex(of: ":") else { return false }
            return header[..<colon].lowercased() == "x-phi-agent-capability"
        }
    }

    /// Returns true when `identity` may connect: a cached session grant, a
    /// remembered grant, or a fresh Allow from the consent prompt.
    private func evaluate(_ identity: AgentIdentity) -> Bool {
        grantsLock.lock()
        if sessionGrants.contains(identity.key) {
            grantsLock.unlock()
            return true
        }
        grantsLock.unlock()

        if PhiPreferences.AgentSpaces.rememberedAgentGrants.contains(identity.key) {
            grantsLock.lock(); sessionGrants.insert(identity.key); grantsLock.unlock()
            return true
        }

        switch promptForConsent(identity) {
        case .deny:
            return false
        case .allowOnce:
            grantsLock.lock(); sessionGrants.insert(identity.key); grantsLock.unlock()
            return true
        case .allowRemember:
            grantsLock.lock(); sessionGrants.insert(identity.key); grantsLock.unlock()
            var remembered = PhiPreferences.AgentSpaces.rememberedAgentGrants
            remembered.insert(identity.key)
            PhiPreferences.AgentSpaces.rememberedAgentGrants = remembered
            return true
        }
    }

    private enum ConsentDecision { case deny, allowOnce, allowRemember }

    private func promptForConsent(_ identity: AgentIdentity) -> ConsentDecision {
        var decision = ConsentDecision.deny
        DispatchQueue.main.sync {
            let alert = NSAlert()
            alert.messageText = String(
                format: NSLocalizedString("agentControl.connectionApproval.title", value: "“%@” wants to control Phi Browser",
                                          comment: "CDP consent - title"),
                identity.displayName)
            alert.informativeText = NSLocalizedString("agentControl.connectionApproval.message", value: "An agent is asking to drive Phi Browser over the DevTools Protocol — opening pages, reading content, and acting on your behalf. Only allow agents you trust.",
                comment: "CDP consent - body")
                + "\n\n" + identity.detail
            alert.addButton(withTitle: NSLocalizedString("agentControl.connectionApproval.allowOnceButton", value: "Allow Once", comment: "CDP consent - allow for this session"))
            alert.addButton(withTitle: NSLocalizedString("agentControl.connectionApproval.alwaysAllowButton", value: "Always Allow", comment: "CDP consent - allow and remember"))
            alert.addButton(withTitle: NSLocalizedString("agentControl.connectionApproval.denyButton", value: "Deny", comment: "CDP consent - deny"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: decision = .allowOnce
            case .alertSecondButtonReturn: decision = .allowRemember
            default: decision = .deny
            }
        }
        return decision
    }

    // MARK: - Helpers

    private struct SocketPaths {
        let socket: String
        let pointer: String
    }

    /// Stable per-bundle suffix (FNV-1a of the bundle id). `String.hashValue`
    /// is seeded per process, which moved the socket directory on every
    /// launch: the stale-socket unlink at start could never fire across
    /// launches, and crash-orphaned dirs accumulated in /tmp until reboot.
    private static func stableSuffix(_ s: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in s.utf8 { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
        return String(format: "%08x", hash)
    }

    /// The bound socket lives at a short `/tmp` path (bind() caps sun_path at
    /// ~104 bytes, mirroring SentinelIPCClient); the pointer file, which has no
    /// length limit, sits in the app-support dir where the skill looks for it.
    private static func resolveSocketPaths() -> SocketPaths? {
        let uid = getuid()
        let bundleId = FileSystemUtils.bundleId
        let hash = stableSuffix(bundleId)
        let dir = "/tmp/phi-cdp-\(uid).\(hash)"
        let socket = (dir as NSString).appendingPathComponent("agent.sock")
        guard socket.utf8.count < 104 else {
            AppLogError("[AgentCDP] socket path too long: \(socket)")
            return nil
        }
        let pointer = (FileSystemUtils.applicationSupportDirctory() as NSString)
            .appendingPathComponent("CDPAgentSocket")
        return SocketPaths(socket: socket, pointer: pointer)
    }

    /// Creates the socket's parent directory as a 0700, self-owned directory,
    /// refusing to proceed if an existing one is owned by someone else (a
    /// squatting attempt on the predictable `/tmp` path).
    private static func prepareSocketDirectory(for socketPath: String) -> Bool {
        let dir = (socketPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dir, isDirectory: &isDir) {
            var st = stat()
            if stat(dir, &st) == 0, st.st_uid != getuid() {
                AppLogError("[AgentCDP] socket dir \(dir) owned by uid \(st.st_uid); refusing")
                return false
            }
            return isDir.boolValue
        }
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            AppLogError("[AgentCDP] mkdir \(dir) failed: \(error)")
            return false
        }
    }

    /// Best-effort sweep of crash-orphaned socket dirs — including the
    /// per-launch-suffixed ones older builds left behind, which a crash
    /// stranded in /tmp until reboot. A sibling dir whose socket no longer
    /// accepts is dead weight; a live one (the other Phi flavor's channel)
    /// is left alone.
    private static func sweepOrphanedSocketDirs(keeping ownDir: String) {
        let prefix = "phi-cdp-\(getuid())."
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/tmp") else { return }
        for entry in entries where entry.hasPrefix(prefix) {
            let dir = "/tmp/" + entry
            guard dir != ownDir else { continue }
            let sock = (dir as NSString).appendingPathComponent("agent.sock")
            guard !socketAccepts(sock) else { continue }
            try? fm.removeItem(atPath: dir)
        }
    }

    /// connect(2) probe: a live listener accepts immediately; a
    /// crash-orphaned socket file refuses in ~0 ms.
    private static func socketAccepts(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        guard fillSunPath(&addr, with: path) else { return false }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, len)
            }
        }
        return rc == 0
    }

    private static func fillSunPath(_ addr: inout sockaddr_un, with path: String) -> Bool {
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= capacity else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: pathBytes.count)
                }
            }
        }
        return true
    }

    private static func bind(fd: Int32, to path: String) -> Bool {
        var addr = sockaddr_un()
        guard fillSunPath(&addr, with: path) else { return false }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len)
            }
        }
        if rc != 0 {
            AppLogError("[AgentCDP] bind() failed: \(String(cString: strerror(errno)))")
            return false
        }
        return true
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// Writes a short 403 so the skill's HTTP discovery gets a clear status,
    /// then closes. The fd is blocking-drained best-effort; denial is rare.
    private static func denyAndClose(_ fd: Int32) {
        let body = "Phi Browser denied agent access.\n"
        let response = "HTTP/1.1 403 Forbidden\r\n"
            + "Content-Type: text/plain\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
            + body
        let bytes = Array(response.utf8)
        bytes.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, raw.count)
        }
        close(fd)
    }
}

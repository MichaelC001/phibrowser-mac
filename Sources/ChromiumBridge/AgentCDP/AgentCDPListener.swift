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
    /// now, with no relaunch. Call from the Settings toggle.
    func setEnabled(_ enabled: Bool) {
        PhiPreferences.AgentSpaces.cdpAgentAccessEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
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

        let identity = AgentPeerIdentity.resolve(socketFD: fd)
            ?? AgentIdentity(key: "unknown", displayName: "Unknown process",
                             teamId: nil, verified: false, executablePath: "")

        guard evaluate(identity) else {
            AppLogInfo("[AgentCDP] denied access to \(identity.displayName)")
            Self.denyAndClose(fd)
            return
        }

        // Route by the (peeked, not consumed) request line: a `/phi-agent`
        // upgrade is an agentSpace.* channel served in the app; everything else
        // (/json, /devtools) is stock CDP handed to Chromium with the fd intact.
        if Self.peekIsPhiAgent(fd) {
            AgentDirectConnection(fd: fd).start()
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

    /// Peeks (without consuming) at the request line to detect the app-served
    /// `/phi-agent` WebSocket path. Non-consuming so a non-matching fd stays
    /// pristine for Chromium's HTTP server to read from the start.
    private static func peekIsPhiAgent(_ fd: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&pfd, 1, 2000)  // up to 2s for the request line to arrive
        var buf = [UInt8](repeating: 0, count: 256)
        let n = recv(fd, &buf, buf.count, Int32(MSG_PEEK))
        guard n > 0 else { return false }
        let text = String(decoding: buf[0..<n], as: UTF8.self)
        guard let line = text.split(separator: "\r\n", maxSplits: 1).first else {
            return false
        }
        return line.hasPrefix("GET /phi-agent")
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
                format: NSLocalizedString("“%@” wants to control Phi Browser",
                                          comment: "CDP consent - title"),
                identity.displayName)
            alert.informativeText = NSLocalizedString(
                "An agent is asking to drive Phi Browser over the DevTools Protocol — opening pages, reading content, and acting on your behalf. Only allow agents you trust.",
                comment: "CDP consent - body")
                + "\n\n" + identity.detail
            alert.addButton(withTitle: NSLocalizedString(
                "Allow Once", comment: "CDP consent - allow for this session"))
            alert.addButton(withTitle: NSLocalizedString(
                "Always Allow", comment: "CDP consent - allow and remember"))
            alert.addButton(withTitle: NSLocalizedString(
                "Deny", comment: "CDP consent - deny"))
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

    /// The bound socket lives at a short `/tmp` path (bind() caps sun_path at
    /// ~104 bytes, mirroring SentinelIPCClient); the pointer file, which has no
    /// length limit, sits in the app-support dir where the skill looks for it.
    private static func resolveSocketPaths() -> SocketPaths? {
        let uid = getuid()
        let bundleId = FileSystemUtils.bundleId
        let hash = String(format: "%08x", bundleId.hashValue & 0xFFFF_FFFF)
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

    private static func bind(fd: Int32, to path: String) -> Bool {
        var addr = sockaddr_un()
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

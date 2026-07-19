// Copyright 2026 Phinomenon Inc.
//
// Use of this source code is governed by an Apache license that can be
// found in the LICENSE file.

import CryptoKit
import Darwin
import Foundation

/// Direct Swift-side transport for `agentSpace.*` calls.
///
/// The management and lifecycle surface (Spaces, profiles, URL rules,
/// bookmarks, pinned tabs, ownership, ping, …) is owned entirely by the Mac
/// client — Chromium holds none of that state. Historically the skill still
/// reached it by tunnelling every message through Chromium's DevTools server
/// (the `PhiAgentSpace.sendMessage` CDP command), a needless hop out to
/// Chromium and back. Now that the app owns the CDP socket, an agent that
/// upgrades to `GET /phi-agent` is served here instead: frames are routed
/// straight into `ExtensionMessageRouter` (as sender "cdp", same as the
/// tunnel), and `agentSpace.*` broadcasts are pushed back over the same
/// socket. Page automation (stock CDP) still goes to Chromium untouched; the
/// tunnel remains only for the `--remote-debugging-port` developer override,
/// where the app owns no socket.
///
/// Wire protocol (JSON text frames):
///   request  → {"id": N, "type": "agentSpace.…", "payloadJson": "…"}
///   response ← {"id": N, "responseJson": "…"}  or  {"id": N, "error": "…"}
///   event    ← {"event": "agentSpace.…", "payloadJson": "…"}

/// Tracks live `/phi-agent` connections and routes app responses/broadcasts to
/// them. `ExtensionMessaging` consults this before falling back to the Chromium
/// bridge, so a response for a direct-channel request never leaves the app.
/// Thread-safe; methods are called from both connection queues and the main
/// thread.
final class AgentDirectChannelRegistry {
    static let shared = AgentDirectChannelRegistry()

    private struct Pending {
        let connectionId: String
        let clientId: Int
        let timeout: DispatchWorkItem
    }

    private let lock = NSLock()
    private var connections: [String: AgentDirectConnection] = [:]
    private var pending: [String: Pending] = [:]

    private init() {}

    var hasConnections: Bool {
        lock.lock(); defer { lock.unlock() }
        return !connections.isEmpty
    }

    func add(_ connection: AgentDirectConnection) {
        lock.lock(); connections[connection.id] = connection; lock.unlock()
    }

    func remove(_ connection: AgentDirectConnection) {
        lock.lock()
        connections[connection.id] = nil
        for (requestId, p) in pending where p.connectionId == connection.id {
            p.timeout.cancel()
            pending[requestId] = nil
        }
        lock.unlock()
    }

    func closeAll() {
        lock.lock()
        let conns = Array(connections.values)
        lock.unlock()
        for c in conns { c.close() }
    }

    /// Registers a request awaiting an async app reply, arming a timeout that
    /// fails it if the handler never responds.
    func registerPending(requestId: String, connectionId: String, clientId: Int) {
        let timeout = DispatchWorkItem { [weak self] in
            _ = self?.deliverError(requestId: requestId, error: "timed out")
        }
        lock.lock()
        pending[requestId] = Pending(connectionId: connectionId, clientId: clientId,
                                     timeout: timeout)
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
    }

    /// Delivers an app response to the originating direct connection. Returns
    /// false when `requestId` isn't ours, so `ExtensionMessaging` falls through
    /// to the Chromium bridge.
    @discardableResult
    func deliverResponse(requestId: String, response: String) -> Bool {
        deliver(requestId: requestId) { conn, clientId in
            conn.sendResult(clientId: clientId, responseJson: response)
        }
    }

    @discardableResult
    func deliverError(requestId: String, error: String) -> Bool {
        deliver(requestId: requestId) { conn, clientId in
            conn.sendError(clientId: clientId, error: error)
        }
    }

    private func deliver(requestId: String,
                         write: (AgentDirectConnection, Int) -> Void) -> Bool {
        lock.lock()
        guard let p = pending.removeValue(forKey: requestId) else {
            lock.unlock(); return false
        }
        p.timeout.cancel()
        let conn = connections[p.connectionId]
        lock.unlock()
        guard let conn else { return true }  // ours, but the client vanished
        write(conn, p.clientId)
        return true
    }

    /// Pushes an `agentSpace.*` broadcast to every live direct connection.
    func broadcast(type: String, payloadJson: String) {
        lock.lock(); let conns = Array(connections.values); lock.unlock()
        for c in conns { c.sendEvent(type: type, payloadJson: payloadJson) }
    }
}

/// One `/phi-agent` WebSocket connection: a minimal server-side RFC 6455
/// endpoint (the mirror of the skill's client codec) that decodes agent
/// requests and encodes responses/events. Owns its fd for its whole lifetime.
final class AgentDirectConnection {
    let id = UUID().uuidString

    private let fd: Int32
    /// The authenticated identity of the connecting code agent, forwarded to
    /// `agentSpace.create` so the Space it opens is badged with who drives it.
    private let agentName: String
    /// Pid of the resolved agent process, echoed back on the 101 upgrade
    /// (X-Phi-Agent-Pid) — the authoritative ancestry answer for a skill
    /// round that cannot walk its own (Codex's seatbelt denies the sysctls
    /// `ps` needs). The skill records it for its detached daemon and
    /// watchers to claim on later connections.
    private let agentPid: pid_t?
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    private var handshakeDone = false
    private var closed = false
    private var fragOpcode: UInt8 = 0
    private var fragData = Data()

    private static let wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    private static let maxFrameBytes = 8 * 1024 * 1024

    init(fd: Int32, agentName: String = "", agentPid: pid_t? = nil) {
        self.fd = fd
        self.agentName = agentName
        self.agentPid = agentPid
        self.queue = DispatchQueue(label: "com.phibrowser.cdp.direct.\(fd)")
    }

    func start() {
        AgentDirectChannelRegistry.shared.add(self)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.onReadable() }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            Darwin.close(self.fd)
        }
        readSource = source
        source.resume()
    }

    func close() {
        queue.async { [weak self] in self?.teardown() }
    }

    private func teardown() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        readSource = nil
        AgentDirectChannelRegistry.shared.remove(self)
    }

    // MARK: - Reading

    private func onReadable() {
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                continue
            }
            if n == 0 { teardown(); return }        // peer closed
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            if errno == EINTR { continue }
            teardown(); return
        }
        if !handshakeDone {
            guard processHandshake() else { return }
        }
        drainFrames()
    }

    /// Completes the WebSocket upgrade once the request headers have arrived.
    private func processHandshake() -> Bool {
        guard let headerEnd = range(of: "\r\n\r\n") else { return false }
        let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<headerEnd.upperBound)

        guard let key = Self.headerValue("Sec-WebSocket-Key", in: header) else {
            writeRaw("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
            teardown()
            return false
        }
        let accept = Self.acceptKey(for: key)
        let claim = agentPid.map { "X-Phi-Agent-Pid: \($0)\r\n" } ?? ""
        writeRaw(
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\nConnection: Upgrade\r\n" +
            claim +
            "Sec-WebSocket-Accept: \(accept)\r\n\r\n")
        handshakeDone = true
        return true
    }

    private func drainFrames() {
        while true {
            guard buffer.count >= 2 else { return }
            let b0 = buffer[buffer.startIndex]
            let b1 = buffer[buffer.startIndex + 1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0f
            let masked = (b1 & 0x80) != 0
            var len = Int(b1 & 0x7f)
            var offset = 2
            if len == 126 {
                guard buffer.count >= 4 else { return }
                len = Int(buffer[buffer.startIndex + 2]) << 8
                    | Int(buffer[buffer.startIndex + 3])
                offset = 4
            } else if len == 127 {
                guard buffer.count >= 10 else { return }
                var v = 0
                for i in 0..<8 { v = (v << 8) | Int(buffer[buffer.startIndex + 2 + i]) }
                len = v
                offset = 10
            }
            if len > Self.maxFrameBytes { teardown(); return }
            // Client frames MUST be masked (RFC 6455 §5.1).
            guard masked else { teardown(); return }
            guard buffer.count >= offset + 4 + len else { return }
            let maskStart = buffer.startIndex + offset
            let mask = Array(buffer[maskStart..<maskStart + 4])
            let payloadStart = maskStart + 4
            var payload = [UInt8](repeating: 0, count: len)
            for i in 0..<len {
                payload[i] = buffer[payloadStart + i] ^ mask[i & 3]
            }
            buffer.removeSubrange(buffer.startIndex..<(payloadStart + len))
            handleFrame(fin: fin, opcode: opcode, payload: payload)
        }
    }

    private func handleFrame(fin: Bool, opcode: UInt8, payload: [UInt8]) {
        switch opcode {
        case 0x8:                                   // close
            writeFrame(opcode: 0x8, payload: payload)
            teardown()
        case 0x9:                                   // ping -> pong
            writeFrame(opcode: 0xa, payload: payload)
        case 0xa:                                   // pong
            break
        case 0x0:                                   // continuation
            fragData.append(contentsOf: payload)
            if fin { dispatchMessage(opcode: fragOpcode, data: fragData); fragData = Data() }
        default:                                    // text (0x1) / binary (0x2)
            if fin {
                dispatchMessage(opcode: opcode, data: Data(payload))
            } else {
                fragOpcode = opcode
                fragData = Data(payload)
            }
        }
    }

    private func dispatchMessage(opcode: UInt8, data: Data) {
        guard opcode == 0x1 else { return }         // JSON is text only
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientId = obj["id"] as? Int,
              let type = obj["type"] as? String else { return }
        let payloadJson = obj["payloadJson"] as? String ?? "{}"
        DispatchQueue.main.async { [weak self] in
            self?.route(clientId: clientId, type: type, payloadJson: payloadJson)
        }
    }

    /// Main-thread: run the request through the same router the CDP tunnel uses,
    /// then reply synchronously or await the async app response.
    private func route(clientId: Int, type: String, payloadJson: String) {
        let requestId = "agentdirect:\(id):\(clientId)"
        AgentDirectChannelRegistry.shared.registerPending(
            requestId: requestId, connectionId: id, clientId: clientId)
        let sync = ExtensionMessageRouter.shared.handle(
            type: type, payload: payloadJson, requestId: requestId, senderId: "cdp",
            agentName: agentName)
        if let sync {
            AgentDirectChannelRegistry.shared.deliverResponse(
                requestId: requestId, response: sync)
        }
        // Otherwise the handler replies later via ExtensionMessaging, which
        // routes back through the registry (or the timeout fires).
    }

    // MARK: - Writing (any thread; serialized on `queue`)

    func sendResult(clientId: Int, responseJson: String) {
        let obj: [String: Any] = ["id": clientId, "responseJson": responseJson]
        sendJSON(obj)
    }

    func sendError(clientId: Int, error: String) {
        let obj: [String: Any] = ["id": clientId, "error": error]
        sendJSON(obj)
    }

    func sendEvent(type: String, payloadJson: String) {
        let obj: [String: Any] = ["event": type, "payloadJson": payloadJson]
        sendJSON(obj)
    }

    private func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        queue.async { [weak self] in
            self?.writeFrame(opcode: 0x1, payload: [UInt8](data))
        }
    }

    /// Server frames are never masked (RFC 6455 §5.1).
    private func writeFrame(opcode: UInt8, payload: [UInt8]) {
        guard !closed else { return }
        var frame = [UInt8]()
        frame.append(0x80 | opcode)
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len < 65536 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xff))
            frame.append(UInt8(len & 0xff))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xff))
            }
        }
        frame.append(contentsOf: payload)
        writeAll(frame)
    }

    private func writeRaw(_ text: String) {
        writeAll([UInt8](text.utf8))
    }

    private func writeAll(_ bytes: [UInt8]) {
        var offset = 0
        bytes.withUnsafeBytes { raw in
            while offset < bytes.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n > 0 { offset += n; continue }
                if n < 0 && errno == EINTR { continue }
                break  // EAGAIN on a full buffer or a dead socket: drop.
            }
        }
    }

    // MARK: - Buffer helpers

    private func range(of marker: String) -> Range<Data.Index>? {
        buffer.range(of: Data(marker.utf8))
    }

    private static func headerValue(_ name: String, in header: String) -> String? {
        for line in header.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame
            else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func acceptKey(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + wsGUID).utf8))
        return Data(digest).base64EncodedString()
    }
}

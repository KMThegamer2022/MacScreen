import Foundation
import Network
import CryptoKit

final class WSClient {
    let conn: NWConnection
    let id: Int
    var buf = Data()
    var upgraded = false
    var ready = false
    var mode = "h264"          // "h264" | "jpeg"
    var inflight = 0
    var waitKey = false
    var slot = 0               // which virtual display this receiver watches
    var assigned = false
    init(conn: NWConnection, id: Int) { self.conn = conn; self.id = id }
}

/// Tiny HTTP + WebSocket server (serves the receiver page and streams frames).
final class Server {
    let queue = DispatchQueue(label: "macscreen.server", qos: .userInteractive)
    private var listener: NWListener?
    private var clients: [Int: WSClient] = [:]
    private var nextID = 1

    var htmlProvider: () -> Data = { Data() }
    var infoProvider: () -> [String: Any] = { [:] }
    var onHello: ((WSClient, [String: Any]) -> Void)?
    var onClientGone: ((WSClient) -> Void)?
    var onMessage: ((WSClient, [String: Any]) -> Void)?
    var onClientsChanged: ((Int) -> Void)?
    var onNeedKey: ((Int) -> Void)?
    var onFailed: ((Error) -> Void)?

    private let countLock = NSLock()
    private var counts: [String: Int] = [:]     // "slot|mode" -> receivers
    private var perSlot: [Int: Int] = [:]

    func count(slot: Int, mode: String) -> Int { countLock.lock(); defer { countLock.unlock() }; return counts["\(slot)|\(mode)"] ?? 0 }
    func clientCount(slot: Int) -> Int { countLock.lock(); defer { countLock.unlock() }; return perSlot[slot] ?? 0 }
    var bytesSent: Int64 = 0

    private var tlsListener: NWListener?

    func start(port: UInt16, tlsPort: UInt16? = nil, identity: sec_identity_t? = nil) throws {
        listener = try makeListener(port: port, identity: nil, advertise: true)
        if let tlsPort, let identity {
            tlsListener = try makeListener(port: tlsPort, identity: identity, advertise: false)
        }
    }

    private func makeListener(port: UInt16, identity: sec_identity_t?, advertise: Bool) throws -> NWListener {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        var tls: NWProtocolTLS.Options?
        if let identity {
            let t = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(t.securityProtocolOptions, identity)
            tls = t
        }
        let params = NWParameters(tls: tls, tcp: tcp)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        if advertise { l.service = NWListener.Service(name: "MacScreen", type: "_http._tcp") }
        l.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st { self?.onFailed?(e) }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        return l
    }

    func stop() {
        listener?.cancel(); listener = nil
        tlsListener?.cancel(); tlsListener = nil
        queue.async {
            for c in self.clients.values { c.conn.cancel() }
            self.clients.removeAll()
            self.recount()
        }
    }

    // MARK: connections

    private func accept(_ conn: NWConnection) {
        let c = WSClient(conn: conn, id: nextID); nextID += 1
        clients[c.id] = c
        conn.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c else { return }
            switch st {
            case .failed, .cancelled: self.drop(c)
            default: break
            }
        }
        conn.start(queue: queue)
        receive(c)
    }

    private func drop(_ c: WSClient) {
        if clients.removeValue(forKey: c.id) != nil {
            recount()
            if c.assigned { c.assigned = false; onClientGone?(c) }
        }
    }

    /// Called once the session has chosen a display for this receiver.
    func activate(_ c: WSClient, slot: Int) {
        queue.async {
            c.slot = slot; c.assigned = true; c.ready = true
            self.recount()
        }
    }

    private func recount() {
        let ready = clients.values.filter { $0.upgraded && $0.ready }
        var c: [String: Int] = [:], p: [Int: Int] = [:]
        for r in ready { c["\(r.slot)|\(r.mode)", default: 0] += 1; p[r.slot, default: 0] += 1 }
        countLock.lock(); counts = c; perSlot = p; countLock.unlock()
        onClientsChanged?(ready.count)
    }

    private func receive(_ c: WSClient) {
        c.conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self, weak c] data, _, done, err in
            guard let self, let c else { return }
            if let data, !data.isEmpty {
                c.buf.append(data)
                self.process(c)
            }
            if err != nil || (done && data == nil) { c.conn.cancel(); self.drop(c); return }
            if c.conn.state != .cancelled { self.receive(c) }
        }
    }

    private func process(_ c: WSClient) {
        if !c.upgraded {
            guard let r = c.buf.range(of: Data("\r\n\r\n".utf8)) else { return }
            let head = String(decoding: c.buf[c.buf.startIndex..<r.lowerBound], as: UTF8.self)
            c.buf.removeSubrange(c.buf.startIndex..<r.upperBound)
            handleHTTP(c, head)
            if !c.upgraded { return }
        }
        parseFrames(c)
    }

    private func handleHTTP(_ c: WSClient, _ head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2 else { c.conn.cancel(); return }
        let path = String(parts[1]).components(separatedBy: "?")[0]
        var h: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                h[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        if h["upgrade"]?.lowercased() == "websocket", let key = h["sec-websocket-key"] {
            let acc = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acc)\r\n\r\n"
            c.upgraded = true
            c.conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
            return
        }
        switch path {
        case "/", "/index.html", "/receiver.html":
            respond(c, 200, "text/html; charset=utf-8", htmlProvider())
        case "/info":
            let d = (try? JSONSerialization.data(withJSONObject: infoProvider())) ?? Data()
            respond(c, 200, "application/json", d)
        default:
            respond(c, 404, "text/plain", Data("Not found".utf8))
        }
    }

    private func respond(_ c: WSClient, _ code: Int, _ type: String, _ body: Data) {
        let head = "HTTP/1.1 \(code) \(code == 200 ? "OK" : "Not Found")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var d = Data(head.utf8); d.append(body)
        c.conn.send(content: d, completion: .contentProcessed { [weak c] _ in c?.conn.cancel() })
    }

    // MARK: WebSocket framing

    private func parseFrames(_ c: WSClient) {
        while true {
            let b = [UInt8](c.buf.prefix(14))
            guard b.count >= 2 else { return }
            let opcode = b[0] & 0x0F
            let masked = b[1] & 0x80 != 0
            var len = Int(b[1] & 0x7F)
            var off = 2
            if len == 126 {
                guard b.count >= 4 else { return }
                len = Int(b[2]) << 8 | Int(b[3]); off = 4
            } else if len == 127 {
                guard b.count >= 10 else { return }
                len = 0; for i in 2..<10 { len = len << 8 | Int(b[i]) }; off = 10
            }
            var mask: [UInt8] = [0, 0, 0, 0]
            if masked {
                guard b.count >= off + 4 else { return }
                mask = Array(b[off..<off + 4]); off += 4
            }
            guard c.buf.count >= off + len else { return }
            var payload = [UInt8](c.buf.dropFirst(off).prefix(len))
            if masked { for i in 0..<payload.count { payload[i] ^= mask[i & 3] } }
            c.buf.removeFirst(off + len)

            switch opcode {
            case 0x1:
                if let j = (try? JSONSerialization.jsonObject(with: Data(payload))) as? [String: Any] { message(c, j) }
            case 0x8:
                c.conn.cancel(); drop(c); return
            case 0x9:
                c.conn.send(content: Self.frame(0xA, Data(payload)), completion: .contentProcessed { _ in })
            default: break
            }
        }
    }

    private func message(_ c: WSClient, _ j: [String: Any]) {
        switch j["t"] as? String {
        case "hello":
            c.mode = (j["webcodecs"] as? Bool ?? false) ? "h264" : "jpeg"
            c.waitKey = c.mode == "h264"
            onHello?(c, j)       // session picks a display, then calls activate()
        case "ping":
            sendText(c, ["t": "pong", "ts": j["ts"] ?? 0])
        case "key":
            c.waitKey = true
            onNeedKey?(c.slot)
        default:
            onMessage?(c, j)
        }
    }

    static func frame(_ opcode: UInt8, _ payload: Data) -> Data {
        var d = Data([0x80 | opcode])
        let n = payload.count
        if n < 126 { d.append(UInt8(n)) }
        else if n < 65536 { d.append(126); d.append(UInt8(n >> 8)); d.append(UInt8(n & 0xFF)) }
        else { d.append(127); for i in (0..<8).reversed() { d.append(UInt8((n >> (8 * i)) & 0xFF)) } }
        d.append(payload)
        return d
    }

    // MARK: sending (call from any thread)

    func sendText(_ c: WSClient, _ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        queue.async { c.conn.send(content: Self.frame(0x1, d), completion: .contentProcessed { _ in }) }
    }

    func broadcastText(_ obj: [String: Any], slot: Int? = nil, mode: String? = nil) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        queue.async {
            let f = Self.frame(0x1, d)
            for c in self.clients.values where c.upgraded && c.ready && (slot == nil || c.slot == slot) && (mode == nil || c.mode == mode) {
                c.conn.send(content: f, completion: .contentProcessed { _ in })
            }
        }
    }

    /// type: 1 = h264 key, 2 = h264 delta, 3 = jpeg
    func sendVideo(slot: Int, type: UInt8, payload: Data, isKey: Bool, mode: String) {
        let ts = UInt64(DispatchTime.now().uptimeNanoseconds / 1000)
        var body = Data(capacity: payload.count + 9)
        body.append(type)
        for i in (0..<8).reversed() { body.append(UInt8((ts >> (8 * UInt64(i))) & 0xFF)) }
        body.append(payload)
        let f = Self.frame(0x2, body)
        queue.async {
            for c in self.clients.values where c.upgraded && c.ready && c.slot == slot && c.mode == mode {
                if c.waitKey {
                    if isKey { c.waitKey = false } else { continue }
                }
                let limit = isKey ? 8 : 3
                if mode == "h264", c.inflight > limit {
                    if !c.waitKey { c.waitKey = true; self.onNeedKey?(slot) }
                    continue
                }
                if mode == "jpeg", c.inflight > 2 { continue }
                c.inflight += 1
                self.bytesSent += Int64(f.count)
                c.conn.send(content: f, completion: .contentProcessed { [weak c] _ in c?.inflight -= 1 })
            }
        }
    }
}

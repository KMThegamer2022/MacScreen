import Foundation
import CoreGraphics
import CVD
import Darwin
import ServiceManagement
import CoreVideo

struct StreamSettings: Codable, Equatable {
    var width = 1920
    var height = 1080
    var fps = 60
    var bitrateMbps = 15
    var hiDPI = false
    var port = 8765
    var matchReceiver = true
    var autoStartServer = false

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1920
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1080
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? 60
        bitrateMbps = try c.decodeIfPresent(Int.self, forKey: .bitrateMbps) ?? 15
        hiDPI = try c.decodeIfPresent(Bool.self, forKey: .hiDPI) ?? false
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 8765
        matchReceiver = try c.decodeIfPresent(Bool.self, forKey: .matchReceiver) ?? true
        autoStartServer = try c.decodeIfPresent(Bool.self, forKey: .autoStartServer) ?? false
    }
}

struct AddressInfo: Identifiable {
    let id = UUID()
    let label: String
    let url: String
}

struct SlotInfo: Identifiable {
    let id: Int
    var width: Int
    var height: Int
    var clients: Int
}

func log(_ s: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(s)\n"
    FileHandle.standardError.write(Data(line.utf8))
    let p = NSHomeDirectory() + "/Library/Logs/MacScreen.log"
    if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { FileManager.default.createFile(atPath: p, contents: Data(line.utf8)) }
}

/// One virtual display with its own capture, encoder, input mapping and receivers.
final class DisplaySlot {
    let id: Int
    var size: (w: Int, h: Int)
    var vd: MSVirtualDisplay?
    let capture = ScreenCapture()
    let input = InputInjector()
    let jpeg = JPEGEncoder()
    // pipeline state — only touched on Session.q
    var h264: H264Encoder?
    var lastPB: CVPixelBuffer?
    var currentCodec: String?
    var lastForce = Date.distantPast
    var outCount = 0
    // main-thread state
    var members = Set<Int>()           // WSClient ids
    var reconfiguring = false
    var pendingView: (Int, Int)?
    var lastReconfig = Date.distantPast
    var teardownWork: DispatchWorkItem?
    var capturing = false

    init(id: Int, size: (Int, Int)) { self.id = id; self.size = (size.0, size.1) }
}

final class Session: ObservableObject {
    static let maxDisplays = 4

    @Published var settings: StreamSettings { didSet { save() } }
    @Published var running = false
    @Published var starting = false
    @Published var status = "Stopped"
    @Published var clients = 0
    @Published var addresses: [AddressInfo] = []
    @Published var slotInfos: [SlotInfo] = []
    @Published var screenOK = CGPreflightScreenCaptureAccess()
    @Published var accessOK = InputInjector.trusted
    @Published var fpsOut = 0
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginNote = ""

    func refreshLoginItem() {
        let st = SMAppService.mainApp.status
        launchAtLogin = st == .enabled
        loginNote = st == .requiresApproval ? "Approve MacScreen in System Settings → General → Login Items." : ""
        if !launchAtLogin && settings.autoStartServer { settings.autoStartServer = false }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log("login item error: \(error)")
            loginNote = "Couldn't change login item: \(error.localizedDescription)"
        }
        refreshLoginItem()
        if on && SMAppService.mainApp.status == .requiresApproval { loginNote = "Approve MacScreen in System Settings → General → Login Items." }
    }

    /// Start streaming at launch only when both toggles are on.
    var shouldAutoStart: Bool { settings.autoStartServer && launchAtLogin }

    let server = Server()
    private let q = DispatchQueue(label: "macscreen.pipeline", qos: .userInteractive)
    private let slotLock = NSLock()
    private var _slots: [Int: DisplaySlot] = [:]
    private var sidMap: [String: Int] = [:]             // receiver session id -> display slot
    private var assignQueue: [(WSClient, [String: Any])] = []
    private var assigning = false
    private var clientSlot: [Int: Int] = [:]            // WSClient id -> slot (main only)
    private var statTimer: Timer?
    private var httpsOn = false

    init() {
        if let d = UserDefaults.standard.data(forKey: "settings"),
           let s = try? JSONDecoder().decode(StreamSettings.self, from: d) { settings = s }
        else { settings = StreamSettings() }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "settings") }
    }

    func refreshPermissions() {
        screenOK = CGPreflightScreenCaptureAccess()
        accessOK = InputInjector.trusted
    }

    // thread-safe slot table
    private func slot(_ id: Int) -> DisplaySlot? { slotLock.lock(); defer { slotLock.unlock() }; return _slots[id] }
    private func allSlots() -> [DisplaySlot] {
        slotLock.lock(); defer { slotLock.unlock() }
        return _slots.values.sorted { $0.id < $1.id }
    }
    private func setSlot(_ s: DisplaySlot?, id: Int) { slotLock.lock(); _slots[id] = s; slotLock.unlock() }

    // MARK: start / stop

    func start() {
        guard !running, !starting else { return }
        starting = true
        status = "Starting…"
        let s = settings
        Task { @MainActor in
            do {
                if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
                if !InputInjector.trusted { InputInjector.requestTrust() }
                wireServer()
                let ips = Self.localAddresses(port: s.port).compactMap { URL(string: $0.url)?.host }.filter { !$0.hasSuffix(".local") }
                let ident = TLSIdentity.load(ips: ips, host: ProcessInfo.processInfo.hostName)
                if ident == nil { log("TLS identity unavailable; HTTP only") }
                try server.start(port: UInt16(s.port), tlsPort: UInt16(s.port + 1), identity: ident)
                httpsOn = ident != nil
                addresses = (httpsOn ? Self.localAddresses(port: s.port + 1, scheme: "https") : []) + Self.localAddresses(port: s.port)
                running = true
                starting = false
                status = "Running — a virtual display is created for each device that connects"
                startStats()
                log("running; urls=\(addresses.map { $0.url })")
            } catch {
                log("start failed: \(error)")
                await teardown()
                starting = false
                status = "Failed: \(error.localizedDescription)"
            }
            refreshPermissions()
        }
    }

    func stop() {
        Task { @MainActor in await teardown(); status = "Stopped" }
    }

    @MainActor func teardown() async {
        statTimer?.invalidate(); statTimer = nil
        server.stop()
        for s in allSlots() { await teardownSlot(s) }
        sidMap.removeAll(); clientSlot.removeAll(); assignQueue.removeAll(); assigning = false
        running = false
        clients = 0
        fpsOut = 0
        slotInfos = []
    }

    @MainActor private func teardownSlot(_ s: DisplaySlot) async {
        s.teardownWork?.cancel()
        s.capture.onFrame = nil
        await s.capture.stop()
        q.sync { s.h264?.invalidate(); s.h264 = nil; s.lastPB = nil; s.currentCodec = nil }
        s.vd = nil                       // releasing the object removes the virtual display
        setSlot(nil, id: s.id)
        sidMap = sidMap.filter { $0.value != s.id }
        refreshSlotInfos()
        log("slot \(s.id) removed")
    }

    private func startStats() {
        statTimer?.invalidate()
        statTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.q.async {
                var n = 0
                for s in self.allSlots() { n += s.outCount; s.outCount = 0 }
                DispatchQueue.main.async { self.fpsOut = n }
            }
        }
    }

    @MainActor private func refreshSlotInfos() {
        slotInfos = allSlots().map { SlotInfo(id: $0.id, width: $0.size.w, height: $0.size.h, clients: $0.members.count) }
    }

    // MARK: server wiring

    private func infoMsg(_ s: DisplaySlot, mode: String? = nil) -> [String: Any] {
        var m: [String: Any] = ["t": "info", "screen": s.id, "width": s.size.w, "height": s.size.h,
                                "fps": settings.fps, "bitrate": settings.bitrateMbps]
        if let mode { m["mode"] = mode }
        return m
    }

    private func wireServer() {
        server.htmlProvider = { Self.loadHTML() }
        server.infoProvider = { [weak self] in
            guard let self else { return [:] }
            let slots = self.allSlots()
            return ["app": "MacScreen", "accessibility": InputInjector.trusted,
                    "bytesSent": self.server.bytesSent, "fps": self.settings.fps,
                    "clients": slots.reduce(0) { $0 + self.server.clientCount(slot: $1.id) },
                    "captured": slots.reduce(0) { $0 + $1.capture.frames },
                    "inputEvents": slots.reduce(0) { $0 + $1.input.eventsPosted },
                    "slots": slots.map { ["id": $0.id, "width": $0.size.w, "height": $0.size.h,
                                          "displayID": Int($0.input.displayID),
                                          "clients": self.server.clientCount(slot: $0.id),
                                          "captured": $0.capture.frames, "inputEvents": $0.input.eventsPosted] }]
        }
        server.onClientsChanged = { [weak self] n in DispatchQueue.main.async { self?.clients = n } }
        server.onHello = { [weak self] c, j in
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.assignQueue.append((c, j)); self.drainAssign()
            }
        }
        server.onClientGone = { [weak self] c in DispatchQueue.main.async { self?.clientGone(c) } }
        server.onNeedKey = { [weak self] slotID in
            self?.q.async { if let s = self?.slot(slotID) { self?.forceKey(s) } }
        }
        server.onMessage = { [weak self] c, j in
            guard let self, let s = self.slot(c.slot) else { return }
            switch j["t"] as? String {
            case "cfg": self.applyCfg(j)
            case "view": self.considerView(s, j)
            default: s.input.handle(j)
            }
        }
        server.onFailed = { [weak self] e in
            DispatchQueue.main.async { self?.status = "Server error: \(e.localizedDescription)" }
        }
    }

    // MARK: assigning receivers to displays (automatic)

    private func drainAssign() {
        guard !assigning, !assignQueue.isEmpty else { return }
        assigning = true
        let (c, j) = assignQueue.removeFirst()
        Task { @MainActor in
            await assign(c, j)
            assigning = false
            drainAssign()
        }
    }

    @MainActor private func assign(_ c: WSClient, _ j: [String: Any]) async {
        let sid = j["sid"] as? String ?? ""
        let wanted = (j["screen"] as? NSNumber)?.intValue
        let vw = (j["vw"] as? NSNumber)?.intValue ?? 0, vh = (j["vh"] as? NSNumber)?.intValue ?? 0
        var target: DisplaySlot?
        var createID: Int?

        if let w = wanted, (1...Self.maxDisplays).contains(w) {                       // explicit: share a display
            target = slot(w); if target == nil { createID = w }
        } else if !sid.isEmpty, let id = sidMap[sid], let s = slot(id) {              // same tab reconnecting
            target = s
        } else if let idle = allSlots().first(where: { $0.members.isEmpty }) {        // reuse an unused display
            target = idle
        } else if let free = (1...Self.maxDisplays).first(where: { slot($0) == nil }) { // brand-new display
            createID = free
        } else {                                                                        // all busy: share the quietest
            target = allSlots().min { $0.members.count < $1.members.count }
        }

        if target == nil, let id = createID {
            let size = settings.matchReceiver && vw > 0
                ? Self.fit(viewW: vw, viewH: vh, maxLong: max(settings.width, settings.height))
                : (settings.width, settings.height)
            do {
                target = try await createSlot(id: id, size: size)
            } catch {
                log("slot \(id) create failed: \(error)")
                status = "Couldn't create display: \(error.localizedDescription)"
                server.sendText(c, ["t": "error", "msg": "Mac couldn't create a display: \(error.localizedDescription)"])
                return
            }
        }
        guard let s = target else { return }

        s.teardownWork?.cancel(); s.teardownWork = nil
        s.members.insert(c.id)
        clientSlot[c.id] = s.id
        if !sid.isEmpty { sidMap[sid] = s.id }
        refreshSlotInfos()
        server.activate(c, slot: s.id)
        server.sendText(c, infoMsg(s, mode: c.mode))
        q.async {
            if c.mode == "h264" {
                if let codec = s.currentCodec { self.server.sendText(c, ["t": "config", "codec": codec]) }
                self.forceKey(s)
            } else if let pb = s.lastPB {
                self.encodeJPEG(s, pb)
            }
        }
        log("client \(c.id) (\(c.mode)) -> screen \(s.id) [\(s.size.w)x\(s.size.h)]")
        considerView(s, j)
    }

    @MainActor private func createSlot(id: Int, size: (Int, Int)) async throws -> DisplaySlot {
        guard let v = MSVirtualDisplay.create(withName: id == 1 ? "MacScreen" : "MacScreen \(id)", serial: UInt32(id),
                                              width: UInt32(size.0), height: UInt32(size.1),
                                              hiDPI: settings.hiDPI, refreshRate: Double(settings.fps)) else {
            throw NSError(domain: "MacScreen", code: 2, userInfo: [NSLocalizedDescriptionKey: "macOS refused to create the virtual display"])
        }
        let s = DisplaySlot(id: id, size: size)
        s.vd = v
        s.input.displayID = v.displayID
        log("screen \(id): virtual display \(v.displayID) \(size.0)x\(size.1)")
        s.capture.onStop = { [weak self, weak s] e in
            guard let s else { return }
            log("screen \(s.id) capture stopped: \(e.localizedDescription)")
            DispatchQueue.main.async { Task { @MainActor in await self?.recoverCapture(s) } }
        }
        do {
            try await s.capture.start(displayID: v.displayID, width: size.0, height: size.1, fps: settings.fps)
        } catch {
            s.vd = nil
            throw error
        }
        s.capturing = true
        s.capture.onFrame = { [weak self, weak s] pb in
            guard let s else { return }
            self?.q.async { self?.handleFrame(s, pb) }
        }
        setSlot(s, id: id)
        refreshSlotInfos()
        return s
    }

    /// (Re)start capture for a slot's current display and size.
    @MainActor private func startCapture(_ s: DisplaySlot) async {
        guard let v = s.vd else { return }
        do {
            try await s.capture.start(displayID: v.displayID, width: s.size.w, height: s.size.h, fps: settings.fps)
            s.capturing = true
            s.capture.onFrame = { [weak self, weak s] pb in
                guard let s else { return }
                self?.q.async { self?.handleFrame(s, pb) }
            }
        } catch {
            status = "Capture failed for screen \(s.id): \(error.localizedDescription)"
            log("startCapture failed: \(error)")
        }
    }

    /// A stream died on its own (e.g. display topology changed) — bring it back.
    @MainActor private func recoverCapture(_ s: DisplaySlot) async {
        guard running, slot(s.id) === s, s.capturing, !s.reconfiguring else { return }
        s.capturing = false
        s.capture.onFrame = nil
        await s.capture.stop()
        for attempt in 1...4 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard running, slot(s.id) === s else { return }
            log("screen \(s.id) restarting capture (attempt \(attempt))")
            await startCapture(s)
            if s.capturing { q.async { self.forceKey(s) }; return }
        }
    }

    @MainActor private func clientGone(_ c: WSClient) {
        guard let id = clientSlot.removeValue(forKey: c.id), let s = slot(id) else { return }
        s.members.remove(c.id)
        refreshSlotInfos()
        if s.members.isEmpty {
            q.async { s.input.releaseAll() }
            // keep the display briefly so a refresh / reconnect gets the same screen back
            let w = DispatchWorkItem { [weak self, weak s] in
                guard let self, let s, s.members.isEmpty, self.running else { return }
                Task { @MainActor in await self.teardownSlot(s) }
            }
            s.teardownWork?.cancel()
            s.teardownWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: w)
        }
    }

    private func applyCfg(_ j: [String: Any]) {
        DispatchQueue.main.async {
            var s = self.settings
            if let b = j["bitrate"] as? Int { s.bitrateMbps = min(max(b, 1), 80) }
            if let f = j["fps"] as? Int, [24, 30, 45, 60].contains(f) { s.fps = f }
            guard s != self.settings else { return }
            let fpsChanged = s.fps != self.settings.fps
            self.settings = s
            for d in self.allSlots() {
                self.q.async { d.h264?.invalidate(); d.h264 = nil; self.forceKey(d) }
                if fpsChanged { d.capture.updateFPS(s.fps, width: d.size.w, height: d.size.h) }
            }
        }
    }

    // MARK: match the receiver's viewport (per display)

    /// Aspect-correct size for a viewport (device pixels), capped to the chosen max long edge.
    static func fit(viewW: Int, viewH: Int, maxLong: Int) -> (Int, Int) {
        guard viewW > 0, viewH > 0 else { return (maxLong, maxLong * 9 / 16) }
        var w = Double(viewW), h = Double(viewH)
        let long = max(w, h)
        let k = long > Double(maxLong) ? Double(maxLong) / long : 1
        w *= k; h *= k
        let minShort = 540.0
        let short = min(w, h)
        if short < minShort { let k2 = minShort / short; w *= k2; h *= k2 }
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return (even(w), even(h))
    }

    private func considerView(_ s: DisplaySlot, _ j: [String: Any]) {
        guard settings.matchReceiver, running,
              let vw = (j["vw"] as? NSNumber)?.intValue, let vh = (j["vh"] as? NSNumber)?.intValue,
              vw > 0, vh > 0 else { return }
        let t = Self.fit(viewW: vw, viewH: vh, maxLong: max(settings.width, settings.height))
        DispatchQueue.main.async {
            if abs(t.0 - s.size.w) <= 16 && abs(t.1 - s.size.h) <= 16 { return }
            s.pendingView = t
            self.drainReconfigure(s)
        }
    }

    private func drainReconfigure(_ s: DisplaySlot) {
        guard !s.reconfiguring, let t = s.pendingView else { return }
        let wait = max(0, 1.5 - Date().timeIntervalSince(s.lastReconfig))
        s.reconfiguring = true
        s.pendingView = nil
        Task { @MainActor in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            let target = s.pendingView ?? t      // newest request wins
            s.pendingView = nil
            await reconfigure(s, width: target.0, height: target.1)
            s.lastReconfig = Date()
            s.reconfiguring = false
            if s.pendingView != nil { drainReconfigure(s) }
        }
    }

    @MainActor private func reconfigure(_ s: DisplaySlot, width: Int, height: Int) async {
        guard running, slot(s.id) === s, width != s.size.w || height != s.size.h else { return }
        log("screen \(s.id) reconfigure \(s.size.w)x\(s.size.h) -> \(width)x\(height)")
        guard let v = s.vd else { return }
        s.capture.onFrame = nil
        s.capturing = false
        await s.capture.stop()
        q.sync { s.h264?.invalidate(); s.h264 = nil; s.lastPB = nil; s.currentCodec = nil }
        // change the mode in place: same display ID, other displays are not disturbed
        guard v.resize(toWidth: UInt32(width), height: UInt32(height), hiDPI: settings.hiDPI, refreshRate: Double(settings.fps)) else {
            status = "Failed to resize virtual display \(s.id)"; log("reconfigure: resize failed"); return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        s.size = (width, height)
        await startCapture(s)
        server.broadcastText(infoMsg(s), slot: s.id)
        refreshSlotInfos()
    }

    // MARK: frame pipeline (runs on `q`)

    private func handleFrame(_ s: DisplaySlot, _ pb: CVPixelBuffer) {
        s.lastPB = pb
        s.outCount += 1
        if server.count(slot: s.id, mode: "h264") > 0 { encodeH264(s, pb, force: false) }
        if server.count(slot: s.id, mode: "jpeg") > 0 { encodeJPEG(s, pb) }
    }

    private func forceKey(_ s: DisplaySlot) {
        guard Date().timeIntervalSince(s.lastForce) > 0.12, let pb = s.lastPB,
              server.count(slot: s.id, mode: "h264") > 0 else { return }
        s.lastForce = Date()
        encodeH264(s, pb, force: true)
    }

    private func encodeH264(_ s: DisplaySlot, _ pb: CVPixelBuffer, force: Bool) {
        if s.h264 == nil {
            let cfg = settings
            guard let e = H264Encoder(width: s.size.w, height: s.size.h, fps: cfg.fps, bitrateMbps: cfg.bitrateMbps) else {
                log("H264 encoder creation failed"); return
            }
            e.onFrame = { [weak self, weak s] data, isKey, codec in
                guard let self, let s else { return }
                if let codec, codec != s.currentCodec {
                    s.currentCodec = codec
                    self.server.broadcastText(["t": "config", "codec": codec], slot: s.id, mode: "h264")
                }
                self.server.sendVideo(slot: s.id, type: isKey ? 1 : 2, payload: data, isKey: isKey, mode: "h264")
            }
            s.h264 = e
            log("screen \(s.id) H264 encoder ready \(s.size.w)x\(s.size.h) @\(cfg.fps) \(cfg.bitrateMbps)Mbps")
        }
        s.h264?.encode(pb, forceKey: force)
    }

    private func encodeJPEG(_ s: DisplaySlot, _ pb: CVPixelBuffer) {
        if let d = s.jpeg.encode(pb) { server.sendVideo(slot: s.id, type: 3, payload: d, isKey: true, mode: "jpeg") }
    }

    // MARK: helpers

    static func loadHTML() -> Data {
        let candidates = [
            Bundle.main.resourcePath.map { $0 + "/receiver.html" },
            FileManager.default.currentDirectoryPath + "/web/receiver.html",
        ].compactMap { $0 }
        for p in candidates { if let d = FileManager.default.contents(atPath: p) { return d } }
        return Data("<h1>receiver.html missing</h1>".utf8)
    }

    static func localAddresses(port: Int, scheme: String = "http") -> [AddressInfo] {
        var out: [AddressInfo] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return out }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let f = p.pointee
            guard let sa = f.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  Int32(f.ifa_flags) & IFF_UP != 0, Int32(f.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            let name = String(cString: f.ifa_name)
            if name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("ap") { continue }
            var kind = "Network"
            if ip.hasPrefix("169.254.") { kind = "Direct cable / link-local" }
            else if name == "en0" { kind = "Wi-Fi / main network" }
            else if name.hasPrefix("bridge") { kind = "Thunderbolt/USB bridge" }
            else { kind = "Wired / USB adapter" }
            out.append(AddressInfo(label: "\(kind) (\(name))" + (scheme == "https" ? " — recommended (smooth H.264)" : " — fallback"),
                                   url: "\(scheme)://\(ip):\(port)"))
        }
        let host = ProcessInfo.processInfo.hostName
        if host.hasSuffix(".local") {
            out.append(AddressInfo(label: "Bonjour name" + (scheme == "https" ? " — recommended" : " — fallback"),
                                   url: "\(scheme)://\(host):\(port)"))
        }
        return out
    }
}

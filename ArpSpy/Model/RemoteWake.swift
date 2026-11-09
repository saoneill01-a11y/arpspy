import Foundation
import AppKit
import Darwin

/// A PC on another network (usually through a VPN) that we can send Wake-on-LAN to.
struct RemoteWakeTarget: Codable, Identifiable, Hashable {
    var id = UUID()
    var name = ""
    var site = ""
    var mac = ""
    var ip = ""
    var prefix = 24
    var sendToIP = true
    var sendToBroadcast = true
    var useRelay = false
    var relay = ""
    var port = 9
    var checkAfter = true

    init() {}

    /// Reads saved entries field by field, so files from older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RemoteWakeTarget()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        site = try c.decodeIfPresent(String.self, forKey: .site) ?? d.site
        mac = try c.decodeIfPresent(String.self, forKey: .mac) ?? d.mac
        ip = try c.decodeIfPresent(String.self, forKey: .ip) ?? d.ip
        prefix = try c.decodeIfPresent(Int.self, forKey: .prefix) ?? d.prefix
        sendToIP = try c.decodeIfPresent(Bool.self, forKey: .sendToIP) ?? d.sendToIP
        sendToBroadcast = try c.decodeIfPresent(Bool.self, forKey: .sendToBroadcast) ?? d.sendToBroadcast
        useRelay = try c.decodeIfPresent(Bool.self, forKey: .useRelay) ?? d.useRelay
        relay = try c.decodeIfPresent(String.self, forKey: .relay) ?? d.relay
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? d.port
        checkAfter = try c.decodeIfPresent(Bool.self, forKey: .checkAfter) ?? d.checkAfter
    }

    var displayName: String { name.isEmpty ? (ip.isEmpty ? "New PC" : ip) : name }
    var subtitle: String { [site, ip].filter { !$0.isEmpty }.joined(separator: " · ") }
}

/// Sending Wake-on-LAN to a PC that isn't on this Mac's LAN.
/// The packets are ordinary UDP, so macOS routes them through whichever VPN reaches that address.
enum RemoteWake {
    enum Failure: LocalizedError {
        case badMAC, badIP, badPrefix, badRelay, badPort, nothingToSend
        case sendFailed(String, String)
        var errorDescription: String? {
            switch self {
            case .badMAC: return "The MAC address isn’t valid. Paste it in any format, like 3C-52-82-1A-7E-09 or 3c52821a7e09."
            case .badIP: return "The PC’s IP address isn’t valid."
            case .badPrefix: return "The subnet must be a number from 8 to 30 (24 means 255.255.255.0)."
            case .badRelay: return "The relay address isn’t a valid IP address."
            case .badPort: return "The UDP port must be a number from 1 to 65535."
            case .nothingToSend: return "Tick at least one “Send to” option."
            case .sendFailed(let ip, let why): return "Couldn’t send to \(ip): \(why). Is the VPN to that site connected?"
            }
        }
    }

    static let rounds = 3

    /// Accepts any common MAC format (colons, dashes, dots, none) and returns "3C:52:82:1A:7E:09".
    static func normalizeMAC(_ text: String) -> String? {
        let hex = text.uppercased().filter { $0.isHexDigit }
        guard hex.count == 12, text.filter({ $0.isLetter && !$0.isHexDigit }).isEmpty else { return nil }
        var parts: [String] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            parts.append(String(hex[i..<j])); i = j
        }
        return parts.joined(separator: ":")
    }

    /// 10.20.30.45 /24 → 10.20.30.255. Nil for /31 and /32, which have no broadcast address.
    static func broadcast(of ip: IPv4, prefix: Int) -> IPv4? {
        guard (8...30).contains(prefix) else { return nil }
        let mask: UInt32 = ~UInt32(0) << UInt32(32 - prefix)
        return IPv4(ip.value | ~mask)
    }

    /// Where the packets go, in order, with duplicates removed.
    static func destinations(for t: RemoteWakeTarget) throws -> [IPv4] {
        guard let ip = IPv4(t.ip) else { throw Failure.badIP }
        var out: [IPv4] = []
        if t.sendToIP { out.append(ip) }
        if t.sendToBroadcast {
            guard let b = broadcast(of: ip, prefix: t.prefix) else { throw Failure.badPrefix }
            out.append(b)
        }
        if t.useRelay {
            guard let r = IPv4(t.relay) else { throw Failure.badRelay }
            out.append(r)
        }
        var seen = Set<UInt32>()
        out = out.filter { seen.insert($0.value).inserted }
        guard !out.isEmpty else { throw Failure.nothingToSend }
        return out
    }

    /// 6 × FF, then the MAC 16 times.
    static func magicPacket(_ mac: [UInt8]) -> [UInt8] {
        [UInt8](repeating: 0xFF, count: 6) + Array((0..<16).map { _ in mac }.joined())
    }

    /// Sends the magic packet `rounds` times to every destination. Returns the destinations.
    @discardableResult
    static func send(_ t: RemoteWakeTarget) throws -> [IPv4] {
        guard let macText = normalizeMAC(t.mac), let mac = DeviceActions.macBytes(macText) else { throw Failure.badMAC }
        guard (1...65535).contains(t.port) else { throw Failure.badPort }
        let dests = try destinations(for: t)

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure.sendFailed(dests[0].description, String(cString: strerror(errno))) }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))

        let packet = magicPacket(mac)
        for round in 0..<rounds {
            for d in dests where Sockets.send(fd, packet, to: d.value, port: UInt16(t.port)) < 0 {
                throw Failure.sendFailed(d.description, String(cString: strerror(errno)))
            }
            if round < rounds - 1 { usleep(150_000) }
        }
        return dests
    }

    /// Ports a woken Windows/Mac/Linux PC usually has open. Windows blocks ping by default,
    /// so an open port also counts as "awake". Only open ports count: a refused connection
    /// can come from a firewall on the way.
    static let awakePorts: [UInt16] = [3389, 445, 135, 22, 5900, 80]

    static func isAwake(_ ip: IPv4) -> Bool {
        let flag = CancelFlag()
        if !Pinger.sweep([ip], timeout: 1.5, flag: flag).isEmpty { return true }
        return !(TCPProbe.openPorts([ip], ports: awakePorts, timeout: 1.5, flag: flag).isEmpty)
    }
}

/// The saved list of remote PCs and what's happening with each one.
/// Saved to ~/Library/Application Support/ArpSpy/remote-wake.json.
@MainActor
final class RemoteWakeStore: ObservableObject {
    static let shared = RemoteWakeStore()

    enum State { case sending, waiting, awake, noAnswer, sent, failed }
    struct Status { var state: State; var headline: String; var lines: [String] }

    @Published var targets: [RemoteWakeTarget] = [] { didSet { scheduleSave() } }
    @Published var selection = Set<UUID>()
    @Published private(set) var statuses: [UUID: Status] = [:]
    private var checks: [UUID: Task<Void, Never>] = [:]
    private var saveTask: Task<Void, Never>?
    private var quitObserver: NSObjectProtocol?

    static let checkSeconds = 120
    static let checkEvery = 5

    static var fileURL: URL {
        DeviceStore.fileURL.deletingLastPathComponent().appendingPathComponent("remote-wake.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let list = try? JSONDecoder().decode([RemoteWakeTarget].self, from: data) {
            targets = list
        }
        // Typing in the form changes `targets` on every keystroke, so saves wait half a second; quitting writes
        // whatever is still waiting.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.save()
        }
    }

    /// Writes a save that is still waiting, right away.
    func flush() {
        guard let t = saveTask else { return }
        t.cancel(); saveTask = nil
        save()
    }

    private func save() {
        saveTask = nil
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(targets).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("ARPradar: couldn’t save remote-wake list: \(error)")
        }
    }

    func addBlank() {
        let t = RemoteWakeTarget()
        targets.append(t)
        selection = [t.id]
    }

    /// From a scanned device: name, MAC, IP and (when it's on this Mac's LAN) the subnet size.
    func add(from d: Device, interfaces: [NetInterface]) {
        if let i = targets.firstIndex(where: { !d.mac.isEmpty && $0.mac == d.mac }) {
            selection = [targets[i].id]; return
        }
        var t = RemoteWakeTarget()
        t.name = d.name
        t.mac = d.mac
        t.ip = d.ip.description
        if let net = interfaces.first(where: { d.ip.value & $0.netmask.value == $0.network.value }) {
            t.prefix = net.netmask.value.nonzeroBitCount
        }
        targets.append(t)
        selection = [t.id]
    }

    func delete(_ ids: Set<UUID>) {
        for id in ids { checks[id]?.cancel(); checks[id] = nil; statuses[id] = nil }
        targets.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func index(of id: UUID) -> Int? { targets.firstIndex { $0.id == id } }

    func wake(_ ids: Set<UUID>) {
        for t in targets where ids.contains(t.id) { wake(t) }
    }

    private func wake(_ t: RemoteWakeTarget) {
        checks[t.id]?.cancel()
        statuses[t.id] = Status(state: .sending, headline: "Sending", lines: ["Sending \(RemoteWake.rounds) magic packets…"])
        let id = t.id
        let name = t.displayName
        checks[id] = Task { [weak self] in
            // The sends pause between rounds (usleep), so they run off the main thread: waking several PCs
            // at once mustn't freeze the window.
            let outcome: Result<[IPv4], Error> = await Task.detached(priority: .userInitiated) {
                Result { try RemoteWake.send(t) }
            }.value
            guard let self, !Task.isCancelled else { return }
            let dests: [IPv4]
            switch outcome {
            case .success(let d): dests = d
            case .failure(let error):
                self.statuses[id] = Status(state: .failed, headline: "Not sent", lines: [error.localizedDescription])
                return
            }
            let sentLine = "Sent \(RemoteWake.rounds) magic packets to \(dests.map(\.description).joined(separator: " and ")), port \(t.port)"
            guard t.checkAfter, let ip = IPv4(t.ip) else {
                self.statuses[id] = Status(state: .sent, headline: "Sent", lines: [sentLine]); return
            }
            self.statuses[id] = Status(state: .waiting, headline: "Waiting", lines: [sentLine, "Checking \(ip) every \(Self.checkEvery) s…"])
            let start = Date()
            while !Task.isCancelled {
                let awake = await Task.detached(priority: .utility) { RemoteWake.isAwake(ip) }.value
                if Task.isCancelled { return }
                let secs = Int(Date().timeIntervalSince(start))
                if awake {
                    let when = secs <= 3 ? "answered right away (it may already have been on)" : "answered after \(secs) seconds"
                    self.statuses[id] = Status(state: .awake, headline: "Awake",
                                               lines: [sentLine, "\(name) \(when)."])
                    return
                }
                if secs >= Self.checkSeconds {
                    self.statuses[id] = Status(state: .noAnswer, headline: "No answer",
                                               lines: [sentLine, "\(ip) didn’t answer ping or open RDP, file sharing or SSH within 2 minutes."])
                    return
                }
                self.statuses[id]?.lines = [sentLine, "Checking \(ip) every \(Self.checkEvery) s… \(secs) s so far"]
                try? await Task.sleep(nanoseconds: UInt64(Self.checkEvery) * 1_000_000_000)
            }
        }
    }
}

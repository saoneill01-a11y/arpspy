import Foundation

/// What a Ubiquiti device says about itself in reply to the discovery packet.
struct UbiquitiInfo: Sendable, Hashable, Codable {
    var name = "", model = "", firmware = "", mac = ""
}

/// Ubiquiti's device discovery (UDP 10001), the same one the UniFi and airMAX tools use. No login needed.
/// Consoles (Cloud Key, UDM), Protect cameras, airMAX radios and bridges answer it. UniFi switches and
/// access points stop answering once they're adopted by a controller, so the map needs the controller for those.
enum UbiquitiDiscovery {
    static let port: UInt16 = 10001
    static let request: [UInt8] = [0x01, 0x00, 0x00, 0x00]

    /// Broadcasts on each interface's subnet and asks every target directly. Returns replies from targets only.
    static func discover(_ targets: Set<UInt32>, interfaces: [NetInterface], timeout: TimeInterval, flag: CancelFlag) -> [UInt32: UbiquitiInfo] {
        guard !targets.isEmpty else { return [:] }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        Sockets.setNonBlocking(fd)
        var broadcasts: Set<UInt32> = [0xFFFF_FFFF]
        for i in interfaces { broadcasts.insert(i.network.value | ~i.netmask.value) }
        for b in broadcasts { Sockets.send(fd, request, to: b, port: port) }
        // Only a few devices can answer, but asking each one directly also reaches them over a VPN.
        for (i, t) in targets.sorted().enumerated() {
            if flag.isCancelled { return [:] }
            Sockets.send(fd, request, to: t, port: port)
            if i % 64 == 63 { usleep(2_000) }
        }
        var out: [UInt32: UbiquitiInfo] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !flag.isCancelled {
            guard Sockets.waitReadable(fd, seconds: deadline.timeIntervalSinceNow) else { continue }
            while let p = Sockets.receive(fd, into: &buffer) {
                if targets.contains(p.from), let info = parse(Array(buffer[0..<p.count])) { out[p.from] = info }
            }
        }
        return out
    }

    /// Reply: version 1, command 0, 2-byte length, then type (1 byte) / length (2 bytes) / value entries.
    static func parse(_ b: [UInt8]) -> UbiquitiInfo? {
        guard b.count >= 4, b[0] == 1, b[1] == 0 else { return nil }
        var i = 4
        var fields: [UInt8: [UInt8]] = [:]
        while i + 3 <= b.count {
            let type = b[i], len = Int(b[i + 1]) << 8 | Int(b[i + 2])
            guard i + 3 + len <= b.count else { break }
            if fields[type] == nil { fields[type] = Array(b[(i + 3)..<(i + 3 + len)]) }
            i += 3 + len
        }
        func text(_ t: UInt8) -> String {
            guard let v = fields[t], let s = String(bytes: v, encoding: .utf8) else { return "" }
            return s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        }
        var info = UbiquitiInfo()
        if let m = fields[0x01], m.count == 6 { info.mac = m.map { String(format: "%02X", $0) }.joined(separator: ":") }
        info.name = text(0x0B)
        let long = text(0x14), short = text(0x0C)
        info.model = !long.isEmpty ? long : (modelNames[short] ?? short)
        info.firmware = shortFirmware(text(0x03))
        return info.name.isEmpty && info.model.isEmpty && info.mac.isEmpty ? nil : info
    }

    /// "UVC.SAV532q.v4.75.62.67.e71c6e5.250411.1517" → "4.75.62.67"; "6.0.11" stays.
    static func shortFirmware(_ s: String) -> String {
        if let r = s.range(of: #"\.v(\d+(\.\d+){1,3})"#, options: .regularExpression) {
            return String(s[r].dropFirst(2))
        }
        return s.count > 24 ? String(s.prefix(24)) + "…" : s
    }

    /// Short model codes some devices send instead of a name.
    static let modelNames: [String: String] = [
        "UCKP": "Cloud Key Gen2 Plus", "UCKG2": "Cloud Key Gen2", "UCK": "Cloud Key",
        "UDM": "Dream Machine", "UDMPRO": "Dream Machine Pro", "UDMPROSE": "Dream Machine Pro SE",
        "UDR": "Dream Router", "UCGULTRA": "Cloud Gateway Ultra", "UCGMAX": "Cloud Gateway Max",
        "UNVR": "Network Video Recorder", "UNVRPRO": "Network Video Recorder Pro",
    ]
}

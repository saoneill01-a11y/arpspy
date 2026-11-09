import Foundation
import Darwin

/// Device names come from three places:
///  - NetBIOS (Windows PCs, NAS boxes, printers): asked directly over UDP 137.
///  - Bonjour/mDNS (Macs, NAS boxes, printers, Home Assistant, Linux): asked over multicast UDP 5353.
///  - Reverse DNS (whatever your router or DNS server knows).
enum NameLookup {

    // MARK: NetBIOS

    /// Sends a NetBIOS "node status" question to every address and collects the answers.
    static func netBIOS(_ targets: [IPv4], timeout: TimeInterval, flag: CancelFlag) -> [UInt32: String] {
        guard !targets.isEmpty else { return [:] }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        Sockets.setNonBlocking(fd)

        // Header: id, flags 0, 1 question, 0 answers. Name "*" encoded, type NBSTAT (0x21), class IN.
        var query: [UInt8] = [0x13, 0x37, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20]
        query += [0x43, 0x4B] + [UInt8](repeating: 0x41, count: 30)
        query += [0x00, 0x00, 0x21, 0x00, 0x01]

        for (i, t) in targets.enumerated() {
            if flag.isCancelled { return [:] }
            Sockets.send(fd, query, to: t.value, port: 137)
            if i % 64 == 63 { usleep(2_000) }
        }

        var names: [UInt32: String] = [:]
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !flag.isCancelled {
            guard Sockets.waitReadable(fd, seconds: deadline.timeIntervalSinceNow) else { continue }
            while let packet = Sockets.receive(fd, into: &buffer) {
                if let name = parseNodeStatus(Array(buffer[0..<packet.count])) { names[packet.from] = name }
            }
        }
        return names
    }

    /// Picks the computer name (unique name with suffix 0x00) from a node status reply.
    static func parseNodeStatus(_ b: [UInt8]) -> String? {
        guard b.count > 57 else { return nil }
        var o = 12
        while o < b.count, b[o] != 0 {                 // skip the echoed name
            if b[o] & 0xC0 == 0xC0 { o += 1; break }   // compressed pointer (2 bytes)
            o += Int(b[o]) + 1
        }
        o += 1 + 10                                    // end byte + type, class, TTL, length
        guard o < b.count else { return nil }
        let count = Int(b[o]); o += 1
        for i in 0..<count {
            let s = o + i * 18
            guard s + 18 <= b.count else { break }
            let suffix = b[s + 15]
            let flags = (UInt16(b[s + 16]) << 8) | UInt16(b[s + 17])
            if suffix == 0x00, flags & 0x8000 == 0,
               let raw = String(bytes: b[s..<s + 15], encoding: .ascii) {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    // MARK: Bonjour (mDNS)

    /// Asks the Bonjour multicast group (224.0.0.251:5353) "what's the name of a.b.c.d?" for every address.
    /// Macs, NAS boxes, printers, Home Assistant and Linux boxes with Avahi answer with their ".local" name.
    /// We send from an ordinary port, so devices answer straight back to us ("legacy unicast").
    static func bonjour(_ targets: [IPv4], timeout: TimeInterval, flag: CancelFlag) -> [UInt32: String] {
        guard !targets.isEmpty else { return [:] }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        Sockets.setNonBlocking(fd)
        var ttl: UInt8 = 255                               // mDNS expects TTL 255
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        let group: UInt32 = 0xE00000FB                     // 224.0.0.251
        // Ask each device directly AND the multicast group: some devices only answer one of the two,
        // and many rate-limit multicast answers when asked about lots of addresses at once.
        for (i, t) in targets.enumerated() {
            if flag.isCancelled { return [:] }
            let q = mdnsQuery(for: t, id: UInt16(truncatingIfNeeded: i))
            Sockets.send(fd, q, to: t.value, port: 5353)
            Sockets.send(fd, q, to: group, port: 5353)
            if i % 32 == 31 { usleep(5_000) }
        }

        let wanted = Set(targets.map(\.value))
        var names: [UInt32: String] = [:]
        var buffer = [UInt8](repeating: 0, count: 9000)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !flag.isCancelled {
            guard Sockets.waitReadable(fd, seconds: deadline.timeIntervalSinceNow) else { continue }
            while let packet = Sockets.receive(fd, into: &buffer) {
                for (ip, name) in parsePTRAnswers(Array(buffer[0..<packet.count])) where wanted.contains(ip) {
                    names[ip] = name
                }
            }
        }
        return names
    }

    /// Asks one DNS server (a site's name server, e.g. a client's domain controller over VPN) for the
    /// name of every address, all at once over UDP 53.
    static func dnsPTR(_ targets: [IPv4], server: IPv4, timeout: TimeInterval, flag: CancelFlag) -> [UInt32: String] {
        guard !targets.isEmpty else { return [:] }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        Sockets.setNonBlocking(fd)
        for (i, t) in targets.enumerated() {
            if flag.isCancelled { return [:] }
            Sockets.send(fd, dnsQuery(for: t, id: UInt16(truncatingIfNeeded: i)), to: server.value, port: 53)
            if i % 32 == 31 { usleep(3_000) }
        }
        let wanted = Set(targets.map(\.value))
        var names: [UInt32: String] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !flag.isCancelled, names.count < wanted.count {
            guard Sockets.waitReadable(fd, seconds: deadline.timeIntervalSinceNow) else { continue }
            while let packet = Sockets.receive(fd, into: &buffer) {
                guard packet.from == server.value else { continue }
                for (ip, name) in parsePTRAnswers(Array(buffer[0..<packet.count]), keepLocal: true) where wanted.contains(ip) {
                    names[ip] = name
                }
            }
        }
        return names
    }

    /// Like `mdnsQuery`, with "recursion desired" set, as a normal DNS lookup sends.
    static func dnsQuery(for ip: IPv4, id: UInt16) -> [UInt8] {
        var q = mdnsQuery(for: ip, id: id)
        q[2] = 0x01
        return q
    }

    /// Skips placeholder names some devices report ("Unknown", "localhost").
    static func isUsefulName(_ n: String) -> Bool {
        let t = n.trimmingCharacters(in: .whitespaces).lowercased()
        return !t.isEmpty && !["unknown", "localhost", "(none)", "none", "default", "name"].contains(t)
    }

    /// A DNS question: PTR record for d.c.b.a.in-addr.arpa.
    static func mdnsQuery(for ip: IPv4, id: UInt16) -> [UInt8] {
        var q: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        let v = ip.value
        for label in [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, v >> 24].map({ String($0) }) + ["in-addr", "arpa"] {
            q.append(UInt8(label.utf8.count)); q += Array(label.utf8)
        }
        q += [0, 0x00, 0x0C, 0x00, 0x01]                   // end of name, type PTR, class IN
        return q
    }

    /// Pulls (IP, name) pairs out of the PTR answers in a DNS reply. Bonjour's ".local" is dropped from names
    /// unless `keepLocal` (a real name server's answer, where "pc1.corp.local" is the whole name).
    static func parsePTRAnswers(_ b: [UInt8], keepLocal: Bool = false) -> [(UInt32, String)] {
        guard b.count >= 12, b[2] & 0x80 != 0 else { return [] }        // must be a response
        let qd = Int(b[4]) << 8 | Int(b[5])
        let an = Int(b[6]) << 8 | Int(b[7])
        var o = 12
        for _ in 0..<qd {
            guard readName(b, &o) != nil else { return [] }
            o += 4
        }
        var out: [(UInt32, String)] = []
        for _ in 0..<an {
            guard let owner = readName(b, &o), o + 10 <= b.count else { break }
            let type = Int(b[o]) << 8 | Int(b[o + 1])
            let len = Int(b[o + 8]) << 8 | Int(b[o + 9])
            o += 10
            let end = o + len
            guard end <= b.count else { break }
            if type == 12, let ip = ipFromReverseName(owner) {
                var r = o
                if var name = readName(b, &r) {
                    if !keepLocal, name.lowercased().hasSuffix(".local") { name.removeLast(6) }
                    if !name.isEmpty { out.append((ip, name)) }
                }
            }
            o = end
        }
        return out
    }

    /// Reads a (possibly compressed) DNS name starting at `o` and moves `o` past it.
    static func readName(_ b: [UInt8], _ o: inout Int) -> String? {
        var labels: [String] = []
        var p = o
        var jumped = false
        var hops = 0
        while p < b.count {
            let len = Int(b[p])
            if len == 0 { if !jumped { o = p + 1 }; return labels.joined(separator: ".") }
            if len & 0xC0 == 0xC0 {
                guard p + 1 < b.count, hops < 20 else { return nil }
                if !jumped { o = p + 2 }
                p = (len & 0x3F) << 8 | Int(b[p + 1])
                jumped = true; hops += 1
                continue
            }
            guard p + 1 + len <= b.count else { return nil }
            labels.append(String(decoding: b[(p + 1)..<(p + 1 + len)], as: UTF8.self))
            p += 1 + len
        }
        return nil
    }

    /// "5.1.168.192.in-addr.arpa" → 192.168.1.5
    static func ipFromReverseName(_ name: String) -> UInt32? {
        let parts = name.lowercased().split(separator: ".")
        guard parts.count == 6, parts[4] == "in-addr", parts[5] == "arpa" else { return nil }
        let octets = parts[0..<4].compactMap { UInt8($0) }
        guard octets.count == 4 else { return nil }
        return UInt32(octets[3]) << 24 | UInt32(octets[2]) << 16 | UInt32(octets[1]) << 8 | UInt32(octets[0])
    }

    // MARK: Reverse DNS

    /// Looks names up in parallel and reports each one as soon as it arrives.
    /// Gives up on whatever is still outstanding after `timeout`.
    /// One pool for every scan: `getnameinfo` can block for up to 30 s on a network with no PTR server,
    /// and a fresh pool per scan would pile those threads up scan after scan.
    private static let reverseQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 32
        q.qualityOfService = .utility
        return q
    }()

    static func reverseDNS(_ targets: [IPv4], timeout: TimeInterval, flag: CancelFlag,
                           onResult: @escaping @Sendable (UInt32, String) -> Void) {
        let queue = reverseQueue
        let group = DispatchGroup()
        for t in targets {
            group.enter()
            queue.addOperation {
                defer { group.leave() }
                guard !flag.isCancelled, let name = reverseDNS(t) else { return }
                onResult(t.value, name)
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        queue.cancelAllOperations()
    }

    static func reverseDNS(_ ip: IPv4) -> String? {
        var addr = Sockets.address(ip.value)
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                            &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard r == 0 else { return nil }
        var name = String(cString: host)
        if name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? nil : name
    }
}

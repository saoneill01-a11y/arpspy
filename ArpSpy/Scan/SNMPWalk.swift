import Foundation
import Darwin

/// One value from an SNMP table.
enum SNMPValue: Equatable, Sendable {
    case int(Int64)
    case bytes([UInt8])
    case oid([UInt32])
    case none

    var int: Int? { if case .int(let v) = self { return Int(exactly: v) }; return nil }
    var bytes: [UInt8] { if case .bytes(let b) = self { return b }; return [] }
    /// Text, with control characters dropped (names, port descriptions).
    var text: String { SNMP.clean(String(decoding: bytes, as: UTF8.self)) }
}

/// Reads whole SNMP v2c tables from one device with GetBulk, for the network map (switch ports, MAC tables, LLDP).
/// Blocking: call it off the main thread.
final class SNMPWalker {
    let ip: IPv4
    let community: String
    let port: UInt16
    let timeout: TimeInterval
    /// Stops a walk that keeps going (a broken agent, or a huge table).
    let maxRows: Int
    private var fd: Int32 = -1
    private var requestID: Int32 = Int32.random(in: 1...0x0FFF_FFFF)

    init(ip: IPv4, community: String, port: UInt16 = 161, timeout: TimeInterval = 1.5, maxRows: Int = 20_000) {
        self.ip = ip; self.community = community; self.port = port; self.timeout = timeout; self.maxRows = maxRows
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if fd >= 0 { Sockets.setNonBlocking(fd) }
    }

    deinit { if fd >= 0 { close(fd) } }

    /// Every row under `root`: (the rest of the OID after `root`, value). Empty when it doesn't answer.
    func walk(_ root: [UInt32], flag: CancelFlag = CancelFlag()) -> [(index: [UInt32], value: SNMPValue)] {
        guard fd >= 0 else { return [] }
        var out: [(index: [UInt32], value: SNMPValue)] = []
        var next = root
        while out.count < maxRows, !flag.isCancelled {
            guard let binds = getBulk(after: next) else { break }
            var moved = false
            for b in binds {
                guard b.oid.count > root.count, Array(b.oid.prefix(root.count)) == root, b.value != .none else { return out }
                guard Self.isAfter(b.oid, next) else { return out }      // an agent that goes backwards would loop forever
                out.append((Array(b.oid.dropFirst(root.count)), b.value))
                next = b.oid
                moved = true
            }
            if !moved { break }
        }
        return out
    }

    /// One value (a scalar such as sysName.0), or nil.
    func get(_ oid: [UInt32]) -> SNMPValue? {
        let rows = walk(Array(oid.dropLast()))
        return rows.first { $0.index == [oid.last!] }?.value
    }

    static func isAfter(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x > y }
        return a.count > b.count
    }

    /// A GetBulk for the rows after `oid`, sent up to three times.
    private func getBulk(after oid: [UInt32]) -> [(oid: [UInt32], value: SNMPValue)]? {
        requestID &+= 1
        let id = requestID
        let packet = Self.bulkRequest(community: community, id: id, oid: oid, repetitions: 20)
        var buffer = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<3 {
            Sockets.send(fd, packet, to: ip.value, port: port)
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                guard Sockets.waitReadable(fd, seconds: deadline.timeIntervalSinceNow) else { continue }
                while let p = Sockets.receive(fd, into: &buffer) {
                    guard p.from == ip.value, let r = Self.parseBinds(Array(buffer[0..<p.count])), r.id == id else { continue }
                    return r.error == 0 ? r.binds : nil
                }
            }
        }
        return nil
    }

    // MARK: Packets

    static func bulkRequest(community: String, id: Int32, oid: [UInt32], repetitions: Int32) -> [UInt8] {
        let bind = SNMP.tlv(0x30, SNMP.oid(oid) + [0x05, 0x00])
        // GetBulkRequest: request id, non-repeaters 0, max-repetitions.
        let pdu = SNMP.tlv(0xA5, SNMP.integer(id) + SNMP.integer(0) + SNMP.integer(repetitions) + SNMP.tlv(0x30, bind))
        return SNMP.tlv(0x30, SNMP.integer(1) + SNMP.tlv(0x04, Array(community.utf8)) + pdu)
    }

    /// A GetResponse: its request id, error status and (OID, value) pairs.
    static func parseBinds(_ b: [UInt8]) -> (id: Int32, error: Int, binds: [(oid: [UInt32], value: SNMPValue)])? {
        var o = 0
        guard let msg = read(b, &o), msg.tag == 0x30 else { return nil }
        o = msg.body.lowerBound
        guard read(b, &o)?.tag == 0x02, read(b, &o)?.tag == 0x04, let pdu = read(b, &o), pdu.tag == 0xA2 else { return nil }
        o = pdu.body.lowerBound
        guard let idT = read(b, &o), idT.tag == 0x02, let errT = read(b, &o), read(b, &o) != nil,
              let list = read(b, &o), list.tag == 0x30 else { return nil }
        let id = Int32(truncatingIfNeeded: signed(b[idT.body]))
        let err = Int(signed(b[errT.body]))
        var binds: [(oid: [UInt32], value: SNMPValue)] = []
        var p = list.body.lowerBound
        while p < list.body.upperBound, let bind = read(b, &p), bind.tag == 0x30 {
            var q = bind.body.lowerBound
            guard let name = read(b, &q), name.tag == 0x06, let v = read(b, &q) else { continue }
            let value: SNMPValue
            switch v.tag {
            case 0x02: value = .int(signed(b[v.body]))                          // INTEGER
            case 0x41, 0x42, 0x43, 0x46: value = .int(unsigned(b[v.body]))      // Counter32, Gauge32, TimeTicks, Counter64
            case 0x04, 0x40: value = .bytes(Array(b[v.body]))                   // OCTET STRING, IpAddress
            case 0x06: value = .oid(SNMP.decodeOID(b[v.body]))
            default: value = .none                                               // NULL, noSuchObject, endOfMibView…
            }
            binds.append((SNMP.decodeOID(b[name.body]), value))
        }
        return (id, err, binds)
    }

    /// Like `SNMP.read`, but allows lengths up to 4 bytes (a GetBulk answer can be big).
    static func read(_ b: [UInt8], _ o: inout Int) -> (tag: UInt8, body: Range<Int>)? {
        guard o + 2 <= b.count else { return nil }
        let tag = b[o]
        var len = Int(b[o + 1]); var p = o + 2
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n >= 1, n <= 4, p + n <= b.count else { return nil }
            len = 0
            for i in 0..<n { len = len << 8 | Int(b[p + i]) }
            p += n
        }
        guard len >= 0, p + len <= b.count else { return nil }
        o = p + len
        return (tag, p..<(p + len))
    }

    static func signed(_ s: ArraySlice<UInt8>) -> Int64 {
        guard let first = s.first else { return 0 }
        var v: Int64 = first & 0x80 != 0 ? -1 : 0
        for byte in s.prefix(8) { v = v << 8 | Int64(byte) }
        return v
    }

    static func unsigned(_ s: ArraySlice<UInt8>) -> Int64 {
        var v: UInt64 = 0
        for byte in s.suffix(8) { v = v << 8 | UInt64(byte) }
        return Int64(truncatingIfNeeded: v)
    }
}

// MARK: - What the map needs from one switch

/// The tables the map reads from a managed switch. Port numbers are bridge ports (on almost every switch
/// these are the front-panel numbers).
struct SNMPSwitchData: Hashable, Sendable {
    var ip: IPv4
    /// The MAC the scan found for its management address.
    var mac = ""
    /// dot1dBaseBridgeAddress (often what LLDP neighbours report as its chassis id).
    var bridgeMAC = ""
    var name = ""
    var descr = ""
    struct Port: Hashable, Sendable { var name = ""; var mbps = 0; var up = false }
    var ports: [Int: Port] = [:]
    /// MAC → the bridge port it was learned on.
    var macTable: [String: Int] = [:]
    struct Neighbor: Hashable, Sendable {
        var localPort: Int
        var chassisMAC = ""
        var chassisText = ""
        var sysName = ""
        var portID = ""
        var portDescr = ""
    }
    var neighbors: [Neighbor] = []
}

enum SNMPSwitchReader {
    // OIDs
    static let bridgeAddress: [UInt32] = [1, 3, 6, 1, 2, 1, 17, 1, 1]
    static let basePortIfIndex: [UInt32] = [1, 3, 6, 1, 2, 1, 17, 1, 4, 1, 2]
    static let ifName: [UInt32] = [1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 1]
    static let ifDescr: [UInt32] = [1, 3, 6, 1, 2, 1, 2, 2, 1, 2]
    static let ifHighSpeed: [UInt32] = [1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 15]
    static let ifOperStatus: [UInt32] = [1, 3, 6, 1, 2, 1, 2, 2, 1, 8]
    static let qFdbPort: [UInt32] = [1, 3, 6, 1, 2, 1, 17, 7, 1, 2, 2, 1, 2]
    static let fdbPort: [UInt32] = [1, 3, 6, 1, 2, 1, 17, 4, 3, 1, 2]
    static let lldpRem: [UInt32] = [1, 0, 8802, 1, 1, 2, 1, 4, 1, 1]
    static let lldpLocPort: [UInt32] = [1, 0, 8802, 1, 1, 2, 1, 3, 7, 1]
    /// CISCO-VTP-MIB vtpVlanState (index: domain.vlan; 1 = operational).
    static let ciscoVlanState: [UInt32] = [1, 3, 6, 1, 4, 1, 9, 9, 46, 1, 3, 1, 1, 2]
    /// Most VLANs read per switch (each is a few requests).
    static let maxVLANs = 64

    /// A real switch: at least 4 bridge ports, and it has learned MACs or has LLDP neighbours. (A NAS or a
    /// virtual-machine host can answer a few bridge questions too, but won't pass this.)
    static func looksLikeSwitch(ports: Int, macs: Int, neighbors: Int) -> Bool {
        ports >= 4 && (macs > 0 || neighbors > 0)
    }

    /// Cisco keeps one bridge table per VLAN, read with "community@vlan". Joins them: the bridge-port → ifIndex map
    /// from each VLAN (ports only in other VLANs get numbers too) and every MAC learned in any VLAN.
    static func joinVLANs(base portOfIf: [Int: Int], vlans: [(bridgePorts: [Int: Int], fdb: [String: Int])])
        -> (portOfIf: [Int: Int], macTable: [String: Int]) {
        var ports = portOfIf
        var macs: [String: Int] = [:]
        for v in vlans {
            for (bp, ifx) in v.bridgePorts where ports[ifx] == nil {
                // The same bridge number for a port in every VLAN on almost all Catalysts; if it's taken, use the ifIndex.
                ports[ifx] = ports.values.contains(bp) ? ifx : bp
            }
            for (m, bp) in v.fdb {
                guard let ifx = v.bridgePorts[bp], let ours = ports[ifx] else { continue }
                macs[m] = ours
            }
        }
        return (ports, macs)
    }

    /// Reads one device. Nil when it isn't a switch (no bridge ports) or doesn't answer.
    static func read(ip: IPv4, mac: String, name: String, descr: String, community: String, port: UInt16 = 161,
                     flag: CancelFlag = CancelFlag(), log: (String) -> Void = { _ in }) -> SNMPSwitchData? {
        let w = SNMPWalker(ip: ip, community: community, port: port)
        let bridgePorts = w.walk(basePortIfIndex, flag: flag)
        guard bridgePorts.count >= 2 else {
            log("SNMP \(ip): not a switch (no bridge ports)")
            return nil
        }
        var d = SNMPSwitchData(ip: ip, mac: mac, name: name, descr: descr)
        if let b = w.walk(bridgeAddress, flag: flag).first?.value.bytes, b.count == 6 { d.bridgeMAC = macText(b) }
        var portOfIf: [Int: Int] = [:]
        for row in bridgePorts { if let bp = row.index.first, let ifx = row.value.int { portOfIf[ifx] = Int(bp) } }
        // The MAC table: Q-BRIDGE (per VLAN, one table) first; on Cisco, one BRIDGE table per VLAN; else the
        // plain BRIDGE table.
        var fdb: [(String, Int)] = w.walk(qFdbPort, flag: flag).compactMap { r -> (String, Int)? in
            guard r.index.count >= 7, let p = r.value.int, p > 0 else { return nil }
            return (macText(r.index.suffix(6).map { UInt8(truncatingIfNeeded: $0) }), p)
        }
        if fdb.isEmpty {
            let vlans = w.walk(ciscoVlanState, flag: flag).compactMap { r -> Int? in
                guard r.index.count == 2, r.value.int == 1 else { return nil }
                let v = Int(r.index[1])
                return (1002...1005).contains(v) ? nil : v                        // Cisco's reserved FDDI/Token Ring VLANs
            }
            if !vlans.isEmpty {
                var contexts: [(bridgePorts: [Int: Int], fdb: [String: Int])] = []
                for v in vlans.prefix(maxVLANs) where !flag.isCancelled {
                    let vw = SNMPWalker(ip: ip, community: "\(community)@\(v)", port: port)
                    var bps: [Int: Int] = [:], table: [String: Int] = [:]
                    for r in vw.walk(basePortIfIndex, flag: flag) { if let bp = r.index.first, let ifx = r.value.int { bps[Int(bp)] = ifx } }
                    for r in vw.walk(fdbPort, flag: flag) where r.index.count == 6 {
                        if let p = r.value.int, p > 0 { table[macText(r.index.map { UInt8(truncatingIfNeeded: $0) })] = p }
                    }
                    contexts.append((bps, table))
                }
                let joined = joinVLANs(base: portOfIf, vlans: contexts)
                portOfIf = joined.portOfIf
                fdb = joined.macTable.map { ($0.key, $0.value) }
                log("SNMP \(ip): Cisco, \(min(vlans.count, maxVLANs)) VLAN\(vlans.count == 1 ? "" : "s") read")
            }
        }
        func byIf(_ oid: [UInt32]) -> [Int: SNMPValue] {
            Dictionary(w.walk(oid, flag: flag).compactMap { r in r.index.first.map { (Int($0), r.value) } }, uniquingKeysWith: { a, _ in a })
        }
        let names = byIf(ifName), descrs = byIf(ifDescr), speeds = byIf(ifHighSpeed), status = byIf(ifOperStatus)
        for (ifx, bp) in portOfIf {
            let n = names[ifx]?.text ?? ""
            d.ports[bp] = SNMPSwitchData.Port(name: n.isEmpty ? (descrs[ifx]?.text ?? "") : n,
                                              mbps: speeds[ifx]?.int ?? 0, up: status[ifx]?.int == 1)
        }
        if fdb.isEmpty {
            fdb = w.walk(fdbPort, flag: flag).compactMap { r -> (String, Int)? in
                guard r.index.count == 6, let p = r.value.int, p > 0 else { return nil }
                return (macText(r.index.map { UInt8(truncatingIfNeeded: $0) }), p)
            }
        }
        for (m, p) in fdb { d.macTable[m] = p }
        // LLDP neighbours (index: timeMark.localPortNum.remIndex).
        let locPorts = w.walk(lldpLocPort, flag: flag)
        let rem = w.walk(lldpRem, flag: flag)
        var neighbors: [String: SNMPSwitchData.Neighbor] = [:]
        for r in rem where r.index.count >= 4 {
            let column = r.index[0], key = r.index.dropFirst().map(String.init).joined(separator: ".")
            var n = neighbors[key] ?? SNMPSwitchData.Neighbor(localPort: Int(r.index[2]))
            switch column {
            case 5:                                                                // lldpRemChassisId
                let b = r.value.bytes
                if b.count == 6 { n.chassisMAC = macText(b) } else { n.chassisText = r.value.text }
            case 7: n.portID = portIDText(r.value.bytes)                           // lldpRemPortId
            case 8: n.portDescr = r.value.text                                     // lldpRemPortDesc
            case 9: n.sysName = r.value.text                                       // lldpRemSysName
            default: break
            }
            neighbors[key] = n
        }
        // LLDP's own port numbers → bridge ports, by the local port's id or description.
        var locID: [Int: String] = [:], locDesc: [Int: String] = [:]
        for r in locPorts where r.index.count == 2 {
            if r.index[0] == 3 { locID[Int(r.index[1])] = portIDText(r.value.bytes) }
            if r.index[0] == 4 { locDesc[Int(r.index[1])] = r.value.text }
        }
        d.neighbors = neighbors.values.compactMap { n in
            var n = n
            guard let bp = bridgePort(lldpPort: n.localPort, id: locID[n.localPort] ?? "", descr: locDesc[n.localPort] ?? "", in: d,
                                      portOfIf: portOfIf) else { return nil }
            n.localPort = bp
            return n
        }.sorted { $0.localPort < $1.localPort }
        guard looksLikeSwitch(ports: d.ports.count, macs: d.macTable.count, neighbors: d.neighbors.count) else {
            log("SNMP \(ip): not a switch (\(d.ports.count) bridge ports, \(d.macTable.count) MACs, no LLDP neighbours)")
            return nil
        }
        log("SNMP \(ip): \(d.ports.count) ports, \(d.macTable.count) MAC table entries, \(d.neighbors.count) LLDP neighbours")
        return d
    }

    /// The bridge port an LLDP port number means: by name, then as an ifIndex, then as a bridge port.
    static func bridgePort(lldpPort: Int, id: String, descr: String, in d: SNMPSwitchData, portOfIf: [Int: Int]) -> Int? {
        for text in [id, descr] where !text.isEmpty {
            if let hit = d.ports.first(where: { $0.value.name.caseInsensitiveCompare(text) == .orderedSame }) { return hit.key }
        }
        if let n = Int(id), let bp = portOfIf[n] { return bp }
        if let bp = portOfIf[lldpPort] { return bp }
        if d.ports[lldpPort] != nil { return lldpPort }
        return nil
    }

    /// A port id is text ("Gi1/0/5", "5") or, for some switches, a MAC address.
    static func portIDText(_ b: [UInt8]) -> String {
        if b.count == 6, b.contains(where: { $0 < 0x20 || $0 > 0x7E }) { return macText(b) }
        return SNMP.clean(String(decoding: b, as: UTF8.self))
    }

    static func macText(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: ":") }
}

import Foundation

/// Turns what managed switches report over SNMP (their MAC tables and LLDP neighbours) into the same device and client
/// records the UniFi controller gives, so `NetMapBuilder.build` draws them, alone or mixed with UniFi gear.
///
/// How it works it out:
/// - A switch's **uplink** is the port it learned the gateway's MAC on. When the gateway is itself one of the switches
///   (a layer-3 core), it has no uplink and becomes the top of the map, with its ports.
/// - Two switches are **linked** when LLDP says so, or when one learned the other's MAC on a port that isn't its uplink
///   (the port with the fewest MACs behind it wins: that's the closest one).
/// - A **device** is on the switch and port where it was learned with the fewest other MACs on that port (further
///   up the tree, every port towards it carries everything behind it too). Ports facing another switch don't count.
enum SNMPMapBuilder {
    struct Result {
        var devices: [RawUniFiDevice] = []
        /// MAC → (switch MAC, bridge port) for every other MAC the switches know (devices, and UniFi gear).
        var placements: [String: (switchMAC: String, port: Int)] = [:]
    }

    static func layout(_ switches: [SNMPSwitchData], gatewayMAC: String?, infrastructure: Set<String> = []) -> Result {
        let mac = NetMapBuilder.mac
        let gw = gatewayMAC.map(mac).flatMap { $0.isEmpty ? nil : $0 }
        // Each switch's id is the MAC the scan found for it (else its bridge address); any of its MACs identifies it.
        let sw = switches.filter { !$0.mac.isEmpty || !$0.bridgeMAC.isEmpty }
        let ids = sw.map { mac($0.mac.isEmpty ? $0.bridgeMAC : $0.mac) }
        var whose: [String: Int] = [:]
        for (i, s) in sw.enumerated() { for m in [s.mac, s.bridgeMAC] where !m.isEmpty { whose[mac(m)] = i } }
        func firstLabel(_ s: String) -> String { s.lowercased().split(separator: ".").first.map(String.init) ?? "" }
        let byName = Dictionary(sw.enumerated().filter { !$0.element.name.isEmpty }.map { (firstLabel($0.element.name), $0.offset) },
                                uniquingKeysWith: { a, _ in a })
        let tables = sw.map { s in Dictionary(s.macTable.map { (mac($0.key), $0.value) }, uniquingKeysWith: { a, _ in a }) }
        // How many MACs each port carries (a smaller number means closer to the device).
        let load: [[Int: Int]] = tables.map { t in t.values.reduce(into: [:]) { $0[$1, default: 0] += 1 } }

        // Uplinks (towards the gateway), and LLDP links between the switches (and to the gateway).
        // Without the gateway's MAC (it isn't in the scan, e.g. over a VPN): the switch that has learned the most
        // addresses is taken as the core, and every other switch's uplink is the port it sees the core on.
        let core: Int? = gw != nil ? nil : tables.indices.max { (tables[$0].count, -$0) < (tables[$1].count, -$1) }
        var uplink: [Int?] = tables.enumerated().map { i, t in
            if let gw { return t[gw] }
            guard let c = core, c != i else { return nil }
            return [sw[c].mac, sw[c].bridgeMAC].filter { !$0.isEmpty }.compactMap { t[mac($0)] }.first
        }
        var links: [Int: [Int: (other: Int, otherPort: Int?)]] = [:]     // switch → its port → the switch there
        var facing: [Set<Int>] = Array(repeating: [], count: sw.count)   // ports that lead to a switch or the gateway
        for (i, s) in sw.enumerated() {
            for n in s.neighbors {
                if let gw, mac(n.chassisMAC) == gw { uplink[i] = uplink[i] ?? n.localPort; facing[i].insert(n.localPort); continue }
                if infrastructure.contains(mac(n.chassisMAC)) { facing[i].insert(n.localPort); continue }
                let other = !n.chassisMAC.isEmpty ? whose[mac(n.chassisMAC)] : nil
                guard let t = other ?? byName[firstLabel(n.sysName)] ?? byName[firstLabel(n.chassisText)], t != i else { continue }
                let theirPort = [n.portID, n.portDescr].compactMap { text -> Int? in
                    guard !text.isEmpty else { return nil }
                    return sw[t].ports.first { $0.value.name.caseInsensitiveCompare(text) == .orderedSame }?.key
                }.first ?? Int(n.portID).flatMap { sw[t].ports[$0] != nil ? $0 : nil }
                links[i, default: [:]][n.localPort] = (t, theirPort)
                facing[i].insert(n.localPort)
            }
            if let u = uplink[i] { facing[i].insert(u) }
            // Ports where UniFi gear (switches, access points) is learned lead to more of the network.
            for (m, p) in tables[i] where infrastructure.contains(m) { facing[i].insert(p) }
        }

        // Parents.
        var parent: [Int?] = Array(repeating: nil, count: sw.count)
        var parentPort: [Int?] = Array(repeating: nil, count: sw.count)
        var toGateway = Array(repeating: false, count: sw.count)
        for i in sw.indices {
            // LLDP on the uplink port names the switch above.
            if let u = uplink[i], let l = links[i]?[u] {
                parent[i] = l.other; parentPort[i] = l.otherPort ?? tables[l.other][ids[i]]; continue
            }
            // Otherwise the closest switch that learned this one's MAC on a port that isn't its own uplink.
            let mine = Set([sw[i].mac, sw[i].bridgeMAC].filter { !$0.isEmpty }.map(mac))
            var best: (t: Int, port: Int, load: Int)? = nil
            for t in sw.indices where t != i {
                for m in mine {
                    guard let p = tables[t][m], p != uplink[t] else { continue }
                    let l = load[t][p] ?? 0
                    if best == nil || l < best!.load { best = (t, p, l) }
                }
            }
            if let b = best { parent[i] = b.t; parentPort[i] = b.port; continue }
            // Nothing above it: it's the switch the gateway plugs into.
            if uplink[i] != nil || i == core { toGateway[i] = true }
        }
        for (i, p) in parentPort.enumerated() { if let t = parent[i], let p { facing[t].insert(p) } }

        // Where everything else is plugged in.
        var placements: [String: (switchMAC: String, port: Int)] = [:]
        var bestLoad: [String: Int] = [:]
        let switchMACs = Set(whose.keys)
        for (i, t) in tables.enumerated() {
            for (m, p) in t where !switchMACs.contains(m) && m != gw {
                // Infrastructure (UniFi gear) may sit on a port that faces more network; ordinary devices may not.
                if facing[i].contains(p) && !(infrastructure.contains(m) && p != uplink[i]) { continue }
                let l = load[i][p] ?? 0
                if bestLoad[m] == nil || l < bestLoad[m]! { bestLoad[m] = l; placements[m] = (ids[i], p) }
            }
        }

        // The switches as map devices.
        var out = Result(placements: placements)
        for (i, s) in sw.enumerated() {
            var d = RawUniFiDevice(mac: ids[i])
            d.name = s.name.isEmpty ? s.ip.description : s.name
            d.model = shortModel(s.descr)
            d.ip = s.ip.description
            d.type = "usw"
            let own = uplink[i] ?? links[i]?.first(where: { $0.value.other == parent[i] })?.key
            d.uplinkOwnPort = own
            if let t = parent[i] {
                d.uplinkMAC = ids[t]
                d.uplinkRemotePort = parentPort[i]
                let speeds = [own.flatMap { s.ports[$0]?.mbps }, parentPort[i].flatMap { sw[t].ports[$0]?.mbps }].compactMap { $0 }.filter { $0 > 0 }
                d.uplinkMbps = speeds.min()
            } else if toGateway[i] || uplink[i] != nil {
                if let gw { d.uplinkMAC = gw } else { d.uplinkToNonUniFi = true }
                d.uplinkMbps = own.flatMap { s.ports[$0]?.mbps }.flatMap { $0 > 0 ? $0 : nil }
            }
            d.ports = s.ports.map { bp, p in
                var mp = MapPort(idx: bp, name: p.name, up: p.up, mbps: p.up ? p.mbps : 0)
                mp.uplink = bp == own
                return mp
            }.sorted { $0.idx < $1.idx }
            out.devices.append(d)
        }
        return out
    }

    /// Mixes SNMP switches into a UniFi controller's devices and clients (either list may be empty).
    /// UniFi's own answers win; SNMP adds the non-UniFi switches, where UniFi gear plugs into them, and the
    /// devices UniFi doesn't know about.
    static func merge(unifiDevices: [RawUniFiDevice], unifiClients: [RawUniFiClient], snmp: Result, scan: [Device])
        -> (devices: [RawUniFiDevice], clients: [RawUniFiClient]) {
        let mac = NetMapBuilder.mac
        let uni = Set(unifiDevices.map { mac($0.mac) })
        var devices = unifiDevices.map { d -> RawUniFiDevice in
            var d = d
            // A UniFi device with nothing UniFi above it: an SNMP switch may know where it's plugged in.
            if d.uplinkMAC.isEmpty, let p = snmp.placements[mac(d.mac)] {
                d.uplinkMAC = p.switchMAC; d.uplinkRemotePort = p.port; d.uplinkToNonUniFi = false
            }
            return d
        }
        devices += snmp.devices.filter { !uni.contains(mac($0.mac)) }
        let deviceMACs = Set(devices.map { mac($0.mac) })
        let known = Set(unifiClients.map { mac($0.mac) })
        let scanByMAC = Dictionary(scan.filter { !$0.mac.isEmpty }.map { (mac($0.mac), $0) }, uniquingKeysWith: { a, _ in a })
        var clients = unifiClients
        for (m, p) in snmp.placements.sorted(by: { $0.key < $1.key }) where !known.contains(m) && !deviceMACs.contains(m) {
            let s = scanByMAC[m]
            clients.append(RawUniFiClient(mac: m, ip: s?.ip.description ?? "", name: s?.name ?? "", parentMAC: p.switchMAC, wired: true, port: p.port))
        }
        return (devices, clients)
    }

    /// "Cisco IOS Software, C2960X Software (C2960X-UNIVERSALK9-M), Version 15.2…" → "Cisco IOS Software"
    static func shortModel(_ descr: String) -> String {
        let first = descr.split(whereSeparator: { $0.isNewline || $0 == "," }).first.map(String.init) ?? ""
        let t = first.trimmingCharacters(in: .whitespaces)
        return t.count > 40 ? String(t.prefix(40)) + "…" : (t.isEmpty ? "Managed switch" : t)
    }
}

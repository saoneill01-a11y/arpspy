import Foundation

// MARK: - The map

/// A network map: the gateway at the top, switches and access points under it, each with its clients.
/// Built from a UniFi controller (plus the scan, for names), or, without one, a rough list from the scan.
struct NetMap: Codable, Hashable {
    var date = Date()
    /// "UniFi controller", or "This scan only".
    var source = ""
    /// The controller it came from ("https://10.0.0.5"), if any.
    var controller = ""
    /// False when nothing says how devices are cabled (no controller): every link is a guess.
    var cabled = true
    var nodes: [MapNode] = []

    var root: MapNode? { nodes.first { $0.parent == nil } }
    func node(_ id: String?) -> MapNode? { nodes.first { $0.id == id } }
    func children(of id: String) -> [MapNode] {
        nodes.filter { $0.parent == id }.sorted { ($0.parentPort ?? 999, $0.name) < ($1.parentPort ?? 999, $1.name) }
    }
    var clientCount: Int { nodes.reduce(0) { $0 + $1.clients.count } }
}

struct MapNode: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case gateway, switchDevice = "switch", accessPoint = "ap", device, guessSwitch = "guess", other
    }
    var id: String
    var kind: Kind
    var name = "", model = "", ip = "", mac = "", firmware = ""
    var parent: String? = nil
    /// The port on the parent it plugs into, and its own port that goes up.
    var parentPort: Int? = nil
    var uplinkPort: Int? = nil
    var linkMbps: Int? = nil
    var wireless = false
    /// dBm, for a wireless (mesh) uplink.
    var signal: Int? = nil
    var online = true
    /// "5 GHz ch 36 · 2.4 GHz ch 6"
    var channels = ""
    /// Total PoE power the switch is giving out, in watts.
    var poeWatts: Double? = nil
    var ports: [MapPort] = []
    var clients: [MapClient] = []
    /// A warning shown in amber, e.g. a 100 Mb uplink.
    var note = ""
    /// Drawn dashed in amber: nothing confirms this box or its link.
    var guessed = false

    /// A wired UniFi switch or access point linked at 100 Mb or less: almost always a bad cable or jack.
    var slowLink: Bool {
        guard !wireless, let l = linkMbps, l > 0 else { return false }
        return l <= 100 && (kind == .switchDevice || kind == .accessPoint)
    }
    var wiredClients: [MapClient] { clients.filter(\.wired) }
    var wifiClients: [MapClient] { clients.filter { !$0.wired } }
}

/// Where a device plugs into the UniFi network: a switch and port, or an access point for Wi-Fi.
struct SwitchLink: Hashable, Sendable {
    /// The switch (or access point) name.
    var device: String
    var port: Int? = nil
    /// The port's (or uplink's) speed, in Mb/s.
    var mbps: Int? = nil
    var wireless = false
    var ssid = ""
    var signal: Int? = nil
    /// Behind an unmanaged switch on that port (several devices share it).
    var viaUnmanaged = false

    /// "Office USW · P5", "Lobby AP · Wi-Fi"
    var short: String {
        if wireless { return "\(device) · Wi-Fi" }
        return port.map { "\(device) · P\($0)" } ?? device
    }
    /// Sorts by switch, then port number.
    var sortKey: String { "\(device.lowercased()) \(String(format: "%05d", port ?? 99999))" }
}

extension NetMap {
    /// MAC (as `NetMapBuilder.mac` writes it) → where it plugs in. Clients come from each switch's and access point's
    /// client list; UniFi switches and access points themselves get their uplink.
    func switchLinks() -> [String: SwitchLink] {
        var out: [String: SwitchLink] = [:]
        for n in nodes {
            // Clients behind a guessed unmanaged switch are on the real switch's port it hangs off.
            let owner = n.kind == .guessSwitch ? node(n.parent) : n
            guard let owner else { continue }
            let ownerName = owner.name.isEmpty ? owner.model : owner.name
            for c in n.clients where !c.mac.isEmpty {
                let port = n.kind == .guessSwitch ? n.parentPort : c.port
                out[NetMapBuilder.mac(c.mac)] = SwitchLink(
                    device: ownerName, port: c.wired ? port : nil,
                    mbps: c.wired ? owner.ports.first { $0.idx == port }?.mbps : nil,
                    wireless: !c.wired, ssid: c.ssid, signal: c.signal, viaUnmanaged: n.kind == .guessSwitch)
            }
            if n.kind != .guessSwitch, !n.mac.isEmpty, let p = node(n.parent), p.kind != .guessSwitch {
                out[NetMapBuilder.mac(n.mac)] = SwitchLink(device: p.name.isEmpty ? p.model : p.name, port: n.wireless ? nil : n.parentPort,
                                                           mbps: n.linkMbps, wireless: n.wireless, signal: n.signal)
            }
        }
        return out
    }
}

struct MapPort: Codable, Hashable, Identifiable {
    var idx: Int
    var name = ""
    var up = false
    var mbps = 0
    var poeWatts: Double? = nil
    var uplink = false
    /// What's on it: a switch or AP name, a device name, or "4 devices". Filled in when the map is built.
    var connected = ""
    var id: Int { idx }
}

struct MapClient: Codable, Hashable, Identifiable {
    var mac = "", ip = "", name = "", vendor = ""
    var wired = true
    var port: Int? = nil
    var signal: Int? = nil
    var ssid = ""
    var isThisMac = false
    var id: String { mac.isEmpty ? ip : mac }
}

// MARK: - Building it

/// The controller's answers turned into plain values first (two APIs give the same things in different shapes).
struct RawUniFiDevice: Hashable {
    var mac = "", name = "", model = "", ip = "", firmware = "", type = ""
    var online = true
    var uplinkMAC = ""
    var uplinkRemotePort: Int? = nil
    var uplinkOwnPort: Int? = nil
    var uplinkMbps: Int? = nil
    /// Online, with a current uplink port but nothing UniFi above it: plugged into a non-UniFi device (the firewall).
    var uplinkToNonUniFi = false
    var wireless = false
    var signal: Int? = nil
    var ports: [MapPort] = []
    var channels = ""
}

struct RawUniFiClient: Hashable {
    var mac = "", ip = "", name = "", parentMAC = "", ssid = ""
    var wired = true
    var port: Int? = nil
    var signal: Int? = nil
}

enum NetMapBuilder {
    /// "74:ac:b9:1e:22:1" / "74acb91e2201" → "74:AC:B9:1E:22:01"
    static func mac(_ s: String) -> String {
        let parts = s.split(whereSeparator: { $0 == ":" || $0 == "-" })
        if parts.count == 6 { return parts.map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":").uppercased() }
        let hex = s.filter(\.isHexDigit)
        guard hex.count == 12 else { return s.uppercased() }
        var out: [String] = []; var i = hex.startIndex
        while i < hex.endIndex { let j = hex.index(i, offsetBy: 2); out.append(String(hex[i..<j])); i = j }
        return out.joined(separator: ":").uppercased()
    }

    /// Puts it all together. `gatewayIP` is the scan's router when it's in the scanned range.
    static func build(devices: [RawUniFiDevice], clients: [RawUniFiClient], scan: [Device],
                      gatewayIP: IPv4?, controller: String) -> NetMap {
        var map = NetMap(source: "UniFi controller", controller: controller)
        let scanByMAC = Dictionary(scan.filter { !$0.mac.isEmpty }.map { (mac($0.mac), $0) }, uniquingKeysWith: { a, _ in a })
        let gwIP = gatewayIP?.description ?? ""
        let gatewayTypes: Set<String> = ["ugw", "udm", "uxg", "ucg", "uck-gateway"]

        // The top of the map: a UniFi gateway, or the scan's router (a Sophos, say).
        var nodes: [MapNode] = []
        let uniGateway = devices.first { gatewayTypes.contains($0.type.lowercased()) || (!gwIP.isEmpty && $0.ip == gwIP) }
        var rootID: String
        if let g = uniGateway {
            rootID = mac(g.mac)
        } else if let gw = scan.first(where: { $0.ip.description == gwIP }) {
            rootID = gw.mac.isEmpty ? "gateway" : mac(gw.mac)
            nodes.append(scanNode(gw, kind: .gateway, id: rootID))
        } else {
            rootID = "gateway"
            nodes.append(MapNode(id: rootID, kind: .gateway, name: "Gateway", model: "Not in this scan", guessed: true))
        }

        // UniFi devices.
        let uniMACs = Set(devices.map { mac($0.mac) })
        for d in devices {
            let id = mac(d.mac)
            var n = MapNode(id: id, kind: kind(of: d, isGateway: id == rootID))
            n.name = !d.name.isEmpty ? d.name : (scanByMAC[id].map(\.name) ?? d.model)
            n.model = d.model; n.ip = d.ip; n.mac = id; n.firmware = d.firmware; n.online = d.online
            n.ports = d.ports.sorted { $0.idx < $1.idx }
            n.channels = d.channels
            let watts = d.ports.compactMap(\.poeWatts).reduce(0, +)
            n.poeWatts = watts > 0 ? watts : nil
            if id != rootID {
                let up = mac(d.uplinkMAC)
                n.wireless = d.wireless; n.signal = d.signal
                n.parentPort = d.uplinkRemotePort; n.uplinkPort = d.uplinkOwnPort; n.linkMbps = d.uplinkMbps
                if !d.uplinkMAC.isEmpty && (uniMACs.contains(up) || up == rootID) {
                    n.parent = up
                } else if !d.uplinkMAC.isEmpty {
                    // Plugged into something that isn't UniFi (another switch, a firewall port): show it.
                    n.parent = up
                    if !nodes.contains(where: { $0.id == up }) {
                        var other = scanByMAC[up].map { scanNode($0, kind: .other, id: up) }
                            ?? MapNode(id: up, kind: .other, name: "Unknown device", mac: up)
                        other.parent = rootID
                        other.guessed = true
                        nodes.append(other)
                    }
                } else if d.uplinkToNonUniFi {
                    // Its uplink port goes to something UniFi doesn't manage: the firewall at the top of the map.
                    n.parent = rootID
                } else {
                    n.parent = rootID
                    n.guessed = true
                }
                if n.slowLink {
                    n.note = "Uplink is at \(d.uplinkMbps ?? 0) Mb. Check the cable or wall jack."
                }
            }
            nodes.append(n)
        }

        nodes = breakLoops(nodes, rootID: rootID)

        // Clients go under the switch or access point they're on.
        let byID = Set(nodes.map(\.id))
        let thisMac = Set(scan.filter(\.isThisMac).map { mac($0.mac) })
        var attached: [String: [MapClient]] = [:]
        for c in clients {
            let m = mac(c.mac)
            guard !uniMACs.contains(m), !byID.contains(m) else { continue }
            let s = scanByMAC[m]
            var mc = MapClient(mac: m, ip: c.ip.isEmpty ? (s?.ip.description ?? "") : c.ip)
            mc.name = !c.name.isEmpty ? c.name : (s.map(\.name).flatMap { $0.isEmpty ? nil : $0 } ?? "")
            mc.vendor = s?.vendor ?? ""
            mc.wired = c.wired; mc.port = c.port; mc.signal = c.signal; mc.ssid = c.ssid
            mc.isThisMac = thisMac.contains(m)
            let known = byID.contains(mac(c.parentMAC))
            if !known { mc.port = nil }   // a port on some switch that isn't on the map
            attached[known ? mac(c.parentMAC) : rootID, default: []].append(mc)
        }
        for i in nodes.indices {
            nodes[i].clients = (attached[nodes[i].id] ?? []).sorted { ($0.port ?? 999, $0.name, $0.ip) < ($1.port ?? 999, $1.name, $1.ip) }
        }

        nodes = guessUnmanagedSwitches(nodes)
        nodes = labelPorts(nodes)
        // The root goes first.
        if let r = nodes.firstIndex(where: { $0.id == rootID }) {
            var root = nodes.remove(at: r); root.parent = nil; root.kind = .gateway
            nodes.insert(root, at: 0)
        }
        map.nodes = nodes
        return map
    }

    /// Controllers sometimes report two switches as each other's uplink (seen on a real network: a USW Pro 48 and a
    /// Flex Mini). A loop cuts everything in it off from the gateway, so the biggest switch in each loop is put
    /// under the gateway instead, as a guess.
    static func breakLoops(_ input: [MapNode], rootID: String) -> [MapNode] {
        var nodes = input
        var index: [String: Int] = [:]
        for (i, n) in nodes.enumerated() { index[n.id] = i }
        var settled = Set<String>([rootID])
        for start in nodes.indices {
            var path: [String] = []
            var cur: String? = nodes[start].id
            while let c = cur, !settled.contains(c), let i = index[c] {
                if let at = path.firstIndex(of: c) {
                    let loop = path[at...].compactMap { index[$0] }
                    let top = loop.max { a, b in
                        (nodes[a].ports.count, nodes[a].kind == .switchDevice ? 1 : 0, nodes[b].name)
                            < (nodes[b].ports.count, nodes[b].kind == .switchDevice ? 1 : 0, nodes[a].name)
                    }!
                    let names = loop.filter { $0 != top }.map { nodes[$0].name }.joined(separator: ", ")
                    nodes[top].parent = rootID
                    nodes[top].parentPort = nil
                    nodes[top].guessed = true
                    nodes[top].note = "The controller says this switch and \(names) are each other’s uplink, so where it connects is a guess."
                    break
                }
                path.append(c)
                cur = nodes[i].parent
            }
            settled.formUnion(path)
        }
        return nodes
    }

    static func kind(of d: RawUniFiDevice, isGateway: Bool) -> MapNode.Kind {
        if isGateway { return .gateway }
        switch d.type.lowercased() {
        case "usw", "switching": return .switchDevice
        case "uap", "accesspoint": return .accessPoint
        case "ugw", "udm", "uxg", "ucg": return .gateway
        default: return .device
        }
    }

    static func scanNode(_ d: Device, kind: MapNode.Kind, id: String) -> MapNode {
        var n = MapNode(id: id, kind: kind)
        n.name = !d.name.isEmpty ? d.name : kind == .gateway ? "Gateway" : (d.vendor.isEmpty ? d.ip.description : d.vendor)
        let descr = d.snmpDescr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        n.model = !d.ubntModel.isEmpty ? d.ubntModel : !descr.isEmpty ? descr : !d.upnp.isEmpty ? d.upnp : d.vendor
        if n.model == n.name { n.model = kind == .gateway ? "" : "No name" }
        n.ip = d.ip.description; n.mac = d.mac.isEmpty ? "" : mac(d.mac); n.firmware = d.ubntFirmware
        return n
    }

    /// Two or more wired devices on one switch port with no UniFi device on it: an unmanaged switch (or a VM host).
    static func guessUnmanagedSwitches(_ input: [MapNode]) -> [MapNode] {
        var nodes = input
        var extra: [MapNode] = []
        for i in nodes.indices where (nodes[i].kind == .switchDevice || nodes[i].kind == .gateway) && !nodes[i].ports.isEmpty {
            let used = Set(nodes.filter { $0.parent == nodes[i].id }.compactMap(\.parentPort))
            let byPort = Dictionary(grouping: nodes[i].clients.filter { $0.wired && $0.port != nil }, by: { $0.port! })
            for (port, list) in byPort where list.count >= 2 && !used.contains(port) && port != nodes[i].uplinkPort {
                var g = MapNode(id: "guess-\(nodes[i].id)-\(port)", kind: .guessSwitch)
                g.name = "Unmanaged switch?"
                g.model = "\(list.count) devices on port \(port)"
                g.parent = nodes[i].id; g.parentPort = port; g.guessed = true
                g.linkMbps = nodes[i].ports.first { $0.idx == port }?.mbps
                g.note = "Several devices share this port: an unmanaged switch, or a computer running virtual machines."
                g.clients = list
                extra.append(g)
                let moved = Set(list.map(\.id))
                nodes[i].clients.removeAll { moved.contains($0.id) && $0.port == port }
            }
        }
        return nodes + extra.sorted { $0.id < $1.id }
    }

    /// Fills in each port's "Connected" text.
    static func labelPorts(_ input: [MapNode]) -> [MapNode] {
        var nodes = input
        for i in nodes.indices where !nodes[i].ports.isEmpty {
            let id = nodes[i].id
            let kids = nodes.filter { $0.parent == id }
            for p in nodes[i].ports.indices {
                let idx = nodes[i].ports[p].idx
                if let k = kids.first(where: { $0.parentPort == idx }) {
                    nodes[i].ports[p].connected = k.kind == .guessSwitch ? k.model : k.name
                } else if let parent = nodes.first(where: { $0.id == nodes[i].parent }), nodes[i].uplinkPort == idx {
                    nodes[i].ports[p].connected = "↑ " + parent.name
                } else {
                    let here = nodes[i].clients.filter { $0.wired && $0.port == idx }
                    nodes[i].ports[p].connected = here.count == 1 ? here[0].displayName : here.count > 1 ? "\(here.count) devices" : ""
                }
            }
        }
        return nodes
    }

    /// No controller: the gateway with every Ubiquiti device the scan found under it. Nothing says how they're cabled.
    static func withoutController(scan: [Device], gatewayIP: IPv4?) -> NetMap {
        var map = NetMap(source: "This scan only", cabled: false)
        let gw = scan.first { $0.ip.description == gatewayIP?.description }
        let rootID = gw.map { $0.mac.isEmpty ? "gateway" : mac($0.mac) } ?? "gateway"
        var root = gw.map { scanNode($0, kind: .gateway, id: rootID) }
            ?? MapNode(id: rootID, kind: .gateway, name: "Gateway", model: "Not in this scan", guessed: true)
        root.parent = nil
        var nodes = [root]
        for d in scan where d.isOnline && d.ip != gw?.ip && isUbiquiti(d) {
            var n = scanNode(d, kind: guessKind(d), id: d.mac.isEmpty ? d.ip.description : mac(d.mac))
            n.parent = rootID; n.guessed = true
            if nodes.contains(where: { $0.id == n.id }) { n.id = d.ip.description }
            nodes.append(n)
        }
        map.nodes = nodes
        return map
    }

    static func isUbiquiti(_ d: Device) -> Bool {
        !d.ubntModel.isEmpty || d.vendor.localizedCaseInsensitiveContains("ubiquiti")
    }

    /// From its name or model: "housebackbedroomswitch.lan" → switch, "shopap.lan" → access point.
    static func guessKind(_ d: Device) -> MapNode.Kind {
        let text = [d.name, d.ubntModel].filter { !$0.isEmpty }.joined(separator: " ").lowercased()
        if text.contains("switch") || text.contains("usw") || text.contains("flex mini") { return .switchDevice }
        if text.range(of: #"(^|[^a-z])(ap|u6|u7|uap|nanohd|access point)([^a-z]|$)"#, options: .regularExpression) != nil
            || text.hasSuffix("ap.lan") || text.hasSuffix("ap") { return .accessPoint }
        return .device
    }
}

extension MapClient {
    var displayName: String {
        if isThisMac { return "This Mac" + (name.isEmpty ? "" : " (\(name))") }
        if !name.isEmpty { return name }
        if !vendor.isEmpty { return vendor }
        return ip.isEmpty ? mac : ip
    }
}

// MARK: - Reading the controller's JSON

/// Turns the controller's JSON into plain values. Every field is optional: versions differ.
enum UniFiJSON {
    static func str(_ d: [String: Any], _ k: String) -> String {
        if let s = d[k] as? String { return s }
        if let n = d[k] as? NSNumber { return n.stringValue }
        return ""
    }
    static func int(_ d: [String: Any], _ k: String) -> Int? {
        if let n = d[k] as? NSNumber { return n.intValue }
        if let s = d[k] as? String { return Int(s) ?? Double(s).map { Int($0) } }
        return nil
    }
    static func double(_ d: [String: Any], _ k: String) -> Double? {
        if let n = d[k] as? NSNumber { return n.doubleValue }
        if let s = d[k] as? String { return Double(s) }
        return nil
    }
    static func bool(_ d: [String: Any], _ k: String) -> Bool? {
        if let b = d[k] as? Bool { return b }
        if let n = d[k] as? NSNumber { return n.intValue != 0 }
        return nil
    }
    static func dicts(_ d: [String: Any], _ k: String) -> [[String: Any]] { d[k] as? [[String: Any]] ?? [] }

    /// The `data` array of a reply (`{"meta":…,"data":[…]}` or `{"offset":…,"data":[…]}`), or a bare array.
    static func dataArray(_ data: Data) -> [[String: Any]]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let a = obj as? [[String: Any]] { return a }
        if let d = obj as? [String: Any], let a = d["data"] as? [[String: Any]] { return a }
        return nil
    }

    // Classic API: /api/s/<site>/stat/device and /stat/sta

    static func classicDevice(_ d: [String: Any]) -> RawUniFiDevice? {
        let m = str(d, "mac")
        guard !m.isEmpty else { return nil }
        var r = RawUniFiDevice(mac: m)
        r.name = str(d, "name")
        let code = str(d, "model")
        r.model = modelNames[code] ?? (code.isEmpty ? str(d, "type").uppercased() : code)
        r.ip = str(d, "ip")
        r.firmware = str(d, "version")
        r.type = str(d, "type")
        if let s = int(d, "state") { r.online = s == 1 }
        if let up = d["uplink"] as? [String: Any] {
            r.uplinkMAC = str(up, "uplink_mac")
            r.uplinkRemotePort = int(up, "uplink_remote_port")
            r.uplinkOwnPort = int(up, "port_idx")
            r.uplinkMbps = int(up, "speed")
            r.wireless = str(up, "type") == "wireless"
            if r.wireless {
                if let s = int(up, "signal"), s < 0 { r.signal = s }
                else if let rssi = int(up, "rssi"), rssi > 0 { r.signal = rssi - 96 }
                r.uplinkMbps = nil
            }
        }
        // `last_uplink` is only the last UniFi device it was seen behind, and can be long out of date (a switch that was
        // once cabled through another one). Use it only when there's no current uplink to go by (the device is offline).
        // An online switch whose current uplink has no UniFi device above it is plugged into the firewall or another
        // non-UniFi device; reading last_uplink there made a USW Pro 48 and a Flex Mini each other's uplink.
        let hasLiveUplink = (d["uplink"] as? [String: Any]).map { !$0.isEmpty } ?? false
        if r.uplinkMAC.isEmpty, hasLiveUplink, r.online {
            r.uplinkToNonUniFi = true
        } else if r.uplinkMAC.isEmpty, let lu = d["last_uplink"] as? [String: Any] {
            r.uplinkMAC = str(lu, "uplink_mac")
            r.uplinkRemotePort = int(lu, "uplink_remote_port")
        }
        r.ports = dicts(d, "port_table").compactMap { p in
            guard let idx = int(p, "port_idx") else { return nil }
            var mp = MapPort(idx: idx)
            mp.name = str(p, "name")
            mp.up = bool(p, "up") ?? false
            mp.mbps = mp.up ? (int(p, "speed") ?? 0) : 0
            if let w = double(p, "poe_power"), w > 0 { mp.poeWatts = w }
            mp.uplink = bool(p, "is_uplink") ?? false
            return mp
        }
        let radios = dicts(d, "radio_table_stats").isEmpty ? dicts(d, "radio_table") : dicts(d, "radio_table_stats")
        r.channels = radios.compactMap { rd -> (Int, String)? in
            guard let ch = int(rd, "channel"), ch > 0 else { return nil }
            let band = str(rd, "radio")
            let name = band == "ng" ? "2.4 GHz" : band == "na" ? "5 GHz" : band == "6e" ? "6 GHz" : band
            let order = band == "6e" ? 0 : band == "na" ? 1 : 2
            return (order, "\(name) ch \(ch)")
        }.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " · ")
        return r
    }

    static func classicClient(_ d: [String: Any]) -> RawUniFiClient? {
        let m = str(d, "mac")
        guard !m.isEmpty else { return nil }
        var c = RawUniFiClient(mac: m)
        c.ip = str(d, "ip").isEmpty ? str(d, "last_ip") : str(d, "ip")
        c.name = str(d, "name").isEmpty ? str(d, "hostname") : str(d, "name")
        c.wired = bool(d, "is_wired") ?? true
        if c.wired {
            c.parentMAC = str(d, "sw_mac")
            c.port = int(d, "sw_port")
        } else {
            c.parentMAC = str(d, "ap_mac")
            if let s = int(d, "signal"), s < 0 { c.signal = s } else if let rssi = int(d, "rssi"), rssi > 0 { c.signal = rssi - 96 }
            c.ssid = str(d, "essid")
        }
        if c.parentMAC.isEmpty { c.parentMAC = str(d, "uplink_mac") }
        return c
    }

    // Official ("integration") API: /integration/v1/sites/<id>/devices, /devices/<id>, /clients

    static func integrationDevice(_ item: [String: Any], detail: [String: Any]?, macByID: [String: String]) -> RawUniFiDevice? {
        let d = detail ?? item
        let m = str(d, "macAddress").isEmpty ? str(item, "macAddress") : str(d, "macAddress")
        guard !m.isEmpty else { return nil }
        var r = RawUniFiDevice(mac: m)
        r.name = str(d, "name")
        r.model = str(d, "model")
        r.ip = str(d, "ipAddress")
        r.firmware = str(d, "firmwareVersion")
        r.online = str(d, "state").isEmpty || str(d, "state").uppercased() == "ONLINE"
        let features = (d["features"] as? [String]) ?? (item["features"] as? [String]) ?? []
        r.type = features.contains("switching") && !features.contains("accessPoint") ? "switching"
            : features.contains("accessPoint") ? "accessPoint" : ""
        if let up = d["uplink"] as? [String: Any], let pid = up["deviceId"] as? String { r.uplinkMAC = macByID[pid] ?? "" }
        let ifaces = d["interfaces"] as? [String: Any] ?? [:]
        r.ports = dicts(ifaces, "ports").compactMap { p in
            guard let idx = int(p, "idx") else { return nil }
            var mp = MapPort(idx: idx)
            mp.up = str(p, "state").uppercased() == "UP"
            mp.mbps = mp.up ? (int(p, "speedMbps") ?? 0) : 0
            return mp
        }
        r.channels = dicts(ifaces, "radios").compactMap { rd -> (Double, String)? in
            guard let ch = int(rd, "channel"), ch > 0 else { return nil }
            let f = double(rd, "frequencyGHz") ?? 0
            let band = f >= 5.9 ? "6 GHz" : f >= 4.9 ? "5 GHz" : "2.4 GHz"
            return (-f, "\(band) ch \(ch)")
        }.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " · ")
        return r
    }

    static func integrationClient(_ d: [String: Any], macByID: [String: String]) -> RawUniFiClient? {
        let m = str(d, "macAddress")
        guard !m.isEmpty else { return nil }
        var c = RawUniFiClient(mac: m)
        c.ip = str(d, "ipAddress")
        c.name = str(d, "name")
        c.wired = str(d, "type").uppercased() != "WIRELESS"
        c.parentMAC = macByID[str(d, "uplinkDeviceId")] ?? ""
        return c
    }

    /// The classic API sends short model codes. The common ones, by name.
    static let modelNames: [String: String] = [
        "USMINI": "USW Flex Mini", "USF5P": "USW Flex", "USL8LP": "USW Lite 8 PoE", "USL16LP": "USW Lite 16 PoE",
        "USL8A": "USW Aggregation", "US8P60": "US 8 60W", "US8P150": "US 8 150W", "US16P150": "US 16 150W",
        "US24P250": "US 24 250W", "US24": "US 24", "US48": "US 48",
        "U7PG2": "AC Pro", "U7LT": "AC Lite", "U7LR": "AC LR", "U7MSH": "AC Mesh", "U7NHD": "nanoHD",
        "UAL6": "U6 Lite", "UAP6MP": "U6 Pro", "UDMPRO": "Dream Machine Pro", "UDM": "Dream Machine", "UDR": "Dream Router",
    ]
}

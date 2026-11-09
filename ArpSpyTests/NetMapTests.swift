import XCTest
@testable import ArpSpy

/// The network map. Every name, address and MAC here is made up.
final class NetMapTests: XCTestCase {
    private func tlv(_ t: UInt8, _ v: [UInt8]) -> [UInt8] { [t, UInt8(v.count >> 8), UInt8(v.count & 0xFF)] + v }
    private func tlv(_ t: UInt8, _ s: String) -> [UInt8] { tlv(t, Array(s.utf8)) }

    func testUbiquitiDiscoveryReply() {
        let body = tlv(0x02, [0x02, 0x11, 0x22, 0x33, 0x44, 0x55, 10, 20, 0, 61])
            + tlv(0x01, [0x02, 0x11, 0x22, 0x33, 0x44, 0x55])
            + tlv(0x0B, "Lobby Camera") + tlv(0x0C, "UVC G3 Instant")
            + tlv(0x03, "UVC.SAV532q.v4.75.62.67.e71c6e5.250411.1517") + tlv(0x0A, [0, 0, 1, 0])
        let packet: [UInt8] = [1, 0, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
        let info = UbiquitiDiscovery.parse(packet)
        XCTAssertEqual(info?.name, "Lobby Camera")
        XCTAssertEqual(info?.model, "UVC G3 Instant")
        XCTAssertEqual(info?.firmware, "4.75.62.67")
        XCTAssertEqual(info?.mac, "02:11:22:33:44:55")
        // A console sends a short code; the long model (0x14) wins when both are there.
        let console = [1, 0, 0, 0] + tlv(0x0B, "Office") + tlv(0x0C, "UCKP") + tlv(0x03, "6.0.11")
        XCTAssertEqual(UbiquitiDiscovery.parse(console)?.model, "Cloud Key Gen2 Plus")
        XCTAssertEqual(UbiquitiDiscovery.parse(console)?.firmware, "6.0.11")
        XCTAssertNil(UbiquitiDiscovery.parse([2, 0, 0, 0]))
        XCTAssertNil(UbiquitiDiscovery.parse([1]))
    }

    func testMACNormalized() {
        XCTAssertEqual(NetMapBuilder.mac("02:aa:b:c:d:e"), "02:AA:0B:0C:0D:0E")
        XCTAssertEqual(NetMapBuilder.mac("02aabbccddee"), "02:AA:BB:CC:DD:EE")
    }

    private func device(_ ip: String, mac: String, name: String = "", vendor: String = "", thisMac: Bool = false) -> Device {
        var d = Device(ip: IPv4(ip)!)
        d.mac = mac; d.name = name; d.vendor = vendor; d.isThisMac = thisMac
        return d
    }

    /// A Sophos firewall at the top, a core switch, a front-desk switch, two access points (one meshed),
    /// and four devices sharing one core port.
    private let classicDevices = #"""
    {"meta":{"rc":"ok"},"data":[
     {"mac":"02:00:00:00:00:10","ip":"10.20.0.10","name":"Core switch","model":"US24P250","type":"usw","version":"7.1.66","state":1,
      "uplink":{"uplink_mac":"02:00:00:00:00:01","uplink_remote_port":2,"port_idx":25,"speed":10000,"type":"wire"},
      "port_table":[{"port_idx":1,"up":true,"speed":1000,"poe_power":"0.00"},{"port_idx":9,"up":true,"speed":100,"poe_power":"6.50"},
                    {"port_idx":10,"up":true,"speed":2500,"poe_power":"12.25"},{"port_idx":17,"up":true,"speed":1000},
                    {"port_idx":24,"up":false,"speed":0},{"port_idx":25,"up":true,"speed":10000,"is_uplink":true}]},
     {"mac":"02:00:00:00:00:11","ip":"10.20.0.11","name":"Front desk","model":"USL8LP","type":"usw","state":1,
      "uplink":{"uplink_mac":"02:00:00:00:00:10","uplink_remote_port":1,"port_idx":8,"speed":1000,"type":"wire"},
      "port_table":[{"port_idx":1,"up":true,"speed":1000},{"port_idx":2,"up":true,"speed":1000},{"port_idx":8,"up":true,"speed":1000}]},
     {"mac":"02:00:00:00:00:21","ip":"10.20.0.21","name":"Lobby AP","model":"U7PRO","type":"uap","state":1,
      "uplink":{"uplink_mac":"02:00:00:00:00:10","uplink_remote_port":9,"speed":100,"type":"wire"},
      "radio_table_stats":[{"radio":"ng","channel":6},{"radio":"na","channel":36}]},
     {"mac":"02:00:00:00:00:22","ip":"10.20.0.22","name":"Back office AP","model":"UAL6","type":"uap","state":1,
      "uplink":{"uplink_mac":"02:00:00:00:00:10","uplink_remote_port":10,"speed":2500,"type":"wire"}},
     {"mac":"02:00:00:00:00:23","ip":"10.20.0.23","name":"Exam rooms AP","model":"U6M","type":"uap","state":1,
      "uplink":{"uplink_mac":"02:00:00:00:00:22","type":"wireless","signal":-61}}
    ]}
    """#

    private let classicClients = #"""
    {"meta":{"rc":"ok"},"data":[
     {"mac":"02:00:00:00:01:01","ip":"10.20.0.101","name":"Reception-PC","is_wired":true,"sw_mac":"02:00:00:00:00:11","sw_port":1},
     {"mac":"02:00:00:00:01:02","ip":"10.20.0.102","hostname":"billing-pc","is_wired":true,"sw_mac":"02:00:00:00:00:11","sw_port":2},
     {"mac":"02:00:00:00:01:61","ip":"10.20.0.61","is_wired":true,"sw_mac":"02:00:00:00:00:10","sw_port":17},
     {"mac":"02:00:00:00:01:62","ip":"10.20.0.62","is_wired":true,"sw_mac":"02:00:00:00:00:10","sw_port":17},
     {"mac":"02:00:00:00:01:70","ip":"10.20.0.70","name":"Door controller","is_wired":true,"sw_mac":"02:00:00:00:00:10","sw_port":17},
     {"mac":"02:00:00:00:02:01","ip":"10.20.0.150","name":"Front-Tablet","is_wired":false,"ap_mac":"02:00:00:00:00:21","signal":-52,"essid":"Example-Staff"},
     {"mac":"02:00:00:00:02:02","ip":"10.20.0.151","is_wired":false,"ap_mac":"02:00:00:00:00:23","rssi":40,"essid":"Example-Staff"}
    ]}
    """#

    private func classicMap() -> NetMap {
        let devs = UniFiJSON.dataArray(Data(classicDevices.utf8))!.compactMap(UniFiJSON.classicDevice)
        let stas = UniFiJSON.dataArray(Data(classicClients.utf8))!.compactMap(UniFiJSON.classicClient)
        let scan = [device("10.20.0.1", mac: "02:00:00:00:00:01", name: "fw-01", vendor: "Sophos Ltd"),
                    device("10.20.0.61", mac: "02:00:00:00:01:61", name: "", vendor: "Axis Communications AB"),
                    device("10.20.0.150", mac: "02:00:00:00:02:01", name: "Tablet", thisMac: false),
                    device("10.20.0.151", mac: "02:00:00:00:02:02", name: "My Mac", thisMac: true)]
        return NetMapBuilder.build(devices: devs, clients: stas, scan: scan, gatewayIP: IPv4("10.20.0.1"), controller: "https://10.20.0.5")
    }

    func testMapFromClassicAPI() throws {
        let map = classicMap()
        let root = try XCTUnwrap(map.root)
        XCTAssertEqual(root.kind, .gateway)
        XCTAssertEqual(root.name, "fw-01")
        XCTAssertEqual(map.nodes.first?.id, root.id)

        let core = try XCTUnwrap(map.node("02:00:00:00:00:10"))
        XCTAssertEqual(core.parent, root.id)
        XCTAssertEqual(core.parentPort, 2); XCTAssertEqual(core.uplinkPort, 25); XCTAssertEqual(core.linkMbps, 10000)
        XCTAssertEqual(core.model, "US 24 250W")
        XCTAssertEqual(core.poeWatts ?? 0, 18.75, accuracy: 0.01)
        XCTAssertEqual(core.linkLabel, "P2 ⇄ P25 · 10G")

        let front = try XCTUnwrap(map.node("02:00:00:00:00:11"))
        XCTAssertEqual(front.parent, core.id)
        XCTAssertEqual(front.wiredClients.map(\.name), ["Reception-PC", "billing-pc"])
        XCTAssertEqual(front.ports.first { $0.idx == 8 }?.connected, "↑ Core switch")
        XCTAssertEqual(core.ports.first { $0.idx == 1 }?.connected, "Front desk")

        // A 100 Mb uplink on an access point is flagged.
        let lobby = try XCTUnwrap(map.node("02:00:00:00:00:21"))
        XCTAssertTrue(lobby.slowLink)
        XCTAssertFalse(lobby.note.isEmpty)
        XCTAssertEqual(lobby.channels, "5 GHz ch 36 · 2.4 GHz ch 6")
        XCTAssertEqual(lobby.wifiClients.first?.signal, -52)
        XCTAssertEqual(lobby.wifiClients.first?.ssid, "Example-Staff")
        XCTAssertFalse(try XCTUnwrap(map.node("02:00:00:00:00:22")).slowLink)

        // The mesh AP hangs off the AP it connects to, wirelessly.
        let mesh = try XCTUnwrap(map.node("02:00:00:00:00:23"))
        XCTAssertEqual(mesh.parent, "02:00:00:00:00:22")
        XCTAssertTrue(mesh.wireless); XCTAssertEqual(mesh.signal, -61)
        XCTAssertEqual(mesh.linkLabel, "Mesh · -61 dBm")
        // rssi 40 → about -56 dBm; the scan knows this one is this Mac.
        XCTAssertEqual(mesh.wifiClients.first?.signal, -56)
        XCTAssertTrue(mesh.wifiClients.first?.isThisMac ?? false)
        XCTAssertEqual(mesh.wifiClients.first?.displayName, "This Mac (My Mac)")

        // Three devices on core port 17, which has no UniFi device: an unmanaged switch?
        let guess = try XCTUnwrap(map.nodes.first { $0.kind == .guessSwitch })
        XCTAssertEqual(guess.parent, core.id); XCTAssertEqual(guess.parentPort, 17)
        XCTAssertEqual(guess.clients.count, 3)
        XCTAssertEqual(guess.clients.first { $0.ip == "10.20.0.61" }?.vendor, "Axis Communications AB")
        XCTAssertFalse(core.clients.contains { $0.port == 17 })
        XCTAssertEqual(core.ports.first { $0.idx == 17 }?.connected, "3 devices on port 17")
        XCTAssertEqual(map.clientCount, 7)
    }

    func testMapWithUniFiGatewayAndUnknownUplink() throws {
        let devs = [
            RawUniFiDevice(mac: "02:00:00:00:00:01", name: "Gateway", model: "Cloud Gateway Ultra", ip: "10.30.0.1", type: "ucg"),
            RawUniFiDevice(mac: "02:00:00:00:00:10", name: "Barn switch", model: "USW Flex", ip: "10.30.0.10", type: "usw",
                           uplinkMAC: "02:00:00:00:09:99", uplinkRemotePort: 4, uplinkMbps: 1000),
        ]
        let scan = [device("10.30.0.5", mac: "02:00:00:00:09:99", name: "old-netgear", vendor: "NETGEAR")]
        let map = NetMapBuilder.build(devices: devs, clients: [], scan: scan, gatewayIP: nil, controller: "")
        XCTAssertEqual(map.root?.id, "02:00:00:00:00:01")
        XCTAssertEqual(map.root?.kind, .gateway)
        // Uplinked through a switch that isn't UniFi: that switch is shown (guessed) between them.
        let other = try XCTUnwrap(map.node("02:00:00:00:09:99"))
        XCTAssertEqual(other.name, "old-netgear"); XCTAssertTrue(other.guessed); XCTAssertEqual(other.parent, map.root?.id)
        XCTAssertEqual(map.node("02:00:00:00:00:10")?.parent, other.id)
    }

    func testMapFromOfficialAPI() throws {
        let list: [[String: Any]] = [
            ["id": "a1", "macAddress": "02:00:00:00:00:10", "name": "Core", "model": "USW Pro 24 PoE", "ipAddress": "10.20.0.10",
             "state": "ONLINE", "features": ["switching"]],
            ["id": "b2", "macAddress": "02:00:00:00:00:21", "name": "Lobby AP", "model": "U7 Pro", "ipAddress": "10.20.0.21",
             "state": "ONLINE", "features": ["accessPoint"]],
        ]
        let macByID = ["a1": "02:00:00:00:00:10", "b2": "02:00:00:00:00:21"]
        let detail: [String: Any] = ["macAddress": "02:00:00:00:00:21", "name": "Lobby AP", "model": "U7 Pro", "firmwareVersion": "8.0.1",
                                     "uplink": ["deviceId": "a1"],
                                     "interfaces": ["radios": [["frequencyGHz": 2.4, "channel": 6], ["frequencyGHz": 5, "channel": 36]]]]
        let core = try XCTUnwrap(UniFiJSON.integrationDevice(list[0], detail: nil, macByID: macByID))
        let ap = try XCTUnwrap(UniFiJSON.integrationDevice(list[1], detail: detail, macByID: macByID))
        XCTAssertEqual(core.type, "switching"); XCTAssertEqual(ap.type, "accessPoint")
        XCTAssertEqual(ap.uplinkMAC, "02:00:00:00:00:10"); XCTAssertEqual(ap.firmware, "8.0.1")
        XCTAssertEqual(ap.channels, "5 GHz ch 36 · 2.4 GHz ch 6")
        let client = try XCTUnwrap(UniFiJSON.integrationClient(["macAddress": "02:00:00:00:02:01", "type": "WIRELESS",
                                                                "uplinkDeviceId": "b2", "name": "Tablet"], macByID: macByID))
        XCTAssertFalse(client.wired); XCTAssertEqual(client.parentMAC, "02:00:00:00:00:21")
        let map = NetMapBuilder.build(devices: [core, ap], clients: [client],
                                      scan: [device("10.20.0.1", mac: "02:00:00:00:00:01", name: "fw")], gatewayIP: IPv4("10.20.0.1"), controller: "")
        XCTAssertEqual(map.node("02:00:00:00:00:21")?.parent, "02:00:00:00:00:10")
        XCTAssertEqual(map.node("02:00:00:00:00:10")?.parent, map.root?.id)
        XCTAssertTrue(map.node("02:00:00:00:00:10")?.guessed ?? false)   // the official API didn't say what Core plugs into
        XCTAssertEqual(map.node("02:00:00:00:00:21")?.wifiClients.first?.name, "Tablet")
    }

    func testMapWithoutController() {
        var cam = device("10.20.0.61", mac: "02:00:00:00:01:61", name: "Lobby Camera", vendor: "Ubiquiti Inc")
        cam.ubntModel = "UVC G3 Instant"
        let scan = [device("10.20.0.1", mac: "02:00:00:00:00:01", name: "fw-01", vendor: "Sophos Ltd"),
                    device("10.20.0.50", mac: "02:00:00:00:00:50", name: "frontofficeswitch.lan", vendor: "Ubiquiti Inc"),
                    device("10.20.0.71", mac: "02:00:00:00:00:71", name: "shopap.lan", vendor: "Ubiquiti Inc"),
                    device("10.20.0.80", mac: "02:00:00:00:00:80", name: "printer", vendor: "Example Printers"),
                    cam]
        let map = NetMapBuilder.withoutController(scan: scan, gatewayIP: IPv4("10.20.0.1"))
        XCTAssertFalse(map.cabled)
        XCTAssertEqual(map.root?.name, "fw-01")
        XCTAssertEqual(map.nodes.count, 4)   // the printer isn't Ubiquiti
        XCTAssertEqual(map.node("02:00:00:00:00:50")?.kind, .switchDevice)
        XCTAssertEqual(map.node("02:00:00:00:00:71")?.kind, .accessPoint)
        XCTAssertEqual(map.node("02:00:00:00:01:61")?.kind, .device)
        XCTAssertEqual(map.node("02:00:00:00:01:61")?.model, "UVC G3 Instant")
        XCTAssertTrue(map.nodes.dropFirst().allSatisfy(\.guessed))
    }

    func testLayoutKeepsBoxesApart() {
        let map = classicMap()
        let layout = MapLayout(map, showClients: true)
        XCTAssertEqual(layout.centers.count, map.nodes.count)
        let byRow = Dictionary(grouping: map.nodes, by: { layout.centers[$0.id]!.y })
        for (_, row) in byRow {
            let xs = row.map { layout.centers[$0.id]!.x }.sorted()
            for (a, b) in zip(xs, xs.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, MapLayout.nodeW) }
        }
        // Children sit below their parent.
        for n in map.nodes { if let p = n.parent { XCTAssertGreaterThan(layout.centers[n.id]!.y, layout.centers[p]!.y) } }
    }

    /// Two switches that each say the other is their uplink: the bigger one goes under the gateway, so nothing is lost.
    func testUplinkLoopIsBroken() throws {
        var big = RawUniFiDevice(mac: "02:00:00:00:00:48", name: "Server room", model: "USW Pro 48 PoE", ip: "10.20.0.48", type: "usw",
                                 uplinkMAC: "02:00:00:00:00:05", uplinkRemotePort: 1, uplinkMbps: 1000)
        big.ports = (1...52).map { MapPort(idx: $0) }
        var small = RawUniFiDevice(mac: "02:00:00:00:00:05", name: "Back bedroom", model: "USW Flex Mini", ip: "10.20.0.5", type: "usw",
                                   uplinkMAC: "02:00:00:00:00:48", uplinkRemotePort: 43, uplinkMbps: 1000)
        small.ports = (1...5).map { MapPort(idx: $0) }
        let ap = RawUniFiDevice(mac: "02:00:00:00:00:21", name: "Hall AP", model: "U6 Lite", ip: "10.20.0.21", type: "uap",
                                uplinkMAC: "02:00:00:00:00:48", uplinkRemotePort: 10, uplinkMbps: 1000)
        let lost = RawUniFiClient(mac: "02:00:00:00:03:01", ip: "10.20.0.90", name: "Old PC", parentMAC: "02:00:00:00:09:09", wired: true, port: 3)
        let map = NetMapBuilder.build(devices: [big, small, ap], clients: [lost],
                                      scan: [device("10.20.0.1", mac: "02:00:00:00:00:01", name: "fw")], gatewayIP: IPv4("10.20.0.1"), controller: "")
        let root = try XCTUnwrap(map.root)
        let server = try XCTUnwrap(map.node("02:00:00:00:00:48"))
        XCTAssertEqual(server.parent, root.id)
        XCTAssertTrue(server.guessed)
        XCTAssertTrue(server.note.contains("Back bedroom"))
        XCTAssertEqual(map.node("02:00:00:00:00:05")?.parent, server.id)
        XCTAssertEqual(map.node("02:00:00:00:00:21")?.parent, server.id)
        // A client on a switch that isn't on the map hangs off the gateway without a (meaningless) port number,
        // and isn't turned into an "Unmanaged switch?" under the gateway.
        XCTAssertNil(root.clients.first?.port)
        XCTAssertFalse(map.nodes.contains { $0.kind == .guessSwitch })
        // Every box gets a place on the map, even a loop saved by an older version.
        var old = map
        if let i = old.nodes.firstIndex(where: { $0.id == server.id }) { old.nodes[i].parent = "02:00:00:00:00:05" }
        let layout = MapLayout(old, showClients: true)
        XCTAssertEqual(layout.centers.count, old.nodes.count)
    }

    func testCompactTilesAreNarrowerAndStillApart() {
        let map = classicMap()
        let full = MapLayout(map, showClients: true)
        let small = MapLayout(map, showClients: true, style: .compactStyle)
        XCTAssertLessThan(small.size.width, full.size.width)
        XCTAssertLessThan(small.size.height, full.size.height)
        let byRow = Dictionary(grouping: map.nodes, by: { small.centers[$0.id]!.y })
        for (_, row) in byRow {
            let xs = row.map { small.centers[$0.id]!.x }.sorted()
            for (a, b) in zip(xs, xs.dropFirst()) { XCTAssertGreaterThanOrEqual(b - a, MapStyle.compactStyle.nodeW) }
        }
    }

    func testLongRowsWrap() {
        let scan = [device("10.20.0.1", mac: "02:00:00:00:00:01", name: "fw")]
            + (1...8).map { device("10.20.0.\(10 + $0)", mac: String(format: "02:00:00:00:01:%02X", $0), name: "Camera \($0)", vendor: "Ubiquiti Inc") }
        let map = NetMapBuilder.withoutController(scan: scan, gatewayIP: IPv4("10.20.0.1"))
        let layout = MapLayout(map, showClients: false)
        let rows = Set(map.nodes.dropFirst().map { layout.centers[$0.id]!.y })
        XCTAssertEqual(rows.count, 2)   // 6, then 2
        XCTAssertLessThanOrEqual(layout.size.width, 24 * 2 + 6 * MapLayout.nodeW + 5 * MapLayout.hGap + 1)
    }

    func testSwitchPortsSheetAndSavedMap() throws {
        let map = classicMap()
        let t = NetMapView.portsTable(map)
        XCTAssertEqual(t.header, ["Switch", "Port", "Status", "Speed", "PoE", "Connected"])
        XCTAssertTrue(t.rows.contains(["Core switch", "9", "Up", "100M", "6.5 W", "Lobby AP"]))
        XCTAssertTrue(t.rows.contains(["Core switch", "24", "Down", "", "", ""]))
        // Saved with the scan and read back.
        var record = ScanRecord(date: Date(), range: "10.20.0.0/24", devices: [])
        record.netMap = map
        let back = try JSONDecoder().decode(ScanRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(back.netMap, map)
        // Older saved scans have no map.
        let old = try JSONDecoder().decode(ScanRecord.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":0,"range":"10.0.0.0/24","devices":[]}"#.utf8))
        XCTAssertNil(old.netMap)
    }
}

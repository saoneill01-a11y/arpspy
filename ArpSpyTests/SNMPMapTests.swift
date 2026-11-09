import XCTest
@testable import ArpSpy

/// The SNMP map: walking tables, and turning switch MAC tables and LLDP into a map.
final class SNMPMapTests: XCTestCase {

    // MARK: Packets

    func testBulkRequestAndResponse() throws {
        let req = SNMPWalker.bulkRequest(community: "public", id: 7, oid: [1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 1], repetitions: 20)
        XCTAssertEqual(req.first, 0x30)
        XCTAssertTrue(req.contains(0xA5))                               // GetBulkRequest
        // A made-up response: ifName.1 = "Gi1/0/1", ifHighSpeed.1 = Gauge32 1000, then endOfMibView.
        func bind(_ oid: [UInt32], _ value: [UInt8]) -> [UInt8] { SNMP.tlv(0x30, SNMP.oid(oid) + value) }
        let binds = bind([1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 1, 1], SNMP.tlv(0x04, Array("Gi1/0/1".utf8)))
            + bind([1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 15, 1], SNMP.tlv(0x42, [0x03, 0xE8]))
            + bind([1, 3, 6, 1, 2, 1, 31, 1, 1, 1, 15, 2], [0x82, 0x00])
        let pdu = SNMP.tlv(0xA2, SNMP.integer(7) + SNMP.integer(0) + SNMP.integer(0) + SNMP.tlv(0x30, binds))
        let msg = SNMP.tlv(0x30, SNMP.integer(1) + SNMP.tlv(0x04, Array("public".utf8)) + pdu)
        let r = try XCTUnwrap(SNMPWalker.parseBinds(msg))
        XCTAssertEqual(r.id, 7)
        XCTAssertEqual(r.binds.count, 3)
        XCTAssertEqual(r.binds[0].value.text, "Gi1/0/1")
        XCTAssertEqual(r.binds[1].value.int, 1000)
        XCTAssertEqual(r.binds[2].value, .none)
        XCTAssertTrue(SNMPWalker.isAfter([1, 3, 6, 2], [1, 3, 6, 1, 9]))
        XCTAssertFalse(SNMPWalker.isAfter([1, 3, 6, 1], [1, 3, 6, 1]))
    }

    /// Against a real agent, when one is running on this Mac for testing (net-snmp on 127.0.0.1:16161,
    /// community "arpradar-test"); skipped otherwise.
    func testWalksARealAgent() throws {
        let w = SNMPWalker(ip: IPv4("127.0.0.1")!, community: "arpradar-test", port: 16161, timeout: 0.5)
        let system = w.walk([1, 3, 6, 1, 2, 1, 1])
        try XCTSkipIf(system.isEmpty, "No test SNMP agent on 127.0.0.1:16161")
        XCTAssertFalse(system.first { $0.index == [1, 0] }?.value.text.isEmpty ?? true)     // sysDescr.0
        let names = w.walk(SNMPSwitchReader.ifName)
        XCTAssertGreaterThan(names.count, 1)
        XCTAssertTrue(names.contains { $0.value.text == "lo0" })
        // Walks past several GetBulk pages (20 rows each) and stops at the end of the table.
        let all = w.walk([1, 3, 6, 1, 2, 1])
        XCTAssertGreaterThan(all.count, 40)
        for (a, b) in zip(all, all.dropFirst()) { XCTAssertTrue(SNMPWalker.isAfter(b.index, a.index)) }
    }

    // MARK: Topology

    /// gateway ─ P1 core (Cisco-ish, 24 ports)
    ///             P10 ─LLDP─ P24 access-a ─ P3 printer, P4 pc-1
    ///             P11 ─────── P8 access-b (no LLDP) ─ P5 UniFi AP (+ its Wi-Fi phone), P6 pc-2 + pc-3 (a small unmanaged switch)
    ///             P2 nas
    private func network() -> (switches: [SNMPSwitchData], gateway: String) {
        let gw = "02:00:00:00:00:01"
        let core = "02:00:00:00:00:10", a = "02:00:00:00:00:20", b = "02:00:00:00:00:30"
        let printer = "02:00:00:00:01:03", pc1 = "02:00:00:00:01:04", nas = "02:00:00:00:01:02"
        let ap = "02:00:00:00:02:05", phone = "02:00:00:00:02:99", pc2 = "02:00:00:00:02:06", pc3 = "02:00:00:00:02:07"
        func ports(_ n: Int) -> [Int: SNMPSwitchData.Port] {
            Dictionary(uniqueKeysWithValues: (1...n).map { ($0, SNMPSwitchData.Port(name: "Gi0/\($0)", mbps: $0 == 10 ? 10_000 : 1000, up: true)) })
        }
        var c = SNMPSwitchData(ip: IPv4("10.20.30.2")!, mac: core, bridgeMAC: "02:00:00:00:00:11", name: "core.example.lan",
                               descr: "Cisco IOS Software, C2960X Software", ports: ports(24))
        c.macTable = [gw: 1, nas: 2, a: 10, printer: 10, pc1: 10, b: 11, ap: 11, phone: 11, pc2: 11, pc3: 11]
        c.neighbors = [.init(localPort: 10, chassisMAC: "02:00:00:00:00:21", sysName: "access-a", portID: "Gi0/24")]
        var sa = SNMPSwitchData(ip: IPv4("10.20.30.3")!, mac: a, bridgeMAC: "02:00:00:00:00:21", name: "access-a", descr: "Aruba", ports: ports(24))
        sa.macTable = [gw: 24, core: 24, nas: 24, b: 24, printer: 3, pc1: 4]
        sa.neighbors = [.init(localPort: 24, chassisMAC: "02:00:00:00:00:11", sysName: "core", portID: "Gi0/10")]
        var sb = SNMPSwitchData(ip: IPv4("10.20.30.4")!, mac: b, name: "access-b", descr: "Netgear GS308T", ports: ports(8))
        sb.macTable = [gw: 8, core: 8, nas: 8, a: 8, ap: 5, phone: 5, pc2: 6, pc3: 6]
        return ([c, sa, sb], gw)
    }

    func testSwitchesAndDevicesArePlaced() throws {
        let (switches, gw) = network()
        let r = SNMPMapBuilder.layout(switches, gatewayMAC: gw)
        let byMAC = Dictionary(uniqueKeysWithValues: r.devices.map { ($0.mac, $0) })
        let core = try XCTUnwrap(byMAC["02:00:00:00:00:10"])
        XCTAssertEqual(core.uplinkMAC, gw)
        XCTAssertEqual(core.uplinkOwnPort, 1)
        XCTAssertEqual(core.model, "Cisco IOS Software")
        let a = try XCTUnwrap(byMAC["02:00:00:00:00:20"])
        XCTAssertEqual(a.uplinkMAC, "02:00:00:00:00:10")
        XCTAssertEqual(a.uplinkRemotePort, 10)           // from LLDP
        XCTAssertEqual(a.uplinkOwnPort, 24)
        XCTAssertEqual(a.uplinkMbps, 1000)                // the slower end of a 10G/1G link
        let b = try XCTUnwrap(byMAC["02:00:00:00:00:30"])
        XCTAssertEqual(b.uplinkMAC, "02:00:00:00:00:10")
        XCTAssertEqual(b.uplinkRemotePort, 11)           // from the MAC table, no LLDP
        XCTAssertEqual(b.uplinkOwnPort, 8)
        func at(_ m: String) -> String? { r.placements[m].map { "\($0.switchMAC) P\($0.port)" } }
        XCTAssertEqual(at("02:00:00:00:01:02"), "02:00:00:00:00:10 P2")      // nas on the core
        XCTAssertEqual(at("02:00:00:00:01:03"), "02:00:00:00:00:20 P3")      // printer on access-a, not the core's P10
        XCTAssertEqual(at("02:00:00:00:01:04"), "02:00:00:00:00:20 P4")
        XCTAssertEqual(at("02:00:00:00:02:06"), "02:00:00:00:00:30 P6")
        XCTAssertNil(r.placements[gw])
        XCTAssertNil(r.placements["02:00:00:00:00:20"])                      // switches aren't devices
    }

    func testDrawnAsAMapAndMixedWithUniFi() throws {
        let (switches, gw) = network()
        // The UniFi controller knows the AP and its Wi-Fi phone, but not where the AP plugs in (a non-UniFi switch).
        var ap = RawUniFiDevice(mac: "02:00:00:00:02:05", name: "Lobby AP", model: "U6 Lite", ip: "10.20.30.50", type: "uap")
        ap.uplinkToNonUniFi = true
        let phone = RawUniFiClient(mac: "02:00:00:00:02:99", ip: "10.20.30.99", name: "phone", parentMAC: "02:00:00:00:02:05", wired: false)
        let snmp = SNMPMapBuilder.layout(switches, gatewayMAC: gw, infrastructure: ["02:00:00:00:02:05"])
        XCTAssertEqual(snmp.placements["02:00:00:00:02:05"].map { "\($0.switchMAC) P\($0.port)" }, "02:00:00:00:00:30 P5")
        var fw = Device(ip: IPv4("10.20.30.1")!); fw.mac = gw; fw.name = "firewall"
        var pc2 = Device(ip: IPv4("10.20.30.62")!); pc2.mac = "02:00:00:00:02:06"; pc2.name = "pc-2"
        let merged = SNMPMapBuilder.merge(unifiDevices: [ap], unifiClients: [phone], snmp: snmp, scan: [fw, pc2])
        let map = NetMapBuilder.build(devices: merged.devices, clients: merged.clients, scan: [fw, pc2],
                                      gatewayIP: IPv4("10.20.30.1"), controller: "")
        let root = try XCTUnwrap(map.root)
        XCTAssertEqual(map.node("02:00:00:00:00:10")?.parent, root.id)
        XCTAssertEqual(map.node("02:00:00:00:00:20")?.parent, "02:00:00:00:00:10")
        let lobby = try XCTUnwrap(map.node("02:00:00:00:02:05"))
        XCTAssertEqual(lobby.parent, "02:00:00:00:00:30")                     // the AP hangs off access-b, port 5
        XCTAssertEqual(lobby.parentPort, 5)
        XCTAssertFalse(lobby.guessed)
        XCTAssertEqual(lobby.wifiClients.map(\.name), ["phone"])              // UniFi's own client list wins
        XCTAssertTrue(map.nodes.allSatisfy { !$0.guessed || $0.kind == .guessSwitch })
        // pc-2 and pc-3 share access-b port 6: the usual "Unmanaged switch?" guess.
        XCTAssertTrue(map.nodes.contains { $0.kind == .guessSwitch && $0.parent == "02:00:00:00:00:30" && $0.parentPort == 6 })
        XCTAssertEqual(map.node("02:00:00:00:00:20")?.clients.map(\.port), [3, 4])
        // The Switch port column reads the same map.
        XCTAssertEqual(map.switchLinks()["02:00:00:00:01:03"]?.short, "access-a · P3")
    }

    func testWithoutTheGatewayMAC() throws {
        // The gateway isn't in the scan: the busiest port counts as each switch's uplink.
        let (switches, _) = network()
        let r = SNMPMapBuilder.layout(switches, gatewayMAC: nil)
        let byMAC = Dictionary(uniqueKeysWithValues: r.devices.map { ($0.mac, $0) })
        XCTAssertEqual(byMAC["02:00:00:00:00:20"]?.uplinkMAC, "02:00:00:00:00:10")
        XCTAssertEqual(byMAC["02:00:00:00:00:30"]?.uplinkMAC, "02:00:00:00:00:10")
        XCTAssertEqual(r.placements["02:00:00:00:01:03"]?.switchMAC, "02:00:00:00:00:20")
    }

    func testLLDPPortNumbers() {
        var d = SNMPSwitchData(ip: IPv4("10.0.0.2")!)
        d.ports = [1: .init(name: "Gi1/0/1"), 2: .init(name: "Gi1/0/2")]
        let portOfIf = [10101: 1, 10102: 2]
        XCTAssertEqual(SNMPSwitchReader.bridgePort(lldpPort: 7, id: "Gi1/0/2", descr: "", in: d, portOfIf: portOfIf), 2)   // by name
        XCTAssertEqual(SNMPSwitchReader.bridgePort(lldpPort: 7, id: "10101", descr: "", in: d, portOfIf: portOfIf), 1)     // ifIndex
        XCTAssertEqual(SNMPSwitchReader.bridgePort(lldpPort: 10102, id: "", descr: "", in: d, portOfIf: portOfIf), 2)
        XCTAssertEqual(SNMPSwitchReader.bridgePort(lldpPort: 1, id: "x", descr: "", in: d, portOfIf: [:]), 1)              // bridge port
        XCTAssertEqual(SNMPSwitchReader.portIDText([0x02, 0, 0, 0, 0, 0x2A]), "02:00:00:00:00:2A")
        XCTAssertEqual(SNMPSwitchReader.portIDText(Array("port 5".utf8)), "port 5")
    }
}

/// The three additions: a layer-3 core switch as the gateway, Cisco's per-VLAN tables, and not mistaking a server for a switch.
final class SNMPMapMoreTests: XCTestCase {
    func testGatewayThatIsASwitch() throws {
        // core (10.20.30.1, the router) ─ P24 ─ P1 access ─ P5 pc; the core's P3 has a printer.
        let core = "02:00:00:00:00:01", access = "02:00:00:00:00:20", pc = "02:00:00:00:01:05", printer = "02:00:00:00:01:03"
        func ports(_ n: Int) -> [Int: SNMPSwitchData.Port] {
            Dictionary(uniqueKeysWithValues: (1...n).map { ($0, SNMPSwitchData.Port(name: "Gi\($0)", mbps: 1000, up: true)) })
        }
        var c = SNMPSwitchData(ip: IPv4("10.20.30.1")!, mac: core, name: "core", descr: "Cisco IOS Software, C9300", ports: ports(24))
        c.macTable = [access: 24, pc: 24, printer: 3]
        var a = SNMPSwitchData(ip: IPv4("10.20.30.2")!, mac: access, name: "access", descr: "Aruba", ports: ports(8))
        a.macTable = [core: 1, printer: 1, pc: 5]
        let snmp = SNMPMapBuilder.layout([c, a], gatewayMAC: core)
        var gwDevice = Device(ip: IPv4("10.20.30.1")!); gwDevice.mac = core; gwDevice.name = "core"
        let merged = SNMPMapBuilder.merge(unifiDevices: [], unifiClients: [], snmp: snmp, scan: [gwDevice])
        let map = NetMapBuilder.build(devices: merged.devices, clients: merged.clients, scan: [gwDevice],
                                      gatewayIP: IPv4("10.20.30.1"), controller: "")
        let root = try XCTUnwrap(map.root)
        XCTAssertEqual(root.id, core)                          // the core switch is the top of the map…
        XCTAssertEqual(root.kind, .gateway)
        XCTAssertEqual(root.ports.count, 24)                   // …with its ports
        XCTAssertEqual(map.nodes.filter { $0.id == core }.count, 1)
        let acc = try XCTUnwrap(map.node(access))
        XCTAssertEqual(acc.parent, core)
        XCTAssertEqual(acc.parentPort, 24)
        XCTAssertEqual(acc.uplinkPort, 1)
        XCTAssertFalse(acc.guessed)
        XCTAssertEqual(root.clients.map(\.port), [3])          // the printer on the core's port 3
        XCTAssertEqual(acc.clients.map(\.port), [5])
    }

    func testCiscoVLANTablesAreJoined() {
        // VLAN 1: Gi1 (ifIndex 10101) is bridge port 1. VLAN 20 adds Gi5 (ifIndex 10105, bridge port 5), only in VLAN 20.
        let base = [10101: 1]
        let vlan1 = (bridgePorts: [1: 10101], fdb: ["02:00:00:00:00:AA": 1])
        let vlan20 = (bridgePorts: [1: 10101, 5: 10105], fdb: ["02:00:00:00:00:BB": 5, "02:00:00:00:00:CC": 1])
        let j = SNMPSwitchReader.joinVLANs(base: base, vlans: [vlan1, vlan20])
        XCTAssertEqual(j.portOfIf[10105], 5)
        XCTAssertEqual(j.macTable["02:00:00:00:00:AA"], 1)
        XCTAssertEqual(j.macTable["02:00:00:00:00:BB"], 5)
        XCTAssertEqual(j.macTable["02:00:00:00:00:CC"], 1)
        // A VLAN whose bridge number is already taken by another port gets the ifIndex instead, never a clash.
        let odd = (bridgePorts: [1: 10107], fdb: ["02:00:00:00:00:DD": 1])
        let k = SNMPSwitchReader.joinVLANs(base: base, vlans: [odd])
        XCTAssertEqual(k.portOfIf[10107], 10107)
        XCTAssertEqual(k.macTable["02:00:00:00:00:DD"], 10107)
    }

    func testServersAreNotSwitches() {
        XCTAssertTrue(SNMPSwitchReader.looksLikeSwitch(ports: 8, macs: 12, neighbors: 0))
        XCTAssertTrue(SNMPSwitchReader.looksLikeSwitch(ports: 24, macs: 0, neighbors: 2))
        XCTAssertFalse(SNMPSwitchReader.looksLikeSwitch(ports: 2, macs: 30, neighbors: 0))   // a VM host's bridge
        XCTAssertFalse(SNMPSwitchReader.looksLikeSwitch(ports: 6, macs: 0, neighbors: 0))    // nothing learned, no neighbours
    }
}

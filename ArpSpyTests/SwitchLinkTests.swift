import XCTest
import SwiftUI
@testable import ArpSpy

/// Where each device plugs in, read from the UniFi map (the Switch port column and the details panel).
final class SwitchLinkTests: XCTestCase {
    private func map() -> NetMap {
        var gw = MapNode(id: "gw", kind: .gateway); gw.name = "Gateway"; gw.mac = "aa:bb:cc:00:00:01"
        var sw = MapNode(id: "sw", kind: .switchDevice); sw.name = "Office Switch"; sw.mac = "aa:bb:cc:00:00:02"
        sw.parent = "gw"; sw.parentPort = 9; sw.linkMbps = 10_000
        sw.ports = [MapPort(idx: 5, up: true, mbps: 1000), MapPort(idx: 7, up: true, mbps: 100)]
        sw.clients = [MapClient(mac: "aa:bb:cc:00:00:10", ip: "10.20.30.10", name: "printer", wired: true, port: 5)]
        var ap = MapNode(id: "ap", kind: .accessPoint); ap.name = "Lobby AP"; ap.mac = "aa:bb:cc:00:00:03"
        ap.parent = "sw"; ap.parentPort = 7; ap.linkMbps = 100
        ap.clients = [MapClient(mac: "aa:bb:cc:00:00:20", ip: "10.20.30.20", name: "phone", wired: false, signal: -58, ssid: "Example-5G")]
        var g = MapNode(id: "guess-sw-7", kind: .guessSwitch); g.parent = "sw"; g.parentPort = 7; g.guessed = true
        g.clients = [MapClient(mac: "aa:bb:cc:00:00:30", ip: "10.20.30.30", name: "desk-pc", wired: true, port: 7)]
        return NetMap(nodes: [gw, sw, ap, g])
    }

    func testClientsAndUplinks() {
        let links = map().switchLinks()
        let printer = links[NetMapBuilder.mac("aa:bb:cc:00:00:10")]
        XCTAssertEqual(printer?.short, "Office Switch · P5")
        XCTAssertEqual(printer?.mbps, 1000)
        let phone = links[NetMapBuilder.mac("aa:bb:cc:00:00:20")]
        XCTAssertEqual(phone?.short, "Lobby AP · Wi-Fi")
        XCTAssertEqual(phone?.ssid, "Example-5G")
        // Behind the guessed unmanaged switch: the real switch and the port it hangs off.
        let pc = links[NetMapBuilder.mac("aa:bb:cc:00:00:30")]
        XCTAssertEqual(pc?.short, "Office Switch · P7")
        XCTAssertEqual(pc?.viaUnmanaged, true)
        // UniFi devices themselves get their uplink.
        XCTAssertEqual(links[NetMapBuilder.mac("aa:bb:cc:00:00:02")]?.short, "Gateway · P9")
        XCTAssertEqual(links[NetMapBuilder.mac("aa:bb:cc:00:00:02")]?.mbps, 10_000)
        XCTAssertEqual(links[NetMapBuilder.mac("aa:bb:cc:00:00:03")]?.short, "Office Switch · P7")
        XCTAssertNil(links[NetMapBuilder.mac("aa:bb:cc:00:00:01")])     // the gateway plugs into nothing on the map
    }

    func testSortsBySwitchThenPort() {
        let a = SwitchLink(device: "Office Switch", port: 5), b = SwitchLink(device: "Office Switch", port: 12)
        XCTAssertLessThan(a.sortKey, b.sortKey)
    }

    func testSpeedColours() {
        XCTAssertEqual(LinkSpeed.color(10_000), .blue)
        XCTAssertEqual(LinkSpeed.color(2_500), .cyan)
        XCTAssertEqual(LinkSpeed.color(1_000), .green)
        XCTAssertEqual(LinkSpeed.color(100), .orange)
        XCTAssertEqual(LinkSpeed.color(10), .orange)
    }
}

/// A core switch plugged into a non-UniFi firewall: its current uplink has no UniFi device above it, and an old
/// `last_uplink` must not be used (it pointed at a smaller switch that hangs off this one, making a loop).
final class StaleUplinkTests: XCTestCase {
    func testCurrentUplinkToFirewallBeatsOldLastUplink() throws {
        let core = try XCTUnwrap(UniFiJSON.classicDevice([
            "mac": "02:00:00:00:00:48", "name": "Server room", "model": "USPM48P", "ip": "10.20.0.48", "type": "usw", "state": 1,
            "uplink": ["port_idx": 1, "speed": 1000, "type": "wire"],
            "last_uplink": ["uplink_mac": "02:00:00:00:00:05", "uplink_remote_port": 1],
        ]))
        XCTAssertTrue(core.uplinkToNonUniFi)
        XCTAssertEqual(core.uplinkMAC, "")
        let mini = try XCTUnwrap(UniFiJSON.classicDevice([
            "mac": "02:00:00:00:00:05", "name": "Back bedroom", "model": "USMINI", "ip": "10.20.0.5", "type": "usw", "state": 1,
            "uplink": ["uplink_mac": "02:00:00:00:00:48", "uplink_remote_port": 43, "port_idx": 1, "speed": 1000],
        ]))
        var fw = Device(ip: IPv4("10.20.0.1")!); fw.mac = "02:00:00:00:00:01"; fw.name = "fw"
        let map = NetMapBuilder.build(devices: [core, mini], clients: [], scan: [fw], gatewayIP: IPv4("10.20.0.1"), controller: "")
        let root = try XCTUnwrap(map.root)
        let server = try XCTUnwrap(map.node("02:00:00:00:00:48"))
        XCTAssertEqual(server.parent, root.id)
        XCTAssertFalse(server.guessed)                 // no dotted border, no "each other's uplink" note
        XCTAssertTrue(server.note.isEmpty)
        XCTAssertEqual(server.uplinkPort, 1)
        XCTAssertEqual(map.node("02:00:00:00:00:05")?.parent, server.id)
    }

    func testOfflineDeviceStillUsesLastUplink() throws {
        let sw = try XCTUnwrap(UniFiJSON.classicDevice([
            "mac": "02:00:00:00:00:16", "type": "usw", "state": 0,
            "last_uplink": ["uplink_mac": "02:00:00:00:00:48", "uplink_remote_port": 42],
        ]))
        XCTAssertFalse(sw.uplinkToNonUniFi)
        XCTAssertEqual(NetMapBuilder.mac(sw.uplinkMAC), "02:00:00:00:00:48")
        XCTAssertEqual(sw.uplinkRemotePort, 42)
    }
}

/// The organization page's tabs.
final class OrgTabsTests: XCTestCase {
    func testSurveysCollapseAndTabsSplit() {
        let org = UUID(), sid = UUID()
        let t = SavedTable(header: [], rows: [])
        let survey = SavedItem(orgID: org, kind: .survey, title: "Site survey", summary: "", table: t, surveyID: sid)
        let scan = SavedItem(orgID: org, kind: .networkScan, title: "Network scan", summary: "", table: t, surveyID: sid)
        let loose = SavedItem(orgID: org, kind: .networkScan, title: "Network scan · 10.20.30.0/24", summary: "", table: t)
        let heat = SavedItem(orgID: org, kind: .heatmap, title: "Wi-Fi heatmap · Office", summary: "", table: t)
        let all = [survey, scan, loose, heat]
        // Closed: just the survey. Open: the survey and what it found, not the other items.
        XCTAssertEqual(OrgStore.surveyRows(all, expanded: []).map(\.item.id), [survey.id])
        let open = OrgStore.surveyRows(all, expanded: [survey.id])
        XCTAssertEqual(open.map(\.item.id), [survey.id, scan.id])
        XCTAssertEqual(open.map(\.indented), [false, true])
        XCTAssertEqual(OrgStore.surveyResultCount(survey, in: all), 1)
        // Network Scans has no survey rows; heatmaps have their own tab.
        XCTAssertEqual(all.filter { $0.kind.group == .scans }.map(\.id), [scan.id, loose.id])
        XCTAssertEqual(all.filter { $0.kind.group == .heatmaps }.map(\.id), [heat.id])
        XCTAssertEqual(SavedItem.Filter.allCases.map(\.rawValue), ["Site Surveys", "Network Scans", "DNS", "Ports", "Wi-Fi Heatmaps", "Other"])
    }
}

final class DNSPartTests: XCTestCase {
    func testExpiryChecksAreSeparate() {
        let t = SavedTable(header: [], rows: [])
        func dns(_ title: String) -> SavedItem { SavedItem(orgID: UUID(), kind: .dns, title: title, summary: "", table: t) }
        XCTAssertTrue(dns("Domain and certificate expiry · example-a.com").isExpiryCheck)
        for title in ["DNS lookup · example-a.com (All)", "Email check · example-a.com", "Compare servers · example-a.com", "Reverse lookup · 10.20.30.0/24"] {
            XCTAssertFalse(dns(title).isExpiryCheck, title)
        }
        XCTAssertFalse(SavedItem(orgID: UUID(), kind: .ping, title: "Domain and certificate expiry · x", summary: "", table: t).isExpiryCheck)
    }
}

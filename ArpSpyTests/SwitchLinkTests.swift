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

/// Saved heatmaps open the real heatmap, saving again updates the same entry, and Save as New makes a separate copy.
@MainActor
final class HeatmapSaveTests: XCTestCase {
    func testSavingAgainFindsTheSameEntry() {
        let org = UUID(), other = UUID(), heat = UUID()
        let t = SavedTable(header: [], rows: [])
        var linked = SavedItem(orgID: org, kind: .heatmap, title: "Wi-Fi heatmap · Floor 1", summary: "", table: t)
        linked.heatmapID = heat
        let old = SavedItem(orgID: org, kind: .heatmap, title: "Wi-Fi heatmap · Floor 2", summary: "", table: t)   // before links
        let elsewhere = SavedItem(orgID: other, kind: .heatmap, title: "Wi-Fi heatmap · Floor 1", summary: "", table: t)
        let list = [elsewhere, old, linked]
        XCTAssertEqual(OrgStore.heatmapEntry(heat, title: "Wi-Fi heatmap · Floor 1 renamed", org: org, in: list), 2)   // by link
        XCTAssertEqual(OrgStore.heatmapEntry(UUID(), title: "Wi-Fi heatmap · Floor 2", org: org, in: list), 1)          // by title
        XCTAssertNil(OrgStore.heatmapEntry(UUID(), title: "Wi-Fi heatmap · Floor 3", org: org, in: list))              // a new one
        XCTAssertNil(OrgStore.heatmapEntry(heat, title: "x", org: UUID(), in: list))                                   // another org
    }

    func testSaveAsNewCopiesPlanAndSpots() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heatmap-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HeatmapStore(folder: folder)
        let id = store.create(name: "Floor 1")
        // A small plan picture and one spot.
        let img = NSImage(size: NSSize(width: 4, height: 4)); img.lockFocus(); NSColor.white.set(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
        let png = folder.appendingPathComponent("in.png")
        try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(img.tiffRepresentation))?.representation(using: .png, properties: [:])).write(to: png)
        try store.setPlan(id, from: png)
        store.update(id) { $0.spots = [HeatSpot(x: 10, y: 20, readings: [])]; $0.orgID = UUID() }
        let copyID = try XCTUnwrap(store.duplicate(id, name: "Floor 1 copy"))
        let copy = try XCTUnwrap(store.survey(copyID)), original = try XCTUnwrap(store.survey(id))
        XCTAssertNotEqual(copyID, id)
        XCTAssertEqual(copy.name, "Floor 1 copy")
        XCTAssertNil(copy.orgID)                          // standalone until saved to an organization
        XCTAssertNotNil(original.orgID)
        XCTAssertEqual(copy.spots.count, 1)
        XCTAssertNotNil(store.plan(copy))                 // the floor plan came along
        // Both are on disk, separately.
        let reloaded = HeatmapStore(folder: folder)
        XCTAssertEqual(Set(reloaded.surveys.map(\.id)), [id, copyID])
    }

    func testDraftCarriesTheHeatmap() throws {
        var s = HeatSurvey(name: "Floor 1")
        s.spots = [HeatSpot(x: 1, y: 1, readings: [])]
        let d = try XCTUnwrap(Heatmap.draft(s, filter: HeatFilter(ssid: nil), coverage: HeatCoverage()))
        XCTAssertEqual(d.heatmapID, s.id)
    }
}

/// Heatmap zoom: the plan fits at 1, grows inside a scrolling area beyond that, and stays centred when smaller.
final class HeatmapZoomTests: XCTestCase {
    func testLayoutAtDifferentZooms() {
        let plan = CGSize(width: 1600, height: 1000), window = CGSize(width: 800, height: 800)
        let fit = HeatmapView.layout(plan: plan, viewport: window, zoom: 1)
        XCTAssertEqual(fit.k, 0.5, accuracy: 0.0001)                    // 1600 wide into 800
        XCTAssertEqual(fit.size, window)                                  // no scrolling at Fit
        XCTAssertEqual(fit.origin.x, 0, accuracy: 0.0001)
        XCTAssertEqual(fit.origin.y, 150, accuracy: 0.0001)              // centred top to bottom
        let z4 = HeatmapView.layout(plan: plan, viewport: window, zoom: 4)
        XCTAssertEqual(z4.k, 2, accuracy: 0.0001)
        XCTAssertEqual(z4.size.width, 3200, accuracy: 0.0001)            // scrolls both ways
        XCTAssertEqual(z4.size.height, 2000, accuracy: 0.0001)
        XCTAssertEqual(z4.origin, .zero)
        // A plan spot maps to the same place whichever zoom it was clicked at.
        let spot = CGPoint(x: 400, y: 300)
        for z in [1.0, 2.5, 8.0] {
            let L = HeatmapView.layout(plan: plan, viewport: window, zoom: z)
            let screen = CGPoint(x: L.origin.x + spot.x * L.k, y: L.origin.y + spot.y * L.k)
            XCTAssertEqual((screen.x - L.origin.x) / L.k, spot.x, accuracy: 0.0001)
            XCTAssertEqual((screen.y - L.origin.y) / L.k, spot.y, accuracy: 0.0001)
        }
    }
}

/// Heatmap access points: radios grouped into one AP, hand-placed positions, names.
final class HeatmapAPTests: XCTestCase {
    private func r(_ bssid: String, _ rssi: Int, band: String = "5 GHz", ssid: String = "Example") -> HeatReading {
        HeatReading(ssid: ssid, bssid: bssid, rssi: rssi, channel: band == "5 GHz" ? 36 : 6, band: band, widthMHz: 20)
    }

    func testRadiosOfOneAPAreGrouped() {
        // UniFi style: the first byte differs per radio. Cisco style: the last byte counts up from a base.
        XCTAssertEqual(Heatmap.apKey("7A:AC:B9:12:34:56"), Heatmap.apKey("76:AC:B9:12:34:56"))
        XCTAssertEqual(Heatmap.apKey("00:11:22:33:44:50"), Heatmap.apKey("00:11:22:33:44:5F"))
        XCTAssertNotEqual(Heatmap.apKey("00:11:22:33:44:50"), Heatmap.apKey("00:11:22:33:44:60"))   // the next AP
        XCTAssertNotEqual(Heatmap.apKey("7A:AC:B9:12:34:56"), Heatmap.apKey("7A:AC:B9:12:35:56"))
    }

    func testOneMarkerPerAPAndPlacedPositions() {
        let spots = (0..<4).map { i in
            HeatSpot(x: Double(i) * 100, y: 0, readings: [r("7A:AC:B9:12:34:56", -50 - i), r("76:AC:B9:12:34:56", -60 - i, band: "2.4 GHz"),
                                                          r("02:00:00:00:00:A0", -70)])
        }
        let aps = Heatmap.accessPoints(spots, filter: HeatFilter(ssid: "Example"))
        XCTAssertEqual(aps.count, 2)                                         // two APs, not three radios
        let main = aps.first { $0.key == Heatmap.apKey("7A:AC:B9:12:34:56") }!
        XCTAssertEqual(main.radios, 2)
        XCTAssertEqual(main.bands, ["2.4 GHz", "5 GHz"])
        XCTAssertEqual(main.best, -50)
        XCTAssertFalse(main.placed)
        XCTAssertTrue(main.worthShowing)                                     // heard at 4 spots
        let placed = Heatmap.accessPoints(spots, filter: HeatFilter(ssid: "Example"), placed: [main.key: HeatPlace(x: 777, y: 55)])
        let p = placed.first { $0.key == main.key }!
        XCTAssertTrue(p.placed)
        XCTAssertEqual(p.x, 777); XCTAssertEqual(p.y, 55)
        // Heard at only 2 spots: too rough a guess to draw.
        let few = Heatmap.accessPoints(Array(spots.prefix(2)), filter: HeatFilter(ssid: "Example"))
        XCTAssertFalse(few.allSatisfy(\.worthShowing))
        // "Show only this AP" uses the loudest of its radios at each spot.
        let one = Heatmap.value(spots[0], mode: .oneAP, filter: HeatFilter(ssid: "Example", bssid: main.key))
        XCTAssertEqual(one, -50)
    }

    func testNames() {
        var s = HeatSurvey(name: "Floor 1")
        XCTAssertEqual(s.apName("7A:AC:B9:12:34:56", ssid: "Example"), "Example …34:56")
        s.apNames["76:AC:B9:12:34:56"] = "Lobby"                              // named per radio before grouping
        XCTAssertEqual(s.apName("7A:AC:B9:12:34:56", ssid: "Example"), "Lobby")
        s.apNames[Heatmap.apKey("7A:AC:B9:12:34:56")] = "Front desk"
        XCTAssertEqual(s.apName("76:AC:B9:12:34:56", ssid: "Example"), "Front desk")
        // UniFi names, from the access point's own MAC.
        var ap = MapNode(id: "ap", kind: .accessPoint); ap.name = "Addition Hobby Room"; ap.mac = "74:AC:B9:12:34:56"
        XCTAssertEqual(Heatmap.uniFiNames(NetMap(nodes: [ap]))[Heatmap.apKey("7A:AC:B9:12:34:56")], "Addition Hobby Room")
    }
}

import MapKit

/// Floor Plan › From Apple Maps: the scale comes from the map.
@MainActor
final class MapPlanTests: XCTestCase {
    func testPixelsPerUnit() {
        // A 3000-pixel plan of an area 100 m wide: 30 px per metre, or about 9.14 px per foot.
        XCTAssertEqual(Heatmap.pixelsPerUnit(planWidth: 3000, metresWide: 100, metres: true), 30, accuracy: 0.0001)
        XCTAssertEqual(Heatmap.pixelsPerUnit(planWidth: 3000, metresWide: 100, metres: false), 9.144, accuracy: 0.001)
    }

    /// Takes a real Apple Maps picture (needs the internet), so it only runs when asked:
    /// ARPRADAR_LIVE_MAP=1 TEST_RUNNER_ARPRADAR_LIVE_MAP=1 xcodebuild test … -only-testing:ArpSpyTests/MapPlanTests
    func testLiveSnapshotWidth() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ARPRADAR_LIVE_MAP"] == "1", "Live map test not asked for")
        // A public place (Apple Park), 200 m east to west, in a square view.
        let centre = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
        let region = MKCoordinateRegion(center: centre, latitudinalMeters: 200, longitudinalMeters: 200)
        let (image, metresWide) = try await MapPlanPicker.snapshot(region: region, viewSize: CGSize(width: 800, height: 800), style: .satellite)
        XCTAssertEqual(image.size.width, 800, accuracy: 1)
        // The same zoom as on screen, so it's the 200 m asked for (MapKit may widen the area slightly to fit).
        XCTAssertEqual(metresWide, 200, accuracy: 30)
        print("Live map snapshot: \(Int(image.size.width))×\(Int(image.size.height)) points, \(String(format: "%.1f", metresWide)) m wide")
    }
}

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

/// Grouping an access point's radios, with made-up addresses in the patterns real APs use.
final class APGroupingTests: XCTestCase {
    func testNumberingStyles() {
        XCTAssertTrue(Heatmap.sameAP("02:00:5E:CC:2C:71", "02:00:5E:CC:2C:73"))     // last byte counts up (2.4/5/6 GHz)
        XCTAssertTrue(Heatmap.sameAP("02:00:5E:2D:B6:12", "02:00:5E:2E:B6:12"))     // a middle byte steps (older Ubiquiti)
        XCTAssertTrue(Heatmap.sameAP("02:00:5E:AA:2E:E4", "02:00:5E:AB:2E:E4"))
        XCTAssertTrue(Heatmap.sameAP("7A:00:5E:12:34:56", "76:00:5E:12:34:56"))     // first byte's admin bits
        XCTAssertTrue(Heatmap.sameAP("7A:00:5E:12:34:56", "76:00:5E:12:34:57"))     // first and last together
        XCTAssertFalse(Heatmap.sameAP("02:00:5E:2D:B6:12", "02:00:5E:2D:B7:40"))    // two bytes differ: another AP
        XCTAssertFalse(Heatmap.sameAP("02:00:5E:2D:B6:12", "02:00:5E:3D:B6:12"))    // too far apart
        XCTAssertFalse(Heatmap.sameAP("02:00:5E:12:34:10", "02:00:5E:12:34:60"))
        XCTAssertFalse(Heatmap.sameAP("02:00:5E:12:34:56", "02:00:5F:12:34:56"))    // a different maker
    }

    func testFiveAPsFromThirteenRadios() {
        let radios = ["02:00:5E:49:E9:65", "02:00:5E:49:E9:66", "02:00:5E:CC:2C:71", "02:00:5E:CC:2C:72", "02:00:5E:CC:2C:73",
                      "02:00:5E:6B:18:64", "02:00:5E:6C:18:64", "02:00:5E:2D:B6:12", "02:00:5E:2E:B6:12",
                      "02:00:5E:AA:2E:E4", "02:00:5E:AB:2E:E4", "02:00:5E:71:69:11", "02:00:5E:72:69:11"]
        let g = Heatmap.groups(radios)
        XCTAssertEqual(Set(g.values).count, 6)
        XCTAssertEqual(g["02:00:5E:2D:B6:12"], g["02:00:5E:2E:B6:12"])
        XCTAssertEqual(g["02:00:5E:CC:2C:71"], g["02:00:5E:CC:2C:73"])
        XCTAssertNotEqual(g["02:00:5E:CC:2C:71"], g["02:00:5E:2D:B6:12"])
        XCTAssertEqual(g["02:00:5E:2D:B6:12"], Heatmap.apKey("02:00:5E:2D:B6:12"))   // the lowest radio's old key, so saved names still fit
    }

    func testCombineAndSeparateByHand() {
        let a = "02:00:5E:11:11:11", b = "02:00:5E:99:99:99"
        XCTAssertNotEqual(Heatmap.groups([a, b])[a], Heatmap.groups([a, b])[b])
        let combined = Heatmap.groups([a, b], overrides: [a: "K", b: "K"])
        XCTAssertEqual(combined[a], "K"); XCTAssertEqual(combined[b], "K")
        let c = "02:00:5E:CC:2C:71", d = "02:00:5E:CC:2C:72"
        let separated = Heatmap.groups([c, d], overrides: [c: c, d: d])
        XCTAssertNotEqual(separated[c], separated[d])
        // In the map: one AP, two radios, with "show only this AP" using both.
        func spot(_ x: Double, _ ra: Int, _ rb: Int) -> HeatSpot {
            HeatSpot(x: x, y: 0, readings: [HeatReading(ssid: "N", bssid: a, rssi: ra, channel: 6, band: "2.4 GHz", widthMHz: 20),
                                            HeatReading(ssid: "N", bssid: b, rssi: rb, channel: 36, band: "5 GHz", widthMHz: 80)])
        }
        let spots = [spot(0, -50, -40), spot(100, -60, -70), spot(200, -70, -75)]
        let aps = Heatmap.accessPoints(spots, filter: HeatFilter(ssid: "N"), overrides: [a: "K", b: "K"])
        XCTAssertEqual(aps.count, 1)
        XCTAssertEqual(aps[0].radioList, [a, b])
        XCTAssertEqual(aps[0].bands, ["2.4 GHz", "5 GHz"])
        XCTAssertEqual(Heatmap.value(spots[0], mode: .oneAP, filter: HeatFilter(ssid: "N", bssid: "K", radios: [a, b])), -40)
    }
}

/// Floor plan over the map picture, and the same-channel highlight.
@MainActor
final class OverlayAndClashTests: XCTestCase {
    /// A PNG of `w`×`h` filled with `bg`, with a `fg` square of `side` at (x, y) from the top left.
    private func png(_ w: Int, _ h: Int, bg: NSColor, fg: NSColor? = nil, square: (x: Int, y: Int, side: Int)? = nil) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        bg.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        if let fg, let q = square { fg.setFill(); NSRect(x: q.x, y: h - q.y - q.side, width: q.side, height: q.side).fill() }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    func testWhiteBackgroundIsRemoved() throws {
        let data = try XCTUnwrap(Heatmap.stripBackground(png(40, 40, bg: .white, fg: .black, square: (10, 10, 10))))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertLessThan(rep.colorAt(x: 2, y: 2)!.alphaComponent, 0.05)           // paper: clear
        XCTAssertGreaterThan(rep.colorAt(x: 15, y: 15)!.alphaComponent, 0.95)      // wall: kept
        let red = try XCTUnwrap(Heatmap.stripBackground(png(10, 10, bg: NSColor(red: 1, green: 0.8, blue: 0.8, alpha: 1))))
        XCTAssertGreaterThan(NSBitmapImageRep(data: red)!.colorAt(x: 5, y: 5)!.alphaComponent, 0.95)   // coloured areas stay
    }

    func testPlanIsPlacedOnTheMap() throws {
        let base = NSImage(data: png(100, 100, bg: .blue))!
        let over = NSImage(data: png(10, 10, bg: .black))!
        let o = HeatOverlay(cx: 25, cy: 25, width: 10, rotation: 0, opacity: 1)
        let data = try XCTUnwrap(Heatmap.composite(base: base, basePixels: CGSize(width: 100, height: 100), overlay: over,
                                                   overlayPixels: CGSize(width: 10, height: 10), o: o))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 100)
        XCTAssertLessThan(rep.colorAt(x: 25, y: 25)!.brightnessComponent, 0.1)       // the plan, top left
        XCTAssertGreaterThan(rep.colorAt(x: 75, y: 75)!.blueComponent, 0.9)          // the map elsewhere
        XCTAssertGreaterThan(rep.colorAt(x: 25, y: 75)!.blueComponent, 0.9)          // not upside down
    }

    func testOverlayFlowKeepsSizeAndScale() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = HeatmapStore(folder: folder)
        let id = store.create(name: "Yard")
        let mapPNG = folder.appendingPathComponent("map.png"); try png(300, 200, bg: .green).write(to: mapPNG)
        try store.setPlan(id, from: mapPNG)
        store.update(id) { $0.scale = HeatScale(pixelsPerUnit: 3) }
        store.keepPlanAsBase(id)
        XCTAssertEqual(store.survey(id)?.baseFile, "base.png")
        let planPNG = folder.appendingPathComponent("floor.png"); try png(80, 60, bg: .white, fg: .black, square: (20, 20, 20)).write(to: planPNG)
        try store.setOverlay(id, from: planPNG)
        var o = try XCTUnwrap(store.survey(id)?.overlay)
        XCTAssertEqual(o.cx, 150); XCTAssertEqual(o.width, 150)                     // starts centred, half as wide
        o.rotation = 90
        try store.applyOverlay(id, o)
        let s = try XCTUnwrap(store.survey(id))
        XCTAssertEqual(s.planWidth, 300); XCTAssertEqual(s.planHeight, 200)            // same size as the map picture…
        XCTAssertEqual(s.scale?.pixelsPerUnit, 3)                                     // …so the scale still holds
        XCTAssertEqual(s.overlay?.rotation, 90)
        store.removeOverlay(id)
        XCTAssertNil(store.survey(id)?.overlay)
        XCTAssertEqual(store.survey(id)?.baseFile, "base.png")
    }

    func testSameChannelClashes() {
        func ap(_ key: String, _ band: String, _ ch: Int, _ width: Int = 20) -> HeatAP {
            HeatAP(key: key, bssid: key, ssid: "N", channel: ch, band: band, widthMHz: width, best: -50, spotsHeard: 5, x: 0, y: 0,
                   radioList: [key], bandReadings: [HeatReading(ssid: "N", bssid: key, rssi: -50, channel: ch, band: band, widthMHz: width)])
        }
        func r(_ key: String, _ rssi: Int, _ band: String = "5 GHz", _ ch: Int = 36, _ w: Int = 80) -> HeatReading {
            HeatReading(ssid: "N", bssid: key, rssi: rssi, channel: ch, band: band, widthMHz: w)
        }
        let aps = [ap("A", "5 GHz", 36, 80), ap("B", "5 GHz", 44, 80), ap("C", "5 GHz", 149, 80), ap("E", "5 GHz", 36, 80)]
        // A and B are both strong at two spots. E shares A's channel but is never strong where A is.
        let spots = [HeatSpot(x: 0, y: 0, readings: [r("A", -55), r("B", -65, "5 GHz", 44), r("E", -85)]),
                     HeatSpot(x: 1, y: 0, readings: [r("A", -60), r("B", -68, "5 GHz", 44), r("C", -40, "5 GHz", 149)]),
                     HeatSpot(x: 2, y: 0, readings: [r("A", -80), r("E", -50)])]
        let cs = Heatmap.channelClashes(aps, spots: spots)
        XCTAssertEqual(cs.count, 1)                                     // A+B only; C is on another channel; A+E never strong together
        XCTAssertEqual(Set([cs[0].a, cs[0].b]), ["A", "B"])
        XCTAssertEqual(cs[0].label, "ch 36 and 44")
        XCTAssertEqual(cs[0].spots, 2)
        // A gentler limit counts A and E too (both above −90 at the first spot).
        XCTAssertEqual(Heatmap.channelClashes(aps, spots: spots, strong: -90).count, 3)
        let two = [ap("A", "2.4 GHz", 1), ap("B", "2.4 GHz", 11)]
        XCTAssertTrue(Heatmap.channelClashes(two, spots: [HeatSpot(x: 0, y: 0, readings: [r("A", -40, "2.4 GHz", 1, 20), r("B", -40, "2.4 GHz", 11, 20)])]).isEmpty)
    }
}

/// Floor plan import: PDFs come in sharp; white lines and a faded map in the combined plan; older overlays still load.
@MainActor
final class OverlayStyleTests: XCTestCase {
    func testPDFPlansAreDrawnLarge() throws {
        // A made-up 252 × 154 point PDF (about the size of a house plan on a letter page): 3000 pixels across, not ~500.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var box = CGRect(x: 0, y: 0, width: 252, height: 154)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil); ctx.setLineWidth(0.5); ctx.stroke(CGRect(x: 10, y: 10, width: 200, height: 100)); ctx.endPDFPage(); ctx.closePDF()
        let png = try XCTUnwrap(HeatmapStore.planPNG(url))
        XCTAssertEqual(png.size.width, 3000, accuracy: 1)
        XCTAssertEqual(png.size.height, 3000 * 154 / 252, accuracy: 2)
    }

    func testWhiteLinesAndFadedMap() throws {
        func img(_ w: Int, _ h: Int, _ fill: NSColor) -> NSImage {
            let i = NSImage(size: NSSize(width: w, height: h)); i.lockFocus(); fill.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill(); i.unlockFocus(); return i
        }
        let base = img(100, 100, .black), plan = img(10, 10, .black)
        var o = HeatOverlay(cx: 25, cy: 25, width: 10, opacity: 1)
        o.white = true; o.mapOpacity = 0.5
        let data = try XCTUnwrap(Heatmap.composite(base: base, basePixels: CGSize(width: 100, height: 100), overlay: plan,
                                                   overlayPixels: CGSize(width: 10, height: 10), o: o))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertGreaterThan(rep.colorAt(x: 25, y: 25)!.brightnessComponent, 0.95)                 // the plan's lines, white
        XCTAssertEqual(rep.colorAt(x: 75, y: 75)!.brightnessComponent, 0.5, accuracy: 0.1)        // black map faded halfway
    }

    func testOlderOverlaysStillLoad() throws {
        let old = #"{"cx": 10, "cy": 20, "width": 300, "rotation": 5, "opacity": 0.8, "stripped": true}"#
        let o = try JSONDecoder().decode(HeatOverlay.self, from: Data(old.utf8))
        XCTAssertEqual(o.width, 300); XCTAssertFalse(o.white); XCTAssertEqual(o.mapOpacity, 1)
    }
}

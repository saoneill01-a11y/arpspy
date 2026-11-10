import XCTest
@testable import ArpSpy

final class HeatmapTests: XCTestCase {
    private func net(_ ssid: String, _ bssid: String, _ rssi: Int, ch: Int, band: String = "5 GHz", width: Int = 80) -> NearbyNetwork {
        NearbyNetwork(id: bssid, ssid: ssid, bssid: bssid, rssi: rssi, channel: ch, band: band, widthMHz: width, security: "WPA2 Personal")
    }
    private func r(_ ssid: String, _ bssid: String, _ rssi: Int, ch: Int, band: String = "5 GHz", width: Int = 80) -> HeatReading {
        HeatReading(ssid: ssid, bssid: bssid, rssi: rssi, channel: ch, band: band, widthMHz: width)
    }
    private func spot(_ x: Double, _ y: Double, _ readings: [HeatReading], ping: Double? = nil) -> HeatSpot {
        HeatSpot(x: x, y: y, readings: readings, joinedSSID: "ExampleNet", joinedBSSID: "AA:00:00:00:00:01", pingMs: ping)
    }

    func testAverageKeepsOnePerAPStrongestFirst() {
        let scans = [
            [net("ExampleNet", "AA:00:00:00:00:01", -50, ch: 36), net("Neighbor", "BB:00:00:00:00:01", -80, ch: 6, band: "2.4 GHz", width: 20)],
            [net("ExampleNet", "AA:00:00:00:00:01", -54, ch: 36)],
            [net("ExampleNet", "AA:00:00:00:00:01", -52, ch: 36), net("Neighbor", "BB:00:00:00:00:01", -76, ch: 6, band: "2.4 GHz", width: 20)],
        ]
        let avg = Heatmap.average(scans)
        XCTAssertEqual(avg.map(\.bssid), ["AA:00:00:00:00:01", "BB:00:00:00:00:01"])
        XCTAssertEqual(avg[0].rssi, -52)
        XCTAssertEqual(avg[1].rssi, -78)
    }

    func testOverlap() {
        XCTAssertTrue(Heatmap.overlaps(r("a", "1", -50, ch: 1, band: "2.4 GHz", width: 20), r("b", "2", -50, ch: 3, band: "2.4 GHz", width: 20)))
        XCTAssertFalse(Heatmap.overlaps(r("a", "1", -50, ch: 1, band: "2.4 GHz", width: 20), r("b", "2", -50, ch: 6, band: "2.4 GHz", width: 20)))
        // 80 MHz on 36 covers 36–48.
        XCTAssertTrue(Heatmap.overlaps(r("a", "1", -50, ch: 36), r("b", "2", -50, ch: 44, width: 20)))
        XCTAssertFalse(Heatmap.overlaps(r("a", "1", -50, ch: 36), r("b", "2", -50, ch: 52, width: 20)))
        XCTAssertFalse(Heatmap.overlaps(r("a", "1", -50, ch: 6, band: "2.4 GHz", width: 20), r("b", "2", -50, ch: 6, band: "5 GHz", width: 20)))
    }

    func testValuesByMode() {
        let s = spot(10, 10, [
            r("ExampleNet", "AA:1", -48, ch: 36), r("ExampleNet", "AA:2", -70, ch: 149),
            r("Other", "CC:1", -60, ch: 40, width: 20), r("Far", "DD:1", -90, ch: 44, width: 20),
        ], ping: 12)
        let f = HeatFilter(ssid: "ExampleNet")
        XCTAssertEqual(Heatmap.value(s, mode: .signal, filter: f), -48)
        XCTAssertEqual(Heatmap.value(s, mode: .apCount, filter: f), 2)
        XCTAssertEqual(Heatmap.value(s, mode: .overlap, filter: f), 1)   // "Other" on 40; "Far" is too quiet
        XCTAssertEqual(Heatmap.value(s, mode: .ping, filter: f), 12)
        XCTAssertEqual(Heatmap.value(s, mode: .oneAP, filter: HeatFilter(ssid: "ExampleNet", bssid: "AA:2")), -70)
        XCTAssertEqual(Heatmap.value(s, mode: .oneAP, filter: HeatFilter(ssid: "ExampleNet", bssid: "ZZ:9")), Heatmap.silent)
        XCTAssertEqual(Heatmap.value(s, mode: .signal, filter: HeatFilter(ssid: "ExampleNet", band: .b24)), Heatmap.silent)
    }

    func testLevelsAndColors() {
        XCTAssertEqual(Heatmap.level(-67, mode: .signal), 0.5, accuracy: 0.001)
        XCTAssertEqual(Heatmap.level(-30, mode: .signal), 1)
        XCTAssertEqual(Heatmap.level(-99, mode: .signal), 0)
        XCTAssertEqual(Heatmap.level(0, mode: .overlap), 1)
        XCTAssertEqual(Heatmap.level(5, mode: .overlap), 0)
        let red = Heatmap.color(0), green = Heatmap.color(1)
        XCTAssertGreaterThan(red.r, red.g)
        XCTAssertGreaterThan(green.g, green.r)
    }

    func testGridMatchesSpotsAndLeavesFarAreasEmpty() {
        let pts = [(x: 100.0, y: 100.0, v: -50.0), (x: 300.0, y: 100.0, v: -80.0)]
        let g = Heatmap.grid(pts, width: 1000, height: 500, cols: 100, reach: 150)
        func at(_ x: Double, _ y: Double) -> Double? { g.values[Int(y / 10) * g.cols + Int(x / 10)] }
        let a = at(100, 100)!, mid = at(200, 100)!, b = at(300, 100)!
        XCTAssertTrue(a > mid && mid > b, "\(a) \(mid) \(b)")
        XCTAssertLessThan(abs(a + 50), abs(a + 80))
        XCTAssertEqual(mid, -65, accuracy: 2)   // the cell centre is 5 px past the midpoint
        XCTAssertNil(at(900, 450))
    }

    func testCoverage() {
        let g = HeatGrid(cols: 4, rows: 1, values: [-50, -70, -80, nil], alpha: [1, 1, 1, 0])
        let c = Heatmap.coverage(g)
        XCTAssertEqual(c.good, 1 / 3, accuracy: 0.001)
        XCTAssertEqual(c.fair, 1 / 3, accuracy: 0.001)
        XCTAssertEqual(c.poor, 1 / 3, accuracy: 0.001)
    }

    func testAccessPointPlacedWhereLoudest() {
        let spots = [
            spot(0, 0, [r("ExampleNet", "AA:1", -40, ch: 36)]),
            spot(100, 0, [r("ExampleNet", "AA:1", -70, ch: 36)]),
            spot(200, 0, [r("ExampleNet", "AA:1", -85, ch: 36), r("Other", "CC:1", -50, ch: 6, band: "2.4 GHz", width: 20)]),
        ]
        let aps = Heatmap.accessPoints(spots, filter: HeatFilter(ssid: "ExampleNet"))
        XCTAssertEqual(aps.count, 1)
        XCTAssertEqual(aps[0].best, -40)
        XCTAssertEqual(aps[0].spotsHeard, 3)
        XCTAssertLessThan(aps[0].x, 5)
        XCTAssertEqual(Heatmap.neighborCount(spots, filter: HeatFilter(ssid: "ExampleNet")), 1)
    }

    func testFindings() {
        var s = HeatSurvey(name: "Test floor")
        s.spots = (0..<6).map { i in
            spot(Double(i) * 100, 0, [
                r("ExampleNet", "AA:1", i == 5 ? -82 : -50, ch: 6, band: "2.4 GHz", width: 20),
                r("ExampleNet", "AA:2", -60, ch: 6, band: "2.4 GHz", width: 20),
                r("Cafe", "CC:1", -70, ch: 6, band: "2.4 GHz", width: 20),
                r("Shop", "DD:1", -75, ch: 4, band: "2.4 GHz", width: 20),
            ])
        }
        let f = HeatFilter(ssid: "ExampleNet")
        let found = Heatmap.findings(s, filter: f, coverage: HeatCoverage(good: 0.8, fair: 0.1, poor: 0.1))
        XCTAssertFalse(found.contains { $0.level == .bad })   // AA:2 still gives −60 at the last spot
        XCTAssertTrue(found.contains { $0.text.contains("shares channel 6 with 2 neighbor networks") })
        XCTAssertTrue(found.contains { $0.text.contains("both on channel 6") })

        s.spots[5].readings = [r("Cafe", "CC:1", -70, ch: 6, band: "2.4 GHz", width: 20)]
        let weak = Heatmap.findings(s, filter: f, coverage: HeatCoverage(good: 0.8, fair: 0.1, poor: 0.1))
        XCTAssertEqual(weak.first { $0.level == .bad }?.spot, s.spots[5].id)
        XCTAssertTrue(weak.contains { $0.text.hasPrefix("10% of the measured area") })
    }

    func testDraftAndNames() {
        var s = HeatSurvey(name: "Test floor")
        s.scale = HeatScale(pixelsPerUnit: 10)
        s.spots = [spot(100, 50, [r("ExampleNet", "AA:00:00:00:12:34", -55, ch: 36)], ping: 8)]
        XCTAssertEqual(s.apName("AA:00:00:00:12:34", ssid: "ExampleNet"), "ExampleNet …12:34")
        s.apNames["AA:00:00:00:12:34"] = "Lobby"
        XCTAssertEqual(s.shownNetwork, "ExampleNet")
        let d = Heatmap.draft(s, filter: HeatFilter(ssid: "ExampleNet"), coverage: HeatCoverage(good: 1))
        XCTAssertEqual(d?.kind, .heatmap)
        XCTAssertEqual(d?.table.rows.first?[1], "10, 5 ft")
        XCTAssertEqual(d?.table.rows.first?[2], "Lobby")
        XCTAssertEqual(d?.table.rows.first?[7], "8")
    }

    @MainActor
    func testStoreSavesAndReloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heatmap-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HeatmapStore(folder: dir)
        let id = store.create(name: "Floor 1")
        XCTAssertEqual(store.create(name: "Floor 1") != id, true)
        store.update(id) { $0.spots.append(self.spot(5, 6, [self.r("ExampleNet", "AA:1", -50, ch: 36)])) }

        // A 200×100 picture as the plan: spots keep their place on it.
        let png = dir.appendingPathComponent("plan-in.png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        try store.setPlan(id, from: png)

        let again = HeatmapStore(folder: dir)
        let s = try XCTUnwrap(again.survey(id))
        XCTAssertEqual(again.surveys.count, 2)
        XCTAssertEqual(s.planWidth, 200)
        XCTAssertEqual(s.spots.first?.x ?? 0, 5 * 200 / HeatSurvey.blankSize.width, accuracy: 0.001)
        XCTAssertNotNil(again.plan(s))
    }
}

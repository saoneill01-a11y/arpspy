import XCTest
@testable import ArpSpy

/// The pieces the Mac and iPhone apps share, and the move to the new app ID.
final class SensorShareTests: XCTestCase {
    func testSensorRowFromSensorJSON() throws {
        let json = #"{"ip":"10.20.30.40","mac":"aa:bb:cc:dd:ee:ff","name":"printer-lobby","vendor":"","ports":[80,443,9100],"ms":2.5,"upnp":"LaserJet 400","snmp":"","snmpName":"","ubnt":"","web":"Home"}"#
        let d = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let r = try XCTUnwrap(SensorRow(d))
        XCTAssertEqual(r.ip.description, "10.20.30.40")
        XCTAssertEqual(r.ports, [80, 443, 9100])
        XCTAssertEqual(r.ms, 2.5)
        XCTAssertEqual(r.id, r.ip.value)
        // Kept on the phone as JSON: comes back the same.
        let back = try JSONDecoder().decode(SensorRow.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        XCTAssertNil(SensorRow(["ip": "not an address"]))
    }

    func testCSVCells() {
        XCTAssertEqual(CSV.cell("=1+2"), "\"'=1+2\"")
        XCTAssertEqual(CSV.cell("a,b"), "\"a,b\"")
        XCTAssertEqual(CSV.text(header: ["IP", "Name"], rows: [["10.0.0.1", "say \"hi\""]]), "IP,Name\n10.0.0.1,\"say \"\"hi\"\"\"\n")
        XCTAssertEqual(Exporter.csvCell("-x"), CSV.cell("-x"))
    }

    func testSettingsMoveCopiesOnlyMissingKeys() throws {
        let name = "arpradar-test-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.set("mine", forKey: "kept")
        SettingsMove.copy(["kept": "old", "showOffline": false, "comments": ["aa:bb": "Lobby printer"]], into: d)
        XCTAssertEqual(d.string(forKey: "kept"), "mine")
        XCTAssertEqual(d.object(forKey: "showOffline") as? Bool, false)
        XCTAssertEqual((d.dictionary(forKey: "comments") as? [String: String])?["aa:bb"], "Lobby printer")
    }

    func testMessagesNameThisMac() {
        XCTAssertEqual(SensorPlatform.thisDevice, "this Mac")
    }
}

final class SigningTests: XCTestCase {
    func testTeamOfMissingAppIsNil() {
        XCTAssertNil(Updates.teamID(of: URL(fileURLWithPath: "/nonexistent/Nothing.app")))
    }
}

@MainActor
final class HeatmapFileTests: XCTestCase {
    private func tempStore() -> HeatmapStore {
        HeatmapStore(folder: FileManager.default.temporaryDirectory.appendingPathComponent("hm-\(UUID().uuidString)"))
    }

    func testRoundTripWithPlan() throws {
        let a = tempStore()
        let id = a.create(name: "Example office")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        try FileManager.default.createDirectory(at: a.dir(id), withIntermediateDirectories: true)
        try png.write(to: a.dir(id).appendingPathComponent("plan.png"))
        a.update(id) {
            $0.planFile = "plan.png"; $0.planWidth = 2000; $0.planHeight = 1200
            $0.scale = HeatScale(pixelsPerUnit: 20, metres: false)
            $0.spots = [HeatSpot(x: 100, y: 200, readings: [HeatReading(ssid: "Example-WiFi", bssid: "02:11:22:33:44:55", rssi: -58, channel: 36, band: "5 GHz", widthMHz: 80)])]
            $0.apNames = ["k": "Lobby AP"]
            $0.orgID = UUID()
        }
        let file = try a.exportFile(id)

        let b = tempStore()
        XCTAssertFalse(b.hasCopy(of: file))
        let newID = try b.importFile(file, replace: false)
        XCTAssertEqual(newID, id)
        let s = try XCTUnwrap(b.survey(newID))
        XCTAssertEqual(s.name, "Example office")
        XCTAssertNil(s.orgID)                       // organizations stay per computer
        XCTAssertEqual(s.spots.first?.readings.first?.rssi, -58)
        XCTAssertEqual(s.scale?.pixelsPerUnit, 20)
        XCTAssertEqual(try Data(contentsOf: b.dir(newID).appendingPathComponent("plan.png")), png)

        // Again: a copy of one already here.
        XCTAssertTrue(b.hasCopy(of: file))
        let both = try b.importFile(file, replace: false)
        XCTAssertNotEqual(both, id)
        XCTAssertEqual(b.survey(both)?.name, "Example office 2")
        XCTAssertEqual(try b.importFile(file, replace: true), id)
        XCTAssertEqual(b.surveys.count, 2)
    }

    func testRejectsOtherFilesAndPaths() throws {
        XCTAssertThrowsError(try HeatmapFile.decode(Data("{}".utf8)))
        var s = HeatSurvey(name: "x"); s.planFile = "../../evil.png"
        let data = try HeatmapFile.encode(s, files: ["../../evil.png": Data([1]), "plan.png": Data([2])])
        let back = try HeatmapFile.decode(data)
        XCTAssertNil(back.survey.planFile)
        XCTAssertEqual(Array(back.files.keys), ["plan.png"])
        XCTAssertEqual(HeatmapFile.fileName(HeatSurvey(name: "Floor 1/2")), "Floor 1-2.arpheatmap")
    }
}

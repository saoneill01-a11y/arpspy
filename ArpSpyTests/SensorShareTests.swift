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

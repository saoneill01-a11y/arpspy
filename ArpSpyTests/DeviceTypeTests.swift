import XCTest
@testable import ArpSpy

final class DeviceTypeTests: XCTestCase {
    private func dev(_ name: String = "", vendor: String = "", ports: [UInt16] = [], ubnt: String = "") -> Device {
        var d = Device(ip: IPv4("10.0.0.50")!)
        d.name = name; d.vendor = vendor; d.openPorts = ports; d.ubntModel = ubnt
        return d
    }

    func testNames() {
        XCTAssertEqual(dev("office-ap").kind, .accessPoint)
        XCTAssertEqual(dev("sample-laptop").kind, .computer)
        XCTAssertEqual(dev("BRN-Laser").kind, .printer)
        XCTAssertEqual(dev("Kitchen iPhone").kind, .phone)
        XCTAssertEqual(dev("Living Room TV").kind, .tv)
        XCTAssertEqual(dev("Nintendo Switch").kind, .console)
        XCTAssertEqual(dev("core-switch").kind, .switchDevice)
        XCTAssertEqual(dev(ubnt: "UVC G4 Bullet").kind, .camera)
        XCTAssertEqual(dev(ubnt: "Cloud Gateway Ultra").kind, .router)
        XCTAssertEqual(dev("Sophos XGS 116").kind, .firewall)
        // Short words only match whole: "laptop" isn't an AP, "apple" isn't either.
        XCTAssertNotEqual(dev("apple-thing").kind, .accessPoint)
    }

    func testVendorPortsAndDHCP() {
        XCTAssertEqual(dev(vendor: "Brother Industries").kind, .printer)
        XCTAssertEqual(dev(vendor: "Espressif Inc.").kind, .smartHome)
        XCTAssertEqual(dev(vendor: "Sample Corp", ports: [9100]).kind, .printer)
        XCTAssertEqual(dev(vendor: "Sample Corp", ports: [554, 80]).kind, .camera)
        XCTAssertNil(dev(vendor: "Apple, Inc.").kind)
        XCTAssertEqual(dev(vendor: "TP-Link Systems Inc").kind, .smartHome)
        XCTAssertNil(dev(vendor: "TP-Link Systems Inc", ports: [80, 443]).kind)
        XCTAssertEqual(dev("SampleHomeAssistant").kind, .smartHome)
        var gw = dev(vendor: "Sample Networks"); gw.isDHCPServer = true
        XCTAssertEqual(gw.kind, .router)
    }

    func testMapAndOverride() {
        var d = dev("closet", vendor: "Ubiquiti Inc"); d.mapKind = .switchDevice
        XCTAssertEqual(d.kind, .switchDevice)
        var fw = dev("Sophos XGS"); fw.mapKind = .router
        XCTAssertEqual(fw.kind, .firewall)
        d.typeOverride = .server
        XCTAssertEqual(d.kind, .server)
        XCTAssertEqual(dev().kindSort > dev("printer").kindSort, true)   // unknown sorts last
    }

    func testExportHasType() {
        let row = Exporter.row(dev("office-ap"))
        XCTAssertEqual(Exporter.columns[2], "Type")
        XCTAssertEqual(row[2], "Wi-Fi AP")
        XCTAssertEqual(Exporter.columns[Exporter.responseColumn], "Response (ms)")
    }
}

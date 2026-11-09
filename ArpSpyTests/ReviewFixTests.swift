import XCTest
@testable import ArpSpy

/// Tests for the fixes from the November 8, 2026 review: text off the network, CSV safety, themes, files.
final class ReviewFixTests: XCTestCase {
    func testNetworkTextIsCleaned() {
        XCTAssertEqual("  Printer\u{200B} \u{202E}evil\t\n".cleanedNetworkText(), "Printer evil")
        XCTAssertEqual("\u{1B}[31mred\u{1B}[0m".cleanedNetworkText(), "[31mred[0m")   // ANSI escape bytes dropped
        XCTAssertEqual("abc".cleanedNetworkText(max: 2), "ab…")
        XCTAssertEqual("plain-name.local".cleanedNetworkText(), "plain-name.local")
        var d = Device(ip: IPv4("10.0.0.5")!)
        d.addName("\tNAS\r\n", from: "NetBIOS")
        XCTAssertEqual(d.name, "NAS")
        d.addName("\u{200B}", from: "Bonjour")        // nothing left after cleaning: ignored
        XCTAssertNil(d.names["Bonjour"])
    }

    func testCSVCellsCannotBeFormulas() {
        XCTAssertEqual(Exporter.csvCell("=HYPERLINK(\"http://x\",\"Open\")"), "\"'=HYPERLINK(\"\"http://x\"\",\"\"Open\"\")\"")
        XCTAssertEqual(Exporter.csvCell("+1"), "\"'+1\"")
        XCTAssertEqual(Exporter.csvCell("-5"), "\"'-5\"")
        XCTAssertEqual(Exporter.csvCell("@cmd"), "\"'@cmd\"")
        XCTAssertEqual(Exporter.csvCell("a\rb"), "\"a\rb\"")            // a bare return is quoted too
        XCTAssertEqual(Exporter.csvCell("Office printer"), "Office printer")
        XCTAssertEqual(Exporter.csvCell("10.0.0.1"), "10.0.0.1")
        XCTAssertEqual(Exporter.tsvCell("a\tb\nc"), "a b c")
        let csv = Exporter.csv(header: ["Name"], rows: [["=1+1"]])
        XCTAssertEqual(csv, "Name\n\"'=1+1\"\n")
    }

    func testAccentTextContrast() {
        XCTAssertGreaterThan(AppTheme.luminance(0xffd400), 0.6)     // High contrast dark: yellow → black text
        XCTAssertLessThan(AppTheme.luminance(0x0040dd), 0.6)        // High contrast light: blue → white text
        XCTAssertLessThan(AppTheme.luminance(0x2fd17a), 0.6)        // Radar green → white text
    }

    func testScansFileErrorsAreSpecific() {
        XCTAssertThrowsError(try ScanTransfer.read(Data("not json".utf8))) { e in
            guard case ScanTransfer.Failure.notScans = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try ScanTransfer.read(Data(#"{"version": 1, "scans": []}"#.utf8))) { e in
            guard case ScanTransfer.Failure.notScans = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try ScanTransfer.read(Data(#"{"format": "arpradar-scans", "version": "1", "scans": []}"#.utf8))) { e in
            guard case ScanTransfer.Failure.broken(let what) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(what.contains("version"), what)
        }
        XCTAssertThrowsError(try ScanTransfer.read(Data(#"{"format": "arpradar-scans", "version": 1, "scans": []}"#.utf8))) { e in
            guard case ScanTransfer.Failure.empty = e else { return XCTFail("\(e)") }
        }
    }

    func testPhonesAreNotCameras() {
        func dev(_ name: String, vendor: String = "") -> Device {
            var d = Device(ip: IPv4("10.0.0.50")!); d.name = name; d.vendor = vendor; return d
        }
        XCTAssertEqual(dev("Moto G5").kind, .phone)
        XCTAssertEqual(dev("Moto G6 Play", vendor: "Motorola Mobility").kind, .phone)
        XCTAssertNotEqual(dev("G5").kind, .camera)     // a bare "g5" is no longer taken for a UniFi camera
        var cam = Device(ip: IPv4("10.0.0.51")!); cam.ubntModel = "UVC G4 Bullet"
        XCTAssertEqual(cam.kind, .camera)
        XCTAssertEqual(dev("G4 Instant").kind, .camera)
    }

    func testSNMPCommunityComesFromTheScan() {
        var site = Site(name: "Lab", range: "10.0.0.0/24")
        XCTAssertEqual(site.snmpCommunity, "")
        site.snmpCommunity = "lab-ro"
        let data = try! JSONEncoder().encode(site)
        let back = try! JSONDecoder().decode(Site.self, from: data)
        XCTAssertEqual(back.snmpCommunity, "lab-ro")
        // Old files have no community: decodes as blank, which the scan sends as "public".
        let old = try! JSONDecoder().decode(Site.self, from: Data(#"{"name":"Old","range":"10.0.0.0/24"}"#.utf8))
        XCTAssertEqual(old.snmpCommunity, "")
        var org = Organization(name: "Example")
        org.snmpCommunity = "example-ro"
        let o = try! JSONDecoder().decode(Organization.self, from: try! JSONEncoder().encode(org))
        XCTAssertEqual(o.snmpCommunity, "example-ro")
    }

    func testRecordsRememberTheirSavedScan() throws {
        let id = UUID()
        let r = ScanRecord(date: Date(), range: "10.0.0.0/24", devices: [], siteName: "Main", siteID: id)
        let back = try JSONDecoder().decode(ScanRecord.self, from: try JSONEncoder().encode(r))
        XCTAssertEqual(back.siteID, id)
        let old = try JSONDecoder().decode(ScanRecord.self, from: Data(#"{"id":"\#(UUID().uuidString)","date":0,"range":"x","devices":[]}"#.utf8))
        XCTAssertNil(old.siteID)
    }
}

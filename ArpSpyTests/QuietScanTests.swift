import XCTest
@testable import ArpSpy

/// Quiet scan: what it sends compared with a normal scan, and that organizations remember the setting.
final class QuietScanTests: XCTestCase {
    func testNormalPlanSendsEverything() {
        let p = ScanPlan(quiet: false)
        XCTAssertEqual(p.pingGapMicroseconds, 0)
        XCTAssertTrue(p.knock)
        XCTAssertEqual(p.ports, Ports.scanList)
        XCTAssertEqual(p.connectionsAtOnce, 900)
        XCTAssertTrue(p.webTitles)
        XCTAssertTrue(p.snmp)
    }

    func testQuietPlanSendsLess() {
        let p = ScanPlan(quiet: true)
        XCTAssertGreaterThan(p.pingGapMicroseconds, 0)
        XCTAssertFalse(p.knock)
        XCTAssertEqual(p.ports, [445, 80, 443, 22, 3389])
        XCTAssertLessThan(p.ports.count, Ports.scanList.count)
        XCTAssertEqual(p.connectionsAtOnce, 16)
        XCTAssertFalse(p.webTitles)
        XCTAssertFalse(p.snmp)
        XCTAssertTrue(ScanPlan(quiet: true, snmpInQuiet: true).snmp)
    }

    func testOptionsMakeThePlan() {
        var o = ScanOptions()
        XCTAssertFalse(o.plan.quiet)
        o.quiet = true
        XCTAssertTrue(o.plan.quiet)
    }

    func testOrganizationRemembersScanStyle() throws {
        var org = Organization(name: "Example Clinic")
        XCTAssertFalse(org.quietScan)
        org.quietScan = true
        let back = try JSONDecoder().decode(Organization.self, from: JSONEncoder().encode(org))
        XCTAssertTrue(back.quietScan)
        // Files saved before Quiet existed open as Normal.
        let old = try JSONDecoder().decode(Organization.self, from: Data(#"{"name":"Old"}"#.utf8))
        XCTAssertFalse(old.quietScan)
    }
}

/// Runs a real Normal scan and a real Quiet scan of this Mac's network and prints how they compare.
/// Only when ARPRADAR_LIVE_SCAN is set (it sends real traffic): ARPRADAR_LIVE_SCAN=1 xcodebuild test …
final class QuietScanLiveTests: XCTestCase {
    actor Tally {
        var found = Set<UInt32>(), portsChecked = 0, openPorts = 0, titles = 0, snmp = 0, steps: [String] = []
        func add(_ e: ScanEvent) {
            switch e {
            case .found(let l): found.formUnion(l.map(\.id))
            case .ports(let p): portsChecked += 1; openPorts = p.values.reduce(0) { $0 + $1.count }
            case .webTitles(let t): titles = t.count
            case .snmp(let s): snmp = s.count
            case .progress(_, let s): steps.append(s)
            default: break
            }
        }
    }

    func testCompareOnThisNetwork() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["ARPRADAR_LIVE_SCAN"] == nil, "Set ARPRADAR_LIVE_SCAN to scan this network")
        let ifaces = Interfaces.current()
        let iface = try XCTUnwrap(ifaces.first { $0.bsdName == "en0" } ?? ifaces.first)
        let targets = try IPRangeParser.parse(iface.suggestedRange)
        for quiet in [false, true] {
            var o = ScanOptions(); o.quiet = quiet
            let t = Tally(), start = Date()
            await ScanEngine.run(targets: targets, interfaces: ifaces, options: o, flag: CancelFlag()) { await t.add($0) }
            let secs = Date().timeIntervalSince(start)
            let (found, open, titles, snmp) = await (t.found.count, t.openPorts, t.titles, t.snmp)
            print("LIVE \(quiet ? "Quiet " : "Normal") \(iface.suggestedRange): \(found) devices, \(open) open ports, \(titles) web titles, \(snmp) SNMP, \(String(format: "%.1f", secs)) s")
            XCTAssertGreaterThan(found, 0)
        }
    }
}

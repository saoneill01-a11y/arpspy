import AppKit
import XCTest
@testable import ArpSpy

final class ParserTests: XCTestCase {
    func testSingleAddress() throws {
        XCTAssertEqual(try IPRangeParser.parse("192.168.1.5").map(\.description), ["192.168.1.5"])
    }

    func testLastOctetRange() throws {
        let r = try IPRangeParser.parse("192.168.1.1-254")
        XCTAssertEqual(r.count, 254)
        XCTAssertEqual(r.first?.description, "192.168.1.1")
        XCTAssertEqual(r.last?.description, "192.168.1.254")
    }

    func testFullRangeAcrossSubnets() throws {
        let r = try IPRangeParser.parse("10.0.0.250-10.0.1.5")
        XCTAssertEqual(r.count, 12)
    }

    func testCIDRSkipsNetworkAndBroadcast() throws {
        let r = try IPRangeParser.parse("10.10.20.0/24")
        XCTAssertEqual(r.count, 254)
        XCTAssertEqual(r.first?.description, "10.10.20.1")
        XCTAssertEqual(r.last?.description, "10.10.20.254")
    }

    func testMultipleWithDuplicates() throws {
        let r = try IPRangeParser.parse("192.168.1.1-3, 192.168.1.2 192.168.1.9")
        XCTAssertEqual(r.map(\.description), ["192.168.1.1", "192.168.1.2", "192.168.1.3", "192.168.1.9"])
    }

    func testBadInput() {
        XCTAssertThrowsError(try IPRangeParser.parse("192.168.1"))
        XCTAssertThrowsError(try IPRangeParser.parse("192.168.1.300"))
        XCTAssertThrowsError(try IPRangeParser.parse("192.168.1.10-5"))
        XCTAssertThrowsError(try IPRangeParser.parse("10.0.0.0/33"))
        XCTAssertThrowsError(try IPRangeParser.parse(""))
    }

    func testTooLarge() {
        XCTAssertThrowsError(try IPRangeParser.parse("10.0.0.0/8"))
    }

    func testIPSortsNumerically() {
        XCTAssertLessThan(IPv4("10.0.0.9")!, IPv4("10.0.0.10")!)
    }

    func testArpOutputParsing() {
        let text = """
        ? (192.168.1.1) at 74:ac:b9:1e:22:1 on en0 ifscope [ethernet]
        ? (192.168.1.50) at (incomplete) on en0 ifscope [ethernet]
        ? (192.168.1.255) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
        """
        let t = ARPTable.parseArpOutput(text)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[IPv4("192.168.1.1")!.value], "74:AC:B9:1E:22:01")
    }

    func testOUIParsingAndPrivateMAC() {
        let csv = """
        Registry,Assignment,Organization Name,Organization Address
        MA-L,286FB9,"Example Networks, Ltd.","1 Main St"
        """
        let t = OUIDatabase.parse(csv)
        XCTAssertEqual(t["286FB9"], "Example Networks, Ltd.")
        XCTAssertEqual(OUIDatabase.shared.vendor(for: "5A:2E:C1:93:0B:66"), "Private address")
    }

    /// The real IEEE file has Windows (\r\n) line endings.
    func testOUIParsingWindowsLineEndings() {
        let csv = "Registry,Assignment,Organization Name,Organization Address\r\n"
                + "MA-L,286FB9,\"Example Networks, Ltd.\",\"1 Main St\"\r\n"
                + "MA-L,38E2CA,Sample Corp,2 Side St\r\n"
        let t = OUIDatabase.parse(csv)
        XCTAssertEqual(t.count, 2)
        XCTAssertEqual(t["38E2CA"], "Sample Corp")
    }

    /// The bundled vendor list should load thousands of entries.
    func testBundledOUIFileLoads() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "oui", withExtension: "csv"))
        let t = OUIDatabase.parse(try String(contentsOf: url, encoding: .utf8))
        XCTAssertGreaterThan(t.count, 10_000)
    }

    /// A Bonjour reply that echoes the question and points back to it (DNS name compression).
    func testBonjourReplyParsing() {
        let ip = IPv4("10.0.0.5")!
        let query = NameLookup.mdnsQuery(for: ip, id: 7)
        let qName = Array(query[12..<(query.count - 4)])           // "5.0.0.10.in-addr.arpa"
        var r: [UInt8] = [0, 7, 0x84, 0x00, 0, 1, 0, 1, 0, 0, 0, 0]
        r += qName + [0, 12, 0, 1]                                  // question
        let target: [UInt8] = [8] + Array("Test-NAS".utf8) + [5] + Array("local".utf8) + [0]
        r += [0xC0, 0x0C, 0, 12, 0x80, 1, 0, 0, 0, 120, 0, UInt8(target.count)] + target
        let answers = NameLookup.parsePTRAnswers(r)
        XCTAssertEqual(answers.count, 1)
        XCTAssertEqual(answers.first?.0, ip.value)
        XCTAssertEqual(answers.first?.1, "Test-NAS")
    }

    func testBonjourIgnoresQueries() {
        XCTAssertTrue(NameLookup.parsePTRAnswers(NameLookup.mdnsQuery(for: IPv4("10.0.0.5")!, id: 1)).isEmpty)
    }

    // MARK: Remote wake

    func testRemoteWakeMACFormats() {
        for text in ["3C-52-82-1A-7E-09", "3c:52:82:1a:7e:09", "3c52821a7e09", "3C52.821A.7E09", " 3C 52 82 1A 7E 09 "] {
            XCTAssertEqual(RemoteWake.normalizeMAC(text), "3C:52:82:1A:7E:09", text)
        }
        XCTAssertNil(RemoteWake.normalizeMAC("3C-52-82-1A-7E"))
        XCTAssertNil(RemoteWake.normalizeMAC("3C-52-82-1A-7E-0G"))
        XCTAssertNil(RemoteWake.normalizeMAC("10.20.30.45"))
    }

    func testRemoteWakeBroadcast() {
        XCTAssertEqual(RemoteWake.broadcast(of: IPv4("10.20.30.45")!, prefix: 24)?.description, "10.20.30.255")
        XCTAssertEqual(RemoteWake.broadcast(of: IPv4("172.16.8.20")!, prefix: 22)?.description, "172.16.11.255")
        XCTAssertEqual(RemoteWake.broadcast(of: IPv4("10.44.0.12")!, prefix: 16)?.description, "10.44.255.255")
        XCTAssertNil(RemoteWake.broadcast(of: IPv4("10.0.0.1")!, prefix: 32))
    }

    func testRemoteWakeDestinations() throws {
        var t = RemoteWakeTarget()
        t.ip = "10.20.30.45"
        XCTAssertEqual(try RemoteWake.destinations(for: t).map(\.description), ["10.20.30.45", "10.20.30.255"])
        t.useRelay = true; t.relay = "10.20.30.1"; t.sendToBroadcast = false
        XCTAssertEqual(try RemoteWake.destinations(for: t).map(\.description), ["10.20.30.45", "10.20.30.1"])
        t.sendToIP = false; t.useRelay = false
        XCTAssertThrowsError(try RemoteWake.destinations(for: t))
    }

    func testMagicPacket() {
        let mac: [UInt8] = [0x3C, 0x52, 0x82, 0x1A, 0x7E, 0x09]
        let p = RemoteWake.magicPacket(mac)
        XCTAssertEqual(p.count, 102)
        XCTAssertEqual(Array(p[0..<6]), [UInt8](repeating: 0xFF, count: 6))
        XCTAssertEqual(Array(p[96..<102]), mac)
    }

    /// Saved entries from an older version (missing fields) still load.
    func testRemoteWakeTargetOldFile() throws {
        let json = #"[{"id":"6F1C2E3A-1B2C-4D5E-8F90-A1B2C3D4E5F6","name":"Front desk PC","mac":"3C:52:82:1A:7E:09","ip":"10.20.30.45"}]"#
        let list = try JSONDecoder().decode([RemoteWakeTarget].self, from: Data(json.utf8))
        XCTAssertEqual(list.first?.name, "Front desk PC")
        XCTAssertEqual(list.first?.port, 9)
        XCTAssertEqual(list.first?.prefix, 24)
        XCTAssertEqual(list.first?.sendToBroadcast, true)
    }

    func testRDPFile() {
        XCTAssertEqual(DeviceActions.rdpFile(for: "10.0.0.5"), "full address:s:10.0.0.5\r\nprompt for credentials:i:1\r\n")
    }

    func testPingChecksumValidates() {
        let p = Pinger.echoRequest(id: 0x1234, seq: 1)
        XCTAssertEqual(Pinger.checksum(p), 0)   // a correct checksum sums to zero
    }

    func testPortLabels() {
        XCTAssertEqual(Ports.label(3389), "RDP")
        XCTAssertEqual(Ports.label(12345), "12345")
        var d = Device(ip: IPv4("192.168.1.40")!)
        d.openPorts = [80, 631, 9100]
        XCTAssertEqual(d.portsSort, "HTTP IPP Printer")
    }

    func testMACParsingForWakeOnLAN() {
        XCTAssertEqual(DeviceActions.macBytes("00:11:32:8A:5D:3F"), [0x00, 0x11, 0x32, 0x8A, 0x5D, 0x3F])
        XCTAssertNil(DeviceActions.macBytes(""))
        XCTAssertNil(DeviceActions.macBytes("00:11:32"))
    }

    func testSavedDataRoundTrip() throws {
        var d = Device(ip: IPv4("192.168.1.10")!)
        d.name = "fileserver01"; d.mac = "00:11:32:8A:5D:3F"; d.openPorts = [445]
        var data = StoredData()
        data.known[d.commentKey] = d
        data.favorites = [d.commentKey]
        data.history = [ScanRecord(date: Date(), range: "192.168.1.0/24", devices: [d])]
        let decoded = try JSONDecoder().decode(StoredData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(decoded.known[d.commentKey]?.name, "fileserver01")
        XCTAssertEqual(decoded.favorites, [d.commentKey])
        XCTAssertEqual(decoded.history.first?.devices.first?.openPorts, [445])
    }

    /// Remembered devices missing from a scan come back as grey (offline) rows.
    func testOfflineRows() {
        func dev(_ ip: String, _ mac: String, daysAgo: Double = 0) -> Device {
            var d = Device(ip: IPv4(ip)!); d.mac = mac; d.lastSeen = Date(timeIntervalSinceNow: -daysAgo * 86_400); return d
        }
        let nas = dev("10.0.0.12", "3C:52:82:1A:7E:12")
        let pc = dev("10.0.0.45", "3C:52:82:1A:7E:45", daysAgo: 1)
        let oldPC = dev("10.0.0.45", "3C:52:82:1A:7E:99", daysAgo: 9)     // used .45 before the PC did
        let elsewhere = dev("10.9.0.5", "3C:52:82:1A:7E:05")              // outside the range
        let known = [nas, pc, oldPC, elsewhere].reduce(into: [String: Device]()) { $0[$1.commentKey] = $1 }
        let targets = Set(try! IPRangeParser.parse("10.0.0.1-254").map(\.value))

        let rows = ScanModel.offlineRows(known: known, found: [nas], targets: targets)
        XCTAssertEqual(rows.map(\.mac), ["3C:52:82:1A:7E:45"])   // newest owner of .45 wins
        XCTAssertEqual(rows.first?.isOnline, false)
        XCTAssertTrue(ScanModel.offlineRows(known: known, found: [nas, pc], targets: targets).isEmpty)
    }

    func testKeepsOldNameWhenLookupMisses() {
        var old = Device(ip: IPv4("10.0.0.12")!); old.name = "office-nas"; old.names = ["Bonjour": "office-nas"]
        var now = Device(ip: IPv4("10.0.0.12")!); now.names = ["DNS": "nas.example.lan"]
        let d = ScanModel.keepingOldNames(now, old: old)
        XCTAssertEqual(d.name, "office-nas")
        XCTAssertEqual(d.names, ["Bonjour": "office-nas", "DNS": "nas.example.lan"])
        var named = now; named.name = "nas.example.lan"
        XCTAssertEqual(ScanModel.keepingOldNames(named, old: old).name, "nas.example.lan")   // a fresh name wins
    }

    func testNewDevices() {
        var a = Device(ip: IPv4("10.0.0.12")!); a.mac = "3C:52:82:1A:7E:12"
        var b = Device(ip: IPv4("10.0.0.60")!); b.mac = "3C:52:82:1A:7E:60"
        XCTAssertTrue(ScanModel.newKeys(found: [a, b], known: [:]).isEmpty)          // first scan of a site
        XCTAssertEqual(ScanModel.newKeys(found: [a, b], known: [a.commentKey: a]), [b.commentKey])
    }

    /// data.json written by version 0.2 (no sites, devices without the new fields) still loads.
    func testOldSavedDataLoads() throws {
        let json = #"{"known":{"3C:52:82:1A:7E:12":{"ip":{"value":167772172},"name":"office-nas","mac":"3C:52:82:1A:7E:12","vendor":"Sample Corp","comment":"","isThisMac":false,"isOnline":true,"openPorts":[445],"lastSeen":800000000}},"favorites":[],"history":[{"id":"6F1C2E3A-1B2C-4D5E-8F90-A1B2C3D4E5F6","date":800000000,"range":"10.0.0.0/24","devices":[]}]}"#
        let ipJSON = String(data: try JSONEncoder().encode(IPv4("10.0.0.12")!), encoding: .utf8)!
        let data = Data(json.replacingOccurrences(of: #"{"value":167772172}"#, with: ipJSON).utf8)
        let s = try JSONDecoder().decode(StoredData.self, from: data)
        let d = try XCTUnwrap(s.known["3C:52:82:1A:7E:12"])
        XCTAssertEqual(d.name, "office-nas")
        XCTAssertEqual(d.firstSeen, d.lastSeen)
        XCTAssertTrue(d.names.isEmpty)
        XCTAssertTrue(s.sites.isEmpty)
        XCTAssertNil(s.history.first?.siteName)
    }

    func testSitesRoundTrip() throws {
        var data = StoredData()
        var site = Site(name: "Client A – Main office", range: "10.0.0.0/24", nameServer: "10.0.0.5")
        var d = Device(ip: IPv4("10.0.0.45")!); d.mac = "3C:52:82:1A:7E:45"; d.webTitle = "Login"; d.banners = [22: "OpenSSH 9.6"]
        site.known[d.commentKey] = d
        data.sites = [site]
        let back = try JSONDecoder().decode(StoredData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(back.sites.first?.name, "Client A – Main office")
        XCTAssertEqual(back.sites.first?.known[d.commentKey]?.banners[22], "OpenSSH 9.6")
    }

    func testDescriptionPicksBestSource() {
        var d = Device(ip: IPv4("10.0.0.60")!)
        d.webTitle = "Printer Home"
        XCTAssertEqual(d.details, "Printer Home")
        d.snmpDescr = "Test Printers LaserJet M400\nFirmware 1.2"
        XCTAssertEqual(d.details, "Test Printers LaserJet M400")
        d.upnp = "Test Printers M400"
        XCTAssertEqual(d.details, "Test Printers M400")
    }

    func testWebTitle() {
        XCTAssertEqual(Web.title(in: "<html><head><TITLE lang=en>\n  Sample DiskStation &amp; more &#8211; Login </TITLE>"),
                       "Sample DiskStation & more – Login")
        XCTAssertNil(Web.title(in: "<html><title>   </title>"))
        XCTAssertNil(Web.title(in: "<html>no title</html>"))
    }

    func testUPnP() {
        let reply = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nLocation: http://10.0.0.88:8060/desc.xml\r\nST: upnp:rootdevice\r\n\r\n"
        XCTAssertEqual(UPnP.location(in: reply), "http://10.0.0.88:8060/desc.xml")
        let xml = "<root><device><friendlyName>Living Room TV</friendlyName><manufacturer>Sample Corp</manufacturer><modelName>Stream 4K</modelName><modelNumber>3940X</modelNumber></device></root>"
        let info = UPnP.parseDescription(Data(xml.utf8))
        XCTAssertEqual(info?.friendlyName, "Living Room TV")
        XCTAssertEqual(info?.model, "Sample Corp Stream 4K 3940X")
    }

    func testSNMPEncodeAndParse() {
        XCTAssertEqual(SNMP.oid([1, 3, 6, 1, 4, 1, 311]), [0x06, 0x07, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37])
        XCTAssertEqual(SNMP.decodeOID([0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37]), [1, 3, 6, 1, 4, 1, 311])
        let req = SNMP.request(community: "public", id: 0x4152)
        XCTAssertEqual(req.first, 0x30)
        XCTAssertNil(SNMP.parseResponse(req))                     // a request isn't a response

        func bind(_ oid: [UInt32], _ text: String) -> [UInt8] { SNMP.tlv(0x30, SNMP.oid(oid) + SNMP.tlv(0x04, Array(text.utf8))) }
        let binds = bind(SNMP.sysDescr, "Example Switch 24-port") + bind(SNMP.sysName, "core-sw1") + bind(SNMP.sysLocation, "IT closet")
        let pdu = SNMP.tlv(0xA2, SNMP.integer(0x4152) + SNMP.integer(0) + SNMP.integer(0) + SNMP.tlv(0x30, binds))
        let reply = SNMP.tlv(0x30, SNMP.integer(1) + SNMP.tlv(0x04, Array("public".utf8)) + pdu)
        XCTAssertEqual(SNMP.parseResponse(reply), SNMPInfo(name: "core-sw1", descr: "Example Switch 24-port", location: "IT closet"))
        XCTAssertEqual(SNMP.integer(300), [0x02, 0x02, 0x01, 0x2C])
        XCTAssertEqual(SNMP.integer(0), [0x02, 0x01, 0x00])
    }

    func testBanners() {
        XCTAssertEqual(Banner.firstLine(Array("SSH-2.0-OpenSSH_9.6p1 Ubuntu-3\r\n".utf8)), "OpenSSH 9.6p1 Ubuntu-3")
        XCTAssertEqual(Banner.firstLine(Array("220 printer FTP server ready\r\n".utf8)), "printer FTP server ready")
        XCTAssertNil(Banner.firstLine([0x00, 0x01, 0xFF, 0x0A]))
        XCTAssertEqual(Banner.httpServer("HTTP/1.1 200 OK\r\nServer: nginx/1.24\r\n\r\n"), "nginx/1.24")
        XCTAssertEqual(Banner.httpServer("HTTP/1.0 401 Unauthorized\r\n\r\n"), "Web server")
    }

    func testPortList() {
        XCTAssertEqual(Ports.parseList("22, 80 8000-8002"), [22, 80, 8000, 8001, 8002])
        XCTAssertEqual(Ports.parseList("1-65535")?.count, 65535)
        XCTAssertNil(Ports.parseList("0-10"))
        XCTAssertNil(Ports.parseList("10-5"))
        XCTAssertNil(Ports.parseList("70000"))
        XCTAssertNil(Ports.parseList(""))
        XCTAssertGreaterThanOrEqual(Ports.common.count, 90)
        XCTAssertEqual(Set(Ports.common.map(\.port)).count, Ports.common.count)   // no duplicates
    }

    func testIPv6Neighbors() {
        let text = """
        Neighbor                                Linklayer Address  Netif Expire    St Flgs Prbs
        fd00:1::3e52:82ff:fe1a:7e12             3c:52:82:1a:7e:12    en0 21h52m33s S
        fe80::3e52:82ff:fe1a:7e12%en0           3c:52:82:1a:7e:12    en0 23h59m58s S
        2001:db8:4a::12                         3c:52:82:1a:7e:12    en0 permanent R
        fe80::1%en0                             (incomplete)         en0 expired   N
        ff02::1%en0                             33:33:0:0:0:1        en0 permanent R
        """
        let t = IPv6Neighbors.parse(text)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t["3C:52:82:1A:7E:12"], ["2001:db8:4a::12", "fd00:1::3e52:82ff:fe1a:7e12", "fe80::3e52:82ff:fe1a:7e12"])
        XCTAssertEqual(IPv6Neighbors.kind("fe80::1"), "Link")
        XCTAssertEqual(IPv6Neighbors.kind("fd00:1::5"), "Local")
        XCTAssertEqual(IPv6Neighbors.kind("2001:db8::5"), "Global")
    }

    func testShareLists() {
        let smb = """
        Share                                           Type    Comments
        -------------------------------
        data                                            Disk    Data Share
        Photo Library                                   Disk
        Front Printer                                   Printer Laser in the hall
        IPC$                                            Pipe    IPC Service (Media server)
        C$                                              Disk    Default share

        5 shares listed
        """
        let s = Shares.parseSMB(smb)
        XCTAssertEqual(s.map(\.name), ["data", "Photo Library", "Front Printer"])
        XCTAssertEqual(s.first?.comment, "Data Share")
        XCTAssertEqual(s[1].comment, "")
        XCTAssertEqual(Shares.parseNFS("Exports list on 10.0.0.12:\n/volume1/backup   10.0.0.0/24\n/srv/media  *\n"),
                       ["/volume1/backup", "/srv/media"])
        XCTAssertEqual(Shares.url(IPv4("10.0.0.12")!, share: "Photo Library")?.absoluteString, "smb://10.0.0.12/Photo%20Library")
    }

    /// A radar dot lights up just after the sweep passes it, not before.
    func testRadarGlow() {
        XCTAssertEqual(RadarFace.angle(of: 100, 20), 0, accuracy: 0.01)     // straight up
        XCTAssertEqual(RadarFace.angle(of: 180, 100), 90, accuracy: 0.01)   // 3 o'clock
        let dot = 90.0
        XCTAssertEqual(RadarFace.glow(blipAngle: dot, sweep: 91), 1, accuracy: 0.01)        // just passed
        XCTAssertLessThan(RadarFace.glow(blipAngle: dot, sweep: 89), 0.25)                   // about to be reached
        XCTAssertGreaterThan(RadarFace.glow(blipAngle: dot, sweep: 150), RadarFace.glow(blipAngle: dot, sweep: 300))
    }

    func testSiteNotesOptional() throws {
        let json = #"[{"id":"6F1C2E3A-1B2C-4D5E-8F90-A1B2C3D4E5F6","name":"Client B","range":"172.16.8.0/22"}]"#
        let sites = try JSONDecoder().decode([Site].self, from: Data(json.utf8))
        XCTAssertEqual(sites.first?.notes, "")
        XCTAssertEqual(sites.first?.nameServer, "")
    }

    // MARK: Tools

    func testTracerouteLines() {
        XCTAssertEqual(TraceParser.hop(" 1  gateway (10.0.0.1)  1.234 ms"), Hop(number: 1, address: "10.0.0.1", name: "gateway", ms: 1.234))
        XCTAssertEqual(TraceParser.hop(" 2  10.0.0.9 (10.0.0.9)  9.8 ms"), Hop(number: 2, address: "10.0.0.9", name: "", ms: 9.8))
        XCTAssertEqual(TraceParser.hop(" 3  *"), Hop(number: 3, address: "*", name: "", ms: nil))
        XCTAssertNil(TraceParser.hop("traceroute to example.com (93.184.215.14), 30 hops max"))
    }

    func testDNSLookup() {
        XCTAssertEqual(DNSTool.arguments(name: "10.0.0.5", type: "PTR", server: "10.0.0.2").suffix(3), ["@10.0.0.2", "-x", "10.0.0.5"])
        XCTAssertEqual(DNSTool.arguments(name: "example.lan", type: "MX", server: "").suffix(2), ["example.lan", "MX"])
        let out = "fileserver.example.lan.\t3600\tIN\tA\t10.0.0.20\nexample.lan.  300 IN MX 10 mail.example.lan.\n;; Query time: 4 msec\n;; SERVER: 10.0.0.5#53(10.0.0.5) (UDP)\n"
        let p = DNSTool.parse(out)
        XCTAssertEqual(p.answers.map(\.data), ["10.0.0.20", "10 mail.example.lan."])
        XCTAssertEqual(p.answers.first?.name, "fileserver.example.lan")
        XCTAssertEqual(p.ms, 4)
        XCTAssertEqual(p.server, "10.0.0.5")
    }

    func testDNSKeepsOnlyOwnRecords() {
        let out = """
        autodiscover.example.com. 3600 IN CNAME autodiscover.outlook.com.
        autodiscover.outlook.com. 60 IN CNAME autod.ms-acdc.office.com.
        autod.ms-acdc.office.com. 30 IN A 52.96.0.1
        """
        let own = DNSTool.ownRecords(DNSTool.parse(out).answers, asked: "Autodiscover.Example.com.")
        XCTAssertEqual(own.map(\.data), ["autodiscover.outlook.com."])
        let followed = DNSTool.arrange(DNSTool.parse(out).answers, asked: "autodiscover.example.com", follow: true)
        XCTAssertEqual(followed.map(\.depth), [0, 1, 2])
        XCTAssertEqual(DNSTool.askedName("10.0.0.5", type: "PTR"), "5.0.0.10.in-addr.arpa")
    }

    func testDNSAllQueries() {
        let q = DNSTool.allQueries("example.lan.")
        XCTAssertTrue(q.contains { $0 == ("example.lan", "MX") })
        XCTAssertTrue(q.contains { $0 == ("_dmarc.example.lan", "TXT") })
        XCTAssertTrue(q.contains { $0 == ("_ldap._tcp.dc._msdcs.example.lan", "SRV") })
        XCTAssertTrue(q.contains { $0 == ("autodiscover.example.lan", "A") })
        XCTAssertTrue(q.contains { $0 == ("selector1._domainkey.example.lan", "TXT") })
        XCTAssertEqual(Set(q.map { "\($0.name) \($0.type)" }).count, q.count)   // nothing asked twice
        XCTAssertFalse(q.contains { $0.type == "ANY" })
        XCTAssertEqual(DNSTool.types.first, "All")
    }

    @MainActor func testActivityTracking() {
        let a = UUID(), b = UUID()
        Activity.shared.set(a, true); Activity.shared.set(b, true)
        Activity.shared.set(a, false)
        XCTAssertTrue(Activity.shared.busy)
        Activity.shared.set(b, false)
        XCTAssertFalse(Activity.shared.busy)
    }

    func testSubnetCalculator() throws {
        let s = try XCTUnwrap(SubnetInfo.parse("172.16.8.20/22"))
        XCTAssertEqual(s.network.description, "172.16.8.0")
        XCTAssertEqual(s.mask.description, "255.255.252.0")
        XCTAssertEqual(s.broadcast.description, "172.16.11.255")
        XCTAssertEqual(s.hosts, 1022)
        XCTAssertEqual(s.kind, "Private (RFC 1918)")
        XCTAssertEqual(SubnetInfo.parse("172.16.8.20 255.255.252.0"), s)
        XCTAssertNil(SubnetInfo.parse("10.0.0.1 255.0.255.0"))       // not a real mask
        XCTAssertEqual(SubnetInfo.parse("100.64.1.1/10")?.kind, "Carrier-grade NAT (RFC 6598)")
        XCTAssertEqual(SubnetInfo.parse("10.0.0.1/31")?.hosts, 2)
    }

    func testConnectionInfoParsing() {
        let packet = "server_identifier (ip): 10.0.0.2\nrouter (ip_mult): {10.0.0.1}\ndomain_name_server (ip_mult): {10.0.0.2, 10.0.0.15}\ndomain_name (string): lan\n"
        let p = ConnectionInfo.parsePacket(packet)
        XCTAssertEqual(p["router"], ["10.0.0.1"])
        XCTAssertEqual(p["domain_name_server"], ["10.0.0.2", "10.0.0.15"])
        let (start, end) = ConnectionInfo.parseLease("  LeaseExpirationTime : 11/06/2026 20:21:55\n  LeaseStartTime : 11/05/2026 20:21:55\n")
        XCTAssertEqual(end?.timeIntervalSince(start ?? Date()), 86_400)
    }

    func testSpeedResult() throws {
        let json = #"{"dl_throughput": 106415496, "ul_throughput": 37917256, "responsiveness": 1288.0, "base_rtt": 12.5}"#
        let r = try XCTUnwrap(SpeedResult.parse(Data(json.utf8), site: "Home"))
        XCTAssertEqual(r.downMbps, 106.4, accuracy: 0.1)
        XCTAssertEqual(r.rating, "High")
        XCTAssertNil(SpeedResult.parse(Data("not json".utf8), site: ""))
    }

    func testPingStats() {
        let s = PingJob.stats([2, 4, nil, 6])
        XCTAssertEqual(s.sent, 4); XCTAssertEqual(s.lost, 1)
        XCTAssertEqual(s.avg, 4); XCTAssertEqual(s.min, 2); XCTAssertEqual(s.max, 6)
        XCTAssertEqual(s.jitter, 2)
        XCTAssertEqual(s.last, 6)
    }

    func testWiFiChannels() {
        XCTAssertEqual(WiFiText.centre(primary: 149, widthMHz: 80, band: "5 GHz"), 155)
        XCTAssertEqual(WiFiText.centre(primary: 36, widthMHz: 40, band: "5 GHz"), 38)
        XCTAssertEqual(WiFiText.centre(primary: 6, widthMHz: 20, band: "2.4 GHz"), 6)
        XCTAssertEqual(WiFiText.centre(primary: 5, widthMHz: 80, band: "6 GHz"), 7)
        func n(_ ch: Int, _ rssi: Int) -> NearbyNetwork {
            NearbyNetwork(id: "\(ch)\(rssi)", ssid: "", bssid: "", rssi: rssi, channel: ch, band: "2.4 GHz", widthMHz: 20, security: "")
        }
        XCTAssertEqual(WiFiScanner.advice([n(6, -50), n(6, -60), n(1, -80)], band: "2.4 GHz"),
                       "Channel 6 is the busiest here; channel 11 has the least overlap.")
    }

    func testPlaceholderNamesSkipped() {
        XCTAssertFalse(NameLookup.isUsefulName("Unknown"))
        XCTAssertFalse(NameLookup.isUsefulName("  "))
        XCTAssertTrue(NameLookup.isUsefulName("core-sw1"))
    }

    func testSiteDNSQuery() {
        let q = NameLookup.dnsQuery(for: IPv4("10.0.0.5")!, id: 9)
        XCTAssertEqual(q[2], 0x01)   // recursion desired
        XCTAssertEqual(Array(q[3...]), Array(NameLookup.mdnsQuery(for: IPv4("10.0.0.5")!, id: 9)[3...]))
    }

    func testExcelFile() throws {
        XCTAssertEqual(Zip.crc32(Data("123456789".utf8)), 0xCBF43926)
        XCTAssertEqual(Exporter.columnName(0), "A")
        XCTAssertEqual(Exporter.columnName(26), "AA")
        var d = Device(ip: IPv4("10.0.0.12")!)
        d.name = "office-nas <main> & \u{1}backup"; d.responseMs = 3.4
        let data = Exporter.xlsx([d], sheetName: "Client A: Main")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arpspy-test.xlsx")
        try data.write(to: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-tq", url.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "the .xlsx isn't a valid zip")
        let sheet = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(sheet.contains("office-nas &lt;main&gt; &amp; backup"))
        XCTAssertTrue(sheet.contains("<v>3</v>"))
        XCTAssertTrue(sheet.contains("name=\"Client A Main\""))
    }

    func testGenericTableExport() {
        let csv = Exporter.csv(header: ["Name", "Answer"], rows: [["example.lan", "\"v=spf1 -all\""]])
        XCTAssertEqual(csv, "Name,Answer\nexample.lan,\"\"\"v=spf1 -all\"\"\"\n")
        let x = String(decoding: Exporter.xlsx(header: ["TTL"], rows: [["300"]], widths: [8], numberColumns: [0]), as: UTF8.self)
        XCTAssertTrue(x.contains("<v>300</v>"))
    }

    // MARK: Organizations

    func testOrgDomainsAndDataRoundTrip() throws {
        XCTAssertEqual(Organization.parseDomains(" Example-A.com, example-a.org.;  "), ["example-a.com", "example-a.org"])
        var d = OrgData()
        let org = Organization(name: "Client A", domains: ["example-a.com"], notes: "VPN ClientA-S2S")
        d.orgs = [org]
        d.items = [SavedItem(orgID: org.id, kind: .dns, title: "DNS lookup · example-a.com (All)", summary: "3 records",
                             table: SavedTable(header: ["Name", "Type"], rows: [["example-a.com", "MX"]]), note: "before move")]
        let back = try JSONDecoder().decode(OrgData.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back.orgs.first?.domains, ["example-a.com"])
        XCTAssertEqual(back.items.first?.note, "before move")
        XCTAssertEqual(back.items.first?.table.rows, [["example-a.com", "MX"]])
        // Older files without newer fields still load.
        let old = try JSONDecoder().decode(OrgData.self, from: Data(#"{"orgs":[{"name":"Client B"}]}"#.utf8))
        XCTAssertEqual(old.orgs.first?.name, "Client B")
        XCTAssertTrue(old.items.isEmpty)
    }

    func testSiteKeepsOrganization() throws {
        var site = Site(name: "Main office", range: "10.0.0.0/24")
        site.orgID = UUID()
        let back = try JSONDecoder().decode(Site.self, from: JSONEncoder().encode(site))
        XCTAssertEqual(back.orgID, site.orgID)
    }

    func testWorkbookWithSeveralSheets() throws {
        XCTAssertEqual(Exporter.sheetNames(["DNS lookup", "DNS lookup", "a/b:c", String(repeating: "x", count: 40)]),
                       ["DNS lookup", "DNS lookup (2)", "abc", String(repeating: "x", count: 31)])
        let data = Exporter.workbook([
            .init(name: "Overview", header: ["", ""], rows: [["Organization", "Client A"]], widths: [20, 40]),
            .init(name: "Ping", header: ["Target", "Sent"], rows: [["10.0.0.1", "60"]], widths: [20, 8], numberColumns: [1]),
        ])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arpspy-org-test.xlsx")
        try data.write(to: url)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-tq", url.path]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("worksheets/sheet2.xml"))
        XCTAssertTrue(text.contains("<sheet name=\"Ping\" sheetId=\"2\""))
        XCTAssertTrue(text.contains("<v>60</v>"))
    }

    func testTimelineGroupsSurveys() {
        let org = UUID(), sv = UUID()
        let t = SavedTable(header: [], rows: [])
        var a = SavedItem(orgID: org, kind: .speedTest, title: "speed", summary: "", table: t, surveyID: sv); a.date = Date(timeIntervalSince1970: 100)
        var b = SavedItem(orgID: org, kind: .wifi, title: "wifi", summary: "", table: t, surveyID: sv); b.date = Date(timeIntervalSince1970: 50)
        var s = SavedItem(orgID: org, kind: .survey, title: "survey", summary: "", table: t, surveyID: sv); s.date = Date(timeIntervalSince1970: 110)
        var d = SavedItem(orgID: org, kind: .dns, title: "dns", summary: "", table: t); d.date = Date(timeIntervalSince1970: 200)
        let rows = OrgStore.timeline([a, b, s, d])
        XCTAssertEqual(rows.map(\.item.title), ["dns", "survey", "wifi", "speed"])
        XCTAssertEqual(rows.map(\.indented), [false, false, true, true])
    }

    func testOrganizationWorkbook() throws {
        let org = Organization(name: "Client A", domains: ["example-a.com"], notes: "VPN ClientA-S2S")
        let items = [
            SavedItem(orgID: org.id, kind: .dns, title: "DNS lookup · example-a.com (All)", summary: "1 records",
                      table: SavedTable(header: ["Name", "Type", "TTL", "Answer"], rows: [["example-a.com", "MX", "300", "10 mail.example-a.com."]],
                                        widths: [30, 8, 8, 40], numberColumns: [2])),
            SavedItem(orgID: org.id, kind: .speedTest, title: "Speed test", summary: "211 down",
                      table: SavedTable(header: ["Measure", "Value"], rows: [["Download", "211 Mb/s"]])),
        ]
        let data = OrgStore.workbook(org: org, items: items, sites: [Site(name: "Main office", range: "10.0.0.0/24")])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arpspy-org-workbook.xlsx")
        try data.write(to: url)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("<sheet name=\"Overview\""))
        XCTAssertTrue(text.contains("worksheets/sheet3.xml"))
        XCTAssertTrue(text.contains("Site: Main office"))
    }

    func testDrafts() throws {
        let hops = [Hop(number: 1, address: "10.0.0.1", name: "gateway", ms: 1.2), Hop(number: 2, address: "*", name: "", ms: nil)]
        let t = try XCTUnwrap(Drafts.traceroute(target: "1.1.1.1", hops: hops))
        XCTAssertEqual(t.table.rows[1][2], "no answer")
        XCTAssertNil(Drafts.dns(target: "example.lan", type: "A", server: "", answers: []))
        let a = DNSAnswer(name: "example.lan", type: "MX", ttl: 300, data: "10 mail.example.lan.")
        var chained = DNSAnswer(name: "mail.example.lan", type: "A", ttl: 60, data: "10.0.0.25"); chained.depth = 1
        let d = try XCTUnwrap(Drafts.dns(target: "example.lan", type: "All", server: "10.0.0.5", answers: [a, chained]))
        XCTAssertEqual(d.summary, "1 records from 10.0.0.5")
        XCTAssertEqual(d.table.rows[1][0], "↳ mail.example.lan")
        let r = SpeedResult(date: Date(), site: "Main office", downMbps: 211, upMbps: 19, rpm: 640, idleMs: 12)
        XCTAssertTrue(Drafts.speed(r).summary.hasPrefix("211 down / 19 up"))
    }

    func testCSVEscaping() {
        var d = Device(ip: IPv4("192.168.1.10")!)
        d.name = "fileserver01"; d.comment = "NAS, \"back\" closet"
        let csv = Exporter.csv([d])
        XCTAssertTrue(csv.contains("\"NAS, \"\"back\"\" closet\""))
    }

    func testDHCPRange() throws {
        let r = try XCTUnwrap(DHCPRange("10.0.0.100-199, 10.0.0.220-10.0.0.250"))
        XCTAssertTrue(r.contains(IPv4("10.0.0.100")!))
        XCTAssertTrue(r.contains(IPv4("10.0.0.199")!))
        XCTAssertFalse(r.contains(IPv4("10.0.0.200")!))
        XCTAssertTrue(r.contains(IPv4("10.0.0.230")!))
        XCTAssertFalse(r.contains(IPv4("10.0.0.5")!))
        XCTAssertEqual(r.short, "10.0.0.100-199, 10.0.0.220-250")
        XCTAssertNil(DHCPRange(""))
        XCTAssertNil(DHCPRange("10.0.0.300-400"))
        XCTAssertTrue(DHCPRange.isValid("  "))
        XCTAssertFalse(DHCPRange.isValid("next to the printer"))
    }

    func testSiteKeepsDHCPRangeAndExportColumn() throws {
        var site = Site(name: "Main office", range: "10.0.0.0/24")
        site.dhcpRange = "10.0.0.100-199"
        let back = try JSONDecoder().decode(Site.self, from: JSONEncoder().encode(site))
        XCTAssertEqual(back.dhcpRange, "10.0.0.100-199")
        let old = try JSONDecoder().decode(Site.self, from: Data(#"{"name":"Old","range":"10.0.0.0/24"}"#.utf8))
        XCTAssertEqual(old.dhcpRange, "")

        let a = Device(ip: IPv4("10.0.0.150")!)
        let b = Device(ip: IPv4("10.0.0.5")!)
        let t = Exporter.deviceTable([a, b], dhcp: DHCPRange(site.dhcpRange))
        XCTAssertEqual(t.header.last, "In DHCP range")
        XCTAssertEqual(t.rows.map { $0.last }, ["Yes", "No"])
        XCTAssertEqual(t.widths.count, t.header.count)
        XCTAssertEqual(Exporter.deviceTable([a], dhcp: nil).header, Exporter.columns)
    }

    func testThemesHaveLightAndDarkColours() {
        XCTAssertNil(AppTheme.system.palette)
        for t in AppTheme.allCases where t != .system {
            XCTAssertNotNil(t.palette, t.title)
            let ns = AppTheme.nsColor(t.palette!.bg)
            var light = NSColor.clear, dark = NSColor.clear
            NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = ns.usingColorSpace(.sRGB)! }
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = ns.usingColorSpace(.sRGB)! }
            XCTAssertGreaterThan(light.brightnessComponent, dark.brightnessComponent, t.title)
        }
        XCTAssertEqual(Set(AppTheme.allCases.map(\.title)).count, AppTheme.allCases.count)
    }

    func testBasicHidesExpertColumnsOnly() {
        XCTAssertEqual(Set(AppMode.advancedColumns), ["description", "mac", "ports", "response"])
        XCTAssertLessThan(RowDensity.compact.padding, RowDensity.roomy.padding)
        XCTAssertEqual(TextSize.medium.points, 13)
    }

    func testHelpTopicsAreComplete() {
        XCTAssertEqual(HelpTopic.all.count, 11)
        XCTAssertEqual(Set(HelpTopic.all.map(\.id)).count, HelpTopic.all.count)
        for t in HelpTopic.all {
            XCTAssertFalse(t.title.isEmpty, t.id)
            XCTAssertFalse(t.lead.isEmpty, t.id)
            XCTAssertFalse(t.steps.isEmpty, t.id)
            XCTAssertTrue(t.steps.allSatisfy { !$0.text.isEmpty }, t.id)
            // Every ** opens and closes, so the bold shows instead of stars.
            for s in t.steps { XCTAssertEqual(s.text.components(separatedBy: "**").count % 2, 1, s.text) }
        }
        XCTAssertTrue(HelpTopic.all.first { $0.id == "orgs" }!.advancedOnly)
        XCTAssertTrue(HelpTopic.all.first { $0.id == "sites" }!.needsAdvanced)
        XCTAssertFalse(HelpTopic.all.first { $0.id == "appearance" }!.needsAdvanced)
    }

    func testHelpSearch() {
        XCTAssertEqual(HelpTopic.matching("").count, HelpTopic.all.count)
        XCTAssertEqual(HelpTopic.matching("   ").count, HelpTopic.all.count)
        XCTAssertTrue(HelpTopic.matching("DHCP").contains { $0.id == "sites" })
        XCTAssertTrue(HelpTopic.matching("dhcp").contains { $0.id == "sites" })
        XCTAssertEqual(HelpTopic.matching("mark outside dhcp").first?.id, "sites")
        XCTAssertTrue(HelpTopic.matching("location").contains { $0.id == "trouble" })
        XCTAssertTrue(HelpTopic.matching("zzqx").isEmpty)
    }

    func testHelpExplainsSavingScans() {
        let topic = HelpTopic.all.first { $0.id == "sites" }!
        XCTAssertEqual(topic.title, "Saved scans")
        XCTAssertEqual(HelpTopic.matching("standalone").first?.id, "sites")
        XCTAssertTrue(HelpTopic.matching("New Scan").contains { $0.id == "sites" })
    }

    func testOrganizationSettingsComeFromItsScans() throws {
        // Older organizations.json has no name server or DHCP range.
        let old = try JSONDecoder().decode(Organization.self, from: Data(#"{"name":"Example Dental","domains":["exampledental.com"]}"#.utf8))
        XCTAssertEqual(old.nameServer, "")
        XCTAssertEqual(old.dhcpRange, "")

        var branch = Site(name: "Branch", range: "10.20.40.0/24", nameServer: "10.20.40.5")
        branch.orgID = old.id
        var main = Site(name: "Main office", range: "10.20.30.0/24")
        main.orgID = old.id
        main.dhcpRange = "10.20.30.100-10.20.30.199"
        var other = Site(name: "Another", range: "172.16.8.0/23", nameServer: "172.16.8.2")
        other.orgID = UUID()
        let filled = ScanModel.filledFromScans(old, sites: [main, other, branch])
        XCTAssertEqual(filled.nameServer, "10.20.40.5")
        XCTAssertEqual(filled.dhcpRange, "10.20.30.100-10.20.30.199")

        // Settings already set on the organization are kept.
        var set = old
        set.nameServer = "10.20.30.5"
        XCTAssertEqual(ScanModel.filledFromScans(set, sites: [branch]).nameServer, "10.20.30.5")

        // The organization's value wins; the scan's own is only a fallback.
        XCTAssertEqual(Site.pick("10.20.30.5", "10.0.0.1"), "10.20.30.5")
        XCTAssertEqual(Site.pick(" ", "10.0.0.1"), "10.0.0.1")
        XCTAssertEqual(Site.pick(nil, "10.0.0.1"), "10.0.0.1")
    }

    func testFindsDHCPAndNameServers() throws {
        func dev(_ ip: String, ports: [UInt16], online: Bool = true, vendor: String = "Dell Inc.") -> Device {
            var d = Device(ip: IPv4(ip)!); d.openPorts = ports; d.isOnline = online; d.vendor = vendor; return d
        }
        let targets = Set(try IPRangeParser.parse("10.20.30.0/24").map(\.value))
        let devices = [dev("10.20.30.6", ports: [53, 389]), dev("10.20.30.5", ports: [53, 445]),
                       dev("10.20.30.1", ports: [22, 443]), dev("10.20.30.9", ports: [53], online: false),
                       dev("10.20.30.40", ports: [53], vendor: "Apple, Inc.")]
        let s = NetServers.find(devices: devices, targets: targets, leaseDHCP: "10.20.30.1",
                                leaseDNS: ["10.20.30.5", "10.20.30.6", "8.8.8.8"])
        XCTAssertEqual(s.dhcp?.description, "10.20.30.1")
        // The lease's DNS servers in the range; not ones outside it, and not other devices with port 53.
        XCTAssertEqual(s.dns.map(\.description), ["10.20.30.5", "10.20.30.6"])
        // No lease on this network (a VPN): devices with port 53, but not offline ones or Apple TVs / HomePods.
        let overVPN = NetServers.find(devices: devices, targets: targets, leaseDHCP: "192.168.1.1", leaseDNS: ["192.168.1.1"])
        XCTAssertNil(overVPN.dhcp)
        XCTAssertEqual(overVPN.dns.map(\.description), ["10.20.30.5", "10.20.30.6"])
        XCTAssertEqual(s.role(of: IPv4("10.20.30.1")!), "DHCP server")
        XCTAssertEqual(s.role(of: IPv4("10.20.30.6")!), "Name server")
        XCTAssertNil(s.role(of: IPv4("10.20.30.9")!))
        XCTAssertEqual(s.summary, "DHCP 10.20.30.1 · DNS 10.20.30.5, 10.20.30.6")

        let nothing = NetServers.find(devices: [], targets: targets, leaseDHCP: "192.168.1.1", leaseDNS: ["192.168.1.1"])
        XCTAssertTrue(nothing.isEmpty)

        // The "Use … for …" offer: only when the organization's name server is blank or not one of those found.
        XCTAssertEqual(ScanModel.nameServerToOffer(current: "", found: s)?.description, "10.20.30.5")
        XCTAssertEqual(ScanModel.nameServerToOffer(current: "10.0.0.9", found: s)?.description, "10.20.30.5")
        XCTAssertNil(ScanModel.nameServerToOffer(current: " 10.20.30.6", found: s))
        XCTAssertNil(ScanModel.nameServerToOffer(current: "", found: NetServers()))

        // Scans saved before this keep loading, with no servers.
        let old = try JSONDecoder().decode(ScanRecord.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":0,"range":"10.20.30.0/24","devices":[]}"#.utf8))
        XCTAssertTrue(old.servers.isEmpty)
    }

    @MainActor func testWindowOpenedFromOrganizationKnowsItOnce() {
        let store = OrgStore.shared
        let org = UUID()
        store.launch(from: org)
        XCTAssertEqual(store.takeLaunch(), org)
        XCTAssertNil(store.takeLaunch(), "a second window opened later isn't from the organization")
    }

    func testDNSGroupedByType() throws {
        let answers = [
            DNSAnswer(name: "example-a.com", type: "TXT", ttl: 3600, data: "\"v=spf1 -all\""),
            DNSAnswer(name: "example-a.com", type: "A", ttl: 300, data: "203.0.113.10"),
            DNSAnswer(name: "www.example-a.com", type: "CNAME", ttl: 300, data: "example-a.com"),
            DNSAnswer(name: "autodiscover.example-a.com", type: "CNAME", ttl: 3600, data: "autodiscover.example-mail.net"),
            DNSAnswer(name: "autodiscover.example-mail.net", type: "A", ttl: 60, data: "198.51.100.7", depth: 1),
            DNSAnswer(name: "example-a.com", type: "MX", ttl: 3600, data: "10 mail.example-a.com"),
        ]
        let sections = DNSTool.sections(answers)
        XCTAssertEqual(sections.map(\.heading), ["A · 1 · IPv4 addresses", "CNAME · 2 · aliases", "MX · 1 · mail servers", "TXT · 1 · text (SPF, verification)"])
        // CNAMEs sorted by name; where one leads stays right under it (not in the A group).
        let cname = sections[1].lines
        XCTAssertEqual(cname.map(\.name), ["autodiscover.example-a.com", "autodiscover.example-mail.net", "www.example-a.com"])
        XCTAssertEqual(cname[1].depth, 1)
        XCTAssertEqual(cname[1].type, "A")

        // A saved lookup groups the same way.
        let saved = try XCTUnwrap(Drafts.dns(target: "example-a.com", type: "All", server: "", answers: answers)).table
        let savedSections = try XCTUnwrap(saved.dnsSections())
        XCTAssertEqual(savedSections.map(\.heading), sections.map(\.heading))
        let followed = savedSections[1].lines[1]
        XCTAssertEqual([followed.name, followed.ttl, followed.type, followed.data], ["autodiscover.example-mail.net", "60", "A", "198.51.100.7"])
        XCTAssertEqual(followed.depth, 1)
        XCTAssertNil(SavedTable(header: ["Port", "Service"], rows: []).dnsSections())
    }

    func testSavedDNSHidesCNAMEChainUnlessFollowing() throws {
        let answers = [
            DNSAnswer(name: "autodiscover.example-a.com", type: "CNAME", ttl: 300, data: "autodiscover.example-mail.net"),
            DNSAnswer(name: "autodiscover.example-mail.net", type: "A", ttl: 60, data: "203.0.113.7", depth: 1),
            DNSAnswer(name: "example-a.com", type: "MX", ttl: 300, data: "10 mail.example-a.com"),
        ]
        let table = try XCTUnwrap(Drafts.dns(target: "example-a.com", type: "All", server: "", answers: answers)).table
        XCTAssertTrue(table.hasCNAMEChain)
        XCTAssertEqual(table.withoutCNAMEChain().rows.map { $0[0] }, ["autodiscover.example-a.com", "example-a.com"])
        XCTAssertFalse(table.withoutCNAMEChain().hasCNAMEChain)

        let org = Organization(name: "Client A")
        let item = SavedItem(orgID: org.id, kind: .dns, title: "DNS lookup · example-a.com (All)", summary: "2 records", table: table)
        let hidden = OrgStore.workbook(org: org, items: [item], sites: [], followCNAMEs: false)
        let shown = OrgStore.workbook(org: org, items: [item], sites: [], followCNAMEs: true)
        XCTAssertLessThan(hidden.count, shown.count)
    }

    // MARK: .arpradar files (shared with ARPradar for Windows)

    func testScanTransferRoundTrip() throws {
        var d = Device(ip: IPv4("10.20.30.10")!)
        d.mac = "00:1A:2B:00:00:0A"; d.name = "NAS-01"; d.vendor = "Sample Storage Inc."
        d.names = ["NetBIOS": "NAS-01"]; d.openPorts = [22, 445]; d.banners = [22: "OpenSSH 9.6"]; d.ipv6 = ["2001:db8::10"]
        d.firstSeen = Date(timeIntervalSince1970: 1_790_000_000); d.lastSeen = Date(timeIntervalSince1970: 1_790_100_000)
        var site = Site(name: "Main office", range: "10.20.30.1-254", nameServer: "10.20.30.10")
        site.known[d.commentKey] = d
        site.lastScan = ScanRecord(date: d.lastSeen, range: site.range, devices: [d], siteName: site.name)
        let data = try ScanTransfer.export([site], organization: { _ in "Example Clinic" }, appVersion: "0.4")
        let file = try ScanTransfer.read(data)
        XCTAssertEqual(file.scans.first?.organization, "Example Clinic")
        let back = ScanTransfer.site(from: file.scans[0], name: "Main office", orgID: nil)
        let b = try XCTUnwrap(back.known["00:1A:2B:00:00:0A"])
        XCTAssertEqual(b.ip, d.ip); XCTAssertEqual(b.name, "NAS-01"); XCTAssertEqual(b.openPorts, [22, 445])
        XCTAssertEqual(b.banners[22], "OpenSSH 9.6"); XCTAssertEqual(b.firstSeen.timeIntervalSince1970, d.firstSeen.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(back.lastScan?.devices.count, 1); XCTAssertEqual(back.nameServer, "10.20.30.10")
    }

    @MainActor func testDNSDomainBoxCleansWebAddresses() {
        XCTAssertEqual(DNSRun.clean(" https://WWW.Example.com/login?x=1 "), "www.example.com")
        XCTAssertEqual(DNSRun.clean("example.com:8443"), "example.com")
        XCTAssertEqual(DNSRun.clean("example.com."), "example.com")
        XCTAssertEqual(DNSRun.clean("10.0.0.5"), "10.0.0.5")
        XCTAssertEqual(DNSRun.clean("fe80::1"), "fe80::1")
        let r = DNSRun(); r.domain = "https://www.example.com/"
        XCTAssertEqual(r.base, "example.com")
        r.domain = "10.0.0.5"; r.checkAll()
        XCTAssertTrue(r.lookUpOnly); XCTAssertEqual(r.token, 1)
    }

    func testReadsWindowsFile() throws {
        // What ARPradar for Windows writes (made-up devices; dates with milliseconds, as JavaScript writes them).
        let json = """
        {"format":"arpradar-scans","version":1,"exported":"2026-11-07T07:04:38.424Z","app":"ARPradar 0.6.0 for Windows",
         "scans":[{"name":"Lab bench","organization":null,"range":"172.16.5.1-30","nameServer":"","dhcpRange":"","notes":"",
           "devices":[{"ip":"172.16.5.7","mac":"00:1a:2b:00:00:07","name":"BENCH-PC","names":{"NetBIOS":"BENCH-PC","This PC":"BENCH-PC"},
             "openPorts":[3389],"firstSeen":"2026-11-07T07:04:38.424Z","lastSeen":"2026-11-07T07:04:38.424Z","banners":{},"thisComputer":true,"extra":1}],
           "lastScan":null}]}
        """
        let file = try ScanTransfer.read(Data(json.utf8))
        let site = ScanTransfer.site(from: file.scans[0], name: "Lab bench", orgID: nil)
        let d = try XCTUnwrap(site.known["00:1A:2B:00:00:07"])
        XCTAssertTrue(d.isThisMac); XCTAssertEqual(d.openPorts, [3389]); XCTAssertNil(site.lastScan)
        XCTAssertThrowsError(try ScanTransfer.read(Data("{\"format\":\"other\"}".utf8)))
        XCTAssertThrowsError(try ScanTransfer.read(Data(#"{"format":"arpradar-scans","version":9,"scans":[]}"#.utf8)))
    }
}

// MARK: - Host-name validation, SPF /prefix terms, UniFi address clean-up (Nov 8, 2026 review)

extension ParserTests {
    func testHostNameValidatorAcceptsNamesAndAddresses() {
        for ok in ["example.com", "8.8.8.8", "sub-domain.example.co.uk", "::1", "example.com.", "_dmarc.example.com"] {
            XCTAssertTrue(HostName.isValid(ok), ok)
        }
    }

    func testHostNameValidatorRejectsOptionsAndJunk() {
        for bad in ["-f/etc/passwd", "+trace", "a b", "", "example..com", "-example.com", String(repeating: "a", count: 254)] {
            XCTAssertFalse(HostName.isValid(bad), bad.isEmpty ? "(empty)" : bad)
        }
    }

    func testDigGetsTheNameAfterDashQ() {
        XCTAssertEqual(DNSTool.arguments(name: "example.com", type: "TXT", server: "").suffix(3), ["-q", "example.com", "TXT"])
    }

    func testSPFCounterCountsMechanismsWithPrefixLength() async {
        var seen = Set<String>()
        // a/24 and mx/24 are still a and mx (one lookup each); ip4 and all never count. No include, so nothing is asked.
        let n = await DNSPlus.spfLookups("v=spf1 a/24 mx/24 ip4:192.0.2.0/24 -all", server: "", seen: &seen)
        XCTAssertEqual(n, 2)
    }

    func testUniFiAddressIsHTTPSHostAndPortOnly() {
        XCTAssertEqual(UniFiClient.normalized("http://10.0.0.5/network"), "https://10.0.0.5")
        XCTAssertEqual(UniFiClient.normalized("https://host:8443"), "https://host:8443")
        XCTAssertEqual(UniFiClient.normalized(" 10.0.0.5/ "), "https://10.0.0.5")
        XCTAssertEqual(UniFiClient.normalized("https://10.0.0.5:8443/manage/site/default"), "https://10.0.0.5:8443")
    }

    func testUniFiControllerDecodesWithoutFingerprint() throws {
        // unifi.json written before certificates were remembered has no certFingerprint.
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","address":"https://10.0.0.5","site":"default","siteName":"Default"}]"#
        let list = try JSONDecoder().decode([UniFiController].self, from: Data(json.utf8))
        XCTAssertEqual(list.count, 1)
        XCTAssertNil(list[0].certFingerprint)
    }
}

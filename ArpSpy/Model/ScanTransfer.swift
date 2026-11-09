import Foundation

/// The .arpradar file (File › Export Scans… / Import Scans…), shared with ARPradar for Windows so saved scans can
/// move between a Mac and a PC. The format is described in arpradar-windows/docs/arpradar-file.md; both apps write
/// the same JSON. Dates are ISO 8601 text and IPs are text here (data.json uses Swift's own encoding).
enum ScanTransfer {
    static let format = "arpradar-scans"
    static let version = 1

    struct File: Codable {
        var format = ScanTransfer.format
        var version = ScanTransfer.version
        var exported: String? = nil
        var app: String? = nil
        var scans: [Scan] = []
    }

    struct Scan: Codable {
        var name: String
        var organization: String?
        var range: String
        var nameServer: String? = ""
        var dhcpRange: String? = ""
        var notes: String? = ""
        var devices: [TDevice]? = []
        var lastScan: Record? = nil
    }

    struct Record: Codable {
        var date: String?
        var range: String?
        var devices: [TDevice]?
    }

    /// A device in the file. Only `ip` is required.
    struct TDevice: Codable {
        var ip: String
        var mac: String? = nil
        var name: String? = nil
        var vendor: String? = nil
        var names: [String: String]? = nil
        var openPorts: [Int]? = nil
        var firstSeen: String? = nil
        var lastSeen: String? = nil
        var webTitle: String? = nil
        var upnp: String? = nil
        var snmpName: String? = nil
        var snmpDescr: String? = nil
        var snmpLocation: String? = nil
        var ipv6: [String]? = nil
        var banners: [String: String]? = nil
        var thisComputer: Bool? = nil
    }

    enum Failure: LocalizedError {
        case notScans, newer, empty, broken(String)
        var errorDescription: String? {
            switch self {
            case .notScans: return "That isn’t an ARPradar scans file."
            case .broken(let what): return "That ARPradar scans file is damaged: \(what)."
            case .newer: return "That file comes from a newer ARPradar. Update this one, then try again."
            case .empty: return "That file has no saved scans in it."
            }
        }
    }

    // MARK: Dates

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()

    static func text(_ d: Date) -> String { isoFrac.string(from: d) }
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s)
    }

    // MARK: Device <-> file

    static func toFile(_ d: Device) -> TDevice {
        TDevice(ip: d.ip.description, mac: d.mac, name: d.name, vendor: d.vendor, names: d.names,
                openPorts: d.openPorts.map(Int.init), firstSeen: text(d.firstSeen), lastSeen: text(d.lastSeen),
                webTitle: d.webTitle, upnp: d.upnp, snmpName: d.snmpName, snmpDescr: d.snmpDescr, snmpLocation: d.snmpLocation,
                ipv6: d.ipv6, banners: Dictionary(uniqueKeysWithValues: d.banners.map { (String($0.key), $0.value) }),
                thisComputer: d.isThisMac)
    }

    /// Nil when the IP isn't a valid IPv4 address.
    static func fromFile(_ t: TDevice) -> Device? {
        guard let ip = IPv4(t.ip) else { return nil }
        var d = Device(ip: ip)
        d.mac = (t.mac ?? "").uppercased()
        d.name = t.name ?? ""
        d.vendor = t.vendor ?? ""
        d.names = t.names ?? [:]
        d.openPorts = (t.openPorts ?? []).compactMap { UInt16(exactly: $0) }.filter { $0 > 0 }
        d.lastSeen = date(t.lastSeen) ?? Date()
        d.firstSeen = date(t.firstSeen) ?? d.lastSeen
        d.webTitle = t.webTitle ?? ""
        d.upnp = t.upnp ?? ""
        d.snmpName = t.snmpName ?? ""
        d.snmpDescr = t.snmpDescr ?? ""
        d.snmpLocation = t.snmpLocation ?? ""
        d.ipv6 = t.ipv6 ?? []
        d.banners = Dictionary((t.banners ?? [:]).compactMap { k, v in UInt16(k).map { ($0, v) } }, uniquingKeysWith: { a, _ in a })
        d.isThisMac = t.thisComputer ?? false
        return d
    }

    // MARK: Whole files

    static func export(_ sites: [Site], organization: (UUID?) -> String?, appVersion: String) throws -> Data {
        let scans = sites.map { s in
            Scan(name: s.name, organization: organization(s.orgID), range: s.range, nameServer: s.nameServer,
                 dhcpRange: s.dhcpRange, notes: s.notes,
                 devices: s.known.values.sorted { $0.ip < $1.ip }.map(toFile),
                 lastScan: s.lastScan.map { Record(date: text($0.date), range: $0.range, devices: $0.devices.map(toFile)) })
        }
        let file = File(exported: text(Date()), app: "ARPradar \(appVersion) for Mac", scans: scans)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(file)
    }

    static func read(_ data: Data) throws -> File {
        let file: File
        do { file = try JSONDecoder().decode(File.self, from: data) }
        catch let DecodingError.keyNotFound(key, _) where key.stringValue == "format" { throw Failure.notScans }
        catch let DecodingError.dataCorrupted(ctx) where ctx.codingPath.isEmpty { throw Failure.notScans }   // not JSON at all
        catch let DecodingError.keyNotFound(key, _) { throw Failure.broken("“\(key.stringValue)” is missing") }
        catch let DecodingError.typeMismatch(_, ctx) { throw Failure.broken("“\(ctx.codingPath.map(\.stringValue).joined(separator: "."))” has the wrong kind of value") }
        catch let DecodingError.valueNotFound(_, ctx) { throw Failure.broken("“\(ctx.codingPath.map(\.stringValue).joined(separator: "."))” is empty") }
        catch { throw Failure.broken(error.localizedDescription) }
        guard file.format == format else { throw Failure.notScans }
        guard file.version <= version else { throw Failure.newer }
        var f = file
        f.scans = file.scans.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !f.scans.isEmpty else { throw Failure.empty }
        return f
    }

    /// A saved scan (site) made from one scan in the file. `orgID` is the organization it goes in.
    static func site(from s: Scan, name: String, orgID: UUID?) -> Site {
        var site = Site(name: name, range: s.range.trimmingCharacters(in: .whitespaces),
                        nameServer: (s.nameServer ?? "").trimmingCharacters(in: .whitespaces))
        site.dhcpRange = (s.dhcpRange ?? "").trimmingCharacters(in: .whitespaces)
        site.notes = s.notes ?? ""
        site.orgID = orgID
        for d in (s.devices ?? []).compactMap(fromFile) { site.known[d.commentKey] = d }
        if let r = s.lastScan {
            site.lastScan = ScanRecord(date: date(r.date) ?? Date(), range: r.range ?? site.range,
                                       devices: (r.devices ?? []).compactMap(fromFile), siteName: name)
        }
        return site
    }
}

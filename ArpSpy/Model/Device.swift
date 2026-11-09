import Foundation

/// One device found on the network (one row in the results table).
struct Device: Identifiable, Hashable, Sendable, Codable {
    let ip: IPv4
    var name: String = ""
    var mac: String = ""
    var vendor: String = ""
    var comment: String = ""
    var isThisMac = false
    var isOnline = true
    var openPorts: [UInt16] = []
    var lastSeen = Date()
    var firstSeen = Date()
    /// Ping round-trip time in this scan (nil = didn't answer ping).
    var responseMs: Double? = nil
    /// Every name found, by where it came from ("NetBIOS", "Bonjour", "DNS", "UPnP", "SNMP").
    var names: [String: String] = [:]
    /// The <title> of its web page.
    var webTitle: String = ""
    /// Make and model from UPnP, e.g. "Sample Corp DS-220".
    var upnp: String = ""
    var snmpName: String = ""
    var snmpDescr: String = ""
    var snmpLocation: String = ""
    /// Model and firmware from Ubiquiti discovery, e.g. "UVC G3 Instant", "4.75.62".
    var ubntModel: String = ""
    var ubntFirmware: String = ""
    /// What answers on each open port ("OpenSSH 9.6"). Filled in by Scan Ports or the details panel.
    var banners: [UInt16: String] = [:]
    /// IPv6 addresses (from the Mac's neighbor list), global first.
    var ipv6: [String] = []
    /// First time this site (or ARPradar) has seen it.
    var isNew = false
    /// For the Type column (not saved with the device; the model fills these in):
    /// the type the user picked, the type the UniFi map says, and whether it's the network's DHCP server.
    var typeOverride: DeviceKind? = nil
    var mapKind: DeviceKind? = nil
    var isDHCPServer = false
    /// Where it plugs into the UniFi network (from the map), for the Switch port column and the details panel.
    var switchLink: SwitchLink? = nil
    var switchPortSort: String { switchLink?.sortKey ?? "\u{10FFFF}" }

    init(ip: IPv4) { self.ip = ip }

    var id: UInt32 { ip.value }

    /// One short line saying what the device is: UPnP model, then SNMP description, then web page title.
    var details: String {
        if !upnp.isEmpty { return upnp }
        if !ubntModel.isEmpty { return ubntFirmware.isEmpty ? ubntModel : "\(ubntModel) · \(ubntFirmware)" }
        let descr = snmpDescr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if !descr.isEmpty { return descr.count > 70 ? String(descr.prefix(70)) + "…" : descr }
        return webTitle
    }

    // Sort keys for the table columns.
    var ipSort: UInt32 { ip.value }
    var nameSort: String { name.lowercased() }
    var portsSort: String { openPorts.map(Ports.label).joined(separator: " ") }
    var detailsSort: String { details.lowercased() }
    var responseSort: Double { responseMs ?? .infinity }

    /// Devices are remembered (comments, favorites, history) by MAC address when we
    /// have one, otherwise by IP.
    var commentKey: String { mac.isEmpty ? ip.description : mac }

    /// Records the name from one source; the first name found becomes the device's name.
    mutating func addName(_ n: String, from source: String) {
        let n = n.cleanedNetworkText(max: 64)
        guard !n.isEmpty else { return }
        names[source] = n
        if name.isEmpty { name = n }
    }
}

extension String {
    /// Text that came off the network (a NetBIOS name, Bonjour label, web page title, UPnP model, SNMP string),
    /// made safe to show, copy and export: control characters, line breaks, tabs and the invisible
    /// direction-changing characters are dropped, the ends are trimmed, and it's cut to `max` characters.
    func cleanedNetworkText(max: Int = 120) -> String {
        var out = ""
        for u in unicodeScalars {
            switch u.value {
            case 0x00...0x1F, 0x7F...0x9F: continue                          // control characters (incl. tab, newline)
            case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: continue   // zero-width and bidi marks
            default: out.unicodeScalars.append(u)
            }
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.count > max ? String(trimmed.prefix(max)) + "…" : trimmed
    }
}

extension Device {
    enum CodingKeys: String, CodingKey {
        case ip, name, mac, vendor, comment, isThisMac, isOnline, openPorts, lastSeen, firstSeen, responseMs
        case names, webTitle, upnp, snmpName, snmpDescr, snmpLocation, banners, isNew, ipv6, ubntModel, ubntFirmware
    }

    /// Reads field by field, so data saved by older versions still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(ip: try c.decode(IPv4.self, forKey: .ip))
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        mac = try c.decodeIfPresent(String.self, forKey: .mac) ?? ""
        vendor = try c.decodeIfPresent(String.self, forKey: .vendor) ?? ""
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        isThisMac = try c.decodeIfPresent(Bool.self, forKey: .isThisMac) ?? false
        isOnline = try c.decodeIfPresent(Bool.self, forKey: .isOnline) ?? true
        openPorts = try c.decodeIfPresent([UInt16].self, forKey: .openPorts) ?? []
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? Date()
        firstSeen = try c.decodeIfPresent(Date.self, forKey: .firstSeen) ?? lastSeen
        responseMs = try c.decodeIfPresent(Double.self, forKey: .responseMs)
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        webTitle = try c.decodeIfPresent(String.self, forKey: .webTitle) ?? ""
        upnp = try c.decodeIfPresent(String.self, forKey: .upnp) ?? ""
        snmpName = try c.decodeIfPresent(String.self, forKey: .snmpName) ?? ""
        snmpDescr = try c.decodeIfPresent(String.self, forKey: .snmpDescr) ?? ""
        snmpLocation = try c.decodeIfPresent(String.self, forKey: .snmpLocation) ?? ""
        banners = try c.decodeIfPresent([UInt16: String].self, forKey: .banners) ?? [:]
        isNew = try c.decodeIfPresent(Bool.self, forKey: .isNew) ?? false
        ipv6 = try c.decodeIfPresent([String].self, forKey: .ipv6) ?? []
        ubntModel = try c.decodeIfPresent(String.self, forKey: .ubntModel) ?? ""
        ubntFirmware = try c.decodeIfPresent(String.self, forKey: .ubntFirmware) ?? ""
    }
}

/// What SNMP told us about a device.
struct SNMPInfo: Sendable, Hashable {
    var name = "", descr = "", location = ""
}

/// What UPnP told us about a device.
struct UPnPInfo: Sendable, Hashable {
    var friendlyName = "", model = ""
}

/// Messages the scanner sends back to the window while it works.
enum ScanEvent: Sendable {
    case found([Device])
    case macs([UInt32: String])
    case names(source: String, [UInt32: String])
    case ports([UInt32: [UInt16]])
    case ipv6([UInt32: [String]])
    case response([UInt32: Double])
    case webTitles([UInt32: String])
    case upnp([UInt32: UPnPInfo])
    case snmp([UInt32: SNMPInfo])
    case ubiquiti([UInt32: UbiquitiInfo])
    case progress(Double, String)
    case finished(cancelled: Bool)
}

/// A thread-safe "stop" switch shared between the window and the scanner.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

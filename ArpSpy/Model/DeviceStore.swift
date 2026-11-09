import Foundation

/// One finished scan, kept for the History tab.
struct ScanRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var range: String
    var devices: [Device]
    /// The site it was scanned as, if any (by name for old records, and by id so Open Recent finds the right one
    /// when two saved scans share a name).
    var siteName: String? = nil
    var siteID: UUID? = nil
    /// The network's DHCP server and name servers found by that scan (see `NetServers`).
    var dhcpServer: String? = nil
    var nameServers: [String]? = nil
    /// The network map read after this scan (UniFi controller, or the scan alone).
    var netMap: NetMap? = nil

    var servers: NetServers {
        NetServers(dhcp: dhcpServer.flatMap(IPv4.init), dns: (nameServers ?? []).compactMap(IPv4.init))
    }
}

/// A network's DHCP server and name servers, as found by a scan.
struct NetServers: Equatable {
    var dhcp: IPv4? = nil
    var dns: [IPv4] = []
    var isEmpty: Bool { dhcp == nil && dns.isEmpty }

    /// The DHCP server and DNS servers from this Mac's lease count only when they're in the scanned range:
    /// those are the name servers the network hands out. When the lease has none there (scanning over a VPN),
    /// devices with the DNS port (53) open count instead, except Apple devices: Apple TVs and HomePods answer
    /// DNS for Thread smart-home gear but aren't the network's name servers.
    static func find(devices: [Device], targets: Set<UInt32>, leaseDHCP: String, leaseDNS: [String]) -> NetServers {
        var s = NetServers()
        if let d = IPv4(leaseDHCP), targets.contains(d.value) { s.dhcp = d }
        var seen = Set<UInt32>()
        for t in leaseDNS { if let ip = IPv4(t), targets.contains(ip.value), seen.insert(ip.value).inserted { s.dns.append(ip) } }
        if s.dns.isEmpty {
            s.dns = devices.filter { $0.isOnline && $0.openPorts.contains(53) && !$0.vendor.localizedCaseInsensitiveContains("apple") }
                .map(\.ip).sorted { $0.value < $1.value }
        }
        return s
    }

    /// "DHCP server", "Name server", "DHCP · DNS server", or nil.
    func role(of ip: IPv4) -> String? {
        let dhcp = self.dhcp == ip, dns = self.dns.contains(ip)
        switch (dhcp, dns) {
        case (true, true): return "DHCP · DNS server"
        case (true, false): return "DHCP server"
        case (false, true): return "Name server"
        default: return nil
        }
    }

    /// "DHCP 10.0.0.1 · DNS 10.0.0.5, 10.0.0.6"
    var summary: String {
        var parts: [String] = []
        if let dhcp { parts.append("DHCP \(dhcp)") }
        if !dns.isEmpty { parts.append("DNS " + dns.map(\.description).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// A named network: "Home", "Client A – Main office". Two sites can share a subnet;
/// each keeps its own devices, so their offline rows never mix.
/// A saved scan in an organization uses the organization's name server and DHCP range
/// (its own only if the organization has none). A standalone one uses its own.
@MainActor
extension Site {
    var organization: Organization? { OrgStore.shared.org(orgID) }
    var effectiveNameServer: String {
        Self.pick(organization?.nameServer, nameServer)
    }
    var effectiveDHCPRange: String {
        Self.pick(organization?.dhcpRange, dhcpRange)
    }
    /// The SNMP community this scan sends: the organization's, else its own, else "public".
    var effectiveSNMPCommunity: String {
        let c = Self.pick(organization?.snmpCommunity, snmpCommunity)
        return c.isEmpty ? "public" : c
    }
    nonisolated static func pick(_ fromOrg: String?, _ own: String) -> String {
        let o = (fromOrg ?? "").trimmingCharacters(in: .whitespaces)
        return o.isEmpty ? own.trimmingCharacters(in: .whitespaces) : o
    }
}

struct Site: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var range: String
    /// Optional DNS server to ask for names (e.g. a client's domain controller). Blank = this Mac's DNS.
    var nameServer = ""
    /// The DHCP pool, e.g. "10.0.0.100-10.0.0.199" (several allowed, comma-separated). Blank = not known.
    var dhcpRange = ""
    /// Standalone scans: the read-only SNMP community to send (blank = "public"). Scans in an organization use its.
    var snmpCommunity = ""
    /// Anything worth remembering: VPN name, contact…
    var notes = ""
    /// The organization it belongs to (nil = none).
    var orgID: UUID? = nil
    /// Every device seen at this site, keyed like `StoredData.known`.
    var known: [String: Device] = [:]
    var lastScan: ScanRecord? = nil

    init(name: String, range: String, nameServer: String = "") {
        self.name = name; self.range = range; self.nameServer = nameServer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Site"
        range = try c.decodeIfPresent(String.self, forKey: .range) ?? ""
        nameServer = try c.decodeIfPresent(String.self, forKey: .nameServer) ?? ""
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        dhcpRange = try c.decodeIfPresent(String.self, forKey: .dhcpRange) ?? ""
        snmpCommunity = try c.decodeIfPresent(String.self, forKey: .snmpCommunity) ?? ""
        orgID = try c.decodeIfPresent(UUID.self, forKey: .orgID)
        known = try c.decodeIfPresent([String: Device].self, forKey: .known) ?? [:]
        lastScan = try c.decodeIfPresent(ScanRecord.self, forKey: .lastScan)
    }
}

/// What ArpSpy remembers between launches. Saved as one JSON file in
/// ~/Library/Application Support/ArpSpy/data.json. It stays on this Mac.
struct StoredData: Codable {
    /// Every device ever seen, keyed by MAC (or IP when there's no MAC). Used to show
    /// "offline" rows and to fill in the Favorites tab.
    var known: [String: Device] = [:]
    var favorites: Set<String> = []
    var history: [ScanRecord] = []
    var sites: [Site] = []

    init() {}

    /// Reads field by field, so files from older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        known = try c.decodeIfPresent([String: Device].self, forKey: .known) ?? [:]
        favorites = try c.decodeIfPresent(Set<String>.self, forKey: .favorites) ?? []
        history = try c.decodeIfPresent([ScanRecord].self, forKey: .history) ?? []
        sites = try c.decodeIfPresent([Site].self, forKey: .sites) ?? []
    }
}

enum DeviceStore {
    static let maxHistory = 50

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ArpSpy", isDirectory: true).appendingPathComponent("data.json")
    }

    /// Set when data.json is there but couldn't be read or decoded at launch. Saving is then refused, so the
    /// real file (and the .unreadable.json copy) stay put instead of being replaced by an empty store.
    nonisolated(unsafe) private(set) static var loadProblem: String? = nil
    static var isReadOnly: Bool { loadProblem != nil }

    /// Writes happen one after another on this queue, off the main thread (the file is a few MB).
    private static let queue = DispatchQueue(label: "arpradar.store", qos: .utility)

    static func load() -> StoredData {
        loadProblem = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return StoredData() }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch {
            loadProblem = "ARPradar couldn’t read its saved data (\(fileURL.lastPathComponent)): \(error.localizedDescription). Nothing will be saved until it opens again, so nothing is lost."
            NSLog("ARPradar: couldn’t read saved data: \(error)")
            return StoredData()
        }
        do { return try JSONDecoder().decode(StoredData.self, from: data) }
        catch {
            // Keep the unreadable file instead of overwriting it on the next save.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            loadProblem = "ARPradar couldn’t make sense of its saved data; a copy was kept at \(backup.path). Nothing will be saved until the app is reopened."
            NSLog("ARPradar: couldn’t read saved data (\(error)); kept a copy at \(backup.path)")
            return StoredData()
        }
    }

    /// Encodes and writes in the background. Returns at once.
    static func save(_ stored: StoredData) {
        guard !isReadOnly else { return }
        queue.async { write(stored) }
    }

    /// Waits for pending writes (at quit).
    static func flush() { queue.sync {} }

    private static func write(_ stored: StoredData) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(stored)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("ARPradar: couldn’t save data: \(error)")
        }
    }
}

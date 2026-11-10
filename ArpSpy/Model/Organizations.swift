import Foundation

/// A client, branch, company, school…: its sites (linked by `Site.orgID`) and everything saved for it.
struct Organization: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Domain names, e.g. ["example-a.com", "example-a.org"]. Used by the site survey's DNS lookups.
    var domains: [String] = []
    /// The DNS server its scans ask for names (e.g. its domain controller). Blank = this Mac's DNS.
    var nameServer = ""
    /// Its DHCP pool, e.g. "10.0.0.100-10.0.0.199". Its scans use it to tint addresses outside the pool.
    var dhcpRange = ""
    /// The read-only SNMP community its scans send (blank = "public"). Kept per organization so one
    /// client's community is never sent to devices on another network.
    var snmpCommunity = ""
    /// Its scans start as quiet scans (fewer probes, slower; see `ScanPlan`), and its surveys skip the speed test.
    var quietScan = false
    var notes = ""
    var created = Date()
    /// What its most recent scan found on the network (shown in Settings).
    var seenDHCPServer = ""
    var seenNameServers: [String] = []
    var seenScan = ""
    var seenDate: Date? = nil

    init(name: String, domains: [String] = [], notes: String = "") {
        self.name = name; self.domains = domains; self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Organization"
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        nameServer = try c.decodeIfPresent(String.self, forKey: .nameServer) ?? ""
        dhcpRange = try c.decodeIfPresent(String.self, forKey: .dhcpRange) ?? ""
        snmpCommunity = try c.decodeIfPresent(String.self, forKey: .snmpCommunity) ?? ""
        quietScan = try c.decodeIfPresent(Bool.self, forKey: .quietScan) ?? false
        seenDHCPServer = try c.decodeIfPresent(String.self, forKey: .seenDHCPServer) ?? ""
        seenNameServers = try c.decodeIfPresent([String].self, forKey: .seenNameServers) ?? []
        seenScan = try c.decodeIfPresent(String.self, forKey: .seenScan) ?? ""
        seenDate = try c.decodeIfPresent(Date.self, forKey: .seenDate)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }

    /// "example-a.com, example-a.org" → ["example-a.com", "example-a.org"]
    static func parseDomains(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" || $0.isNewline })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            .filter { !$0.isEmpty }
    }
}

/// A table of results, kept as text so any saved item can be shown, opened and exported the same way.
struct SavedTable: Codable, Hashable {
    var header: [String]
    var rows: [[String]]
    var widths: [Int] = []
    var numberColumns: Set<Int> = []

    /// DNS lookups: rows for where a CNAME leads start with "↳" (indented by depth).
    static func isChainRow(_ row: [String]) -> Bool {
        let first = row.first ?? ""
        return first.hasPrefix("↳") || (first.hasPrefix(" ") && first.contains("↳"))
    }
    var hasCNAMEChain: Bool { rows.contains(where: Self.isChainRow) }
    func withoutCNAMEChain() -> SavedTable {
        var t = self; t.rows = rows.filter { !Self.isChainRow($0) }; return t
    }
}

/// One thing saved for an organization: a scan, a DNS lookup, a speed test…
struct SavedItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case survey, networkScan, dns, portScan, traceroute, ping, speedTest, wifi, wifiSignal, connection, heatmap

        var title: String {
            switch self {
            case .survey: return "Site survey"
            case .networkScan: return "Network scan"
            case .dns: return "DNS lookup"
            case .portScan: return "Scan Ports"
            case .traceroute: return "Traceroute"
            case .ping: return "Ping"
            case .speedTest: return "Speed test"
            case .wifi: return "Wi-Fi survey"
            case .wifiSignal: return "Wi-Fi signal"
            case .connection: return "Connection info"
            case .heatmap: return "Wi-Fi heatmap"
            }
        }

        var symbol: String {
            switch self {
            case .survey: return "checklist"
            case .networkScan: return "network"
            case .dns: return "globe"
            case .portScan: return "door.left.hand.open"
            case .traceroute: return "point.topleft.down.to.point.bottomright.curvepath"
            case .ping: return "waveform.path.ecg"
            case .speedTest: return "speedometer"
            case .wifi, .wifiSignal: return "wifi"
            case .connection: return "cable.connector"
            case .heatmap: return "map"
            }
        }

        /// The filter tab it's under in the Organizations window.
        var group: Filter {
            switch self {
            case .survey, .networkScan: return .scans
            case .dns: return .dns
            case .portScan: return .ports
            default: return .other
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case everything = "Everything", scans = "Scans", dns = "DNS", ports = "Ports", other = "Other"
        var id: String { rawValue }
    }

    var id = UUID()
    var orgID: UUID
    var kind: Kind
    var date = Date()
    /// "DNS lookup · example-a.com (All)"
    var title: String
    /// "61 records"
    var summary: String
    var note = ""
    var siteName = ""
    /// Items made by the same site survey share this.
    var surveyID: UUID? = nil
    var table: SavedTable

    init(orgID: UUID, kind: Kind, title: String, summary: String, table: SavedTable, siteName: String = "",
         note: String = "", surveyID: UUID? = nil) {
        self.orgID = orgID; self.kind = kind; self.title = title; self.summary = summary
        self.table = table; self.siteName = siteName; self.note = note; self.surveyID = surveyID
    }
}

/// What a tool hands over to be saved (the organization and note are chosen when saving).
struct SavedDraft {
    var kind: SavedItem.Kind
    var title: String
    var summary: String
    var table: SavedTable
}

struct OrgData: Codable {
    var orgs: [Organization] = []
    var items: [SavedItem] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orgs = try c.decodeIfPresent([Organization].self, forKey: .orgs) ?? []
        items = try c.decodeIfPresent([SavedItem].self, forKey: .items) ?? []
    }
}

/// The organizations and their saved items. Saved to ~/Library/Application Support/ArpSpy/organizations.json.
@MainActor
final class OrgStore: ObservableObject {
    static let shared = OrgStore()

    @Published private(set) var orgs: [Organization] = []
    @Published private(set) var items: [SavedItem] = []
    /// Set to show this organization in the Organizations window.
    @Published var focus: UUID? = nil
    /// A tool window opened from an organization's page picks this up (`OrgAutoSaveScope`)
    /// and files its finished results there.
    private var launchOrgID: UUID? = nil
    private var launchAt = Date.distantPast

    func launch(from org: UUID) { launchOrgID = org; launchAt = Date() }

    /// The organization a window was just opened from (within a few seconds), once.
    func takeLaunch() -> UUID? {
        defer { launchOrgID = nil }
        return Date().timeIntervalSince(launchAt) < 5 ? launchOrgID : nil
    }
    private var saveTask: Task<Void, Never>?

    static var fileURL: URL {
        DeviceStore.fileURL.deletingLastPathComponent().appendingPathComponent("organizations.json")
    }

    /// Set when organizations.json is there but couldn't be read; saving is then refused so the file stays as it is.
    private(set) var loadProblem: String? = nil

    init() {
        guard FileManager.default.fileExists(atPath: Self.fileURL.path) else { return }
        let data: Data
        do { data = try Data(contentsOf: Self.fileURL) }
        catch {
            loadProblem = "ARPradar couldn’t read its organizations file: \(error.localizedDescription). Nothing will be saved there until the app is reopened."
            NSLog("ARPradar: couldn’t read organizations: \(error)")
            return
        }
        do {
            let d = try JSONDecoder().decode(OrgData.self, from: data)
            orgs = d.orgs; items = d.items
        } catch {
            let backup = Self.fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: Self.fileURL, to: backup)
            loadProblem = "ARPradar couldn’t make sense of its organizations file; a copy was kept at \(backup.path). Nothing will be saved there until the app is reopened."
            NSLog("ARPradar: couldn’t read organizations (\(error)); kept a copy at \(backup.path)")
        }
    }

    var sortedOrgs: [Organization] { orgs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    func org(_ id: UUID?) -> Organization? { orgs.first { $0.id == id } }
    func items(for org: UUID) -> [SavedItem] { items.filter { $0.orgID == org }.sorted { $0.date > $1.date } }

    /// For the list: newest first, with each survey's results right under the survey (oldest first), indented.
    nonisolated static func timeline(_ list: [SavedItem]) -> [(item: SavedItem, indented: Bool)] {
        let surveys = Set(list.filter { $0.kind == .survey }.compactMap(\.surveyID))
        var out: [(SavedItem, Bool)] = []
        for i in list.sorted(by: { $0.date > $1.date }) {
            if let s = i.surveyID, surveys.contains(s), i.kind != .survey { continue }   // shown under its survey
            out.append((i, false))
            if i.kind == .survey, let s = i.surveyID {
                for c in list.filter({ $0.surveyID == s && $0.kind != .survey }).sorted(by: { $0.date < $1.date }) { out.append((c, true)) }
            }
        }
        return out
    }
    func item(_ id: UUID?) -> SavedItem? { items.first { $0.id == id } }

    func uniqueName(_ base: String) -> String {
        let taken = Set(orgs.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    @discardableResult
    func add(_ org: Organization) -> UUID {
        orgs.append(org); save(); return org.id
    }

    /// The organization with this name (any case), made if there isn't one.
    func ensure(named name: String) -> UUID {
        if let o = orgs.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return o.id }
        return add(Organization(name: name))
    }

    func update(_ id: UUID, _ change: (inout Organization) -> Void) {
        guard let i = orgs.firstIndex(where: { $0.id == id }) else { return }
        change(&orgs[i]); saveSoon()
    }

    /// Removes the organization and everything saved for it.
    func delete(_ id: UUID) {
        orgs.removeAll { $0.id == id }
        items.removeAll { $0.orgID == id }
        save()
    }

    @discardableResult
    func add(_ item: SavedItem) -> UUID {
        items.append(item); save(); return item.id
    }

    func save(_ draft: SavedDraft, to org: UUID, note: String = "", siteName: String = "", surveyID: UUID? = nil) {
        add(SavedItem(orgID: org, kind: draft.kind, title: draft.title, summary: draft.summary, table: draft.table,
                      siteName: siteName, note: note, surveyID: surveyID))
    }

    func updateItem(_ id: UUID, _ change: (inout SavedItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i]); saveSoon()
    }

    func deleteItems(_ ids: Set<UUID>) {
        items.removeAll { ids.contains($0.id) }
        save()
    }

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        guard loadProblem == nil else { return }
        var d = OrgData(); d.orgs = orgs; d.items = items
        do {
            try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(d).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("ARPradar: couldn’t save organizations: \(error)")
        }
    }

    // MARK: Excel export

    /// One workbook: an Overview sheet (the organization, its sites and a list of saved items), then a sheet per item.
    func workbook(for orgID: UUID, sites: [Site]) -> Data {
        guard let org = org(orgID) else { return Exporter.workbook([]) }
        return Self.workbook(org: org, items: items(for: orgID), sites: sites,
                             followCNAMEs: UserDefaults.standard.bool(forKey: "dnsFollowCNAMEs"))
    }

    nonisolated static func workbook(org: Organization, items list: [SavedItem], sites: [Site], followCNAMEs: Bool = false) -> Data {
        var overview: [[String]] = [
            ["Organization", org.name], ["Domains", org.domains.joined(separator: ", ")],
            ["Name server", org.nameServer], ["DHCP range", org.dhcpRange], ["Notes", org.notes],
            ["Exported", Date().formatted(date: .abbreviated, time: .shortened)], ["", ""],
        ]
        for s in sites { overview.append(["Site: \(s.name)", [s.range, s.nameServer.isEmpty ? "" : "name server \(s.nameServer)"].filter { !$0.isEmpty }.joined(separator: " · ")]) }
        overview.append(["", ""])
        overview.append(["Saved", "\(list.count) items (one sheet each, newest first)"])
        for i in list {
            overview.append([i.date.formatted(date: .abbreviated, time: .shortened),
                             [i.title, i.summary, i.note].filter { !$0.isEmpty }.joined(separator: " · ")])
        }
        var sheets = [Exporter.Sheet(name: "Overview", header: ["ARPradar", "Organization export"], rows: overview, widths: [24, 100])]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d HH.mm"                      // Excel sheet names can't contain ":"
        for i in list {
            let stamp = f.string(from: i.date)
            let t = i.kind == .dns && !followCNAMEs ? i.table.withoutCNAMEChain() : i.table
            sheets.append(Exporter.Sheet(name: "\(i.kind.title) \(stamp)", header: t.header, rows: t.rows,
                                         widths: t.widths, numberColumns: t.numberColumns))
        }
        return Exporter.workbook(sheets)
    }
}

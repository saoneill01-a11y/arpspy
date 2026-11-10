import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UserNotifications

/// Everything the window shows, and the Scan / Stop logic.
@MainActor
final class ScanModel: ObservableObject {
    /// The one main window's model (the File and View menus use it too).
    static let shared = ScanModel()

    enum Tab: String, CaseIterable, Identifiable {
        case results = "Results", favorites = "Favorites", history = "History", map = "Map"
        var id: String { rawValue }
    }

    /// Which site sheet is open.
    enum SiteSheet: Identifiable {
        case new, edit(UUID)
        var id: String { if case .edit(let u) = self { return u.uuidString }; return "new" }
    }

    enum ExportKind { case csv, excel }

    @Published var rangeText = ""
    /// Normal / Quiet switch in the scan bar. Opening a saved scan sets it from its organization's Scan style.
    @Published var quietScan = false
    @Published var interfaces: [NetInterface] = []
    @Published var selectedInterface = "" { didSet { if selectedInterface != oldValue { applySelectedInterface() } } }
    @Published private(set) var devices: [Device] = [] { didSet { visibleCache = nil } }
    @Published var searchText = "" { didSet { visibleCache = nil } }
    @Published var sortOrder = [KeyPathComparator(\Device.ipSort)] { didSet { visibleCache = nil } }
    @Published var selection = Set<Device.ID>()
    @Published var tab: Tab = .results {
        didSet {
            selection = []; visibleCache = nil
            // A scan picked in History stays in Results when you go back there.
            if oldValue == .history, tab == .results || tab == .map, let id = selectedRecord, id != currentRecordID,
               let record = stored.history.first(where: { $0.id == id }) {
                openHistoryRecord(record)
            }
        }
    }
    @Published var selectedRecord: ScanRecord.ID? = nil { didSet { selection = []; visibleCache = nil } }
    @Published private(set) var isScanning = false
    @Published private(set) var progress = 0.0
    @Published private(set) var statusText = "Ready"
    @Published private(set) var scannedCount = 0
    @Published private(set) var showPermissionHint = false
    @Published private(set) var stored: StoredData { didSet { visibleCache = nil } }
    @Published private(set) var comments: [String: String] { didSet { visibleCache = nil } }
    /// Types set by hand (right-click › Type), by MAC (or IP), as DeviceKind raw values.
    @Published private(set) var deviceTypes: [String: String] { didSet { visibleCache = nil } }
    @Published var errorMessage: String? = nil
    /// The "Show offline" switch. Remembered between launches.
    @Published var showOffline: Bool {
        didSet { UserDefaults.standard.set(showOffline, forKey: Self.showOfflineKey); visibleCache = nil }
    }
    /// "Mark outside DHCP": tint addresses outside the current site's DHCP range. Remembered between launches.
    @Published var markOutsideDHCP: Bool {
        didSet { UserDefaults.standard.set(markOutsideDHCP, forKey: Self.markDHCPKey) }
    }
    /// The details panel on the right (⌘I).
    @Published var showDetails: Bool {
        didSet { UserDefaults.standard.set(showDetails, forKey: Self.showDetailsKey) }
    }
    /// The site being worked on (nil = no site).
    @Published private(set) var siteID: UUID?
    @Published var siteSheet: SiteSheet? = nil
    /// After a scan that isn't saved yet: show the "Save this scan?" bar.
    @Published var offerSave = false
    /// Which choice the Save Scan sheet starts on (set by the save bar's buttons).
    @Published var saveStandalone = false
    /// Bumped by View › Find Device (⌘F); the scan bar moves the cursor to Search.
    @Published var searchFocusToken = 0
    /// The organization a new scan or DNS lookup was started from; saving offers it first.
    @Published var preferredOrgID: UUID? = nil
    /// A new scan started from an organization's page: each finished run is filed there automatically.
    @Published private(set) var autoFileOrgID: UUID? = nil
    @Published var siteToDelete: Site? = nil
    /// The DHCP server and name servers of the scan in Results.
    @Published private(set) var servers = NetServers() { didSet { visibleCache = nil } }
    /// After a scan in an organization: a name server it could use (the "Use … for …" bar).
    @Published var serverOffer: IPv4? = nil
    /// File › Open Recent › Clear Menu hides scans up to this date (History keeps them).
    @Published private(set) var recentClearedAt: Date? = UserDefaults.standard.object(forKey: "recentClearedAt") as? Date
    /// The device the Scan Ports window is open for.
    @Published var portScanTarget: Device? = nil
    /// Shared folders per device, read when the details panel opens (not saved).
    @Published private(set) var shares: [UInt32: ShareInfo] = [:]
    @Published private(set) var sharesLoading = Set<UInt32>()
    /// The Map tab: the network map for the scan in Results.
    @Published private(set) var netMap: NetMap? = nil {
        didSet { mapKinds = Self.mapKinds(of: netMap); switchLinks = netMap?.switchLinks() ?? [:]; visibleCache = nil }
    }
    @Published private(set) var mapLoading = false
    @Published var mapError: String? = nil
    /// What the last map load asked the controller (no key, no values), for "Connection details".
    @Published private(set) var mapLog = ""

    static let showOfflineKey = "showOffline"
    static let showDetailsKey = "showDetails"
    static let markDHCPKey = "markOutsideDHCP"
    /// The old app-wide SNMP community (moved into each organization / standalone scan once, see `moveCommunity`).
    static let communityKey = "snmpCommunity"
    static let notifyKey = "notifyNewDevices"

    private var flag = CancelFlag()
    private var indexByID: [UInt32: Int] = [:]
    private var startedAt = Date()
    private var currentTargets = Set<UInt32>()
    private var currentRange = ""
    private var scanSiteID: UUID?
    /// The History record of the scan in Results (its map is saved there).
    private var currentRecordID: UUID?
    private var bannerJobs = Set<UInt32>()
    private var webTitleJobs = Set<UInt32>()
    private let commentsKey = "comments"
    private let typesKey = "deviceTypes"

    init() {
        comments = UserDefaults.standard.dictionary(forKey: commentsKey) as? [String: String] ?? [:]
        deviceTypes = UserDefaults.standard.dictionary(forKey: typesKey) as? [String: String] ?? [:]
        stored = DeviceStore.load()
        showOffline = UserDefaults.standard.object(forKey: Self.showOfflineKey) as? Bool ?? true
        showDetails = UserDefaults.standard.bool(forKey: Self.showDetailsKey)
        markOutsideDHCP = UserDefaults.standard.object(forKey: Self.markDHCPKey) as? Bool ?? true
        // Always open as a new scan on this Mac's network; a saved scan is only used when picked.
        siteID = nil
        migrateSitesToOrganizations()
        Self.copySettingsToOrganizations(sites: stored.sites)
        moveCommunityToScans()
        refreshInterfaces()
        statusText = "New scan · press Scan"
        if let problem = DeviceStore.loadProblem ?? OrgStore.shared.loadProblem { errorMessage = problem }
        LocalNetworkPermission.trigger(for: interfaces)
        Task.detached(priority: .utility) { OUIDatabase.shared.loadIfNeeded() }
        // Quitting right after an edit must not lose it: finish the half-second save delay and any pending write.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.saveTask != nil { self.saveTask?.cancel(); self.saveTask = nil; DeviceStore.save(self.stored) }
                DeviceStore.flush()
            }
        }
    }

    /// Once: the SNMP community used to be one setting sent to every network scanned. It now lives with each
    /// organization and standalone saved scan, so a client's community never goes out on someone else's LAN.
    /// The old value is copied to what existed at the time; new scans send "public" unless told otherwise.
    private func moveCommunityToScans() {
        let d = UserDefaults.standard
        guard let old = d.string(forKey: Self.communityKey) else { return }
        let c = old.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty && c != "public" {
            for o in OrgStore.shared.orgs where o.snmpCommunity.isEmpty { OrgStore.shared.update(o.id) { $0.snmpCommunity = c } }
            for i in stored.sites.indices where stored.sites[i].orgID == nil && stored.sites[i].snmpCommunity.isEmpty {
                stored.sites[i].snmpCommunity = c
            }
            DeviceStore.save(stored)
        }
        d.removeObject(forKey: Self.communityKey)
    }

    // MARK: Organizations

    /// Once: every existing site gets an organization with the same name.
    private func migrateSitesToOrganizations() {
        let key = "sitesMovedToOrganizations"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        for i in stored.sites.indices where stored.sites[i].orgID == nil {
            stored.sites[i].orgID = OrgStore.shared.ensure(named: stored.sites[i].name)
        }
        DeviceStore.save(stored)
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Once: an organization with no name server or DHCP range takes them from its first saved scan that has one.
    static func copySettingsToOrganizations(sites: [Site], store: OrgStore = .shared, defaults: UserDefaults = .standard) {
        let key = "orgSettingsFromScans"
        guard !defaults.bool(forKey: key) else { return }
        for org in store.orgs {
            let filled = filledFromScans(org, sites: sites)
            if filled != org { store.update(org.id) { $0 = filled } }
        }
        defaults.set(true, forKey: key)
    }

    /// The organization with a blank name server / DHCP range filled from its first saved scan (by name) that has one.
    nonisolated static func filledFromScans(_ org: Organization, sites: [Site]) -> Organization {
        func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
        let mine = sites.filter { $0.orgID == org.id }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var o = org
        if t(o.nameServer).isEmpty { o.nameServer = mine.map { t($0.nameServer) }.first { !$0.isEmpty } ?? "" }
        if t(o.dhcpRange).isEmpty { o.dhcpRange = mine.map { t($0.dhcpRange) }.first { !$0.isEmpty } ?? "" }
        return o
    }

    /// The organization of the site being worked on.
    var currentOrgID: UUID? { currentSite?.orgID }

    func sites(in org: UUID?) -> [Site] {
        stored.sites.filter { $0.orgID == org }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A new, empty site (no devices yet), selected.
    @discardableResult
    func createSite(name: String, range: String, nameServer: String, orgID: UUID?, dhcpRange: String = "", snmpCommunity: String = "") -> UUID {
        var site = Site(name: name, range: range, nameServer: nameServer)
        site.orgID = orgID
        site.dhcpRange = dhcpRange
        site.snmpCommunity = snmpCommunity
        stored.sites.append(site)
        stored.sites.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        DeviceStore.save(stored)
        selectSite(site.id)
        return site.id
    }

    func setOrg(_ org: UUID?, forSite id: UUID) {
        guard let i = siteIndex(id) else { return }
        stored.sites[i].orgID = org
        DeviceStore.save(stored)
    }

    /// Unlinks sites from an organization that's being deleted (the sites stay).
    func detachSites(from org: UUID) {
        for i in stored.sites.indices where stored.sites[i].orgID == org { stored.sites[i].orgID = nil }
        DeviceStore.save(stored)
    }

    /// Set by the site survey so the scan it runs is filed with the survey's other results.
    var surveyIDForNextScan: UUID? = nil
    private var scanWaiters: [CheckedContinuation<Bool, Never>] = []

    /// Scans a range and waits for it to finish. True if it finished (not stopped or invalid).
    func runScan(range: String) async -> Bool {
        guard !isScanning else { return false }
        rangeText = range
        startScan()
        guard isScanning else { return false }
        return await withCheckedContinuation { scanWaiters.append($0) }
    }

    /// The device table as saved for an organization.
    static func scanTable(_ list: [Device]) -> SavedTable {
        SavedTable(header: Exporter.columns, rows: list.map(Exporter.row), widths: Exporter.widths, numberColumns: [Exporter.responseColumn])
    }

    // MARK: Sites

    var currentSite: Site? { stored.sites.first { $0.id == siteID } }

    /// The current site's DHCP pool, if one is set.
    var dhcpRange: DHCPRange? { currentSite.flatMap { DHCPRange($0.effectiveDHCPRange) } }

    nonisolated static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    /// The Scan button says Rescan when the list shows a scan of the range that's typed in.
    var canRescan: Bool {
        !isScanning && !devices.isEmpty
            && rangeText.trimmingCharacters(in: .whitespaces) == currentRange.trimmingCharacters(in: .whitespaces)
    }

    /// True when the switch is on, the site has a DHCP range, and this address is outside it.
    func isOutsideDHCP(_ d: Device) -> Bool {
        guard markOutsideDHCP, let r = dhcpRange else { return false }
        return !r.contains(d.ip)
    }

    /// Shown devices outside the DHCP range (nil when the site has none).
    var outsideDHCPCount: Int? {
        guard let r = dhcpRange else { return nil }
        return visibleDevices.filter { !r.contains($0.ip) }.count
    }
    private func siteIndex(_ id: UUID?) -> Int? { stored.sites.firstIndex { $0.id == id } }

    /// Picks a site (or none) and shows its last scan.
    func selectSite(_ id: UUID?) {
        guard !isScanning else { return }
        flag = CancelFlag()          // names still arriving for the previous scan are ignored from here on
        siteID = id
        offerSave = false
        serverOffer = nil
        autoFileOrgID = nil
        servers = NetServers()
        searchText = ""
        if let site = currentSite {
            rangeText = site.range
            if let org = site.organization { quietScan = org.quietScan }
            if site.lastScan != nil { showLastScan() } else {
                devices = []; indexByID = [:]; selection = []; scannedCount = 0; progress = 0
                statusText = "\(site.name) · not scanned yet"
            }
            tab = .results
        }
    }

    /// New Scan (next to Scan, ⌘N): an empty list on this Mac's network (or whatever is typed in IP range), not saved.
    func newScan(for org: UUID? = nil) {
        guard !isScanning else { return }
        selectSite(nil)
        preferredOrgID = org
        autoFileOrgID = org
        if let o = OrgStore.shared.org(org) { quietScan = o.quietScan }
        devices = []; indexByID = [:]; selection = []; scannedCount = 0; progress = 0
        currentRange = ""
        servers = NetServers(); serverOffer = nil
        netMap = nil; mapError = nil; currentRecordID = nil
        applySelectedInterface()
        statusText = OrgStore.shared.org(org).map { "New scan for \($0.name) · press Scan" } ?? "New scan · press Scan"
        tab = .results
        showPermissionHint = false
    }

    /// Saves what's in Results now as a new site, and switches to it.
    func saveSite(name: String, range: String, nameServer: String, orgID: UUID? = nil, dhcpRange: String = "", snmpCommunity: String = "") {
        var site = Site(name: name, range: range, nameServer: nameServer)
        site.orgID = orgID
        site.dhcpRange = dhcpRange
        site.snmpCommunity = snmpCommunity
        let online = devices.filter(\.isOnline)
        for d in online { site.known[d.commentKey] = clean(d) }
        if !online.isEmpty {
            site.lastScan = ScanRecord(date: online.map(\.lastSeen).max() ?? Date(), range: currentRange.isEmpty ? range : currentRange,
                                       devices: online.map(clean), siteName: name, siteID: site.id,
                                       dhcpServer: servers.dhcp?.description, nameServers: servers.dns.map(\.description),
                                       netMap: netMap)
            currentRecordID = site.lastScan?.id
            // The History copy of this scan now belongs to the saved scan too.
            if let r = currentRecordID, let i = stored.history.firstIndex(where: { $0.date == site.lastScan?.date && $0.range == site.lastScan?.range && $0.siteName == nil }) {
                stored.history[i].siteName = name; stored.history[i].siteID = site.id; _ = r
            }
        }
        stored.sites.append(site)
        stored.sites.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        DeviceStore.save(stored)
        siteID = site.id
        offerSave = false
        rangeText = range
        let found = servers
        if !online.isEmpty { showLastScan() }
        servers = found
        noteServersForOrganization()
    }

    func updateSite(_ id: UUID, name: String, range: String, nameServer: String, orgID: UUID?? = nil, dhcpRange: String? = nil,
                    snmpCommunity: String? = nil) {
        guard let i = siteIndex(id) else { return }
        if let orgID { stored.sites[i].orgID = orgID }
        if let dhcpRange { stored.sites[i].dhcpRange = dhcpRange }
        if let snmpCommunity { stored.sites[i].snmpCommunity = snmpCommunity }
        stored.sites[i].name = name
        stored.sites[i].range = range
        stored.sites[i].nameServer = nameServer
        stored.sites.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        DeviceStore.save(stored)
        if id == siteID { rangeText = range; refreshStatusForSite() }
    }

    func deleteSite(_ id: UUID) {
        stored.sites.removeAll { $0.id == id }
        DeviceStore.save(stored)
        if siteID == id { siteID = nil }
    }

    // MARK: Export / Import Scans (.arpradar files, shared with ARPradar for Windows)

    enum TransferSheet: Identifiable {
        case export
        case importing(ScanTransfer.File, String)
        var id: String {
            switch self {
            case .export: return "export"
            case .importing(_, let name): return "import-" + name
            }
        }
    }
    @Published var transferSheet: TransferSheet? = nil

    enum ImportAction: Hashable { case new, replace, keepBoth }

    /// The saved scan with this name (any case), for Import Scans' "Here already?".
    func existingSite(named name: String) -> Int? {
        stored.sites.firstIndex { $0.name.caseInsensitiveCompare(name.trimmingCharacters(in: .whitespaces)) == .orderedSame }
    }

    /// File › Import Scans…: picks a file, reads it, and shows the Import Scans sheet.
    func beginImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "arpradar") ?? .json, .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try ScanTransfer.read(try Data(contentsOf: url))
            transferSheet = .importing(file, url.lastPathComponent)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn’t read \(url.lastPathComponent)."
        }
    }

    /// Adds (or replaces, matched by name) saved scans from an .arpradar file. Organizations are matched by name and
    /// created when missing. Returns how many were added and replaced.
    @discardableResult
    func importScans(_ choices: [(scan: ScanTransfer.Scan, action: ImportAction)]) -> (added: Int, replaced: Int) {
        var added = 0, replaced = 0, current = false
        for (s, action) in choices {
            let name = s.name.trimmingCharacters(in: .whitespaces)
            let orgName = (s.organization ?? "").trimmingCharacters(in: .whitespaces)
            let orgID = orgName.isEmpty ? nil : OrgStore.shared.ensure(named: orgName)
            if action == .replace, let i = existingSite(named: name) {
                var site = ScanTransfer.site(from: s, name: stored.sites[i].name, orgID: orgID)
                site.id = stored.sites[i].id
                stored.sites[i] = site
                replaced += 1
                if site.id == siteID { current = true }
            } else {
                stored.sites.append(ScanTransfer.site(from: s, name: uniqueSiteName(name), orgID: orgID))
                added += 1
            }
            // Favorites need a remembered copy of each device too.
            for d in (s.devices ?? []).compactMap(ScanTransfer.fromFile) where stored.known[d.commentKey] == nil {
                stored.known[d.commentKey] = clean(d)
            }
        }
        stored.sites.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        DeviceStore.save(stored)
        if current { showLastScan() }
        let n = added + replaced
        statusText = "Imported \(n) saved scan\(n == 1 ? "" : "s")" + (replaced > 0 ? " (\(replaced) replaced)" : "")
        return (added, replaced)
    }

    /// A name not used by another saved scan: "New Scan", "New Scan 2"…
    func uniqueSiteName(_ base: String, ignoring id: UUID? = nil) -> String {
        let taken = Set(stored.sites.filter { $0.id != id }.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    @discardableResult
    func newSite() -> UUID {
        let site = Site(name: uniqueSiteName("New Scan"), range: rangeText)
        stored.sites.append(site)
        DeviceStore.save(stored)
        return site.id
    }

    /// Copies a site's range, name server and notes (not its devices).
    @discardableResult
    func duplicateSite(_ id: UUID) -> UUID? {
        guard let s = stored.sites.first(where: { $0.id == id }) else { return nil }
        var copy = Site(name: uniqueSiteName(s.name + " copy"), range: s.range, nameServer: s.nameServer)
        copy.notes = s.notes
        stored.sites.append(copy)
        DeviceStore.save(stored)
        return copy.id
    }

    func deleteSites(_ ids: Set<UUID>) {
        stored.sites.removeAll { ids.contains($0.id) }
        DeviceStore.save(stored)
        if let id = siteID, ids.contains(id) { siteID = nil }
    }

    /// Forgets the saved devices and last scan of these sites; the sites stay.
    func clearSiteDevices(_ ids: Set<UUID>) {
        for i in stored.sites.indices where ids.contains(stored.sites[i].id) {
            stored.sites[i].known = [:]
            stored.sites[i].lastScan = nil
        }
        DeviceStore.save(stored)
        if let id = siteID, ids.contains(id), !isScanning {
            devices.removeAll { !$0.isOnline }
            indexByID = Dictionary(devices.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// Live edits from the Site List window. Saved half a second after the last change.
    func editSite(_ id: UUID, _ change: (inout Site) -> Void) {
        guard let i = siteIndex(id) else { return }
        change(&stored.sites[i])
        if id == siteID { refreshStatusForSite() }
        saveSoon()
    }
    private var saveTask: Task<Void, Never>?

    /// Called when the Scan List editor leaves a name: a name another saved scan already has gets a number.
    func fixDuplicateName(_ id: UUID) {
        guard let i = siteIndex(id) else { return }
        let name = Self.trim(stored.sites[i].name)
        let clash = stored.sites.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        guard clash || name.isEmpty else { return }
        stored.sites[i].name = uniqueSiteName(name.isEmpty ? "New Scan" : name, ignoring: id)
        DeviceStore.save(stored)
    }

    private func refreshStatusForSite() {
        guard !isScanning, let site = currentSite, let last = site.lastScan else { return }
        statusText = "\(site.name) · last scan \(last.date.formatted(date: .abbreviated, time: .shortened))"
    }

    /// The devices offline rows are compared against: the site's, or everything ArpSpy has seen.
    /// What a saved scan remembers. An unsaved (new) scan remembers nothing: no red offline rows, no NEW badges.
    /// To compare with an earlier scan of the same network, load the saved scan and scan it again.
    private func knownDevices(for site: UUID?) -> [String: Device] {
        siteIndex(site).map { stored.sites[$0].known } ?? [:]
    }

    // MARK: What the table shows

    /// Rows for the current tab, before search and sort.
    private var tabRows: [Device] {
        switch tab {
        case .results, .map:
            return devices
        case .favorites:
            // Two favorites can have been last seen at the same IP (DHCP moved them); the table needs one row
            // per IP, so the one that's online now, else the most recently seen, is shown.
            let rows: [Device] = stored.favorites.compactMap { key in
                if let live = devices.first(where: { $0.commentKey == key && $0.isOnline }) { return live }
                guard var d = stored.known[key] else { return nil }
                d.isOnline = false   // not seen in the current scan (or no scan yet)
                d.isNew = false
                return d
            }
            var seen = Set<UInt32>()
            return rows.sorted { ($0.isOnline ? 1 : 0, $0.lastSeen) > ($1.isOnline ? 1 : 0, $1.lastSeen) }
                .filter { seen.insert($0.id).inserted }
        case .history:
            return stored.history.first(where: { $0.id == selectedRecord })?.devices ?? []
        }
    }

    /// The rows the table shows. Worked out once and kept until something it depends on changes (the two
    /// tables, the details panel and the status bar all ask for it on every redraw).
    var visibleDevices: [Device] {
        if let visibleCache { return visibleCache.rows }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = (showOffline || tab == .history ? tabRows : tabRows.filter(\.isOnline)).map(withTypeInfo)
        let filtered = q.isEmpty ? rows : rows.filter {
            $0.name.lowercased().contains(q) || $0.ip.description.contains(q)
                || ($0.kind?.label.lowercased().contains(q) ?? false)
                || $0.mac.lowercased().contains(q) || $0.vendor.lowercased().contains(q)
                || (comments[$0.commentKey] ?? "").lowercased().contains(q)
                || $0.portsSort.lowercased().contains(q) || $0.details.lowercased().contains(q)
        }
        let sorted = filtered.sorted(using: sortOrder)
        visibleCache = (sorted, rows.count - sorted.count)
        return sorted
    }
    private var visibleCache: (rows: [Device], hiddenBySearch: Int)? = nil

    /// Rows the Search box is hiding right now.
    var hiddenBySearch: Int { _ = visibleDevices; return visibleCache?.hiddenBySearch ?? 0 }

    var onlineCount: Int { devices.filter(\.isOnline).count }
    var offlineCount: Int { devices.count - onlineCount }
    var newCount: Int { devices.filter { $0.isOnline && $0.isNew }.count }

    func rows(with ids: Set<Device.ID>) -> [Device] {
        visibleDevices.filter { ids.contains($0.id) }
    }

    /// The one selected row, for the details panel.
    var selectedDevice: Device? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return visibleDevices.first { $0.id == id }
    }

    // MARK: Network picker

    /// Reads the adapter list again. The IP range only changes when the adapter does (or the box is empty),
    /// so a range typed by hand survives a refresh.
    func refreshInterfaces() {
        interfaces = Interfaces.current()
        if !interfaces.contains(where: { $0.id == selectedInterface }) {
            selectedInterface = interfaces.first?.id ?? ""
            if interfaces.isEmpty { rangeText = rangeText }   // nothing to suggest
        } else if rangeText.trimmingCharacters(in: .whitespaces).isEmpty {
            applySelectedInterface()
        }
    }

    private func applySelectedInterface() {
        if let i = interfaces.first(where: { $0.id == selectedInterface }) { rangeText = i.suggestedRange }
    }

    // MARK: Last scan

    /// Fills Results with the site's last scan (or, with no site, the most recent scan), plus grey rows
    /// for devices seen in that range before but not found in it.
    private func showLastScan(_ chosen: ScanRecord? = nil) {
        let site = currentSite
        flag = CancelFlag()
        offerSave = false
        guard let record = chosen ?? (site != nil ? site?.lastScan : stored.history.first) else { return }
        servers = record.servers
        let targets = Set(((try? IPRangeParser.parse(record.range)) ?? record.devices.map(\.ip)).map(\.value))
        var seen = Set<UInt32>()
        let found = record.devices.filter { seen.insert($0.id).inserted }.map { d -> Device in
            var d = d; d.isOnline = true; d.comment = comments[d.commentKey] ?? ""; return d
        }
        let missing = Self.offlineRows(known: knownDevices(for: siteID), found: found, targets: targets).map { d -> Device in
            var d = d; d.comment = comments[d.commentKey] ?? ""; return d
        }
        devices = found + missing
        indexByID = Dictionary(devices.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        selection = []
        rangeText = record.range
        currentRange = record.range
        currentTargets = targets
        currentRecordID = record.id
        netMap = record.netMap
        mapError = nil
        scannedCount = targets.count
        progress = 1
        let when = record.date.formatted(date: .abbreviated, time: .shortened)
        if let site, site.lastScan?.id != record.id {
            statusText = "\(site.name) · scan from \(when) (an earlier scan)"
        } else {
            statusText = site.map { "\($0.name) · last scan \(when)" } ?? "Scan from \(when) · not saved"
        }
    }

    // MARK: File › Open Recent

    /// The last 5 scans, newest first (saved or not), after any Clear Menu.
    var recentScans: [ScanRecord] {
        Array(stored.history.filter { recentClearedAt == nil || $0.date > recentClearedAt! }.prefix(5))
    }

    /// A saved scan opens as that saved scan; an unsaved one comes back as a new scan that can still be saved.
    func openRecent(_ record: ScanRecord) {
        guard !isScanning else { return }
        if let site = stored.sites.first(where: { $0.id == record.siteID })
            ?? record.siteName.flatMap({ name in stored.sites.first { $0.name == name } }) {
            selectSite(site.id)
            return
        }
        selectSite(nil)
        preferredOrgID = nil
        showLastScan(record)
        tab = .results
        offerSave = devices.contains { $0.isOnline && !$0.isThisMac }
    }

    /// Loads a scan from History into Results (History › Open in Results, or going back to Results with one picked).
    /// A scan of a saved scan opens as that saved scan, so Rescan scans it again; an unsaved one can still be saved.
    func openHistoryRecord(_ record: ScanRecord) {
        guard !isScanning else { return }
        let site = stored.sites.first { $0.id == record.siteID }
            ?? record.siteName.flatMap { name in stored.sites.first { $0.name == name } }
        siteID = site?.id
        preferredOrgID = nil
        autoFileOrgID = nil
        serverOffer = nil
        searchText = ""
        showLastScan(record)
        offerSave = site == nil && devices.contains { $0.isOnline && !$0.isThisMac }
    }

    func clearRecentScans() {
        recentClearedAt = Date()
        UserDefaults.standard.set(recentClearedAt, forKey: "recentClearedAt")
    }

    /// "Main office – 10.20.30.0/24 · Today 9:41"
    static func recentTitle(_ r: ScanRecord) -> String {
        let when = Calendar.current.isDateInToday(r.date) ? "Today " + r.date.formatted(date: .omitted, time: .shortened)
            : r.date.formatted(date: .abbreviated, time: .shortened)
        return "\(r.siteName ?? "New scan (not saved)") – \(r.range) · \(when)"
    }

    // MARK: Network map

    /// The UniFi controller for the scan in Results: its organization's, or one inside the scanned range.
    var mapController: UniFiController? {
        UniFiStore.shared.controller(org: currentSite?.orgID ?? autoFileOrgID, targets: mapTargets)
    }

    /// The organization a controller set up from the Map tab belongs to.
    var mapOrgID: UUID? { currentSite?.orgID ?? autoFileOrgID }

    private var mapTargets: Set<UInt32> {
        if !currentTargets.isEmpty { return currentTargets }
        return Set(((try? IPRangeParser.parse(rangeText)) ?? []).map(\.value))
    }

    /// A Ubiquiti console the scan found ("UniFi OS" web page), to offer as the controller's address.
    var detectedController: Device? {
        devices.first { $0.isOnline && $0.webTitle.localizedCaseInsensitiveContains("UniFi OS") }
            ?? devices.first { $0.isOnline && $0.webTitle.localizedCaseInsensitiveContains("UniFi Network") }
    }

    /// Builds the map: from the UniFi controller when there is one, otherwise from the scan alone.
    /// Saved with the scan in History (and its saved scan).
    func loadMap() async {
        guard !mapLoading, !devices.isEmpty else { return }
        mapLoading = true
        mapError = nil
        defer { mapLoading = false }
        let bsd = interfaces.first { $0.id == selectedInterface }?.bsdName ?? ""
        let targets = mapTargets
        let scan = devices.filter(\.isOnline)
        let router = await Task.detached(priority: .utility) { bsd.isEmpty ? "" : ConnectionInfo.router(bsd) }.value
        var gateway = IPv4(router).flatMap { targets.contains($0.value) ? $0 : nil }
        if gateway == nil {
            // Scanning another network (over a VPN): its .1 or .254, if something answered there.
            gateway = scan.map(\.ip).first { [1, 254].contains($0.value & 0xFF) }
        }
        let recordID = currentRecordID
        let gatewayMAC = scan.first { $0.ip == gateway }?.mac
        // Managed switches that answered SNMP during the scan: read their MAC tables and LLDP neighbours, alongside
        // the UniFi controller (if any). Only this scan's own SNMP community is used.
        let community = currentSite?.effectiveSNMPCommunity ?? "public"
        let snmpLog = SNMPLog()
        // The gateway is read too: on many networks it's a layer-3 core switch, and then it tops the map with its ports.
        let candidates = scan.filter { !$0.isThisMac && !($0.snmpName.isEmpty && $0.snmpDescr.isEmpty) }
        async let snmpRead: [SNMPSwitchData] = DNSPlus.inParallel(candidates, limit: 6) { d in
            await offMain {
                SNMPSwitchReader.read(ip: d.ip, mac: d.mac, name: d.snmpName.isEmpty ? d.name : d.snmpName, descr: d.snmpDescr,
                                      community: community, log: { snmpLog.add($0) })
            }
        }.compactMap { $0 }
        var map: NetMap
        var unifi: (devices: [RawUniFiDevice], clients: [RawUniFiClient], source: String, controller: String)? = nil
        var log = ""
        if let c = mapController {
            guard let key = UniFiStore.shared.key(c) else {
                mapError = "The API key for \(c.address) isn't in the Keychain. Open UniFi Controller… and enter it again."
                _ = await snmpRead
                return
            }
            let client = UniFiClient(address: c.address, key: key)
            do {
                let r = try await client.fetch(siteRef: c.site)
                unifi = (r.devices, r.clients,
                         "UniFi controller (\(r.api))" + (r.siteName.isEmpty || r.siteName == "Default" ? "" : " · \(r.siteName)"),
                         UniFiClient.normalized(c.address))
            } catch {
                mapError = error.localizedDescription
            }
            log = client.log.text
        }
        let switches = await snmpRead
        if !snmpLog.text.isEmpty { log += (log.isEmpty ? "" : "\n") + snmpLog.text }
        mapLog = log
        if unifi != nil || !switches.isEmpty {
            let infra = Set((unifi?.devices ?? []).map { NetMapBuilder.mac($0.mac) })
            let snmp = SNMPMapBuilder.layout(switches, gatewayMAC: gatewayMAC, infrastructure: infra)
            let merged = SNMPMapBuilder.merge(unifiDevices: unifi?.devices ?? [], unifiClients: unifi?.clients ?? [], snmp: snmp, scan: scan)
            map = NetMapBuilder.build(devices: merged.devices, clients: merged.clients, scan: scan, gatewayIP: gateway,
                                      controller: unifi?.controller ?? "")
            let snmpPart = switches.isEmpty ? "" : "SNMP (\(switches.count) switch\(switches.count == 1 ? "" : "es"))"
            map.source = [unifi?.source ?? "", snmpPart].filter { !$0.isEmpty }.joined(separator: " + ")
        } else {
            map = NetMapBuilder.withoutController(scan: scan, gatewayIP: gateway)
        }
        guard recordID == currentRecordID else { return }   // a newer scan came in meanwhile
        netMap = map
        if let id = recordID {
            if let i = stored.history.firstIndex(where: { $0.id == id }) { stored.history[i].netMap = map }
            for s in stored.sites.indices where stored.sites[s].lastScan?.id == id { stored.sites[s].lastScan?.netMap = map }
            DeviceStore.save(stored)
        }
    }

    /// Lines for the map's "Connection details", written from several threads.
    final class SNMPLog: @unchecked Sendable {
        private let lock = NSLock(); private var lines: [String] = []
        func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return lines.sorted().joined(separator: "\n") }
    }

    // MARK: DHCP server and name servers

    /// After a scan: reads this Mac's lease, finds the servers, saves them with the scan,
    /// and for a scan in an organization records them there and may offer a name server.
    private func findServers(recordID: UUID, siteID scanSite: UUID?) {
        let bsd = interfaces.first { $0.id == selectedInterface }?.bsdName ?? ""
        let found = devices, targets = currentTargets
        Task {
            let lease: (dhcp: String, dns: [String]) = await Task.detached(priority: .utility) {
                bsd.isEmpty ? (dhcp: "", dns: []) : ConnectionInfo.lease(bsd)
            }.value
            let s = NetServers.find(devices: found, targets: targets, leaseDHCP: lease.dhcp, leaseDNS: lease.dns)
            let dhcp = s.dhcp?.description, dns = s.dns.map(\.description)
            if let i = stored.history.firstIndex(where: { $0.id == recordID }) {
                stored.history[i].dhcpServer = dhcp; stored.history[i].nameServers = dns
            }
            if let i = siteIndex(scanSite), stored.sites[i].lastScan?.id == recordID {
                stored.sites[i].lastScan?.dhcpServer = dhcp; stored.sites[i].lastScan?.nameServers = dns
            }
            DeviceStore.save(stored)
            guard !isScanning, siteID == scanSite else { return }
            servers = s
            noteServersForOrganization()
        }
    }

    /// For a saved scan in an organization: shows what was found in its Settings, and offers a name server
    /// when the organization's is blank or isn't one of those found.
    private func noteServersForOrganization() {
        guard let site = currentSite, let org = site.organization, !servers.isEmpty else { return }
        let s = servers
        OrgStore.shared.update(org.id) {
            $0.seenDHCPServer = s.dhcp?.description ?? ""; $0.seenNameServers = s.dns.map(\.description)
            $0.seenScan = site.name; $0.seenDate = Date()
        }
        serverOffer = Self.nameServerToOffer(current: org.nameServer, found: s)
    }

    nonisolated static func nameServerToOffer(current: String, found: NetServers) -> IPv4? {
        let c = current.trimmingCharacters(in: .whitespaces)
        guard let first = found.dns.first, !found.dns.contains(where: { $0.description == c }) else { return nil }
        return first
    }

    /// The bar's "Use … for …" button.
    func useOfferedNameServer() {
        guard let ip = serverOffer, let org = currentSite?.organization else { serverOffer = nil; return }
        OrgStore.shared.update(org.id) { $0.nameServer = ip.description }
        serverOffer = nil
    }

    /// Remembered devices in `targets` that aren't in `found`, marked offline.
    /// When two remembered devices share an IP (DHCP moved them), the most recently seen one wins.
    nonisolated static func offlineRows(known: [String: Device], found: [Device], targets: Set<UInt32>) -> [Device] {
        let foundKeys = Set(found.map(\.commentKey))
        var usedIPs = Set(found.map(\.id))
        var out: [Device] = []
        for (key, d) in known.sorted(by: { $0.value.lastSeen > $1.value.lastSeen })
        where !foundKeys.contains(key) && targets.contains(d.ip.value) && !usedIPs.contains(d.id) {
            var gone = d
            gone.isOnline = false
            gone.isNew = false
            gone.responseMs = nil
            usedIPs.insert(gone.id)
            out.append(gone)
        }
        return out
    }

    /// Fills in names a scan didn't get from the previous copy of the same device.
    nonisolated static func keepingOldNames(_ d: Device, old: Device) -> Device {
        var d = d
        for (source, n) in old.names where d.names[source] == nil { d.names[source] = n }
        if d.name.isEmpty && !old.name.isEmpty && !old.isThisMac { d.name = old.name }
        return d
    }

    /// Devices in `found` that aren't in `known`. Nothing counts as new the first time a site is scanned.
    nonisolated static func newKeys(found: [Device], known: [String: Device]) -> Set<String> {
        guard !known.isEmpty else { return [] }
        return Set(found.map(\.commentKey).filter { known[$0] == nil })
    }

    // MARK: Scan / Stop

    /// Shows a short note in the bottom bar ("Copied 3 rows") and puts the old text back after a moment.
    func flashStatus(_ text: String) {
        let previous = flashRestore ?? statusText
        flashRestore = previous
        statusText = text
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.statusText == text { self.statusText = previous }
            self.flashRestore = nil
        }
    }
    private var flashRestore: String? = nil
    private var flashTask: Task<Void, Never>?

    func toggleScan() {
        if isScanning {
            flag.cancel()
            statusText = "Stopping…"
        } else {
            startScan()
        }
    }

    private func startScan() {
        let targets: [IPv4]
        do { targets = try IPRangeParser.parse(rangeText) }
        catch { errorMessage = error.localizedDescription; return }

        var options = ScanOptions()
        if let server = currentSite?.effectiveNameServer, !server.isEmpty {
            guard let ip = IPv4(server) else {
                errorMessage = currentSite?.organization != nil
                    ? "The name server “\(server)” isn’t a valid IP address. Fix it in the organization’s settings (Saved Scans › Organizations…)."
                    : "The name server “\(server)” isn’t a valid IP address. Fix it in Saved Scans › Edit This Scan…"
                return
            }
            options.nameServer = ip
        }
        // Only this scan's own community goes out (an organization's, or a standalone scan's); a new scan sends "public".
        options.snmpCommunity = currentSite?.effectiveSNMPCommunity ?? "public"
        options.quiet = quietScan
        // A quiet scan asks SNMP only when this organization (or saved scan) has its own community set.
        options.snmpInQuiet = currentSite.map { !Site.pick($0.organization?.snmpCommunity, $0.snmpCommunity).isEmpty } ?? false

        // Typing a different range while a saved scan is open scans as a new, unsaved scan (offered for saving
        // afterwards) instead of quietly rewriting the saved scan's range and results.
        if let site = currentSite, Self.trim(rangeText) != Self.trim(site.range) {
            let org = site.orgID
            let typed = rangeText
            selectSite(nil)
            rangeText = typed
            preferredOrgID = org
            options.snmpCommunity = "public"
            options.snmpInQuiet = false
        }

        tab = .results
        devices = []; indexByID = [:]; selection = []
        servers = NetServers(); serverOffer = nil
        isScanning = true; progress = 0; scannedCount = targets.count
        showPermissionHint = false
        startedAt = Date()
        currentTargets = Set(targets.map(\.value))
        currentRange = rangeText
        scanSiteID = siteID
        let flag = CancelFlag(); self.flag = flag
        let ifaces = interfaces
        let report: @Sendable (ScanEvent) async -> Void = { [weak self] event in
            await self?.handle(event, flag: flag)
        }

        Task.detached(priority: .userInitiated) {
            await ScanEngine.run(targets: targets, interfaces: ifaces, options: options, flag: flag, report: report)
        }
    }

    /// Results from the ARPradar Sensor (Bluetooth): shown as a new, unsaved scan, through the same steps as a scan
    /// from this Mac (vendors, types, NEW badges, History, the offer to save), so they behave the same way.
    func showSensorScan(rows: [SensorRow], range: String, seconds: Double, label: String, cancelled: Bool) {
        guard !isScanning else { return }
        newScan()
        rangeText = range
        let targets = (try? IPRangeParser.parse(range)) ?? rows.map(\.ip)
        tab = .results
        isScanning = true; progress = 0; scannedCount = targets.count
        startedAt = Date().addingTimeInterval(-seconds)
        currentTargets = Set(targets.map(\.value)).union(rows.map(\.ip.value))
        currentRange = range
        scanSiteID = nil
        let flag = CancelFlag(); self.flag = flag
        handle(.found(rows.map { Device(ip: $0.ip) }), flag: flag)
        handle(.macs(Dictionary(rows.filter { !$0.mac.isEmpty }.map { ($0.ip.value, $0.mac) }, uniquingKeysWith: { a, _ in a })), flag: flag)
        handle(.ports(Dictionary(rows.map { ($0.ip.value, $0.ports) }, uniquingKeysWith: { a, _ in a })), flag: flag)
        handle(.response(Dictionary(rows.compactMap { r in r.ms.map { (r.ip.value, $0) } }, uniquingKeysWith: { a, _ in a })), flag: flag)
        handle(.webTitles(Dictionary(rows.filter { !$0.web.isEmpty }.map { ($0.ip.value, $0.web) }, uniquingKeysWith: { a, _ in a })), flag: flag)
        for r in rows {
            guard let i = indexByID[r.ip.value] else { continue }
            if !r.upnp.isEmpty { devices[i].upnp = r.upnp.cleanedNetworkText() }
            if !r.snmp.isEmpty { devices[i].snmpDescr = r.snmp.cleanedNetworkText() }
            if !r.snmpName.isEmpty { devices[i].snmpName = r.snmpName.cleanedNetworkText() }
            if !r.ubnt.isEmpty { devices[i].ubntModel = r.ubnt.cleanedNetworkText() }
        }
        handle(.names(source: "Sensor", Dictionary(rows.filter { !$0.name.isEmpty }.map { ($0.ip.value, $0.name) }, uniquingKeysWith: { a, _ in a })), flag: flag)
        handle(.finished(cancelled: cancelled), flag: flag)
        statusText = "\(label) · \(rows.count) devices in \(String(format: "%.1f", seconds)) s"
        showPermissionHint = false
    }

    private func handle(_ event: ScanEvent, flag: CancelFlag) {
        guard flag === self.flag else { return }   // ignore leftovers from an older scan
        switch event {
        case .found(let list):
            for var d in list where indexByID[d.id] == nil {
                d.comment = comments[d.commentKey] ?? ""
                indexByID[d.id] = devices.count
                devices.append(d)
            }
        case .macs(let macs):
            for (id, mac) in macs {
                guard let i = indexByID[id] else { continue }
                devices[i].mac = mac
                devices[i].vendor = OUIDatabase.shared.vendor(for: mac)
                devices[i].comment = comments[mac] ?? devices[i].comment
            }
        case .ports(let ports):
            for (id, list) in ports {
                if let i = indexByID[id] { devices[i].openPorts = list }
            }
        case .ipv6(let list):
            for (id, addrs) in list { if let i = indexByID[id] { devices[i].ipv6 = addrs } }
        case .response(let times):
            for (id, ms) in times { if let i = indexByID[id] { devices[i].responseMs = ms } }
        case .webTitles(let titles):
            for (id, t) in titles { if let i = indexByID[id] { devices[i].webTitle = t.cleanedNetworkText() } }
        case .upnp(let info):
            for (id, u) in info { if let i = indexByID[id] { devices[i].upnp = u.model.cleanedNetworkText() } }
        case .snmp(let info):
            for (id, s) in info {
                guard let i = indexByID[id] else { continue }
                devices[i].snmpName = s.name.cleanedNetworkText(max: 64)
                devices[i].snmpDescr = s.descr.cleanedNetworkText(max: 255)
                devices[i].snmpLocation = s.location.cleanedNetworkText()
            }
        case .ubiquiti(let info):
            for (id, u) in info {
                guard let i = indexByID[id] else { continue }
                devices[i].ubntModel = u.model.cleanedNetworkText(max: 64); devices[i].ubntFirmware = u.firmware.cleanedNetworkText(max: 32)
            }
        case .names(let source, let names):
            var changed = false
            for (id, name) in names {
                guard let i = indexByID[id], devices[i].isOnline else { continue }
                devices[i].addName(name, from: source)
                // DNS names can trickle in after the scan is saved; keep the saved copies current.
                if !isScanning { changed = updateSaved(devices[i]) || changed }
            }
            if changed { saveSoon() }   // one write for the whole trickle, not one per name
        case .progress(let value, let text):
            progress = value
            statusText = text
        case .finished(let cancelled):
            isScanning = false
            progress = 1
            let seconds = String(format: "%.1f", Date().timeIntervalSince(startedAt))
            let filedIn = !cancelled && scanSiteID == nil ? OrgStore.shared.org(autoFileOrgID)?.name : nil
            statusText = cancelled ? "Stopped" : "Scan complete in \(seconds) s" + (filedIn.map { " · saved in \($0)" } ?? "")
            if !cancelled { recordScan() }
            if cancelled { surveyIDForNextScan = nil }
            offerSave = !cancelled && scanSiteID == nil && devices.contains { $0.isOnline && !$0.isThisMac }
            let waiters = scanWaiters; scanWaiters = []
            for w in waiters { w.resume(returning: !cancelled) }
            showPermissionHint = !cancelled && devices.filter(\.isOnline).allSatisfy(\.isThisMac)
        }
    }

    /// Copies a device's newer details into the saved lists. Returns true if anything changed.
    private func updateSaved(_ d: Device) -> Bool {
        var changed = false
        // Match on IP too: two devices can share a MAC (a Docker container on a NAS, a router's
        // second address), and only the one with this IP should change.
        let key = d.commentKey
        let copy = clean(d)
        if let old = stored.known[key], old.ip == d.ip, old != copy { stored.known[key] = copy; changed = true }
        if let s = siteIndex(scanSiteID) {
            if let old = stored.sites[s].known[key], old.ip == d.ip, old != copy { stored.sites[s].known[key] = copy; changed = true }
            if let r = stored.sites[s].lastScan?.devices.firstIndex(where: { $0.commentKey == key && $0.ip == d.ip }),
               stored.sites[s].lastScan?.devices[r] != copy {
                stored.sites[s].lastScan?.devices[r] = copy
                changed = true
            }
        }
        return changed
    }

    /// Saves half a second after the last call (the trickle of late DNS names, comment typing).
    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            DeviceStore.save(self.stored)
        }
    }

    /// The copy that gets saved: no comment (those live in UserDefaults) and no NEW flag.
    private func clean(_ d: Device) -> Device {
        var d = d; d.comment = ""; d.isNew = false; return d
    }

    /// After a full scan: remember every device, mark the new ones, add "offline" rows for devices
    /// seen in this range before but missing now, and save the scan to History (and the site).
    private func recordScan() {
        let now = Date()
        let site = siteIndex(scanSiteID)
        let before = knownDevices(for: scanSiteID)
        let fresh = Self.newKeys(found: devices.filter(\.isOnline), known: before)
        for i in devices.indices where devices[i].isOnline {
            let key = devices[i].commentKey
            devices[i].lastSeen = now
            let remembered = before[key] ?? (site != nil ? stored.known[key] : nil)
            devices[i].firstSeen = remembered?.firstSeen ?? now
            // Name lookups are UDP and sometimes go unanswered; keep the last known name for the same device.
            if let old = remembered, old.ip == devices[i].ip {
                devices[i] = Self.keepingOldNames(devices[i], old: old)
            }
            devices[i].isNew = fresh.contains(key)
            stored.known[key] = clean(devices[i])
            if let site { stored.sites[site].known[key] = clean(devices[i]) }
        }
        let online = devices.filter(\.isOnline)
        for var gone in Self.offlineRows(known: knownDevices(for: scanSiteID), found: devices, targets: currentTargets) {
            gone.comment = comments[gone.commentKey] ?? ""
            indexByID[gone.id] = devices.count
            devices.append(gone)
        }
        let record = ScanRecord(date: now, range: currentRange, devices: online.map(clean),
                                siteName: site.map { stored.sites[$0].name }, siteID: site.map { stored.sites[$0].id })
        stored.history.insert(record, at: 0)
        if stored.history.count > DeviceStore.maxHistory {
            stored.history.removeLast(stored.history.count - DeviceStore.maxHistory)
        }
        if let site {
            stored.sites[site].lastScan = record
            stored.sites[site].range = currentRange
        }
        DeviceStore.save(stored)
        currentRecordID = record.id
        netMap = nil
        findServers(recordID: record.id, siteID: scanSiteID)
        // The map (UniFi controller and/or SNMP switches) also fills the Switch port column, so build it when that's on.
        if mapController != nil || tab == .map || UserDefaults.standard.bool(forKey: "showSwitchPortColumn") { Task { await loadMap() } }
        notifyNew(online.filter { fresh.contains($0.commentKey) }, site: site.map { stored.sites[$0].name })
        // Scans of an organization's site are filed under it automatically.
        if let site, let org = stored.sites[site].orgID {
            let s = stored.sites[site]
            let offline = devices.count - online.count
            var summary = "\(online.count) online"
            if offline > 0 { summary += ", \(offline) offline" }
            if !fresh.isEmpty { summary += ", \(fresh.count) new" }
            OrgStore.shared.add(SavedItem(orgID: org, kind: .networkScan, title: "Network scan · \(s.name)",
                                          summary: summary + " · \(currentRange)", table: Self.scanTable(withComments(devices)),
                                          siteName: s.name, surveyID: surveyIDForNextScan))
        } else if site == nil, let org = autoFileOrgID, OrgStore.shared.org(org) != nil {
            // A new scan started from an organization's page is filed there (delete it there if not wanted).
            let offline = devices.count - online.count
            OrgStore.shared.add(SavedItem(orgID: org, kind: .networkScan, title: "Network scan · \(currentRange)",
                                          summary: "\(online.count) online" + (offline > 0 ? ", \(offline) offline" : ""),
                                          table: Self.scanTable(withComments(devices))))
        }
        surveyIDForNextScan = nil
    }

    private func notifyNew(_ list: [Device], site: String?) {
        guard !list.isEmpty, UserDefaults.standard.bool(forKey: Self.notifyKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = list.count == 1 ? "New device\(site.map { " at \($0)" } ?? "")"
                                        : "\(list.count) new devices\(site.map { " at \($0)" } ?? "")"
        content.body = list.prefix(4).map { "\($0.name.isEmpty ? $0.vendor : $0.name) (\($0.ip))" }.joined(separator: ", ")
            + (list.count > 4 ? "…" : "")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Favorites

    func isFavorite(_ d: Device) -> Bool { stored.favorites.contains(d.commentKey) }

    func allFavorite(_ list: [Device]) -> Bool { !list.isEmpty && list.allSatisfy(isFavorite) }

    func toggleFavorite(_ list: [Device]) {
        let makeFavorite = !allFavorite(list)
        for d in list {
            if makeFavorite {
                stored.favorites.insert(d.commentKey)
                if stored.known[d.commentKey] == nil { stored.known[d.commentKey] = clean(d) }
            } else {
                stored.favorites.remove(d.commentKey)
            }
        }
        DeviceStore.save(stored)
    }

    // MARK: History

    func deleteHistory(_ id: ScanRecord.ID) {
        stored.history.removeAll { $0.id == id }
        if selectedRecord == id { selectedRecord = nil }
        DeviceStore.save(stored)
    }

    func clearHistory() {
        stored.history = []
        selectedRecord = nil
        DeviceStore.save(stored)
    }

    /// Forget these offline devices only (right-click › Forget This Device). Favorites are kept.
    func forgetDevices(_ list: [Device]) {
        let keys = Set(list.filter { !$0.isOnline && !stored.favorites.contains($0.commentKey) }.map(\.commentKey))
        guard !keys.isEmpty else { return }
        if let s = siteIndex(siteID) {
            for k in keys { stored.sites[s].known[k] = nil }
        } else {
            for k in keys { stored.known[k] = nil }
        }
        devices.removeAll { !$0.isOnline && keys.contains($0.commentKey) }
        indexByID = Dictionary(devices.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        DeviceStore.save(stored)
    }

    /// Forget devices that are no longer around (clears the offline rows). Favorites are kept.
    func forgetOfflineDevices() {
        let favorites = stored.favorites
        let onlineKeys = Set(devices.filter(\.isOnline).map(\.commentKey))
        if let s = siteIndex(siteID) {
            stored.sites[s].known = stored.sites[s].known.filter { onlineKeys.contains($0.key) }
        } else {
            stored.known = stored.known.filter { onlineKeys.contains($0.key) || favorites.contains($0.key) }
        }
        devices.removeAll { !$0.isOnline }
        indexByID = Dictionary(devices.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        DeviceStore.save(stored)
    }

    // MARK: Comments

    func commentBinding(for d: Device) -> Binding<String> {
        let key = d.commentKey
        return Binding(
            get: { [weak self] in self?.comments[key] ?? "" },
            set: { [weak self] newValue in self?.setComment(newValue, key: key) }
        )
    }

    private func setComment(_ text: String, key: String) {
        guard (comments[key] ?? "") != text else { return }
        comments[key] = text.isEmpty ? nil : text
        // Every keystroke lands here: write the defaults after a pause, and touch only the rows that match.
        commentSaveTask?.cancel()
        commentSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            UserDefaults.standard.set(self.comments, forKey: self.commentsKey)
        }
        for i in devices.indices where devices[i].commentKey == key && devices[i].comment != text { devices[i].comment = text }
    }
    private var commentSaveTask: Task<Void, Never>?

    // MARK: Device types

    /// Adds what the Type column needs: the type picked by hand, the UniFi map's type, the DHCP server.
    func withTypeInfo(_ d: Device) -> Device {
        var d = d
        d.typeOverride = deviceTypes[d.commentKey].flatMap(DeviceKind.init(rawValue:))
        d.mapKind = d.mac.isEmpty ? nil : mapKinds[NetMapBuilder.mac(d.mac)]
        d.switchLink = d.mac.isEmpty ? nil : switchLinks[NetMapBuilder.mac(d.mac)]
        d.isDHCPServer = servers.dhcp == d.ip
        return d
    }

    /// Gateways, switches and access points on the UniFi map, by MAC. Rebuilt when the map changes
    /// (`withTypeInfo` runs for every row on every table update).
    private var mapKinds: [String: DeviceKind] = [:]
    /// Where each device plugs in, by MAC, from the same map.
    private var switchLinks: [String: SwitchLink] = [:]

    nonisolated private static func mapKinds(of netMap: NetMap?) -> [String: DeviceKind] {
        guard let netMap else { return [:] }
        var out: [String: DeviceKind] = [:]
        for n in netMap.nodes where !n.mac.isEmpty {
            switch n.kind {
            case .gateway: out[NetMapBuilder.mac(n.mac)] = .router
            case .switchDevice: out[NetMapBuilder.mac(n.mac)] = .switchDevice
            case .accessPoint: out[NetMapBuilder.mac(n.mac)] = .accessPoint
            default: break
            }
        }
        return out
    }

    /// nil puts the rows back to the automatic guess.
    func setType(_ kind: DeviceKind?, for list: [Device]) {
        for d in list { deviceTypes[d.commentKey] = kind?.rawValue }
        UserDefaults.standard.set(deviceTypes, forKey: typesKey)
    }

    // MARK: Ports and banners

    /// After Scan Ports: add the open ports (and what answers on them) to the device's row.
    func addPortScan(_ ip: IPv4, open: [UInt16], banners: [UInt16: String]) {
        guard let i = indexByID[ip.value], i < devices.count, devices[i].ip == ip else { return }
        devices[i].openPorts = Array(Set(devices[i].openPorts).union(open)).sorted()
        devices[i].banners.merge(banners) { _, new in new }
        if updateSaved(devices[i]) { DeviceStore.save(stored) }
    }

    /// For the details panel: list the device's shared folders, once per device per launch.
    func loadShares(for d: Device) {
        let ports = Set(d.openPorts)
        guard d.isOnline, !ports.isDisjoint(with: [139, 445, 2049]), shares[d.id] == nil, !sharesLoading.contains(d.id) else { return }
        sharesLoading.insert(d.id)
        let ip = d.ip, list = d.openPorts
        Task {
            let info = await offMain { Shares.list(ip, ports: list) }
            sharesLoading.remove(ip.value)
            shares[ip.value] = info
        }
    }

    func openShare(_ name: String, on d: Device) {
        guard let url = Shares.url(d.ip, share: name), NSWorkspace.shared.open(url) else {
            errorMessage = "Couldn’t open the share in Finder."; return
        }
    }

    /// For the details panel: find out what answers on each open port, once per device.
    func loadBanners(for d: Device) {
        loadWebTitle(for: d)
        guard d.isOnline, !d.openPorts.isEmpty, d.banners.isEmpty, !bannerJobs.contains(d.id) else { return }
        bannerJobs.insert(d.id)
        let ip = d.ip, ports = d.openPorts
        Task {
            let found = await offMain { Banner.grabAll(ip: ip, ports: ports, timeout: 2) }
            bannerJobs.remove(ip.value)
            if !found.isEmpty { addPortScan(ip, open: [], banners: found) }
        }
    }

    /// A quiet scan skips web pages, so the details panel reads the device's page title when it opens.
    func loadWebTitle(for d: Device) {
        guard d.isOnline, d.webTitle.isEmpty, !d.openPorts.isEmpty, !webTitleJobs.contains(d.id) else { return }
        webTitleJobs.insert(d.id)
        let ports = [d.ip.value: d.openPorts]
        Task {
            let titles = await offMain { Web.titles(ports, timeout: 3, flag: CancelFlag()) }
            for (id, t) in titles { if let i = indexByID[id] { devices[i].webTitle = t.cleanedNetworkText() } }
        }
    }

    // MARK: Right-click actions

    func perform(_ action: (Device) throws -> Void, on d: Device) {
        do { try action(d) } catch { errorMessage = error.localizedDescription }
    }

    func wake(_ list: [Device]) {
        do {
            let n = try DeviceActions.wake(list, interfaces: interfaces)
            statusText = "Sent Wake-on-LAN to \(n) device\(n == 1 ? "" : "s")"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Rows with the comment filled in from what the user typed, for copy/export.
    func withComments(_ list: [Device]) -> [Device] {
        list.map { var d = withTypeInfo($0); d.comment = comments[d.commentKey] ?? ""; return d }
    }

    // MARK: Export

    /// Saves what's in the table now (search and the Show offline switch apply).
    func export(_ kind: ExportKind) {
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day())
        let base = (currentSite?.name).map { "ARPradar \($0) \(stamp)" } ?? "ARPradar \(stamp)"
        let safe = String(base.map { "/:\\".contains($0) ? "-" : $0 })
        switch kind {
        case .csv:
            panel.allowedContentTypes = [.commaSeparatedText]
            panel.nameFieldStringValue = safe + ".csv"
        case .excel:
            panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
            panel.nameFieldStringValue = safe + ".xlsx"
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let t = Exporter.deviceTable(withComments(visibleDevices), dhcp: dhcpRange)
        do {
            switch kind {
            case .csv: try Exporter.csv(header: t.header, rows: t.rows).write(to: url, atomically: true, encoding: .utf8)
            case .excel:
                try Exporter.xlsx(header: t.header, rows: t.rows, widths: t.widths, numberColumns: [Exporter.responseColumn],
                                  sheetName: currentSite?.name ?? "ARPradar").write(to: url, options: .atomic)
            }
        } catch {
            errorMessage = "Couldn’t save the file: \(error.localizedDescription)"
        }
    }
}

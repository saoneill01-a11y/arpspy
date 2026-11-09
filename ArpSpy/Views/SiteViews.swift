import SwiftUI
import UserNotifications

/// Save to Organization… / Save Standalone… / Edit This Scan…
/// A scan in an organization takes the organization's name server and DHCP range; a standalone one has its own.
struct SiteSheetView: View {
    @ObservedObject var model: ScanModel
    let mode: ScanModel.SiteSheet
    @ObservedObject private var orgs = OrgStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var name = ""
    @State private var range = ""
    @State private var nameServer = ""
    @State private var dhcpRange = ""
    @State private var community = ""
    /// The organization picked; `standaloneTag` = none, `newOrgTag` = make one.
    @State private var orgID: UUID = SiteSheetView.standaloneTag
    @State private var newOrgName = ""
    @State private var newOrgDomains = ""
    static let newOrgTag = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let standaloneTag = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    private var editingID: UUID? { if case .edit(let id) = mode { return id }; return nil }
    /// Save Standalone… from the save bar: no organization choice at all.
    private var standaloneOnly: Bool { editingID == nil && model.saveStandalone }
    private var isNewOrg: Bool { orgID == Self.newOrgTag }
    private var existingOrg: Organization? { orgs.org(orgID) }
    /// Name server and DHCP range are typed here (standalone or a new organization), not inherited.
    private var ownSettings: Bool { existingOrg == nil }

    private func trimmed(_ t: String) -> String { t.trimmingCharacters(in: .whitespaces) }
    private var rangeOK: Bool { (try? IPRangeParser.parse(range)) != nil }
    private var serverOK: Bool { trimmed(nameServer).isEmpty || IPv4(trimmed(nameServer)) != nil }
    private var nameTaken: Bool {
        model.stored.sites.contains { $0.id != editingID && $0.name.caseInsensitiveCompare(trimmed(name)) == .orderedSame }
    }
    private var dhcpOK: Bool { DHCPRange.isValid(dhcpRange) }
    private var orgOK: Bool { !isNewOrg || !trimmed(newOrgName).isEmpty }
    private var canSave: Bool {
        !trimmed(name).isEmpty && !nameTaken && rangeOK && orgOK && (!ownSettings || (serverOK && dhcpOK))
    }

    private var title: String {
        if editingID != nil { return "Edit saved scan" }
        return standaloneOnly ? "Save Standalone" : "Save to Organization"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Form {
                if !standaloneOnly {
                    Picker("Organization", selection: $orgID) {
                        if editingID != nil {
                            Text("Standalone (no organization)").tag(Self.standaloneTag)
                            Divider()
                        }
                        ForEach(orgs.sortedOrgs) { o in Text(o.name).tag(o.id) }
                        if !orgs.orgs.isEmpty { Divider() }
                        Text("New Organization…").tag(Self.newOrgTag)
                    }
                    if isNewOrg {
                        TextField("Organization name", text: $newOrgName, prompt: Text("e.g. Example Dental"))
                        TextField("Domains", text: $newOrgDomains, prompt: Text("Optional, e.g. example.com"))
                            .font(.system(.body, design: .monospaced))
                    }
                }
                TextField("Scan name", text: $name, prompt: Text(standaloneOnly || orgID == Self.standaloneTag ? "e.g. Home" : "e.g. Main office"))
                if nameTaken { Text("There’s already a saved scan with that name.").font(.caption).foregroundStyle(.red) }
                TextField("IP range", text: $range, prompt: Text("10.0.0.0/24"))
                    .font(.system(.body, design: .monospaced))
                if !range.isEmpty && !rangeOK { Text("That isn’t a valid IP range.").font(.caption).foregroundStyle(.red) }

                if let org = existingOrg {
                    inherited("Name server", org.nameServer, from: org.name, blank: "This Mac’s DNS")
                    inherited("DHCP range", org.dhcpRange, from: org.name, blank: "Not set")
                    inherited("SNMP community", org.snmpCommunity, from: org.name, blank: "public")
                    HStack(spacing: 4) {
                        Text("Change these in the organization’s settings.")
                        Button("Open \(org.name)…") { orgs.focus = org.id; openWindow(id: OrgWindows.list) }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    TextField("Name server", text: $nameServer, prompt: Text("Optional, e.g. 10.0.0.5"))
                        .font(.system(.body, design: .monospaced))
                    Text(serverOK
                         ? "That network’s DNS server (a domain controller, Pi-hole or router). ARPradar asks it for device names. Leave blank to use this Mac’s DNS."
                         : "The name server must be an IP address.")
                        .font(.caption)
                        .foregroundStyle(serverOK ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("DHCP range", text: $dhcpRange, prompt: Text("Optional, e.g. 10.0.0.100-10.0.0.199"))
                        .font(.system(.body, design: .monospaced))
                    Text(dhcpOK ? "The DHCP server’s pool (several allowed, comma-separated). Addresses outside it are tinted when Mark outside DHCP is on."
                                : "That isn’t a valid range. Use start-end, e.g. 10.0.0.100-10.0.0.199 or 10.0.0.100-199.")
                        .font(.caption)
                        .foregroundStyle(dhcpOK ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField("SNMP community", text: $community, prompt: Text("public"))
                        .font(.system(.body, design: .monospaced))
                    Text("Read-only community for asking switches, printers and UPSes their name and model. Only sent on this scan’s network.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isNewOrg {
                        Text("These become the new organization’s settings, used by all its scans.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if editingID == nil {
                Text(model.onlineCount > 0
                     ? "The \(model.onlineCount) devices in Results are saved with it. Pick it from Saved Scans later to see them and scan that network again."
                     : "Nothing is in Results yet; press Scan after saving to fill it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if let id = editingID, let s = model.stored.sites.first(where: { $0.id == id }) {
                name = s.name; range = s.range; nameServer = s.nameServer; dhcpRange = s.dhcpRange; community = s.snmpCommunity
                orgID = s.orgID.flatMap { orgs.org($0)?.id } ?? Self.standaloneTag
            } else {
                range = model.rangeText
                if standaloneOnly {
                    orgID = Self.standaloneTag
                } else {
                    orgID = [model.preferredOrgID, model.currentOrgID, orgs.sortedOrgs.first?.id]
                        .compactMap { $0 }.first { orgs.org($0) != nil } ?? Self.newOrgTag
                }
            }
        }
    }

    private func inherited(_ label: String, _ value: String, from org: String, blank: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Text(value.isEmpty ? blank : value)
                    .font(.system(.body, design: value.isEmpty ? .default : .monospaced))
                Text("from \(org)").foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        let n = trimmed(name), r = trimmed(range)
        var ns = trimmed(nameServer), d = trimmed(dhcpRange), c = trimmed(community)
        var org: UUID? = orgID == Self.standaloneTag ? nil : orgID
        if isNewOrg {
            var o = Organization(name: orgs.uniqueName(trimmed(newOrgName)), domains: Organization.parseDomains(newOrgDomains))
            o.nameServer = ns; o.dhcpRange = d; o.snmpCommunity = c
            org = orgs.add(o)
            ns = ""; d = ""; c = ""
        } else if editingID == nil, org != nil {
            ns = ""; d = ""; c = ""   // a new scan in an organization uses the organization's settings
        }
        if let id = editingID {
            // Moving into an organization keeps the scan's own values only as a fallback.
            model.updateSite(id, name: n, range: r, nameServer: ns, orgID: .some(org), dhcpRange: d, snmpCommunity: c)
        } else {
            model.saveSite(name: n, range: r, nameServer: ns, orgID: org, dhcpRange: d, snmpCommunity: c)
        }
    }
}

/// ArpSpy › Settings…
struct SettingsView: View {
    @AppStorage(ScanModel.notifyKey) private var notify = false
    @AppStorage(MenuBarSetting.key) private var menuBar = false
    @State private var notifyDenied = false
    @AppStorage(ColumnSetting.typeKey) private var showType = true
    @AppStorage(ColumnSetting.switchPortKey) private var showSwitchPort = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }
        }
        .frame(width: 500)
    }

    private var general: some View {
        Form {
            Toggle("Show the Type column", isOn: $showType)
            Toggle("Show the Switch port column", isOn: $showSwitchPort)
            Text("Switch port shows where each device plugs in (switch and port, or access point for Wi-Fi). It needs a UniFi controller: see the Map tab.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("Show ARPradar in the menu bar", isOn: $menuBar)
            Text("A radar icon next to the clock: the current network, Scan Now, new devices, Ping and Speed Test. ARPradar keeps running there when its windows are closed.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("Notify me about new devices", isOn: $notify)
                .onChange(of: notify) { _, on in if on { askPermission() } }
            Text("After a scan, a notification lists devices this saved scan (or ARPradar) has never seen before.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if notifyDenied {
                Text("Notifications are off for ARPradar in System Settings › Notifications.")
                    .font(.caption).foregroundStyle(.red)
            }
            Divider()
            Text("SNMP community").fontWeight(.semibold)
            Text("ARPradar asks switches, access points, printers and UPSes for their name and model with a read-only SNMP community. New scans send “public”. A client’s own community is set per organization (Organizations › Settings) or per standalone saved scan (Edit This Scan…), so it is only ever sent on that client’s network.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    private func askPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            DispatchQueue.main.async { notifyDenied = !ok }
        }
    }
}

/// File › Save Current Scan as Site…, Export…; View › Device Details, Show Offline.
struct MainCommands: Commands {
    @ObservedObject var model = ScanModel.shared
    @AppStorage(AppMode.key) private var advanced = true
    @AppStorage(ColumnSetting.typeKey) private var showType = true
    @AppStorage(ColumnSetting.switchPortKey) private var showSwitchPort = false

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Scan") { model.newScan() }
                .keyboardShortcut("n")
                .disabled(model.isScanning)
            Menu("Open Recent") {
                ForEach(model.recentScans) { r in
                    Button(ScanModel.recentTitle(r)) { model.openRecent(r) }
                }
                if !model.recentScans.isEmpty { Divider() }
                Button("Clear Menu") { model.clearRecentScans() }
                    .disabled(model.recentScans.isEmpty)
            }
            .disabled(model.isScanning)
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Save Scan…") { model.saveStandalone = false; model.siteSheet = .new }
                .keyboardShortcut("s")
                .disabled(model.isScanning || model.siteID != nil || !model.devices.contains(where: \.isOnline))
            Button("Edit This Scan…") { if let id = model.siteID { model.siteSheet = .edit(id) } }
                .disabled(model.siteID == nil)
            OpenSiteListButton()
            Divider()
            OpenRemoteWakeButton()
        }
        CommandGroup(replacing: .importExport) {
            Button("Export as CSV…") { model.export(.csv) }
                .keyboardShortcut("e")
            Button("Export as Excel (.xlsx)…") { model.export(.excel) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Divider()
            Button("Export Scans…") { model.transferSheet = .export }
                .disabled(model.stored.sites.isEmpty)
            Button("Import Scans…") { model.beginImport() }
                .disabled(model.isScanning)
        }
        CommandGroup(after: .toolbar) {
            Button("Rescan") { if model.canRescan { model.toggleScan() } }
                .keyboardShortcut("r")
                .disabled(!model.canRescan)
            Button("Find Device") { model.searchFocusToken += 1 }
                .keyboardShortcut("f")
            Divider()
            Button(model.showDetails ? "Hide Device Details" : "Show Device Details") { model.showDetails.toggle() }
                .keyboardShortcut("i")
            Toggle("Show Offline Devices", isOn: $model.showOffline)
            Toggle("Type Column", isOn: $showType)
            Toggle("Switch Port Column", isOn: $showSwitchPort)
            if advanced { Toggle("Mark Addresses Outside DHCP Range", isOn: $model.markOutsideDHCP) }
            Toggle("Advanced Mode", isOn: $advanced)
                .keyboardShortcut("b", modifiers: [.command, .option])
            Divider()
        }
    }
}

/// File › Edit Scan List… (⌥⌘S).
struct OpenSiteListButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Edit Scan List…") { openWindow(id: SiteListView.windowID) }
            .keyboardShortcut("s", modifiers: [.command, .option])
    }
}

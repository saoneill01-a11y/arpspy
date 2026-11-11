import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum OrgWindows {
    static let list = "organizations", setup = "organization-setup", survey = "site-survey", item = "saved-item"
}

// MARK: - Menus and scenes

/// File › New Organization… (⇧⌘N) and Organizations… (⌘K).
struct OrgMenuItems: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppMode.key) private var advanced = true
    var body: some View {
        if advanced {
            Button("New Organization…") { openWindow(id: OrgWindows.setup) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Organizations…") { openWindow(id: OrgWindows.list) }
                .keyboardShortcut("k")
        }
    }
}

struct OrgCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .newItem) { Divider(); OrgMenuItems() }
    }
}

struct OrgScenes: Scene {
    var body: some Scene {
        Window("Organizations", id: OrgWindows.list) { OrganizationsView().modifier(AppearanceApplier()) }
            .defaultSize(width: 1000, height: 640)
        WindowGroup("Organization", id: OrgWindows.setup, for: UUID.self) { $org in
            SurveySetupView(orgID: org).modifier(AppearanceApplier())
        }
        .defaultSize(width: 560, height: 640)
        Window("Site Survey", id: OrgWindows.survey) { SurveyView().modifier(AppearanceApplier()) }
            .defaultSize(width: 560, height: 420)
        WindowGroup("Saved", id: OrgWindows.item, for: UUID.self) { $item in
            SavedItemView(itemID: item).modifier(AppearanceApplier())
        }
        .defaultSize(width: 900, height: 560)
    }
}

// MARK: - Save to Organization (used by every tool)

private struct AutoSaveOrgKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    /// Set in a window opened from an organization's page: finished results are filed there automatically.
    var autoSaveOrg: UUID? {
        get { self[AutoSaveOrgKey.self] }
        set { self[AutoSaveOrgKey.self] = newValue }
    }
}

/// On every tool window: if it was opened from an organization's page, remembers that organization.
struct OrgAutoSaveScope: ViewModifier {
    @State private var org: UUID? = nil
    @Environment(\.controlActiveState) private var active
    func body(content: Content) -> some View {
        content
            .environment(\.autoSaveOrg, org)
            .onAppear { if org == nil { org = OrgStore.shared.takeLaunch() } }
            // A single-instance tool window (Speed Test, Connection Info, Wi-Fi Analyzer) that is already open is
            // only brought to the front when opened from an organization; it takes the launch when it becomes key.
            .onChange(of: active) { _, state in
                if state == .key, let o = OrgStore.shared.takeLaunch() { org = o }
            }
    }
}

struct SaveToOrgButton: View {
    var enabled = true
    /// False for tools that keep running (Ping, Wi-Fi): they're saved by hand only.
    var auto = true
    let make: () -> SavedDraft?
    @Environment(\.autoSaveOrg) private var autoOrg
    @State private var autoSaved = 0
    @ObservedObject private var orgs = OrgStore.shared
    @ObservedObject private var model = ScanModel.shared
    @Environment(\.openWindow) private var openWindow
    @State private var target: UUID? = nil
    @State private var draft: SavedDraft? = nil
    @State private var note = ""
    @State private var justSaved = false

    @AppStorage(AppMode.key) private var advanced = true

    var body: some View {
        Group {
            if advanced { button }
        }
        // Opened from an organization: each finished run is filed there without asking.
        .onChange(of: enabled) { was, now in
            guard auto, !was, now, let o = autoOrg, orgs.org(o) != nil, let d = make() else { return }
            orgs.save(d, to: o, siteName: model.currentSite?.name ?? "")
            autoSaved += 1
        }
    }

    private var label: String {
        if justSaved { return "Saved ✓" }
        if auto, let o = autoOrg.flatMap({ orgs.org($0) }) {
            return autoSaved > 0 ? "Saved to \(o.name) ✓" : "Saves to \(o.name)"
        }
        return "Save to Organization"
    }

    private var button: some View {
        Menu(label) {
            if let cur = model.preferredOrgID ?? model.currentOrgID, let o = orgs.org(cur) {
                Button("\(o.name) (\(model.preferredOrgID == cur ? "started from here" : "current scan"))") { pick(cur) }
                Divider()
            }
            ForEach(orgs.sortedOrgs) { o in Button(o.name) { pick(o.id) } }
            if !orgs.orgs.isEmpty { Divider() }
            Button("New Organization…") { openWindow(id: OrgWindows.setup) }
        }
        .fixedSize()
        .disabled(!enabled)
        .help("File these results under an organization, to look back at later")
        .alert("Save to \(orgs.org(target)?.name ?? "")", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } })) {
            TextField("Note (optional)", text: $note)
            Button("Save") {
                if let t = target, let d = draft {
                    orgs.save(d, to: t, note: note.trimmingCharacters(in: .whitespaces), siteName: model.currentSite?.name ?? "")
                    justSaved = true
                    Task { try? await Task.sleep(nanoseconds: 2_000_000_000); justSaved = false }
                }
                target = nil
            }
            Button("Cancel", role: .cancel) { target = nil }
        } message: {
            Text(draft.map { "\($0.title) · \($0.summary)" } ?? "")
        }
    }

    private func pick(_ id: UUID) {
        guard let d = make() else { return }
        draft = d; note = ""; target = id
    }
}

// MARK: - Organizations window

struct OrganizationsView: View {
    @ObservedObject private var orgs = OrgStore.shared
    @ObservedObject private var model = ScanModel.shared
    @State private var selected: UUID? = nil
    @State private var confirmDelete = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    Section("Organizations") {
                        ForEach(orgs.sortedOrgs) { o in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(o.name)
                                let n = model.sites(in: o.id).count
                                Text("\(n) scan\(n == 1 ? "" : "s") · \(orgs.items(for: o.id).count) saved")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(o.id)
                            .contextMenu {
                                Button("Delete Organization…") { selected = o.id; confirmDelete = true }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .onDeleteCommand { if selected != nil { confirmDelete = true } }
                Divider()
                HStack(spacing: 4) {
                    Button { openWindow(id: OrgWindows.setup) } label: { Label("New", systemImage: "plus") }
                        .help("New organization (⇧⌘N)")
                        .accessibilityLabel("New organization")
                    Spacer()
                    Button("Delete Organization…", role: .destructive) { confirmDelete = true }
                        .disabled(selected == nil)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 320)

            Group {
                if let id = selected, orgs.org(id) != nil {
                    OrgDetail(orgID: id)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "building.2").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text(orgs.orgs.isEmpty ? "No organizations yet." : "Pick an organization on the left.").foregroundStyle(.secondary)
                        Button("New Organization…") { openWindow(id: OrgWindows.setup) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 800, minHeight: 460)
        .onAppear {
            if let f = orgs.focus { selected = f; orgs.focus = nil }
            if selected == nil { selected = model.currentOrgID ?? orgs.sortedOrgs.first?.id }
        }
        .onChange(of: orgs.focus) { _, f in if let f { selected = f; orgs.focus = nil } }
        .confirmationDialog("Delete “\(orgs.org(selected)?.name ?? "")”?", isPresented: $confirmDelete) {
            Button("Delete Organization", role: .destructive) {
                if let id = selected { model.detachSites(from: id); orgs.delete(id); selected = orgs.sortedOrgs.first?.id }
            }
        } message: {
            Text("Its \(orgs.items(for: selected ?? UUID()).count) saved items are removed. This can’t be undone. Its saved scans stay, as standalone.")
        }
    }
}

/// Organizations › Settings: what every scan in the organization uses. Edits save as you type.
private struct OrgSettingsBox: View {
    let org: Organization
    @ObservedObject private var orgs = OrgStore.shared
    @ObservedObject private var unifi = UniFiStore.shared
    @State private var showUniFi = false

    private func trimmed(_ t: String) -> String { t.trimmingCharacters(in: .whitespaces) }
    private var serverOK: Bool { trimmed(org.nameServer).isEmpty || IPv4(trimmed(org.nameServer)) != nil }
    private var dhcpOK: Bool { DHCPRange.isValid(org.dhcpRange) }

    var body: some View {
        GroupBox {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                row("Domains") {
                    field("example.com, example.org", Binding(get: { org.domains.joined(separator: ", ") },
                                                             set: { v in orgs.update(org.id) { $0.domains = Organization.parseDomains(v) } }))
                }
                row("Name server") {
                    field("Blank = this Mac’s DNS, or e.g. 10.0.0.5", Binding(get: { org.nameServer },
                                                                              set: { v in orgs.update(org.id) { $0.nameServer = v } }))
                    if !serverOK { warn("The name server must be an IP address.") }
                }
                row("DHCP range") {
                    field("Optional, e.g. 10.0.0.100-10.0.0.199", Binding(get: { org.dhcpRange },
                                                                          set: { v in orgs.update(org.id) { $0.dhcpRange = v } }))
                    if !dhcpOK { warn("Use start-end, e.g. 10.0.0.100-10.0.0.199 (several allowed, comma-separated).") }
                }
                row("SNMP community") {
                    field("public", Binding(get: { org.snmpCommunity }, set: { v in orgs.update(org.id) { $0.snmpCommunity = v } }))
                    Text("Read-only community for asking its switches, printers and UPSes their name and model. Only sent on this organization’s networks.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                row("Scan style") {
                    Picker("Scan style", selection: Binding(get: { org.quietScan }, set: { v in orgs.update(org.id) { $0.quietScan = v } })) {
                        Text("Normal").tag(false)
                        Text("Quiet").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Text(org.quietScan
                         ? "Every scan and survey for \(org.name) starts in Quiet: slower, far fewer probes. The survey’s speed test starts unchecked."
                         : "Quiet sends far fewer probes (for networks with an IDS or touchy devices). You can still switch any scan in the scan bar.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                row("UniFi") {
                    HStack(spacing: 8) {
                        if let c = unifi.controller(forOrg: org.id) {
                            Text(c.address + (c.siteName.isEmpty || c.siteName == "Default" ? "" : " · \(c.siteName)"))
                                .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        } else {
                            Text("No controller (the Map tab shows only what the scan finds)").foregroundStyle(.secondary)
                        }
                        Button(unifi.controller(forOrg: org.id) == nil ? "Set Up…" : "Edit…") { showUniFi = true }
                    }
                }
                row("Notes") {
                    TextEditor(text: Binding(get: { org.notes }, set: { v in orgs.update(org.id) { $0.notes = v } }))
                        .font(.body)
                        .frame(minHeight: 40, maxHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                }
            }
            .padding(4)
            Text("Every scan in \(org.name) uses this name server, DHCP range and SNMP community.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            if let when = org.seenDate {
                let found = NetServers(dhcp: IPv4(org.seenDHCPServer), dns: org.seenNameServers.compactMap(IPv4.init))
                Text("Seen on the last scan (\(org.seenScan), \(when.formatted(date: .abbreviated, time: .shortened))): \(found.summary)")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        } label: {
            Text("Settings").font(.headline)
        }
        .sheet(isPresented: $showUniFi) {
            UniFiControllerSheet(orgID: org.id, existing: unifi.controller(forOrg: org.id), suggested: "")
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            VStack(alignment: .leading, spacing: 3) { content() }
        }
    }

    private func field(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
    }

    private func warn(_ t: String) -> some View { Text(t).font(.caption).foregroundStyle(.red) }
}

private struct OrgDetail: View {
    let orgID: UUID
    @ObservedObject private var orgs = OrgStore.shared
    @ObservedObject private var model = ScanModel.shared
    @State private var filter = SavedItem.Filter.surveys
    /// Surveys opened on the Site Surveys tab (they start closed).
    @State private var expanded = Set<UUID>()
    @State private var askPortTarget = false
    @State private var portTarget = ""
    @State private var selection = Set<UUID>()
    @State private var confirmDelete = false
    @State private var editingNote: UUID? = nil
    @State private var noteText = ""
    @Environment(\.openWindow) private var openWindow

    private var org: Organization? { orgs.org(orgID) }
    private var shown: [(item: SavedItem, indented: Bool)] {
        let list = orgs.items(for: orgID)
        if filter == .surveys { return OrgStore.surveyRows(list, expanded: expanded) }
        return list.filter { $0.kind.group == filter }.map { ($0, false) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let org {
                HStack(spacing: 6) {
                    TextField("Name", text: Binding(get: { org.name }, set: { v in orgs.update(orgID) { $0.name = v } }))
                        .font(.title2.weight(.semibold))
                        .textFieldStyle(.plain)
                        .help("Click to rename the organization")
                    Image(systemName: "pencil").foregroundStyle(.tertiary).help("Click the name to rename it")
                        .accessibilityHidden(true)
                }
                OrgSettingsBox(org: org)
                HStack(alignment: .firstTextBaseline) {
                    Text("Scans").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    let sites = model.sites(in: orgID)
                    if sites.isEmpty {
                        Text("None yet: run a survey, or press New Network Scan below and save it to this organization.").foregroundStyle(.secondary).font(.callout)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(sites) { s in
                                    Button { model.selectSite(s.id); openWindow(id: "main") } label: {
                                        Text("\(s.name)  \(s.range)").font(.callout)
                                    }
                                    .help("Open \(s.name) in the main window")
                                    .disabled(model.isScanning)
                                }
                            }
                        }
                    }
                }
            }

            HStack {
                Picker("", selection: $filter) {
                    ForEach(SavedItem.Filter.allCases) { f in Text(f.rawValue).tag(f) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                if filter == .surveys {
                    Button { openWindow(id: OrgWindows.setup, value: orgID) } label: { Label("New Site Survey", systemImage: "plus") }
                        .disabled(SurveyRunner.shared.running || model.isScanning)
                        .help("Runs a survey for this organization. Click a survey to show or hide what it found.")
                }
                if filter == .heatmaps {
                    Button { openTool(ToolWindow.heatmap) } label: { Label("New Wi-Fi Heatmap", systemImage: "plus") }
                        .help("Opens Wi-Fi Heatmap. Save the result to this organization from there.")
                }
                if filter == .scans {
                    Button { model.newScan(for: orgID); openWindow(id: "main") } label: {
                        Label("New Network Scan", systemImage: "plus")
                    }
                    .disabled(model.isScanning)
                    .help("Opens a new scan in the main window. Each finished scan is saved here automatically.")
                }
                if filter == .ports {
                    Button { portTarget = ""; askPortTarget = true } label: { Label("New Port Scan", systemImage: "plus") }
                        .disabled(model.isScanning)
                        .help("Scans one address for open ports. The result is saved here automatically.")
                }
                if filter == .other {
                    Menu {
                        Button("Ping…") { openTool(ToolWindow.ping) }
                        Button("Traceroute…") { openTool(ToolWindow.trace) }
                        Button("Speed Test") { openTool(ToolWindow.speed) }
                        Button("Connection Info") { openTool(ToolWindow.connection) }
                        Button("Wi-Fi Analyzer") { openTool(ToolWindow.analyzer) }
                    } label: { Label("New…", systemImage: "plus") }
                    .fixedSize()
                    .help("Traceroutes, speed tests and connection info are saved here automatically when they finish. Ping and Wi-Fi keep running, so save those with their Save to Organization button.")
                }
                if filter == .dns {
                    let domains = org?.domains ?? []
                    if domains.count > 1 {
                        Menu {
                            ForEach(domains, id: \.self) { d in Button(d) { newDNS(d) } }
                            Divider()
                            Button("Other Name…") { newDNS(nil) }
                        } label: { Label("New DNS Lookup", systemImage: "plus") }
                        .fixedSize()
                    } else {
                        Button { newDNS(domains.first) } label: { Label("New DNS Lookup", systemImage: "plus") }
                            .help(domains.first.map { "Looks up \($0) (All) and saves the result here automatically." } ?? "Opens DNS Lookup. Each finished lookup is saved here automatically.")
                    }
                }
            }

            .alert("New Port Scan", isPresented: $askPortTarget) {
                TextField("IP address", text: $portTarget, prompt: Text("e.g. 10.20.30.5"))
                Button("Scan") { startPortScan() }
                    .disabled(IPv4(portTarget.trimmingCharacters(in: .whitespaces)) == nil)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The address to check for open ports (one IPv4 address, like 10.20.30.5). The result is saved in \(org?.name ?? "this organization").")
            }

            List(selection: $selection) {
                ForEach(shown, id: \.item.id) { row in
                    let i = row.item
                    let isSurveyHeader = filter == .surveys && i.kind == .survey
                    HStack(alignment: .top, spacing: 10) {
                        if isSurveyHeader {
                            Image(systemName: expanded.contains(i.id) ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 12).padding(.top, 3)
                                .accessibilityLabel(expanded.contains(i.id) ? "Hide results" : "Show results")
                        }
                        Image(systemName: i.kind.symbol).foregroundStyle(.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(i.title).fontWeight(.semibold)
                            Text([i.date.formatted(date: .abbreviated, time: .shortened), i.summary].joined(separator: " · "))
                                .font(.callout).foregroundStyle(.secondary)
                            if !i.note.isEmpty { Text("“\(i.note)”").font(.callout).italic() }
                        }
                        Spacer()
                        if isSurveyHeader {
                            let n = OrgStore.surveyResultCount(i, in: orgs.items(for: orgID))
                            Text("\(n) result\(n == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                        }
                        if i.surveyID != nil && i.kind != .survey && !row.indented {
                            Text("survey").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                    }
                    .padding(.leading, row.indented ? 50 : 0)
                    .contentShape(Rectangle())
                    // Clicking a survey opens or closes its list of results (it's still selected, too).
                    .simultaneousGesture(TapGesture().onEnded {
                        guard isSurveyHeader else { return }
                        if expanded.contains(i.id) { expanded.remove(i.id) } else { expanded.insert(i.id) }
                    })
                    .tag(i.id)
                    .padding(.vertical, 2)
                }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if ids.count == 1, let id = ids.first {
                    Button("Open") { openWindow(id: OrgWindows.item, value: id) }
                    Button("Edit Note…") { editingNote = id; noteText = orgs.item(id)?.note ?? "" }
                    Divider()
                }
                if !ids.isEmpty { Button(ids.count == 1 ? "Delete…" : "Delete \(ids.count) Items…") { selection = ids; confirmDelete = true } }
            } primaryAction: { ids in
                for id in ids.prefix(5) { openWindow(id: OrgWindows.item, value: id) }   // not a window per item for a big selection
            }
            .onDeleteCommand { if !selection.isEmpty { confirmDelete = true } }
            .overlay {
                if shown.isEmpty {
                    Text(filter == .surveys ? "No site surveys yet. Click New Site Survey to run one."
                                            : "Nothing saved under \(filter.rawValue).")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }

            HStack {
                Button("Open") { for id in selection { openWindow(id: OrgWindows.item, value: id) } }
                    .disabled(selection.isEmpty)
                Button("Run Survey…") { openWindow(id: OrgWindows.setup, value: orgID) }
                    .disabled(SurveyRunner.shared.running || model.isScanning)
                Button(selection.count > 1 ? "Delete \(selection.count) Saved Items…" : "Delete Saved Item…", role: .destructive) { confirmDelete = true }
                    .disabled(selection.isEmpty)
                    .help("Deletes the saved results selected in the list (not the organization)")
                Spacer()
                Button("Export Organization (Excel)…", action: export)
            }
        }
        .padding(16)
        .onChange(of: orgID) { selection = []; filter = .surveys; expanded = [] }
        .confirmationDialog(selection.count == 1 ? "Delete this saved item?" : "Delete \(selection.count) saved items?",
                            isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { orgs.deleteItems(selection); selection = [] }
        } message: { Text("This can’t be undone.") }
        .alert("Note", isPresented: Binding(get: { editingNote != nil }, set: { if !$0 { editingNote = nil } })) {
            TextField("Note", text: $noteText)
            Button("Save") { if let id = editingNote { orgs.updateItem(id) { $0.note = noteText } }; editingNote = nil }
            Button("Cancel", role: .cancel) { editingNote = nil }
        }
    }

    /// Opens DNS Lookup (looking up `domain` right away, if given); its Save to Organization offers this one first.
    private func newDNS(_ domain: String?) {
        model.preferredOrgID = orgID
        orgs.launch(from: orgID)
        if let domain { openWindow(id: ToolWindow.dns, value: domain) } else { openWindow(id: ToolWindow.dns) }
    }

    private func openTool(_ id: String) {
        model.preferredOrgID = orgID
        orgs.launch(from: orgID)
        openWindow(id: id)
    }

    /// New Port Scan: the address typed in the prompt, as the device it is if a scan found it.
    private func startPortScan() {
        let t = portTarget.trimmingCharacters(in: .whitespaces)
        guard let ip = IPv4(t) else { return }
        model.preferredOrgID = orgID
        orgs.launch(from: orgID)
        let d = model.devices.first { $0.ip == ip } ?? Device(ip: ip)
        PortScanView.pending[ip.value] = d
        openWindow(id: PortScanView.windowID, value: ip.value)
    }

    private func export() {
        guard let org else { return }
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = String("\(org.name) \(stamp).xlsx".map { "/:\\".contains($0) ? "-" : $0 })
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try orgs.workbook(for: orgID, sites: model.sites(in: orgID)).write(to: url, options: .atomic) }
        catch { model.errorMessage = "Couldn’t save the file: \(error.localizedDescription)" }
    }
}

// MARK: - A saved item, as it was

struct SavedItemView: View {
    let itemID: UUID?
    @ObservedObject private var orgs = OrgStore.shared
    /// Same switch as the DNS Lookup tool.
    @AppStorage("dnsFollowCNAMEs") private var follow = false

    /// The table as shown: a DNS lookup hides the CNAME chain (↳ rows) unless Follow CNAMEs is on.
    private func shown(_ item: SavedItem) -> SavedTable {
        item.kind == .dns && !follow ? item.table.withoutCNAMEChain() : item.table
    }

    var body: some View {
        if let item = orgs.item(itemID) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: item.kind.symbol).foregroundStyle(.secondary)
                    Text(item.title).font(.title3.weight(.semibold))
                    Spacer()
                    if item.kind == .dns {
                        Toggle("Follow CNAMEs to other domains", isOn: $follow)
                            .toggleStyle(.checkbox)
                            .help("Also show where this domain’s CNAMEs lead (indented with ↳)")
                            .fixedSize()
                    }
                    Menu("Download…") {
                        Button("Download CSV…") { save(item, excel: false) }
                        Button("Download Excel (.xlsx)…") { save(item, excel: true) }
                    }
                    .fixedSize()
                }
                let orgName = orgs.org(item.orgID)?.name ?? ""
                Text([orgName, item.siteName == orgName ? "" : item.siteName, item.date.formatted(date: .abbreviated, time: .shortened), item.summary]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .foregroundStyle(.secondary).font(.callout)
                if !item.note.isEmpty { Text("“\(item.note)”").italic().font(.callout) }
                if item.kind == .dns && follow && !item.table.hasCNAMEChain {
                    Text("This lookup was saved without where its CNAMEs lead. Look it up again in DNS Lookup to see them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if item.kind == .dns, let sections = shown(item).dnsSections() {
                    DNSSectionsView(sections: sections)
                } else {
                    SavedTableView(table: shown(item))
                }
            }
            .padding(16)
            .frame(minWidth: 520, minHeight: 300)
            .navigationTitle(item.title)
        } else {
            Text("This saved item was deleted.").foregroundStyle(.secondary).frame(minWidth: 300, minHeight: 120)
        }
    }

    private func save(_ item: SavedItem, excel: Bool) {
        let panel = NSSavePanel()
        let base = "\(item.title) \(item.date.formatted(.iso8601.year().month().day()))".map { "/:\\".contains($0) ? "-" : $0 }
        panel.nameFieldStringValue = String(base) + (excel ? ".xlsx" : ".csv")
        panel.allowedContentTypes = excel ? [UTType(filenameExtension: "xlsx") ?? .data] : [.commaSeparatedText]
        panel.prompt = "Download"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let t = shown(item)
        do {
            if excel {
                try Exporter.xlsx(header: t.header, rows: t.rows, widths: t.widths,
                                  numberColumns: t.numberColumns, sheetName: item.kind.title).write(to: url, options: .atomic)
            } else {
                try Exporter.csv(header: t.header, rows: t.rows).write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            ScanModel.shared.errorMessage = "Couldn’t save the file: \(error.localizedDescription)"
        }
    }
}

/// Any saved table: a header row and rows, scrollable both ways, text selectable.
struct SavedTableView: View {
    let table: SavedTable

    private func width(_ c: Int) -> CGFloat {
        CGFloat(c < table.widths.count ? table.widths[c] : 16) * 7.5 + 12
    }

    var body: some View {
        let columns = max(table.header.count, table.rows.map(\.count).max() ?? 0)
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { r, row in
                        HStack(spacing: 0) {
                            ForEach(0..<columns, id: \.self) { c in
                                Text(c < row.count ? row[c] : "")
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                                    .frame(width: width(c), alignment: .leading)
                                    .padding(.vertical, 3)
                            }
                        }
                        .padding(.horizontal, 6)
                        .background(r % 2 == 1 ? Color.secondary.opacity(0.07) : Color.clear)
                    }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(0..<columns, id: \.self) { c in
                            Text(c < table.header.count ? table.header[c] : "").fontWeight(.semibold)
                                .frame(width: width(c), alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
            .font(.callout)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }
}

// MARK: - New organization / run a survey

struct SurveySetupView: View {
    /// nil = a new organization; otherwise run a survey for this one.
    let orgID: UUID?
    @ObservedObject private var orgs = OrgStore.shared
    @ObservedObject private var model = ScanModel.shared
    @ObservedObject private var survey = SurveyRunner.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var domains = ""
    @State private var notes = ""
    /// nil = a new site (this network).
    @State private var siteID: UUID? = nil
    @State private var siteName = ""
    @State private var range = ""
    @State private var nameServer = ""
    @State private var dhcpRange = ""
    @State private var steps = Set(SurveyRunner.StepKind.allCases)
    @State private var loaded = false
    /// This Mac's network, and whether the Range was typed by hand (then it no longer follows the DHCP range).
    @State private var thisNetwork = ""
    @State private var rangeEdited = false

    private var existing: Organization? { orgs.org(orgID) }
    private var orgSites: [Site] { orgID.map { model.sites(in: $0) } ?? [] }
    private var rangeOK: Bool { siteID != nil || (try? IPRangeParser.parse(range)) != nil }
    private var serverOK: Bool { nameServer.trimmingCharacters(in: .whitespaces).isEmpty || IPv4(nameServer.trimmingCharacters(in: .whitespaces)) != nil }
    private var nameOK: Bool { existing != nil || !name.trimmingCharacters(in: .whitespaces).isEmpty }
    private var siteOK: Bool { siteID != nil || !siteName.trimmingCharacters(in: .whitespaces).isEmpty }
    private var dhcpOK: Bool { existing != nil || DHCPRange.isValid(dhcpRange) }
    private var canSave: Bool { nameOK && siteOK && rangeOK && (existing != nil || (serverOK && dhcpOK)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(existing.map { "Run a site survey · \($0.name)" } ?? "New organization").font(.headline)
            Form {
                if existing == nil {
                    TextField("Name", text: $name, prompt: Text("Client A, Head office, Lincoln High…"))
                    TextField("Domain name(s)", text: $domains, prompt: Text("example.com, example.org"))
                        .font(.system(.body, design: .monospaced))
                    TextField("Name server", text: $nameServer, prompt: Text("Optional, e.g. the domain controller"))
                        .font(.system(.body, design: .monospaced))
                    if !serverOK { Text("The name server must be an IP address.").font(.caption).foregroundStyle(.red) }
                    TextField("DHCP range", text: $dhcpRange, prompt: Text("Optional, e.g. 10.0.0.100-10.0.0.199"))
                        .font(.system(.body, design: .monospaced))
                    if !dhcpOK { Text("That isn’t a valid range. Use start-end, e.g. 10.0.0.100-199.").font(.caption).foregroundStyle(.red) }
                    LabeledContent("Notes") {
                        TextEditor(text: $notes).frame(height: 50)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                    }
                    Divider()
                }
                if !orgSites.isEmpty {
                    Picker("Scan", selection: $siteID) {
                        ForEach(orgSites) { s in Text("\(s.name) – \(s.range)").tag(Optional(s.id)) }
                        Divider()
                        Text("New scan (this network)").tag(UUID?.none)
                    }
                }
                if siteID == nil {
                    TextField("Scan name", text: $siteName, prompt: Text("Main office"))
                    TextField("Range", text: Binding(get: { range }, set: { range = $0; rangeEdited = true }))
                        .font(.system(.body, design: .monospaced))
                    if !range.isEmpty && !rangeOK { Text("That isn’t a valid IP range.").font(.caption).foregroundStyle(.red) }
                    if let o = existing {
                        Text("Uses \(o.name)’s name server and DHCP range (change them in Organizations › Settings).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Survey") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(SurveyRunner.StepKind.allCases, id: \.self) { k in
                            Toggle(k.label, isOn: Binding(get: { steps.contains(k) }, set: { on in if on { steps.insert(k) } else { steps.remove(k) } }))
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            if steps.contains(.dns) && (existing?.domains.isEmpty ?? Organization.parseDomains(domains).isEmpty) {
                Text("No domain names, so the DNS lookups will be skipped.").font(.caption).foregroundStyle(.secondary)
            }
            if steps.contains(.expiry) && !(existing?.domains.isEmpty ?? Organization.parseDomains(domains).isEmpty) {
                Text("Expiry asks rdap.org for each domain’s registration.").font(.caption).foregroundStyle(.secondary)
            }
            if steps.contains(.connection) {
                Text("Connection Info looks up the public IP address once, at api.ipify.org.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if existing == nil {
                    Button("Save Only") { _ = commit(); dismiss() }.disabled(!canSave)
                }
                Button(existing == nil ? "Save and Run Survey" : "Run Survey") {
                    if let (org, site) = commit() {
                        survey.start(org: org, site: site, steps: steps)
                        openWindow(id: OrgWindows.survey)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || steps.isEmpty || survey.running || model.isScanning)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 520)
        .onAppear(perform: load)
        .onChange(of: dhcpRange) { followOrgNetwork() }
        .onChange(of: nameServer) { followOrgNetwork() }
    }

    /// The scan covers the organization's network (from its DHCP range or name server) unless this Mac is on it.
    private func followOrgNetwork() {
        guard !rangeEdited else { return }
        let o = existing
        range = SurveyRange.suggested(thisNetwork: thisNetwork, dhcpRange: o?.dhcpRange ?? dhcpRange,
                                      nameServer: o?.nameServer ?? nameServer)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let iface = model.interfaces.first { $0.id == model.selectedInterface } ?? model.interfaces.first
        thisNetwork = iface?.suggestedRange ?? model.rangeText
        range = thisNetwork
        followOrgNetwork()
        if let cur = model.currentSite, cur.orgID == orgID, orgID != nil { siteID = cur.id }
        else { siteID = orgSites.first?.id }
        if orgSites.isEmpty { siteID = nil }
        siteName = orgSites.isEmpty ? "Main office" : ""
        if existing?.quietScan == true { steps.remove(.speed) }
    }

    /// Makes the organization and/or site. Returns their ids.
    private func commit() -> (UUID, UUID)? {
        guard canSave else { return nil }
        let org: UUID = orgID ?? {
            var o = Organization(name: orgs.uniqueName(name.trimmingCharacters(in: .whitespaces)),
                                 domains: Organization.parseDomains(domains),
                                 notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
            o.nameServer = nameServer.trimmingCharacters(in: .whitespaces)
            o.dhcpRange = dhcpRange.trimmingCharacters(in: .whitespaces)
            return orgs.add(o)
        }()
        let site: UUID
        if let s = siteID { site = s; model.selectSite(s) }
        else {
            let base = siteName.trimmingCharacters(in: .whitespaces)
            let orgName = orgs.org(org)?.name ?? ""
            // Site names are shared across organizations, so prefix with the organization when needed.
            let taken = Set(model.stored.sites.map { $0.name.lowercased() })
            let n = taken.contains(base.lowercased()) ? "\(orgName) – \(base)" : base
            site = model.createSite(name: model.uniqueSiteName(n), range: range.trimmingCharacters(in: .whitespaces),
                                    nameServer: "", orgID: org)
        }
        return (org, site)
    }
}

// MARK: - The survey itself

@MainActor
final class SurveyRunner: ObservableObject {
    static let shared = SurveyRunner()

    enum StepKind: String, CaseIterable, Hashable {
        case connection, wifi, scan, speed, dns, expiry, trace
        var label: String {
            switch self {
            case .connection: return "Connection Info (DHCP, DNS, gateway, public IP)"
            case .wifi: return "Wi-Fi signal and nearby networks"
            case .scan: return "Network scan"
            case .speed: return "Speed test"
            case .dns: return "DNS lookup (All) for each domain"
            case .expiry: return "Domain registration and HTTPS certificate expiry for each domain"
            case .trace: return "Traceroute to 1.1.1.1"
            }
        }
        var short: String {
            switch self {
            case .connection: return "Connection Info"
            case .wifi: return "Wi-Fi"
            case .scan: return "Network scan"
            case .speed: return "Speed test"
            case .dns: return "DNS lookups"
            case .expiry: return "Expiry"
            case .trace: return "Traceroute to 1.1.1.1"
            }
        }
    }

    enum State: Equatable { case waiting, running, done(String), failed(String), skipped(String) }
    struct Step: Identifiable { let kind: StepKind; var state: State; var id: StepKind { kind } }

    @Published private(set) var steps: [Step] = []
    @Published private(set) var running = false { didSet { Activity.shared.set(activityID, running) } }
    @Published private(set) var orgID: UUID? = nil
    @Published private(set) var siteName = ""
    @Published private(set) var finished = false
    private let activityID = UUID()
    private var stopped = false
    private var task: Task<Void, Never>?

    var progress: Double {
        guard !steps.isEmpty else { return 0 }
        return Double(steps.filter { if case .waiting = $0.state { return false }; if case .running = $0.state { return false }; return true }.count) / Double(steps.count)
    }

    func stop() {
        stopped = true
        if ScanModel.shared.isScanning { ScanModel.shared.toggleScan() }
    }

    func start(org: UUID, site: UUID, steps kinds: Set<StepKind>) {
        guard !running, let s = ScanModel.shared.stored.sites.first(where: { $0.id == site }) else { return }
        orgID = org; siteName = s.name; finished = false; stopped = false
        steps = StepKind.allCases.filter { kinds.contains($0) }.map { Step(kind: $0, state: .waiting) }
        running = true
        let surveyID = UUID()
        task = Task { await run(org: org, site: s, surveyID: surveyID) }
    }

    private func set(_ k: StepKind, _ st: State) {
        if let i = steps.firstIndex(where: { $0.kind == k }) { steps[i].state = st }
    }

    private func run(org: UUID, site: Site, surveyID: UUID) async {
        let model = ScanModel.shared, store = OrgStore.shared
        func file(_ d: SavedDraft?) { if let d { store.save(d, to: org, siteName: site.name, surveyID: surveyID) } }

        for step in steps.map(\.kind) {
            if stopped { set(step, .skipped("stopped")); continue }
            set(step, .running)
            switch step {
            case .connection:
                let iface = model.interfaces.first { $0.id == model.selectedInterface } ?? model.interfaces.first
                guard let iface else { set(step, .failed("no network connection")); continue }
                let info = await offMain { ConnectionInfo.read(iface) }
                let rate = await offMain { CWWiFiClientRate.rate() }
                let pub = await ConnectionInfo.publicIP()
                let rows = info.rows(wifiRate: iface.friendlyName.localizedCaseInsensitiveContains("wi-fi") ? rate : nil, publicIP: pub)
                file(Drafts.connection(rows, interface: "\(iface.friendlyName) (\(iface.bsdName))"))
                set(step, .done(["DHCP \(info.dhcpServer.isEmpty ? "—" : info.dhcpServer)", "gateway \(info.router.isEmpty ? "—" : info.router)",
                                 pub.isEmpty ? "" : "public \(pub)"].filter { !$0.isEmpty }.joined(separator: ", ")))
            case .wifi:
                let snap = await offMain { WiFiMonitor.snapshot() }
                let (nets, problem) = await offMain { WiFiScanner.scanOnce() }
                if snap.isEmpty && nets.isEmpty { set(step, .skipped(problem ?? "Wi-Fi not connected")); continue }
                file(Drafts.wifiNetworks(nets, signal: snap))
                let sig = snap.first { $0.0 == "Signal" }?.1 ?? "not connected"
                let ch = snap.first { $0.0 == "Channel" }?.1.split(separator: "·").first.map { "ch \($0.trimmingCharacters(in: .whitespaces))" } ?? ""
                set(step, .done("\(sig)\(ch.isEmpty ? "" : " on \(ch)"), \(nets.count) networks nearby"))
            case .scan:
                model.selectSite(site.id)
                model.surveyIDForNextScan = surveyID
                let ok = await model.runScan(range: site.range)
                set(step, ok ? .done("\(model.onlineCount) online · \(site.range)") : .failed(stopped ? "stopped" : "didn’t finish"))
            case .speed:
                let r = await offMain { Command.run("/usr/bin/networkQuality", ["-c"], timeout: 90) }
                if let r, let result = SpeedResult.parse(Data(r.out.utf8), site: site.name) {
                    file(Drafts.speed(result))
                    set(step, .done(String(format: "%.0f down / %.0f up Mb/s, %@", result.downMbps, result.upMbps, result.rating)))
                } else {
                    set(step, .failed("the test didn’t finish"))
                }
            case .dns:
                let domains = store.org(org)?.domains ?? []
                guard !domains.isEmpty else { set(step, .skipped("no domain names")); continue }
                var parts: [String] = []
                for d in domains where !stopped {
                    let (groups, _) = await DNSTool.collectAll(d, server: site.effectiveNameServer)
                    let answers = DNSTool.display(groups, follow: false)
                    // Keep where CNAMEs lead too; the saved view shows them with Follow CNAMEs.
                    file(Drafts.dns(target: d, type: "All", server: site.effectiveNameServer, answers: DNSTool.display(groups, follow: true)))
                    parts.append("\(d): \(answers.count)")
                }
                set(step, .done(parts.joined(separator: ", ") + " records"))
            case .expiry:
                let domains = store.org(org)?.domains ?? []
                guard !domains.isEmpty else { set(step, .skipped("no domain names")); continue }
                var parts: [String] = []
                for d in domains where !stopped {
                    let r = await DNSPlus.expiry(d, server: site.effectiveNameServer)
                    let dates = ([r.registration?.expires] + r.certs.map(\.expires)).compactMap { $0 }.sorted()
                    let soonText = DNSPlus.daysLeft(dates.first).map { $0 < 0 ? "something has EXPIRED" : "soonest in \($0) days" } ?? "nothing found"
                    file(SavedDraft(kind: .dns, title: "Domain and certificate expiry · \(d)", summary: soonText,
                                    table: SavedTable(header: ["", "Expires", "Issued by / registrar", "Details"], rows: DNSPlus.expiryRows(r), widths: [32, 24, 26, 60])))
                    parts.append("\(d): \(soonText)")
                }
                set(step, .done(parts.joined(separator: ", ")))
            case .trace:
                let hops = await TraceParser.run("1.1.1.1")
                file(Drafts.traceroute(target: "1.1.1.1", hops: hops))
                set(step, hops.isEmpty ? .failed("no answer") : .done("\(hops.count) hops"))
            }
        }

        let rows = steps.map { s -> [String] in
            switch s.state {
            case .done(let t): return [s.kind.short, "✓ " + t]
            case .failed(let t): return [s.kind.short, "✗ " + t]
            case .skipped(let t): return [s.kind.short, "skipped: " + t]
            default: return [s.kind.short, ""]
            }
        }
        let ok = steps.filter { if case .done = $0.state { return true }; return false }.count
        store.add(SavedItem(orgID: org, kind: .survey, title: "Site survey · \(site.name)",
                            summary: "\(ok) of \(steps.count) checks" + (stopped ? " (stopped)" : ""),
                            table: SavedTable(header: ["Check", "Result"], rows: rows, widths: [22, 90]),
                            siteName: site.name, surveyID: surveyID))
        running = false
        finished = true
    }
}

struct SurveyView: View {
    @ObservedObject private var survey = SurveyRunner.shared
    @ObservedObject private var orgs = OrgStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let orgName = orgs.org(survey.orgID)?.name ?? ""
            Text("Site survey · \(orgName)\(survey.siteName.isEmpty || survey.siteName == orgName ? "" : ", \(survey.siteName)")").font(.headline)
            if survey.steps.isEmpty {
                Text("No survey running. Start one from File › New Organization… or an organization’s Run Survey….")
                    .foregroundStyle(.secondary)
            }
            ForEach(survey.steps) { s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon(s.state).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.kind.short)
                        if let t = detail(s.state) { Text(t).font(.callout).foregroundStyle(.secondary) }
                    }
                }
            }
            if !survey.steps.isEmpty {
                ProgressView(value: survey.progress)
                Text(survey.running ? "Each result is filed under the organization as it finishes." :
                        (survey.finished ? "Done. Everything is saved under the organization." : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if survey.running { Button("Stop") { survey.stop() } }
                Button("Open Organization") { openWindow(id: OrgWindows.list) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(survey.orgID == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 320)
    }

    @ViewBuilder private func icon(_ s: SurveyRunner.State) -> some View {
        switch s {
        case .waiting: Image(systemName: "circle").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    private func detail(_ s: SurveyRunner.State) -> String? {
        switch s {
        case .done(let t), .failed(let t): return t
        case .skipped(let t): return "skipped: \(t)"
        default: return nil
        }
    }
}

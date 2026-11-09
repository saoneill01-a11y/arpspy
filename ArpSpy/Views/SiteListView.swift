import SwiftUI

/// File › Edit Site List…: every saved site in one place. Pick several to delete or clear them;
/// pick one to edit it on the right.
struct SiteListView: View {
    static let windowID = "site-list"

    @ObservedObject var model = ScanModel.shared
    @State private var selection = Set<UUID>()
    @State private var sortOrder = [KeyPathComparator(\Site.name, comparator: .localizedStandard)]
    @State private var confirm: Confirm? = nil
    @Environment(\.openWindow) private var openWindow

    enum Confirm: Identifiable { case delete, clear; var id: Self { self } }

    private var rows: [Site] { model.stored.sites.sorted(using: sortOrder) }
    private var picked: [Site] { rows.filter { selection.contains($0.id) } }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \Site.name, comparator: .localizedStandard) { s in
                        HStack(spacing: 4) {
                            Text(s.name)
                            if s.id == model.siteID { Text("open").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    .width(min: 140, ideal: 200)
                    TableColumn("Organization", value: \Site.orgSort, comparator: .localizedStandard) { s in
                        Text(OrgStore.shared.org(s.orgID)?.name ?? "Standalone").foregroundStyle(.secondary)
                    }
                    .width(min: 90, ideal: 130)
                    TableColumn("Range", value: \Site.range) { s in
                        Text(s.range).font(.system(.body, design: .monospaced))
                    }
                    .width(min: 110, ideal: 140)
                    TableColumn("Name server", value: \Site.nameServer) { s in
                        Text(s.effectiveNameServer).font(.system(.body, design: .monospaced))
                    }
                    .width(min: 90, ideal: 110)
                    TableColumn("DHCP range", value: \Site.dhcpRange) { s in
                        Text(s.effectiveDHCPRange).font(.system(.body, design: .monospaced))
                    }
                    .width(min: 90, ideal: 150)
                    TableColumn("Devices", value: \Site.deviceCount) { s in
                        Text("\(s.known.count)").monospacedDigit()
                    }
                    .width(min: 50, ideal: 60)
                    TableColumn("Last scan", value: \Site.lastScanSort) { s in
                        Text(s.lastScan.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                            .foregroundStyle(s.lastScan == nil ? .secondary : .primary)
                    }
                    .width(min: 110, ideal: 140)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count == 1, let id = ids.first {
                        Button("Open in Main Window") { open(id) }
                        Button("Duplicate") { if let n = model.duplicateSite(id) { selection = [n] } }
                        Divider()
                    }
                    if !ids.isEmpty {
                        Button("Clear Devices…") { selection = ids; confirm = .clear }
                        Button(ids.count == 1 ? "Delete Scan…" : "Delete \(ids.count) Scans…") { selection = ids; confirm = .delete }
                    }
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first { open(id) }
                }
                .onDeleteCommand { if !selection.isEmpty { confirm = .delete } }
                .overlay {
                    if model.stored.sites.isEmpty {
                        Text("No saved scans yet. Scan a network, then choose Save to Organization… or Save Standalone… in the bar that appears.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }

                Divider()
                HStack(spacing: 8) {
                    Button { selection = [model.newSite()] } label: { Label("New Scan", systemImage: "plus") }
                    Button("Duplicate") { if let id = selection.first, let n = model.duplicateSite(id) { selection = [n] } }
                        .disabled(selection.count != 1)
                    Button(selection.count > 1 ? "Delete \(selection.count) Scans…" : "Delete…", role: .destructive) { confirm = .delete }
                        .disabled(selection.isEmpty)
                    Spacer()
                    Button("Clear Devices…") { confirm = .clear }
                        .disabled(selection.isEmpty)
                        .help("Forget the saved devices (red rows) and last scan, but keep the saved scan")
                    Button("Open in Main Window") { if let id = selection.first { open(id) } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selection.count != 1 || model.isScanning)
                }
                .padding(10)
            }
            .frame(minWidth: 600, idealWidth: 700, maxWidth: .infinity)
            .layoutPriority(1)

            SiteEditor(model: model, selection: selection)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 340, maxHeight: .infinity)
                .onChange(of: selection) { old, _ in for id in old { model.fixDuplicateName(id) } }
        }
        .frame(minWidth: 880, minHeight: 360)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                            presenting: confirm) { kind in
            switch kind {
            case .delete:
                Button(picked.count == 1 ? "Delete Scan" : "Delete \(picked.count) Scans", role: .destructive) {
                    model.deleteSites(selection); selection = []
                }
            case .clear:
                Button("Clear Devices", role: .destructive) { model.clearSiteDevices(selection) }
            }
        } message: { kind in
            switch kind {
            case .delete: Text("Their saved devices and last scans are removed. This can’t be undone. Past scans in History stay.")
            case .clear: Text("The saved scans stay, but their saved devices and last results are forgotten. This can’t be undone.")
            }
        }
    }

    private var confirmTitle: String {
        let names = picked.prefix(3).map { "“\($0.name)”" }.joined(separator: ", ") + (picked.count > 3 ? "…" : "")
        switch confirm {
        case .delete: return "Delete \(names)?"
        case .clear: return "Clear the saved devices of \(names)?"
        case nil: return ""
        }
    }

    private func open(_ id: UUID) {
        guard !model.isScanning else { return }
        model.selectSite(id)
        openWindow(id: "main")
    }
}

extension Site {
    var deviceCount: Int { known.count }
    var lastScanSort: Date { lastScan?.date ?? .distantPast }
    /// Organization name for sorting; standalone scans sort last.
    var orgSort: String {
        MainActor.assumeIsolated { OrgStore.shared.org(orgID)?.name } ?? "\u{10FFFF}Standalone"
    }
}

/// The right side: edit the one selected site. Changes save as you type.
private struct SiteEditor: View {
    @ObservedObject var model: ScanModel
    let selection: Set<UUID>

    var body: some View {
        if selection.count == 1, let id = selection.first, let site = model.stored.sites.first(where: { $0.id == id }) {
            Form {
                TextField("Name", text: binding(id, \.name, site))
                    .onSubmit { model.fixDuplicateName(id) }
                if model.stored.sites.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(site.name) == .orderedSame }) {
                    Text("Another saved scan has this name; a number is added when you move on.").font(.caption).foregroundStyle(.orange)
                }
                Picker("Organization", selection: Binding(get: { site.orgID }, set: { v in model.editSite(id) { $0.orgID = v } })) {
                    Text("Standalone").tag(UUID?.none)
                    Divider()
                    ForEach(OrgStore.shared.sortedOrgs) { o in Text(o.name).tag(Optional(o.id)) }
                }
                TextField("Range", text: binding(id, \.range, site), prompt: Text("10.0.0.0/24"))
                    .font(.system(.body, design: .monospaced))
                if (try? IPRangeParser.parse(site.range)) == nil {
                    Text("That isn’t a valid IP range.").font(.caption).foregroundStyle(.red)
                }
                if let org = site.organization {
                    LabeledContent("Name server") {
                        Text(site.effectiveNameServer.isEmpty ? "This Mac’s DNS" : site.effectiveNameServer)
                            .font(.system(.body, design: .monospaced))
                    }
                    LabeledContent("DHCP range") {
                        Text(site.effectiveDHCPRange.isEmpty ? "Not set" : site.effectiveDHCPRange)
                            .font(.system(.body, design: .monospaced))
                    }
                    LabeledContent("SNMP community") {
                        Text(site.effectiveSNMPCommunity).font(.system(.body, design: .monospaced))
                    }
                    Text("From \(org.name). Change them in Organizations › Settings.").font(.caption).foregroundStyle(.secondary)
                } else {
                TextField("Name server", text: binding(id, \.nameServer, site), prompt: Text("Optional"))
                    .font(.system(.body, design: .monospaced))
                if !site.nameServer.trimmingCharacters(in: .whitespaces).isEmpty && IPv4(site.nameServer.trimmingCharacters(in: .whitespaces)) == nil {
                    Text("The name server must be an IP address.").font(.caption).foregroundStyle(.red)
                }
                TextField("DHCP range", text: binding(id, \.dhcpRange, site), prompt: Text("Optional, e.g. 10.0.0.100-10.0.0.199"))
                    .font(.system(.body, design: .monospaced))
                if !DHCPRange.isValid(site.dhcpRange) {
                    Text("That isn’t a valid range. Use start-end, e.g. 10.0.0.100-199.").font(.caption).foregroundStyle(.red)
                }
                TextField("SNMP community", text: binding(id, \.snmpCommunity, site), prompt: Text("public"))
                    .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Notes") {
                    TextEditor(text: binding(id, \.notes, site))
                        .font(.body)
                        .frame(minHeight: 80, maxHeight: 140)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                }
                LabeledContent("Saved") {
                    Text("\(site.known.count) devices · last scan \(site.lastScan.map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "never")")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        } else {
            Text(selection.isEmpty ? "Pick a saved scan to edit it." : "\(selection.count) scans selected.\nPick one to edit it.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func binding(_ id: UUID, _ key: WritableKeyPath<Site, String>, _ site: Site) -> Binding<String> {
        Binding(get: { model.stored.sites.first(where: { $0.id == id })?[keyPath: key] ?? "" },
                set: { v in model.editSite(id) { $0[keyPath: key] = v } })
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// File › Export Scans…: tick saved scans (grouped by organization) and save them to one .arpradar file,
/// which ARPradar for Mac or Windows opens with File › Import Scans….
struct ExportScansView: View {
    @ObservedObject var model: ScanModel
    @ObservedObject private var orgs = OrgStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<UUID> = []
    @State private var problem: String? = nil

    private var groups: [(title: String, sites: [Site])] {
        var out: [(String, [Site])] = orgs.sortedOrgs.map { o in (o.name, model.sites(in: o.id)) }.filter { !$0.1.isEmpty }
        let loose = model.stored.sites.filter { $0.orgID == nil || orgs.org($0.orgID) == nil }
        if !loose.isEmpty { out.append(("Standalone", loose)) }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Scans").font(.headline)
            Text("Saves the ticked scans to one .arpradar file. Open it with File › Import Scans… in ARPradar on another Mac or PC.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                Toggle("All saved scans (\(model.stored.sites.count))", isOn: Binding(
                    get: { picked.count == model.stored.sites.count && !picked.isEmpty },
                    set: { picked = $0 ? Set(model.stored.sites.map(\.id)) : [] }))
                    .fontWeight(.semibold)
                ForEach(groups, id: \.title) { g in
                    Section(g.title) {
                        ForEach(g.sites) { s in
                            Toggle(isOn: Binding(get: { picked.contains(s.id) },
                                                 set: { if $0 { picked.insert(s.id) } else { picked.remove(s.id) } })) {
                                HStack {
                                    Text(s.name)
                                    Spacer()
                                    Text(s.range).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                                    Text("\(s.known.count) devices").foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                                }
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 260)
            Text("Each scan brings its settings, remembered devices (for offline rows and NEW badges) and last scan. Favorites, comments and History stay on this Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem { Text(problem).foregroundStyle(.red).font(.callout) }
            HStack {
                Text("\(picked.count) of \(model.stored.sites.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") { export() }.keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { picked = Set(model.stored.sites.map(\.id)) }
    }

    private func export() {
        let sites = model.stored.sites.filter { picked.contains($0.id) }
        let orgNames = Set(sites.compactMap { orgs.org($0.orgID)?.name })
        let base = (sites.count == 1 ? sites[0].name : orgNames.count == 1 ? orgNames.first! : "ARPradar") + " scans"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "arpradar") ?? .json]
        panel.nameFieldStringValue = String(base.map { "/:\\".contains($0) ? "-" : $0 }) + ".arpradar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let data = try ScanTransfer.export(sites, organization: { orgs.org($0)?.name }, appVersion: version)
            try data.write(to: url, options: .atomic)
            dismiss()
        } catch {
            problem = "Couldn’t save: \(error.localizedDescription)"
        }
    }
}

/// File › Import Scans… after picking a file: tick which scans to bring in; for ones that already exist,
/// Replace mine or Keep both.
struct ImportScansView: View {
    @ObservedObject var model: ScanModel
    let file: ScanTransfer.File
    let fileName: String
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []

    struct Row: Identifiable {
        let id: Int
        let scan: ScanTransfer.Scan
        var on = true
        var action: ScanModel.ImportAction
    }

    private var subtitle: String {
        var parts = [fileName]
        if let app = file.app { parts.append("from \(app)") }
        if let d = ScanTransfer.date(file.exported) { parts.append("exported \(d.formatted(date: .abbreviated, time: .shortened))") }
        return parts.joined(separator: " · ")
    }

    private var clashes: [String] { rows.filter { $0.action != .new }.map { "“\($0.scan.name)”" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Scans").font(.headline)
            Text(subtitle).foregroundStyle(.secondary)
            Table($rows) {
                TableColumn("") { $r in Toggle("", isOn: $r.on).labelsHidden() }.width(24)
                TableColumn("Saved scan") { $r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.scan.name)
                        Text(r.scan.organization.flatMap { $0.isEmpty ? nil : $0 } ?? "Standalone").font(.caption).foregroundStyle(.secondary)
                    }
                }
                TableColumn("Range") { $r in Text(r.scan.range).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary) }
                    .width(min: 100, ideal: 130)
                TableColumn("Devices") { $r in Text("\(r.scan.devices?.count ?? 0)").monospacedDigit() }.width(60)
                TableColumn("Here already?") { $r in
                    if r.action == .new {
                        Text("New").foregroundStyle(.green)
                    } else {
                        Picker("", selection: $r.action) {
                            Text("Replace mine").tag(ScanModel.ImportAction.replace)
                            Text("Keep both").tag(ScanModel.ImportAction.keepBoth)
                        }
                        .labelsHidden()
                    }
                }
                .width(min: 130, ideal: 150)
            }
            .frame(minHeight: 240)
            if !clashes.isEmpty {
                Text("\(clashes.joined(separator: ", ")) already \(clashes.count == 1 ? "exists" : "exist") here. Keep both (the default) adds the imported one with a number after its name; Replace mine swaps it in over yours (its devices and last scan), which can’t be undone. Organizations that don’t exist yet are created.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("\(rows.filter(\.on).count) of \(rows.count) selected").foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                let on = rows.filter(\.on), replacing = on.filter { $0.action == .replace }.count
                Button(replacing > 0 ? "Import \(on.count) (\(replacing) replace\(replacing == 1 ? "s" : "") mine)" : "Import \(on.count)") {
                    model.importScans(on.map { ($0.scan, $0.action) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!rows.contains(where: \.on))
            }
        }
        .padding(20)
        .frame(width: 680)
        .onAppear {
            rows = file.scans.enumerated().map { i, s in
                // Keep both is the default for a clash: nothing of yours is overwritten unless you choose it.
                Row(id: i, scan: s, action: model.existingSite(named: s.name) == nil ? .new : .keepBoth)
            }
        }
    }
}

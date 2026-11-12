import SwiftUI
import UIKit

/// One scan's devices: search, sort, share as CSV, tap for details.
struct ResultsView: View {
    let scan: SavedScan
    enum Sort: String, CaseIterable, Identifiable {
        case ip = "IP address", name = "Name", vendor = "Manufacturer"
        var id: String { rawValue }
    }
    @AppStorage("results.sort") private var sort = Sort.ip
    @State private var query = ""

    private var rows: [SensorRow] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let found = words.isEmpty ? scan.rows : scan.rows.filter { r in
            let text = [r.ip.description, r.name, r.mac, r.vendor, r.describe, r.ports.map(String.init).joined(separator: " ")]
                .joined(separator: " ").lowercased()
            return words.allSatisfy(text.contains)
        }
        switch sort {
        case .ip: return found.sorted { $0.ip < $1.ip }
        case .name: return found.sorted { ($0.displayName.isEmpty ? "\u{10FFFF}" : $0.displayName.lowercased(), $0.ip) < ($1.displayName.isEmpty ? "\u{10FFFF}" : $1.displayName.lowercased(), $1.ip) }
        case .vendor: return found.sorted { ($0.vendor.isEmpty ? "\u{10FFFF}" : $0.vendor.lowercased(), $0.ip) < ($1.vendor.isEmpty ? "\u{10FFFF}" : $1.vendor.lowercased(), $1.ip) }
        }
    }

    var body: some View {
        let shown = rows
        List {
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(scan.rows.count) devices in \(String(format: "%.1f", scan.seconds)) s\(scan.cancelled ? " (stopped early)" : "")")
                        .font(.headline)
                    Text([scan.range, scan.sensor, scan.date.formatted(date: .abbreviated, time: .shortened)].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(shown) { r in
                    NavigationLink { DeviceView(row: r) } label: { DeviceRowLabel(row: r) }
                        .contextMenu {
                            Button { UIPasteboard.general.string = r.ip.description } label: { Label("Copy IP Address", systemImage: "doc.on.doc") }
                            if !r.mac.isEmpty {
                                Button { UIPasteboard.general.string = r.mac } label: { Label("Copy MAC Address", systemImage: "doc.on.doc") }
                            }
                        }
                }
            } footer: {
                if !query.isEmpty { Text("\(shown.count) of \(scan.rows.count) match “\(query)”") }
            }
        }
        .searchable(text: $query, prompt: "IP, name, MAC, maker, port")
        .navigationTitle(scan.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Sort")
                ShareLink(item: scan.csvFile()) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityLabel("Share as CSV")
            }
        }
    }
}

struct DeviceRowLabel: View {
    let row: SensorRow
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.ip.description).font(.body.monospacedDigit().weight(.semibold))
                if !row.displayName.isEmpty { Text(row.displayName).lineLimit(1) }
                if !row.vendor.isEmpty && row.vendor != row.displayName {
                    Text(row.vendor).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if !row.ports.isEmpty {
                Text(row.ports.prefix(3).map { Ports.label($0) }.joined(separator: " ") + (row.ports.count > 3 ? " +\(row.ports.count - 3)" : ""))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Everything the sensor learned about one device.
struct DeviceView: View {
    let row: SensorRow

    var body: some View {
        List {
            Section("Device") {
                copyable("IP address", row.ip.description)
                if !row.name.isEmpty { copyable("Name", row.name) }
                if !row.mac.isEmpty { copyable("MAC address", row.mac) }
                if !row.vendor.isEmpty { copyable("Manufacturer", row.vendor) }
                if let ms = row.ms { LabeledContent("Response", value: ms < 1 ? "under 1 ms" : String(format: "%.0f ms", ms)) }
            }
            if !row.describe.isEmpty {
                Section("What it says it is") {
                    if !row.ubnt.isEmpty { copyable("UniFi model", row.ubnt) }
                    if !row.upnp.isEmpty { copyable("UPnP", row.upnp) }
                    if !row.snmpName.isEmpty { copyable("SNMP name", row.snmpName) }
                    if !row.snmp.isEmpty { copyable("SNMP description", row.snmp) }
                    if !row.web.isEmpty { copyable("Web page", row.web) }
                }
            }
            Section("Open ports") {
                if row.ports.isEmpty { Text("None found").foregroundStyle(.secondary) }
                ForEach(row.ports, id: \.self) { p in
                    LabeledContent(String(p), value: Ports.service(p).isEmpty ? Ports.label(p) : Ports.service(p))
                }
            }
        }
        .navigationTitle(row.displayName.isEmpty ? row.ip.description : row.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func copyable(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }
            .contextMenu { Button { UIPasteboard.general.string = value } label: { Label("Copy", systemImage: "doc.on.doc") } }
    }
}

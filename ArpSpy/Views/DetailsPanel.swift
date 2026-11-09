import SwiftUI

/// The panel on the right (⌘I): everything ArpSpy knows about the selected device.
struct DetailsPanel: View {
    @ObservedObject var model: ScanModel

    var body: some View {
        Group {
            if let d = model.selectedDevice {
                ScrollView { DeviceDetails(model: model, d: d).padding(14) }
                    .onAppear { model.loadBanners(for: d); model.loadShares(for: d) }
                    .onChange(of: d.id) {
                        if let d = model.selectedDevice { model.loadBanners(for: d); model.loadShares(for: d) }
                    }
            } else {
                Text(model.selection.count > 1 ? "\(model.selection.count) devices selected." : "Select a device to see its details.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct DeviceDetails: View {
    @ObservedObject var model: ScanModel
    let d: Device
    @Environment(\.theme) private var theme
    @AppStorage(TextSize.storageKey) private var textSize = TextSize.medium
    @AppStorage(AppMode.key) private var advanced = true

    private static let nameSources = ["NetBIOS", "Bonjour", "DNS", "UPnP", "SNMP", "UniFi"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(d.name.isEmpty ? "(no name)" : d.name).font(.title3).bold().textSelection(.enabled)
                if d.isNew { NewBadge() }
            }
            HStack(spacing: 5) {
                Circle().fill(d.isOnline ? theme.online : theme.offline).frame(width: 8, height: 8)
                Text(subtitle).foregroundStyle(.secondary)
            }
            .font(.system(size: textSize.points - 1))
            if advanced, let r = model.dhcpRange {
                let inside = r.contains(d.ip)
                Text(inside ? "Inside DHCP range" : "Outside DHCP range (static or reserved)")
                    .font(.caption)
                    .foregroundStyle(inside ? Color.secondary : Color.dhcpOutside)
                    .padding(.horizontal, inside ? 0 : 5).padding(.vertical, 1)
                    .background(inside ? Color.clear : Color.dhcpOutside.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            }

            section(nil, rows: [
                ("Type", d.kind?.label ?? ""), ("MAC", d.mac), ("Maker", d.vendor),
                ("First seen", d.firstSeen.formatted(date: .abbreviated, time: .shortened)),
                ("Last seen", d.isOnline ? "This scan" : d.lastSeen.formatted(date: .abbreviated, time: .shortened)),
                ("Comment", model.comments[d.commentKey] ?? ""),
            ])
            if let l = d.switchLink {
                section("Plugged into", rows: l.wireless
                        ? [("Access point", l.device), ("Network", l.ssid), ("Signal", l.signal.map { "\($0) dBm" } ?? "")]
                        : [("Switch", l.device), ("Port", l.port.map(String.init) ?? ""),
                           ("Speed", l.mbps.flatMap { $0 > 0 ? MapNode.speed($0) : nil } ?? ""),
                           ("Note", l.viaUnmanaged ? "Behind an unmanaged switch on that port" : "")])
            }
            if advanced, !d.ipv6.isEmpty {
                section("IPv6", rows: d.ipv6.map { (IPv6Neighbors.kind($0), $0) }, monospaced: true)
            }
            SharesSection(model: model, d: d)
            if advanced {
            section("Names", rows: Self.nameSources.map { ($0, d.names[$0] ?? "") })
            section("What it is", rows: [
                ("Web page", d.webTitle), ("UPnP", d.upnp),
                ("SNMP name", d.snmpName), ("SNMP", d.snmpDescr), ("Location", d.snmpLocation),
                ("Ubiquiti", d.ubntModel), ("Firmware", d.ubntFirmware),
            ], empty: "Nothing answered (web page, UPnP, SNMP, Ubiquiti).")
            section("Open ports", rows: d.openPorts.map { p in
                let service = PortScanJob.service(p).isEmpty ? "unknown service" : PortScanJob.service(p)
                return (String(p), [service, d.banners[p]].compactMap { $0 }.joined(separator: " · "))
            }, empty: "None of the usual ports are open.")
            } else {
                section("What it is", rows: [("Web page", d.webTitle), ("Model", d.snmpDescr.isEmpty ? d.details : d.snmpDescr)])
            }

            Divider().padding(.top, 8)
            Text("ACTIONS").font(.caption2).foregroundStyle(.secondary).padding(.bottom, 1)
            ActionRow(model: model, d: d, copyText: copyText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        var parts = [d.ip.description, d.isOnline ? "online" : "offline"]
        if let ms = d.responseMs, d.isOnline { parts.append(String(format: "%.0f ms", ms)) }
        return parts.joined(separator: " · ")
    }

    private func visible(_ rows: [(String, String)]) -> [(String, String)] { rows.filter { !$0.1.isEmpty } }

    @ViewBuilder
    private func section(_ title: String?, rows: [(String, String)], empty: String? = nil, monospaced: Bool = false) -> some View {
        let shown = visible(rows)
        if !shown.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let title {
                    Divider().padding(.top, 8)
                    Text(title == "IPv6" ? "IPv6" : title.uppercased()).font(.caption2).foregroundStyle(.secondary).padding(.bottom, 1)
                }
                if shown.isEmpty, let empty {
                    Text(empty).font(.system(size: textSize.points - 1)).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(row.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                Text(row.1).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    .font(.system(size: textSize.points - 1, design: monospaced ? .monospaced : .default))
                            }
                        }
                    }
                    .font(.system(size: textSize.points - 1))
                }
            }
            .padding(.top, title == nil ? 8 : 0)
        }
    }

    private var copyText: String {
        var lines = ["\(d.name.isEmpty ? "(no name)" : d.name) – \(subtitle)"]
        let all: [(String, String)] = [("Type", d.kind?.label ?? ""), ("MAC", d.mac), ("Maker", d.vendor)]
            + Self.nameSources.map { ("\($0) name", d.names[$0] ?? "") }
            + [("Web page", d.webTitle), ("UPnP", d.upnp), ("SNMP name", d.snmpName), ("SNMP", d.snmpDescr),
               ("Location", d.snmpLocation), ("Ubiquiti", d.ubntModel), ("Firmware", d.ubntFirmware)]
            + d.openPorts.map { ("Port \($0)", [Ports.service($0), d.banners[$0] ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")) }
        if let l = d.switchLink { lines.append("Plugged into: " + SwitchLinkText.help(l)) }
        lines += d.ipv6.map { "IPv6 (\(IPv6Neighbors.kind($0))): \($0)" }
        if let s = model.shares[d.id] {
            lines += s.smb.map { "Share: \($0.name)\($0.comment.isEmpty ? "" : " – \($0.comment)")" }
            lines += s.nfs.map { "NFS export: \($0)" }
        }
        lines += all.filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }
        return lines.joined(separator: "\n")
    }
}

/// Buttons for what you can do with the device (the same things as the right-click menu), wrapped to the panel's width.
private struct ActionRow: View {
    @ObservedObject var model: ScanModel
    let d: Device
    let copyText: String
    @AppStorage(AppMode.key) private var advanced = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let web = d.openPorts.contains { [80, 443, 8080, 8443].contains($0) }
        let shares = d.openPorts.contains { [139, 445, 2049].contains($0) }
        FlowLayout(spacing: 6) {
            Button("Open in Browser") { model.perform(DeviceActions.openWeb, on: d) }
                .disabled(!d.isOnline).help(web ? "Open its web page" : "No web port was seen open; tries http:// anyway")
            Button("Shares") { model.perform(DeviceActions.openShares, on: d) }
                .disabled(!d.isOnline).help(shares ? "Open its shared folders in Finder" : "No file-sharing port was seen open")
            if advanced {
                Button("SSH") { model.perform(DeviceActions.ssh, on: d) }.disabled(!d.isOnline).help("SSH in Terminal")
                Button("RDP") { model.perform(DeviceActions.remoteDesktop, on: d) }.disabled(!d.isOnline).help("Remote Desktop (opens Windows App)")
                Button("Scan Ports…") { model.portScanTarget = d }.disabled(!d.isOnline)
            }
            Button("Ping") { openWindow(id: ToolWindow.ping, value: d.ip.description) }
            Button("Wake") { model.wake([d]) }.disabled(d.mac.isEmpty).help("Wake on LAN")
            Button("Copy IP") { Exporter.copyToClipboard(d.ip.description); model.flashStatus("Copied \(d.ip)") }
            Button("Copy MAC") { Exporter.copyToClipboard(d.mac); model.flashStatus("Copied \(d.mac)") }.disabled(d.mac.isEmpty)
            Button("Copy All") { Exporter.copyToClipboard(copyText); model.flashStatus("Copied the details of \(d.name.isEmpty ? d.ip.description : d.name)") }
        }
        .controlSize(.small)
        .padding(.top, 4)
    }
}

/// Lays children out left to right, wrapping to the next line when the width runs out.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > bounds.width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Shared folders: SMB shares a guest can see (each with an Open button) and NFS exports.
private struct SharesSection: View {
    @ObservedObject var model: ScanModel
    let d: Device

    private var hasSharePorts: Bool { !Set(d.openPorts).isDisjoint(with: [139, 445, 2049]) }

    var body: some View {
        if d.isOnline && hasSharePorts {
            VStack(alignment: .leading, spacing: 4) {
                Divider().padding(.top, 8)
                Text("SHARES").font(.caption2).foregroundStyle(.secondary).padding(.bottom, 1)
                if let info = model.shares[d.id] {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                        ForEach(info.smb, id: \.name) { s in
                            GridRow {
                                Text(s.name).gridColumnAlignment(.trailing).textSelection(.enabled)
                                HStack(spacing: 4) {
                                    Button("Open") { model.openShare(s.name, on: d) }
                                        .buttonStyle(.link)
                                        .help("Open smb://\(d.ip)/\(s.name) in Finder")
                                    if !s.comment.isEmpty { Text("· \(s.comment)").foregroundStyle(.secondary) }
                                }
                            }
                        }
                        ForEach(info.nfs, id: \.self) { path in
                            GridRow {
                                Text("NFS").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                Text(path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                    .font(.callout)
                    if let problem = info.smbProblem, info.smb.isEmpty {
                        HStack(spacing: 4) {
                            Text(problem).foregroundStyle(.secondary)
                            Button("Open in Finder") { model.perform(DeviceActions.openShares, on: d) }.buttonStyle(.link)
                        }
                        .font(.callout)
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Listing shares…").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

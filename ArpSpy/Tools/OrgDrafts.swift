import Foundation
import CoreWLAN

/// Turning each tool's results into a table to save for an organization, and one-shot versions of the
/// tools for the site survey.
enum Drafts {
    static func dns(target: String, type: String, server: String, answers: [DNSAnswer]) -> SavedDraft? {
        guard !answers.isEmpty else { return nil }
        let rows = answers.map { a -> [String] in
            let name = a.depth == 0 ? a.name : String(repeating: "  ", count: a.depth - 1) + "↳ " + a.name
            return [name, a.type, String(a.ttl), a.data]
        }
        let own = answers.filter { $0.depth == 0 }.count
        return SavedDraft(kind: .dns, title: "DNS lookup · \(target) (\(type))",
                          summary: "\(own) records" + (server.isEmpty ? "" : " from \(server)"),
                          table: SavedTable(header: ["Name", "Type", "TTL", "Answer"], rows: rows, widths: [48, 8, 8, 70], numberColumns: [2]))
    }

    static func ports(device: Device, results: [(port: UInt16, service: String, banner: String)], checked: Int) -> SavedDraft? {
        guard checked > 0 else { return nil }
        let who = device.name.isEmpty ? device.ip.description : "\(device.name) (\(device.ip))"
        return SavedDraft(kind: .portScan, title: "Scan Ports · \(who)", summary: "\(results.count) open of \(checked) checked",
                          table: SavedTable(header: ["Port", "Service", "What answers"],
                                            rows: results.map { [String($0.port), $0.service, $0.banner] },
                                            widths: [8, 28, 50], numberColumns: [0]))
    }

    static func traceroute(target: String, hops: [Hop]) -> SavedDraft? {
        guard !hops.isEmpty else { return nil }
        let rows = hops.map { h in [String(h.number), h.address, h.address == "*" ? "no answer" : h.name, h.ms.map { String(format: "%.1f", $0) } ?? ""] }
        let last = hops.last.flatMap { $0.ms }.map { String(format: ", %.0f ms to the end", $0) } ?? ""
        return SavedDraft(kind: .traceroute, title: "Traceroute · \(target)", summary: "\(hops.count) hops\(last)",
                          table: SavedTable(header: ["Hop", "Address", "Name", "Time (ms)"], rows: rows, widths: [6, 18, 44, 10], numberColumns: [0]))
    }

    static func ping(targets: [String], stats: (String) -> PingJob.Stats) -> SavedDraft? {
        let list = targets.map { ($0, stats($0)) }.filter { $0.1.sent > 0 }
        guard !list.isEmpty else { return nil }
        func f(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "" }
        let rows = list.map { t, s in [t, String(s.sent), String(s.lost), f(s.avg), f(s.min), f(s.max), f(s.jitter)] }
        let lost = list.reduce(0) { $0 + $1.1.lost }, sent = list.reduce(0) { $0 + $1.1.sent }
        return SavedDraft(kind: .ping, title: "Ping · \(targets.joined(separator: ", "))",
                          summary: "\(sent) sent, \(lost) lost, avg \(list.compactMap { $0.1.avg }.map { String(format: "%.0f ms", $0) }.joined(separator: " / "))",
                          table: SavedTable(header: ["Target", "Sent", "Lost", "Avg ms", "Min ms", "Max ms", "Jitter ms"], rows: rows,
                                            widths: [24, 7, 7, 9, 9, 9, 10], numberColumns: [1, 2]))
    }

    static func speed(_ r: SpeedResult) -> SavedDraft {
        SavedDraft(kind: .speedTest, title: "Speed test" + (r.site.isEmpty ? "" : " · \(r.site)"),
                   summary: String(format: "%.0f down / %.0f up Mb/s · %@ (%d RPM)", r.downMbps, r.upMbps, r.rating, Int(r.rpm)),
                   table: SavedTable(header: ["Measure", "Value"], rows: [
                       ["Download", String(format: "%.1f Mb/s", r.downMbps)], ["Upload", String(format: "%.1f Mb/s", r.upMbps)],
                       ["Responsiveness", "\(r.rating) · \(Int(r.rpm)) RPM"], ["Idle latency", String(format: "%.0f ms", r.idleMs)],
                       ["When", r.date.formatted(date: .abbreviated, time: .shortened)],
                   ], widths: [20, 40]))
    }

    static func wifiNetworks(_ list: [NearbyNetwork], signal: [(String, String)]) -> SavedDraft? {
        guard !list.isEmpty || !signal.isEmpty else { return nil }
        let rows = list.sorted { ($0.band, -$0.rssi) < ($1.band, -$1.rssi) }.map { n in
            [n.ssid.isEmpty ? "(name hidden)" : n.ssid, String(n.rssi), String(n.channel), n.band, String(n.widthMHz), n.security, n.bssid, n.isMine ? "yes" : ""]
        }
        let mine = signal.first { $0.0 == "Signal" }?.1 ?? ""
        return SavedDraft(kind: .wifi, title: "Wi-Fi survey",
                          summary: "\(list.count) networks nearby" + (mine.isEmpty ? "" : " · this Mac \(mine)"),
                          table: SavedTable(header: ["Network", "Signal dBm", "Channel", "Band", "Width MHz", "Security", "Access point", "Connected"],
                                            rows: signal.map { ["This Mac: \($0.0)", $0.1, "", "", "", "", "", ""] } + rows,
                                            widths: [28, 11, 9, 9, 10, 22, 20, 10], numberColumns: [1, 2, 4]))
    }

    static func wifiSignal(_ rows: [(String, String)]) -> SavedDraft? {
        guard !rows.isEmpty else { return nil }
        let sig = rows.first { $0.0 == "Signal" }?.1 ?? ""
        return SavedDraft(kind: .wifiSignal, title: "Wi-Fi signal", summary: sig,
                          table: SavedTable(header: ["", "Value"], rows: rows.map { [$0.0, $0.1] }, widths: [18, 60]))
    }

    static func connection(_ rows: [(String, String)], interface: String) -> SavedDraft? {
        guard !rows.isEmpty else { return nil }
        func v(_ k: String) -> String { rows.first { $0.0 == k }?.1 ?? "" }
        return SavedDraft(kind: .connection, title: "Connection info · \(interface)",
                          summary: ["IP \(v("IP address"))", v("DHCP server").isEmpty ? "" : "DHCP \(v("DHCP server"))",
                                    v("Public IP").isEmpty ? "" : "public \(v("Public IP"))"].filter { !$0.isEmpty }.joined(separator: " · "),
                          table: SavedTable(header: ["", "Value"], rows: rows.filter { !$0.1.isEmpty }.map { [$0.0, $0.1] }, widths: [18, 70]))
    }
}

// MARK: - One-shot versions of the tools (for the site survey)

extension DNSTool {
    /// Every "All" question for a name (an IP's PTR name first), answered in parallel, in the order asked.
    /// Names that aren't valid host names (the target, a PTR answer, a name from the certificate logs) are skipped,
    /// so nothing odd ever reaches dig. At most 16 digs run at once.
    static func collectAll(_ target: String, server: String, extraNames: [String] = []) async -> (groups: [DNSGroup], lookups: Int) {
        var found: [DNSGroup] = []
        var forward = target
        guard HostName.isValid(target) else { return ([], 0) }
        if let ip = IPv4(target) {
            let r = await offMain { Command.run("/usr/bin/dig", DNSTool.arguments(name: target, type: "PTR", server: server), timeout: 6) }
            let ptr = DNSTool.parse(r?.out ?? "").answers
            found.append(DNSGroup(asked: DNSTool.reverseName(ip), answers: ptr))
            forward = ptr.first(where: { $0.type == "PTR" })?.data ?? ""
            if !HostName.isValid(forward) { forward = "" }
        }
        var lookups = found.count
        if !forward.isEmpty {
            let queries = (DNSTool.allQueries(forward) + extraNames.map { (name: $0, type: "A") }).filter { HostName.isValid($0.name) }
            lookups += queries.count
            found += await DNSPlus.inParallel(queries.map { [$0.name, $0.type] }, limit: 16) { q in
                let r = await offMain { Command.run("/usr/bin/dig", DNSTool.arguments(name: q[0], type: q[1], server: server), timeout: 6) }
                return DNSGroup(asked: q[0], answers: DNSTool.parse(r?.out ?? "").answers)
            }
        }
        return (found, lookups)
    }

    /// The rows the DNS window shows for these questions.
    static func display(_ groups: [DNSGroup], follow: Bool) -> [DNSAnswer] {
        var seen = Set<String>()
        return groups.enumerated().flatMap { i, g in
            DNSTool.arrange(g.answers, asked: g.asked, follow: follow)
                .filter { seen.insert("\($0.depth == 0 ? "" : "\(i)")|\($0.depth)|\($0.name.lowercased())|\($0.type)|\($0.data)").inserted }
        }
    }
}

extension TraceParser {
    /// Runs traceroute to the end and returns the hops. Addresses only (-n: no name lookups, which the survey
    /// doesn't need and which make it slow); if it runs out of time, the hops found so far are kept.
    static func run(_ target: String) async -> [Hop] {
        guard HostName.isValid(target) else { return [] }
        let r = await offMain { Command.run("/usr/sbin/traceroute", ["-n", "-w", "2", "-q", "1", "-m", "30", target], timeout: 90, partialOnTimeout: true) }
        return (r?.out ?? "").split(whereSeparator: \.isNewline).compactMap { hop(String($0)) }
    }
}

extension WiFiScanner {
    /// One scan of nearby networks.
    nonisolated static func scanOnce() -> ([NearbyNetwork], String?) {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn() else { return ([], "Wi-Fi is off.") }
        do {
            let mine = i.bssid()?.uppercased()
            let list = try i.scanForNetworks(withSSID: nil).enumerated().map { idx, n -> NearbyNetwork in
                let ch = n.wlanChannel
                let b = n.bssid?.uppercased() ?? ""
                return NearbyNetwork(id: b.isEmpty ? "n\(idx)-\(ch?.channelNumber ?? 0)-\(n.rssiValue)" : b,
                                     ssid: n.ssid ?? "", bssid: b, rssi: n.rssiValue, channel: ch?.channelNumber ?? 0,
                                     band: WiFiText.band(ch), widthMHz: WiFiText.widthMHz(ch),
                                     security: WiFiText.security(of: n), isMine: mine != nil && b == mine)
            }
            return (list.sorted { $0.rssi > $1.rssi }, nil)
        } catch {
            return ([], "Couldn’t scan: \(error.localizedDescription)")
        }
    }
}

extension WiFiMonitor {
    /// The current connection, as label/value rows (empty if Wi-Fi isn't connected).
    nonisolated static func snapshot() -> [(String, String)] {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn(), i.rssiValue() != 0 else { return [] }
        let ch = i.wlanChannel()
        let b = i.bssid()?.uppercased() ?? ""
        return [
            ("Signal", "\(i.rssiValue()) dBm"), ("Noise", "\(i.noiseMeasurement()) dBm"),
            ("SNR", "\(i.rssiValue() - i.noiseMeasurement()) dB"), ("Link rate", String(format: "%.0f Mb/s", i.transmitRate())),
            ("Network", i.ssid() ?? "(name hidden by macOS)"), ("Access point", b),
            ("Channel", ch.map { "\($0.channelNumber) · \(WiFiText.band($0)) · \(WiFiText.widthMHz($0)) MHz" } ?? ""),
            ("Security", WiFiText.security(i.security())),
        ]
    }
}

extension ConnectionInfo {
    /// The label/value rows Connection Info shows.
    func rows(wifiRate: Double?, publicIP: String) -> [(String, String)] {
        let left: String = leaseEnd.map { end in
            let secs = Int(end.timeIntervalSinceNow)
            return secs > 0 ? "renews by \(end.formatted(date: .omitted, time: .shortened)) (\(secs / 3600) h \(secs % 3600 / 60) m left)" : "expired"
        } ?? ""
        var leaseLength = ""
        if let s = leaseStart, let e = leaseEnd { leaseLength = "\(Int(e.timeIntervalSince(s) / 3600)) h" }
        let linkText = wifiRate.map { String(format: "Wi-Fi · %.0f Mb/s", $0) } ?? link
        let macNote = mac.isEmpty ? "" : (UInt8(mac.prefix(2), radix: 16).map { $0 & 0x02 != 0 } ?? false ? " (private address)" : "")
        var out: [(String, String)] = [
            ("IP address", "\(address) /\(prefix)"), ("Router", router), ("DHCP server", dhcpServer),
            ("Lease", [leaseLength, left].filter { !$0.isEmpty }.joined(separator: ", ")),
            ("DNS servers", dns.joined(separator: ", ")), ("Search domain", domain),
            ("IPv6", ipv6.map { "\($0) (\(IPv6Neighbors.kind($0).lowercased()))" }.joined(separator: "\n")),
            ("MAC", mac + macNote), ("MTU", mtu), ("Link", linkText),
        ]
        if !publicIP.isEmpty { out.append(("Public IP", publicIP)) }
        return out
    }

    static func publicIP() async -> String {
        guard let url = URL(string: "https://api.ipify.org"),
              let (data, _) = try? await URLSession.shared.data(from: url) else { return "" }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

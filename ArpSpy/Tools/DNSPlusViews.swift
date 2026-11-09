import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What the DNS tabs share: the one domain box, the server, and each tab's mark.
@MainActor final class DNSRun: ObservableObject {
    enum Mark { case none, running, done, warn }
    @Published var domain = ""
    @Published var server = ""
    /// Goes up by one each time Check all is pressed; the domain tabs watch it.
    @Published var token = 0
    /// True when the last Check all was for an IP address: only Look Up runs.
    @Published var lookUpOnly = false
    @Published var marks: [String: Mark] = [:]
    /// Goes up by one when Stop is pressed; every tab drops what it was doing.
    @Published var stopToken = 0
    /// True after Stop until something runs again, so a stopped tab shows no mark instead of a tick.
    private var stopped = false

    /// The host from whatever was typed or pasted: drops https://, a path, a port and a trailing dot.
    var host: String { Self.clean(domain) }
    /// The host without a leading www. (for the email and registration checks).
    var base: String { host.hasPrefix("www.") ? String(host.dropFirst(4)) : host }

    static func clean(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { "/?#".contains($0) }) { s = String(s[..<i]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if s.filter({ $0 == ":" }).count == 1, let c = s.firstIndex(of: ":") { s = String(s[..<c]) }
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }
    static func isAddress(_ s: String) -> Bool { IPv4(s) != nil || s.contains(":") }

    func set(_ tab: String, busy: Bool, warn: Bool) {
        if busy { stopped = false }
        marks[tab] = busy ? .running : stopped ? Mark.none : warn ? .warn : .done
    }

    var isRunning: Bool { marks.values.contains(.running) }

    func checkAll() {
        let h = host
        guard !h.isEmpty else { return }
        stopped = false
        lookUpOnly = Self.isAddress(h)
        if lookUpOnly { for t in ["email", "compare", "expiry"] { marks[t] = Mark.none } }
        token += 1
    }

    /// Stops every tab that is still working.
    func stopAll() {
        stopped = true
        stopToken += 1
    }
}

/// The DNS Lookup window: one domain box on top runs Look Up, Email Check, Compare Servers and Expiry
/// together; Reverse Subnet has its own range box.
struct DNSView: View {
    let initial: String?
    @AppStorage("dnsTab") private var tab = "lookup"
    @StateObject private var run = DNSRun()
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    static let tabs = [("lookup", "Look Up"), ("email", "Email Check"), ("compare", "Compare Servers"), ("expiry", "Expiry"), ("reverse", "Reverse Subnet")]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Domain or web address, like example.com (or an IP address for its name)", text: $run.domain)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    .onSubmit { run.checkAll() }
                ServerField(server: $run.server)
                if run.isRunning {
                    Button("Stop") { run.stopAll() }
                        .keyboardShortcut(.cancelAction)
                        .help("Stops the checks that are still running")
                } else {
                    Button("Check all") { run.checkAll() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(run.host.isEmpty)
                        .help("Runs Look Up, Email Check, Compare Servers and Expiry for this domain")
                }
            }
            .padding([.horizontal, .top], 16)
            HStack(spacing: 0) {
                ForEach(Self.tabs, id: \.0) { t in tabButton(t.0, t.1) }
            }
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 16)
            // Every tab stays alive (and keeps its results) while another is shown.
            ZStack {
                DNSLookUpPanel(initial: initial, run: run).opacity(tab == "lookup" ? 1 : 0).allowsHitTesting(tab == "lookup")
                EmailCheckPanel(run: run).opacity(tab == "email" ? 1 : 0).allowsHitTesting(tab == "email")
                CompareServersPanel(run: run).opacity(tab == "compare" ? 1 : 0).allowsHitTesting(tab == "compare")
                ExpiryPanel(run: run).opacity(tab == "expiry" ? 1 : 0).allowsHitTesting(tab == "expiry")
                ReverseSubnetPanel().opacity(tab == "reverse" ? 1 : 0).allowsHitTesting(tab == "reverse")
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .onAppear { if initial != nil { tab = "lookup" } }
    }

    private func tabButton(_ key: String, _ label: String) -> some View {
        let on = tab == key
        let onAccent = Color.onAccent(theme: theme, dark: colorScheme == .dark)
        return Button { tab = key } label: {
            HStack(spacing: 5) {
                Text(label)
                switch run.marks[key] ?? .none {
                case .running: ProgressView().controlSize(.mini)
                case .done: Image(systemName: "checkmark").foregroundStyle(on ? onAccent : .green)
                case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .none: EmptyView()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .foregroundStyle(on ? onAccent : Color.primary)
            .background(on ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private extension Color {
    /// Black or white, whichever reads on the accent colour (the High contrast theme's dark accent is yellow,
    /// where white text vanishes). Uses the theme's own accent, else the Mac's.
    static func onAccent(theme: AppTheme, dark: Bool) -> Color {
        let rgb: (Double, Double, Double)
        if let pair = theme.palette?.accent {
            let v = dark ? pair.1 : pair.0
            rgb = (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
        } else if let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) {
            rgb = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        } else {
            return .white
        }
        // Relative luminance (WCAG): linearise each channel, then weight them.
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * lin(rgb.0) + 0.7152 * lin(rgb.1) + 0.0722 * lin(rgb.2)
        return luminance > 0.6 ? .black : .white
    }
}

/// The Server field with the saved scans' name servers in a menu (shared by the tabs).
private struct ServerField: View {
    @Binding var server: String
    @ObservedObject private var model = ScanModel.shared
    var body: some View {
        HStack(spacing: 4) {
            Text("Server")
            TextField("", text: $server, prompt: Text("this Mac’s DNS"))
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).frame(width: 150)
            let servers = model.stored.sites.filter { !$0.effectiveNameServer.isEmpty }
            if !servers.isEmpty {
                Menu("Saved scan") { ForEach(servers) { s in Button("\(s.name) – \(s.effectiveNameServer)") { server = s.effectiveNameServer } } }.fixedSize()
            }
        }
    }
}

private func stateColor(_ s: DNSPlus.State) -> Color {
    switch s { case .good: return .green; case .warn: return .orange; case .bad: return .red; case .info: return .secondary }
}
private func dayColor(_ d: Int?) -> Color { guard let d else { return .secondary }; return d < 0 ? .red : d < 30 ? .orange : .green }

/// Busy indicator shared with the radar in the main window.
private struct BusyMark: ViewModifier {
    let busy: Bool
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content.onChange(of: busy) { _, on in Activity.shared.set(id, on) }.onDisappear { Activity.shared.set(id, false) }
    }
}

// MARK: - Email Check

struct EmailCheckPanel: View {
    @ObservedObject var run: DNSRun
    @State private var rows: [DNSPlus.EmailRow] = []
    @State private var checked = ""
    @State private var busy = false
    @State private var runID = 0
    @State private var task: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(checked.isEmpty ? "Mail servers, SPF, DMARC, DKIM, MTA-STS, BIMI and DNSSEC for the domain above." : "Email for \(checked)")
                    .foregroundStyle(.secondary)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                SaveToOrgButton(enabled: !rows.isEmpty && !busy) {
                    SavedDraft(kind: .dns, title: "Email check · \(checked)",
                               summary: "\(rows.filter { $0.state == .good }.count) good, \(rows.filter { $0.state == .warn }.count) to look at, \(rows.filter { $0.state == .bad }.count) problems",
                               table: SavedTable(header: ["", "Check", "Result", "Details"], rows: rows.map { [$0.state.mark, $0.check, $0.text, $0.detail] }, widths: [4, 12, 60, 70]))
                }
                Button("Check again", action: go).disabled(run.base.isEmpty || busy)
            }
            if !rows.isEmpty {
                HStack(spacing: 8) {
                    chip(rows.filter { $0.state == .good }.count, "good", .green)
                    chip(rows.filter { $0.state == .warn }.count, "to look at", .orange)
                    chip(rows.filter { $0.state == .bad }.count, rows.filter { $0.state == .bad }.count == 1 ? "problem" : "problems", .red)
                }
            }
            List(rows) { r in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(r.state.mark).bold().foregroundStyle(stateColor(r.state)).frame(width: 16)
                    Text(r.check).bold().frame(width: 100, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.text).font(r.text.contains("=") ? .system(.body, design: .monospaced) : .body).textSelection(.enabled)
                        if !r.detail.isEmpty { Text(r.detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .modifier(BusyMark(busy: busy))
        .onChange(of: busy) { _, on in run.set("email", busy: on, warn: rows.contains { $0.state != .good && $0.state != .info }) }
        .onChange(of: run.token) { _, _ in if !run.lookUpOnly { go() } else { rows = []; checked = "" } }
        .onChange(of: run.stopToken) { _, _ in stop() }
        .onDisappear { task?.cancel() }
    }

    private func stop() { task?.cancel(); task = nil; runID += 1; busy = false }

    @ViewBuilder private func chip(_ n: Int, _ label: String, _ c: Color) -> some View {
        if n > 0 { Text("\(n) \(label)").font(.caption).padding(.horizontal, 8).padding(.vertical, 2).background(c.opacity(0.18), in: Capsule()).foregroundStyle(c) }
    }

    private func go() {
        let d = run.base, srv = run.server
        guard !d.isEmpty, !DNSRun.isAddress(d) else { return }
        stop()
        let id = runID
        busy = true; rows = []
        task = Task {
            let r = await DNSPlus.emailCheck(d, server: srv)
            guard id == runID else { return }       // a newer check started meanwhile
            rows = r; checked = d; busy = false
        }
    }
}

// MARK: - Compare Servers

struct CompareServersPanel: View {
    @ObservedObject var run: DNSRun
    @State private var type = "A"
    @State private var rows: [DNSPlus.CompareRow] = []
    @State private var differ = false
    @State private var soaNote = ""
    @State private var asked = ""
    @State private var busy = false
    @State private var runID = 0
    @State private var task: Task<Void, Never>? = nil
    @State private var off: Set<String> = Set((UserDefaults.standard.stringArray(forKey: "compareOff") ?? []))
    @ObservedObject private var model = ScanModel.shared

    private var choices: [(key: String, label: String, server: String?)] {
        [("pc", "This Mac’s DNS", "")] + model.stored.sites.filter { !$0.effectiveNameServer.isEmpty }.map { ("site-\($0.effectiveNameServer)", "\($0.name) name server (\($0.effectiveNameServer))", $0.effectiveNameServer) }
        + [("cf", "Cloudflare 1.1.1.1", "1.1.1.1"), ("google", "Google 8.8.8.8", "8.8.8.8"), ("quad9", "Quad9 9.9.9.9", "9.9.9.9"), ("own", "The domain’s own name servers", nil)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(asked.isEmpty ? "Asks several DNS servers the same question and shows any that disagree." : "Compared \(asked)")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $type) { ForEach(DNSTool.types.filter { $0 != DNSTool.all }, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 90)
                if busy { ProgressView().controlSize(.small) }
                SaveToOrgButton(enabled: !rows.isEmpty && !busy) {
                    SavedDraft(kind: .dns, title: "Compare servers · \(asked)", summary: differ ? "answers differ" : "all servers agree",
                               table: SavedTable(header: ["Server", "Answer", "TTL", "Time (ms)"],
                                                 rows: rows.map { [$0.label, $0.answer + ($0.different ? " (different)" : ""), $0.ttl.map(String.init) ?? "", $0.ms.map(String.init) ?? ""] },
                                                 widths: [34, 50, 8, 10], numberColumns: [2, 3]))
                }
                Button("Compare again", action: go).disabled(run.host.isEmpty || busy)
            }
            FlowToggles(choices: choices.map { ($0.key, $0.label) }, off: $off)
            if !rows.isEmpty {
                let odd = rows.filter(\.different)
                Text(differ ? "The answers differ: \(odd.map(\.label).joined(separator: ", ")) \(odd.count == 1 ? "has" : "have") a different answer." + (odd.compactMap(\.ttl).max().map { " \(odd.count == 1 ? "Its" : "Their") copy expires in \(max(1, $0 / 60)) minutes (TTL), if it’s an old answer still cached." } ?? "")
                            : "Every server gives the same answer.")
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background((differ ? Color.orange : Color.green).opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
            }
            Table(rows) {
                TableColumn("Server") { r in Text(r.label) }.width(min: 160, ideal: 240)
                TableColumn("Answer") { r in
                    Text(r.answer + (r.different ? " (different)" : "")).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .foregroundStyle(r.different ? Color.orange : r.aliasOnly || r.failed ? Color.secondary : Color.primary)
                }
                TableColumn("TTL") { r in Text(r.ttl.map(String.init) ?? "").monospacedDigit() }.width(60)
                TableColumn("Time") { r in Text(r.ms.map { "\($0) ms" } ?? "").monospacedDigit() }.width(60)
            }
            if !soaNote.isEmpty { Text(soaNote).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(16)
        .modifier(BusyMark(busy: busy))
        .onChange(of: off) { _, v in UserDefaults.standard.set(Array(v), forKey: "compareOff") }
        .onChange(of: busy) { _, on in run.set("compare", busy: on, warn: differ || soaNote.contains("DON’T")) }
        .onChange(of: run.token) { _, _ in if !run.lookUpOnly { go() } else { rows = []; asked = ""; soaNote = "" } }
        .onChange(of: run.stopToken) { _, _ in stop() }
        .onDisappear { task?.cancel() }
    }

    private func stop() { task?.cancel(); task = nil; runID += 1; busy = false }

    private func go() {
        let n = run.host, t = type
        guard !n.isEmpty, !DNSRun.isAddress(n) else { return }
        var list = choices.filter { !off.contains($0.key) }.compactMap { c in c.server.map { (label: c.label, server: $0) } }
        let wantOwn = !off.contains("own")
        stop()
        let id = runID
        busy = true; rows = []; soaNote = ""; asked = "\(n) (\(t))"
        task = Task {
            var zone: (zone: String, ns: [String]) = ("", [])
            if wantOwn { zone = await DNSPlus.ownNameServers(n); list = zone.ns.map { (label: "\($0) (own)", server: $0) } + list }
            let r = await DNSPlus.compare(n, type: t, servers: list)
            guard id == runID else { return }       // a newer comparison started meanwhile
            rows = r.rows; differ = r.differ
            if !zone.ns.isEmpty {
                let serials = await DNSPlus.soaSerials(zone: zone.zone, ns: zone.ns)
                guard id == runID else { return }
                let uniq = Set(serials.map(\.serial))
                soaNote = serials.allSatisfy({ $0.serial == "(no answer)" }) ? "Couldn’t read the domain’s name servers’ serial numbers."
                    : uniq.count == 1 ? "The domain’s name servers agree with each other: \(zone.ns.joined(separator: ", ")) all have serial \(uniq.first!) (zone \(zone.zone))."
                    : "The domain’s name servers DON’T agree: \(serials.map { "\($0.ns) \($0.serial)" }.joined(separator: ", ")). One may not have the latest changes."
            }
            busy = false
        }
    }
}

/// A row of checkboxes that wraps.
private struct FlowToggles: View {
    let choices: [(String, String)]
    @Binding var off: Set<String>
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(choices, id: \.0) { c in
                Toggle(c.1, isOn: Binding(get: { !off.contains(c.0) }, set: { if $0 { off.remove(c.0) } else { off.insert(c.0) } }))
                    .toggleStyle(.checkbox)
            }
        }
    }
}

// MARK: - Expiry

struct ExpiryPanel: View {
    @ObservedObject var run: DNSRun
    @State private var result: DNSPlus.ExpiryResult? = nil
    @State private var checked = ""
    @State private var busy = false
    @State private var runID = 0
    @State private var task: Task<Void, Never>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(checked.isEmpty ? "When the domain’s registration and its HTTPS certificates run out." : "Expiry for \(checked)")
                        .foregroundStyle(.secondary)
                    Text("Asks rdap.org for the registration dates.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                SaveToOrgButton(enabled: result != nil && !busy) {
                    result.map { r in SavedDraft(kind: .dns, title: "Domain and certificate expiry · \(checked)", summary: summary(r),
                                                 table: SavedTable(header: ["", "Expires", "Issued by / registrar", "Details"], rows: DNSPlus.expiryRows(r), widths: [32, 24, 26, 60])) }
                }
                Button("Check again", action: go).disabled(run.base.isEmpty || busy)
            }
            if let r = result {
                let reg = r.registration, rd = DNSPlus.daysLeft(reg?.expires)
                let soon = r.certs.filter { $0.expires != nil }.min { $0.expires! < $1.expires! }, sd = DNSPlus.daysLeft(soon?.expires)
                HStack(spacing: 10) {
                    tile("Domain registration", reg?.expires.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "unknown",
                         reg.map { "\(rd.map { "in \($0) days · " } ?? "")\($0.registrar)" } ?? r.registrationProblem, dayColor(rd))
                    tile("Soonest certificate", soon?.expires.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "none found",
                         soon.map { "\((sd ?? 0) < 0 ? "EXPIRED" : "in \(sd ?? 0) days") · \($0.host)" } ?? "", dayColor(sd))
                    tile("Name servers", reg.map { $0.nameServers.joined(separator: ", ") } ?? "unknown",
                         reg?.dnssec.map { "DNSSEC: \($0 ? "signed" : "not signed")" } ?? "", .primary)
                }
                Table(r.certs) {
                    TableColumn("HTTPS certificate on") { c in Text("\(c.host)\(c.port == 443 ? "" : ":\(c.port)")") }.width(min: 160, ideal: 220)
                    TableColumn("Expires") { c in
                        let d = DNSPlus.daysLeft(c.expires)
                        Text(c.expires.map { "\($0.formatted(date: .abbreviated, time: .omitted))\((d ?? 0) < 0 ? " (EXPIRED)" : (d ?? 99) < 30 ? " (\(d ?? 0) days)" : "")" } ?? c.problem)
                            .foregroundStyle(c.expires == nil ? .secondary : dayColor(d))
                    }.width(min: 110, ideal: 150)
                    TableColumn("Issued by") { c in Text(c.issuer) }.width(min: 90, ideal: 140)
                    TableColumn("Covers") { c in
                        HStack(spacing: 4) {
                            if c.expires != nil && !c.coversHost { Text("Doesn’t cover this name.").bold().foregroundStyle(.red) }
                            Text(c.names.count > 3 ? c.names.prefix(3).joined(separator: ", ") + " and \(c.names.count - 3) more" : c.names.joined(separator: ", ")).foregroundStyle(.secondary)
                        }
                    }
                }
            } else { Spacer() }
            Text("Certificates are read from each host on port 443 (remote and vpn also 4443/8443). Orange under 30 days, red when expired.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .modifier(BusyMark(busy: busy))
        .onChange(of: busy) { _, on in run.set("expiry", busy: on, warn: result.map(needsLook) ?? false) }
        .onChange(of: run.token) { _, _ in if !run.lookUpOnly { go() } else { result = nil; checked = "" } }
        .onChange(of: run.stopToken) { _, _ in stop() }
        .onDisappear { task?.cancel() }
    }

    private func stop() { task?.cancel(); task = nil; runID += 1; busy = false }

    /// Something expires within 30 days, a certificate doesn't cover its name, or the registration couldn't be read.
    private func needsLook(_ r: DNSPlus.ExpiryResult) -> Bool {
        let days = ([r.registration?.expires] + r.certs.map(\.expires)).compactMap { DNSPlus.daysLeft($0) }
        return r.registration == nil || days.contains { $0 < 30 } || r.certs.contains { $0.expires != nil && !$0.coversHost }
    }

    private func tile(_ label: String, _ value: String, _ sub: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).foregroundStyle(color).lineLimit(2)
            Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func summary(_ r: DNSPlus.ExpiryResult) -> String {
        let dates = ([r.registration?.expires] + r.certs.map(\.expires)).compactMap { $0 }.sorted()
        guard let first = dates.first, let d = DNSPlus.daysLeft(first) else { return "nothing found" }
        return d < 0 ? "something has EXPIRED" : "soonest in \(d) days"
    }

    private func go() {
        let d = run.base
        guard !d.isEmpty, !DNSRun.isAddress(d) else { return }
        stop()
        let id = runID
        busy = true; result = nil
        task = Task {
            let r = await DNSPlus.expiry(d, server: "")
            guard id == runID else { return }       // a newer check started meanwhile
            result = r; checked = d; busy = false
        }
    }
}

// MARK: - Reverse Subnet

struct ReverseSubnetPanel: View {
    struct Row: Identifiable { let id: String; let name: String }
    @State private var range = ""
    @State private var server = ""
    @State private var rows: [Row] = []
    @State private var showAll = false
    @State private var status = ""
    @State private var asked = ""
    @State private var busy = false
    @State private var runID = 0
    @State private var task: Task<Void, Never>? = nil

    private var shown: [Row] { showAll ? rows : rows.filter { !$0.name.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Range, like 10.0.0.0/24", text: $range).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).onSubmit(run)
                ServerField(server: $server)
                if busy { ProgressView().controlSize(.small) }
                SaveToOrgButton(enabled: !rows.isEmpty && !busy) {
                    SavedDraft(kind: .dns, title: "Reverse lookup · \(asked)", summary: "\(rows.filter { !$0.name.isEmpty }.count) of \(rows.count) addresses have a name",
                               table: SavedTable(header: ["IP", "Name"], rows: rows.filter { !$0.name.isEmpty }.map { [$0.id, $0.name] }, widths: [16, 60]))
                }
                Button("Look Up", action: run).keyboardShortcut(.defaultAction).disabled(range.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            HStack {
                Toggle("Show addresses with no name too", isOn: $showAll).toggleStyle(.checkbox)
                Spacer()
                Button("Download CSV…", action: download).disabled(rows.isEmpty)
            }
            Text(status).font(.caption).foregroundStyle(.secondary)
            Table(shown) {
                TableColumn("IP") { r in Text(r.id).font(.system(.body, design: .monospaced)) }.width(140)
                TableColumn("Name") { r in Text(r.name.isEmpty ? "(no name)" : r.name).foregroundStyle(r.name.isEmpty ? .secondary : .primary).textSelection(.enabled) }
            }
        }
        .padding(16)
        .modifier(BusyMark(busy: busy))
        .onDisappear { task?.cancel() }
    }

    private func run() {
        let r = range.trimmingCharacters(in: .whitespaces), srv = server
        task?.cancel()
        runID += 1
        let id = runID
        busy = true; rows = []; status = "Asking…"
        let start = Date()
        task = Task {
            do {
                let list = try await DNSPlus.reverse(r, server: srv)
                guard id == runID else { return }       // a newer lookup started meanwhile
                rows = list.map { Row(id: $0.ip, name: $0.name) }
                asked = r
                status = "\(rows.filter { !$0.name.isEmpty }.count) of \(rows.count) addresses have a name · \(String(format: "%.1f", Date().timeIntervalSince(start))) s"
            } catch {
                guard id == runID else { return }
                status = (error as? LocalizedError)?.errorDescription ?? "That isn’t a valid range."
            }
            busy = false
        }
    }

    private func download() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "reverse-\(asked)".map { "/:\\ ".contains($0) ? "-" : $0 }.map(String.init).joined() + ".csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Exporter.csv(header: ["IP", "Name"], rows: rows.map { [$0.id, $0.name] }).write(to: url, atomically: true, encoding: .utf8)
    }
}

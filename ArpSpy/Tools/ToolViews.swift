import SwiftUI
import Charts
import AppKit
import CoreWLAN
import UniformTypeIdentifiers

enum ToolWindow {
    static let ping = "ping", trace = "traceroute", dns = "dns-lookup"
    static let wifi = "wifi-signal", analyzer = "wifi-analyzer", connection = "connection-info"
    static let speed = "speed-test", subnet = "subnet-calculator"
}

// MARK: - Menus

/// The Tools menu (⌘1–⌘8).
struct ToolsCommands: Commands {
    var body: some Commands {
        CommandMenu("Tools") { ToolsMenuItems() }
    }
}

private struct ToolsMenuItems: View {
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppMode.key) private var advanced = true
    var body: some View {
        Button("Ping…") { openWindow(id: ToolWindow.ping) }.keyboardShortcut("1")
        if advanced {
            Button("Traceroute…") { openWindow(id: ToolWindow.trace) }.keyboardShortcut("2")
            Button("DNS Lookup…") { openWindow(id: ToolWindow.dns) }.keyboardShortcut("3")
        }
        Divider()
        Button("Wi-Fi Signal") { openWindow(id: ToolWindow.wifi) }.keyboardShortcut("4")
        if advanced { Button("Wi-Fi Analyzer") { openWindow(id: ToolWindow.analyzer) }.keyboardShortcut("5") }
        Button("Connection Info") { openWindow(id: ToolWindow.connection) }.keyboardShortcut("6")
        Divider()
        Button("Speed Test") { openWindow(id: ToolWindow.speed) }.keyboardShortcut("7")
        if advanced { Button("Subnet Calculator") { openWindow(id: ToolWindow.subnet) }.keyboardShortcut("8") }
    }
}

/// Right-click › Ping / Traceroute / DNS Lookup, with the device's address filled in.
struct DeviceToolItems: View {
    let device: Device
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppMode.key) private var advanced = true
    var body: some View {
        Button("Ping") { openWindow(id: ToolWindow.ping, value: device.ip.description) }
        if advanced {
            Button("Traceroute") { openWindow(id: ToolWindow.trace, value: device.ip.description) }
            Button("DNS Lookup") { openWindow(id: ToolWindow.dns, value: device.ip.description) }
        }
    }
}

/// The window scenes, added to the app in ArpSpyApp.
struct ToolScenes: Scene {
    var body: some Scene {
        WindowGroup("Ping", id: ToolWindow.ping, for: String.self) { $target in
            PingView(initial: target).modifier(AppearanceApplier()).modifier(OrgAutoSaveScope())
        }
        .defaultSize(width: 620, height: 460)

        WindowGroup("Traceroute", id: ToolWindow.trace, for: String.self) { $target in
            TraceView(initial: target).modifier(AppearanceApplier()).modifier(OrgAutoSaveScope())
        }
        .defaultSize(width: 620, height: 460)

        WindowGroup("DNS Lookup", id: ToolWindow.dns, for: String.self) { $target in
            DNSView(initial: target).modifier(AppearanceApplier()).modifier(OrgAutoSaveScope())
        }
        .defaultSize(width: 860, height: 480)

        Window("Wi-Fi Signal", id: ToolWindow.wifi) { WiFiSignalView().modifier(AppearanceApplier()).modifier(OrgAutoSaveScope()) }
            .defaultSize(width: 560, height: 460)
        Window("Wi-Fi Analyzer", id: ToolWindow.analyzer) { WiFiAnalyzerView().modifier(AppearanceApplier()).modifier(OrgAutoSaveScope()) }
            .defaultSize(width: 760, height: 620)
        Window("Connection Info", id: ToolWindow.connection) { ConnectionView().modifier(AppearanceApplier()).modifier(OrgAutoSaveScope()) }
            .defaultSize(width: 520, height: 480)
        Window("Speed Test", id: ToolWindow.speed) { SpeedView().modifier(AppearanceApplier()).modifier(OrgAutoSaveScope()) }
            .defaultSize(width: 560, height: 420)
        Window("Subnet Calculator", id: ToolWindow.subnet) { SubnetView().modifier(AppearanceApplier()).modifier(OrgAutoSaveScope()) }
            .defaultSize(width: 460, height: 360)
    }
}

// MARK: - Small shared pieces

private struct Stat: View {
    let title: String, value: String
    var color: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        }
        .frame(minWidth: 70, alignment: .leading)
    }
}

private struct KeyValues: View {
    let rows: [(String, String)]
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                GridRow {
                    Text(r.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(r.1.isEmpty ? "—" : r.1).textSelection(.enabled)
                }
            }
        }
    }
}

/// Milliseconds the same way everywhere in the Tools: one decimal under 10 ms, whole numbers above.
private func msNumber(_ v: Double) -> String { v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v) }
private func ms(_ v: Double?) -> String { v.map { msNumber($0) + " ms" } ?? "—" }

// MARK: - Ping

struct PingView: View {
    let initial: String?
    @StateObject private var job = PingJob()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Address or name (several: separate with commas)", text: $job.targetsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { job.start() }
                Text("every")
                Picker("", selection: $job.interval) {
                    Text("0.5 s").tag(0.5); Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0)
                }
                .labelsHidden().frame(width: 80)
                Button(job.running ? "Stop" : "Start") { job.running ? job.stop() : job.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.targets.isEmpty)
                SaveToOrgButton(enabled: !job.samples.isEmpty, auto: false) { Drafts.ping(targets: job.targets, stats: job.stats(for:)) }
            }
            if let p = job.problem { Text(p).foregroundStyle(.red).font(.callout) }

            ForEach(job.targets, id: \.self) { t in
                let s = job.stats(for: t)
                HStack(spacing: 16) {
                    if job.targets.count > 1 { Text(t).font(.headline).frame(width: 120, alignment: .leading).lineLimit(1) }
                    Stat(title: "Last", value: s.sent == 0 ? "—" : (s.last.map { ms($0) } ?? "lost"), color: s.last == nil && s.sent > 0 ? .red : .primary)
                    Stat(title: "Average", value: ms(s.avg))
                    Stat(title: "Min / max", value: s.min.map { "\(msNumber($0)) / \(msNumber(s.max ?? 0))" } ?? "—")
                    Stat(title: "Jitter", value: ms(s.jitter))
                    Stat(title: "Lost", value: s.sent == 0 ? "—" : "\(s.lost) of \(s.sent)", color: s.lost > 0 ? .orange : .primary)
                }
            }

            Chart {
                ForEach(job.samples.filter { $0.time > Date().addingTimeInterval(-PingJob.window) }) { s in
                    if let v = s.ms {
                        LineMark(x: .value("Time", s.time), y: .value("ms", v))
                            .foregroundStyle(by: .value("Target", s.target))
                            .interpolationMethod(.monotone)
                    } else {
                        RuleMark(x: .value("Time", s.time))
                            .foregroundStyle(.red.opacity(0.8))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
            }
            .chartYAxisLabel("ms")
            .chartXScale(domain: Date().addingTimeInterval(-PingJob.window)...Date())
            .chartLegend(job.targets.count > 1 ? .visible : .hidden)
            .frame(minHeight: 180)
            Text("Last 60 seconds. Red lines are replies that didn’t come back.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 360)
        .onAppear {
            if let initial, job.targetsText.isEmpty { job.targetsText = initial; job.start() }
        }
        .onDisappear { job.stop() }
    }
}

// MARK: - Traceroute

struct TraceView: View {
    let initial: String?
    @StateObject private var job = TraceJob()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Address or name", text: $job.target)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { job.start() }
                if job.running { ProgressView().controlSize(.small) }
                Button(job.running ? "Stop" : "Trace") { job.running ? job.stop() : job.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.target.trimmingCharacters(in: .whitespaces).isEmpty)
                SaveToOrgButton(enabled: !job.hops.isEmpty && !job.running) { Drafts.traceroute(target: job.target, hops: job.hops) }
            }
            Table(job.hops) {
                TableColumn("#") { h in Text("\(h.number)").monospacedDigit() }.width(30)
                TableColumn("Address") { h in
                    Text(h.address).font(.system(.body, design: .monospaced)).foregroundStyle(h.address == "*" ? .secondary : .primary)
                }
                .width(min: 110, ideal: 130)
                TableColumn("Name") { h in
                    Text(h.address == "*" ? "no answer" : h.name).foregroundStyle(h.address == "*" ? .secondary : .primary)
                        .textSelection(.enabled)
                }
                TableColumn("Time") { h in Text(ms(h.ms)).monospacedDigit() }.width(70)
            }
            Text(job.status).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 300)
        .onAppear { if let initial, job.target.isEmpty { job.target = initial; job.start() } }
        .onDisappear { job.stop() }
    }
}

// MARK: - DNS lookup

/// DNS Lookup's Look Up tab (the window itself, with its other tabs, is DNSView in DNSPlusViews.swift).
struct DNSLookUpPanel: View {
    let initial: String?
    @ObservedObject var run: DNSRun
    @State private var type = DNSTool.all
    /// The name from the shared box at the top of the window (for All, without a leading www.,
    /// since All asks for www. and the other common names itself), and its server.
    private var name: String { type == DNSTool.all ? run.base : run.host }
    private var server: String { run.server }
    @State private var groups: [DNSGroup] = []
    @State private var status = ""
    @State private var busy = false
    /// Goes up with every lookup; a lookup that finishes after a newer one started throws its results away.
    @State private var runID = 0
    @State private var task: Task<Void, Never>? = nil
    @State private var activityID = UUID()
    @AppStorage("dnsFollowCNAMEs") private var follow = false
    @AppStorage("dnsFindSubdomains") private var findSubdomains = false
    @ObservedObject private var model = ScanModel.shared

    /// What the table shows: each question's own records, plus (optionally) where their CNAMEs lead, indented.
    private var answers: [DNSAnswer] {
        DNSTool.display(groups, follow: follow)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Type", selection: $type) { ForEach(DNSTool.types, id: \.self) { Text($0).tag($0) } }
                    .frame(width: 130)
                Toggle("Follow CNAMEs to other domains", isOn: $follow)
                    .toggleStyle(.checkbox)
                    .help("Also show the records of the names a CNAME points to, indented under it")
                Toggle("Find subdomains", isOn: $findSubdomains)
                    .toggleStyle(.checkbox)
                    .help("With All: asks the public certificate logs (crt.sh, or Cert Spotter) for every name this domain has had an HTTPS certificate for, then looks each one up")
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Menu("Download…") {
                    Button("Download CSV…") { save(excel: false) }
                    Button("Download Excel (.xlsx)…") { save(excel: true) }
                }
                .fixedSize()
                .disabled(answers.isEmpty || busy)
                SaveToOrgButton(enabled: !answers.isEmpty && !busy) {
                    Drafts.dns(target: name.trimmingCharacters(in: .whitespaces), type: type, server: server,
                               answers: DNSTool.display(groups, follow: true))
                }
                Button("Look up again", action: lookUp)
                    .disabled(name.isEmpty || busy)
            }
            // Grouped by record type: a box per type with a heading that folds it; no Type column.
            DNSSectionsView(sections: DNSTool.sections(answers))
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 280)
        .onChange(of: busy) { _, on in
            Activity.shared.set(activityID, on)
            run.set("lookup", busy: on, warn: answers.isEmpty)
        }
        .onDisappear { Activity.shared.set(activityID, false); task?.cancel() }
        .onChange(of: run.token) { _, _ in
            // An address gets its name (PTR); a name that was set to PTR goes back to All.
            if run.lookUpOnly { type = "PTR" } else if type == "PTR" { type = DNSTool.all }
            lookUp()
        }
        .onChange(of: run.stopToken) { _, _ in
            if busy { cancel(); status = "Stopped." }
        }
        .onAppear {
            if let initial, run.domain.isEmpty {
                // Opened from a device: only Look Up runs (the other tabs are for internet domains).
                // An address: ask the saved scan's name server for its name. A domain: this Mac's DNS,
                // which works from anywhere (a client's internal DNS may be out of reach).
                run.domain = initial
                if IPv4(initial) != nil { type = "PTR"; run.server = model.currentSite?.effectiveNameServer ?? "" } else { run.server = "" }
                lookUp()
            }
        }
    }

    /// Drops whatever lookup is running (its late results are ignored).
    fileprivate func cancel() {
        task?.cancel(); task = nil
        runID += 1
        busy = false
    }

    /// A new lookup: the old one is dropped first. Returns the id the new one must still match when it finishes.
    fileprivate func begin() -> Int {
        cancel()
        busy = true
        return runID
    }

    private func lookUp() {
        guard HostName.isValid(name) else { cancel(); groups = []; status = HostName.problem; return }
        if type == DNSTool.all { lookUpAll(); return }
        let t = type
        let asked = DNSTool.askedName(name, type: t)
        let args = DNSTool.arguments(name: name, type: t, server: server)
        let id = begin()
        status = "Asking…"; groups = []
        task = Task {
            let r = await offMain { Command.run("/usr/bin/dig", args, timeout: 8) }
            guard id == runID else { return }
            busy = false
            guard let r else { status = "No answer in time."; return }
            let p = DNSTool.parse(r.out)
            groups = [DNSGroup(asked: asked, answers: p.answers)]
            if p.answers.isEmpty && p.ms == nil { status = "No answer. Is the server address right?"; return }
            let by = p.server.map { " by \($0)" } ?? ""
            status = answers.isEmpty ? "No \(t) records (answered in \(p.ms ?? 0) ms\(by))."
                                     : "Answered in \(p.ms ?? 0) ms\(by)."
        }
    }
}

extension DNSLookUpPanel {
    /// Saves the rows shown as CSV or Excel. Followed CNAME records are marked "↳" and indented.
    fileprivate func save(excel: Bool) {
        let header = ["Name", "Type", "TTL", "Answer"]
        let rows = answers.map { a -> [String] in
            let name = a.depth == 0 ? a.name : String(repeating: "  ", count: a.depth - 1) + "↳ " + a.name
            return [name, a.type, String(a.ttl), a.data]
        }
        let target = name.trimmingCharacters(in: .whitespaces)
        let panel = NSSavePanel()
        let stamp = Date().formatted(.iso8601.year().month().day())
        let base = "dns-\(target.isEmpty ? "lookup" : target)-\(stamp)".map { "/:\\ ".contains($0) ? "-" : $0 }
        panel.nameFieldStringValue = String(base) + (excel ? ".xlsx" : ".csv")
        panel.allowedContentTypes = excel ? [UTType(filenameExtension: "xlsx") ?? .data] : [.commaSeparatedText]
        panel.message = "DNS results for \(target)\(server.isEmpty ? "" : " from \(server)")"
        panel.prompt = "Download"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if excel {
                try Exporter.xlsx(header: header, rows: rows, widths: [48, 8, 8, 70], numberColumns: [2],
                                  sheetName: "DNS \(target)").write(to: url, options: .atomic)
            } else {
                try Exporter.csv(header: header, rows: rows).write(to: url, atomically: true, encoding: .utf8)
            }
            status = "Downloaded \(rows.count) records to \(url.lastPathComponent)."
        } catch {
            status = "Couldn’t download: \(error.localizedDescription)"
        }
    }

    /// Every common record type for the name (for an IP: its PTR name first, then everything for that name).
    fileprivate func lookUpAll() {
        let target = name.trimmingCharacters(in: .whitespaces)
        let srv = server
        let wantSubs = findSubdomains && IPv4(target) == nil
        let id = begin()
        status = wantSubs ? "Asking the certificate logs for subdomains… (can take 30 seconds)" : "Asking for everything…"; groups = []
        task = Task {
            var extra: [String] = [], note = ""
            if wantSubs {
                let s = await DNSPlus.subdomains(target)
                guard id == runID else { return }
                let asked = Set(DNSTool.allQueries(target).map { $0.name.lowercased() })
                extra = Array(s.names.filter { !asked.contains($0) }.prefix(300))
                note = s.problem.isEmpty ? " · \(extra.count) more names from \(s.source)" : " · subdomains: \(s.problem)"
                status = "Asking for everything…"
            }
            let (found, lookups) = await DNSTool.collectAll(target, server: srv, extraNames: extra)
            guard id == runID else { return }
            groups = found
            busy = false
            status = (answers.isEmpty ? "Nothing found for \(target)." : "\(answers.filter { $0.depth == 0 }.count) records from \(lookups) lookups.") + note
        }
    }
}

// MARK: - Wi-Fi signal

struct WiFiSignalView: View {
    @StateObject private var wifi = WiFiMonitor()
    @ObservedObject private var location = LocationPermission.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !wifi.available {
                Text("Wi-Fi is off or not connected.").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 18) {
                    Stat(title: "Signal", value: "\(wifi.rssi) dBm", color: color(wifi.rssi))
                    Stat(title: "Noise", value: "\(wifi.noise) dBm")
                    Stat(title: "SNR", value: "\(wifi.rssi - wifi.noise) dB", color: wifi.rssi - wifi.noise >= 25 ? .green : .orange)
                    Stat(title: "Link rate", value: String(format: "%.0f Mb/s", wifi.rate))
                }
                KeyValues(rows: [
                    ("Network", wifi.ssid.isEmpty ? (location.allowed ? "" : "hidden by macOS – see below") : wifi.ssid),
                    ("Access point", wifi.bssid.isEmpty ? "" : "\(wifi.bssid)  \(OUIDatabase.shared.vendor(for: wifi.bssid))"),
                    ("Channel", wifi.channel), ("Security", wifi.security),
                ])
                .font(.callout)
                Chart {
                    RectangleMark(yStart: .value("", -67), yEnd: .value("", -30)).foregroundStyle(.green.opacity(0.08))
                    ForEach(wifi.samples.suffix(120)) { s in
                        LineMark(x: .value("Time", s.time), y: .value("dBm", s.rssi), series: .value("", "Signal"))
                            .foregroundStyle(.green)
                        LineMark(x: .value("Time", s.time), y: .value("dBm", s.noise), series: .value("", "Noise"))
                            .foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    ForEach(wifi.roams, id: \.self) { t in
                        RuleMark(x: .value("Roamed", t)).foregroundStyle(.orange)
                            .annotation(position: .top, alignment: .leading) { Text("roamed").font(.caption2).foregroundStyle(.orange) }
                    }
                }
                .chartYScale(domain: -100 ... -30)
                .chartYAxisLabel("dBm")
                .frame(minHeight: 160)
HStack {
                    Text("Last 2 minutes. Green band = good (−67 dBm or better). Orange line = moved to another access point.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    SaveToOrgButton(auto: false) { Drafts.wifiSignal(WiFiMonitor.snapshot()) }
                }
            }
            LocationNote(location: location)
        }
        .padding(16)
        .frame(minWidth: 500, minHeight: 360)
        .onAppear { wifi.start() }
        .onDisappear { wifi.stop() }
    }

    private func color(_ r: Int) -> Color { r >= -67 ? .green : r >= -75 ? .orange : .red }
}

/// Explains (once) why network names are hidden and offers the permission prompt.
private struct LocationNote: View {
    @ObservedObject var location: LocationPermission
    var body: some View {
        if !location.allowed {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "location").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("macOS hides Wi-Fi network names until you allow ARPradar to use Location. ARPradar never reads your location; this is only how macOS guards network names.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if location.undecided {
                        Button("Allow…") { location.ask() }.controlSize(.small)
                    } else {
                        Button("Open Location Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        }
    }
}

// MARK: - Wi-Fi analyzer

struct WiFiAnalyzerView: View {
    @StateObject private var scanner = WiFiScanner()
    @ObservedObject private var location = LocationPermission.shared
    @State private var band = "2.4 GHz"
    static let bands = ["2.4 GHz", "5 GHz", "6 GHz"]

    private var shown: [NearbyNetwork] { scanner.networks.filter { $0.band == band } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $band) {
                    ForEach(Self.bands, id: \.self) { b in Text("\(b) (\(scanner.networks.filter { $0.band == b }.count))").tag(b) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 330)
                Spacer()
                if scanner.scanning { ProgressView().controlSize(.small) }
                Text("\(scanner.networks.count) networks · rescans every \(Int(WiFiScanner.every)) s").font(.caption).foregroundStyle(.secondary)
                SaveToOrgButton(enabled: !scanner.networks.isEmpty, auto: false) { Drafts.wifiNetworks(scanner.networks, signal: WiFiMonitor.snapshot()) }
            }
            ChannelChart(networks: shown, band: band)
                .frame(minHeight: 220)
            if let tip = WiFiScanner.advice(scanner.networks, band: band) {
                Label(tip, systemImage: "lightbulb").font(.callout)
            }
            if let p = scanner.problem { Text(p).foregroundStyle(.red).font(.callout) }
            Table(shown) {
                TableColumn("Network") { n in
                    HStack(spacing: 4) {
                        Text(n.ssid.isEmpty ? (location.allowed ? "(hidden network)" : "(name hidden)") : n.ssid)
                            .foregroundStyle(n.ssid.isEmpty ? .secondary : .primary)
                        if n.isMine { Text("you").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                .width(min: 140, ideal: 180)
                TableColumn("Signal") { n in
                    Text("\(n.rssi) dBm").monospacedDigit()
                        .foregroundStyle(n.rssi >= -67 ? Color.green : n.rssi >= -75 ? .orange : .red)
                }
                .width(70)
                TableColumn("Channel") { n in Text("\(n.channel)").monospacedDigit() }.width(60)
                TableColumn("Width") { n in Text("\(n.widthMHz) MHz") }.width(70)
                TableColumn("Security") { n in Text(n.security) }.width(min: 90, ideal: 130)
                TableColumn("Access point") { n in
                    Text(n.bssid.isEmpty ? "" : "\(n.bssid)").font(.system(.caption, design: .monospaced))
                }
            }
            .frame(minHeight: 160)
            LocationNote(location: location)
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 520)
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
    }
}

/// Each network as a hump over the channels it covers, as tall as its signal.
private struct ChannelChart: View {
    let networks: [NearbyNetwork]
    let band: String

    private var range: ClosedRange<Double> {
        switch band {
        case "2.4 GHz": return -1 ... 15
        case "5 GHz": return 30 ... 181
        default: return -3 ... 237
        }
    }
    private var ticks: [Int] {
        switch band {
        case "2.4 GHz": return Array(1...14)
        case "5 GHz": return [36, 52, 64, 100, 116, 132, 149, 165, 177]
        default: return [1, 33, 65, 97, 129, 161, 193, 225]
        }
    }
    static let palette: [Color] = [.blue, .red, .green, .orange, .purple, .pink, .teal, .brown, .indigo, .mint, .cyan, .yellow]

    var body: some View {
        Canvas { ctx, size in
            let left = 34.0, bottom = 18.0, top = 8.0
            let w = size.width - left - 6, h = size.height - bottom - top
            let w_ = w
            func x(_ ch: Double) -> Double { left + (ch - range.lowerBound) / (range.upperBound - range.lowerBound) * w }
            func y(_ dbm: Double) -> Double { top + (-30 - dbm) / 70 * h }          // -30 at top, -100 at bottom

            for d in stride(from: -40.0, through: -90, by: -10) {
                var line = Path(); line.move(to: CGPoint(x: left, y: y(d))); line.addLine(to: CGPoint(x: left + w, y: y(d)))
                ctx.stroke(line, with: .color(.secondary.opacity(0.15)), lineWidth: 1)
                ctx.draw(Text("\(Int(d))").font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: 16, y: y(d)))
            }
            for t in ticks {
                ctx.draw(Text("\(t)").font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: x(Double(t)), y: size.height - 8))
            }
            let ordered = networks.sorted(by: { $0.rssi < $1.rssi })
            func colour(_ i: Int, _ n: NearbyNetwork) -> Color { n.isMine ? Color.accentColor : Self.palette[i % Self.palette.count] }
            var labels: [(text: String, at: CGPoint, color: Color, bold: Bool, peak: Double)] = []
            for (i, n) in ordered.enumerated() {
                let color = colour(i, n)
                let half = band == "2.4 GHz" ? 2.0 * Double(n.widthMHz) / 20 : Double(n.widthMHz) / 10
                let x0 = x(n.centre - half), x1 = x(n.centre + half), peak = y(Double(n.rssi)), base = y(-100)
                var hump = Path()
                hump.move(to: CGPoint(x: x0, y: base))
                hump.addCurve(to: CGPoint(x: (x0 + x1) / 2, y: peak), control1: CGPoint(x: x0 + (x1 - x0) * 0.15, y: peak),
                              control2: CGPoint(x: x0 + (x1 - x0) * 0.3, y: peak))
                hump.addCurve(to: CGPoint(x: x1, y: base), control1: CGPoint(x: x1 - (x1 - x0) * 0.3, y: peak),
                              control2: CGPoint(x: x1 - (x1 - x0) * 0.15, y: peak))
                ctx.fill(hump, with: .color(color.opacity(0.12)))
                ctx.stroke(hump, with: .color(color), lineWidth: n.isMine ? 2.5 : 1.3)
                let label = n.ssid.isEmpty ? "ch \(n.channel)" : n.ssid
                labels.append((label, CGPoint(x: (x0 + x1) / 2, y: peak - 8), color, n.isMine, peak))
            }
            // Names: strongest first, each moved up (or down) until it doesn't overlap one already placed.
            var placed: [CGRect] = []
            for l in labels.sorted(by: { $0.peak < $1.peak }) {
                let w = Double(l.text.count) * 6 + 6, hgt = 12.0
                let cx = min(max(l.at.x, left + w / 2), left + w_ - w / 2)
                var offsets: [Double] = [0]
                for k in 1...8 { offsets += [-Double(k) * hgt, Double(k) * hgt] }
                var spot: CGRect? = nil
                for off in offsets {
                    let r = CGRect(x: cx - w / 2, y: l.at.y + off - hgt / 2, width: w, height: hgt)
                    guard r.minY >= top - 2, r.maxY <= size.height - bottom else { continue }
                    if !placed.contains(where: { $0.intersects(r) }) { spot = r; break }
                }
                guard let r = spot else { continue }        // nowhere free: the table below still lists it
                placed.append(r)
                ctx.fill(Path(roundedRect: r.insetBy(dx: -1, dy: 0), cornerRadius: 3), with: .color(Color(nsColor: .textBackgroundColor).opacity(0.75)))
                ctx.draw(Text(l.text).font(.system(size: 10, weight: l.bold ? .bold : .regular)).foregroundColor(l.color),
                         at: CGPoint(x: r.midX, y: r.midY))
            }
            if networks.isEmpty {
                ctx.draw(Text("No networks on \(band)").foregroundColor(.secondary), at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }
}

// MARK: - Connection info

struct ConnectionView: View {
    @ObservedObject private var model = ScanModel.shared
    @State private var iface = ""
    @State private var info: ConnectionInfo? = nil
    @State private var wifiRate: Double? = nil
    @State private var publicIP = ""
    @State private var confirmRenew = false
    @State private var note = ""

    private var current: NetInterface? { model.interfaces.first { $0.id == iface } ?? model.interfaces.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $iface) {
                    ForEach(model.interfaces) { Text("\($0.friendlyName) (\($0.bsdName))").tag($0.id) }
                }
                .labelsHidden().frame(width: 200)
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh").accessibilityLabel("Refresh")
                Spacer()
                Button("Renew DHCP Lease…") { confirmRenew = true }
                    .disabled(info?.dhcpServer.isEmpty ?? true)
                Button("Copy") { Exporter.copyToClipboard(copyText) }
                SaveToOrgButton(enabled: info != nil) {
                    info.flatMap { Drafts.connection($0.rows(wifiRate: wifiRate, publicIP: publicIP), interface: current.map { "\($0.friendlyName) (\($0.bsdName))" } ?? "") }
                }
            }
            if let c = info {
                KeyValues(rows: rows(c)).font(.callout)
                HStack {
                    Text("Public IP").foregroundStyle(.secondary)
                    if publicIP.isEmpty {
                        Button("Look Up") { lookUpPublicIP() }.controlSize(.small)
                        Text("asks api.ipify.org once").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(publicIP).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                }
                .font(.callout)
            } else if model.interfaces.isEmpty {
                Text("No network adapters found").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 380)
        .onAppear { if iface.isEmpty { iface = model.selectedInterface.isEmpty ? (model.interfaces.first?.id ?? "") : model.selectedInterface }; load() }
        .onChange(of: iface) { load() }
        .confirmationDialog("Renew the DHCP lease on \(current?.bsdName ?? "")?", isPresented: $confirmRenew) {
            Button("Renew") { renew() }
        } message: {
            Text("macOS asks for your Mac password for this. The connection may drop for a few seconds.")
        }
    }

    private func rows(_ c: ConnectionInfo) -> [(String, String)] { c.rows(wifiRate: wifiRate, publicIP: "") }

    private var copyText: String {
        guard let c = info else { return "" }
        return (rows(c) + [("Public IP", publicIP)]).filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }

    private func load() {
        guard let i = current else { return }
        Task {
            info = await offMain { ConnectionInfo.read(i) }
            wifiRate = i.friendlyName.localizedCaseInsensitiveContains("wi-fi") ? await offMain { CWWiFiClientRate.rate() } : nil
        }
    }

    private func lookUpPublicIP() {
        Task {
            guard let url = URL(string: "https://api.ipify.org") else { return }
            if let (data, _) = try? await URLSession.shared.data(from: url) {
                publicIP = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                publicIP = "couldn’t reach the lookup service"
            }
        }
    }

    private func renew() {
        guard let name = current?.bsdName, name.allSatisfy({ $0.isLetter || $0.isNumber }) else { return }
        note = "Renewing…"
        Task {
            let ok: Bool = await offMain {
                let script = "do shell script \"/usr/sbin/ipconfig set \(name) DHCP\" with administrator privileges"
                var err: NSDictionary?
                _ = NSAppleScript(source: script)?.executeAndReturnError(&err)
                return err == nil
            }
            note = ok ? "Lease renewed." : "Not renewed (cancelled or not allowed)."
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            load()
        }
    }
}

enum CWWiFiClientRate {
    static func rate() -> Double? {
        guard let i = CWWiFiClient.shared().interface(), i.rssiValue() != 0 else { return nil }
        return i.transmitRate()
    }
}

// MARK: - Speed test

struct SpeedView: View {
    @StateObject private var job = SpeedJob()
    @ObservedObject private var model = ScanModel.shared
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let r = job.latest {
                HStack(spacing: 20) {
                    Stat(title: "Download", value: String(format: "%.0f Mb/s", r.downMbps))
                    Stat(title: "Upload", value: String(format: "%.0f Mb/s", r.upMbps))
                    Stat(title: "Responsiveness", value: "\(r.rating) · \(Int(r.rpm)) RPM",
                         color: r.rating == "High" ? .green : r.rating == "Medium" ? .orange : .red)
                    Stat(title: "Idle latency", value: String(format: "%.0f ms", r.idleMs))
                }
            }
            HStack {
                Button(job.history.isEmpty ? "Run Test" : "Run Again") { job.run(site: model.currentSite?.name ?? "") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(job.running)
                SaveToOrgButton(enabled: job.latest != nil && !job.running) { job.latest.map(Drafts.speed) }
                if job.running { ProgressView().controlSize(.small) }
                Text(job.status.isEmpty ? "Uses Apple’s built-in test (about 20 s, a few hundred MB of data)." : job.status)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Table(job.history) {
                TableColumn("When") { r in Text(r.date.formatted(date: .abbreviated, time: .shortened)) }.width(min: 130, ideal: 150)
                TableColumn("Saved scan") { r in Text(r.site) }
                TableColumn("Down") { r in Text(String(format: "%.0f", r.downMbps)).monospacedDigit() }.width(60)
                TableColumn("Up") { r in Text(String(format: "%.0f", r.upMbps)).monospacedDigit() }.width(60)
                TableColumn("RPM") { r in Text("\(Int(r.rpm))").monospacedDigit() }.width(60)
            }
            HStack { Spacer(); Button("Clear List") { confirmClear = true }.buttonStyle(.link).disabled(job.history.isEmpty) }
        }
        .padding(16)
        .frame(minWidth: 500, minHeight: 320)
        .confirmationDialog("Clear the speed test list?", isPresented: $confirmClear) {
            Button("Clear List", role: .destructive) { job.clear() }
        } message: {
            Text("This can’t be undone.")
        }
    }
}

// MARK: - Subnet calculator

struct SubnetView: View {
    @State private var text = ""
    @ObservedObject private var model = ScanModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let s = SubnetInfo.parse(text)
        VStack(alignment: .leading, spacing: 12) {
            TextField("172.16.8.20/22 or 172.16.8.20 255.255.252.0", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            if let s {
                KeyValues(rows: [
                    ("Network", s.network.description), ("Mask", "\(s.mask) (/\(s.prefix))"), ("Wildcard", s.wildcard.description),
                    ("Broadcast", s.prefix >= 31 ? "none" : s.broadcast.description),
                    ("Usable", "\(s.firstHost) – \(s.lastHost)"), ("Hosts", s.hosts.formatted()), ("Type", s.kind),
                ])
                .font(.system(.callout, design: .monospaced))
                Button("Scan This Range") {
                    model.rangeText = s.cidr
                    openWindow(id: "main")
                }
                .disabled(s.hosts > UInt64(IPRangeParser.maxHosts) || model.isScanning)
                .help(s.hosts > UInt64(IPRangeParser.maxHosts) ? "Too big to scan at once (more than 65,536 addresses)" : "Put this range in the main window")
            } else if !text.isEmpty {
                Text("Type an address with /prefix or a mask.").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(minWidth: 400, minHeight: 300)
        .onAppear { if text.isEmpty { text = model.interfaces.first.map { "\($0.address)/\($0.prefixLength)" } ?? "" } }
    }
}

/// The small "A" / "AAAA" tag on a record reached through a CNAME.
struct DNSTypeTag: View {
    let type: String
    var body: some View {
        Text(type)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.blue)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
            .fixedSize()
    }
}

/// DNS records grouped by type: each type in its own outlined box with a darker heading bar.
/// Click a heading to fold or unfold that group.
struct DNSSectionsView: View {
    let sections: [DNSSection]
    @State private var collapsed = Set<String>()
    private let nameWidth: CGFloat = 320, ttlWidth: CGFloat = 64

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("Name").frame(width: nameWidth, alignment: .leading)
                Text("TTL").frame(width: ttlWidth, alignment: .trailing)
                Text("Answer").padding(.leading, 14).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 5)
            Divider()
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(sections) { box($0) }
                }
                .padding(8)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }

    private func box(_ s: DNSSection) -> some View {
        let open = !collapsed.contains(s.type)
        return VStack(spacing: 0) {
            Button {
                if open { collapsed.insert(s.type) } else { collapsed.remove(s.type) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                    Text(s.heading).fontWeight(.semibold)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color.accentColor.opacity(0.24))
            .help(open ? "Hide these records" : "Show these records")
            .accessibilityLabel("\(s.heading), \(open ? "expanded" : "collapsed")")
            if open {
                ForEach(Array(s.lines.enumerated()), id: \.element.id) { i, line in
                    row(line).background(i % 2 == 1 ? Color.secondary.opacity(0.07) : Color.clear)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor.opacity(0.55), lineWidth: 1))
    }

    private func row(_ l: DNSLine) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                if l.depth > 0 { Text("↳").foregroundStyle(.secondary) }
                Text(l.name).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            }
            .padding(.leading, CGFloat(max(0, l.depth - 1)) * 16 + (l.depth > 0 ? 8 : 0))
            .foregroundStyle(l.depth > 0 ? .secondary : .primary)
            .frame(width: nameWidth, alignment: .leading)
            Text(l.ttl).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: ttlWidth, alignment: .trailing)
            HStack(spacing: 6) {
                // Where a CNAME leads: say what kind of record it is (there's no Type column).
                if l.depth > 0 { DNSTypeTag(type: l.type) }
                Text(l.data).font(.system(.body, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                    .foregroundStyle(l.depth > 0 ? .secondary : .primary)
                    .help(l.data)      // long answers (DKIM keys) are cut at two lines; hover shows it all
            }
            .padding(.leading, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Copy Answer") { Exporter.copyToClipboard(l.data) }
            Button("Copy Name") { Exporter.copyToClipboard(l.name) }
            Button("Copy Row") { Exporter.copyToClipboard("\(l.name)\t\(l.type)\t\(l.ttl)\t\(l.data)") }
        }
    }
}

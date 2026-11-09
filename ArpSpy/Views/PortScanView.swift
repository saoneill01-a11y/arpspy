import SwiftUI
import AppKit

/// Right-click › Scan Ports…: checks one device for common ports, all ports, or a list/range.
/// Its own window (one per device), so the main window stays usable while a long scan runs.
struct PortScanView: View {
    static let windowID = "port-scan"
    /// The device each window was opened for, handed over by whoever opened it (keyed by IP).
    @MainActor static var pending: [UInt32: Device] = [:]

    @ObservedObject var model: ScanModel
    let device: Device
    @StateObject private var job = PortScanJob()
    @Environment(\.dismiss) private var dismiss

    /// The window's content: finds the device for this IP (from the scan, or the one handed over).
    static func window(ip: UInt32?) -> some View {
        let model = ScanModel.shared
        let d = ip.flatMap { v in model.devices.first { $0.ip.value == v } ?? pending[v] } ?? Device(ip: IPv4(ip ?? 0))
        return PortScanView(model: model, device: d)
            .modifier(OrgAutoSaveScope())
            .modifier(AppearanceApplier())
            .navigationTitle("Scan Ports · \(d.name.isEmpty ? d.ip.description : d.name)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan ports on \(device.name.isEmpty ? device.ip.description : "\(device.name) (\(device.ip))")")
                .font(.headline)

            Picker("", selection: $job.mode) {
                Text("Common ports (about \(Ports.common.count): web, file sharing, remote access, mail, databases, printers, cameras)")
                    .tag(PortScanJob.Mode.common)
                Text("All ports (1–65535; seconds on your LAN, up to a minute over a VPN)").tag(PortScanJob.Mode.all)
                HStack {
                    Text("Ports:")
                    TextField("", text: $job.rangeText, prompt: Text("1-1024, 8000-8100, 5060"))
                        .frame(width: 220)
                        .font(.system(.body, design: .monospaced))
                        .disabled(job.mode != .range)
                    if job.mode == .range && Ports.parseList(job.rangeText) == nil && !job.rangeText.isEmpty {
                        Text("Use numbers 1–65535, like 1-1024").font(.caption).foregroundStyle(.red)
                    }
                }
                .tag(PortScanJob.Mode.range)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(job.running)

            HStack {
                if job.running || job.progress > 0 {
                    ProgressView(value: job.progress).frame(maxWidth: .infinity)
                } else { Spacer() }
                Text(job.status).foregroundStyle(.secondary).font(.callout).lineLimit(1)
            }

            Table(job.results) {
                TableColumn("Port") { r in Text(String(r.port)).font(.system(.body, design: .monospaced)) }
                    .width(60)
                TableColumn("Service") { r in Text(r.service) }
                    .width(min: 110, ideal: 150)
                TableColumn("What answers") { r in Text(r.banner).foregroundStyle(.secondary).textSelection(.enabled) }
                    .width(min: 100)
                TableColumn("") { r in
                    if let action = PortAction.for(r.port) {
                        Button(action.title) { model.perform({ try action.open($0) }, on: device) }
                            .controlSize(.small)
                    }
                }
                .width(115)
            }
            .frame(minHeight: 200)
            .overlay {
                if job.results.isEmpty && !job.running && job.progress >= 1 {
                    Text("No open ports found.").foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Copy List") {
                    Exporter.copyToClipboard(job.results.map { "\($0.port)\t\($0.service)\t\($0.banner)" }.joined(separator: "\n"))
                }
                .disabled(job.results.isEmpty)
                SaveToOrgButton(enabled: job.checked > 0 && !job.running) {
                    Drafts.ports(device: device, results: job.results.map { ($0.port, $0.service, $0.banner) }, checked: job.checked)
                }
                Spacer()
                Button("Close") { job.stop(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(job.running ? "Stop" : "Scan") {
                    if job.running { job.stop() } else { job.start(device.ip, model: model) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!job.running && job.mode == .range && Ports.parseList(job.rangeText) == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 480)
        .onDisappear { job.stop() }
    }
}

/// The button next to an open port.
struct PortAction {
    let title: String
    let open: (Device) throws -> Void

    static let webTLS: Set<UInt16> = [443, 4443, 5001, 7443, 8443, 8843, 9443]

    static func `for`(_ port: UInt16) -> PortAction? {
        switch port {
        case 22: return PortAction(title: "Open in Terminal", open: DeviceActions.ssh)
        case 139, 445: return PortAction(title: "Open in Finder", open: DeviceActions.openShares)
        case 3389: return PortAction(title: "Remote Desktop", open: DeviceActions.remoteDesktop)
        case 5900, 5901: return PortAction(title: "Screen Sharing", open: DeviceActions.screenSharing)
        default:
            let tls = webTLS.contains(port)
            guard tls || Banner.httpPorts.contains(port) else { return nil }
            return PortAction(title: "Open in Browser") { d in
                let url = URL(string: "\(tls ? "https" : "http")://\(d.ip):\(port)")!
                guard NSWorkspace.shared.open(url) else { throw DeviceActions.Failure.noApp("Couldn’t open a web browser.") }
            }
        }
    }
}

@MainActor
final class PortScanJob: ObservableObject {
    enum Mode: Hashable { case common, all, range }
    struct Result: Identifiable { let port: UInt16; var service: String; var banner: String; var id: UInt16 { port } }

    @Published var mode: Mode = .common
    @Published var rangeText = "1-1024"
    @Published private(set) var running = false { didSet { Activity.shared.set(activityID, running) } }
    private let activityID = UUID()
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published private(set) var results: [Result] = []
    /// How many ports the last finished scan checked.
    @Published private(set) var checked = 0
    private var flag = CancelFlag()

    func stop() { flag.cancel() }

    func start(_ ip: IPv4, model: ScanModel) {
        let ports: [UInt16]
        switch mode {
        case .common: ports = Ports.common.map(\.port)
        case .all: ports = Array(1...65535)
        case .range:
            guard let list = Ports.parseList(rangeText) else { return }
            ports = list
        }
        let flag = CancelFlag(); self.flag = flag
        running = true; progress = 0; results = []
        status = "Checking \(ports.count) ports…"
        let started = Date()

        Task {
            let chunk = 2000
            var open: [UInt16] = []
            var start = 0
            while start < ports.count, !flag.isCancelled {
                let part = Array(ports[start..<min(start + chunk, ports.count)])
                let t0 = Date()
                var found = await offMain { TCPProbe.openPorts([ip], ports: part, timeout: 1.0, flag: flag)[ip.value] ?? [] }
                // Every connection failing at once (well under the 1 s timeout) means macOS hadn't let
                // ARPradar onto the local network yet (seen right after an update). Wait a moment and try again once.
                if start == 0, found.isEmpty, Date().timeIntervalSince(t0) < 0.3, !flag.isCancelled {
                    status = "Waiting for the network…"
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    found = await offMain { TCPProbe.openPorts([ip], ports: part, timeout: 1.0, flag: flag)[ip.value] ?? [] }
                }
                open += found
                results += found.map { Result(port: $0, service: Self.service($0), banner: "") }
                start += chunk
                progress = Double(min(start, ports.count)) / Double(ports.count)
                status = "\(open.count) open · \(min(start, ports.count)) of \(ports.count) checked"
            }
            let stopped = flag.isCancelled
            if !open.isEmpty {
                status = "Reading what answers on \(open.count) ports…"
                let found = open
                let banners = await offMain { Banner.grabAll(ip: ip, ports: found, timeout: 2) }
                for i in results.indices { results[i].banner = banners[results[i].port] ?? "" }
                model.addPortScan(ip, open: open, banners: banners)
            }
            let secs = String(format: "%.1f", Date().timeIntervalSince(started))
            status = stopped ? "Stopped · \(open.count) open" : "\(open.count) open of \(ports.count) checked in \(secs) s"
            progress = 1
            checked = min(start, ports.count)
            running = false
        }
    }

    static func service(_ port: UInt16) -> String {
        let s = Ports.service(port)
        return s.isEmpty ? (Ports.label(port) == String(port) ? "" : Ports.label(port)) : s
    }
}

import SwiftUI
import UIKit

/// ARPradar for iPhone: runs network scans on an ARPradar Sensor (a Raspberry Pi) over Bluetooth and shows what it
/// found. The phone itself never scans: the sensor does, on whatever Wi-Fi it's on or is told to join.
@main
struct SensorApp: App {
    @StateObject private var archive = ScanArchive.shared
    @StateObject private var router = Router()

    init() {
        DispatchQueue.global(qos: .utility).async { OUIDatabase.shared.loadIfNeeded() }
        let link = SensorLink.shared
        link.onResults = { r in
            let scan = ScanArchive.shared.add(r, sensor: link.sensorName)
            Router.shared?.show(scan.id)
            return "\(r.rows.count) devices in \(String(format: "%.1f", r.seconds)) s"
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(archive)
                .environmentObject(router)
                .onAppear { Router.shared = router }
                // A heatmap file sent from the Mac (AirDrop, Files, Mail).
                .onOpenURL { url in
                    guard url.pathExtension.lowercased() == HeatmapFile.fileExtension else { return }
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    if let d = try? Data(contentsOf: url), let id = try? PhoneHeatmapStore.shared.importFile(d) {
                        router.path = [.heatmap(id)]
                    }
                }
        }
    }
}

enum Route: Hashable {
    case sensor(UUID)
    case scan(UUID)
    case heatmap(UUID)
    case about
}

/// The navigation stack, so a finished scan can open its results from anywhere.
@MainActor
final class Router: ObservableObject {
    static weak var shared: Router?
    @Published var path: [Route] = []

    func show(_ scan: UUID) { path.append(.scan(scan)) }
}

/// Scans kept on the phone (newest first), in Application Support/scans.json. Up to 100.
@MainActor
final class ScanArchive: ObservableObject {
    static let shared = ScanArchive()
    static let limit = 100

    @Published private(set) var scans: [SavedScan] = []
    private let url: URL

    init(folder: URL? = nil) {
        let dir = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("scans.json")
        if let d = try? Data(contentsOf: url) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            scans = (try? dec.decode([SavedScan].self, from: d)) ?? []
        }
    }

    @discardableResult
    func add(_ r: SensorScanResult, sensor: String, date: Date = Date()) -> SavedScan {
        let rows = r.rows.map { row -> SensorRow in
            var row = row
            for keyPath in [\SensorRow.name, \.web, \.upnp, \.snmp, \.snmpName, \.ubnt] {
                row[keyPath: keyPath] = row[keyPath: keyPath].cleanedNetworkText()
            }
            if row.vendor.isEmpty, !row.mac.isEmpty { row.vendor = OUIDatabase.shared.vendor(for: row.mac) }
            return row
        }.sorted { $0.ip < $1.ip }
        let scan = SavedScan(id: UUID(), date: date, sensor: sensor, ssid: r.ssid, range: r.range,
                             seconds: r.seconds, cancelled: r.cancelled, rows: rows)
        scans.insert(scan, at: 0)
        if scans.count > Self.limit { scans.removeLast(scans.count - Self.limit) }
        save()
        return scan
    }

    func scan(_ id: UUID) -> SavedScan? { scans.first { $0.id == id } }

    func delete(_ ids: Set<UUID>) {
        scans.removeAll { ids.contains($0.id) }
        save()
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(scans) else { return }
        try? d.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

struct SavedScan: Codable, Identifiable, Hashable {
    var id: UUID
    var date: Date
    var sensor: String
    var ssid: String
    var range: String
    var seconds: Double
    var cancelled: Bool
    var rows: [SensorRow]

    var title: String { ssid.isEmpty ? (range.isEmpty ? "Scan" : range) : ssid }

    /// The scan as CSV, with the same columns as the Mac app's export where they exist.
    var csv: String {
        let header = ["IP", "Name", "MAC", "Manufacturer", "Description", "Open ports", "Response (ms)", "Web page", "UPnP", "SNMP name", "SNMP description"]
        let rows = rows.map { r in
            [r.ip.description, r.name, r.mac, r.vendor, r.describe, r.ports.map(String.init).joined(separator: " "),
             r.ms.map { String(format: "%.0f", $0) } ?? "", r.web, r.upnp, r.snmpName, r.snmp]
        }
        return CSV.text(header: header, rows: rows)
    }

    /// A file to share: "ARPradar Office Wi-Fi 2026-11-12 0815.csv".
    func csvFile() -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"
        let safe = title.map { "/:\\?%*|\"<>".contains($0) ? "-" : $0 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ARPradar \(String(safe)) \(f.string(from: date)).csv")
        try? csv.data(using: .utf8)?.write(to: url, options: .atomic)
        return url
    }
}

extension SensorRow {
    /// What the device is, from what it said about itself (UniFi model › UPnP model › SNMP › web page title).
    var describe: String {
        [ubnt, upnp, snmpName.isEmpty ? snmp : snmpName, web].first { !$0.isEmpty } ?? ""
    }
    var displayName: String { name.isEmpty ? (describe.isEmpty ? vendor : describe) : name }
}

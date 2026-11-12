import Foundation
import AppKit
import CoreWLAN

// Mac-only parts of the heatmap (the shared data and math are in HeatmapCore.swift).
extension Heatmap {
    /// Several scans at one spot → one reading per access point (average dBm), strongest first.
    static func average(_ scans: [[NearbyNetwork]]) -> [HeatReading] {
        var groups: [String: [NearbyNetwork]] = [:]
        var order: [String] = []
        for scan in scans {
            for n in scan {
                let key = n.bssid.isEmpty ? "\(n.ssid)|\(n.channel)" : n.bssid
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(n)
            }
        }
        return order.compactMap { key -> HeatReading? in
            guard let list = groups[key], let last = list.last else { return nil }
            let avg = Double(list.reduce(0) { $0 + $1.rssi }) / Double(list.count)
            return HeatReading(ssid: last.ssid, bssid: last.bssid, rssi: Int(avg.rounded()), channel: last.channel,
                               band: last.band, widthMHz: last.widthMHz)
        }
        .sorted { $0.rssi > $1.rssi }
    }

    /// UniFi access points on a network map, by access point key: a radio is the AP's when its BSSID is the AP's MAC
    /// or numbered from it (`sameAP`). Without `groups`, by `apKey` of the AP's MAC.
    static func uniFiNames(_ map: NetMap?, groups: [String: String] = [:]) -> [String: String] {
        guard let map else { return [:] }
        var out: [String: String] = [:]
        for n in map.nodes where n.kind == .accessPoint && !n.mac.isEmpty && !n.name.isEmpty {
            let m = NetMapBuilder.mac(n.mac)
            out[apKey(m)] = n.name
            for (bssid, key) in groups where bssid == m || sameAP(bssid, m) { out[key] = n.name }
        }
        return out
    }

    /// A table of the spots, for Save to Organization.
    static func draft(_ survey: HeatSurvey, filter: HeatFilter, coverage: HeatCoverage) -> SavedDraft? {
        guard !survey.spots.isEmpty else { return nil }
        let rows = survey.spots.enumerated().map { i, s -> [String] in
            let mine = s.readings.filter(filter.matches)
            let best = mine.first
            let place = survey.scale.map { sc in
                "\(Int((s.x / sc.pixelsPerUnit).rounded())), \(Int((s.y / sc.pixelsPerUnit).rounded())) \(sc.unit)"
            } ?? "\(Int(s.x)), \(Int(s.y)) px"
            return [String(i + 1), place, best.map { survey.apName($0.bssid, ssid: $0.ssid) } ?? "",
                    best.map { String($0.rssi) } ?? "", best.map { "\($0.channel) · \($0.band)" } ?? "",
                    String(mine.filter { $0.rssi >= -75 }.count), String(s.readings.count),
                    s.pingMs.map { String(format: "%.0f", $0) } ?? "", s.date.formatted(date: .abbreviated, time: .shortened)]
        }
        var summary = "\(survey.spots.count) spots"
        if coverage.measured { summary += String(format: " · %.0f%% good, %.0f%% fair, %.0f%% poor", coverage.good * 100, coverage.fair * 100, coverage.poor * 100) }
        if let s = filter.ssid { summary += " · \(s)" }
        return SavedDraft(kind: .heatmap, title: "Wi-Fi heatmap · \(survey.name)", summary: summary,
                          table: SavedTable(header: ["Spot", "Where", "Best AP", "Signal dBm", "Channel", "APs at −75+", "Networks heard", "Ping ms", "When"],
                                            rows: rows, widths: [6, 14, 26, 11, 14, 12, 15, 9, 20], numberColumns: [0, 3, 5, 6, 7]),
                          heatmapID: survey.id)
    }
}

// MARK: - Storage

@MainActor
final class HeatmapStore: ObservableObject {
    static let shared = HeatmapStore()
    @Published private(set) var surveys: [HeatSurvey] = []
    private var plans: [UUID: NSImage] = [:]
    let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArpSpy", isDirectory: true).appendingPathComponent("Heatmaps", isDirectory: true)
        load()
    }

    func dir(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString, isDirectory: true) }
    /// Drops the remembered plan picture (after plan.png is rewritten).
    func forgetPlan(_ id: UUID) { plans[id] = nil }

    func load() {
        let fm = FileManager.default
        let subs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        surveys = subs.compactMap { d in
            (try? Data(contentsOf: d.appendingPathComponent("heatmap.json"))).flatMap { try? dec.decode(HeatSurvey.self, from: $0) }
        }
        .sorted { $0.created > $1.created }
    }

    func survey(_ id: UUID?) -> HeatSurvey? { surveys.first { $0.id == id } }

    @discardableResult
    func create(name: String) -> UUID {
        let s = HeatSurvey(name: uniqueName(name))
        surveys.insert(s, at: 0)
        write(s)
        return s.id
    }

    func uniqueName(_ base: String) -> String {
        let names = Set(surveys.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    func update(_ id: UUID, _ change: (inout HeatSurvey) -> Void) {
        guard let i = surveys.firstIndex(where: { $0.id == id }) else { return }
        change(&surveys[i])
        write(surveys[i])
    }

    /// Save as New Heatmap: a copy (floor plan, scale, spots, AP names) under a new name, standalone until it's saved
    /// to an organization. The original stays as it is.
    @discardableResult
    func duplicate(_ id: UUID, name: String) -> UUID? {
        guard let s = survey(id) else { return nil }
        var copy = s
        copy.id = UUID(); copy.name = uniqueName(name); copy.created = Date(); copy.orgID = nil
        let fm = FileManager.default
        try? fm.createDirectory(at: dir(copy.id), withIntermediateDirectories: true)
        if let file = s.planFile { try? fm.copyItem(at: dir(id).appendingPathComponent(file), to: dir(copy.id).appendingPathComponent(file)) }
        surveys.insert(copy, at: 0)
        write(copy)
        return copy.id
    }

    /// The heatmap as one .arpheatmap file (for the iPhone, or another Mac).
    func exportFile(_ id: UUID) throws -> Data {
        guard let s = survey(id) else { throw HeatmapFile.Problem(text: "That heatmap is gone.") }
        var files: [String: Data] = [:]
        for name in HeatmapFile.pictureNames {
            if let d = try? Data(contentsOf: dir(id).appendingPathComponent(name)) { files[name] = d }
        }
        var copy = s
        copy.orgID = nil   // organizations are per computer
        return try HeatmapFile.encode(copy, files: files)
    }

    /// Adds a heatmap from an .arpheatmap file. With `replace`, one with the same id (an earlier copy of the same
    /// heatmap) is overwritten, keeping its organization; otherwise it comes in as a new heatmap. Returns its id.
    @discardableResult
    func importFile(_ data: Data, replace: Bool) throws -> UUID {
        var (s, files) = try HeatmapFile.decode(data)
        let fm = FileManager.default
        if let old = survey(s.id), replace {
            s.orgID = old.orgID
            for name in HeatmapFile.pictureNames { try? fm.removeItem(at: dir(s.id).appendingPathComponent(name)) }
        } else {
            if survey(s.id) != nil { s.id = UUID() }
            s.orgID = nil
            s.name = uniqueName(s.name)
        }
        try fm.createDirectory(at: dir(s.id), withIntermediateDirectories: true)
        for (name, d) in files { try d.write(to: dir(s.id).appendingPathComponent(name), options: .atomic) }
        plans[s.id] = nil
        surveys.removeAll { $0.id == s.id }
        surveys.insert(s, at: 0)
        write(s)
        return s.id
    }

    /// True when a heatmap file is a copy of one already here (same id).
    func hasCopy(of data: Data) -> Bool {
        guard let s = try? HeatmapFile.decode(data).survey else { return false }
        return survey(s.id) != nil
    }

    /// Moves the heatmap's folder to the Trash.
    func delete(_ id: UUID) {
        surveys.removeAll { $0.id == id }
        plans[id] = nil
        try? FileManager.default.trashItem(at: dir(id), resultingItemURL: nil)
    }

    private func write(_ s: HeatSurvey) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir(s.id), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        if let data = try? enc.encode(s) { try? data.write(to: dir(s.id).appendingPathComponent("heatmap.json"), options: .atomic) }
    }

    func plan(_ s: HeatSurvey) -> NSImage? {
        guard let file = s.planFile else { return nil }
        if let p = plans[s.id] { return p }
        let img = NSImage(contentsOf: dir(s.id).appendingPathComponent(file))
        plans[s.id] = img
        return img
    }

    /// Uses a picture or PDF (first page) as the floor plan. Spots already measured keep their place on it.
    func setPlan(_ id: UUID, from url: URL) throws {
        guard let png = Self.planPNG(url) else {
            throw NSError(domain: "ARPradar", code: 1, userInfo: [NSLocalizedDescriptionKey: "That file isn’t a picture or PDF ARPradar can read."])
        }
        try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        try png.data.write(to: dir(id).appendingPathComponent("plan.png"), options: .atomic)
        plans[id] = nil
        update(id) { s in
            let fx = png.size.width / s.planWidth, fy = png.size.height / s.planHeight
            for i in s.spots.indices { s.spots[i].x *= fx; s.spots[i].y *= fy }
            if var sc = s.scale { sc.pixelsPerUnit *= (fx + fy) / 2; s.scale = sc }
            s.planWidth = png.size.width; s.planHeight = png.size.height
            s.planFile = "plan.png"
        }
    }

    /// The file as a PNG at most 3000 px on its longest side (PDFs drawn at twice their page size).
    nonisolated static func planPNG(_ url: URL) -> (data: Data, size: CGSize)? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        var size = img.size
        if let bitmap = img.representations.compactMap({ $0 as? NSBitmapImageRep }).first, bitmap.pixelsWide > 0 {
            size = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        } else if size.width > 0, size.height > 0 {
            // A PDF (or other drawing) has no pixels of its own: draw it 3000 pixels across, so thin walls stay sharp.
            let f = 3000 / max(size.width, size.height)
            size = CGSize(width: size.width * f, height: size.height * f)
        }
        guard size.width >= 1, size.height >= 1 else { return nil }
        let f = min(1, 3000 / max(size.width, size.height))
        let w = Int((size.width * f).rounded()), h = Int((size.height * f).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = CGSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return (data, CGSize(width: w, height: h))
    }
}

// MARK: - Measuring a spot

@MainActor
final class HeatMeter: ObservableObject {
    struct Busy: Equatable { var x: Double, y: Double, scan: Int, heard: Int }
    @Published private(set) var busy: Busy? = nil
    @Published private(set) var problem: String? = nil
    static let scans = 3

    /// Takes three scans at this spot (and pings the router, if asked) and returns the spot.
    func measure(x: Double, y: Double, ping: Bool) async -> HeatSpot? {
        guard busy == nil else { return nil }
        problem = nil
        busy = Busy(x: x, y: y, scan: 1, heard: 0)
        defer { busy = nil }
        var scans: [[NearbyNetwork]] = []
        for n in 1...Self.scans {
            busy = Busy(x: x, y: y, scan: n, heard: Set(scans.flatMap { $0.map(\.id) }).count)
            let result: ([NearbyNetwork], String?) = await offMain { WiFiScanner.scanOnce() }
            if let p = result.1 { problem = p; return nil }
            scans.append(result.0)
        }
        let joined: (String, String, String) = await offMain {
            let i = CWWiFiClient.shared().interface()
            return (i?.ssid() ?? "", i?.bssid()?.uppercased() ?? "", i?.interfaceName ?? "")
        }
        var spot = HeatSpot(x: x, y: y, readings: Heatmap.average(scans), joinedSSID: joined.0, joinedBSSID: joined.1)
        if ping, !joined.2.isEmpty {
            spot.pingMs = await offMain {
                guard let router = IPv4(ConnectionInfo.router(joined.2)) else { return nil }
                let times = (0..<3).compactMap { _ in Pinger.sweep([router], timeout: 1, flag: CancelFlag()).values.first }
                return times.isEmpty ? nil : times.reduce(0, +) / Double(times.count)
            }
        }
        return spot
    }
}

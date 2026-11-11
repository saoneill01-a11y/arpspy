import Foundation
import AppKit
import CoreWLAN

// MARK: - What a heatmap keeps

/// One network heard at a spot: the average of the scans taken there.
struct HeatReading: Codable, Hashable, Sendable {
    var ssid: String
    var bssid: String
    var rssi: Int
    var channel: Int
    /// "2.4 GHz", "5 GHz", "6 GHz"
    var band: String
    var widthMHz: Int

    var centre: Double { WiFiText.centre(primary: channel, widthMHz: widthMHz, band: band) }
}

/// One place on the floor plan where the Mac measured.
struct HeatSpot: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// Position in floor-plan pixels.
    var x: Double
    var y: Double
    var date = Date()
    var readings: [HeatReading]
    /// The network the Mac was joined to while measuring.
    var joinedSSID = ""
    var joinedBSSID = ""
    /// Average ping to the router, if asked for.
    var pingMs: Double? = nil
}

struct HeatScale: Codable, Hashable, Sendable {
    /// Floor-plan pixels per foot (or per metre).
    var pixelsPerUnit: Double
    var metres = false
    var unit: String { metres ? "m" : "ft" }
}

/// A floor plan and the spots measured on it. Saved in ~/Library/Application Support/ArpSpy/Heatmaps/<id>/.
struct HeatSurvey: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var created = Date()
    /// The plan's size in pixels (a blank grid when there's no plan picture).
    var planWidth: Double = HeatSurvey.blankSize.width
    var planHeight: Double = HeatSurvey.blankSize.height
    /// "plan.png" in the heatmap's folder; nil = blank grid.
    var planFile: String? = nil
    var scale: HeatScale? = nil
    var spots: [HeatSpot] = []
    /// Names given to access points, by access point (`Heatmap.apKey`; older heatmaps have them by BSSID).
    var apNames: [String: String] = [:]
    /// Where access points really are, placed by hand on the Map tab (plan pixels), by access point.
    var apPlaces: [String: HeatPlace] = [:]
    /// Radios combined or separated by hand (BSSID → the access point it belongs to), over the automatic grouping.
    var apOverrides: [String: String] = [:]
    /// "base.png": the Apple Maps picture the plan was made from (kept so a floor plan can be laid over it).
    var baseFile: String? = nil
    /// A floor plan laid over the map picture: where it sits. Its picture is overlay.png (background removed) and
    /// overlay-original.png (as loaded); plan.png is the two combined.
    var overlay: HeatOverlay? = nil
    /// The network shown; nil = the one the Mac was joined to.
    var network: String? = nil
    var orgID: UUID? = nil

    static let blankSize = CGSize(width: 1600, height: 1000)

    init(name: String) { self.name = name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Heatmap"
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        planWidth = try c.decodeIfPresent(Double.self, forKey: .planWidth) ?? Self.blankSize.width
        planHeight = try c.decodeIfPresent(Double.self, forKey: .planHeight) ?? Self.blankSize.height
        planFile = try c.decodeIfPresent(String.self, forKey: .planFile)
        scale = try c.decodeIfPresent(HeatScale.self, forKey: .scale)
        spots = try c.decodeIfPresent([HeatSpot].self, forKey: .spots) ?? []
        apNames = try c.decodeIfPresent([String: String].self, forKey: .apNames) ?? [:]
        apPlaces = try c.decodeIfPresent([String: HeatPlace].self, forKey: .apPlaces) ?? [:]
        apOverrides = try c.decodeIfPresent([String: String].self, forKey: .apOverrides) ?? [:]
        baseFile = try c.decodeIfPresent(String.self, forKey: .baseFile)
        overlay = try c.decodeIfPresent(HeatOverlay.self, forKey: .overlay)
        network = try c.decodeIfPresent(String.self, forKey: .network)
        orgID = try c.decodeIfPresent(UUID.self, forKey: .orgID)
    }

    /// The network to show: the chosen one, else the one joined at most spots.
    var shownNetwork: String? {
        if let network { return network.isEmpty ? nil : network }
        let joined = spots.map(\.joinedSSID).filter { !$0.isEmpty }
        return Dictionary(grouping: joined, by: { $0 }).max { $0.value.count < $1.value.count }?.key
    }

    /// Every network name heard, most-heard first.
    var networkNames: [String] {
        var count: [String: Int] = [:]
        for s in spots { for r in Set(s.readings.map(\.ssid)) where !r.isEmpty { count[r, default: 0] += 1 } }
        return count.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
    }

    /// The access point a radio belongs to: its name (given here, or from UniFi), else "Network …AB:CD".
    /// Every radio heard → the access point it belongs to.
    var apGroups: [String: String] { Heatmap.cachedGroups(self) }

    func apName(_ bssid: String, ssid: String) -> String {
        let groups = apGroups
        let key = groups[bssid.uppercased()] ?? Heatmap.apKey(bssid)
        if let n = apNames[key], !n.isEmpty { return n }
        if let n = apNames[bssid], !n.isEmpty { return n }
        // A name given to another radio of the same access point (or under an older grouping) names it too.
        let radios = groups.filter { $0.value == key }.map(\.key)
        for r in radios {
            if let n = apNames[r], !n.isEmpty { return n }
            if let n = apNames[Heatmap.apKey(r)], !n.isEmpty { return n }
        }
        // A name given to a radio numbered from this one (heard or not).
        if let n = apNames.first(where: { $0.key.count == 17 && (Heatmap.apKey($0.key) == Heatmap.apKey(bssid) || Heatmap.sameAP($0.key, bssid.uppercased())) })?.value,
           !n.isEmpty { return n }
        let tail = bssid.split(separator: ":").suffix(2).joined(separator: ":")
        return tail.isEmpty ? (ssid.isEmpty ? "Hidden network" : ssid) : "\(ssid.isEmpty ? "AP" : ssid) …\(tail)"
    }

    /// "12 ft" from plan pixels, when the scale is set.
    func length(_ pixels: Double) -> String? {
        guard let s = scale, s.pixelsPerUnit > 0 else { return nil }
        return "\(Int((pixels / s.pixelsPerUnit).rounded())) \(s.unit)"
    }
}

// MARK: - What the map shows

enum HeatMode: String, CaseIterable, Identifiable, Sendable {
    case signal = "Best signal"
    case oneAP = "One access point"
    case apCount = "Access points heard"
    case overlap = "Channel overlap"
    case ping = "Ping to router"
    var id: String { rawValue }

    var isSignal: Bool { self == .signal || self == .oneAP }

    /// Legend: the values at the bad end, a third of the way, two thirds, and the good end.
    var legend: [String] {
        switch self {
        case .signal, .oneAP: return ["−85", "−75", "−67", "−60", "−45 dBm"]
        case .apCount: return ["0", "1", "2", "3+ APs at −75 or better"]
        case .overlap: return ["3+", "2", "1", "0 networks on the same channel"]
        case .ping: return ["100+", "60", "30", "10 ms"]
        }
    }
}

enum HeatBand: String, CaseIterable, Identifiable, Sendable {
    case all = "All", b24 = "2.4", b5 = "5", b6 = "6 GHz"
    var id: String { rawValue }
    func matches(_ band: String) -> Bool {
        switch self {
        case .all: return true
        case .b24: return band == "2.4 GHz"
        case .b5: return band == "5 GHz"
        case .b6: return band == "6 GHz"
        }
    }
}

struct HeatFilter: Hashable, Sendable {
    /// nil = every network.
    var ssid: String?
    var band: HeatBand = .all
    /// For .oneAP: the access point, and its radios (when given, they decide; otherwise radios are matched by `apKey`).
    var bssid: String? = nil
    var radios: Set<String> = []

    func matches(_ r: HeatReading) -> Bool {
        (ssid == nil || r.ssid == ssid) && band.matches(r.band)
    }
}

/// A point on the plan (plan pixels).
struct HeatPlace: Codable, Hashable, Sendable { var x: Double, y: Double }

/// One access point: all the radios (bands, network names) it broadcasts, grouped.
struct HeatAP: Identifiable, Hashable, Sendable {
    var id: String { key }
    /// `Heatmap.apKey` of its radios.
    var key: String
    /// Its loudest radio (for the name, channel and band shown).
    var bssid: String, ssid: String
    var channel: Int, band: String, widthMHz: Int
    var best: Int
    var spotsHeard: Int
    /// Where it is (plan pixels): placed by hand, or guessed from the spots it was loudest at, weighted by power.
    var x: Double, y: Double
    var placed = false
    var radios = 1
    var bands: [String] = []
    /// Its radios' BSSIDs.
    var radioList: [String] = []
    /// Its loudest reading on each band (that band's channel and width), 2.4 GHz first.
    var bandReadings: [HeatReading] = []
    /// A guess from fewer than 3 spots is too rough to draw.
    var worthShowing: Bool { placed || spotsHeard >= 3 }
}

struct HeatGrid: Sendable {
    var cols: Int, rows: Int
    /// Per cell: the value there, or nil where nothing was measured close by.
    var values: [Double?]
    /// Per cell: 1 near measured spots, fading to 0 at the edge of what was measured.
    var alpha: [Double]
}

struct HeatCoverage: Hashable, Sendable {
    var good = 0.0, fair = 0.0, poor = 0.0
    var measured: Bool { good + fair + poor > 0 }
}

struct HeatFinding: Hashable, Sendable {
    enum Level: Sendable { case good, warn, bad, info }
    var level: Level
    var text: String
    var spot: UUID? = nil
}

// MARK: - The math

enum Heatmap {
    /// What "no signal" counts as when a spot didn't hear the network at all.
    static let silent = -95.0

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

    /// Two networks share air when their channels overlap in the same band.
    static func overlaps(_ a: HeatReading, _ b: HeatReading) -> Bool {
        guard a.band == b.band, a.channel > 0, b.channel > 0 else { return false }
        // Channel numbers are 5 MHz apart; 2.4 GHz channels are about 22 MHz wide.
        let wa = a.band == "2.4 GHz" ? max(a.widthMHz, 22) : a.widthMHz
        let wb = b.band == "2.4 GHz" ? max(b.widthMHz, 22) : b.widthMHz
        return abs(a.centre - b.centre) < Double(wa + wb) / 10 - 0.01
    }

    /// The value one spot contributes to the map.
    static func value(_ spot: HeatSpot, mode: HeatMode, filter: HeatFilter) -> Double? {
        let mine = spot.readings.filter(filter.matches)
        switch mode {
        case .signal:
            return mine.map { Double($0.rssi) }.max() ?? silent
        case .oneAP:
            guard let b = filter.bssid else { return nil }   // an access point: its loudest radio here
            let mine = spot.readings.filter { (filter.radios.isEmpty ? apKey($0.bssid) == b : filter.radios.contains($0.bssid.uppercased())) && filter.band.matches($0.band) }
            return mine.map { Double($0.rssi) }.max() ?? silent
        case .apCount:
            return Double(mine.filter { $0.rssi >= -75 }.count)
        case .overlap:
            guard let best = mine.max(by: { $0.rssi < $1.rssi }) else { return nil }
            let others = spot.readings.filter { $0.ssid != best.ssid && $0.rssi >= -82 && overlaps($0, best) }
            return Double(Set(others.map { $0.ssid.isEmpty ? $0.bssid : $0.ssid }).count)
        case .ping:
            return spot.pingMs
        }
    }

    /// 0 (bad) … 1 (good) for a value, by mode.
    static func level(_ v: Double, mode: HeatMode) -> Double {
        func ramp(_ points: [(Double, Double)]) -> Double {
            if v <= points[0].0 { return points[0].1 }
            for (a, b) in zip(points, points.dropFirst()) where v <= b.0 {
                return a.1 + (b.1 - a.1) * (v - a.0) / (b.0 - a.0)
            }
            return points[points.count - 1].1
        }
        switch mode {
        case .signal, .oneAP: return ramp([(-85, 0), (-75, 0.25), (-67, 0.5), (-60, 0.75), (-45, 1)])
        case .apCount: return ramp([(0, 0), (1, 0.33), (2, 0.66), (3, 1)])
        case .overlap: return ramp([(0, 1), (1, 0.6), (2, 0.33), (3, 0)])
        case .ping: return ramp([(10, 1), (30, 0.66), (60, 0.33), (100, 0)])
        }
    }

    /// Red → orange → yellow → green, for a 0…1 level.
    static func color(_ level: Double) -> (r: Double, g: Double, b: Double) {
        let stops: [(Double, (Double, Double, Double))] = [
            (0, (0xE2, 0x46, 0x3C)), (0.25, (0xEF, 0x8A, 0x2B)), (0.5, (0xF1, 0xC2, 0x32)),
            (0.75, (0x5D, 0xBB, 0x3F)), (1, (0x15, 0x94, 0x47)),
        ]
        let l = min(max(level, 0), 1)
        for (a, b) in zip(stops, stops.dropFirst()) where l <= b.0 {
            let t = (l - a.0) / (b.0 - a.0)
            return ((a.1.0 + (b.1.0 - a.1.0) * t) / 255, (a.1.1 + (b.1.1 - a.1.1) * t) / 255, (a.1.2 + (b.1.2 - a.1.2) * t) / 255)
        }
        return (0x15 / 255.0, 0x94 / 255.0, 0x47 / 255.0)
    }

    /// How far from a measured spot the map still shows a colour, in plan pixels: about 35 ft when the scale
    /// is set, else worked out from how far apart the spots are.
    static func reach(_ survey: HeatSurvey) -> Double {
        let longest = max(survey.planWidth, survey.planHeight)
        if let s = survey.scale, s.pixelsPerUnit > 0 { return s.pixelsPerUnit * (s.metres ? 10.5 : 35) }
        let pts = survey.spots
        guard pts.count > 1 else { return longest * 0.15 }
        let nearest = pts.map { p in
            pts.filter { $0.id != p.id }.map { hypot($0.x - p.x, $0.y - p.y) }.min() ?? 0
        }.sorted()
        let median = nearest[nearest.count / 2]
        return min(max(median * 2.5, longest * 0.12), longest * 0.35)
    }

    /// Inverse-distance blend of the spots' values over a grid `cols` wide.
    static func grid(_ points: [(x: Double, y: Double, v: Double)], width: Double, height: Double, cols: Int, reach: Double) -> HeatGrid {
        let cols = max(cols, 2)
        let cell = width / Double(cols)
        let rows = max(Int((height / cell).rounded(.up)), 2)
        var values = [Double?](repeating: nil, count: cols * rows)
        var alpha = [Double](repeating: 0, count: cols * rows)
        guard !points.isEmpty, reach > 0 else { return HeatGrid(cols: cols, rows: rows, values: values, alpha: alpha) }
        // Softened weights (1 / (d² + s²)) blend neighboring spots instead of drawing a ring around each one.
        let soft = reach * 0.18
        for row in 0..<rows {
            let y = (Double(row) + 0.5) * cell
            for col in 0..<cols {
                let x = (Double(col) + 0.5) * cell
                var sumW = 0.0, sumV = 0.0, nearest = Double.infinity
                for p in points {
                    let d = hypot(p.x - x, p.y - y)
                    nearest = min(nearest, d)
                    guard d < reach * 1.5 else { continue }
                    let w = 1 / (d * d + soft * soft)
                    sumW += w; sumV += w * p.v
                }
                guard nearest <= reach, sumW > 0 else { continue }
                let i = row * cols + col
                values[i] = sumV / sumW
                alpha[i] = nearest <= reach * 0.7 ? 1 : max(0, 1 - (nearest - reach * 0.7) / (reach * 0.3))
            }
        }
        return HeatGrid(cols: cols, rows: rows, values: values, alpha: alpha)
    }

    static func grid(_ survey: HeatSurvey, mode: HeatMode, filter: HeatFilter, cols: Int = 180) -> HeatGrid {
        let pts = survey.spots.compactMap { s in value(s, mode: mode, filter: filter).map { (x: s.x, y: s.y, v: $0) } }
        return grid(pts, width: survey.planWidth, height: survey.planHeight, cols: cols, reach: reach(survey))
    }

    /// Share of the measured area that's good (−67 dBm or better), fair (to −75) and poor.
    static func coverage(_ g: HeatGrid) -> HeatCoverage {
        var good = 0.0, fair = 0.0, poor = 0.0
        for (v, a) in zip(g.values, g.alpha) {
            guard let v, a > 0.5 else { continue }
            if v >= -67 { good += 1 } else if v >= -75 { fair += 1 } else { poor += 1 }
        }
        let total = good + fair + poor
        guard total > 0 else { return HeatCoverage() }
        return HeatCoverage(good: good / total, fair: fair / total, poor: poor / total)
    }

    /// The access points heard on the chosen network and band, loudest first.
    /// Which access point a radio belongs to. One access point broadcasts a BSSID per band and per network name;
    /// they share the middle of the address and differ in the first byte (UniFi and others set "locally
    /// administered" bits there) or in the last few bits of the last byte (Cisco, Aruba, Ruckus count up from a base).
    /// So the key is bytes 2–5 plus the top half of byte 6. Not a BSSID: "AC:B9:12:34:5".
    static func apKey(_ bssid: String) -> String {
        let parts = bssid.uppercased().split(separator: ":").map(String.init)
        guard parts.count == 6, let last = UInt8(parts[5], radix: 16) else { return bssid.uppercased() }
        return parts[1...4].joined(separator: ":") + ":" + String(last >> 4, radix: 16, uppercase: true)
    }

    /// An access point's loudest reading per band.
    static func bandBest(_ spots: [HeatSpot], radios: Set<String>, filter: HeatFilter) -> [HeatReading] {
        var best: [String: HeatReading] = [:]
        for s in spots {
            for r in s.readings where radios.contains(r.bssid.uppercased()) && filter.matches(r) {
                if let b = best[r.band], b.rssi >= r.rssi { continue }
                best[r.band] = r
            }
        }
        return best.values.sorted { $0.band < $1.band }
    }

    /// Two of your access points on the same (or an overlapping) channel in one band.
    struct ChannelClash: Hashable, Sendable {
        var a: String, b: String
        var band: String
        var channelA: Int, channelB: Int
        /// "ch 36" or "ch 36 and 40"
        var label: String { channelA == channelB ? "ch \(channelA)" : "ch \(channelA) and \(channelB)" }
    }

    /// Every pair of access points that share a channel on some band. Each pair hears the other's traffic as noise and
    /// they take turns talking, so where both reach, both are slower.
    static func channelClashes(_ aps: [HeatAP]) -> [ChannelClash] {
        var out: [ChannelClash] = []
        for (i, x) in aps.enumerated() {
            for y in aps.dropFirst(i + 1) {
                for rx in x.bandReadings {
                    for ry in y.bandReadings where overlaps(rx, ry) {
                        out.append(ChannelClash(a: x.key, b: y.key, band: rx.band, channelA: rx.channel, channelB: ry.channel))
                    }
                }
            }
        }
        return out
    }

    /// Whether two radios are probably the same access point. Makers number an AP's radios from one address by:
    /// - counting up the last byte (Cisco, Aruba, Ruckus, Ubiquiti's newer APs: …2C:71 / 2C:72 / 2C:73),
    /// - stepping a middle byte (Ubiquiti's older APs: 74:AC:B9:**2D**:B6:12 and 74:AC:B9:**2E**:B6:12),
    /// - changing the first byte's "locally administered" bits (7A:… / 76:… for extra network names),
    /// or the first and last together. Anything else is a different AP. Combine / Separate by hand fixes a wrong guess.
    static func sameAP(_ a: String, _ b: String) -> Bool {
        func bytes(_ s: String) -> [Int]? {
            let p = s.split(separator: ":").compactMap { Int($0, radix: 16) }
            return p.count == 6 ? p : nil
        }
        guard let x = bytes(a), let y = bytes(b) else { return false }
        let diff = (0..<6).filter { x[$0] != y[$0] }
        func last() -> Bool { abs(x[5] - y[5]) <= 15 && (x[5] >> 4 == y[5] >> 4 || abs(x[5] - y[5]) <= 3) }
        func first() -> Bool { (x[0] ^ y[0]) & 0x01 == 0 }      // never the multicast bit
        switch diff {
        case []: return true
        case [5]: return last()
        case [3], [4]: return abs(x[diff[0]] - y[diff[0]]) <= 2
        case [0]: return first()
        case [0, 5]: return first() && last()
        default: return false
        }
    }

    /// Radio (BSSID) → its access point's key. Automatic grouping by `sameAP`, then `overrides` (Combine / Separate)
    /// on top. An automatic group's key is the `apKey` of its lowest BSSID, so names and positions saved earlier still
    /// find it.
    static func groups(_ bssids: some Sequence<String>, overrides: [String: String] = [:]) -> [String: String] {
        let list = Array(Set(bssids.map { $0.uppercased() })).sorted()
        var parent = Array(list.indices)
        func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
        for i in list.indices where overrides[list[i]] == nil {
            for j in list.indices where j > i && overrides[list[j]] == nil && sameAP(list[i], list[j]) {
                let a = root(i), b = root(j)
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        }
        var out: [String: String] = [:]
        for (i, r) in list.enumerated() { out[r] = overrides[r] ?? apKey(list[root(i)]) }
        return out
    }

    /// `groups` for a heatmap, remembered until its spots or overrides change (names are looked up often).
    private final class GroupCache: @unchecked Sendable {
        let lock = NSLock(); var map: [String: [String: String]] = [:]
    }
    private static let groupCache = GroupCache()
    static func cachedGroups(_ s: HeatSurvey) -> [String: String] {
        let key = "\(s.id)|\(s.spots.count)|\(s.spots.last?.id.uuidString ?? "")|\(s.apOverrides.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))"
        groupCache.lock.lock(); defer { groupCache.lock.unlock() }
        if let hit = groupCache.map[key] { return hit }
        let g = groups(s.spots.flatMap { $0.readings.map(\.bssid) }.filter { !$0.isEmpty }, overrides: s.apOverrides)
        if groupCache.map.count > 50 { groupCache.map.removeAll() }
        groupCache.map[key] = g
        return g
    }

    /// Plan pixels per foot (or metre) for a plan that's `metresWide` across in real life.
    static func pixelsPerUnit(planWidth: Double, metresWide: Double, metres: Bool) -> Double {
        planWidth / (metres ? metresWide : metresWide * 3.280839895)
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

    static func accessPoints(_ spots: [HeatSpot], filter: HeatFilter, placed: [String: HeatPlace] = [:],
                             overrides: [String: String] = [:]) -> [HeatAP] {
        let groups = groups(spots.flatMap { $0.readings.map(\.bssid) }.filter { !$0.isEmpty }, overrides: overrides)
        // Each access point's loudest radio at each spot.
        var heard: [String: [UUID: (spot: HeatSpot, r: HeatReading)]] = [:]
        var radios: [String: Set<String>] = [:]
        for s in spots {
            for r in s.readings where filter.matches(r) && !r.bssid.isEmpty {
                let key = groups[r.bssid.uppercased()] ?? apKey(r.bssid)
                radios[key, default: []].insert(r.bssid.uppercased())
                if let have = heard[key]?[s.id], have.r.rssi >= r.rssi { continue }
                heard[key, default: [:]][s.id] = (s, r)
            }
        }
        return heard.compactMap { key, bySpot -> HeatAP? in
            let list = Array(bySpot.values)
            guard let loudest = list.max(by: { $0.r.rssi < $1.r.rssi }) else { return nil }
            let top = list.sorted { $0.r.rssi > $1.r.rssi }.prefix(3)
            let weights = top.map { pow(10, Double($0.r.rssi) / 10) }
            let total = weights.reduce(0, +)
            var x = zip(top, weights).reduce(0) { $0 + $1.0.spot.x * $1.1 } / total
            var y = zip(top, weights).reduce(0) { $0 + $1.0.spot.y * $1.1 } / total
            let mine = radios[key] ?? []
            // A position placed under an earlier grouping still counts.
            let place = placed[key] ?? mine.lazy.compactMap { placed[apKey($0)] ?? placed[$0] }.first
            if let p = place { x = p.x; y = p.y }
            let bands = Set(spots.flatMap { $0.readings }.filter { mine.contains($0.bssid.uppercased()) && filter.matches($0) }.map(\.band))
            return HeatAP(key: key, bssid: loudest.r.bssid, ssid: loudest.r.ssid, channel: loudest.r.channel, band: loudest.r.band,
                          widthMHz: loudest.r.widthMHz, best: loudest.r.rssi, spotsHeard: list.count, x: x, y: y,
                          placed: place != nil, radios: mine.count, bands: bands.sorted(), radioList: mine.sorted(),
                          bandReadings: bandBest(spots, radios: mine, filter: filter))
        }
        .sorted { ($0.best, $1.key) > ($1.best, $0.key) }
    }

    /// Networks heard that aren't the chosen one.
    static func neighborCount(_ spots: [HeatSpot], filter: HeatFilter) -> Int {
        guard let ssid = filter.ssid else { return 0 }
        return Set(spots.flatMap { $0.readings.filter { $0.ssid != ssid && filter.band.matches($0.band) }.map { $0.bssid.isEmpty ? $0.ssid : $0.bssid } }).count
    }

    /// Plain-language notes about the map.
    static func findings(_ survey: HeatSurvey, filter: HeatFilter, coverage: HeatCoverage) -> [HeatFinding] {
        var out: [HeatFinding] = []
        let spots = survey.spots
        if spots.count < 5 {
            out.append(HeatFinding(level: .info, text: "Measure at least 5 spots, about every 10–15 ft, for a useful map."))
        }
        guard !spots.isEmpty else { return out }
        let signal = spots.map { ($0, value($0, mode: .signal, filter: filter) ?? silent) }
        if let weakest = signal.min(by: { $0.1 < $1.1 }), weakest.1 < -75 {
            let dBm = weakest.1 <= silent ? "nothing heard" : "\(Int(weakest.1)) dBm".replacingOccurrences(of: "-", with: "−")
            var text = "Weakest spot: \(dBm) (marked on the map)."
            if coverage.poor >= 0.05 { text = "\(Int((coverage.poor * 100).rounded()))% of the measured area is below −75 dBm. " + text }
            out.append(HeatFinding(level: .bad, text: text, spot: weakest.0.id))
        } else if spots.count >= 5 {
            out.append(HeatFinding(level: .good, text: "Every spot measured −75 dBm or better" + (signal.allSatisfy { $0.1 >= -67 } ? ", and all are −67 or better." : ".")))
        }
        guard let ssid = filter.ssid else { return out }
        let aps = accessPoints(spots, filter: HeatFilter(ssid: filter.ssid, band: filter.band), overrides: survey.apOverrides)
        let groups = cachedGroups(survey)
        func groupOf(_ bssid: String) -> String { groups[bssid.uppercased()] ?? apKey(bssid) }
        // Neighbors on an own AP's channel, heard where that AP is useful.
        for ap in aps {
            let r = HeatReading(ssid: ap.ssid, bssid: ap.bssid, rssi: ap.best, channel: ap.channel, band: ap.band, widthMHz: ap.widthMHz)
            var neighbors = Set<String>()
            for s in spots where s.readings.contains(where: { $0.bssid == ap.bssid && $0.rssi >= -75 }) {
                for n in s.readings where n.ssid != ssid && n.rssi >= -82 && overlaps(n, r) { neighbors.insert(n.ssid.isEmpty ? n.bssid : n.ssid) }
            }
            if neighbors.count >= 2 {
                out.append(HeatFinding(level: .warn, text: "\(survey.apName(ap.bssid, ssid: ap.ssid)) shares channel \(ap.channel) with \(neighbors.count) neighbor networks."))
            }
        }
        // Own APs on the same channel, both strong at one spot.
        var pairs = Set<String>()
        for s in spots {
            let strong = s.readings.filter { $0.ssid == ssid && $0.rssi >= -72 && filter.band.matches($0.band) }
            for (i, a) in strong.enumerated() {
                for b in strong.dropFirst(i + 1) where groupOf(a.bssid) != groupOf(b.bssid) && overlaps(a, b) {
                    let key = [groupOf(a.bssid), groupOf(b.bssid)].sorted().joined(separator: "|")
                    guard pairs.insert(key).inserted else { continue }
                    out.append(HeatFinding(level: .warn, text: "\(survey.apName(a.bssid, ssid: a.ssid)) and \(survey.apName(b.bssid, ssid: b.ssid)) are both on channel \(a.channel) and loud in the same place."))
                }
            }
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
        } else {
            size = CGSize(width: size.width * 2, height: size.height * 2)
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

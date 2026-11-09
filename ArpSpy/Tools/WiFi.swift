import Foundation
import CoreWLAN
import CoreLocation

/// macOS only shows Wi-Fi network names (SSID/BSSID) to apps the user has allowed to use Location.
/// ARPradar never reads the location itself.
@MainActor
final class LocationPermission: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationPermission()
    private let manager = CLLocationManager()
    @Published private(set) var status: CLAuthorizationStatus

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var allowed: Bool { status == .authorizedAlways || status == .authorized }
    var undecided: Bool { status == .notDetermined }

    func ask() { manager.requestWhenInUseAuthorization() }

    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        let s = m.authorizationStatus
        Task { @MainActor in self.status = s }
    }
}

enum WiFiText {
    static func band(_ c: CWChannel?) -> String {
        switch c?.channelBand {
        case .band2GHz: return "2.4 GHz"
        case .band5GHz: return "5 GHz"
        case .band6GHz: return "6 GHz"
        default: return ""
        }
    }

    static func widthMHz(_ c: CWChannel?) -> Int {
        switch c?.channelWidth {
        case .width40MHz: return 40
        case .width80MHz: return 80
        case .width160MHz: return 160
        default: return 20
        }
    }

    static let securityNames: [(CWSecurity, String)] = [
        (.wpa3Enterprise, "WPA3 Enterprise"), (.wpa3Personal, "WPA3 Personal"), (.wpa3Transition, "WPA2/WPA3 Personal"),
        (.wpa2Enterprise, "WPA2 Enterprise"), (.enterprise, "Enterprise"), (.wpa2Personal, "WPA2 Personal"),
        (.personal, "WPA/WPA2 Personal"), (.wpaPersonal, "WPA Personal"), (.OWE, "Enhanced Open"),
        (.dynamicWEP, "Dynamic WEP"), (.WEP, "WEP"), (.none, "Open"),
    ]

    static func security(_ s: CWSecurity) -> String { securityNames.first { $0.0 == s }?.1 ?? "" }
    static func security(of n: CWNetwork) -> String { securityNames.first { n.supportsSecurity($0.0) }?.1 ?? "" }

    /// The centre channel of a wide channel (CoreWLAN reports the primary 20 MHz channel).
    static func centre(primary ch: Int, widthMHz: Int, band: String) -> Double {
        guard widthMHz > 20 else { return Double(ch) }
        if band == "6 GHz" {
            let size = widthMHz / 20
            let start = (ch - 1) / 4 / size * size
            return Double(1 + 4 * start + 2 * (size - 1))
        }
        if band == "5 GHz" {
            let blocks: [Int: [ClosedRange<Int>]] = [
                40: [36...40, 44...48, 52...56, 60...64, 100...104, 108...112, 116...120, 124...128, 132...136, 140...144, 149...153, 157...161, 165...169],
                80: [36...48, 52...64, 100...112, 116...128, 132...144, 149...161, 165...177],
                160: [36...64, 100...128, 149...177],
            ]
            if let r = blocks[widthMHz]?.first(where: { $0.contains(ch) }) { return Double(r.lowerBound + r.upperBound) / 2 }
        }
        return Double(ch)
    }

    /// Signal colour bands, in dBm.
    static func quality(_ rssi: Int) -> String { rssi >= -67 ? "good" : rssi >= -75 ? "fair" : "poor" }
}

// MARK: - Live signal

@MainActor
final class WiFiMonitor: ObservableObject {
    struct Sample: Identifiable { let id = UUID(); let time: Date; let rssi: Int; let noise: Int; let bssid: String }

    @Published private(set) var rssi = 0
    @Published private(set) var noise = 0
    @Published private(set) var rate = 0.0
    @Published private(set) var ssid = ""
    @Published private(set) var bssid = ""
    @Published private(set) var channel = ""
    @Published private(set) var security = ""
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var roams: [Date] = []
    @Published private(set) var available = true
    private var timer: Timer?

    func start() {
        poll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        guard let i = CWWiFiClient.shared().interface(), i.powerOn() else { available = false; return }
        let r = i.rssiValue()
        guard r != 0 else { available = false; return }      // not joined to a network
        available = true
        rssi = r; noise = i.noiseMeasurement(); rate = i.transmitRate()
        ssid = i.ssid() ?? ""
        let b = i.bssid()?.uppercased() ?? ""
        if !bssid.isEmpty, !b.isEmpty, b != bssid { roams.append(Date()) }
        bssid = b
        let ch = i.wlanChannel()
        channel = ch.map { "\($0.channelNumber) · \(WiFiText.band($0)) · \(WiFiText.widthMHz($0)) MHz" } ?? ""
        security = WiFiText.security(i.security())
        samples.append(Sample(time: Date(), rssi: r, noise: noise, bssid: b))
        if samples.count > 300 { samples.removeFirst(samples.count - 300) }
        let cutoff = Date().addingTimeInterval(-300)
        roams.removeAll { $0 < cutoff }
    }
}

// MARK: - Nearby networks

struct NearbyNetwork: Identifiable, Hashable {
    let id: String          // BSSID, or a made-up key when macOS hides it
    let ssid: String, bssid: String
    let rssi: Int, channel: Int, band: String, widthMHz: Int, security: String
    var centre: Double { WiFiText.centre(primary: channel, widthMHz: widthMHz, band: band) }
    var isMine = false
}

@MainActor
final class WiFiScanner: ObservableObject {
    @Published private(set) var networks: [NearbyNetwork] = []
    @Published private(set) var scanning = false
    @Published private(set) var lastScan: Date? = nil
    @Published private(set) var problem: String? = nil
    private var timer: Timer?

    /// Seconds between scans. A CoreWLAN scan takes the radio off its channel for a moment, so the Mac's own
    /// Wi-Fi stalls each time; every 20 s keeps the chart fresh without making the connection feel broken.
    static let every: TimeInterval = 20

    func start() {
        scan()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in Task { @MainActor in self?.scan() } }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func scan() {
        guard !scanning else { return }
        scanning = true
        Task {
            let result: ([NearbyNetwork], String?) = await offMain { Self.scanOnce() }
            scanning = false
            if result.1 == nil || networks.isEmpty { networks = result.0 }
            problem = result.1
            lastScan = Date()
        }
    }

    /// "Channel 6 is the busiest; channel 1 has the least overlap." for 2.4 GHz.
    nonisolated static func advice(_ list: [NearbyNetwork], band: String) -> String? {
        let candidates: [Int]
        switch band {
        case "2.4 GHz": candidates = [1, 6, 11]
        case "5 GHz": candidates = [36, 52, 100, 116, 132, 149]
        default: return nil
        }
        let nets = list.filter { $0.band == band && !$0.isMine }
        guard nets.count >= 2 else { return nil }
        func load(_ ch: Int) -> Double {
            nets.reduce(0) { sum, n in
                let half = Double(n.widthMHz) / 10        // channel numbers are 5 MHz apart
                let reach = band == "2.4 GHz" ? 4.0 : half
                return abs(n.centre - Double(ch)) < reach ? sum + pow(10, Double(n.rssi) / 10) : sum
            }
        }
        let loads = candidates.map { ($0, load($0)) }
        guard let busiest = loads.max(by: { $0.1 < $1.1 }), let quiet = loads.min(by: { $0.1 < $1.1 }),
              busiest.0 != quiet.0, busiest.1 > 0 else { return nil }
        return "Channel \(busiest.0) is the busiest here; channel \(quiet.0) has the least overlap."
    }
}

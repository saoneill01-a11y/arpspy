import CoreBluetooth
import CryptoKit
import Foundation

/// The ARPradar Sensor (a Raspberry Pi running arpradar-sensor; source in the arpradar-windows repo, sensor/) over
/// Bluetooth LE. Protocol: sensor/src/link.rs. Ownership works like adopting a UniFi device: the first app to connect
/// claims it (an X25519 key exchange) and keeps the owner secret (SensorKeychain: a 0600 file in Application Support); the sensor ignores other apps
/// until the owner releases it. Every command and every result is AES-GCM encrypted with a key from that secret.
enum SensorProtocol {
    static let service = CBUUID(string: "41525052-4144-4152-0000-000000000001")
    static let info = CBUUID(string: "41525052-4144-4152-0000-000000000002")
    static let command = CBUUID(string: "41525052-4144-4152-0000-000000000003")
    static let events = CBUUID(string: "41525052-4144-4152-0000-000000000004")

    static func hmac(_ key: Data, _ parts: Data...) -> Data {
        var m = HMAC<SHA256>(key: SymmetricKey(data: key))
        for p in parts { m.update(data: p) }
        return Data(m.finalize())
    }
    /// The owner secret from a claim: X25519 with the sensor's public key, then HMAC.
    static func ownerSecret(mine: Curve25519.KeyAgreement.PrivateKey, sensorPublic: Data) throws -> Data {
        let shared = try mine.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: sensorPublic))
        return hmac(shared.withUnsafeBytes { Data($0) }, Data("arpradar-owner-v1".utf8))
    }
    static func key(owner: Data, nonce: Data) -> SymmetricKey {
        SymmetricKey(data: hmac(owner, Data("arpradar-sensor-v1".utf8), nonce))
    }
    /// iv(12) ‖ ciphertext ‖ tag(16), the same layout as the sensor.
    static func seal(_ plain: Data, key: SymmetricKey) throws -> Data {
        guard let d = try AES.GCM.seal(plain, using: key).combined else { throw CocoaError(.coderInvalidValue) }
        return d
    }
    static func open(_ sealed: Data, key: SymmetricKey) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
    static func unhex(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var d = Data(); var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        return d
    }
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// Puts notification frames back together ([flags][bytes]; bit 0 = first frame, bit 1 = last).
    struct Reassembler {
        private var buf = Data(), started = false
        mutating func push(_ frame: Data) -> Data? {
            guard let flags = frame.first else { return nil }
            if flags & 1 != 0 { buf = Data(); started = true }
            guard started else { return nil }
            buf.append(frame.dropFirst())
            guard flags & 2 != 0 else { return nil }
            started = false
            defer { buf = Data() }
            return buf
        }
    }
}

/// Words for the device this app runs on, used in messages ("this Mac" / "this iPhone").
enum SensorPlatform {
    #if os(iOS)
    static let thisDevice = "this iPhone", tap = "Tap"
    static let bluetoothSettings = "Settings › Privacy & Security › Bluetooth"
    #else
    static let thisDevice = "this Mac", tap = "Click"
    static let bluetoothSettings = "System Settings › Privacy & Security › Bluetooth"
    #endif
}

#if os(iOS)
/// Owner keys, one per sensor id, in the iPhone's Keychain (this device only, never synced to iCloud).
enum SensorKeychain {
    private static let service = "ARPradar Sensor"
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
    }
    static func get(_ id: String) -> Data? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
    static func set(_ id: String, _ secret: Data) {
        delete(id)
        var q = query(id)
        q[kSecValueData as String] = secret
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    static func delete(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
}
#else
/// Owner keys, one per sensor id, in ~/Library/Application Support/ArpSpy/sensor-owners.json (readable only by this
/// user). Not the Keychain: an app that isn't signed by Apple yet gets a Keychain password prompt after every update.
enum SensorKeychain {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ArpSpy")
        return dir.appendingPathComponent("sensor-owners.json")
    }
    private static func load() -> [String: String] {
        guard let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }
    private static func save(_ m: [String: String]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(m) else { return }
        try? d.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func get(_ id: String) -> Data? { load()[id].flatMap(SensorProtocol.unhex) }
    static func set(_ id: String, _ secret: Data) { var m = load(); m[id] = SensorProtocol.hex(secret); save(m) }
    static func delete(_ id: String) { var m = load(); m[id] = nil; save(m) }
}
#endif

/// One device in the sensor's results.
struct SensorRow: Equatable, Codable, Identifiable, Hashable {
    var id: UInt32 { ip.value }
    var ip: IPv4, mac = "", name = "", vendor = "", ports: [UInt16] = [], ms: Double? = nil
    var web = "", upnp = "", snmp = "", snmpName = "", ubnt = ""

    init(ip: IPv4) { self.ip = ip }

    init?(_ d: [String: Any]) {
        guard let ip = (d["ip"] as? String).flatMap(IPv4.init) else { return nil }
        self.ip = ip
        mac = d["mac"] as? String ?? ""; name = d["name"] as? String ?? ""; vendor = d["vendor"] as? String ?? ""
        ports = (d["ports"] as? [Int] ?? []).compactMap { UInt16(exactly: $0) }
        ms = d["ms"] as? Double
        web = d["web"] as? String ?? ""; upnp = d["upnp"] as? String ?? ""; snmp = d["snmp"] as? String ?? ""
        snmpName = d["snmpName"] as? String ?? ""; ubnt = d["ubnt"] as? String ?? ""
    }
}

/// A finished scan from the sensor, handed to the app (`SensorLink.onResults`).
struct SensorScanResult {
    var rows: [SensorRow]
    var range: String
    var seconds: Double
    /// "Sensor · Office Wi-Fi"
    var label: String
    /// The Wi-Fi network the sensor scanned from ("" = unknown).
    var ssid: String
    var cancelled: Bool
}

@MainActor
final class SensorLink: NSObject, ObservableObject {
    static let shared = SensorLink()

    struct Nearby: Identifiable, Equatable { let id: UUID; var name: String; var rssi: Int; var seen: Date }
    struct WiFi: Identifiable, Hashable { var id: String { ssid }; let ssid: String; let signal: Int; let secure: Bool }

    enum Phase: Equatable {
        case bluetoothOff(String)
        case idle            // nothing selected
        case connecting
        case ready           // connected and ours
        case ownedByOther    // connected, but another app owns it
        case working(Double, String)
        case failed(String)
    }

    @Published private(set) var nearby: [Nearby] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selected: UUID?
    @Published private(set) var sensorName = ""
    @Published private(set) var version = ""
    @Published private(set) var ssid = ""
    @Published private(set) var ip = ""
    @Published private(set) var networks: [WiFi] = []
    /// Shown under the buttons after something finishes ("128 devices in 19.4 s").
    @Published private(set) var note = ""
    /// What to do with a finished scan; returns the note to show ("128 devices in 19.4 s · shown in the main window").
    var onResults: ((SensorScanResult) -> String)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var sensorID = ""
    private var key: SymmetricKey?
    private var frames = SensorProtocol.Reassembler()
    /// The command waiting for a fresh nonce from INFO.
    private var pending: [String: Any]?
    private var queue: [[String: Any]] = []
    /// A claim was written; the waiting command goes out once the sensor acknowledges it.
    private var claimInFlight = false
    /// An INFO read is on its way (only ever one, so each command gets its own fresh nonce).
    private var infoInFlight = false
    /// The waiting command was refused once (an old nonce); it gets one more try with a fresh one.
    private var retried = false
    /// Gives up on a connection that never gets ready (a sensor rebooting, out of range).
    private var connectWatch: Task<Void, Never>?
    private var serviceTries = 0

    /// Starts Bluetooth (first use asks for permission) and looks for sensors.
    func start() {
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else if central?.state == .poweredOn { scan() }
    }

    func stop() {
        central?.stopScan()
        disconnect()
    }

    private func scan() {
        central?.scanForPeripherals(withServices: [SensorProtocol.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func select(_ id: UUID?) {
        guard id != selected else { return }
        disconnect()
        selected = id
        guard let id, let p = central?.retrievePeripherals(withIdentifiers: [id]).first else { phase = .idle; return }
        peripheral = p
        p.delegate = self
        phase = .connecting
        serviceTries = 0
        central?.connect(p)
        connectWatch?.cancel()
        connectWatch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, self.selected == id, self.phase == .connecting else { return }
            self.disconnect()
            self.phase = .failed("Couldn’t reach the sensor. Make sure it’s on and nearby, then \(SensorPlatform.tap.lowercased()) it again.")
        }
    }

    private func disconnect() {
        connectWatch?.cancel()
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil; chars = [:]; key = nil; pending = nil; queue = []; claimInFlight = false; infoInFlight = false; retried = false
        sensorName = ""; version = ""; ssid = ""; ip = ""; networks = []; note = ""; sensorID = ""
        if selected != nil { phase = .idle }
        selected = nil
    }

    // MARK: Commands

    var canScan: Bool { if case .ready = phase { return true } else { return false } }
    var isWorking: Bool { if case .working = phase { return true } else { return false } }

    /// One-step scan: with `ssid`, the sensor joins that Wi-Fi just for this scan, then leaves it and deletes it.
    func scan(ssid: String?, password: String, range: String, quiet: Bool, community: String = "") {
        var cmd: [String: Any] = ["cmd": "scan", "quiet": quiet]
        let c = community.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty { cmd["community"] = c }
        if let ssid, !ssid.isEmpty { cmd["ssid"] = ssid; cmd["password"] = password }
        if !range.trimmingCharacters(in: .whitespaces).isEmpty { cmd["range"] = range.trimmingCharacters(in: .whitespaces) }
        phase = .working(0, ssid.map { "Joining \($0)…" } ?? "Starting…")
        note = ""
        send(cmd)
    }

    func cancel() { send(["cmd": "cancel"]) }
    func refreshNetworks() { send(["cmd": "networks"]) }

    /// Stop owning this sensor: the next app to connect becomes its owner.
    func release() { send(["cmd": "release"]) }

    private func send(_ cmd: [String: Any]) {
        queue.append(cmd)
        if pending == nil { next() }
    }

    private func next() {
        guard pending == nil, !queue.isEmpty else { return }
        pending = queue.removeFirst()
        retried = false
        readInfo()
    }

    /// Asks for INFO (a fresh nonce) for the waiting command; never two at once.
    private func readInfo() {
        guard !infoInFlight, pending != nil, let p = peripheral, let info = chars[SensorProtocol.info] else { return }
        infoInFlight = true
        p.readValue(for: info)
    }

    /// INFO arrived: claim a free sensor, or send the waiting command.
    private func gotInfo(_ data: Data) {
        infoInFlight = false
        guard pending != nil else { return }
        guard let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nonce = (info["nonce"] as? String).flatMap(SensorProtocol.unhex), nonce.count == 16,
              let id = info["id"] as? String, let p = peripheral, let cmdChar = chars[SensorProtocol.command] else {
            phase = .failed("The sensor answered with something unexpected."); return
        }
        sensorID = id
        sensorName = info["name"] as? String ?? "ARPradar Sensor"
        version = info["version"] as? String ?? ""
        let owned = info["owned"] as? Bool ?? true
        if !owned, let pubHex = info["claimPub"] as? String, let sensorPub = SensorProtocol.unhex(pubHex) {
            // A free sensor: this device becomes its owner.
            let mine = Curve25519.KeyAgreement.PrivateKey()
            guard let secret = try? SensorProtocol.ownerSecret(mine: mine, sensorPublic: sensorPub) else { phase = .failed("Couldn’t set up the sensor."); return }
            SensorKeychain.set(id, secret)
            key = SensorProtocol.key(owner: secret, nonce: nonce)
            var bytes = Data([0xC1]); bytes.append(mine.publicKey.rawRepresentation)
            claimInFlight = true
            p.writeValue(bytes, for: cmdChar, type: .withResponse)
            return   // the claim's acknowledgement sends `pending` (didWriteValue)
        }
        guard let secret = SensorKeychain.get(id) else {
            pending = nil; queue = []
            phase = .ownedByOther
            return
        }
        guard let cmd = pending, let body = try? JSONSerialization.data(withJSONObject: cmd) else { pending = nil; return }
        let k = SensorProtocol.key(owner: secret, nonce: nonce)
        key = k
        guard let sealed = try? SensorProtocol.seal(body, key: k) else { pending = nil; return }
        p.writeValue(nonce + sealed, for: cmdChar, type: .withResponse)
    }

    private func gotEvent(_ ev: [String: Any]) {
        switch ev["type"] as? String {
        case "claimed":
            break   // handled by the claim's acknowledgement
        case "status":
            ssid = ev["ssid"] as? String ?? ""; ip = ev["ip"] as? String ?? ""
            connectWatch?.cancel()
            if !isWorking { phase = .ready }
        case "networks":
            networks = (ev["networks"] as? [[String: Any]] ?? []).compactMap {
                guard let s = $0["ssid"] as? String else { return nil }
                return WiFi(ssid: s, signal: $0["signal"] as? Int ?? 0, secure: $0["secure"] as? Bool ?? true)
            }
        case "progress":
            phase = .working(ev["fraction"] as? Double ?? 0, ev["text"] as? String ?? "")
        case "devices":
            let rows = (ev["devices"] as? [[String: Any]] ?? []).compactMap(SensorRow.init)
            let seconds = ev["seconds"] as? Double ?? 0
            let net = (ev["ssid"] as? String) ?? ssid
            let label = "Sensor" + (net.isEmpty ? "" : " · \(net)")
            let result = SensorScanResult(rows: rows, range: ev["range"] as? String ?? "", seconds: seconds, label: label,
                                          ssid: net, cancelled: ev["cancelled"] as? Bool ?? false)
            note = onResults?(result) ?? "\(rows.count) devices in \(String(format: "%.1f", seconds)) s"
        case "done":
            phase = .ready
            send(["cmd": "status"])
        case "error":
            phase = .ready
            note = ev["text"] as? String ?? "The sensor reported a problem."
        case "released":
            SensorKeychain.delete(sensorID)
            note = "Released: the next app to connect becomes its owner."
            phase = .ownedByOther
        default: break
        }
    }
}

extension SensorLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        MainActor.assumeIsolated {
            switch c.state {
            case .poweredOn:
                if case .bluetoothOff = phase { phase = .idle }
                scan()
            case .unauthorized: phase = .bluetoothOff("ARPradar isn’t allowed to use Bluetooth. Turn it on in \(SensorPlatform.bluetoothSettings).")
            case .poweredOff: phase = .bluetoothOff("Bluetooth is off on \(SensorPlatform.thisDevice).")
            case .unsupported: phase = .bluetoothOff("\(SensorPlatform.thisDevice.prefix(1).uppercased() + SensorPlatform.thisDevice.dropFirst()) has no Bluetooth LE.")
            default: break
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name ?? "ARPradar Sensor"
        let id = p.identifier, signal = rssi.intValue
        MainActor.assumeIsolated {
            guard signal < 0 else { return }   // 127 = no reading
            if let i = nearby.firstIndex(where: { $0.id == id }) {
                nearby[i].rssi = signal; nearby[i].seen = Date(); nearby[i].name = name
            } else {
                nearby.append(Nearby(id: id, name: name, rssi: signal, seen: Date()))
            }
            // Drop sensors not heard from for a while (but never the one in use).
            nearby.removeAll { $0.id != selected && Date().timeIntervalSince($0.seen) > 30 }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices([SensorProtocol.service])
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        let why = error?.localizedDescription ?? "unknown"
        MainActor.assumeIsolated { phase = .failed("Couldn’t connect to the sensor (\(why)).") }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let id = p.identifier
        MainActor.assumeIsolated {
            guard selected == id else { return }
            peripheral = nil; chars = [:]; pending = nil; queue = []
            phase = .failed("The sensor disconnected. \(SensorPlatform.tap) it again to reconnect.")
            selected = nil
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let s = p.services?.first(where: { $0.uuid == SensorProtocol.service }) {
            p.discoverCharacteristics([SensorProtocol.info, SensorProtocol.command, SensorProtocol.events], for: s)
            return
        }
        // Not there (yet): the sensor may be starting up. Look again a few times.
        MainActor.assumeIsolated {
            serviceTries += 1
            guard serviceTries < 6 else { phase = .failed("That device isn’t answering as an ARPradar Sensor."); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { p.discoverServices([SensorProtocol.service]) }
        }
    }

    /// The sensor restarted its service (an update, a reboot): find it again.
    nonisolated func peripheral(_ p: CBPeripheral, didModifyServices invalidated: [CBService]) {
        MainActor.assumeIsolated {
            chars = [:]; pending = nil; infoInFlight = false; claimInFlight = false
            if !isWorking { phase = .connecting }
            serviceTries = 0
        }
        p.discoverServices([SensorProtocol.service])
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        let found = s.characteristics ?? []
        MainActor.assumeIsolated {
            for c in found { chars[c.uuid] = c }
            guard let ev = chars[SensorProtocol.events] else { phase = .failed("That isn’t an ARPradar Sensor."); return }
            p.setNotifyValue(true, for: ev)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            // Connected: claim it if it's free, then status and nearby networks.
            send(["cmd": "status"])
            send(["cmd": "networks"])
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard let data = c.value else { return }
        let uuid = c.uuid
        MainActor.assumeIsolated {
            if uuid == SensorProtocol.info {
                gotInfo(data)
            } else if uuid == SensorProtocol.events, let msg = frames.push(data) {
                guard let key, let plain = SensorProtocol.open(msg, key: key),
                      let ev = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return }
                gotEvent(ev)
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        let failed = error != nil
        MainActor.assumeIsolated {
            if claimInFlight {
                claimInFlight = false
                if failed { pending = nil; queue = []; phase = .failed("Couldn’t set \(SensorPlatform.thisDevice) up as the sensor’s owner. \(SensorPlatform.tap) it again to retry."); return }
                readInfo()   // the claimed sensor: now send the waiting command with a fresh nonce
                return
            }
            if failed {
                // Most often an old nonce (two apps nearby, or a reconnect): one more try with a fresh one.
                if !retried { retried = true; readInfo(); return }
                // Still refused: this device's key no longer fits (released or reset elsewhere).
                if !sensorID.isEmpty { SensorKeychain.delete(sensorID) }
                pending = nil; queue = []
                phase = .ownedByOther
                return
            }
            pending = nil
            next()
        }
    }
}

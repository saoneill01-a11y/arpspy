import CoreBluetooth
import CryptoKit
import Foundation

/// The ARPradar Sensor (a Raspberry Pi running arpradar-sensor; source in the arpradar-windows repo, sensor/) over
/// Bluetooth LE. Protocol: sensor/src/link.rs. Ownership works like adopting a UniFi device: the first app to connect
/// claims it (an X25519 key exchange) and keeps the owner secret in the Keychain; the sensor ignores other apps
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

/// Owner secrets, one per sensor id, in the login Keychain.
enum SensorKeychain {
    static let service = "ARPradar Sensor"
    static func get(_ id: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return d
    }
    static func set(_ id: String, _ secret: Data) {
        delete(id)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: id, kSecValueData as String: secret, kSecAttrLabel as String: "ARPradar Sensor owner key"]
        SecItemAdd(q as CFDictionary, nil)
    }
    static func delete(_ id: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
        SecItemDelete(q as CFDictionary)
    }
}

/// One device in the sensor's results.
struct SensorRow: Equatable {
    var ip: IPv4, mac = "", name = "", vendor = "", ports: [UInt16] = [], ms: Double? = nil
    var web = "", upnp = "", snmp = "", snmpName = "", ubnt = ""

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

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var chars: [CBUUID: CBCharacteristic] = [:]
    private var sensorID = ""
    private var key: SymmetricKey?
    private var frames = SensorProtocol.Reassembler()
    /// The command waiting for a fresh nonce from INFO.
    private var pending: [String: Any]?
    private var queue: [[String: Any]] = []
    /// A claim was written; the waiting command goes out after the sensor answers "claimed".
    private var claimInFlight = false

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
        central?.connect(p)
    }

    private func disconnect() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        peripheral = nil; chars = [:]; key = nil; pending = nil; queue = []; claimInFlight = false
        sensorName = ""; version = ""; ssid = ""; ip = ""; networks = []; note = ""; sensorID = ""
        if selected != nil { phase = .idle }
        selected = nil
    }

    // MARK: Commands

    var canScan: Bool { if case .ready = phase { return true } else { return false } }
    var isWorking: Bool { if case .working = phase { return true } else { return false } }

    /// One-step scan: with `ssid`, the sensor joins that Wi-Fi just for this scan, then leaves it and deletes it.
    func scan(ssid: String?, password: String, range: String, quiet: Bool) {
        var cmd: [String: Any] = ["cmd": "scan", "quiet": quiet]
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
        guard pending == nil, !queue.isEmpty, let p = peripheral, let info = chars[SensorProtocol.info] else { return }
        pending = queue.removeFirst()
        p.readValue(for: info)   // a fresh nonce for this command
    }

    /// INFO arrived: claim a free sensor, or send the waiting command.
    private func gotInfo(_ data: Data) {
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
            // A free sensor: this Mac becomes its owner.
            let mine = Curve25519.KeyAgreement.PrivateKey()
            guard let secret = try? SensorProtocol.ownerSecret(mine: mine, sensorPublic: sensorPub) else { phase = .failed("Couldn’t set up the sensor."); return }
            SensorKeychain.set(id, secret)
            key = SensorProtocol.key(owner: secret, nonce: nonce)
            var bytes = Data([0xC1]); bytes.append(mine.publicKey.rawRepresentation)
            claimInFlight = true
            p.writeValue(bytes, for: cmdChar, type: .withResponse)
            return   // the claim answers; `pending` is sent after "claimed"
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
            claimInFlight = false
            // The waiting command goes out with a fresh nonce.
            if let p = peripheral, let info = chars[SensorProtocol.info], pending != nil { p.readValue(for: info) }
        case "status":
            ssid = ev["ssid"] as? String ?? ""; ip = ev["ip"] as? String ?? ""
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
            let joined = ev["ssid"] as? String
            let label = "Sensor" + (joined.map { " · \($0)" } ?? (ssid.isEmpty ? "" : " · \(ssid)"))
            ScanModel.shared.showSensorScan(rows: rows, range: ev["range"] as? String ?? "", seconds: seconds, label: label,
                                           cancelled: ev["cancelled"] as? Bool ?? false)
            note = "\(rows.count) devices in \(String(format: "%.1f", seconds)) s · shown in the main window"
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
            case .unauthorized: phase = .bluetoothOff("ARPradar isn’t allowed to use Bluetooth. Turn it on in System Settings › Privacy & Security › Bluetooth.")
            case .poweredOff: phase = .bluetoothOff("Bluetooth is off on this Mac.")
            case .unsupported: phase = .bluetoothOff("This Mac has no Bluetooth LE.")
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
            phase = .failed("The sensor disconnected. Click it again to reconnect.")
            selected = nil
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == SensorProtocol.service }) else { return }
        p.discoverCharacteristics([SensorProtocol.info, SensorProtocol.command, SensorProtocol.events], for: s)
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
            if failed {
                let wasClaim = claimInFlight
                pending = nil; queue = []; claimInFlight = false
                phase = wasClaim ? .failed("Couldn’t set up the sensor. Try again.") : .ownedByOther
                return
            }
            if claimInFlight { return }   // wait for "claimed"
            pending = nil
            next()
        }
    }
}

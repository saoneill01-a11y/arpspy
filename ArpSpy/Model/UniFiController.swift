import Foundation
import Security
import CryptoKit

// MARK: - Saved controllers

/// One UniFi controller ARPradar reads the network map from. The API key is in the Keychain, never in this file.
struct UniFiController: Codable, Identifiable, Hashable {
    var id = UUID()
    /// "https://10.0.0.5" (a Cloud Key, UDM, UCG or other UniFi OS console) or "https://10.0.0.5:8443" (self-hosted).
    var address = ""
    /// The controller's own short site name ("default") and what it's called on screen ("Default").
    var site = ""
    var siteName = ""
    /// The organization it belongs to (nil = used for any scan that covers its address).
    var orgID: UUID? = nil
    /// SHA-256 of the controller's certificate ("AA:BB:…"), remembered on the first connection and required to
    /// match afterwards. nil = not connected yet (or forgotten). Optional so older unifi.json files still load.
    var certFingerprint: String? = nil

    var host: String { URL(string: UniFiClient.normalized(address))?.host ?? "" }
}

@MainActor
final class UniFiStore: ObservableObject {
    static let shared = UniFiStore()
    @Published private(set) var controllers: [UniFiController] = []
    /// What went wrong on the last save (the Keychain refusing the key), in plain words; nil when it went fine.
    @Published private(set) var lastError: String? = nil
    /// Certificates seen for controllers that aren't saved yet (the sheet's Test before Save), by address.
    private var pendingFingerprints: [String: String] = [:]

    private let file: URL

    init(file: URL? = nil) {
        self.file = file ?? DeviceStore.fileURL.deletingLastPathComponent().appendingPathComponent("unifi.json")
        if let data = try? Data(contentsOf: self.file),
           let list = try? JSONDecoder().decode([UniFiController].self, from: data) { controllers = list }
    }

    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? enc.encode(controllers) { try? data.write(to: file, options: .atomic) }
    }

    func controller(forOrg org: UUID?) -> UniFiController? {
        guard let org else { return nil }
        return controllers.first { $0.orgID == org }
    }

    /// The controller for a scan: its organization's, else one whose address is inside the scanned range.
    func controller(org: UUID?, targets: Set<UInt32>) -> UniFiController? {
        if let c = controller(forOrg: org) { return c }
        return controllers.first { c in
            guard c.orgID == nil || c.orgID == org, let ip = IPv4(c.host) else { return false }
            return targets.contains(ip.value)
        }
    }

    /// Saves (or adds) a controller and, when given, its API key. Returns a plain-English problem when the
    /// Keychain refuses the key (also kept in `lastError`), nil when everything was saved.
    @discardableResult
    func upsert(_ c: UniFiController, key: String?) -> String? {
        var c = c
        c.address = UniFiClient.normalized(c.address)
        if let old = controllers.first(where: { $0.id == c.id }), old.address != c.address { c.certFingerprint = nil }   // a new address is a new certificate
        if c.certFingerprint == nil { c.certFingerprint = pendingFingerprints[c.address] }
        if let i = controllers.firstIndex(where: { $0.id == c.id }) { controllers[i] = c } else { controllers.append(c) }
        save()
        if let key, !key.isEmpty {
            let status = Keychain.set(key, account: c.id.uuidString)
            if status != errSecSuccess {
                lastError = UniFiClient.Failure.keychain(status).errorDescription
                return lastError
            }
        }
        lastError = nil
        return nil
    }

    func remove(_ id: UUID) {
        controllers.removeAll { $0.id == id }
        save()
        Keychain.delete(account: id.uuidString)
    }

    func hasKey(_ c: UniFiController) -> Bool { Keychain.get(account: c.id.uuidString) != nil }
    func key(_ c: UniFiController) -> String? { Keychain.get(account: c.id.uuidString) }

    // MARK: Certificate trust (first use is remembered)

    /// The certificate fingerprint remembered for a controller address, if any.
    func fingerprint(forAddress address: String) -> String? {
        let a = UniFiClient.normalized(address)
        return controllers.first { UniFiClient.normalized($0.address) == a && $0.certFingerprint != nil }?.certFingerprint
            ?? pendingFingerprints[a]
    }

    /// Remembers the certificate a controller showed on its first connection.
    func recordFingerprint(_ fp: String, forAddress address: String) {
        let a = UniFiClient.normalized(address)
        pendingFingerprints[a] = fp
        var changed = false
        for i in controllers.indices where UniFiClient.normalized(controllers[i].address) == a && controllers[i].certFingerprint == nil {
            controllers[i].certFingerprint = fp; changed = true
        }
        if changed { save() }
    }

    /// Forgets a controller's certificate (after replacing the controller or its certificate): the next
    /// connection accepts and remembers whatever it shows.
    func forgetCertificate(for id: UUID) {
        guard let i = controllers.firstIndex(where: { $0.id == id }) else { return }
        pendingFingerprints[UniFiClient.normalized(controllers[i].address)] = nil
        controllers[i].certFingerprint = nil
        save()
    }
}

/// The login Keychain, under "ARPradar UniFi". After each rebuild of the app macOS may ask once to allow it.
enum Keychain {
    static let service = "ARPradar UniFi"

    /// Stores the value, replacing any old one. Returns errSecSuccess or the Keychain's error code.
    @discardableResult
    static func set(_ value: String, account: String) -> OSStatus {
        delete(account: account)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                kSecAttrLabel as String: "ARPradar UniFi API key"]
        return SecItemAdd(q as CFDictionary, nil)
    }

    static func get(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Talking to the controller

/// Reads a UniFi Network controller with a read-only API key (UniFi Network › Settings › Control Plane › Integrations).
/// Tries the classic API first (it has switch ports and Wi-Fi signal), then the official one (no port numbers).
/// It only ever sends GET requests: it never changes anything on the controller.
struct UniFiClient {
    struct Site: Hashable, Identifiable { var id: String; var ref: String; var name: String }

    enum Failure: LocalizedError {
        case badAddress, refused, notUniFi(String), network(String)
        case keychain(OSStatus), certificateChanged
        var errorDescription: String? {
            switch self {
            case .badAddress: return "Enter the controller's address, e.g. https://10.0.0.5"
            case .refused: return "The controller refused the API key. Check it in UniFi Network › Settings › Control Plane › Integrations."
            case .notUniFi(let s): return "That address didn't answer like a UniFi controller (\(s))."
            case .network(let s): return s
            case .keychain(let status): return "macOS refused to store the API key in the Keychain (error \(status))"
            case .certificateChanged:
                return "The controller's certificate changed. If you replaced the controller or its certificate, open Settings › UniFi and choose Forget Certificate; otherwise someone may be intercepting the connection."
            }
        }
    }

    let address: String
    let key: String
    /// What it tried and what came back, without the key or any values. Shown under "Connection details".
    final class Log: @unchecked Sendable {
        private let lock = NSLock(); private var lines: [String] = []
        func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    }
    let log = Log()

    /// The certificate check, shared with the session delegate: the fingerprint to expect (nil the first time)
    /// and what the controller showed. Read `seen` after a request to find out what it presented.
    final class TrustState: @unchecked Sendable {
        private let lock = NSLock()
        private var _expected: String?, _seen: String?, _mismatch = false, _lookedUp = false, _recorded = false
        var expected: String? { get { lock.lock(); defer { lock.unlock() }; return _expected } set { lock.lock(); _expected = newValue; lock.unlock() } }
        var seen: String? { get { lock.lock(); defer { lock.unlock() }; return _seen } set { lock.lock(); _seen = newValue; lock.unlock() } }
        /// True once the controller showed a certificate other than the remembered one.
        var mismatch: Bool { get { lock.lock(); defer { lock.unlock() }; return _mismatch } set { lock.lock(); _mismatch = newValue; lock.unlock() } }
        /// Whether the saved fingerprint has been asked for already / the new one has been written down.
        var lookedUp: Bool { get { lock.lock(); defer { lock.unlock() }; return _lookedUp } set { lock.lock(); _lookedUp = newValue; lock.unlock() } }
        var recorded: Bool { get { lock.lock(); defer { lock.unlock() }; return _recorded } set { lock.lock(); _recorded = newValue; lock.unlock() } }
    }
    let trust = TrustState()

    /// "https://host[:port]": http:// becomes https:// (the API key must not travel in the clear) and anything
    /// after the host and port (a path like /network, a trailing slash) is dropped.
    static func normalized(_ address: String) -> String {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return a }
        if a.lowercased().hasPrefix("http://") { a = "https://" + a.dropFirst("http://".count) }
        if !a.contains("://") { a = "https://" + a }
        if let u = URL(string: a), let host = u.host, !host.isEmpty {
            let h = host.contains(":") ? "[\(host)]" : host          // an IPv6 address keeps its brackets
            return "https://" + h + (u.port.map { ":\($0)" } ?? "")
        }
        while a.hasSuffix("/") { a.removeLast() }
        return a
    }

    private var base: URL? { URL(string: Self.normalized(address)) }

    /// SHA-256 of the certificate the server presented (the first in its chain), as "AA:BB:…".
    static func fingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Accepts the controller's own (usually self-signed) certificate, for its address only: any certificate the
    /// first time, and only that same one afterwards (so a changed certificate stops the connection).
    final class TrustOneHost: NSObject, URLSessionDelegate {
        let host: String
        let state: TrustState
        init(host: String, state: TrustState) { self.host = host; self.state = state }
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil); return
            }
            let fp = UniFiClient.fingerprint(of: trust)
            state.seen = fp
            if let expected = state.expected, fp != expected {
                state.mismatch = true
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    private func get(_ path: String, session: URLSession) async throws -> (Int, Data) {
        guard let base, let url = URL(string: base.absoluteString + path) else { throw Failure.badAddress }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "GET"
        req.setValue(key, forHTTPHeaderField: "X-API-KEY")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            log.add("GET \(path) → \(code), \(data.count) bytes")
            await rememberCertificate()
            return (code, data)
        } catch {
            if trust.mismatch {
                log.add("GET \(path) → certificate changed (now \(trust.seen ?? "unreadable"), remembered \(trust.expected ?? "none"))")
                throw Failure.certificateChanged
            }
            log.add("GET \(path) → \(error.localizedDescription)")
            throw Failure.network("Couldn't reach \(base.host ?? address): \(error.localizedDescription)")
        }
    }

    /// First connection: write down the certificate it showed, in the store and in the log.
    private func rememberCertificate() async {
        guard trust.expected == nil, !trust.recorded, let fp = trust.seen else { return }
        trust.recorded = true
        trust.expected = fp
        log.add("certificate SHA-256 \(fp) (first connection: remembered, later connections must show the same one)")
        let address = address
        await MainActor.run { UniFiStore.shared.recordFingerprint(fp, forAddress: address) }
    }

    private func session() async throws -> URLSession {
        guard let host = base?.host else { throw Failure.badAddress }
        if !trust.lookedUp {
            // The fingerprint remembered for this address, if it has connected before.
            let address = address
            trust.expected = await MainActor.run { UniFiStore.shared.fingerprint(forAddress: address) }
            trust.lookedUp = true
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        return URLSession(configuration: cfg, delegate: TrustOneHost(host: host, state: trust), delegateQueue: nil)
    }

    /// Finds where the API lives ("/proxy/network" on UniFi OS consoles, nothing on self-hosted) and lists the sites.
    func sites() async throws -> (prefix: String, sites: [Site]) {
        let s = try await session()
        defer { s.finishTasksAndInvalidate() }
        var lastCode = 0
        for prefix in ["/proxy/network", ""] {
            let (code, data) = try await get(prefix + "/integration/v1/sites?limit=200", session: s)
            lastCode = code
            if code == 401 || code == 403 { throw Failure.refused }
            guard code == 200, let list = UniFiJSON.dataArray(data) else { continue }
            let sites = list.map { d in
                Site(id: UniFiJSON.str(d, "id"),
                     ref: UniFiJSON.str(d, "internalReference").isEmpty ? "default" : UniFiJSON.str(d, "internalReference"),
                     name: UniFiJSON.str(d, "name"))
            }
            log.add("API at \(prefix.isEmpty ? "/" : prefix), \(sites.count) site(s)")
            return (prefix, sites)
        }
        throw Failure.notUniFi(lastCode == 0 ? "no answer" : "HTTP \(lastCode)")
    }

    struct Result {
        var devices: [RawUniFiDevice]
        var clients: [RawUniFiClient]
        /// "classic API" or "official API"
        var api: String
        var siteName: String
    }

    /// Everything the map needs from one site (`siteRef` = the short name, e.g. "default"; blank = the first site).
    func fetch(siteRef: String) async throws -> Result {
        let (prefix, sites) = try await sites()
        guard let site = sites.first(where: { $0.ref == siteRef || $0.id == siteRef }) ?? sites.first else {
            throw Failure.notUniFi("no sites")
        }
        let s = try await session()
        defer { s.finishTasksAndInvalidate() }

        // Official API: model names (the classic one only has codes), and the fallback.
        var official: [[String: Any]] = []
        var macByID: [String: String] = [:]
        if !site.id.isEmpty {
            official = try await pages("\(prefix)/integration/v1/sites/\(site.id)/devices", session: s)
            for d in official { macByID[UniFiJSON.str(d, "id")] = UniFiJSON.str(d, "macAddress") }
            log.add("official API: \(official.count) devices")
        }
        let modelByMAC = Dictionary(official.map { (NetMapBuilder.mac(UniFiJSON.str($0, "macAddress")), UniFiJSON.str($0, "model")) },
                                    uniquingKeysWith: { a, _ in a })

        // Classic API.
        let (dc, dd) = try await get("\(prefix)/api/s/\(site.ref)/stat/device", session: s)
        let (cc, cd) = try await get("\(prefix)/api/s/\(site.ref)/stat/sta", session: s)
        if dc == 200, cc == 200, let devs = UniFiJSON.dataArray(dd), let stas = UniFiJSON.dataArray(cd) {
            log.add("classic API: \(devs.count) devices, \(stas.count) clients; device fields: \(fieldNames(devs))")
            log.add("client fields: \(fieldNames(stas))")
            var devices = devs.compactMap(UniFiJSON.classicDevice)
            for i in devices.indices {
                if let m = modelByMAC[NetMapBuilder.mac(devices[i].mac)], !m.isEmpty { devices[i].model = m }
            }
            return Result(devices: devices, clients: stas.compactMap(UniFiJSON.classicClient), api: "classic API", siteName: site.name)
        }
        guard !official.isEmpty || !site.id.isEmpty else { throw Failure.notUniFi("no device list") }

        // Official API only: one more call per device for its ports and uplink, six at a time.
        let ids = official.map { UniFiJSON.str($0, "id") }
        let details: [Data?] = await DNSPlus.inParallel(ids, limit: 6) { id in
            guard !id.isEmpty, let r = try? await get("\(prefix)/integration/v1/sites/\(site.id)/devices/\(id)", session: s), r.0 == 200 else { return nil }
            return r.1
        }
        var devices: [RawUniFiDevice] = []
        for (item, data) in zip(official, details) {
            let detail = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            if let d = UniFiJSON.integrationDevice(item, detail: detail, macByID: macByID) { devices.append(d) }
        }
        let clients = try await pages("\(prefix)/integration/v1/sites/\(site.id)/clients", session: s)
        log.add("official API: \(clients.count) clients; client fields: \(fieldNames(clients))")
        return Result(devices: devices, clients: clients.compactMap { UniFiJSON.integrationClient($0, macByID: macByID) },
                      api: "official API", siteName: site.name)
    }

    /// The official API pages its lists (up to 200 at a time).
    private func pages(_ path: String, session s: URLSession) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var offset = 0
        while offset < 5000 {
            let (code, data) = try await get("\(path)?offset=\(offset)&limit=200", session: s)
            if code == 401 || code == 403 { throw Failure.refused }
            guard code == 200, let list = UniFiJSON.dataArray(data) else { break }
            out += list
            let total = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap { UniFiJSON.int($0, "totalCount") } ?? out.count
            if list.isEmpty || out.count >= total { break }
            offset += list.count
        }
        return out
    }

    /// The field names in a list (never the values), for "Connection details".
    private func fieldNames(_ list: [[String: Any]]) -> String {
        Set(list.prefix(20).flatMap(\.keys)).sorted().prefix(60).joined(separator: ", ")
    }
}

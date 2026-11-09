import Foundation
import Darwin

// MARK: - Busy indicator

/// Anything running (ping, traceroute, DNS, speed test, port scan) makes the top-bar radar sweep.
@MainActor
final class Activity: ObservableObject {
    static let shared = Activity()
    @Published private(set) var busy = false
    private var running = Set<UUID>()

    func set(_ id: UUID, _ on: Bool) {
        if on { running.insert(id) } else { running.remove(id) }
        if busy != !running.isEmpty { busy = !running.isEmpty }
    }
}

// MARK: - Names → addresses

enum Resolver {
    /// An IPv4 address as typed, or the first IPv4 address a host name resolves to.
    static func ipv4(_ text: String) -> IPv4? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let ip = IPv4(t) { return ip }
        guard !t.isEmpty else { return nil }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(t, nil, &hints, &res) == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }
        guard let sa = first.pointee.ai_addr else { return nil }
        let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
        return IPv4(UInt32(bigEndian: addr))
    }
}

// MARK: - Host names

/// Checks a name before it goes to dig or traceroute, so it can never be read as an option (-f, +trace).
enum HostName {
    static let maxLength = 253
    /// Letters, digits, dots, hyphens and underscores; starts with a letter, digit or underscore (for _dmarc, _ldap._tcp)
    /// and ends with a letter or digit, optionally a trailing dot.
    private static let pattern = #"^[A-Za-z0-9_]([A-Za-z0-9._-]*[A-Za-z0-9])?\.?$"#

    /// True for an IPv4 or IPv6 address, or a well-formed host name (at most 253 characters).
    static func isValid(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= maxLength else { return false }
        if IPv4(t) != nil || isIPv6(t) { return true }
        guard !t.contains("..") else { return false }      // an empty label
        return t.range(of: pattern, options: .regularExpression) != nil
    }

    static func isIPv6(_ text: String) -> Bool {
        var addr = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
    }

    static let problem = "That isn’t a valid host name."
}

// MARK: - Ping

@MainActor
final class PingJob: ObservableObject {
    struct Sample: Identifiable { let id = UUID(); let target: String; let time: Date; let ms: Double? }
    struct Stats { var last: Double?; var avg: Double?; var min: Double?; var max: Double?; var jitter: Double?; var lost = 0; var sent = 0 }

    @Published var targetsText = ""
    @Published var interval = 1.0
    @Published private(set) var running = false { didSet { Activity.shared.set(activityID, running) } }
    private let activityID = UUID()
    @Published private(set) var samples: [Sample] = []
    @Published private(set) var problem: String? = nil
    private var task: Task<Void, Never>?
    private var flag = CancelFlag()
    static let keep = 600          // samples per target kept for the graph
    static let window = 60.0       // seconds shown and used for stats
    /// How long each ping waits for its reply. Separate from the send interval: a 0.5 s interval
    /// must not mean a reply that takes 0.6 s counts as lost.
    nonisolated static let replyTimeout = 2.0

    /// The names typed, in order, each once (the rows and the chart use them as ids).
    var targets: [String] {
        var seen = Set<String>()
        return targetsText.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func start() {
        stop()
        let names = targets
        guard !names.isEmpty else { return }
        problem = nil
        samples = []
        running = true
        let every = max(0.2, interval)
        let flag = CancelFlag()
        self.flag = flag
        task = Task { [weak self] in
            // Resolve every name at once; one slow lookup shouldn't hold up the others.
            let resolved: [String: IPv4] = await withTaskGroup(of: (String, IPv4?).self) { group in
                for n in names { group.addTask { (n, await offMain { Resolver.ipv4(n) }) } }
                var out: [String: IPv4] = [:]
                for await (n, ip) in group { if let ip { out[n] = ip } }
                return out
            }
            guard let self, !Task.isCancelled else { return }
            let missing = names.filter { resolved[$0] == nil }
            if !missing.isEmpty { self.problem = "Couldn’t find \(missing.joined(separator: ", "))." }
            if resolved.isEmpty { self.running = false; return }
            let ips = names.compactMap { resolved[$0] }
            while !Task.isCancelled {
                let started = Date()
                // Each sweep waits up to `replyTimeout` in its own task, so the next ping still goes out
                // on time even while an earlier one is waiting for a slow reply. Sweeps always last the
                // full timeout, so their results arrive in the order they were sent.
                Task { [weak self] in
                    let replies = await offMain { Pinger.sweep(ips, timeout: Self.replyTimeout, flag: flag) }
                    guard let self, !flag.isCancelled else { return }
                    self.record(names: names, resolved: resolved, started: started, replies: replies)
                }
                try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
            }
        }
    }

    private func record(names: [String], resolved: [String: IPv4], started: Date, replies: [UInt32: Double]) {
        for n in names { if let ip = resolved[n] { samples.append(Sample(target: n, time: started, ms: replies[ip.value])) } }
        if samples.count > Self.keep * names.count { samples.removeFirst(samples.count - Self.keep * names.count) }
    }

    func stop() { flag.cancel(); task?.cancel(); task = nil; running = false }

    func stats(for target: String) -> Stats {
        let cutoff = Date().addingTimeInterval(-Self.window)
        return Self.stats(samples.filter { $0.target == target && $0.time >= cutoff }.map(\.ms))
    }

    nonisolated static func stats(_ list: [Double?]) -> Stats {
        var s = Stats()
        s.sent = list.count
        s.lost = list.filter { $0 == nil }.count
        let got = list.compactMap { $0 }
        s.last = list.last ?? nil
        guard !got.isEmpty else { return s }
        s.avg = got.reduce(0, +) / Double(got.count)
        s.min = got.min(); s.max = got.max()
        if got.count > 1 {
            s.jitter = zip(got.dropFirst(), got).map { abs($0 - $1) }.reduce(0, +) / Double(got.count - 1)
        }
        return s
    }
}

// MARK: - Traceroute

struct Hop: Identifiable, Hashable {
    let number: Int
    var address: String
    var name: String
    var ms: Double?
    var id: Int { number }
}

enum TraceParser {
    /// " 3  core1.example.net (198.51.100.20)  14.2 ms" or " 4  *" or " 1  10.0.0.1 (10.0.0.1)  1.1 ms"
    static func hop(_ line: String) -> Hop? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, let n = Int(first) else { return nil }
        if parts.count < 2 || parts[1] == "*" { return Hop(number: n, address: "*", name: "", ms: nil) }
        let name = parts[1]
        var address = name
        if parts.count > 2, parts[2].hasPrefix("("), parts[2].hasSuffix(")") { address = String(parts[2].dropFirst().dropLast()) }
        let ms = parts.firstIndex(of: "ms").flatMap { $0 > 0 ? Double(parts[$0 - 1]) : nil }
        return Hop(number: n, address: address, name: name == address ? "" : name, ms: ms)
    }
}

@MainActor
final class TraceJob: ObservableObject {
    @Published var target = ""
    @Published private(set) var hops: [Hop] = []
    @Published private(set) var running = false { didSet { Activity.shared.set(activityID, running) } }
    private let activityID = UUID()
    @Published private(set) var status = ""
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = ""

    /// Lines from `proc` only: output from a run that was stopped (or replaced) is dropped.
    private func feed(_ chunk: String, from proc: Process) {
        guard process === proc else { return }
        buffer += chunk
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl]); buffer.removeSubrange(...nl)
            if let hop = TraceParser.hop(line) { hops.append(hop) }
        }
    }

    func start() {
        stop()
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        hops = []
        guard HostName.isValid(t) else { status = HostName.problem; return }
        running = true; status = "Tracing \(t)…"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
        p.arguments = ["-w", "2", "-q", "1", "-m", "30", t]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        buffer = ""
        // The handler holds `p`; both stop() and the termination handler clear it, which breaks the loop.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            Task { @MainActor in self?.feed(chunk, from: p) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                pipe.fileHandleForReading.readabilityHandler = nil
                // A run that was stopped (or replaced by a newer one) already said so: leave its status alone.
                guard let self, self.process === proc else { return }
                self.process = nil; self.pipe = nil
                self.running = false
                if proc.terminationStatus != 0 && self.hops.isEmpty { self.status = "Couldn’t trace \(t). Is the name right?" }
                else { self.status = "\(self.hops.count) hops" }
            }
        }
        process = p; self.pipe = pipe
        do { try p.run() } catch { process = nil; self.pipe = nil; running = false; status = "Couldn’t start traceroute." }
    }

    func stop() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil; pipe = nil
        if running { running = false; status = "Stopped" }
    }
}

// MARK: - DNS lookup

struct DNSAnswer: Identifiable, Hashable {
    let id = UUID()
    let name: String, type: String, ttl: Int, data: String
    /// 0 = the domain's own record; 1, 2… = followed through a CNAME to another name (shown indented).
    var depth = 0
}

/// One group in DNS Look Up: every record of one type.
struct DNSSection: Identifiable {
    let type: String
    let heading: String
    let lines: [DNSLine]
    var id: String { type }
}

/// One record in a group. `depth` > 0: reached through a CNAME (indented, with its type as a tag).
struct DNSLine: Identifiable {
    let id = UUID()
    let name: String
    let depth: Int
    let ttl: String
    let type: String
    let data: String
}

extension DNSTool {
    /// The order of the groups in DNS Lookup.
    static let groupOrder = ["A", "AAAA", "CNAME", "MX", "NS", "TXT", "SRV", "CAA", "SOA", "PTR", "DS", "DNSKEY"]

    static func groupDescription(_ type: String) -> String {
        switch type {
        case "A": return "IPv4 addresses"
        case "AAAA": return "IPv6 addresses"
        case "CNAME": return "aliases"
        case "MX": return "mail servers"
        case "NS": return "name servers"
        case "TXT": return "text (SPF, verification)"
        case "SRV": return "services"
        case "CAA": return "who may issue certificates"
        case "SOA": return "zone settings"
        case "PTR": return "names for an address"
        case "DS", "DNSKEY": return "DNSSEC keys"
        default: return ""
        }
    }

    static func heading(_ type: String, count: Int) -> String {
        let d = groupDescription(type)
        return "\(type) · \(count)" + (d.isEmpty ? "" : " · \(d)")
    }

    /// Records grouped by type (in `groupOrder`, then any others), sorted by name inside a group.
    /// A record followed through a CNAME (depth > 0) stays with the record above it.
    static func grouped<T>(_ items: [T], type: (T) -> String, isChild: (T) -> Bool, name: (T) -> String) -> [(type: String, blocks: [[T]])] {
        var blocks: [[T]] = []
        for i in items {
            if isChild(i), !blocks.isEmpty { blocks[blocks.count - 1].append(i) } else { blocks.append([i]) }
        }
        var byType: [String: [[T]]] = [:]
        for b in blocks { byType[type(b[0]), default: []].append(b) }
        let types = groupOrder.filter { byType[$0] != nil } + byType.keys.filter { !groupOrder.contains($0) }.sorted()
        return types.map { t in
            (t, byType[t]!.enumerated().sorted {
                let (a, b) = (name($0.element[0]).lowercased(), name($1.element[0]).lowercased())
                return a == b ? $0.offset < $1.offset : a < b
            }.map(\.element))
        }
    }

    /// The live results, grouped by type.
    static func sections(_ answers: [DNSAnswer]) -> [DNSSection] {
        grouped(answers, type: \.type, isChild: { $0.depth > 0 }, name: \.name).map { g in
            DNSSection(type: g.type, heading: heading(g.type, count: g.blocks.count),
                       lines: g.blocks.joined().map { DNSLine(name: $0.name, depth: $0.depth, ttl: String($0.ttl), type: $0.type, data: $0.data) })
        }
    }
}

extension SavedTable {
    /// A saved DNS Look Up (Name, Type, TTL, Answer) grouped the same way; nil for other tables.
    func dnsSections() -> [DNSSection]? {
        guard header == ["Name", "Type", "TTL", "Answer"] else { return nil }
        return DNSTool.grouped(rows.filter { $0.count >= 4 }, type: { $0[1] }, isChild: Self.isChainRow, name: { $0[0] }).map { g in
            DNSSection(type: g.type, heading: DNSTool.heading(g.type, count: g.blocks.count), lines: g.blocks.joined().map { r in
                // "    ↳ name": two spaces per extra level, then the arrow.
                let lead = r[0].prefix { $0 == " " }.count
                let chained = Self.isChainRow(r)
                let name = chained ? String(r[0].dropFirst(lead).dropFirst(2)) : r[0]
                return DNSLine(name: name, depth: chained ? lead / 2 + 1 : 0, ttl: r[2], type: r[1], data: r[3])
            })
        }
    }
}

/// One question asked and everything dig answered (before filtering).
struct DNSGroup: Hashable {
    let asked: String
    let answers: [DNSAnswer]
}

enum DNSTool {
    static let all = "All"
    static let types = [all, "A", "AAAA", "PTR", "MX", "TXT", "SRV", "CNAME", "NS", "SOA", "CAA", "DS", "DNSKEY"]

    /// Common service records: Active Directory, Exchange/365, Teams/SIP, mail, calendars.
    static let services = ["_ldap._tcp", "_kerberos._tcp", "_kerberos._udp", "_kpasswd._tcp", "_gc._tcp",
                           "_ldap._tcp.dc._msdcs", "_autodiscover._tcp", "_sip._tls", "_sipfederationtls._tcp",
                           "_xmpp-client._tcp", "_caldavs._tcp", "_carddavs._tcp", "_imaps._tcp", "_submission._tcp"]

    /// Well-known host names, asked for A records (any CNAME they point through shows too).
    static let hosts = ["www", "mail", "webmail", "owa", "smtp", "imap", "pop", "mx", "mx1", "mx2", "autodiscover", "autoconfig", "lyncdiscover", "sip",
                        "enterpriseregistration", "enterpriseenrollment", "msoid", "remote", "vpn", "vpn2", "ras", "rdweb", "rdgateway", "rdp", "ts", "citrix",
                        "gateway", "fw", "firewall", "portal", "intranet", "extranet", "exchange", "ftp", "sftp", "files", "share", "nas", "ns1", "ns2", "ns3",
                        "mta-sts", "sso", "login", "auth", "adfs", "sts", "id", "account", "accounts", "admin", "api", "app", "apps", "cloud", "cdn", "static",
                        "assets", "images", "img", "media", "m", "mobile", "blog", "shop", "store", "support", "help", "helpdesk", "ticket", "status", "docs",
                        "dev", "test", "staging", "beta", "demo", "crm", "erp", "hr", "payroll", "calendar", "meet", "teams", "voip", "pbx", "phone", "print",
                        "backup", "monitor", "dashboard", "cpanel", "webdisk", "whm", "secure", "cp"]

    /// Well-known TXT names: email security (DMARC, MTA-STS, TLS reporting, BIMI) and common DKIM selectors
    /// (Microsoft 365, Google Workspace, Mailchimp, generic).
    static let txtNames = ["_dmarc", "_mta-sts", "_smtp._tls", "default._bimi",
                           "selector1._domainkey", "selector2._domainkey", "google._domainkey",
                           "k1._domainkey", "default._domainkey", "s1._domainkey", "s2._domainkey"]

    /// Everything "All" asks about a name. (ANY isn't used: most servers refuse it now.)
    static func allQueries(_ name: String) -> [(name: String, type: String)] {
        let n = name.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var q: [(String, String)] = ["A", "AAAA", "CNAME", "MX", "NS", "SOA", "TXT", "CAA"].map { (n, $0) }
        q += txtNames.map { ("\($0).\(n)", "TXT") }
        q += hosts.map { ("\($0).\(n)", "A") }
        q += services.map { ("\($0).\(n)", "SRV") }
        return q
    }

    /// dig's arguments. Callers check `HostName.isValid(name)` first; the name goes after -q (or -x) so dig
    /// can never read it as an option.
    static func arguments(name: String, type: String, server: String) -> [String] {
        var args = ["+noall", "+answer", "+stats", "+time=3", "+tries=1"]
        let s = server.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { args.append("@\(s)") }
        let n = name.trimmingCharacters(in: .whitespaces)
        if type == "PTR" || (IPv4(n) != nil && type == "A") { args += ["-x", n] } else { args += ["-q", n, type] }
        return args
    }

    /// Only the records that belong to the name asked about. A lookup of autodiscover.example.com that
    /// CNAMEs to autodiscover.outlook.com keeps that CNAME, but not what outlook.com's own records say next.
    static func ownRecords(_ answers: [DNSAnswer], asked: String) -> [DNSAnswer] {
        arrange(answers, asked: asked, follow: false)
    }

    /// The asked name's own records (depth 0). With `follow`, also the records of the names its CNAMEs point to,
    /// each one level deeper than the CNAME it came from, kept right after it.
    static func arrange(_ answers: [DNSAnswer], asked: String, follow: Bool) -> [DNSAnswer] {
        func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        var depth: [String: Int] = [norm(asked): 0]
        var out: [DNSAnswer] = []
        for var a in answers {
            guard let d = depth[norm(a.name)] else { continue }
            a.depth = d
            if d == 0 || follow { out.append(a) }
            if a.type == "CNAME", depth[norm(a.data)] == nil { depth[norm(a.data)] = d + 1 }
        }
        return out
    }

    /// 10.0.0.5 → 5.0.0.10.in-addr.arpa (the name a PTR answer is filed under).
    static func reverseName(_ ip: IPv4) -> String {
        let v = ip.value
        return "\(v & 0xFF).\((v >> 8) & 0xFF).\((v >> 16) & 0xFF).\(v >> 24).in-addr.arpa"
    }

    /// The name dig's answers are filed under for this question.
    static func askedName(_ name: String, type: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let ip = IPv4(n), type == "PTR" || type == "A" { return reverseName(ip) }
        return n
    }

    static func parse(_ text: String) -> (answers: [DNSAnswer], ms: Int?, server: String?) {
        var answers: [DNSAnswer] = [], ms: Int? = nil, server: String? = nil
        for raw in text.split(whereSeparator: \.isNewline).map(String.init) {
            if raw.hasPrefix(";; Query time:") {
                ms = Int(raw.split(separator: " ").dropFirst(3).first ?? "")
            } else if raw.hasPrefix(";; SERVER:") {
                server = raw.split(separator: " ").dropFirst(2).first.map { String($0.split(separator: "#").first ?? "") }
            } else if !raw.hasPrefix(";"), !raw.isEmpty {
                let f = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard f.count >= 5, let ttl = Int(f[1]) else { continue }
                var name = f[0]; if name.hasSuffix(".") { name.removeLast() }
                answers.append(DNSAnswer(name: name, type: f[3], ttl: ttl, data: f[4...].joined(separator: " ")))
            }
        }
        return (answers, ms, server)
    }
}

// MARK: - Subnet calculator

struct SubnetInfo: Equatable {
    let address: IPv4, prefix: Int
    var mask: IPv4 { IPv4(prefix == 0 ? 0 : ~UInt32(0) << UInt32(32 - prefix)) }
    var network: IPv4 { IPv4(address.value & mask.value) }
    var wildcard: IPv4 { IPv4(~mask.value) }
    var broadcast: IPv4 { IPv4(network.value | ~mask.value) }
    var hosts: UInt64 { prefix >= 31 ? (prefix == 31 ? 2 : 1) : (UInt64(1) << UInt64(32 - prefix)) - 2 }
    var firstHost: IPv4 { prefix >= 31 ? network : IPv4(network.value + 1) }
    var lastHost: IPv4 { prefix >= 31 ? broadcast : IPv4(broadcast.value - 1) }
    var cidr: String { "\(network)/\(prefix)" }

    var kind: String {
        let v = address.value
        func inNet(_ n: String, _ p: Int) -> Bool { SubnetInfo(address: IPv4(n)!, prefix: p).network.value == (v & SubnetInfo(address: IPv4(n)!, prefix: p).mask.value) }
        if inNet("10.0.0.0", 8) || inNet("172.16.0.0", 12) || inNet("192.168.0.0", 16) { return "Private (RFC 1918)" }
        if inNet("100.64.0.0", 10) { return "Carrier-grade NAT (RFC 6598)" }
        if inNet("169.254.0.0", 16) { return "Link-local (no DHCP answer)" }
        if inNet("127.0.0.0", 8) { return "Loopback" }
        if inNet("224.0.0.0", 4) { return "Multicast" }
        return "Public"
    }

    /// "172.16.8.20/22", "172.16.8.20 255.255.252.0" or "172.16.8.20" (/32).
    static func parse(_ text: String) -> SubnetInfo? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == "/" || $0 == " " }).map(String.init)
        guard let first = parts.first, let ip = IPv4(first) else { return nil }
        if parts.count == 1 { return SubnetInfo(address: ip, prefix: 32) }
        if let p = Int(parts[1].replacingOccurrences(of: "/", with: "")), (0...32).contains(p), !parts[1].contains(".") {
            return SubnetInfo(address: ip, prefix: p)
        }
        guard let m = IPv4(parts[1]) else { return nil }
        let bits = m.value.nonzeroBitCount
        guard bits == 0 || m.value == ~UInt32(0) << UInt32(32 - bits) else { return nil }   // must be contiguous
        return SubnetInfo(address: ip, prefix: bits)
    }
}

// MARK: - Connection info

struct ConnectionInfo {
    var interface = "", address = "", prefix = 0, router = "", dhcpServer = "", dns: [String] = [], domain = ""
    var leaseStart: Date? = nil, leaseEnd: Date? = nil
    var ipv6: [String] = [], mac = "", mtu = "", link = ""

    /// `ipconfig getpacket` answers, kept for 2 s per adapter: one scan asks for the lease, the router and
    /// the connection details within moments of each other, so the command runs once instead of three times.
    private final class PacketCache: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: (at: Date, fields: [String: [String]])] = [:]
        func get(_ k: String) -> [String: [String]]? {
            lock.lock(); defer { lock.unlock() }
            guard let i = items[k], Date().timeIntervalSince(i.at) < 2 else { return nil }
            return i.fields
        }
        func set(_ k: String, _ v: [String: [String]]) { lock.lock(); items[k] = (Date(), v); lock.unlock() }
    }
    private static let packets = PacketCache()

    /// This Mac's DHCP lease on an adapter, as field → values (empty when it has none).
    static func packet(_ bsdName: String) -> [String: [String]] {
        if let p = packets.get(bsdName) { return p }
        guard let r = Command.run("/usr/sbin/ipconfig", ["getpacket", bsdName], timeout: 3), r.ok else { return [:] }
        let p = parsePacket(r.out)
        packets.set(bsdName, p)
        return p
    }

    /// Just the DHCP server and DNS servers from this Mac's lease on an adapter (blank if it has none).
    static func lease(_ bsdName: String) -> (dhcp: String, dns: [String]) {
        let p = packet(bsdName)
        return (p["server_identifier"]?.first ?? "", p["domain_name_server"] ?? [])
    }

    /// Just the router (default gateway) from this Mac's lease on an adapter.
    static func router(_ bsdName: String) -> String {
        packet(bsdName)["router"]?.first ?? ""
    }

    static func read(_ iface: NetInterface) -> ConnectionInfo {
        var c = ConnectionInfo()
        c.interface = iface.bsdName
        c.address = iface.address.description
        c.prefix = iface.netmask.value.nonzeroBitCount
        c.mac = Interfaces.macAddresses()[iface.bsdName] ?? ""
        let p = packet(iface.bsdName)
        if !p.isEmpty {
            c.router = p["router"]?.first ?? ""
            c.dhcpServer = p["server_identifier"]?.first ?? ""
            c.dns = p["domain_name_server"] ?? []
            c.domain = p["domain_name"]?.first ?? ""
        }
        if let r = Command.run("/usr/sbin/ipconfig", ["getsummary", iface.bsdName], timeout: 3) {
            (c.leaseStart, c.leaseEnd) = parseLease(r.out)
        }
        if let r = Command.run("/sbin/ifconfig", [iface.bsdName], timeout: 3) {
            for line in r.out.split(whereSeparator: \.isNewline) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if let m = t.range(of: "mtu ") { c.mtu = String(t[m.upperBound...].prefix { $0.isNumber }) }
                if t.hasPrefix("inet6 ") {
                    let a = t.split(separator: " ")[1].split(separator: "%")[0]
                    c.ipv6.append(String(a))
                }
                if t.hasPrefix("media:") { c.link = t.replacingOccurrences(of: "media: ", with: "") }
            }
        }
        c.ipv6.sort { (IPv6Neighbors.rank($0), $0) < (IPv6Neighbors.rank($1), $1) }
        return c
    }

    /// `ipconfig getpacket` lines: "router (ip_mult): {10.0.0.1}" → ["router": ["10.0.0.1"]].
    static func parsePacket(_ text: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let colon = line.range(of: "): ") else { continue }
            let key = line[..<colon.lowerBound].split(separator: " ").first.map(String.init) ?? ""
            var value = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("{") { value = String(value.dropFirst().dropLast()) }
            out[key] = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    static func parseLease(_ text: String) -> (Date?, Date?) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd/yyyy HH:mm:ss"
        var start: Date?, end: Date?
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("LeaseStartTime :") { start = f.date(from: String(t.dropFirst("LeaseStartTime :".count)).trimmingCharacters(in: .whitespaces)) }
            if t.hasPrefix("LeaseExpirationTime :") { end = f.date(from: String(t.dropFirst("LeaseExpirationTime :".count)).trimmingCharacters(in: .whitespaces)) }
        }
        return (start, end)
    }
}

// MARK: - Speed test (Apple's networkQuality)

struct SpeedResult: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var site: String
    var downMbps: Double, upMbps: Double, rpm: Double, idleMs: Double

    var rating: String { rpm >= 1000 ? "High" : rpm >= 200 ? "Medium" : "Low" }

    static func parse(_ json: Data, site: String) -> SpeedResult? {
        guard let d = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let dl = d["dl_throughput"] as? Double, let ul = d["ul_throughput"] as? Double else { return nil }
        return SpeedResult(date: Date(), site: site, downMbps: dl / 1_000_000, upMbps: ul / 1_000_000,
                           rpm: d["responsiveness"] as? Double ?? 0, idleMs: d["base_rtt"] as? Double ?? 0)
    }
}

@MainActor
final class SpeedJob: ObservableObject {
    @Published private(set) var running = false { didSet { Activity.shared.set(activityID, running) } }
    private let activityID = UUID()
    @Published private(set) var status = ""
    @Published private(set) var history: [SpeedResult] = []
    static let key = "speedTests"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([SpeedResult].self, from: data) { history = list }
    }

    var latest: SpeedResult? { history.first }

    func run(site: String) {
        guard !running else { return }
        running = true
        status = "Testing… about 20 seconds"
        Task {
            let r = await offMain { Command.run("/usr/bin/networkQuality", ["-c"], timeout: 60) }
            running = false
            guard let r, let result = SpeedResult.parse(Data(r.out.utf8), site: site) else {
                status = "The test didn’t finish. Is the internet reachable?"; return
            }
            history.insert(result, at: 0)
            if history.count > 50 { history.removeLast(history.count - 50) }
            if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: Self.key) }
            status = ""
        }
    }

    func clear() { history = []; UserDefaults.standard.removeObject(forKey: Self.key) }
}

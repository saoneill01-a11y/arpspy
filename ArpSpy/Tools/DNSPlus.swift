import Foundation
import Security

/// DNS Lookup's extra tabs (Email Check, Compare Servers, Expiry, Reverse Subnet) and Find subdomains.
/// Same checks as ARPradar for Windows (arpradar-windows/ui/dnsplus.js), using dig, URLSession and Security.
enum DNSPlus {

    // MARK: One question

    struct Reply: Sendable { var answers: [DNSAnswer]; var ms: Int?; var server: String? }

    /// Asks one question with dig. `server` empty = this Mac's DNS; it may be a name (ns1.example.com).
    /// A name that isn't a valid host name (it could be read as a dig option) gets an empty answer.
    static func ask(_ name: String, _ type: String, server: String) async -> Reply {
        guard HostName.isValid(name) else { return Reply(answers: [], ms: nil, server: nil) }
        let args = DNSTool.arguments(name: name, type: type, server: server)
        let r = await offMain { Command.run("/usr/bin/dig", args, timeout: 8) }
        let p = DNSTool.parse(r?.out ?? "")
        return Reply(answers: p.answers, ms: p.ms, server: p.server)
    }

    static func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    static func own(_ a: [DNSAnswer], _ name: String, _ type: String) -> [DNSAnswer] {
        a.filter { $0.type == type && norm($0.name) == norm(name) }
    }
    /// A TXT record's text without the quotes dig adds (long records come in several quoted pieces).
    static func txt(_ a: DNSAnswer) -> String {
        a.data.replacingOccurrences(of: "\" \"", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Runs `work` on every item, `limit` at a time, keeping the order.
    static func inParallel<I: Sendable, T: Sendable>(_ items: [I], limit: Int, _ work: @escaping @Sendable (I) async -> T) async -> [T] {
        var out = [T?](repeating: nil, count: items.count)
        var next = 0
        await withTaskGroup(of: (Int, T).self) { group in
            func add() { if next < items.count { let i = next; next += 1; group.addTask { (i, await work(items[i])) } } }
            for _ in 0..<min(limit, items.count) { add() }
            for await (i, v) in group { out[i] = v; add() }
        }
        return out.compactMap { $0 }
    }

    // MARK: Email Check

    enum State: String, Sendable { case good, warn, bad, info
        var mark: String { switch self { case .good: return "✓"; case .warn: return "!"; case .bad: return "✗"; case .info: return "–" } }
    }
    struct EmailRow: Identifiable, Sendable { let id = UUID(); var state: State; var check: String; var text: String; var detail: String = "" }

    static let dkimSelectors = ["selector1", "selector2", "google", "k1", "k2", "k3", "default", "s1", "s2", "dkim", "mail", "smtp",
                                "mandrill", "mxvault", "everlytickey1", "zoho", "protonmail"]

    /// SPF: follows include: and redirect= and counts the DNS lookups (the limit is 10).
    static func spfLookups(_ record: String, server: String, seen: inout Set<String>, depth: Int = 0) async -> Int {
        var count = 0
        for term in record.split(separator: " ").dropFirst().map(String.init) {
            var t = term.trimmingCharacters(in: CharacterSet(charactersIn: "+~?-"))
            // "a/24" and "mx/24" are still a and mx: the /prefix only widens the match.
            if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
            let parts = t.split(maxSplits: 1, whereSeparator: { $0 == ":" || $0 == "=" }).map(String.init)
            let mech = parts.first?.lowercased() ?? ""
            guard ["include", "a", "mx", "ptr", "exists", "redirect"].contains(mech) else { continue }
            count += 1
            if (mech == "include" || mech == "redirect"), parts.count == 2, depth < 10, !seen.contains(norm(parts[1])) {
                let target = norm(parts[1]); seen.insert(target)
                let r = await ask(target, "TXT", server: server)
                if let spf = own(r.answers, target, "TXT").map(txt).first(where: { $0.lowercased().hasPrefix("v=spf1") }) {
                    count += await spfLookups(spf, server: server, seen: &seen, depth: depth + 1)
                }
            }
        }
        return count
    }

    /// The five groups don't depend on each other, so they run at the same time; the rows keep their order.
    static func emailCheck(_ domain: String, server: String) async -> [EmailRow] {
        let d = norm(domain.trimmingCharacters(in: .whitespaces))
        async let mx = mxRows(d, server: server)
        async let spf = spfRows(d, server: server)
        async let dmarc = dmarcRows(d, server: server)
        async let dkim = dkimRows(d, server: server)
        async let extra = extraRows(d, server: server)
        return await mx + spf + dmarc + dkim + extra
    }

    /// MX, and whether each mail server's address has a reverse name.
    private static func mxRows(_ d: String, server: String) async -> [EmailRow] {
        let mx = own(await ask(d, "MX", server: server).answers, d, "MX").compactMap { a -> (Int, String)? in
            let f = a.data.split(separator: " "); guard f.count == 2, let p = Int(f[0]) else { return nil }
            return (p, norm(String(f[1])))
        }.sorted { $0.0 < $1.0 }
        if mx.isEmpty {
            return [EmailRow(state: .bad, check: "MX", text: "No mail servers (MX records): this domain can’t receive email.")]
        }
        let problems = await inParallel(mx.map(\.1), limit: 4) { host -> String? in
            let ips = await ask(host, "A", server: server).answers.filter { $0.type == "A" }.map(\.data)
            guard let ip = ips.first else { return "\(host): no address" }
            let ptr = await ask(ip, "PTR", server: server).answers.filter { $0.type == "PTR" }
            return ptr.isEmpty ? "\(host) (\(ip)): no reverse name" : nil
        }.compactMap { $0 }
        return [EmailRow(state: problems.isEmpty ? .good : .warn, check: "MX",
                         text: "\(mx.count) mail server\(mx.count == 1 ? "" : "s"): " + mx.map { "\($0.1) (\($0.0))" }.joined(separator: ", ") + ".",
                         detail: problems.isEmpty ? "All have addresses with reverse names."
                                                  : problems.joined(separator: "; ") + ". Other servers may distrust mail from an address without a reverse name.")]
    }

    private static func spfRows(_ d: String, server: String) async -> [EmailRow] {
        let spfs = own(await ask(d, "TXT", server: server).answers, d, "TXT").map(txt).filter { $0.lowercased().hasPrefix("v=spf1") }
        if spfs.isEmpty {
            return [EmailRow(state: .bad, check: "SPF", text: "No SPF record: anyone can send mail claiming to be from this domain.",
                             detail: "Add a TXT record starting v=spf1 that lists your mail services.")]
        }
        if spfs.count > 1 {
            return [EmailRow(state: .bad, check: "SPF", text: "More than one SPF record. Only one is allowed, so receivers treat SPF as broken.",
                             detail: spfs.joined(separator: "\n"))]
        }
        let spf = spfs[0]
        var seen = Set<String>()
        let n = await spfLookups(spf, server: server, seen: &seen)
        var state: State = n > 10 ? .bad : n >= 8 ? .warn : .good
        var notes = ["\(n) of 10 DNS lookups used" + (n > 10 ? " (over the limit: receivers treat SPF as broken)." : n >= 8 ? " (close to the limit)." : ".")]
        let allTerm = spf.split(separator: " ").map(String.init).first { $0.lowercased().hasSuffix("all") && $0.count <= 4 }
        switch allTerm?.first {
        case nil: notes.append("No “all” at the end, so mail from other servers isn’t covered."); if state == .good { state = .warn }
        case "+", "a": notes.append("Ends in +all: allows any server to send as this domain."); state = .bad
        case "?": notes.append("Ends in ?all (neutral): says nothing about other servers."); if state == .good { state = .warn }
        case "~": notes.append("Ends in ~all (soft fail): mail from other servers is marked, not refused.")
        default: notes.append("Ends in -all: mail from other servers is refused.")
        }
        return [EmailRow(state: state, check: "SPF", text: spf, detail: notes.joined(separator: " "))]
    }

    private static func dmarcRows(_ d: String, server: String) async -> [EmailRow] {
        guard let dmarc = own(await ask("_dmarc.\(d)", "TXT", server: server).answers, "_dmarc.\(d)", "TXT").map(txt)
            .first(where: { $0.lowercased().hasPrefix("v=dmarc1") }) else {
            return [EmailRow(state: .bad, check: "DMARC", text: "No DMARC record: nothing tells receivers what to do with mail that fails SPF and DKIM.",
                             detail: "Start with v=DMARC1; p=none; rua=mailto:… to collect reports, then tighten it.")]
        }
        func tag(_ k: String) -> String {
            dmarc.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.lowercased().hasPrefix(k + "=") }.map { String($0.dropFirst(k.count + 1)) } ?? ""
        }
        let p = tag("p").lowercased(), pct = tag("pct"), rua = tag("rua")
        let extra = [rua.isEmpty ? "No report address (rua), so nobody sees the results." : "Reports go to \(rua).",
                     !pct.isEmpty && pct != "100" ? "Only \(pct)% of failing mail is affected (pct)." : ""].filter { !$0.isEmpty }.joined(separator: " ")
        let partial = !pct.isEmpty && pct != "100"
        if p == "reject" { return [EmailRow(state: partial ? .warn : .good, check: "DMARC", text: "p=reject: mail that fails SPF and DKIM is refused.", detail: extra)] }
        if p == "quarantine" { return [EmailRow(state: partial ? .warn : .good, check: "DMARC", text: "p=quarantine: mail that fails SPF and DKIM goes to junk.", detail: extra)] }
        return [EmailRow(state: .bad, check: "DMARC", text: "p=none: reports only. Mail that fails SPF and DKIM is still delivered. Move to p=quarantine, then p=reject, once reports look clean.", detail: extra)]
    }

    /// DKIM: only the usual selector names can be checked.
    private static func dkimRows(_ d: String, server: String) async -> [EmailRow] {
        let found = await inParallel(dkimSelectors, limit: 8) { s -> String? in
            let a = await ask("\(s)._domainkey.\(d)", "TXT", server: server).answers
            let hit = a.contains { $0.type == "TXT" && (txt($0).contains("v=DKIM1") || txt($0).contains("p=")) } || a.contains { $0.type == "CNAME" }
            return hit ? s : nil
        }.compactMap { $0 }
        let vendor = found.contains("selector1") || found.contains("selector2") ? " (Microsoft 365)" : found.contains("google") ? " (Google Workspace)" : ""
        return [found.isEmpty
            ? EmailRow(state: .warn, check: "DKIM", text: "None of the usual selector names found.", detail: "DKIM may still be set up under another name; check the mail service’s settings.")
            : EmailRow(state: .good, check: "DKIM", text: "Found \(found.joined(separator: " and "))\(vendor).")]
    }

    /// MTA-STS, TLS reports, BIMI, DNSSEC.
    private static func extraRows(_ d: String, server: String) async -> [EmailRow] {
        @Sendable func one(_ n: String, _ prefix: String) async -> String? {
            own(await ask(n, "TXT", server: server).answers, n, "TXT").map(txt).first { $0.lowercased().hasPrefix(prefix) }
        }
        async let sts = one("_mta-sts.\(d)", "v=stsv1")
        async let tls = one("_smtp._tls.\(d)", "v=tlsrptv1")
        async let bimi = one("default._bimi.\(d)", "v=bimi1")
        async let ds = ask(d, "DS", server: server).answers.filter { $0.type == "DS" }
        let (s, t, b, signed) = await (sts, tls, bimi, !ds.isEmpty)
        return [
            EmailRow(state: s == nil ? .warn : .good, check: "MTA-STS", text: s ?? "Not set up. Optional: makes other servers use encryption when sending to you."),
            EmailRow(state: t == nil ? .warn : .good, check: "TLS reports", text: t ?? "Not set up. Optional: reports when other servers can’t deliver securely."),
            EmailRow(state: .info, check: "BIMI", text: b ?? "Not set up (optional: shows your logo in some mail apps)."),
            EmailRow(state: signed ? .good : .info, check: "DNSSEC",
                     text: signed ? "Signed (DS record at the registry)." : "Not signed (most domains aren’t). Shown for information only."),
        ]
    }

    // MARK: Compare Servers

    struct CompareRow: Identifiable, Sendable {
        let id = UUID()
        var label: String, server: String
        var answer = "", ttl: Int? = nil, ms: Int? = nil
        var failed = false, aliasOnly = false, different = false
    }

    /// The zone a name lives in and its own name servers: walks up the name until a level has NS records.
    static func ownNameServers(_ name: String) async -> (zone: String, ns: [String]) {
        let labels = norm(name).split(separator: ".").map(String.init)
        for i in 0..<max(0, labels.count - 1) {
            let zone = labels[i...].joined(separator: ".")
            let ns = own(await ask(zone, "NS", server: "").answers, zone, "NS").map { norm($0.data) }
            if !ns.isEmpty { return (zone, ns.sorted()) }
        }
        return ("", [])
    }

    static func compare(_ name: String, type: String, servers: [(label: String, server: String)]) async -> (rows: [CompareRow], differ: Bool) {
        var rows = await inParallel(servers, limit: 8) { s -> CompareRow in
            var row = CompareRow(label: s.label, server: s.server)
            let r = await ask(name, type, server: s.server)
            let ans = r.answers.filter { $0.type == type }
            row.ms = r.ms
            if ans.isEmpty, type != "CNAME", let c = r.answers.first(where: { $0.type == "CNAME" }) {
                // A domain's own name servers often answer an alias with just the CNAME: not a different answer.
                row.answer = "→ alias for \(norm(c.data))"; row.ttl = c.ttl; row.aliasOnly = true
            } else if ans.isEmpty {
                row.answer = r.ms == nil ? "no answer from this server" : "(no answer)"; row.failed = r.ms == nil
            } else {
                row.answer = ans.map(\.data).sorted().joined(separator: "\n"); row.ttl = ans.map(\.ttl).min()
            }
            return row
        }
        let counted = rows.filter { !$0.failed && !$0.aliasOnly }
        let usual = Dictionary(grouping: counted, by: \.answer).max { $0.value.count < $1.value.count }?.key
        for i in rows.indices { rows[i].different = !rows[i].failed && !rows[i].aliasOnly && rows[i].answer != usual }
        return (rows, Set(counted.map(\.answer)).count > 1)
    }

    static func soaSerials(zone: String, ns: [String]) async -> [(ns: String, serial: String)] {
        await inParallel(ns, limit: 6) { n -> (String, String) in
            let s = own(await ask(zone, "SOA", server: n).answers, zone, "SOA").first
            return (n, s.map { String($0.data.split(separator: " ").dropFirst(2).first ?? "") } ?? "(no answer)")
        }.map { (ns: $0.0, serial: $0.1) }
    }

    // MARK: Expiry

    struct Registration: Sendable { var registrar = "", expires: Date? = nil, nameServers: [String] = [], dnssec: Bool? = nil }
    struct Cert: Identifiable, Sendable {
        let id = UUID()
        var host: String, port: Int
        var expires: Date? = nil, issuer = "", names: [String] = [], coversHost = false, problem = ""
    }
    struct ExpiryResult: Sendable { var registration: Registration?; var registrationProblem = ""; var certs: [Cert] }

    static let expiryHosts = ["", "www", "mail", "autodiscover", "remote", "vpn", "portal", "owa", "webmail", "sso"]
    static func daysLeft(_ d: Date?) -> Int? { d.map { Int(floor($0.timeIntervalSinceNow / 86_400)) } }

    static func json(_ url: String, timeout: TimeInterval) async -> (status: Int, value: Any?) {
        guard let u = URL(string: url) else { return (0, nil) }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.setValue("ARPradar", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, application/rdap+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return (0, nil) }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data))
    }

    /// A domain name made safe for a URL: checked as a host name, then everything but letters, digits, "." and "-"
    /// percent-encoded (so "&" or "/" can't change the request). Nil when it isn't a valid name.
    static func urlSafe(_ domain: String) -> String? {
        let d = norm(domain)
        guard HostName.isValid(d), IPv4(d) == nil else { return nil }
        return d.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-")))
    }

    /// Domain registration from the public RDAP service (rdap.org sends you on to the registry).
    static func rdap(_ domain: String) async -> (Registration?, String) {
        let d = norm(domain)
        guard let safe = urlSafe(d) else { return (nil, HostName.problem) }
        let (status, value) = await json("https://rdap.org/domain/\(safe)", timeout: 15)
        if status == 404 { return (nil, "No registration found for \(d) (is it the main domain, like example.com?).") }
        guard status == 200, let v = value as? [String: Any] else { return (nil, status == 0 ? "Couldn’t reach rdap.org." : "The registration service answered \(status).") }
        var r = Registration()
        let iso = ISO8601DateFormatter()
        for e in v["events"] as? [[String: Any]] ?? [] where e["eventAction"] as? String == "expiration" {
            r.expires = (e["eventDate"] as? String).flatMap { iso.date(from: $0) ?? ScanTransfer.date($0) }
        }
        for ent in v["entities"] as? [[String: Any]] ?? [] where (ent["roles"] as? [String] ?? []).contains("registrar") {
            if let card = ent["vcardArray"] as? [Any], card.count > 1, let items = card[1] as? [[Any]],
               let fn = items.first(where: { ($0.first as? String) == "fn" }), fn.count > 3 { r.registrar = fn[3] as? String ?? "" }
        }
        r.nameServers = (v["nameservers"] as? [[String: Any]] ?? []).compactMap { ($0["ldhName"] as? String)?.lowercased() }
        r.dnssec = (v["secureDNS"] as? [String: Any])?["delegationSigned"] as? Bool
        return (r, "")
    }

    /// Captures the certificate a server sends, then cancels (accepts expired or mismatched ones, to report them).
    final class CertGrabber: NSObject, URLSessionDelegate, @unchecked Sendable {
        var cert: SecCertificate?
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let t = challenge.protectionSpace.serverTrust {
                cert = (SecTrustCopyCertificateChain(t) as? [SecCertificate])?.first
            }
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    static func cert(host: String, port: Int) async -> Cert {
        var out = Cert(host: host, port: port)
        guard let url = URL(string: "https://\(host)\(port == 443 ? "" : ":\(port)")/") else { out.problem = "bad name"; return out }
        let grabber = CertGrabber()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        let session = URLSession(configuration: config, delegate: grabber, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var req = URLRequest(url: url); req.httpMethod = "HEAD"
        _ = try? await session.data(for: req)
        guard let c = grabber.cert else { out.problem = "no HTTPS answer"; return out }
        let keys = [kSecOIDX509V1ValidityNotAfter, kSecOIDSubjectAltName, kSecOIDX509V1IssuerName] as CFArray
        let values = SecCertificateCopyValues(c, keys, nil) as? [String: Any] ?? [:]
        func val(_ k: CFString) -> Any? { (values[k as String] as? [String: Any])?[kSecPropertyKeyValue as String] }
        if let n = val(kSecOIDX509V1ValidityNotAfter) as? NSNumber { out.expires = Date(timeIntervalSinceReferenceDate: n.doubleValue) }
        for item in val(kSecOIDSubjectAltName) as? [[String: Any]] ?? [] where (item[kSecPropertyKeyLabel as String] as? String) == "DNS Name" {
            if let s = item[kSecPropertyKeyValue as String] as? String { out.names.append(s) }
        }
        let issuer = val(kSecOIDX509V1IssuerName) as? [[String: Any]] ?? []
        func part(_ oid: String) -> String? { issuer.first { ($0[kSecPropertyKeyLabel as String] as? String) == oid }?[kSecPropertyKeyValue as String] as? String }
        out.issuer = part("2.5.4.10") ?? part("2.5.4.3") ?? ""
        if out.names.isEmpty, let cn = SecCertificateCopySubjectSummary(c) as String? { out.names = [cn] }
        let h = host.lowercased()
        out.coversHost = out.names.contains { n in
            let n = n.lowercased()
            if n == h { return true }
            if n.hasPrefix("*."), let dot = h.firstIndex(of: ".") { return String(h[h.index(after: dot)...]) == String(n.dropFirst(2)) }
            return false
        }
        return out
    }

    static func expiry(_ domain: String, server: String) async -> ExpiryResult {
        let d = norm(domain)
        async let reg = rdap(d)
        let hosts = expiryHosts.map { $0.isEmpty ? d : "\($0).\(d)" }
        let exists = await inParallel(hosts, limit: 8) { h in await ask(h, "A", server: server).answers.contains { $0.type == "A" || $0.type == "CNAME" } }
        let live = zip(hosts, exists).filter(\.1).map(\.0)
        let certs = await inParallel(live, limit: 6) { h -> Cert in
            var c = await cert(host: h, port: 443)
            if c.expires == nil, h.hasPrefix("remote.") || h.hasPrefix("vpn.") {
                for p in [4443, 8443] { let c2 = await cert(host: h, port: p); if c2.expires != nil { c = c2; break } }
            }
            return c
        }
        let (r, problem) = await reg
        return ExpiryResult(registration: r, registrationProblem: problem, certs: certs)
    }

    /// The rows saved for an organization (and shown in the site survey).
    static func expiryRows(_ e: ExpiryResult) -> [[String]] {
        func f(_ d: Date?) -> String { d.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "" }
        var rows: [[String]] = []
        if let r = e.registration {
            rows.append(["Domain registration", r.expires.map { "\(f($0)) (\(daysLeft($0) ?? 0) days)" } ?? "unknown", r.registrar,
                         r.nameServers.joined(separator: ", ") + (r.dnssec.map { " · DNSSEC \($0 ? "signed" : "not signed")" } ?? "")])
        } else { rows.append(["Domain registration", "", "", e.registrationProblem]) }
        for c in e.certs {
            let d = daysLeft(c.expires) ?? 0
            let names = c.names.count > 3 ? c.names.prefix(3).joined(separator: ", ") + " and \(c.names.count - 3) more" : c.names.joined(separator: ", ")
            rows.append(["\(c.host)\(c.port == 443 ? "" : ":\(c.port)")", c.expires.map { "\(f($0)) (\(d < 0 ? "expired" : "\(d) days"))" } ?? c.problem, c.issuer,
                         c.expires == nil ? "" : (c.coversHost ? "" : "DOESN’T COVER THIS NAME · ") + names])
        }
        return rows
    }

    // MARK: Reverse Subnet

    /// PTR names for every address in a range (at most 4,096). The questions go straight to the DNS server
    /// over UDP, all at once (`NameLookup.dnsPTR`, the same code the scan uses), with a second round for any
    /// that didn't answer; one dig per address took minutes on a /22. Falls back to dig when the server
    /// can't be worked out (an odd name, or this Mac has no DNS server set).
    static func reverse(_ range: String, server: String) async throws -> [(ip: String, name: String)] {
        let ips = Array(try IPRangeParser.parse(range).prefix(4096))
        let srv = server.trimmingCharacters(in: .whitespaces)
        guard let dns = await offMain({ srv.isEmpty ? systemDNS() : Resolver.ipv4(srv) }) else {
            let names = await inParallel(ips.map(\.description), limit: 32) { ip in
                await ask(ip, "PTR", server: srv).answers.filter { $0.type == "PTR" }.map { norm($0.data) }.joined(separator: ", ")
            }
            return zip(ips, names).map { (ip: $0.description, name: $1) }
        }
        var found = await offMain { NameLookup.dnsPTR(ips, server: dns, timeout: 3, flag: CancelFlag()) }
        let missing = ips.filter { found[$0.value] == nil }
        if !missing.isEmpty, missing.count < ips.count {
            for (ip, name) in await offMain({ NameLookup.dnsPTR(missing, server: dns, timeout: 3, flag: CancelFlag()) }) { found[ip] = name }
        }
        return ips.map { (ip: $0.description, name: found[$0.value].map(norm) ?? "") }
    }

    /// The first DNS server this Mac uses (macOS keeps /etc/resolv.conf up to date).
    static func systemDNS() -> IPv4? {
        guard let text = try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.count >= 2, f[0] == "nameserver", let ip = IPv4(String(f[1])) { return ip }
        }
        return nil
    }

    // MARK: Subdomains from the certificate logs

    /// Every name under `domain` that has appeared in a public HTTPS certificate, without wildcards.
    /// Asks crt.sh (full history) first; Cert Spotter (current certificates) when crt.sh is busy, which is often.
    static func subdomains(_ domain: String) async -> (names: [String], source: String, problem: String) {
        let d = norm(domain)
        guard let safe = urlSafe(d) else { return ([], "", HostName.problem) }
        var names = Set<String>()
        func add(_ raw: String) {
            let n = raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "*.", with: "")
            // Only well-formed names under the domain: these come from a public log, and get looked up next.
            if (n.hasSuffix(".\(d)") || n == d) && HostName.isValid(n) { names.insert(n) }
        }
        let (status, value) = await json("https://crt.sh/?q=%25.\(safe)&output=json", timeout: 25)
        if status == 200, let list = value as? [[String: Any]] {
            for e in list { for k in ["name_value", "common_name"] { (e[k] as? String ?? "").split(separator: "\n").forEach { add(String($0)) } } }
            return (names.sorted(), "crt.sh", "")
        }
        var after = ""
        for _ in 0..<5 {
            let (st, v) = await json("https://api.certspotter.com/v1/issuances?domain=\(safe)&include_subdomains=true&expand=dns_names\(after)", timeout: 20)
            if st == 429 { break }
            guard st == 200, let list = v as? [[String: Any]] else {
                return (names.sorted(), "", "The certificate log services are busy (crt.sh didn’t answer, Cert Spotter answered \(st)). Try again later.")
            }
            for e in list { (e["dns_names"] as? [String] ?? []).forEach(add) }
            guard list.count >= 100, let id = list.last?["id"] as? String,
                  let safeID = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { break }
            after = "&after=\(safeID)"
        }
        return (names.sorted(), "Cert Spotter (crt.sh was busy)", "")
    }
}

import Foundation
import Darwin

/// Runs blocking work on a background thread and waits for it without tying up Swift's task threads.
func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in
        DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) }
    }
}

/// A small thread-safe dictionary for collecting results from many threads.
final class Collector<K: Hashable, V>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [K: V] = [:]
    func set(_ k: K, _ v: V) { lock.lock(); items[k] = v; lock.unlock() }
    var all: [K: V] { lock.lock(); defer { lock.unlock() }; return items }
}

// MARK: - Web pages

/// Reads web pages on devices. Accepts self-signed certificates (almost every router, NAS and
/// camera has one); we only read the page, we never send anything to it.
enum Web {
    final class TrustingDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        /// A device may redirect its home page (http → https, / → /login). Follow that only on the device itself:
        /// a redirect to another address (the internet, another device on the LAN) is not followed, so a device
        /// can't make the scanner fetch an arbitrary URL or show another host's page title as its own.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            let from = task.originalRequest?.url?.host?.lowercased()
            let to = request.url?.host?.lowercased()
            completionHandler(from != nil && from == to ? request : nil)
        }
    }

    static func session(timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 1
        config.httpMaximumConnectionsPerHost = 2
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = ["User-Agent": "ARPradar"]
        return URLSession(configuration: config, delegate: TrustingDelegate(), delegateQueue: nil)
    }

    /// The URL to read for a device's home page, from its open ports.
    static func homeURL(ip: IPv4, ports: [UInt16]) -> URL? {
        let p = Set(ports)
        if p.contains(443) { return URL(string: "https://\(ip)/") }
        if p.contains(80) { return URL(string: "http://\(ip)/") }
        if p.contains(8443) { return URL(string: "https://\(ip):8443/") }
        if p.contains(8080) { return URL(string: "http://\(ip):8080/") }
        return nil
    }

    /// Fetches every URL at once and returns the bodies of the ones that answered 2xx/3xx.
    static func fetch(_ urls: [UInt32: URL], timeout: TimeInterval, flag: CancelFlag) -> [UInt32: Data] {
        guard !urls.isEmpty else { return [:] }
        let s = session(timeout: timeout)
        defer { s.invalidateAndCancel() }
        let out = Collector<UInt32, Data>()
        let group = DispatchGroup()
        var tasks: [URLSessionDataTask] = []
        for (ip, url) in urls {
            group.enter()
            let t = s.dataTask(with: url) { data, response, _ in
                defer { group.leave() }
                guard let data, let http = response as? HTTPURLResponse, http.statusCode < 400 else { return }
                out.set(ip, data.prefix(256 * 1024))
            }
            tasks.append(t); t.resume()
        }
        let deadline = Date().addingTimeInterval(timeout + 1)
        while group.wait(timeout: .now() + 0.2) == .timedOut {
            if flag.isCancelled || Date() > deadline { tasks.forEach { $0.cancel() }; break }
        }
        return out.all
    }

    /// Page titles for devices with a web port open.
    static func titles(_ ports: [UInt32: [UInt16]], timeout: TimeInterval, flag: CancelFlag) -> [UInt32: String] {
        var urls: [UInt32: URL] = [:]
        for (ip, list) in ports { if let u = homeURL(ip: IPv4(ip), ports: list) { urls[ip] = u } }
        return fetch(urls, timeout: timeout, flag: flag).compactMapValues { title(in: $0) }
    }

    static func title(in data: Data) -> String? {
        title(in: String(decoding: data, as: UTF8.self))
    }

    /// The text of the first <title>…</title>, tidied up. Nil if missing or empty.
    static func title(in html: String) -> String? {
        guard let open = html.range(of: "<title[^>]*>", options: [.regularExpression, .caseInsensitive]),
              let close = html.range(of: "</title>", options: .caseInsensitive, range: open.upperBound..<html.endIndex)
        else { return nil }
        let raw = decodeEntities(String(html[open.upperBound..<close.lowerBound]))
        let t = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !t.isEmpty else { return nil }
        return t.count > 100 ? String(t.prefix(100)) + "…" : t
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                       ("&apos;", "'"), ("&nbsp;", " "), ("&ndash;", "–"), ("&mdash;", "—")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        // Numeric entities like &#8211; or &#x2013;
        while let r = out.range(of: "&#[xX]?[0-9a-fA-F]+;", options: .regularExpression) {
            let body = out[r].dropFirst(2).dropLast()
            let value = body.first == "x" || body.first == "X" ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
            out.replaceSubrange(r, with: value.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? "")
        }
        return out
    }
}

// MARK: - UPnP / SSDP

/// Asks the network "who's out there?" over SSDP (multicast 239.255.255.250:1900). TVs, speakers,
/// streamers, routers, NAS boxes and printers answer with a link to an XML file that names their model.
enum UPnP {
    static func search(_ st: String) -> [UInt8] {
        Array(("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\n"
               + "MX: 2\r\nST: \(st)\r\nUSER-AGENT: macOS UPnP/1.1 ARPradar/1.0\r\n\r\n").utf8)
    }

    static func discover(_ wanted: Set<UInt32>, timeout: TimeInterval, flag: CancelFlag) -> [UInt32: UPnPInfo] {
        guard !wanted.isEmpty else { return [:] }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        Sockets.setNonBlocking(fd)
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        let group: UInt32 = 0xEFFFFFFA   // 239.255.255.250
        for round in 0..<2 {
            Sockets.send(fd, search("upnp:rootdevice"), to: group, port: 1900)
            Sockets.send(fd, search("ssdp:all"), to: group, port: 1900)
            if round == 0 { usleep(300_000) }
        }

        var locations: [UInt32: URL] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !flag.isCancelled {
            guard Sockets.waitReadable(fd, seconds: deadline.timeIntervalSinceNow) else { continue }
            while let packet = Sockets.receive(fd, into: &buffer) {
                guard wanted.contains(packet.from), locations[packet.from] == nil,
                      let loc = location(in: String(decoding: buffer[0..<packet.count], as: UTF8.self)),
                      let url = URL(string: loc),
                      url.host == IPv4(packet.from).description      // only read files on the device itself
                else { continue }
                locations[packet.from] = url
            }
        }
        return Web.fetch(locations, timeout: 3, flag: flag).compactMapValues { parseDescription($0) }
    }

    /// The LOCATION header of an SSDP reply.
    static func location(in reply: String) -> String? {
        for line in reply.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "location" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func parseDescription(_ data: Data) -> UPnPInfo? {
        let xml = String(decoding: data, as: UTF8.self)
        func tag(_ name: String) -> String {
            guard let o = xml.range(of: "<\(name)>", options: .caseInsensitive),
                  let c = xml.range(of: "</\(name)>", options: .caseInsensitive, range: o.upperBound..<xml.endIndex)
            else { return "" }
            return Web.decodeEntities(String(xml[o.upperBound..<c.lowerBound])).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let maker = tag("manufacturer"), modelName = tag("modelName"), number = tag("modelNumber")
        var model = modelName
        if !number.isEmpty && !modelName.localizedCaseInsensitiveContains(number) { model += (model.isEmpty ? "" : " ") + number }
        let firstWord = maker.split(separator: " ").first.map(String.init) ?? maker
        if !maker.isEmpty && !model.localizedCaseInsensitiveContains(firstWord) { model = maker + (model.isEmpty ? "" : " " + model) }
        let info = UPnPInfo(friendlyName: tag("friendlyName"), model: model.trimmingCharacters(in: .whitespaces))
        return info.friendlyName.isEmpty && info.model.isEmpty ? nil : info
    }
}

// MARK: - SNMP

/// SNMP v2c "get" of sysDescr, sysName and sysLocation (UDP 161). Switches, access points,
/// printers, UPSes and NAS boxes answer when SNMP is on and the community matches.
enum SNMP {
    static let sysDescr: [UInt32] = [1, 3, 6, 1, 2, 1, 1, 1, 0]
    static let sysName: [UInt32] = [1, 3, 6, 1, 2, 1, 1, 5, 0]
    static let sysLocation: [UInt32] = [1, 3, 6, 1, 2, 1, 1, 6, 0]

    static func query(_ targets: [IPv4], community: String, timeout: TimeInterval, flag: CancelFlag) -> [UInt32: SNMPInfo] {
        guard !targets.isEmpty, !community.isEmpty else { return [:] }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        Sockets.setNonBlocking(fd)
        let packet = request(community: community, id: 0x4152)
        for (i, t) in targets.enumerated() {
            if flag.isCancelled { return [:] }
            Sockets.send(fd, packet, to: t.value, port: 161)
            if i % 64 == 63 { usleep(2_000) }
        }
        let wanted = Set(targets.map(\.value))
        var out: [UInt32: SNMPInfo] = [:]
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !flag.isCancelled {
            guard Sockets.waitReadable(fd, seconds: deadline.timeIntervalSinceNow) else { continue }
            while let p = Sockets.receive(fd, into: &buffer) {
                if wanted.contains(p.from), let info = parseResponse(Array(buffer[0..<p.count])) { out[p.from] = info }
            }
        }
        return out
    }

    // BER encoding
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let n = content.count
        let len: [UInt8] = n < 128 ? [UInt8(n)] : n < 256 ? [0x81, UInt8(n)] : [0x82, UInt8(n >> 8), UInt8(n & 0xFF)]
        return [tag] + len + content
    }

    static func integer(_ v: Int32) -> [UInt8] {
        var bytes = withUnsafeBytes(of: v.bigEndian, Array.init)
        while bytes.count > 1 && ((bytes[0] == 0 && bytes[1] & 0x80 == 0) || (bytes[0] == 0xFF && bytes[1] & 0x80 != 0)) {
            bytes.removeFirst()
        }
        return tlv(0x02, bytes)
    }

    static func oid(_ parts: [UInt32]) -> [UInt8] {
        var out: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for var p in parts.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(p & 0x7F)]
            p >>= 7
            while p > 0 { chunk.insert(UInt8(p & 0x7F) | 0x80, at: 0); p >>= 7 }
            out += chunk
        }
        return tlv(0x06, out)
    }

    static func request(community: String, id: Int32) -> [UInt8] {
        let binds = [sysDescr, sysName, sysLocation].map { tlv(0x30, oid($0) + [0x05, 0x00]) }.joined()
        let pdu = tlv(0xA0, integer(id) + integer(0) + integer(0) + tlv(0x30, Array(binds)))
        return tlv(0x30, integer(1) + tlv(0x04, Array(community.utf8)) + pdu)   // version 1 = v2c
    }

    /// Reads one tag-length-value at `o`; returns the tag and where its content is.
    static func read(_ b: [UInt8], _ o: inout Int) -> (tag: UInt8, body: Range<Int>)? {
        guard o + 2 <= b.count else { return nil }
        let tag = b[o]
        var len = Int(b[o + 1]); var p = o + 2
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n >= 1, n <= 3, p + n <= b.count else { return nil }
            len = 0
            for i in 0..<n { len = len << 8 | Int(b[p + i]) }
            p += n
        }
        guard p + len <= b.count else { return nil }
        o = p + len
        return (tag, p..<(p + len))
    }

    static func decodeOID(_ b: ArraySlice<UInt8>) -> [UInt32] {
        guard let first = b.first else { return [] }
        var out: [UInt32] = [UInt32(first) / 40, UInt32(first) % 40]
        var v: UInt32 = 0
        for byte in b.dropFirst() {
            v = v << 7 | UInt32(byte & 0x7F)
            if byte & 0x80 == 0 { out.append(v); v = 0 }
        }
        return out
    }

    static func parseResponse(_ b: [UInt8]) -> SNMPInfo? {
        var o = 0
        guard let msg = read(b, &o), msg.tag == 0x30 else { return nil }
        o = msg.body.lowerBound
        guard read(b, &o)?.tag == 0x02, read(b, &o)?.tag == 0x04,          // version, community
              let pdu = read(b, &o), pdu.tag == 0xA2 else { return nil }      // GetResponse
        o = pdu.body.lowerBound
        guard read(b, &o) != nil, let err = read(b, &o), read(b, &o) != nil,  // id, error, index
              let list = read(b, &o), list.tag == 0x30 else { return nil }
        if err.body.contains(where: { b[$0] != 0 }) && err.body.count > 0 {
            // An error (e.g. noSuchName in v1) still means it answered, but there's nothing to show.
            return nil
        }
        var info = SNMPInfo()
        var p = list.body.lowerBound
        while p < list.body.upperBound, let bind = read(b, &p), bind.tag == 0x30 {
            var q = bind.body.lowerBound
            guard let name = read(b, &q), name.tag == 0x06, let value = read(b, &q) else { continue }
            guard value.tag == 0x04 else { continue }
            let text = clean(String(decoding: b[value.body], as: UTF8.self))
            switch decodeOID(b[name.body]) {
            case sysDescr: info.descr = text
            case sysName: info.name = text
            case sysLocation: info.location = text
            default: break
            }
        }
        return info.name.isEmpty && info.descr.isEmpty && info.location.isEmpty ? nil : info
    }

    static func clean(_ s: String) -> String {
        String(s.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Service banners

/// What answers on a port: the web server's name, or the greeting an SSH/FTP/SMTP server sends.
enum Banner {
    static let tlsPorts: Set<UInt16> = [443, 465, 636, 853, 993, 995, 4443, 5001, 5061, 5986, 6443, 7443, 8443, 8843, 8883, 9443]
    static let httpPorts: Set<UInt16> = [80, 81, 3000, 5000, 7000, 8000, 8008, 8060, 8080, 8081, 8088, 8123,
                                         8200, 8880, 8888, 9000, 9090, 9091, 9100, 10000, 32400]

    static func grabAll(ip: IPv4, ports: [UInt16], timeout: TimeInterval) -> [UInt16: String] {
        let out = Collector<UInt16, String>()
        let list = ports.filter { !tlsPorts.contains($0) }
        // All at once (not limited to the CPU count): each one mostly waits on the network.
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "arpspy.banners", attributes: .concurrent)
        for port in list.prefix(200) {
            queue.async(group: group) { if let b = grab(ip: ip, port: port, timeout: timeout) { out.set(port, b) } }
        }
        _ = group.wait(timeout: .now() + timeout * 2 + 1)
        return out.all
    }

    static func grab(ip: IPv4, port: UInt16, timeout: TimeInterval) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        Sockets.setNonBlocking(fd)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = Sockets.address(ip.value, port: port)
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if r != 0 {
            guard errno == EINPROGRESS else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return nil }
            var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { return nil }
        }
        let isHTTP = httpPorts.contains(port)
        if isHTTP {
            let req = Array("HEAD / HTTP/1.0\r\nHost: \(ip)\r\nUser-Agent: ARPradar\r\n\r\n".utf8)
            _ = req.withUnsafeBytes { write(fd, $0.baseAddress, req.count) }
        }
        var data: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, data.count < 4096 {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(max(1, deadline.timeIntervalSinceNow * 1000))) > 0 else { break }
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            data += buffer[0..<n]
            if !isHTTP && data.contains(0x0A) { break }
            if isHTTP && String(decoding: data, as: UTF8.self).contains("\r\n\r\n") { break }
        }
        return isHTTP ? httpServer(String(decoding: data, as: UTF8.self)) : firstLine(data)
    }

    /// "Server: nginx/1.24" → "nginx/1.24". A web server with no Server header → "Web server".
    static func httpServer(_ reply: String) -> String? {
        guard reply.hasPrefix("HTTP/") else { return nil }
        for line in reply.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "server" {
                let v = parts[1].trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { return String(v.prefix(80)) }
            }
        }
        return "Web server"
    }

    /// The first line a service sends, if it's readable text ("SSH-2.0-OpenSSH_9.6" → "OpenSSH 9.6").
    static func firstLine(_ data: [UInt8]) -> String? {
        guard !data.isEmpty else { return nil }
        let line = data.prefix { $0 != 0x0A && $0 != 0x0D }
        guard !line.isEmpty, line.allSatisfy({ (0x20...0x7E).contains($0) || $0 == 0x09 }) else { return nil }
        var s = String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("SSH-") {
            // SSH-2.0-OpenSSH_9.6p1 Ubuntu-3 → OpenSSH 9.6p1 Ubuntu-3
            let parts = s.split(separator: "-", maxSplits: 2)
            if parts.count == 3 { s = parts[2].replacingOccurrences(of: "_", with: " ") }
        } else if s.count > 4, s.prefix(3).allSatisfy(\.isNumber), s.dropFirst(3).first == " " || s.dropFirst(3).first == "-" {
            s = String(s.dropFirst(4))            // "220 printer FTP ready" → "printer FTP ready"
        }
        return s.isEmpty ? nil : String(s.prefix(80))
    }
}

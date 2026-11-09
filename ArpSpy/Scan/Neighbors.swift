import Foundation

/// Runs a command-line tool and returns what it printed (standard output only; what it printed to standard
/// error is read and dropped, so a warning can't spoil JSON output), or nil if it failed or took too long.
/// With `partialOnTimeout`, a tool that runs out of time returns what it had printed so far (ok: false) instead.
enum Command {
    /// Bytes read so far, from a background thread.
    private final class Bytes: @unchecked Sendable {
        private let lock = NSLock(); private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var all: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval, partialOnTimeout: Bool = false) -> (out: String, ok: Bool)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in done.signal() }
        do { try task.run() } catch { return nil }
        // Read both pipes while it runs, so a full pipe can't stall it.
        let bytes = Bytes()
        let reader = DispatchQueue(label: "arpspy.command")
        reader.async {
            let h = out.fileHandleForReading
            while true { let d = h.availableData; if d.isEmpty { break }; bytes.append(d) }
        }
        DispatchQueue.global(qos: .utility).async { _ = err.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            _ = done.wait(timeout: .now() + 1)
            return partialOnTimeout ? (String(decoding: bytes.all, as: UTF8.self), false) : nil
        }
        reader.sync {}
        return (String(decoding: bytes.all, as: UTF8.self), task.terminationStatus == 0)
    }
}

/// IPv6 addresses, from the Mac's IPv6 neighbor list (`ndp -an`), matched to devices by MAC.
/// Like MAC addresses, this only works on the Mac's own LAN.
enum IPv6Neighbors {
    /// Pings every IPv6 device on each interface (ff02::1), so the neighbor list is fresh.
    static func refresh(_ interfaces: [String], timeout: TimeInterval = 2) {
        let group = DispatchGroup()
        for name in Set(interfaces) {
            DispatchQueue.global().async(group: group) {
                _ = Command.run("/sbin/ping6", ["-c", "2", "-q", "ff02::1%\(name)"], timeout: timeout)
            }
        }
        _ = group.wait(timeout: .now() + timeout + 1)
    }

    /// MAC → its IPv6 addresses (global first, link-local last).
    static func read() -> [String: [String]] {
        guard let r = Command.run("/usr/sbin/ndp", ["-an"], timeout: 3) else { return [:] }
        return parse(r.out)
    }

    static func parse(_ text: String) -> [String: [String]] {
        var out: [String: Set<String>] = [:]
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2 else { continue }
            let addr = String(cols[0].split(separator: "%").first ?? cols[0])
            let octets = cols[1].split(separator: ":").compactMap { UInt8($0, radix: 16) }
            guard addr.contains(":"), octets.count == 6, let mac = ARPTable.format(octets) else { continue }
            out[mac, default: []].insert(addr.lowercased())
        }
        return out.mapValues { $0.sorted { (rank($0), $0) < (rank($1), $1) } }
    }

    static func rank(_ a: String) -> Int {
        switch kind(a) { case "Global": return 0; case "Local": return 1; default: return 2 }
    }

    /// "Global" (internet), "Local" (fc00::/7, private), or "Link" (fe80::, this LAN only).
    static func kind(_ a: String) -> String {
        let l = a.lowercased()
        if l.hasPrefix("fe8") || l.hasPrefix("fe9") || l.hasPrefix("fea") || l.hasPrefix("feb") { return "Link" }
        if l.hasPrefix("fc") || l.hasPrefix("fd") { return "Local" }
        return "Global"
    }
}

/// Shared folders on a device, the way a guest (no password) sees them.
struct ShareInfo: Sendable, Hashable {
    struct Share: Sendable, Hashable { var name: String; var comment: String }
    var smb: [Share] = []
    /// Why SMB shares couldn't be listed (usually: it needs a login).
    var smbProblem: String? = nil
    var nfs: [String] = []
}

enum Shares {
    static func list(_ ip: IPv4, ports: [UInt16]) -> ShareInfo {
        var info = ShareInfo()
        if ports.contains(445) || ports.contains(139) {
            if let r = Command.run("/usr/bin/smbutil", ["view", "-N", "//guest@\(ip)"], timeout: 8) {
                info.smb = parseSMB(r.out)
                if info.smb.isEmpty { info.smbProblem = r.ok ? "No shared folders visible to a guest." : "Needs a login to list the shares." }
            } else {
                info.smbProblem = "Didn’t answer in time."
            }
        }
        if ports.contains(2049), let r = Command.run("/usr/bin/showmount", ["-e", ip.description], timeout: 6), r.ok {
            info.nfs = parseNFS(r.out)
        }
        return info
    }

    /// `smbutil view` output: a "Share  Type  Comments" table. Keeps disks and printers, drops hidden ($) shares.
    static func parseSMB(_ text: String) -> [ShareInfo.Share] {
        var out: [ShareInfo.Share] = []
        var inTable = false
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("---") { inTable = true; continue }
            guard inTable,
                  let m = line.range(of: #"\s{2,}(Disk|Printer)(\s+|$)"#, options: .regularExpression) else { continue }
            let name = line[..<m.lowerBound].trimmingCharacters(in: .whitespaces)
            let comment = line[m.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.hasSuffix("$") else { continue }
            out.append(.init(name: name, comment: comment))
        }
        return out
    }

    /// `showmount -e` output: "Exports list on x:" then "/path   hosts".
    static func parseNFS(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).dropFirst()
            .compactMap { $0.split(separator: " ").first.map(String.init) }
            .filter { $0.hasPrefix("/") }
    }

    static func url(_ ip: IPv4, share: String) -> URL? {
        let escaped = share.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? share
        return URL(string: "smb://\(ip)/\(escaped)")
    }
}

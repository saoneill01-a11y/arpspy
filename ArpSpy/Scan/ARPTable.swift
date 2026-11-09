import Foundation
import Darwin

/// Reads the Mac's ARP table (IP → MAC for devices on the same subnet).
/// After the ping/port sweep, the Mac has tried to reach every local address, so the
/// table also reveals "quiet" devices that answered ARP but nothing else.
///
/// We read it in-process with sysctl (same data `arp -an` shows). Reports say newer
/// macOS hides this table from helper command-line tools but not from the app itself,
/// so in-process is the safer route. `arp -an` is kept only as a fallback.
enum ARPTable {
    static func read() -> [UInt32: String] {
        let table = readSysctl()
        return table.isEmpty ? readArpCommand() : table
    }

    // MARK: sysctl

    private static let NET_RT_FLAGS_: Int32 = 2      // from <sys/socket.h>
    private static let RTF_LLINFO_: Int32 = 0x400    // from <net/route.h>

    static func readSysctl() -> [UInt32: String] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS_, RTF_LLINFO_]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buf, &length, nil, 0) == 0 else { return [:] }

        let headerSize = MemoryLayout<rt_msghdr>.size
        var result: [UInt32: String] = [:]
        var offset = 0
        while offset + headerSize <= length {
            let msgLen = Int(UInt16(buf[offset]) | (UInt16(buf[offset + 1]) << 8))   // rtm_msglen (little-endian)
            guard msgLen > 0 else { break }
            defer { offset += msgLen }

            // sockaddr_in follows the header: [len, family, port(2), addr(4), ...]
            let sin = offset + headerSize
            guard sin + 8 <= length else { continue }
            let sinLen = Int(buf[sin])
            let ip = (UInt32(buf[sin + 4]) << 24) | (UInt32(buf[sin + 5]) << 16)
                   | (UInt32(buf[sin + 6]) << 8) | UInt32(buf[sin + 7])

            // sockaddr_dl follows, rounded up to 4 bytes: [len, family, index(2), type, nlen, alen, slen, data...]
            let sdl = sin + (sinLen > 0 ? 1 + ((sinLen - 1) | 3) : 4)
            guard sdl + 8 <= length else { continue }
            let nameLen = Int(buf[sdl + 5])
            let addrLen = Int(buf[sdl + 6])
            let macStart = sdl + 8 + nameLen
            guard addrLen == 6, macStart + 6 <= length else { continue }   // incomplete entries have no MAC
            let mac = Array(buf[macStart..<macStart + 6])
            if let text = format(mac) { result[ip] = text }
        }
        return result
    }

    // MARK: arp -an fallback

    static func readArpCommand() -> [UInt32: String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        task.arguments = ["-an"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return parseArpOutput(String(decoding: data, as: UTF8.self))
    }

    /// Parses lines like: `? (192.168.1.1) at 74:ac:b9:1e:22:1 on en0 ifscope [ethernet]`
    static func parseArpOutput(_ text: String) -> [UInt32: String] {
        var result: [UInt32: String] = [:]
        for line in text.split(separator: "\n") {
            guard let open = line.firstIndex(of: "("), let close = line.firstIndex(of: ")"), open < close,
                  let ip = IPv4(String(line[line.index(after: open)..<close])),
                  let atRange = line.range(of: " at ") else { continue }
            let macPart = line[atRange.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            let octets = macPart.split(separator: ":").compactMap { UInt8($0, radix: 16) }
            guard octets.count == 6, let text = format(octets) else { continue }
            result[ip.value] = text
        }
        return result
    }

    /// "74:AC:B9:1E:22:01". Skips broadcast and multicast entries.
    static func format(_ bytes: [UInt8]) -> String? {
        guard bytes.count == 6, bytes != [UInt8](repeating: 0xFF, count: 6),
              bytes != [UInt8](repeating: 0, count: 6), bytes[0] & 0x01 == 0 else { return nil }
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

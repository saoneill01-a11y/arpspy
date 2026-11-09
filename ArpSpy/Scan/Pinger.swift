import Foundation
import Darwin

/// Ping sweep without admin rights.
/// macOS allows normal apps to open an ICMP "datagram" socket, which is enough to
/// send echo requests and read echo replies. We fire one ping at every address,
/// then listen for replies until the timeout.
enum Pinger {
    /// Returns the addresses that answered, with round-trip time in milliseconds.
    /// `gapMicroseconds` > 0 paces the sweep (a quiet scan): that pause after every ping.
    static func sweep(_ targets: [IPv4], timeout: TimeInterval, gapMicroseconds: UInt32 = 0, flag: CancelFlag) -> [UInt32: Double] {
        guard !targets.isEmpty else { return [:] }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        Sockets.setNonBlocking(fd)
        // Hundreds of replies can land within a few milliseconds on a busy /22; the default
        // receive buffer drops some, and those devices are then only found by the slower TCP knock.
        var bufferSize: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))

        let ident = UInt16.random(in: 1...0xFFFF)
        var sentAt: [UInt32: Date] = [:]
        var replies: [UInt32: Double] = [:]
        var buffer = [UInt8](repeating: 0, count: 2048)

        func drain() {
            while let packet = Sockets.receive(fd, into: &buffer) {
                let from = packet.from
                guard isEchoReply(buffer, count: packet.count), let start = sentAt[from], replies[from] == nil else { continue }
                replies[from] = Date().timeIntervalSince(start) * 1000
            }
        }

        var seq: UInt16 = 0
        for (i, target) in targets.enumerated() {
            if flag.isCancelled { return replies }
            seq &+= 1
            let packet = echoRequest(id: ident, seq: seq)
            sentAt[target.value] = Date()
            if Sockets.send(fd, packet, to: target.value) < 0 && errno == ENOBUFS {
                usleep(5_000)
                Sockets.send(fd, packet, to: target.value)
            }
            // Don't flood: short pause every 32 pings, and pick up early replies.
            if gapMicroseconds > 0 { usleep(gapMicroseconds); drain() }
            else if i % 32 == 31 { usleep(2_000); drain() }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !flag.isCancelled {
            if Sockets.waitReadable(fd, seconds: deadline.timeIntervalSinceNow) { drain() }
        }
        return replies
    }

    static func echoRequest(id: UInt16, seq: UInt16) -> [UInt8] {
        var p: [UInt8] = [8, 0, 0, 0,
                          UInt8(id >> 8), UInt8(id & 0xFF),
                          UInt8(seq >> 8), UInt8(seq & 0xFF)]
        p += Array("ARPradar-ping-01".utf8)   // 16 bytes of payload
        let sum = checksum(p)
        p[2] = UInt8(sum >> 8)
        p[3] = UInt8(sum & 0xFF)
        return p
    }

    /// On macOS the reply includes the IP header in front of the ICMP part; skip it if present.
    static func isEchoReply(_ b: [UInt8], count: Int) -> Bool {
        guard count >= 8 else { return false }
        var offset = 0
        if b[0] >> 4 == 4 { offset = Int(b[0] & 0x0F) * 4 }
        guard count >= offset + 8 else { return false }
        return b[offset] == 0   // type 0 = echo reply
    }

    static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count {
            sum += (UInt32(data[i]) << 8) | UInt32(data[i + 1])
            i += 2
        }
        if i < data.count { sum += UInt32(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }
}

import Foundation
import Darwin

/// TCP "knocks" using plain non-blocking connects (no admin rights needed).
/// Used two ways:
///  - `sweep`: find devices that ignore ping. A device counts as there if a port is
///    open or it actively refuses, since either way something answered.
///  - `openPorts`: on devices we already found, list which common ports are open.
enum TCPProbe {
    static let discoveryPorts: [UInt16] = [445, 80, 443, 22, 3389]

    static func sweep(_ targets: [IPv4], ports: [UInt16] = discoveryPorts,
                      timeout: TimeInterval, flag: CancelFlag) -> Set<UInt32> {
        var alive = Set<UInt32>()
        let jobs = targets.flatMap { t in ports.map { (t.value, $0) } }
        run(jobs, timeout: timeout, flag: flag, skip: { alive.contains($0) }) { ip, _, open in
            _ = open   // open or refused: both mean the device is there
            alive.insert(ip)
        }
        return alive
    }

    static func openPorts(_ targets: [IPv4], ports: [UInt16] = Ports.scanList,
                          timeout: TimeInterval, flag: CancelFlag) -> [UInt32: [UInt16]] {
        var result: [UInt32: Set<UInt16>] = [:]
        let jobs = targets.flatMap { t in ports.map { (t.value, $0) } }
        run(jobs, timeout: timeout, flag: flag, skip: { _ in false }) { ip, port, open in
            if open { result[ip, default: []].insert(port) }
        }
        return result.mapValues { $0.sorted() }
    }

    /// Connects to every (ip, port) in batches and reports each one that answered.
    /// `answered(ip, port, open)`: open = true if the port accepted, false if the device refused.
    private static func run(_ jobs: [(UInt32, UInt16)], timeout: TimeInterval, flag: CancelFlag,
                            skip: (UInt32) -> Bool,
                            answered: (UInt32, UInt16, Bool) -> Void) {
        Sockets.raiseOpenFileLimit()
        let batchSize = 900
        var index = 0

        while index < jobs.count, !flag.isCancelled {
            let batch = jobs[index..<min(index + batchSize, jobs.count)].filter { !skip($0.0) }
            index += batchSize

            var pending: [(fd: Int32, ip: UInt32, port: UInt16)] = []
            for (ip, port) in batch {
                let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
                guard fd >= 0 else { continue }
                Sockets.setNonBlocking(fd)
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var addr = Sockets.address(ip, port: port)
                let r = withUnsafePointer(to: &addr) { p in
                    p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                let err = errno
                if r == 0 {
                    answered(ip, port, true); close(fd)
                } else if err == ECONNREFUSED {
                    answered(ip, port, false); close(fd)
                } else if err == EINPROGRESS {
                    pending.append((fd, ip, port))
                } else {
                    close(fd)
                }
            }

            var pfds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
            var left = pfds.count
            let deadline = Date().addingTimeInterval(timeout)
            while left > 0, Date() < deadline, !flag.isCancelled {
                let ms = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
                if poll(&pfds, nfds_t(pfds.count), ms) <= 0 { break }
                for i in pfds.indices where pfds[i].fd >= 0 && pfds[i].revents != 0 {
                    var soErr: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(pfds[i].fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
                    if soErr == 0 { answered(pending[i].ip, pending[i].port, true) }
                    else if soErr == ECONNREFUSED { answered(pending[i].ip, pending[i].port, false) }
                    close(pfds[i].fd)
                    pfds[i].fd = -1     // poll() ignores negative fds
                    left -= 1
                }
            }
            for p in pfds where p.fd >= 0 { close(p.fd) }
        }
    }
}

import Darwin

/// Small helpers around the low-level BSD socket calls.
enum Sockets {
    static func address(_ ip: UInt32, port: UInt16 = 0) -> sockaddr_in {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr = in_addr(s_addr: ip.bigEndian)
        return a
    }

    static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    /// Lets us open more sockets at once (macOS defaults to 256).
    static func raiseOpenFileLimit(to wanted: rlim_t = 4096) {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        if limit.rlim_cur < wanted {
            limit.rlim_cur = min(wanted, limit.rlim_max)
            _ = setrlimit(RLIMIT_NOFILE, &limit)
        }
    }

    @discardableResult
    static func send(_ fd: Int32, _ bytes: [UInt8], to ip: UInt32, port: UInt16 = 0) -> Int {
        var dest = address(ip, port: port)
        return withUnsafePointer(to: &dest) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, bytes, bytes.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    /// Reads one waiting packet. Returns how many bytes and who sent it, or nil if nothing is waiting.
    static func receive(_ fd: Int32, into buffer: inout [UInt8]) -> (count: Int, from: UInt32)? {
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = buffer.withUnsafeMutableBytes { raw -> Int in
            withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, raw.baseAddress, raw.count, 0, sa, &len)
                }
            }
        }
        guard n > 0 else { return nil }
        return (n, UInt32(bigEndian: from.sin_addr.s_addr))
    }

    /// Waits up to `seconds` for the socket to have data.
    static func waitReadable(_ fd: Int32, seconds: Double) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&pfd, 1, Int32(max(1, seconds * 1000))) > 0
    }
}

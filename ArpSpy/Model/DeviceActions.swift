import Foundation
import AppKit
import Darwin

/// The right-click actions. Most just hand a URL to macOS, which opens the right app:
///   http(s)://  → default browser
///   smb://      → Finder (Connect to Server)
///   ssh://      → Terminal
///   vnc://      → Screen Sharing
///   rdp://      → Microsoft "Windows App" (free on the App Store), if installed
enum DeviceActions {
    enum Failure: LocalizedError {
        case noApp(String)
        case noMAC
        case wakeNotSent(String)
        var errorDescription: String? {
            switch self {
            case .noApp(let what): return what
            case .noMAC: return "Wake-on-LAN needs the device’s MAC address. Scan it while it’s awake on this subnet first."
            case .wakeNotSent(let why): return "Couldn’t send the wake packet: \(why)."
            }
        }
    }

    static func openWeb(_ d: Device) throws {
        let p = d.openPorts
        let url: String
        if p.contains(443) { url = "https://\(d.ip)" }
        else if p.contains(80) { url = "http://\(d.ip)" }
        else if p.contains(8443) { url = "https://\(d.ip):8443" }
        else if p.contains(8080) { url = "http://\(d.ip):8080" }
        else { url = "http://\(d.ip)" }
        try open(url, missingApp: "Couldn’t open a web browser.")
    }

    static func openShares(_ d: Device) throws {
        try open("smb://\(d.ip)", missingApp: "Couldn’t open the shares in Finder.")
    }

    static func ssh(_ d: Device) throws {
        try open("ssh://\(d.ip)", missingApp: "Couldn’t open Terminal for SSH.")
    }

    static func screenSharing(_ d: Device) throws {
        try open("vnc://\(d.ip)", missingApp: "Couldn’t open Screen Sharing.")
    }

    /// Writes a small .rdp connection file and opens it in Windows App.
    /// (The old rdp://full%20address=s:IP link is rejected by macOS's URL parser, so it never reached the app.)
    static func remoteDesktop(_ d: Device) throws {
        let missing = "No app is set up for Remote Desktop. Install Microsoft’s free “Windows App” from the Mac App Store, then try again."
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ArpSpy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        removeOldRDPFiles(in: dir)
        let file = dir.appendingPathComponent("\(d.ip).rdp")
        do { try rdpFile(for: d.ip.description).write(to: file, atomically: true, encoding: .utf8) }
        catch { throw Failure.noApp("Couldn’t create the Remote Desktop connection file.") }

        let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.rdc.macos")
            ?? NSWorkspace.shared.urlForApplication(toOpen: file)
        guard let app else { throw Failure.noApp(missing) }
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func rdpFile(for host: String) -> String {
        "full address:s:\(host)\r\nprompt for credentials:i:1\r\n"
    }

    /// Cheap housekeeping each time a connection file is written: .rdp files from more than a day ago go.
    static func removeOldRDPFiles(in dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-86_400)
        for f in files where f.pathExtension == "rdp" {
            if let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date < cutoff {
                try? fm.removeItem(at: f)
            }
        }
    }

    private static func open(_ string: String, missingApp: String) throws {
        guard let url = URL(string: string),
              NSWorkspace.shared.urlForApplication(toOpen: url) != nil else { throw Failure.noApp(missingApp) }
        NSWorkspace.shared.open(url)
    }

    // MARK: Wake-on-LAN

    /// Sends the "magic packet" (6 × FF, then the MAC 16 times) as a UDP broadcast on port 9,
    /// to the general broadcast address and to each local subnet's broadcast address.
    /// Returns how many devices a packet was sent for. Throws when nothing could be sent at all (the general
    /// broadcast alone failing is fine: some networks refuse it while the subnet broadcast works).
    @discardableResult
    static func wake(_ devices: [Device], interfaces: [NetInterface]) throws -> Int {
        let macs = devices.compactMap { macBytes($0.mac) }
        guard !macs.isEmpty else { throw Failure.noMAC }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure.wakeNotSent(String(cString: strerror(errno))) }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))

        var targets: [UInt32] = [0xFFFF_FFFF]
        targets += interfaces.map { $0.network.value | ~$0.netmask.value }
        var sent = 0, lastError: Int32 = 0
        for mac in macs {
            let packet = [UInt8](repeating: 0xFF, count: 6) + Array((0..<16).map { _ in mac }.joined())
            for t in Set(targets) {
                if Sockets.send(fd, packet, to: t, port: 9) < 0 { lastError = errno } else { sent += 1 }
            }
        }
        guard sent > 0 else { throw Failure.wakeNotSent(String(cString: strerror(lastError))) }
        return macs.count
    }

    static func macBytes(_ text: String) -> [UInt8]? {
        let parts = text.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        return parts.count == 6 ? parts : nil
    }
}

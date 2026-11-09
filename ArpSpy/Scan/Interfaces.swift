import Foundation
import Darwin
import SystemConfiguration

/// A network connection on this Mac (Wi-Fi, Ethernet, VPN…), for the "Network" picker.
struct NetInterface: Identifiable, Hashable, Sendable {
    let bsdName: String       // en0
    let friendlyName: String  // Wi-Fi
    let address: IPv4
    let netmask: IPv4

    var id: String { bsdName }
    var prefixLength: Int { netmask.value.nonzeroBitCount }
    var network: IPv4 { IPv4(address.value & netmask.value) }
    var cidr: String { "\(network)/\(prefixLength)" }
    var displayName: String { "\(friendlyName) (\(bsdName)) – \(cidr)" }

    /// What to put in the range box. Big subnets get trimmed to this Mac's /24 so a scan stays quick.
    var suggestedRange: String {
        if prefixLength >= 22 { return cidr }
        return "\(IPv4(address.value & 0xFFFF_FF00))/24"
    }
}

enum Interfaces {
    static func current() -> [NetInterface] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        let names = friendlyNames()

        var result: [NetInterface] = []
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.pointee.ifa_netmask else { continue }
            let bsd = String(cString: ifa.pointee.ifa_name)
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if a >> 16 == 0xA9FE { continue }               // 169.254.x.x self-assigned
            if m == 0xFFFF_FFFF { continue }                 // point-to-point /32, nothing to scan
            result.append(NetInterface(bsdName: bsd, friendlyName: names[bsd] ?? bsd,
                                       address: IPv4(a), netmask: IPv4(m)))
        }
        return result.sorted { $0.bsdName < $1.bsdName }
    }

    /// This Mac's own MAC address per interface (en0 → "F0:18:…").
    static func macAddresses() -> [String: String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }
        var result: [String: String] = [:]
        for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let raw = UnsafeRawPointer(addr)
            let nameLen = Int(raw.load(fromByteOffset: 5, as: UInt8.self))
            let addrLen = Int(raw.load(fromByteOffset: 6, as: UInt8.self))
            guard addrLen == 6 else { continue }
            let bytes = (0..<6).map { raw.load(fromByteOffset: 8 + nameLen + $0, as: UInt8.self) }
            if let mac = ARPTable.format(bytes) { result[String(cString: ifa.pointee.ifa_name)] = mac }
        }
        return result
    }

    /// "en0" → "Wi-Fi", "en7" → "USB 10/100/1000 LAN", etc.
    static func friendlyNames() -> [String: String] {
        var map: [String: String] = [:]
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return map }
        for iface in all {
            if let bsd = SCNetworkInterfaceGetBSDName(iface),
               let name = SCNetworkInterfaceGetLocalizedDisplayName(iface) {
                map[bsd as String] = name as String
            }
        }
        return map
    }
}

/// macOS asks "Allow ARPradar to find devices on local networks?" the first time the app
/// talks to the LAN. Poking the network at launch gets that prompt out of the way before
/// the first scan, instead of the first scan quietly finding nothing.
enum LocalNetworkPermission {
    static func trigger(for interfaces: [NetInterface]) {
        DispatchQueue.global(qos: .utility).async {
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return }
            defer { close(fd) }
            for i in interfaces {
                Sockets.send(fd, [0], to: i.network.value + 1, port: 9)   // port 9 = "discard"
            }
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
}

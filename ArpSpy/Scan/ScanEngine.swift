import Foundation

/// What a scan should do besides the basics.
struct ScanOptions: Sendable {
    /// A site's DNS server to ask for names (nil = only this Mac's DNS).
    var nameServer: IPv4? = nil
    var snmpCommunity = "public"
}

/// Runs one scan, start to finish, off the main thread:
///   1. ping sweep (with response times)
///   2. TCP knock on the addresses that didn't answer ping
///   3. ARP table → MAC addresses (+ quiet devices that answered nothing else)
///   4. open ports on the devices found
///   5. names (NetBIOS, Bonjour, the site's DNS server, then this Mac's DNS; the first name found wins),
///      and at the same time: web page titles, UPnP models and SNMP descriptions
enum ScanEngine {
    static func run(targets: [IPv4], interfaces: [NetInterface], options: ScanOptions = ScanOptions(),
                    flag: CancelFlag, report: @escaping @Sendable (ScanEvent) async -> Void) async {
        let targetSet = Set(targets.map(\.value))
        var alive = Set<UInt32>()

        // This Mac itself, if it's inside the range.
        let ownMACs = Interfaces.macAddresses()
        var selfMACs: [UInt32: String] = [:]
        var me: [Device] = []
        for i in interfaces where targetSet.contains(i.address.value) && !alive.contains(i.address.value) {
            var d = Device(ip: i.address)
            d.name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            d.isThisMac = true
            me.append(d)
            alive.insert(i.address.value)
            if let mac = ownMACs[i.bsdName] { selfMACs[i.address.value] = mac }
        }
        await report(.found(me))

        // 1. Ping
        await report(.progress(0.05, "Pinging \(targets.count) addresses…"))
        let pingTargets = targets.filter { !alive.contains($0.value) }
        let replies = await offMain { Pinger.sweep(pingTargets, timeout: 1.2, flag: flag) }
        alive.formUnion(replies.keys)
        await report(.found(replies.keys.sorted().map { Device(ip: IPv4($0)) }))
        await report(.response(replies))
        if flag.isCancelled { await report(.finished(cancelled: true)); return }

        // 2. TCP knock
        await report(.progress(0.35, "Checking devices that ignore ping…"))
        let rest = targets.filter { !alive.contains($0.value) }
        let knocked = await offMain { TCPProbe.sweep(rest, timeout: 0.7, flag: flag) }
        alive.formUnion(knocked)
        await report(.found(knocked.sorted().map { Device(ip: IPv4($0)) }))
        if flag.isCancelled { await report(.finished(cancelled: true)); return }

        // IPv6 neighbors: ping them all now, read the list after the port check.
        let ifNames = interfaces.map(\.bsdName)
        async let v6 = offMain { IPv6Neighbors.refresh(ifNames); return IPv6Neighbors.read() }

        // 3. ARP
        await report(.progress(0.65, "Reading MAC addresses…"))
        let arp = await offMain { ARPTable.read() }.filter { targetSet.contains($0.key) }
        let quiet = arp.keys.filter { !alive.contains($0) }.sorted()
        alive.formUnion(quiet)
        await report(.found(quiet.map { Device(ip: IPv4($0)) }))
        await report(.macs(arp.merging(selfMACs) { _, mine in mine }))

        // 4. Open ports on everything we found
        let aliveList = alive.sorted().map(IPv4.init)
        let others = aliveList.filter { selfMACs[$0.value] == nil }
        await report(.progress(0.72, "Checking open ports on \(aliveList.count) devices…"))
        let ports = await offMain { TCPProbe.openPorts(aliveList, timeout: 0.8, flag: flag) }
        await report(.ports(ports))
        let byMAC = await v6
        let macs = arp.merging(selfMACs) { _, mine in mine }
        await report(.ipv6(macs.compactMapValues { byMAC[$0] }))
        if flag.isCancelled { await report(.finished(cancelled: true)); return }

        // 5. Identify: these three run alongside the name lookups below.
        async let web = offMain { Web.titles(ports, timeout: 3, flag: flag) }
        async let upnp = offMain { UPnP.discover(Set(others.map(\.value)), timeout: 3, flag: flag) }
        let community = options.snmpCommunity
        async let snmp = offMain { SNMP.query(others, community: community, timeout: 2, flag: flag) }
        let ubntTargets = Set(others.map(\.value))
        async let ubnt = offMain { UbiquitiDiscovery.discover(ubntTargets, interfaces: interfaces, timeout: 2, flag: flag) }

        // NetBIOS, Bonjour and the site's name server are independent UDP bursts, so they run at the same
        // time (about 3.5 s saved per scan). Results are still reported in that order: the first name wins.
        await report(.progress(0.8, options.nameServer.map { "Looking up names (NetBIOS, Bonjour, \($0))…" } ?? "Looking up names (NetBIOS, Bonjour)…"))
        async let netbiosNames = offMain { NameLookup.netBIOS(aliveList, timeout: 1.5, flag: flag) }
        async let bonjourNames = offMain { NameLookup.bonjour(aliveList, timeout: 2, flag: flag) }
        let server = options.nameServer
        async let siteNames = offMain { server.map { NameLookup.dnsPTR(aliveList, server: $0, timeout: 2, flag: flag) } ?? [:] }
        await report(.names(source: "NetBIOS", await netbiosNames))
        await report(.progress(0.84, "Looking up names…"))
        await report(.names(source: "Bonjour", await bonjourNames))
        if server != nil { await report(.names(source: "DNS", await siteNames)) }

        await report(.progress(0.9, "Reading web pages, UPnP and SNMP…"))
        await report(.webTitles(await web))
        let upnpInfo = await upnp
        await report(.upnp(upnpInfo))
        let snmpInfo = await snmp
        await report(.snmp(snmpInfo))
        let ubntInfo = await ubnt
        await report(.ubiquiti(ubntInfo))
        if flag.isCancelled { await report(.finished(cancelled: true)); return }

        await report(.progress(0.95, "Looking up DNS names…"))
        await offMain {
            NameLookup.reverseDNS(aliveList, timeout: 4, flag: flag) { ip, name in
                Task { await report(.names(source: "DNS", [ip: name])) }
            }
        }
        // Device names from UPnP and SNMP come last: only used when nothing else named it.
        await report(.names(source: "UPnP", upnpInfo.compactMapValues { NameLookup.isUsefulName($0.friendlyName) ? $0.friendlyName : nil }))
        await report(.names(source: "SNMP", snmpInfo.compactMapValues { NameLookup.isUsefulName($0.name) ? $0.name : nil }))
        await report(.names(source: "UniFi", ubntInfo.compactMapValues { NameLookup.isUsefulName($0.name) ? $0.name : nil }))

        await report(.finished(cancelled: flag.isCancelled))
    }
}

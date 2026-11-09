import Foundation

/// The ports shown in the "Open ports" column, with their short labels,
/// and the longer "common ports" list used by Scan Ports.
enum Ports {
    static let known: [(port: UInt16, label: String)] = [
        (21, "FTP"), (22, "SSH"), (23, "Telnet"), (53, "DNS"),
        (80, "HTTP"), (443, "HTTPS"), (445, "SMB"), (548, "AFP"),
        (554, "RTSP"), (631, "IPP"), (3389, "RDP"), (5900, "VNC"),
        (8080, "HTTP:8080"), (8443, "HTTPS:8443"), (9100, "Printer"),
    ]

    static let scanList: [UInt16] = known.map { $0.port }

    static func label(_ port: UInt16) -> String {
        known.first(where: { $0.port == port })?.label ?? String(port)
    }

    /// About 100 TCP ports worth checking on one device, with what usually runs there.
    static let common: [(port: UInt16, service: String)] = [
        (20, "FTP data"), (21, "FTP"), (22, "SSH"), (23, "Telnet"), (25, "SMTP (mail)"), (53, "DNS"),
        (80, "HTTP (web)"), (81, "HTTP (web, alt.)"), (88, "Kerberos"), (102, "Siemens S7 PLC"),
        (110, "POP3 (mail)"), (111, "RPC portmapper"), (135, "Windows RPC"), (139, "NetBIOS file sharing"),
        (143, "IMAP (mail)"), (179, "BGP"), (389, "LDAP / Active Directory"), (443, "HTTPS (web)"),
        (445, "SMB (file sharing)"), (465, "SMTP over TLS"), (502, "Modbus"), (515, "LPD printing"),
        (548, "AFP (Mac file sharing)"), (554, "RTSP (camera video)"), (587, "Mail submission"),
        (593, "RPC over HTTP"), (631, "IPP printing"), (636, "LDAP over TLS"), (873, "rsync"),
        (902, "VMware ESXi"), (993, "IMAP over TLS"), (995, "POP3 over TLS"), (1080, "SOCKS proxy"),
        (1194, "OpenVPN"), (1433, "Microsoft SQL Server"), (1521, "Oracle database"), (1723, "PPTP VPN"),
        (1883, "MQTT"), (2049, "NFS"), (2179, "Hyper-V console"), (2375, "Docker API"),
        (2376, "Docker API (TLS)"), (3000, "Web app (Grafana etc.)"), (3128, "Web proxy"), (3260, "iSCSI"),
        (3306, "MySQL / MariaDB"), (3389, "RDP (Remote Desktop)"), (4443, "HTTPS (alt.)"),
        (5000, "Synology / UPnP / web app"), (5001, "Synology HTTPS"), (5060, "SIP (VoIP)"),
        (5061, "SIP over TLS"), (5222, "XMPP chat"), (5432, "PostgreSQL"), (5555, "Android debug"),
        (5601, "Kibana"), (5900, "VNC (screen sharing)"), (5901, "VNC display 1"), (5985, "WinRM"),
        (5986, "WinRM over TLS"), (6379, "Redis"), (6443, "Kubernetes API"), (7000, "AirPlay"),
        (7443, "HTTPS (alt.)"), (8000, "HTTP (alt.)"), (8008, "HTTP (alt.)"), (8009, "Chromecast"),
        (8060, "Roku"), (8080, "HTTP (alt. / proxy)"), (8081, "HTTP (alt.)"), (8088, "HTTP (alt.)"),
        (8123, "Home Assistant"), (8200, "DLNA media"), (8291, "MikroTik Winbox"), (8443, "HTTPS (alt.)"),
        (8554, "RTSP (alt.)"), (8728, "MikroTik API"), (8843, "UniFi HTTPS"), (8880, "UniFi HTTP"),
        (8883, "MQTT over TLS"), (8888, "HTTP (alt.)"), (9000, "Portainer / web app"),
        (9090, "Cockpit / Prometheus"), (9091, "Transmission"), (9100, "Printer (JetDirect)"),
        (9200, "Elasticsearch"), (9443, "HTTPS (alt.)"), (10000, "Webmin"), (11211, "Memcached"),
        (27017, "MongoDB"), (32400, "Plex"), (34567, "DVR / NVR"), (37777, "Dahua camera / NVR"),
        (49152, "UPnP"), (62078, "iPhone / iPad sync"),
    ]

    static func service(_ port: UInt16) -> String {
        common.first(where: { $0.port == port })?.service ?? ""
    }

    /// "1-1024" or "22, 80, 8000-8100" → sorted ports. Nil if anything is invalid or out of 1–65535.
    static func parseList(_ text: String) -> [UInt16]? {
        var out = Set<UInt16>()
        let pieces = text.split(whereSeparator: { $0 == "," || $0 == " " }).filter { !$0.isEmpty }
        guard !pieces.isEmpty else { return nil }
        for piece in pieces {
            let ends = piece.split(separator: "-", omittingEmptySubsequences: false)
            guard ends.count <= 2, let a = UInt16(ends[0]), a > 0 else { return nil }
            let b = ends.count == 2 ? UInt16(ends[1]) : a
            guard let b, b >= a else { return nil }
            for p in a...b { out.insert(p) }
        }
        return out.sorted()
    }
}

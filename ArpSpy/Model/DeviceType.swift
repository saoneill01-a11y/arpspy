import Foundation

/// What kind of thing a device is, for the Type column. Guessed from what the scan learned;
/// the user can set it by hand (right-click › Type), which is remembered like a comment.
enum DeviceKind: String, CaseIterable, Codable, Sendable, Hashable {
    case router, firewall, switchDevice = "switch", accessPoint = "ap", camera, printer, tv, speaker
    case computer, server, nas, phone, tablet, watch, deskPhone, console, smartHome, ups, other

    var label: String {
        switch self {
        case .router: "Router"
        case .firewall: "Firewall"
        case .switchDevice: "Switch"
        case .accessPoint: "Wi-Fi AP"
        case .camera: "Camera"
        case .printer: "Printer"
        case .tv: "TV"
        case .speaker: "Speaker"
        case .computer: "Computer"
        case .server: "Server"
        case .nas: "NAS"
        case .phone: "Phone"
        case .tablet: "Tablet"
        case .watch: "Watch"
        case .deskPhone: "Desk phone"
        case .console: "Game console"
        case .smartHome: "Smart home"
        case .ups: "UPS"
        case .other: "Other"
        }
    }

    /// SF Symbol for the column.
    var symbol: String {
        switch self {
        case .router: "wifi.router"
        case .firewall: "shield.lefthalf.filled"
        case .switchDevice: "rectangle.connected.to.line.below"
        case .accessPoint: "wifi"
        case .camera: "video"
        case .printer: "printer"
        case .tv: "tv"
        case .speaker: "hifispeaker"
        case .computer: "desktopcomputer"
        case .server: "server.rack"
        case .nas: "externaldrive.connected.to.line.below"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .watch: "applewatch"
        case .deskPhone: "phone"
        case .console: "gamecontroller"
        case .smartHome: "lightbulb"
        case .ups: "bolt.batteryblock"
        case .other: "questionmark.square.dashed"
        }
    }
}

enum DeviceTypeGuess {
    /// Best guess from what the scan found. Order: the UniFi map, then names and models, then the
    /// manufacturer, then being the DHCP server (usually the router), then open ports. nil = no idea.
    static func guess(_ d: Device) -> DeviceKind? {
        let g = guessWithoutMap(d)
        // The map calls every gateway a gateway; keep "Firewall" for a Sophos or FortiGate.
        if let k = d.mapKind { return k == .router && g == .firewall ? .firewall : k }
        return g
    }

    private static func guessWithoutMap(_ d: Device) -> DeviceKind? {
        let key = Key(texts: [d.name, d.upnp, d.ubntModel, d.snmpName, d.webTitle, d.snmpDescr] + d.names.values.sorted(),
                      vendor: d.vendor, ports: d.openPorts, dhcp: d.isDHCPServer)
        return Cache.shared.value(for: key) {
            let first = d.snmpDescr.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let text = ([d.name, d.upnp, d.ubntModel, d.snmpName, d.webTitle, first] + Array(d.names.values))
                .filter { !$0.isEmpty }.joined(separator: " | ").lowercased()
            if let k = fromText(text) { return k }
            let vendor = d.vendor.lowercased()
            if let k = fromVendor(vendor) { return k }
            // TP-Link with nothing open is almost always a Kasa or Tapo plug, switch or bulb.
            if vendor.contains("tp-link") && d.openPorts.isEmpty && d.name.isEmpty { return .smartHome }
            if d.isDHCPServer { return .router }
            return fromPorts(Set(d.openPorts))
        }
    }

    /// Names, models, descriptions. Specific before general: "Nintendo Switch" is a console, not a switch.
    static func fromText(_ t: String) -> DeviceKind? {
        guard !t.isEmpty else { return nil }
        let range = NSRange(t.startIndex..., in: t)
        for (kind, rx) in textPatterns where rx.firstMatch(in: t, range: range) != nil { return kind }
        return nil
    }

    /// One whole-word pattern per kind: "ap" matches "office-ap" and "AP Kitchen" but not "laptop" or "apple".
    private static let textPatterns: [(DeviceKind, NSRegularExpression)] = textRules.map { kind, words in
        (kind, try! NSRegularExpression(pattern: "(?:^|[^a-z0-9])(?:" + words.joined(separator: "|") + ")(?:$|[^a-z0-9])"))
    }

    /// The table asks for the type on every redraw and sort, so guesses are remembered by their inputs.
    private struct Key: Hashable { let texts: [String]; let vendor: String; let ports: [UInt16]; let dhcp: Bool }
    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private var map: [Key: DeviceKind?] = [:]
        func value(for key: Key, _ make: () -> DeviceKind?) -> DeviceKind? {
            lock.lock()
            if let hit = map[key] { lock.unlock(); return hit }
            lock.unlock()
            let v = make()
            lock.lock()
            if map.count > 20_000 { map.removeAll() }
            map[key] = v
            lock.unlock()
            return v
        }
    }

    private static let textRules: [(DeviceKind, [String])] = [
        (.console, ["xbox", "playstation", "ps4", "ps5", "nintendo"]),
        (.firewall, ["sophos", "xgs", "fortigate", "fortinet", "pfsense", "opnsense", "sonicwall", "watchguard", "firebox", "palo alto", "firewall"]),
        (.router, ["gateway", "router", "udm", "udr", "uxg", "usg", "ucg", "dream machine", "dream router", "cloud gateway",
                   "edgerouter", "er-x", "mikrotik", "routeros", "fritz!box", "eero", "orbi"]),
        (.accessPoint, ["access point", "uap", "u6", "u7", "nanohd", "flexhd", "ac lite", "ac pro", "ac lr", "eap\\d*", "wap", "ap"]),
        (.camera, ["camera", "cam", "uvc", "uvc[- ]?g[3-6]\\w*", "g[3-6] (?:instant|flex|bullet|dome|pro|ptz)\\w*", "doorbell", "ipcam", "ipc", "hikvision", "dahua", "reolink", "amcrest", "wyze", "arlo", "blink"]),
        (.printer, ["printer", "laserjet", "officejet", "deskjet", "pagewide", "pixma", "imageclass", "maxify", "workforce",
                    "ecotank", "mfc-?\\w*", "hl-\\w+", "dcp-\\w+", "brn\\w*", "npi\\w*", "bizhub", "taskalfa", "ecosys", "imagerunner",
                    "xerox", "lexmark", "zebra", "dymo", "label printer"]),
        (.nas, ["nas", "diskstation", "ds\\d{3,4}\\+?", "rs\\d{3,4}\\+?", "synology", "qnap", "truenas", "freenas", "unraid", "readynas", "terramaster", "asustor"]),
        (.server, ["server", "cloud key", "unvr", "nvr", "esxi", "proxmox", "idrac", "ilo", "ipmi", "hyper-v", "dc\\d+", "vcenter", "pihole", "pi-hole"]),
        (.switchDevice, ["switch", "usw", "flex mini", "catalyst", "procurve", "nexus", "edgeswitch", "gs\\d{3}\\w*", "sg\\d{3}\\w*", "cbs\\d{3}"]),
        (.tv, ["tv", "bravia", "roku", "chromecast", "fire tv", "firetv", "fire stick", "apple tv", "appletv", "shield", "vizio", "webos", "tizen", "android tv", "google tv"]),
        (.speaker, ["sonos", "homepod", "echo", "alexa", "google home", "nest mini", "nest audio", "nest hub", "speaker", "soundbar", "heos", "denon", "bose", "marantz"]),
        (.deskPhone, ["polycom", "yealink", "grandstream", "snom", "ip phone", "sip-?\\w*", "voip", "obihai", "cisco cp-\\w+"]),
        (.tablet, ["ipad", "tablet", "kindle", "fire hd", "galaxy tab"]),
        (.watch, ["watch"]),
        (.phone, ["iphone", "galaxy", "pixel", "android", "oneplus", "motorola", "moto", "phone"]),
        (.ups, ["ups", "smart-ups", "apc", "eaton", "cyberpower", "network management card"]),
        (.smartHome, ["hue", "shelly\\w*", "tasmota", "esphome", "esp32", "esp8266", "esp-\\w+", "ecobee", "nest", "thermostat", "plug", "bulb",
                      "kasa", "\\w*homeassistant\\w*", "hs\\d{3}", "kp\\d{3}", "ep\\d{2}", "myq", "wemo", "lutron", "caseta", "home assistant", "homeassistant",
                      "hubitat", "smartthings", "tuya", "zigbee", "z-wave", "zwave", "sensor", "garage", "sprinkler", "rachio", "ring"]),
        (.computer, ["macbook", "imac", "mac mini", "mac-mini", "macmini", "mac studio", "mac pro", "desktop-\\w+", "laptop-\\w+", "laptop",
                     "desktop", "\\w+-pc", "pc", "windows", "thinkpad", "workstation", "ubuntu", "debian", "raspberry", "raspberrypi", "chromebook"]),
    ]

    /// Manufacturers that make mostly one kind of thing. Makers of many kinds (Apple, Samsung, TP-Link,
    /// Netgear, Cisco, Ubiquiti, Amazon, Google, HP) are left to the name and ports.
    static func fromVendor(_ v: String) -> DeviceKind? {
        guard !v.isEmpty else { return nil }
        for (kind, makers) in vendorRules where makers.contains(where: { v.contains($0) }) { return kind }
        return nil
    }

    private static let vendorRules: [(DeviceKind, [String])] = [
        (.printer, ["brother", "canon", "seiko epson", "epson", "lexmark", "xerox", "kyocera", "ricoh", "zebra", "konica"]),
        (.camera, ["hikvision", "dahua", "axis comm", "amcrest", "reolink", "wyze", "hanwha", "arlo", "lorex", "uniview", "vivotek", "mobotix"]),
        (.firewall, ["sophos", "fortinet", "sonicwall", "watchguard", "palo alto", "netgate", "check point"]),
        (.router, ["mikrotik", "routerboard", "avm", "eero"]),
        (.tv, ["roku", "vizio", "tcl", "hisense", "lg electronics"]),
        (.console, ["nintendo", "sony interactive"]),
        (.speaker, ["sonos", "bose", "sound united", "denon"]),
        (.nas, ["synology", "qnap", "asustor", "western digital", "terramaster"]),
        (.deskPhone, ["polycom", "yealink", "grandstream", "mitel", "avaya", "snom", "obihai"]),
        (.ups, ["american power conversion", "eaton", "cyber power"]),
        (.smartHome, ["espressif", "tuya", "shelly", "allterco", "signify", "philips lighting", "ecobee", "nest labs", "lutron", "chamberlain", "ring llc", "resideo", "honeywell home"]),
        (.server, ["vmware", "super micro", "supermicro"]),
        (.computer, ["raspberry pi", "intel corporate", "dell", "lenovo", "micro-star", "gigabyte", "asustek", "framework computer"]),
    ]

    static func fromPorts(_ p: Set<UInt16>) -> DeviceKind? {
        if p.contains(9100) || p.contains(631) || p.contains(515) { return .printer }
        if p.contains(554) { return .camera }
        if p.contains(3389) { return .computer }
        if p.contains(5060) { return .deskPhone }
        if p.contains(8008) || p.contains(8009) { return .tv }
        if p.contains(445) || p.contains(139) || p.contains(548) || p.contains(5900) { return .computer }
        return nil
    }
}

extension Device {
    /// The type shown in the table: the user's choice, else the guess.
    var kind: DeviceKind? { typeOverride ?? DeviceTypeGuess.guess(self) }
    /// Sorts by label; unknown types last.
    var kindSort: String { kind?.label ?? "\u{10FFFF}" }
}

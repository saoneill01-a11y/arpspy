import Foundation

extension String {
    /// Text that came off the network (a NetBIOS name, Bonjour label, web page title, UPnP model, SNMP string),
    /// made safe to show, copy and export: control characters, line breaks, tabs and the invisible
    /// direction-changing characters are dropped, the ends are trimmed, and it's cut to `max` characters.
    func cleanedNetworkText(max: Int = 120) -> String {
        var out = ""
        for u in unicodeScalars {
            switch u.value {
            case 0x00...0x1F, 0x7F...0x9F: continue                          // control characters (incl. tab, newline)
            case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: continue   // zero-width and bidi marks
            default: out.unicodeScalars.append(u)
            }
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.count > max ? String(trimmed.prefix(max)) + "…" : trimmed
    }
}

/// CSV shared by the Mac app and the iPhone app.
enum CSV {
    /// One CSV cell. Quoted when it needs to be. A cell that starts like a formula (=, +, -, @, tab, return)
    /// gets a leading apostrophe so Excel and Numbers show it as text instead of running it: device names,
    /// web page titles and SNMP strings come straight off the network and could say anything.
    static func cell(_ s: String) -> String {
        var s = s
        if let first = s.first, "=+-@\t\r".contains(first) { s = "'" + s }
        return s.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline || $0 == "'" && s.hasPrefix("'") })
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func text(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }
}

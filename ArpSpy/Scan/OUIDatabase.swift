import Foundation

/// Looks up the manufacturer from the first half of a MAC address,
/// using the IEEE list bundled as oui.csv (refresh it with scripts/update-oui.sh).
final class OUIDatabase: @unchecked Sendable {
    static let shared = OUIDatabase()

    private let lock = NSLock()
    private var table: [String: String] = [:]
    private var loaded = false

    /// Call once at launch (off the main thread); lookups before it finishes just return "".
    func loadIfNeeded() {
        lock.lock()
        if loaded { lock.unlock(); return }
        loaded = true
        lock.unlock()

        guard let url = Bundle.main.url(forResource: "oui", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let parsed = OUIDatabase.parse(text)
        lock.lock(); table = parsed; lock.unlock()
    }

    func vendor(for mac: String) -> String {
        let hex = mac.replacingOccurrences(of: ":", with: "").uppercased()
        guard hex.count >= 6 else { return "" }
        // Second-lowest bit of the first byte set = "locally administered" (phones' private Wi-Fi addresses).
        if let first = UInt8(hex.prefix(2), radix: 16), first & 0x02 != 0 { return "Private address" }
        lock.lock(); defer { lock.unlock() }
        return table[String(hex.prefix(6))] ?? ""
    }

    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        // The IEEE file uses Windows line endings. Swift treats "\r\n" as ONE character,
        // so splitting on "\n" alone never matches; isNewline catches both kinds.
        for line in text.split(whereSeparator: \.isNewline).dropFirst() {   // skip header row
            let fields = csvFields(String(line))
            guard fields.count >= 3, fields[1].count == 6 else { continue }
            result[fields[1].uppercased()] = fields[2].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// Minimal CSV splitter that understands "quoted, fields".
    static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var chars = Array(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if inQuotes, i + 1 < chars.count, chars[i + 1] == "\"" { current.append("\""); i += 1 }
                else { inQuotes.toggle() }
            } else if c == ",", !inQuotes {
                fields.append(current); current = ""
            } else {
                current.append(c)
            }
            i += 1
        }
        fields.append(current)
        chars.removeAll()
        return fields
    }
}

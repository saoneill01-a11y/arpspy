import Foundation

/// An IPv4 address stored as a number, so it sorts correctly (10.0.0.9 before 10.0.0.10).
struct IPv4: Hashable, Comparable, CustomStringConvertible, Sendable, Codable {
    let value: UInt32

    init(_ value: UInt32) { self.value = value }

    init?(_ string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, let n = UInt32(part), n <= 255 else { return nil }
            v = (v << 8) | n
        }
        value = v
    }

    var description: String {
        "\(value >> 24).\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)"
    }

    static func < (a: IPv4, b: IPv4) -> Bool { a.value < b.value }
}

enum RangeParseError: LocalizedError, Equatable {
    case invalid(String)
    case tooLarge(Int)
    case empty

    var errorDescription: String? {
        switch self {
        case .invalid(let token): return "“\(token)” isn’t a valid IP, range or subnet."
        case .tooLarge(let max): return "That’s more than \(max) addresses. Try a smaller range."
        case .empty: return "Enter an IP range to scan, like 192.168.1.1-254."
        }
    }
}

/// Turns what the user types into a list of addresses.
/// Accepts, separated by commas or spaces:
///   192.168.1.5            one address
///   192.168.1.1-254        last-octet range
///   192.168.1.1-192.168.2.10  full range
///   10.0.0.0/24            subnet (network and broadcast are skipped)
enum IPRangeParser {
    static let maxHosts = 65_536

    static func parse(_ text: String) throws -> [IPv4] {
        let tokens = text
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" || $0 == "\n" })
            .map { String($0) }
        guard !tokens.isEmpty else { throw RangeParseError.empty }

        var result: [IPv4] = []
        var seen = Set<UInt32>()
        for token in tokens {
            let (lo, hi) = try bounds(of: token)
            if result.count + Int(hi - lo) + 1 > maxHosts { throw RangeParseError.tooLarge(maxHosts) }
            for v in lo...hi where seen.insert(v).inserted {
                result.append(IPv4(v))
            }
        }
        return result
    }

    static func bounds(of token: String) throws -> (UInt32, UInt32) {
        if let slash = token.firstIndex(of: "/") {
            guard let base = IPv4(String(token[..<slash])),
                  let bits = Int(token[token.index(after: slash)...]),
                  (0...32).contains(bits) else { throw RangeParseError.invalid(token) }
            let mask: UInt32 = bits == 0 ? 0 : ~UInt32(0) << UInt32(32 - bits)
            let network = base.value & mask
            let broadcast = network | ~mask
            if bits >= 31 { return (network, broadcast) }
            return (network + 1, broadcast - 1)
        }
        if let dash = token.firstIndex(of: "-") {
            let left = String(token[..<dash])
            let right = String(token[token.index(after: dash)...])
            guard let start = IPv4(left) else { throw RangeParseError.invalid(token) }
            let end: IPv4
            if let full = IPv4(right) {
                end = full
            } else if let last = UInt32(right), last <= 255 {
                end = IPv4((start.value & 0xFFFF_FF00) | last)
            } else {
                throw RangeParseError.invalid(token)
            }
            guard end.value >= start.value else { throw RangeParseError.invalid(token) }
            return (start.value, end.value)
        }
        guard let ip = IPv4(token) else { throw RangeParseError.invalid(token) }
        return (ip.value, ip.value)
    }
}

/// A site's DHCP pool: one or more ranges typed like the scan range ("10.0.0.100-199, 10.0.0.220-250").
struct DHCPRange: Equatable, Sendable {
    let spans: [ClosedRange<UInt32>]

    /// nil when the text is blank or not a valid range.
    init?(_ text: String) {
        let tokens = text.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" || $0 == "\n" }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        var out: [ClosedRange<UInt32>] = []
        for t in tokens {
            guard let (lo, hi) = try? IPRangeParser.bounds(of: t) else { return nil }
            out.append(lo...hi)
        }
        spans = out
    }

    static func isValid(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty || DHCPRange(text) != nil
    }

    func contains(_ ip: IPv4) -> Bool { spans.contains { $0.contains(ip.value) } }

    /// "10.0.0.100-199" for the status bar.
    var short: String {
        spans.map { r in
            let a = IPv4(r.lowerBound), b = IPv4(r.upperBound)
            if r.lowerBound == r.upperBound { return a.description }
            if r.lowerBound >> 8 == r.upperBound >> 8 { return "\(a)-\(r.upperBound & 0xFF)" }
            return "\(a)-\(b)"
        }.joined(separator: ", ")
    }
}

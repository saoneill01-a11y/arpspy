import AppKit
import CryptoKit
import Foundation

/// Help › Check for Updates…: asks GitHub for the latest ARPradar release (only when clicked), downloads this Mac's
/// file into Downloads, checks it against the SHA-256 in the release notes, and can install it in place of this copy.
enum Updates {
    static let latestURL = URL(string: "https://api.github.com/repos/saoneill01-a11y/arpradar/releases/latest")!
    static let assetName = "ARPradar.zip"

    struct Release: Equatable {
        var version: String        // "1.1.0"
        var whatsNew: String       // first line under "What's new" in the notes
        var downloadURL: URL
        var sha256: String         // lower-case hex from the notes' checksum table
    }

    enum Problem: LocalizedError, Equatable {
        case noRelease, noFile, noChecksum, checksumMismatch, http(String)
        var errorDescription: String? {
            switch self {
            case .noRelease: return "GitHub didn’t return a release."
            case .noFile: return "The latest release has no Mac download."
            case .noChecksum: return "The release notes have no checksum for the Mac download, so it can’t be checked."
            case .checksumMismatch: return "The download doesn’t match the checksum in the release notes, so it was deleted. Try again later."
            case .http(let s): return s
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// "1.10.0" > "1.9.2"; a leading "v" is ignored.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The SHA-256 next to `file` in the notes' table: | `ARPradar.zip` | `abc…` |
    static func checksum(in notes: String, for file: String) -> String? {
        for line in notes.split(whereSeparator: \.isNewline) where line.contains("`\(file)`") {
            let hex = line.split(separator: "`").map(String.init).first { $0.count == 64 && $0.allSatisfy(\.isHexDigit) }
            if let hex { return hex.lowercased() }
        }
        return nil
    }

    /// The first sentence under a "## What's new…" heading (bullets and ** removed), else "".
    static func whatsNew(in notes: String) -> String {
        let lines = notes.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let h = lines.firstIndex(where: { $0.hasPrefix("#") && $0.lowercased().contains("what") }) else { return "" }
        guard let first = lines[(h + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else { return "" }
        var t = first
        if t.hasPrefix("- ") || t.hasPrefix("* ") { t.removeFirst(2) }
        t = t.replacingOccurrences(of: "**", with: "")
        if let end = t.range(of: ". ") { t = String(t[..<end.lowerBound]) + "." }
        return t
    }

    static func parse(_ json: Data, asset: String = assetName) throws -> Release {
        guard let o = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let tag = o["tag_name"] as? String else { throw Problem.noRelease }
        let notes = o["body"] as? String ?? ""
        let assets = o["assets"] as? [[String: Any]] ?? []
        guard let a = assets.first(where: { $0["name"] as? String == asset }),
              let s = a["browser_download_url"] as? String, let url = URL(string: s), url.scheme == "https" else { throw Problem.noFile }
        guard let sum = checksum(in: notes, for: asset) else { throw Problem.noChecksum }
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                       whatsNew: whatsNew(in: notes), downloadURL: url, sha256: sum)
    }

    static func latest() async throws -> Release {
        var req = URLRequest(url: latestURL, timeoutInterval: 15)
        req.setValue("ARPradar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw Problem.http(h.statusCode == 403 || h.statusCode == 429 ? "GitHub is limiting requests right now. Try again in an hour."
                                                                        : "GitHub answered \(h.statusCode).")
        }
        return try parse(data)
    }

    static func sha256(of file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads the release into ~/Downloads (as ARPradar-1.1.0.zip), checks its SHA-256 and unzips it next to it.
    /// Returns the unzipped ARPradar.app.
    static func download(_ r: Release) async throws -> URL {
        var req = URLRequest(url: r.downloadURL, timeoutInterval: 120)
        req.setValue("ARPradar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw Problem.http("The download failed (\(h.statusCode)).") }
        guard try sha256(of: tmp) == r.sha256 else { try? FileManager.default.removeItem(at: tmp); throw Problem.checksumMismatch }

        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let zip = unique(downloads.appendingPathComponent("ARPradar-\(r.version).zip"))
        try fm.moveItem(at: tmp, to: zip)
        let folder = unique(downloads.appendingPathComponent("ARPradar-\(r.version)"))
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, folder.path]
        try p.run(); p.waitUntilExit()
        let app = folder.appendingPathComponent("ARPradar.app")
        guard p.terminationStatus == 0, fm.fileExists(atPath: app.path) else { throw Problem.http("Couldn’t unzip the download.") }
        return app
    }

    /// This copy can be replaced in place when it runs from an Applications folder.
    static var canInstallInPlace: Bool {
        let path = Bundle.main.bundleURL.path
        return (path.hasPrefix("/Applications/") || path.contains("/Applications/"))
            && FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path)
    }

    /// Sets `current` aside (renamed next to it) and puts `newApp` in its place; on failure the old copy goes back.
    /// Returns where the old copy now is.
    @discardableResult
    static func swap(current: URL, with newApp: URL) throws -> URL {
        let fm = FileManager.default
        let old = current.deletingLastPathComponent().appendingPathComponent(".ARPradar-old-\(UUID().uuidString).app")
        try fm.moveItem(at: current, to: old)
        do { try fm.moveItem(at: newApp, to: current) }
        catch {
            try? fm.moveItem(at: old, to: current)   // put the old one back
            throw error
        }
        return old
    }

    /// Replaces this copy with the new app, opens it and quits.
    @MainActor
    static func install(_ newApp: URL) throws {
        let current = Bundle.main.bundleURL
        let old = try swap(current: current, with: newApp)
        try? FileManager.default.trashItem(at: old, resultingItemURL: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait until this copy has quit, then open the new one.
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", current.path]
        try p.run()
        NSApp.terminate(nil)
    }

    private static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        for n in 2...99 {
            let u = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: u.path) { return u }
        }
        return url
    }
}

@MainActor
final class UpdateModel: ObservableObject {
    static let shared = UpdateModel()

    enum State: Equatable {
        case idle, checking, upToDate(String), available(Updates.Release), downloading(Updates.Release)
        case ready(Updates.Release, URL), failed(String)
    }
    @Published var state: State = .idle

    func check() {
        if case .checking = state { return }
        if case .downloading = state { return }
        state = .checking
        Task {
            do {
                let r = try await Updates.latest()
                state = Updates.isNewer(r.version, than: Updates.currentVersion) ? .available(r) : .upToDate(Updates.currentVersion)
            } catch {
                state = .failed(Self.describe(error))
            }
        }
    }

    func download(_ r: Updates.Release) {
        state = .downloading(r)
        Task {
            do { state = .ready(r, try await Updates.download(r)) }
            catch { state = .failed(Self.describe(error)) }
        }
    }

    func install(_ app: URL) {
        do { try Updates.install(app) }
        catch {
            NSWorkspace.shared.activateFileViewerSelecting([app])
            state = .failed("Couldn’t replace ARPradar in Applications (\(error.localizedDescription)). The new copy is selected in Finder: quit ARPradar and drag it into Applications.")
        }
    }

    private static func describe(_ error: Error) -> String {
        if let p = error as? Updates.Problem { return p.localizedDescription }
        if (error as? URLError) != nil { return "No connection to github.com. Try again later, or visit arpradar.com." }
        return error.localizedDescription
    }
}

import XCTest
@testable import ArpSpy

/// Help › Check for Updates…: reading GitHub's answer, comparing versions, and the checksum check.
final class UpdateTests: XCTestCase {
    let notes = """
    **Download `ARPradar.zip` below** or `ARPradar-Windows-setup.exe`.

    | File | SHA-256 |
    |---|---|
    | `ARPradar.zip` | `428D7DD353870083DEBB4047003E443AC9B6C0648D2AC55DBBAF5E7869AFDCCC` |
    | `ARPradar-Windows-setup.exe` | `b176c106de9e4e7301c2cb060caa91018d516fd660369a0b3f5c674f06df9dbb` |

    ## What's fixed in 1.0.2

    - **Site survey scans the right network.** When you set up a survey…
    """

    func testVersionCompare() {
        XCTAssertTrue(Updates.isNewer("1.1.0", than: "1.0.2"))
        XCTAssertTrue(Updates.isNewer("v1.10.0", than: "1.9.9"))
        XCTAssertTrue(Updates.isNewer("2", than: "1.9"))
        XCTAssertFalse(Updates.isNewer("1.0.2", than: "1.0.2"))
        XCTAssertFalse(Updates.isNewer("1.0.1", than: "1.0.2"))
        XCTAssertFalse(Updates.isNewer("1.0", than: "1.0.0"))
    }

    func testChecksumAndWhatsNew() {
        XCTAssertEqual(Updates.checksum(in: notes, for: "ARPradar.zip"), "428d7dd353870083debb4047003e443ac9b6c0648d2ac55dbbaf5e7869afdccc")
        XCTAssertEqual(Updates.checksum(in: notes, for: "ARPradar-Windows-setup.exe")?.prefix(6), "b176c1")
        XCTAssertNil(Updates.checksum(in: notes, for: "Other.zip"))
        XCTAssertEqual(Updates.whatsNew(in: notes), "Site survey scans the right network.")
    }

    func testParseRelease() throws {
        let json: [String: Any] = ["tag_name": "v1.0.2", "body": notes, "assets": [
            ["name": "ARPradar-Windows-setup.exe", "browser_download_url": "https://github.com/example/w.exe"],
            ["name": "ARPradar.zip", "browser_download_url": "https://github.com/example/ARPradar.zip"]]]
        let r = try Updates.parse(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(r.version, "1.0.2")
        XCTAssertEqual(r.downloadURL.absoluteString, "https://github.com/example/ARPradar.zip")
        XCTAssertEqual(r.sha256.prefix(6), "428d7d")
    }

    func testRefusesWithoutFileOrChecksum() {
        let noFile: [String: Any] = ["tag_name": "v1.0.2", "body": notes, "assets": []]
        XCTAssertThrowsError(try Updates.parse(JSONSerialization.data(withJSONObject: noFile))) { XCTAssertEqual($0 as? Updates.Problem, .noFile) }
        let noSum: [String: Any] = ["tag_name": "v1.0.2", "body": "No table", "assets": [["name": "ARPradar.zip", "browser_download_url": "https://github.com/example/a.zip"]]]
        XCTAssertThrowsError(try Updates.parse(JSONSerialization.data(withJSONObject: noSum))) { XCTAssertEqual($0 as? Updates.Problem, .noChecksum) }
        let http: [String: Any] = ["tag_name": "v1.0.2", "body": notes, "assets": [["name": "ARPradar.zip", "browser_download_url": "http://example.com/a.zip"]]]
        XCTAssertThrowsError(try Updates.parse(JSONSerialization.data(withJSONObject: http)))
    }

    func testSwapReplacesTheAppAndKeepsTheOldOneWhenItFails() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("arpradar-swap-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let current = dir.appendingPathComponent("ARPradar.app"), new = dir.appendingPathComponent("new/ARPradar.app")
        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        try "old".write(to: current.appendingPathComponent("v"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        try "new".write(to: new.appendingPathComponent("v"), atomically: true, encoding: .utf8)

        let old = try Updates.swap(current: current, with: new)
        XCTAssertEqual(try String(contentsOf: old.appendingPathComponent("v"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("v"), encoding: .utf8), "new")
        XCTAssertFalse(fm.fileExists(atPath: new.path))

        // A new copy that isn't there: the installed one goes back where it was.
        XCTAssertThrowsError(try Updates.swap(current: current, with: dir.appendingPathComponent("missing.app")))
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("v"), encoding: .utf8), "new")
    }

    /// Asks the real GitHub and checks the real download's checksum (into a temporary file only).
    /// Only with ARPRADAR_LIVE_UPDATE set.
    func testRealLatestRelease() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["ARPRADAR_LIVE_UPDATE"] == nil, "Set ARPRADAR_LIVE_UPDATE to ask GitHub")
        let r = try await Updates.latest()
        print("LIVE latest \(r.version): \(r.whatsNew)")
        let (tmp, _) = try await URLSession.shared.download(from: r.downloadURL)
        XCTAssertEqual(try Updates.sha256(of: tmp), r.sha256)
        try? FileManager.default.removeItem(at: tmp)
    }
}

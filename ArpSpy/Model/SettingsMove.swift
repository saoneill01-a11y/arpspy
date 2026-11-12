import Foundation

/// The app's ID changed from com.example.arpspy to com.arpradar.mac (Nov 2026, for Apple signing). macOS keeps
/// settings per ID, so on the first launch with the new ID the old settings (favourites' comments, device types,
/// columns, speed tests, switches…) are copied over once. Saved scans and organizations live in
/// ~/Library/Application Support/ArpSpy and aren't affected.
enum SettingsMove {
    static let oldID = "com.example.arpspy"
    static let doneKey = "settingsMovedFromOldID"

    static func runOnce(into defaults: UserDefaults = .standard, from oldID: String = oldID) {
        // Not while the unit tests run inside the app: that would mark the move done before the real app ever opens.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard !defaults.bool(forKey: doneKey) else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard Bundle.main.bundleIdentifier != oldID else { return }
        let app = oldID as CFString
        guard let keys = CFPreferencesCopyKeyList(app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keys.isEmpty,
              let old = CFPreferencesCopyMultiple(keys as CFArray, app, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any]
        else { return }
        copy(old, into: defaults)
    }

    /// Copies every setting the new ID doesn't have yet.
    static func copy(_ old: [String: Any], into defaults: UserDefaults) {
        for (k, v) in old where defaults.object(forKey: k) == nil && k != doneKey { defaults.set(v, forKey: k) }
    }
}

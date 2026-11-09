import SwiftUI
import AppKit

/// Auto (follow the Mac), Light or Dark. Remembered between launches and applied to every window.
enum AppAppearance: String, CaseIterable, Identifiable {
    case auto, light, dark
    static let storageKey = "appearance"
    var id: String { rawValue }

    var title: String {
        switch self { case .auto: return "Auto"; case .light: return "Light"; case .dark: return "Dark" }
    }
    var symbol: String {
        switch self { case .auto: return "circle.lefthalf.filled"; case .light: return "sun.max"; case .dark: return "moon" }
    }
    var help: String {
        switch self {
        case .auto: return "Follow the Mac’s light/dark setting"
        case .light: return "Always light"
        case .dark: return "Always dark"
        }
    }

    func apply() {
        switch self {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// The small Auto / ☀︎ / ☾ picker in the status bar.
struct AppearancePicker: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.auto

    var body: some View {
        Picker("Appearance", selection: $appearance) {
            ForEach(AppAppearance.allCases) { a in
                Group {
                    if a == .auto { Text(a.title) } else { Image(systemName: a.symbol).accessibilityLabel(a.title) }
                }
                .help(a.help)
                .tag(a)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Light or dark")
    }
}

/// View > Appearance > Auto / Light / Dark.
struct AppearanceCommands: Commands {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.auto

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Picker("Appearance", selection: $appearance) {
                Text("Auto").tag(AppAppearance.auto).keyboardShortcut("0", modifiers: [.command, .option])
                Text("Light").tag(AppAppearance.light).keyboardShortcut("1", modifiers: [.command, .option])
                Text("Dark").tag(AppAppearance.dark).keyboardShortcut("2", modifiers: [.command, .option])
            }
            .onChange(of: appearance) { _, new in new.apply() }
            Divider()
        }
    }
}

/// Applies the saved choice at launch and whenever it changes.
struct AppearanceApplier: ViewModifier {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.auto
    func body(content: Content) -> some View {
        content
            .modifier(ThemeApplier())
            .onAppear { appearance.apply() }
            .onChange(of: appearance) { _, new in new.apply() }
    }
}

extension Color {
    /// The soft purple used for addresses outside a site's DHCP range (works in light and dark).
    static let dhcpOutside = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.82, green: 0.61, blue: 0.95, alpha: 1)
            : NSColor(red: 0.54, green: 0.27, blue: 0.67, alpha: 1)
    })
}

/// Basic hides the expert columns, tools and menus; Advanced shows everything. Remembered between launches.
enum AppMode {
    static let key = "advancedMode"
    static var isAdvanced: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    /// First launch of this version: people who already use ARPradar keep everything; new installs start in Basic.
    static func setDefault() {
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        UserDefaults.standard.set(FileManager.default.fileExists(atPath: DeviceStore.fileURL.path), forKey: key)
    }

    /// Columns Basic hides in the device table.
    static let advancedColumns = ["description", "mac", "ports", "response"]
}

/// The Basic / Advanced switch at the top right of the main window.
struct ModeSwitch: View {
    @AppStorage(AppMode.key) private var advanced = true

    var body: some View {
        Picker("Mode", selection: $advanced) {
            Text("Basic").tag(false)
            Text("Advanced").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Basic hides the expert columns, tools and menus (⌥⌘B)")
    }
}

import SwiftUI
import AppKit

/// Colour themes (Settings › Appearance). Each has a light and a dark version; Auto/Light/Dark picks which.
/// "System" leaves the Mac's own colours alone.
enum AppTheme: String, CaseIterable, Identifiable {
    case system, radar, ocean, sunset, graphite, contrast
    static let storageKey = "theme"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .radar: return "Radar"
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        case .graphite: return "Graphite"
        case .contrast: return "High contrast"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "Mac default"
        case .radar: return "Matches the icon"
        case .ocean: return "Soft blue-teal"
        case .sunset: return "Warm orange"
        case .graphite: return "Quiet grey"
        case .contrast: return "Easiest to read"
        }
    }

    /// Hex colours: (light, dark).
    struct Palette { let bg, bar, text, accent, online, offline: (UInt32, UInt32) }

    var palette: Palette? {
        switch self {
        case .system: return nil
        case .radar: return Palette(bg: (0xf3f8f5, 0x0e1b2c), bar: (0xe6f0ea, 0x13243a), text: (0x0e1b2c, 0xd9f5e6),
                                    accent: (0x1f9e5b, 0x2fd17a), online: (0x1f9e5b, 0x2fd17a), offline: (0xdd3333, 0xff5c5c))
        case .ocean: return Palette(bg: (0xf7fbfc, 0x0f1f26), bar: (0xe9f3f6, 0x142a33), text: (0x13303a, 0xdff2f7),
                                    accent: (0x0f8fa8, 0x3cc3dd), online: (0x18a87b, 0x3ddc97), offline: (0xe0484d, 0xff6b6b))
        case .sunset: return Palette(bg: (0xfffaf5, 0x231a14), bar: (0xfbefe3, 0x2e231b), text: (0x33241a, 0xfbeee2),
                                     accent: (0xe8710a, 0xff9a3c), online: (0x3aa655, 0x5ad07a), offline: (0xc62828, 0xff6b5e))
        case .graphite: return Palette(bg: (0xfafafa, 0x1b1b1c), bar: (0xf0f0f0, 0x242425), text: (0x222222, 0xe6e6e6),
                                       accent: (0x5c5c66, 0xa1a1aa), online: (0x5f9e6e, 0x7fbf8e), offline: (0xbb5555, 0xdd7777))
        case .contrast: return Palette(bg: (0xffffff, 0x000000), bar: (0xffffff, 0x000000), text: (0x000000, 0xffffff),
                                       accent: (0x0040dd, 0xffd400), online: (0x007a1f, 0x3dff6e), offline: (0xc00000, 0xff4d4d))
        }
    }

    // Colours that follow light/dark by themselves.
    var background: Color? { palette.map { Self.color($0.bg) } }
    var bar: Color? { palette.map { Self.color($0.bar) } }
    var text: Color? { palette.map { Self.color($0.text) } }
    var accent: Color? { palette.map { Self.color($0.accent) } }
    /// Text drawn on top of the accent colour (badges, selected tabs): black on a light accent such as
    /// High contrast's yellow, white otherwise.
    var accentText: Color {
        guard let p = palette else { return .white }
        return Color(nsColor: NSColor(name: nil) { a in
            let v = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? p.accent.1 : p.accent.0
            return Self.luminance(v) > 0.6 ? .black : .white
        })
    }
    /// Relative luminance (0 = black, 1 = white) of a hex colour.
    static func luminance(_ v: UInt32) -> Double {
        func lin(_ c: UInt32) -> Double { let s = Double(c) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin((v >> 16) & 0xff) + 0.7152 * lin((v >> 8) & 0xff) + 0.0722 * lin(v & 0xff)
    }
    var online: Color { palette.map { Self.color($0.online) } ?? .green }
    var offline: Color { palette.map { Self.color($0.offline) } ?? .red }
    var barNSColor: NSColor { palette.map { Self.nsColor($0.bar) } ?? .windowBackgroundColor }

    static func nsColor(_ pair: (UInt32, UInt32)) -> NSColor {
        NSColor(name: nil) { a in
            let v = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? pair.1 : pair.0
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
    }
    static func color(_ pair: (UInt32, UInt32)) -> Color { Color(nsColor: nsColor(pair)) }

    static var current: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }
}

/// Settings › Appearance › Row height.
enum RowDensity: String, CaseIterable, Identifiable {
    case compact, regular, roomy
    static let storageKey = "rowDensity"
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Space above and below the text in a table row.
    var padding: CGFloat { switch self { case .compact: return 1; case .regular: return 4; case .roomy: return 9 } }
}

/// Settings › Appearance › Text size (the device table and details panel).
enum TextSize: String, CaseIterable, Identifiable {
    case small, medium, large
    static let storageKey = "textSize"
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var points: CGFloat { switch self { case .small: return 11.5; case .medium: return 13; case .large: return 15 } }
}

private struct ThemeKey: EnvironmentKey { static let defaultValue = AppTheme.system }
extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Puts the theme on a window: accent, text colour, background. Used by `AppearanceApplier`.
struct ThemeApplier: ViewModifier {
    @AppStorage(AppTheme.storageKey) private var theme = AppTheme.system

    func body(content: Content) -> some View {
        if let text = theme.text, let accent = theme.accent, let bg = theme.background {
            content
                .environment(\.theme, theme)
                .tint(accent)
                .foregroundStyle(text)
                .scrollContentBackground(.hidden)
                .background(bg)
        } else {
            content.environment(\.theme, theme)
        }
    }
}

/// Settings › Appearance.
struct AppearanceSettings: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.auto
    @AppStorage(AppTheme.storageKey) private var theme = AppTheme.system
    @AppStorage(RowDensity.storageKey) private var density = RowDensity.regular
    @AppStorage(TextSize.storageKey) private var size = TextSize.medium

    var body: some View {
        Form {
            Picker("Mode", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            LabeledContent("Theme") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(104), spacing: 10), count: 3), alignment: .leading, spacing: 10) {
                    ForEach(AppTheme.allCases) { t in ThemeCard(theme: t, selected: t == theme) { theme = t } }
                }
            }

            Picker("Row height", selection: $density) {
                ForEach(RowDensity.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Picker("Text size", selection: $size) {
                ForEach(TextSize.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Text("Themes change colours only; the layout stays the same. Row height and text size apply to the device list and details panel.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }
}

/// A small picture of a theme: dark half on top, light strip below.
private struct ThemeCard: View {
    let theme: AppTheme
    let selected: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 3) {
                swatch
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                Text(theme.title).font(.callout)
                Text(theme.subtitle).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.title) theme")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func c(_ pair: KeyPath<AppTheme.Palette, (UInt32, UInt32)>, dark: Bool, fallback: NSColor) -> Color {
        guard let p = theme.palette else { return Color(nsColor: fallback) }
        let v = dark ? p[keyPath: pair].1 : p[keyPath: pair].0
        return Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    private var swatch: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                c(\.bg, dark: true, fallback: NSColor(white: 0.12, alpha: 1))
                VStack(alignment: .leading, spacing: 4) {
                    c(\.bar, dark: true, fallback: NSColor(white: 0.17, alpha: 1)).frame(height: 10)
                    Capsule().fill(c(\.accent, dark: true, fallback: .systemBlue)).frame(width: 52, height: 5).padding(.leading, 5)
                    Capsule().fill(c(\.text, dark: true, fallback: .white).opacity(0.5)).frame(width: 74, height: 5).padding(.leading, 5)
                    Capsule().fill(c(\.online, dark: true, fallback: .systemGreen)).frame(width: 34, height: 5).padding(.leading, 5)
                }
            }
            c(\.bg, dark: false, fallback: .white).frame(height: 10)
        }
    }
}

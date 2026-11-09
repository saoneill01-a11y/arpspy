import SwiftUI
import AppKit

/// Settings › General › "Show ARPradar in the menu bar": a radar icon by the clock with a small panel.
enum MenuBarSetting {
    static let key = "showInMenuBar"
}

struct MenuBarScene: Scene {
    @AppStorage(MenuBarSetting.key) private var show = false
    @ObservedObject private var model = ScanModel.shared
    @ObservedObject private var activity = Activity.shared
    @ObservedObject private var sweep = MenuBarSweep.shared

    var body: some Scene {
        MenuBarExtra(isInserted: $show) {
            MenuBarPanel()
                .modifier(AppearanceApplier())
        } label: {
            Image(nsImage: MenuBarIcon.image(angle: sweep.angle))
                .accessibilityLabel("ARPradar")
                .onChange(of: model.isScanning || activity.busy, initial: true) { _, busy in sweep.run(busy) }
        }
        .menuBarExtraStyle(.window)
    }
}

/// What drops down from the menu bar icon: the current network, a Scan button, new devices, quick tools.
struct MenuBarPanel: View {
    @ObservedObject private var model = ScanModel.shared
    @ObservedObject private var activity = Activity.shared
    @Environment(\.openWindow) private var openWindow

    private var newDevices: [Device] { model.devices.filter { $0.isOnline && $0.isNew } }
    private var offline: Int { model.devices.filter { !$0.isOnline }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RadarIcon(scanning: model.isScanning || activity.busy).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.currentSite?.name ?? "New scan (not saved)").font(.headline).lineLimit(1)
                    Text(model.rangeText).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 14) {
                count(model.onlineCount, "online")
                if offline > 0 { count(offline, "offline") }
                if !newDevices.isEmpty { count(newDevices.count, "new") }
                Spacer(minLength: 0)
                Button(model.isScanning ? "Stop" : "Scan Now") { model.toggleScan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.rangeText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if model.isScanning {
                ProgressView(value: model.progress)
            }
            Text(model.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)

            if !newDevices.isEmpty {
                Divider()
                Text("NEW DEVICES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(newDevices.prefix(5)) { d in
                    HStack {
                        Text(d.name.isEmpty ? (d.vendor.isEmpty ? "(no name)" : d.vendor) : d.name).lineLimit(1)
                        Spacer()
                        Text(d.ip.description).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if newDevices.count > 5 {
                    Text("and \(newDevices.count - 5) more").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack {
                Button("Ping…") { open(ToolWindow.ping) }
                Button("Speed Test") { open(ToolWindow.speed) }
                Spacer()
                Button("Open ARPradar") { open("main") }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func count(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(n)").font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The menu bar icon: a small copy of the app icon (navy tile, green radar) in its own colours.
enum MenuBarIcon {
    /// Where the sweep rests (degrees clockwise from 12 o'clock), as in the app icon.
    static let restAngle = RadarIcon.restAngle
    /// Points. The menu bar is 24 points tall.
    static let size: CGFloat = 21

    static func image(angle: Double) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            draw(angle: angle)
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "ARPradar"
        return img
    }

    /// Drawn on a 24-unit grid, scaled to `size` points.
    private static func draw(angle: Double) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.scaleBy(x: size / 24, y: size / 24)
        let navy = NSColor(srgbRed: 0x0e / 255, green: 0x1b / 255, blue: 0x2c / 255, alpha: 1)
        let green = NSColor(srgbRed: 0x2f / 255, green: 0xd1 / 255, blue: 0x7a / 255, alpha: 1)
        let bright = NSColor(srgbRed: 0x7d / 255, green: 1, blue: 0xb2 / 255, alpha: 1)
        let c = CGPoint(x: 12, y: 12)

        navy.setFill()
        NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 21, height: 21), xRadius: 5.2, yRadius: 5.2).fill()

        green.withAlphaComponent(0.5).setStroke()
        for r in [7.5, 4.2] {
            let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            ring.lineWidth = 1
            ring.stroke()
        }

        // The sweep: a 60° wedge ending at `angle` (clockwise from 12 o'clock; y points down here).
        let r = 7.5
        func point(_ deg: Double) -> CGPoint {
            let a = deg * .pi / 180
            return CGPoint(x: c.x + r * sin(a), y: c.y - r * cos(a))
        }
        let wedge = CGMutablePath()
        wedge.move(to: c)
        wedge.addLine(to: point(angle - 60))
        wedge.addArc(center: c, radius: r, startAngle: (angle - 60 - 90) * .pi / 180, endAngle: (angle - 90) * .pi / 180, clockwise: false)
        wedge.closeSubpath()
        ctx.addPath(wedge)
        ctx.setFillColor(green.withAlphaComponent(0.45).cgColor)
        ctx.fillPath()

        ctx.setStrokeColor(green.cgColor)
        ctx.setLineWidth(1.4)
        ctx.setLineCap(.round)
        ctx.move(to: c)
        ctx.addLine(to: point(angle))
        ctx.strokePath()

        bright.setFill()
        NSBezierPath(ovalIn: NSRect(x: 16.2 - 1.3, y: 7.6 - 1.3, width: 2.6, height: 2.6)).fill()
        green.setFill()
        NSBezierPath(ovalIn: NSRect(x: 8 - 1.1, y: 15 - 1.1, width: 2.2, height: 2.2)).fill()
    }
}

/// Turns the menu bar icon's sweep while ARPradar is scanning (10 frames a second; nothing runs when idle).
@MainActor
final class MenuBarSweep: ObservableObject {
    static let shared = MenuBarSweep()
    @Published private(set) var angle = MenuBarIcon.restAngle
    private var timer: Timer?
    private var startedAt = Date()

    func run(_ on: Bool) {
        if on {
            guard timer == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            startedAt = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let turns = Date().timeIntervalSince(self.startedAt) / RadarIcon.turnSeconds
                    self.angle = (MenuBarIcon.restAngle + turns * 360).truncatingRemainder(dividingBy: 360)
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
            angle = MenuBarIcon.restAngle
        }
    }
}

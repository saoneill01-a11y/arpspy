import SwiftUI

/// The app icon, drawn live: the sweep turns while a scan runs and stops when it's done.
/// Each dot lights up right after the sweep passes over it, then fades.
struct RadarIcon: View {
    let scanning: Bool
    /// One turn takes this long.
    static let turnSeconds = 3.0
    /// Where the sweep rests when idle (degrees clockwise from 12 o'clock), as in the app icon.
    static let restAngle = 60.0
    @State private var startedAt = Date()
    @State private var stoppedAngle = restAngle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if scanning && !reduceMotion {
                TimelineView(.animation) { tl in
                    RadarFace(angle: angle(at: tl.date))
                }
            } else {
                RadarFace(angle: stoppedAngle)
            }
        }
        .onChange(of: scanning) { _, now in
            if now { startedAt = Date() } else { stoppedAngle = angle(at: Date()) }
        }
        .help(scanning ? "Scanning…" : "ARPradar")
        .accessibilityHidden(true)
    }

    private func angle(at date: Date) -> Double {
        let turns = date.timeIntervalSince(startedAt) / Self.turnSeconds
        return (Self.restAngle + turns * 360).truncatingRemainder(dividingBy: 360)
    }
}

/// One frame of the radar, in the app icon's 200×200 layout.
struct RadarFace: View {
    let angle: Double

    /// Blips: position (in the 200-unit icon), radius, and the base colour.
    static let blips: [(x: Double, y: Double, r: Double)] = [(138, 60, 7), (64, 128, 6), (122, 140, 5)]
    static let green = Color(red: 0.184, green: 0.820, blue: 0.478)      // #2fd17a
    static let bright = Color(red: 0.490, green: 1.0, blue: 0.698)        // #7dffb2

    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 200
            let c = CGPoint(x: 100 * s, y: 100 * s)
            func pt(_ deg: Double, _ r: Double) -> CGPoint {
                let a = deg * .pi / 180
                return CGPoint(x: c.x + r * s * sin(a), y: c.y - r * s * cos(a))
            }

            let bg = Path(roundedRect: CGRect(x: 0, y: 0, width: 200 * s, height: 200 * s), cornerRadius: 45 * s)
            ctx.fill(bg, with: .color(Color(red: 0.055, green: 0.106, blue: 0.173)))   // #0e1b2c

            for r in [68.0, 45, 22] {
                let ring = Path(ellipseIn: CGRect(x: c.x - r * s, y: c.y - r * s, width: 2 * r * s, height: 2 * r * s))
                ctx.stroke(ring, with: .color(Self.green.opacity(0.35)), lineWidth: 3 * s)
            }

            // The sweep: a 60° wedge trailing behind the line.
            var wedge = Path()
            wedge.move(to: c)
            wedge.addLine(to: pt(angle - 60, 68))
            wedge.addArc(center: c, radius: 68 * s, startAngle: .degrees(angle - 60 - 90),
                         endAngle: .degrees(angle - 90), clockwise: false)
            wedge.closeSubpath()
            ctx.fill(wedge, with: .linearGradient(Gradient(colors: [Self.green.opacity(0), Self.green.opacity(0.4)]),
                                                  startPoint: pt(angle - 60, 50), endPoint: pt(angle, 50)))
            var line = Path()
            line.move(to: c); line.addLine(to: pt(angle, 68))
            ctx.stroke(line, with: .color(Self.green), style: StrokeStyle(lineWidth: 4 * s, lineCap: .round))

            for b in Self.blips {
                let level = Self.glow(blipAngle: Self.angle(of: b.x, b.y), sweep: angle)
                let rect = CGRect(x: (b.x - b.r) * s, y: (b.y - b.r) * s, width: 2 * b.r * s, height: 2 * b.r * s)
                ctx.fill(Path(ellipseIn: rect), with: .color((level > 0.8 ? Self.bright : Self.green).opacity(level)))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 6 * s, y: c.y - 6 * s, width: 12 * s, height: 12 * s)),
                     with: .color(Self.green))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Angle of a point, in degrees clockwise from 12 o'clock.
    static func angle(of x: Double, _ y: Double) -> Double {
        let a = atan2(x - 100, 100 - y) * 180 / .pi
        return a < 0 ? a + 360 : a
    }

    /// 1 just after the sweep passes the dot, fading to a dim glow by the time the sweep comes round again.
    /// A dot the sweep hasn't reached yet stays dim.
    static func glow(blipAngle: Double, sweep: Double) -> Double {
        var behind = (sweep - blipAngle).truncatingRemainder(dividingBy: 360)
        if behind < 0 { behind += 360 }
        let dim = 0.2
        return max(dim, 1 - behind / 300 * (1 - dim))
    }
}

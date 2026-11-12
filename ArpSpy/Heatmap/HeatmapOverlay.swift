import SwiftUI
import AppKit

/// Where a floor plan sits over the map picture, in map-picture pixels.
struct HeatOverlay: Codable, Hashable, Sendable {
    /// Its centre.
    var cx: Double, cy: Double
    /// Its width (its height follows its own shape).
    var width: Double
    /// Degrees, clockwise.
    var rotation: Double = 0
    /// 0…1: how solid the floor plan is drawn over the map.
    var opacity: Double = 0.85
    /// Whether its white background was removed.
    var stripped = true
    /// Draw its lines white instead of black (easier to see on a dark satellite picture).
    var white = false
    /// 0…1: how strongly the satellite picture shows under it (lower = faded towards white).
    var mapOpacity = 1.0

    init(cx: Double, cy: Double, width: Double, rotation: Double = 0, opacity: Double = 0.85, stripped: Bool = true,
         white: Bool = false, mapOpacity: Double = 1) {
        self.cx = cx; self.cy = cy; self.width = width; self.rotation = rotation; self.opacity = opacity
        self.stripped = stripped; self.white = white; self.mapOpacity = mapOpacity
    }

    /// Reads field by field, so overlays saved before a setting existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cx = try c.decode(Double.self, forKey: .cx); cy = try c.decode(Double.self, forKey: .cy)
        width = try c.decode(Double.self, forKey: .width)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.85
        stripped = try c.decodeIfPresent(Bool.self, forKey: .stripped) ?? true
        white = try c.decodeIfPresent(Bool.self, forKey: .white) ?? false
        mapOpacity = try c.decodeIfPresent(Double.self, forKey: .mapOpacity) ?? 1
    }
}

extension Heatmap {
    /// A floor plan with its paper removed: white and near-white (and light grey, unless it's coloured) becomes clear,
    /// with a soft edge so lines stay smooth. Walls, text and anything coloured stay.
    static func stripBackground(_ png: Data) -> Data? {
        guard let src = NSBitmapImageRep(data: png) else { return nil }
        let w = src.pixelsWide, h = src.pixelsHigh
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32),
              let out = rep.bitmapData else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        src.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        for i in 0..<(w * h) {
            let p = i * 4
            let r = Double(out[p]), g = Double(out[p + 1]), b = Double(out[p + 2]), a = Double(out[p + 3])
            guard a > 0 else { continue }
            // Un-premultiply to judge the colour.
            let R = r / a, G = g / a, B = b / a
            let hi = max(R, G, B), lo = min(R, G, B)
            let sat = hi > 0 ? (hi - lo) / hi : 0
            guard sat < 0.18 else { continue }
            // Brightness 0.80 and below stays; 0.93 and above goes; in between fades.
            let keep = min(1, max(0, (0.93 - hi) / 0.13))
            let na = a * keep
            out[p] = UInt8(min(255, R * na)); out[p + 1] = UInt8(min(255, G * na)); out[p + 2] = UInt8(min(255, B * na))
            out[p + 3] = UInt8(min(255, na))
        }
        return rep.representation(using: .png, properties: [:])
    }

    /// The map picture with the floor plan drawn on it where `o` says.
    static func composite(base: NSImage, basePixels: CGSize, overlay: NSImage, overlayPixels: CGSize, o: HeatOverlay) -> Data? {
        let w = Int(basePixels.width), h = Int(basePixels.height)
        guard w > 0, h > 0, overlayPixels.width > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        // The map, faded towards white as asked.
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
        base.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: o.mapOpacity)
        let overlay = o.white ? whitened(overlay) : overlay
        let cg = ctx.cgContext
        let ow = o.width, oh = o.width * overlayPixels.height / overlayPixels.width
        cg.translateBy(x: o.cx, y: Double(h) - o.cy)           // plan pixels have y going down; the context's go up
        cg.rotate(by: -o.rotation * .pi / 180)
        overlay.draw(in: NSRect(x: -ow / 2, y: -oh / 2, width: ow, height: oh), from: .zero, operation: .sourceOver, fraction: o.opacity)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// The same picture with every line white (its see-through parts stay see-through).
    static func whitened(_ img: NSImage) -> NSImage {
        let out = NSImage(size: img.size)
        out.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: img.size))
        NSColor.white.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    static func pixelSize(_ url: URL) -> CGSize? {
        guard let rep = NSImage(contentsOf: url)?.representations.compactMap({ $0 as? NSBitmapImageRep }).first else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

extension HeatmapStore {
    func baseURL(_ s: HeatSurvey) -> URL? { s.baseFile.map { dir(s.id).appendingPathComponent($0) } }
    private func overlayURL(_ id: UUID, original: Bool = false) -> URL {
        dir(id).appendingPathComponent(original ? "overlay-original.png" : "overlay.png")
    }

    /// After a plan from Apple Maps: keep that picture as base.png too (and drop any old overlay).
    func keepPlanAsBase(_ id: UUID) {
        let d = dir(id), fm = FileManager.default
        try? fm.removeItem(at: d.appendingPathComponent("base.png"))
        guard (try? fm.copyItem(at: d.appendingPathComponent("plan.png"), to: d.appendingPathComponent("base.png"))) != nil else { return }
        update(id) { $0.baseFile = "base.png"; $0.overlay = nil }
    }

    /// Loads a floor plan (picture or PDF) to lay over the map picture; keeps it as loaded and with its paper removed.
    func setOverlay(_ id: UUID, from url: URL) throws {
        guard let s = survey(id), s.baseFile != nil else { throw Self.problem("Make a plan from Apple Maps first.") }
        guard let png = Self.planPNG(url) else { throw Self.problem("That file isn’t a picture or PDF ARPradar can read.") }
        try png.data.write(to: overlayURL(id, original: true), options: .atomic)
        try (Heatmap.stripBackground(png.data) ?? png.data).write(to: overlayURL(id), options: .atomic)
        // Start in the middle, half as wide as the map picture.
        let width = s.planWidth * 0.5
        update(id) { $0.overlay = HeatOverlay(cx: s.planWidth / 2, cy: s.planHeight / 2, width: width) }
    }

    /// The floor plan as loaded (`original`) or with its background removed.
    func overlayPicture(_ id: UUID, original: Bool) -> NSImage? { NSImage(contentsOf: overlayURL(id, original: original)) }

    func baseImage(_ s: HeatSurvey) -> NSImage? { baseURL(s).flatMap { NSImage(contentsOf: $0) } }

    /// Puts the floor plan on the map picture and makes that the heatmap's plan. Measured spots keep their places
    /// (the picture is the same size), and so does the scale.
    func applyOverlay(_ id: UUID, _ o: HeatOverlay) throws {
        guard let s = survey(id), let bURL = baseURL(s), let base = NSImage(contentsOf: bURL), let bPx = Heatmap.pixelSize(bURL) else {
            throw Self.problem("The map picture is missing. Make the plan from Apple Maps again.")
        }
        let oURL = overlayURL(id, original: !o.stripped)
        guard let over = NSImage(contentsOf: oURL), let oPx = Heatmap.pixelSize(oURL) else { throw Self.problem("The floor plan picture is missing.") }
        guard let data = Heatmap.composite(base: base, basePixels: bPx, overlay: over, overlayPixels: oPx, o: o) else {
            throw Self.problem("Couldn’t put the floor plan on the map.")
        }
        try data.write(to: dir(id).appendingPathComponent("plan.png"), options: .atomic)
        forgetPlan(id)
        update(id) { $0.overlay = o; $0.planFile = "plan.png"; $0.planWidth = bPx.width; $0.planHeight = bPx.height }
    }

    /// Takes the floor plan off again: the plan is the plain map picture.
    func removeOverlay(_ id: UUID) {
        guard let s = survey(id), let bURL = baseURL(s) else { return }
        let plan = dir(id).appendingPathComponent("plan.png")
        try? FileManager.default.removeItem(at: plan)
        try? FileManager.default.copyItem(at: bURL, to: plan)
        forgetPlan(id)
        update(id) { $0.overlay = nil }
    }

    static func problem(_ text: String) -> NSError { NSError(domain: "ARPradar", code: 3, userInfo: [NSLocalizedDescriptionKey: text]) }
}

/// Floor Plan › Lay a Floor Plan Over the Map: drag it into place, then size, turn and fade it to line it up.
struct OverlayComposer: View {
    let base: NSImage
    let basePixels: CGSize
    let original: NSImage?
    let stripped: NSImage?
    @State var o: HeatOverlay
    let onDone: (HeatOverlay) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var dragStart: CGPoint? = nil
    @State private var pinchStart: Double? = nil
    @State private var turnStart: Double? = nil
    /// Zooming the view in on the map (1 = whole map), to line up details. Doesn't change the plan.
    @State private var zoom = 1.0
    @State private var viewZoomStart: Double? = nil

    /// White-line versions, made once (redrawing a big picture on every drag step would make dragging lag).
    @State private var whiteStripped: NSImage? = nil
    @State private var whiteOriginal: NSImage? = nil

    private var picture: NSImage? {
        guard let p = o.stripped ? stripped : original else { return nil }
        guard o.white else { return p }
        return (o.stripped ? whiteStripped : whiteOriginal) ?? p
    }
    private var aspect: Double {
        guard let p = picture, p.size.width > 0 else { return 1 }
        return p.size.height / p.size.width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Line up the floor plan with the map").font(.headline)
            Text("Drag the floor plan onto the building. Pinch it or use Size to scale it, and Turn to rotate it, until the walls sit on the roof lines. Zoom in (or pinch the map) for the fine lining up; fade the map or switch the plan to white lines to see both better.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GeometryReader { g in
                let k = min(g.size.width / basePixels.width, g.size.height / basePixels.height) * zoom
                let area = CGSize(width: max(g.size.width, basePixels.width * k), height: max(g.size.height, basePixels.height * k))
                let ox = (area.width - basePixels.width * k) / 2, oy = (area.height - basePixels.height * k) / 2
                ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.white.frame(width: basePixels.width * k, height: basePixels.height * k).offset(x: ox, y: oy)
                    Image(nsImage: base).resizable()
                        .frame(width: basePixels.width * k, height: basePixels.height * k)
                        .opacity(o.mapOpacity)
                        .offset(x: ox, y: oy)
                        // Pinching the map (not the plan) zooms the view.
                        .gesture(MagnifyGesture()
                            .onChanged { v in
                                if viewZoomStart == nil { viewZoomStart = zoom }
                                zoom = min(8, max(1, viewZoomStart! * v.magnification))
                            }
                            .onEnded { _ in viewZoomStart = nil })
                    if let p = picture {
                        Image(nsImage: p).resizable()
                            .frame(width: o.width * k, height: o.width * aspect * k)
                            .overlay(Rectangle().stroke(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                            .rotationEffect(.degrees(o.rotation))
                            .opacity(o.opacity)
                            .position(x: ox + o.cx * k, y: oy + o.cy * k)
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { v in
                                    if dragStart == nil { dragStart = CGPoint(x: o.cx, y: o.cy) }
                                    o.cx = dragStart!.x + v.translation.width / k
                                    o.cy = dragStart!.y + v.translation.height / k
                                }
                                .onEnded { _ in dragStart = nil })
                            .simultaneousGesture(MagnifyGesture()
                                .onChanged { v in
                                    if pinchStart == nil { pinchStart = o.width }
                                    o.width = min(basePixels.width * 4, max(basePixels.width * 0.05, pinchStart! * v.magnification))
                                }
                                .onEnded { _ in pinchStart = nil })
                            .simultaneousGesture(RotateGesture()
                                .onChanged { v in
                                    if turnStart == nil { turnStart = o.rotation }
                                    o.rotation = Self.wrap(turnStart! + v.rotation.degrees)
                                }
                                .onEnded { _ in turnStart = nil })
                            .help("Drag to move; pinch to size; two-finger twist to turn")
                    }
                }
                .frame(width: area.width, height: area.height, alignment: .topLeading)
                }
                .scrollIndicators(zoom > 1.001 ? .visible : .hidden)
            }
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Size").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { log2(o.width / basePixels.width) }, set: { o.width = basePixels.width * pow(2, $0) }), in: -4.3...2)
                    Text("\(Int((o.width / basePixels.width * 100).rounded()))% of the map").font(.caption).monospacedDigit().frame(width: 110, alignment: .leading)
                }
                GridRow {
                    Text("Turn").foregroundStyle(.secondary)
                    Slider(value: $o.rotation, in: -180...180)
                    HStack(spacing: 4) {
                        Button("−90°") { o.rotation = Self.wrap(o.rotation - 90) }
                        Button("+90°") { o.rotation = Self.wrap(o.rotation + 90) }
                        Text("\(Int(o.rotation.rounded()))°").font(.caption).monospacedDigit()
                    }
                    .controlSize(.small)
                }
                GridRow {
                    Text("Plan").foregroundStyle(.secondary)
                    Slider(value: $o.opacity, in: 0.2...1)
                    HStack(spacing: 6) {
                        Text("\(Int((o.opacity * 100).rounded()))% solid").font(.caption).monospacedDigit()
                        Picker("", selection: $o.white) { Text("Black").tag(false); Text("White").tag(true) }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                            .help("Plan lines in black, or white to stand out on a dark satellite picture")
                    }
                }
                GridRow {
                    Text("Map").foregroundStyle(.secondary)
                    Slider(value: $o.mapOpacity, in: 0.15...1)
                    Text("\(Int((o.mapOpacity * 100).rounded()))% (fade the satellite)").font(.caption).monospacedDigit().frame(width: 150, alignment: .leading)
                }
                GridRow {
                    Text("Zoom").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { log2(zoom) }, set: { zoom = pow(2, $0) }), in: 0...3)
                    HStack(spacing: 6) {
                        Text("\(Int((zoom * 100).rounded()))%").font(.caption).monospacedDigit()
                        Button("Fit") { zoom = 1 }.controlSize(.small).disabled(zoom <= 1.001)
                    }
                }
            }
            HStack {
                Toggle("Remove the plan’s white background", isOn: $o.stripped).toggleStyle(.checkbox)
                    .disabled(original == nil || stripped == nil)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") { onDone(o); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 700, idealHeight: 780)
        .onAppear {
            whiteStripped = stripped.map(Heatmap.whitened)
            whiteOriginal = original.map(Heatmap.whitened)
        }
    }

    static func wrap(_ d: Double) -> Double { var d = d.truncatingRemainder(dividingBy: 360); if d > 180 { d -= 360 }; if d < -180 { d += 360 }; return d }
}

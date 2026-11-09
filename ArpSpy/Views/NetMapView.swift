import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Layout

/// Where each box goes: a top-down tree, the gateway at the top, each level's boxes spread under their parent.
/// Box sizes: Full (icon, three lines) or Compact (narrower, no icon, smaller text).
struct MapStyle: Equatable {
    var nodeW: CGFloat, nodeH: CGFloat, hGap: CGFloat, vGap: CGFloat, chipH: CGFloat
    var compact = false
    static let full = MapStyle(nodeW: 210, nodeH: 62, hGap: 26, vGap: 78, chipH: 24)
    static let compactStyle = MapStyle(nodeW: 104, nodeH: 36, hGap: 8, vGap: 44, chipH: 16, compact: true)
}

struct MapLayout {
    static let nodeW = MapStyle.full.nodeW, nodeH = MapStyle.full.nodeH, hGap = MapStyle.full.hGap
    let style: MapStyle
    let centers: [String: CGPoint]
    let size: CGSize
    let showClients: Bool
    /// Parents whose children are laid out in a grid (drawn with a bus line instead of one curve each).
    let wrapped: Set<String>

    /// More than this many children with nothing under them wrap onto further rows.
    static let maxPerRow = 6

    init(_ map: NetMap, showClients: Bool, scale: CGFloat = 1, style: MapStyle = .full) {
        self.showClients = showClients
        self.style = style
        let nodeW = style.nodeW, nodeH = style.nodeH, hGap = style.hGap
        let levelH = nodeH + style.vGap + (showClients ? style.chipH + 10 : 0)
        var widths: [String: CGFloat] = [:]
        var visiting = Set<String>()
        var kidsOf: [String: [MapNode]] = [:]
        func kids(_ id: String) -> [MapNode] {
            if let k = kidsOf[id] { return k }
            let k = map.children(of: id); kidsOf[id] = k; return k
        }
        /// Children that are all leaves and too many for one row are laid out in a grid.
        func wraps(_ id: String) -> Bool {
            let k = kids(id)
            return k.count > Self.maxPerRow && k.allSatisfy { kids($0.id).isEmpty }
        }
        func width(_ id: String) -> CGFloat {
            if let w = widths[id] { return w }
            guard visiting.insert(id).inserted else { return nodeW }
            let k = kids(id)
            let sum: CGFloat
            if wraps(id) {
                sum = CGFloat(Self.maxPerRow) * nodeW + CGFloat(Self.maxPerRow - 1) * hGap
            } else {
                sum = k.map { width($0.id) }.reduce(0, +) + CGFloat(max(0, k.count - 1)) * hGap
            }
            let w = max(nodeW, sum)
            widths[id] = w
            return w
        }
        var centers: [String: CGPoint] = [:]
        var wrappedIDs = Set<String>()
        var maxDepth = 0
        func put(_ id: String, x: CGFloat, depth: Int) {
            centers[id] = CGPoint(x: x * scale, y: (24 + nodeH / 2 + CGFloat(depth) * levelH) * scale)
            maxDepth = max(maxDepth, depth)
        }
        func place(_ id: String, left: CGFloat, depth: Int) {
            guard centers[id] == nil else { return }
            let w = width(id)
            put(id, x: left + w / 2, depth: depth)
            let k = kids(id)
            if wraps(id) {
                wrappedIDs.insert(id)
                for (i, child) in k.enumerated() {
                    let row = i / Self.maxPerRow, col = i % Self.maxPerRow
                    let inRow = min(Self.maxPerRow, k.count - row * Self.maxPerRow)
                    let rowW = CGFloat(inRow) * nodeW + CGFloat(inRow - 1) * hGap
                    let x = left + (w - rowW) / 2 + CGFloat(col) * (nodeW + hGap) + nodeW / 2
                    put(child.id, x: x, depth: depth + 1 + row)
                }
                return
            }
            let sum = k.map { width($0.id) }.reduce(0, +) + CGFloat(max(0, k.count - 1)) * hGap
            var x = left + (w - sum) / 2
            for child in k {
                place(child.id, left: x, depth: depth + 1)
                x += width(child.id) + hGap
            }
        }
        var left: CGFloat = 24
        // Anything not reachable from the root (shouldn't happen) goes alongside it.
        let tops = map.nodes.filter { n in n.parent == nil || map.node(n.parent) == nil }
        for t in tops {
            place(t.id, left: left, depth: 0)
            left += width(t.id) + hGap
        }
        // Anything still not placed (a loop in a map saved by an older version) goes alongside too.
        for n in map.nodes where centers[n.id] == nil {
            place(n.id, left: left, depth: 0)
            left += width(n.id) + hGap
        }
        self.centers = centers
        self.wrapped = wrappedIDs
        let w = (left + 24 - hGap) * scale
        let h = (24 + CGFloat(maxDepth + 1) * levelH + 24) * scale
        self.size = CGSize(width: max(w, 300), height: h)
    }
}

extension MapNode {
    var symbol: String {
        switch kind {
        case .gateway: return "network.badge.shield.half.filled"
        case .switchDevice: return "rectangle.connected.to.line.below"
        case .accessPoint: return "wifi.router"
        case .device: return model.localizedCaseInsensitiveContains("UVC") || model.localizedCaseInsensitiveContains("camera") ? "video" : "cube"
        case .guessSwitch: return "questionmark.square.dashed"
        case .other: return "questionmark.circle"
        }
    }

    /// "P1 ⇄ P8 · 1G", "Mesh · −61 dBm"
    var linkLabel: String {
        if wireless { return "Mesh" + (signal.map { " · \($0) dBm" } ?? "") }
        var parts: [String] = []
        switch (parentPort, uplinkPort) {
        case let (p?, u?): parts.append("P\(p) ⇄ P\(u)")
        case let (p?, nil): parts.append("P\(p)")
        case let (nil, u?): parts.append("⇄ P\(u)")
        default: break
        }
        if let l = linkMbps, l > 0 { parts.append(Self.speed(l)) }
        return parts.joined(separator: " · ") + (slowLink ? " ⚠" : "")
    }

    static func speed(_ mbps: Int) -> String {
        mbps >= 1000 ? (mbps % 1000 == 0 ? "\(mbps / 1000)G" : String(format: "%.1fG", Double(mbps) / 1000)) : "\(mbps)M"
    }

    var clientSummary: String {
        let w = wiredClients.count, f = wifiClients.count
        var parts: [String] = []
        if w > 0 { parts.append("\(w) wired") }
        if f > 0 { parts.append("\(f) Wi-Fi") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The drawing (also used for Export)

struct MapCanvas: View {
    static let rootAnchor = "map-root"
    let map: NetMap
    let layout: MapLayout
    var selected: String? = nil
    var scale: CGFloat = 1
    var onSelect: (String) -> Void = { _ in }
    /// The box whose client list is open (clicked its "N wired · N Wi-Fi" chip).
    @State private var clientsFor: String? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Links
            Canvas { ctx, _ in
                let half = layout.style.nodeH / 2 * scale
                // A grid of children: parent → trunk on the left → a bus above each row → a drop to each box.
                for p in layout.wrapped {
                    guard let a = layout.centers[p] else { continue }
                    let kids = map.nodes.filter { $0.parent == p }
                    let pts = kids.compactMap { layout.centers[$0.id] }
                    guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max() else { continue }
                    let rows = Set(pts.map(\.y)).sorted()
                    let busYs = rows.map { $0 - half - (layout.style.compact ? 16 : 22) * scale }
                    let trunkX = minX - (layout.style.nodeW / 2 + layout.style.hGap / 2) * scale
                    let dashed = !map.cabled
                    let style = StrokeStyle(lineWidth: 2 * scale, dash: dashed ? [6 * scale, 5 * scale] : [])
                    var path = Path()
                    path.move(to: CGPoint(x: a.x, y: a.y + half))
                    path.addLine(to: CGPoint(x: a.x, y: busYs[0]))
                    path.move(to: CGPoint(x: trunkX, y: busYs[0]))
                    path.addLine(to: CGPoint(x: trunkX, y: busYs.last!))
                    for (row, y) in zip(rows, busYs) {
                        let xs = pts.filter { $0.y == row }.map(\.x)
                        path.move(to: CGPoint(x: trunkX, y: y))
                        path.addLine(to: CGPoint(x: max(xs.max() ?? maxX, a.x), y: y))
                    }
                    ctx.stroke(path, with: .color(.secondary.opacity(0.7)), style: style)
                    // Each box's own drop from the bus is coloured by its link speed.
                    for k in kids {
                        guard let b = layout.centers[k.id], let i = rows.firstIndex(of: b.y) else { continue }
                        var drop = Path()
                        drop.move(to: CGPoint(x: b.x, y: busYs[i])); drop.addLine(to: CGPoint(x: b.x, y: b.y - half))
                        let d = dashed || k.wireless
                        ctx.stroke(drop, with: .color(Self.linkColor(k)), style: StrokeStyle(lineWidth: 2 * scale, dash: d ? [6 * scale, 5 * scale] : []))
                    }
                }
                for n in map.nodes {
                    guard let p = n.parent, !layout.wrapped.contains(p), let a = layout.centers[p], let b = layout.centers[n.id] else { continue }
                    let start = CGPoint(x: a.x, y: a.y + layout.style.nodeH / 2 * scale)
                    let end = CGPoint(x: b.x, y: b.y - layout.style.nodeH / 2 * scale)
                    var path = Path()
                    path.move(to: start)
                    let midY = (start.y + end.y) / 2
                    path.addCurve(to: end, control1: CGPoint(x: start.x, y: midY), control2: CGPoint(x: end.x, y: midY))
                    let dashed = n.wireless || !map.cabled
                    ctx.stroke(path, with: .color(Self.linkColor(n)), style: StrokeStyle(lineWidth: 2 * scale, dash: dashed ? [6 * scale, 5 * scale] : []))
                }
                if layout.showClients {
                    for n in map.nodes where !n.clients.isEmpty {
                        guard let c = layout.centers[n.id] else { continue }
                        var path = Path()
                        path.move(to: CGPoint(x: c.x, y: c.y + layout.style.nodeH / 2 * scale))
                        path.addLine(to: CGPoint(x: c.x, y: c.y + (layout.style.nodeH / 2 + 10) * scale))
                        ctx.stroke(path, with: .color(.secondary.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5 * scale))
                    }
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)

            // Port labels, just above each box
            ForEach(map.nodes.filter { $0.parent != nil && !$0.linkLabel.isEmpty }) { n in
                if let c = layout.centers[n.id] {
                    Text(n.linkLabel)
                        .font(.system(size: (layout.style.compact ? 8.5 : 10.5) * scale, design: .monospaced))
                        .foregroundStyle(n.slowLink ? Color.orange : Color.secondary)
                        .fontWeight(n.slowLink ? .semibold : .regular)
                        .fixedSize()
                        .padding(.horizontal, 4 * scale)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.85), in: Capsule())
                        .position(x: c.x, y: c.y - (layout.style.nodeH / 2 + 14) * scale)
                }
            }

            ForEach(map.nodes) { n in
                if let c = layout.centers[n.id] {
                    MapNodeBox(node: n, selected: n.id == selected, scale: scale, compact: layout.style.compact)
                        .frame(width: layout.style.nodeW * scale, height: layout.style.nodeH * scale)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(n.id) }
                        .position(c)
                    if layout.showClients && !n.clients.isEmpty {
                        Text(n.clientSummary)
                            .font(.system(size: (layout.style.compact ? 9 : 11) * scale, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, (layout.style.compact ? 5 : 10) * scale).padding(.vertical, (layout.style.compact ? 1 : 3) * scale)
                            .background(Color.accentColor.opacity(0.13), in: Capsule())
                            .fixedSize()
                            .contentShape(Capsule())
                            .onTapGesture { onSelect(n.id); clientsFor = n.id }
                            .help("Show the clients and the port each is on")
                            .popover(isPresented: Binding(get: { clientsFor == n.id }, set: { if !$0 { clientsFor = nil } }),
                                     arrowEdge: .bottom) { MapClientsPopover(node: n) }
                            .position(x: c.x, y: c.y + (layout.style.nodeH / 2 + 10 + layout.style.chipH / 2) * scale)
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            // Where the gateway is, so the map can open scrolled to it.
            if let r = map.root, let c = layout.centers[r.id] {
                Color.clear.frame(width: 1, height: 1).position(x: c.x, y: max(1, c.y - layout.style.nodeH * scale)).id(MapCanvas.rootAnchor)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }
}

extension MapCanvas {
    /// 10G blue, 2.5G/5G light blue, 1G green, 100M or less orange; Wi-Fi and unknown speeds grey.
    static func linkColor(_ n: MapNode) -> Color {
        guard !n.wireless, let m = n.linkMbps, m > 0 else { return .secondary.opacity(0.7) }
        return LinkSpeed.color(m)
    }
}

/// The client list shown when the "12 wired · 3 Wi-Fi" chip under a box is clicked: each client and its port.
struct MapClientsPopover: View {
    let node: MapNode

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(node.name.isEmpty ? node.model : node.name).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if !node.wiredClients.isEmpty { list("Wired", node.wiredClients.sorted { ($0.port ?? 9999, $0.displayName) < ($1.port ?? 9999, $1.displayName) }) }
                    if !node.wifiClients.isEmpty { list("Wi-Fi", node.wifiClients.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) }
                }
            }
            .frame(maxHeight: 420)
            Button("Copy List") {
                let lines = node.clients.map { c in
                    [c.port.map { "P\($0)" } ?? (c.wired ? "" : "Wi-Fi"), c.displayName, c.ip, c.mac].joined(separator: "\t")
                }
                Exporter.copyToClipboard(lines.joined(separator: "\n"))
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 360)
    }

    private func list(_ title: String, _ clients: [MapClient]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(title) (\(clients.count))").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(clients) { c in
                    GridRow {
                        Text(c.wired ? (c.port.map { "P\($0)" } ?? "") : (c.signal.map { "\($0) dBm" } ?? ""))
                            .monospacedDigit().foregroundStyle(.secondary)
                        Text(c.displayName).lineLimit(1)
                        Text(c.ip).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            .textSelection(.enabled)
        }
    }
}

struct MapNodeBox: View {
    let node: MapNode
    let selected: Bool
    var scale: CGFloat = 1
    var compact = false

    private var dot: Color { !node.online ? .red : node.slowLink ? .orange : .green }
    /// Access points get a purple border so they stand out from switches.
    private var border: Color {
        if selected { return .accentColor }
        if node.kind == .accessPoint { return .purple }
        return Color.secondary.opacity(0.35)
    }
    private var borderWidth: CGFloat { selected ? 2.2 : node.kind == .accessPoint ? 1.8 : 1.2 }

    var body: some View {
        HStack(alignment: .top, spacing: 8 * scale) {
            if !compact {
                Image(systemName: node.symbol)
                    .font(.system(size: 17 * scale))
                    .foregroundStyle(node.kind == .accessPoint ? Color.purple : node.guessed ? Color.secondary : Color.accentColor)
                    .frame(width: 22 * scale)
            }
            VStack(alignment: .leading, spacing: (compact ? 1 : 2) * scale) {
                HStack(spacing: (compact ? 3 : 5) * scale) {
                    if !node.guessed { Circle().fill(dot).frame(width: (compact ? 5 : 7) * scale, height: (compact ? 5 : 7) * scale) }
                    Text(node.name.isEmpty ? node.model : node.name)
                        .font(.system(size: (compact ? 10 : 13) * scale, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                }
                // Compact keeps the name and the IP address only.
                if !compact || node.ip.isEmpty {
                    Text(node.model).font(.system(size: (compact ? 8.5 : 11) * scale)).foregroundStyle(.secondary).lineLimit(1)
                }
                if !node.ip.isEmpty {
                    Text(node.ip).font(.system(size: (compact ? 9 : 10.5) * scale, design: .monospaced)).foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, (compact ? 5 : 10) * scale).padding(.vertical, (compact ? 3 : 7) * scale)
        // Fill the whole box, so a box with fewer lines (an unmanaged switch has no IP) is the same size as the rest.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: (compact ? 7 : 9) * scale)
            .fill(selected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: (compact ? 7 : 9) * scale)
            .stroke(border, style: StrokeStyle(lineWidth: borderWidth * scale, dash: node.guessed ? [5 * scale, 4 * scale] : [])))
        .help(node.name.isEmpty ? node.model : "\(node.name) · \(node.model)")
    }
}

/// Finds the NSScrollView around the map, so zooming can keep the spot under the pointer in place.
final class MapScroller {
    weak var scrollView: NSScrollView? {
        didSet { if scrollView !== oldValue { watch() } }
    }
    var origin: CGPoint { scrollView?.contentView.bounds.origin ?? .zero }
    var visible: CGSize { scrollView?.contentView.bounds.size ?? .zero }
    /// Where to scroll once the map has been redrawn at its new size (set just before a zoom is applied).
    var pending: CGPoint?
    private var observer: NSObjectProtocol?

    /// Scrolls the moment the map changes size, in the same screen update, so a zoom doesn't jump.
    private func watch() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let doc = scrollView?.documentView else { return }
        doc.postsFrameChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: doc, queue: .main) { [weak self] _ in
            self?.applyPending()
        }
    }

    func applyPending() {
        guard let p = pending else { return }
        scroll(to: p)
    }

    /// Scrolls to `target` once the map is redrawn, then again a moment later, because SwiftUI can move the view
    /// itself just after it redraws.
    private var generation = 0
    func settle(at target: CGPoint) {
        generation += 1
        let g = generation
        pending = target
        for delay in [0.03, 0.12, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.generation == g else { return }
                self.scroll(to: target)
                if delay == 0.3 { self.pending = nil }
            }
        }
    }

    /// Where the pointer is, in map coordinates (top-left origin), or nil when it isn't over the map.
    var pointerInMap: CGPoint? {
        guard let doc = scrollView?.documentView, let win = doc.window else { return nil }
        var p = doc.convert(win.mouseLocationOutsideOfEventStream, from: nil)
        if !doc.isFlipped { p.y = doc.bounds.height - p.y }
        return p
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func scroll(to p: CGPoint) {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let maxX = max(0, doc.frame.width - sv.contentView.bounds.width)
        let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
        sv.contentView.scroll(to: CGPoint(x: min(max(0, p.x), maxX), y: min(max(0, p.y), maxY)))
        sv.reflectScrolledClipView(sv.contentView)
    }
}

private struct ScrollFinder: NSViewRepresentable {
    let scroller: MapScroller
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { if let sv = v.enclosingScrollView { scroller.scrollView = sv } }
    }
}

// MARK: - The Map tab

struct NetMapView: View {
    @ObservedObject var model: ScanModel
    @ObservedObject private var unifi = UniFiStore.shared
    @AppStorage("mapShowClients") private var showClients = true
    @AppStorage("mapZoom") private var zoom = 1.0
    @AppStorage("mapCompact") private var compact = false
    /// Width of the side panel (drag the line next to it).
    @AppStorage("mapSideWidth") private var sideWidth = 320.0
    @State private var scroller = MapScroller()
    /// While pinching: the zoom it started at, and the map point under the fingers (map and window coordinates).
    @State private var pinch: (zoom: Double, point: CGPoint, inView: CGPoint)? = nil
    /// While pinching the drawing is only magnified (smooth); it's redrawn at the new zoom when the fingers lift.
    @State private var liveMag: CGFloat = 1
    @State private var liveAnchor: UnitPoint = .center
    private static let minZoom = 0.3, maxZoom = 2.0
    private var style: MapStyle { compact ? .compactStyle : .full }
    @State private var selected: String? = nil
    @State private var showController = false
    @State private var showLog = false
    @State private var showDetailsLog = false
    /// Size of the map area, for Fit (and so a pinch works anywhere in it, not only on the drawing).
    @State private var viewWidth: CGFloat = 800
    @State private var viewHeight: CGFloat = 500

    /// The zoom Fit picks: the whole width in the window (30–100%). Zooming out further is never needed.
    private var fitZoom: Double {
        guard let map = model.netMap else { return Self.minZoom }
        let full = MapLayout(map, showClients: showClients, scale: 1, style: style).size.width + 16
        return min(1, max(Self.minZoom, ((viewWidth - 8) / full * 20).rounded(.down) / 20))
    }
    private var lowest: Double { fitZoom }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let e = model.mapError { errorBar(e) }
            if let map = model.netMap, !map.cabled, !model.mapLoading { noControllerBar }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showController) {
            UniFiControllerSheet(orgID: model.mapOrgID, existing: model.mapController,
                                 suggested: model.detectedController.map { "https://\($0.ip)" } ?? "") {
                Task { await model.loadMap() }
            }
        }
        .onAppear {
            if model.netMap == nil && !model.devices.isEmpty && !model.isScanning { Task { await model.loadMap() } }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            if let map = model.netMap {
                Text("From \(map.source) · \(map.date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("Network map").font(.caption).foregroundStyle(.secondary)
            }
            if model.mapLoading { ProgressView().controlSize(.small) }
            if !model.mapLog.isEmpty && model.mapError == nil {
                Button("Details") { showDetailsLog = true }
                    .buttonStyle(.link).font(.caption)
                    .help("What the map asked the UniFi controller and the switches (SNMP)")
                    .popover(isPresented: $showDetailsLog) { LogPopover(text: model.mapLog) }
            }
            Spacer()
            Button(model.mapController == nil ? "Connect UniFi…" : "UniFi Controller…") { showController = true }
            Button { Task { await model.loadMap() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.mapLoading || model.devices.isEmpty || model.isScanning)
                .help("Read the map again")
            Picker("Tiles", selection: $compact) {
                Text("Full").tag(false)
                Text("Compact").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Full tiles with icons, or narrower compact tiles")
            Toggle("Clients", isOn: $showClients).toggleStyle(.checkbox)
            Button("Fit") { fit() }
                .disabled(model.netMap == nil)
                .help("Zoom out to show the whole map")
            HStack(spacing: 2) {
                Button { zoomAroundCenter(zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out (or pinch on the trackpad); no further than Fit")
                    .accessibilityLabel("Zoom out")
                    .disabled(zoom <= lowest + 0.001)
                Button { zoomAroundCenter(1) } label: { Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 38) }
                    .help("Actual size")
                    .accessibilityLabel("Actual size")
                Button { zoomAroundCenter(zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in (or pinch on the trackpad)")
                    .accessibilityLabel("Zoom in")
            }
            .buttonStyle(.borderless)
            Menu("Export…") {
                Button("Map as PNG…") { export(.png) }
                Button("Map as PDF…") { export(.pdf) }
                Button("Switch Ports as Excel (.xlsx)…") { export(.ports) }
            }
            .fixedSize()
            .disabled(model.netMap == nil)
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
    }

    private func errorBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            if !model.mapLog.isEmpty { Button("Connection Details") { showLog = true } }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Color.orange.opacity(0.12))
        .popover(isPresented: $showLog) { LogPopover(text: model.mapLog) }
    }

    private var noControllerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("No UniFi controller and no switch answered SNMP, so this only lists the Ubiquiti devices the scan found; it can’t tell how they’re cabled. Dashed lines are guesses. Managed switches of any brand are mapped when SNMP is on and the community matches (the organization’s Settings).")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Connect UniFi…") { showController = true }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Color.secondary.opacity(0.08))
    }

    @ViewBuilder private var content: some View {
        if model.devices.isEmpty {
            EmptyHint(text: "Scan a network first. The map is built from the scan and, when you connect one, the UniFi controller.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let map = model.netMap {
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView([.horizontal, .vertical]) {
                        let layout = MapLayout(map, showClients: showClients, scale: zoom, style: style)
                        let canvasSize = CGSize(width: layout.size.width + 16, height: layout.size.height + 16)
                        // At least as big as the window, so pinching over empty space (a small or zoomed-out map) works too.
                        let area = CGSize(width: max(canvasSize.width, viewWidth), height: max(canvasSize.height, viewHeight))
                        MapCanvas(map: map, layout: layout, selected: selected ?? map.root?.id, scale: zoom) { selected = $0 }
                            .padding(8)
                            .frame(width: area.width, height: area.height, alignment: .topLeading)
                            .contentShape(Rectangle())
                            .scaleEffect(liveMag, anchor: liveAnchor)
                            .background(ScrollFinder(scroller: scroller))
                            .gesture(MagnifyGesture()
                                .onChanged { v in
                                    if pinch == nil {
                                        // The pointer is where the fingers are; SwiftUI's own start point is less reliable here.
                                        let at = scroller.pointerInMap ?? v.startLocation
                                        let o = scroller.origin
                                        pinch = (zoom, at, CGPoint(x: at.x - o.x, y: at.y - o.y))
                                        liveAnchor = UnitPoint(x: at.x / max(1, area.width), y: at.y / max(1, area.height))
                                    }
                                    guard let p = pinch else { return }
                                    let z = min(Self.maxZoom, max(lowest, p.zoom * v.magnification))
                                    liveMag = z / p.zoom
                                }
                                .onEnded { _ in
                                    guard let p = pinch else { return }
                                    let z = p.zoom * liveMag
                                    pinch = nil
                                    // The spot stayed under the fingers while magnified; if the fingers also slid, the map
                                    // scrolled, so measure where that spot is in the window now.
                                    let o = scroller.origin
                                    let inView = CGPoint(x: p.point.x - o.x, y: p.point.y - o.y)
                                    var t = Transaction(); t.disablesAnimations = true
                                    withTransaction(t) {
                                        liveMag = 1
                                        zoomAround(z, from: p.zoom, point: p.point, inView: inView)
                                    }
                                })
                    }
                    .onAppear { DispatchQueue.main.async { proxy.scrollTo(MapCanvas.rootAnchor, anchor: .top) } }
                    .onChange(of: map.date) { DispatchQueue.main.async { proxy.scrollTo(MapCanvas.rootAnchor, anchor: .top) } }
                    .onChange(of: compact) { DispatchQueue.main.async { proxy.scrollTo(MapCanvas.rootAnchor, anchor: .top) } }
                }
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { viewWidth = g.size.width; viewHeight = g.size.height }
                        .onChange(of: g.size) { _, s in viewWidth = s.width; viewHeight = s.height }
                })
                // A zoom saved from before (or a wider window) may be below what Fit needs now.
                .onChange(of: lowest) { _, low in if zoom < low { zoom = low } }
                .onAppear { if zoom < lowest { zoom = lowest } }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
                ResizeHandle(width: $sideWidth)
                MapSidePanel(model: model, map: map, node: map.node(selected) ?? map.root)
                    .frame(width: sideWidth)
            }
        } else if model.mapLoading {
            VStack(spacing: 10) { ProgressView(); Text("Reading the network…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 10) {
                Button("Build Map") { Task { await model.loadMap() } }.controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Zoom so the whole width fits (not below 30% or above 100%), then show the top.
    private func fit() {
        guard model.netMap != nil else { return }
        zoom = fitZoom
        DispatchQueue.main.async { scroller.scroll(to: .zero) }
    }

    /// Zoom keeping `point` (map coordinates at zoom `from`) where it is in the window (`inView`).
    private func zoomAround(_ wanted: Double, from: Double, point: CGPoint, inView: CGPoint) {
        let z = min(Self.maxZoom, max(lowest, wanted))
        guard abs(z - zoom) > 0.001 else { liveMag = 1; return }
        let r = z / from, pad: CGFloat = 8
        let moved = CGPoint(x: (point.x - pad) * r + pad, y: (point.y - pad) * r + pad)
        // Scroll as soon as the map is redrawn at the new size, and again just after.
        scroller.settle(at: CGPoint(x: moved.x - inView.x, y: moved.y - inView.y))
        zoom = z
    }

    /// The zoom buttons keep the middle of the window in place.
    private func zoomAroundCenter(_ wanted: Double) {
        let o = scroller.origin, v = scroller.visible
        let mid = CGPoint(x: v.width / 2, y: v.height / 2)
        zoomAround(wanted, from: zoom, point: CGPoint(x: o.x + mid.x, y: o.y + mid.y), inView: mid)
    }

    // MARK: Export

    private enum ExportKind { case png, pdf, ports }

    private func export(_ kind: ExportKind) {
        guard let map = model.netMap else { return }
        let panel = NSSavePanel()
        let stamp = map.date.formatted(.iso8601.year().month().day())
        let base = (model.currentSite?.name ?? "network").map { "/:\\".contains($0) ? "-" : $0 }.map(String.init).joined()
        switch kind {
        case .png: panel.nameFieldStringValue = "\(base) map \(stamp).png"; panel.allowedContentTypes = [.png]
        case .pdf: panel.nameFieldStringValue = "\(base) map \(stamp).pdf"; panel.allowedContentTypes = [.pdf]
        case .ports: panel.nameFieldStringValue = "\(base) switch ports \(stamp).xlsx"
            panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch kind {
        case .png, .pdf:
            let layout = MapLayout(map, showClients: showClients, scale: 1, style: style)
            let view = MapCanvas(map: map, layout: layout)
                .padding(16)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            if kind == .png {
                renderer.scale = 2
                if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    do { try png.write(to: url) } catch { model.errorMessage = "Couldn’t save the file: \(error.localizedDescription)" }
                } else {
                    model.errorMessage = "Couldn’t draw the map as a picture."
                }
            } else {
                renderer.render { size, draw in
                    var box = CGRect(origin: .zero, size: size)
                    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
                    ctx.beginPDFPage(nil); draw(ctx); ctx.endPDFPage(); ctx.closePDF()
                }
            }
        case .ports:
            let t = Self.portsTable(map)
            do {
                try Exporter.xlsx(header: t.header, rows: t.rows, widths: [26, 8, 8, 10, 10, 40], numberColumns: [1],
                                  sheetName: "Switch ports").write(to: url)
            } catch { model.errorMessage = "Couldn’t save the file: \(error.localizedDescription)" }
        }
    }

    /// One row per port of every switch (and gateway with ports).
    static func portsTable(_ map: NetMap) -> (header: [String], rows: [[String]]) {
        var rows: [[String]] = []
        for n in map.nodes where !n.ports.isEmpty {
            for p in n.ports {
                rows.append([n.name, String(p.idx), p.up ? "Up" : "Down", p.mbps > 0 ? MapNode.speed(p.mbps) : "",
                             p.poeWatts.map { String(format: "%.1f W", $0) } ?? "", p.connected])
            }
        }
        return (["Switch", "Port", "Status", "Speed", "PoE", "Connected"], rows)
    }
}

private struct LogPopover: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What ARPradar asked the controller (no key or values)").font(.headline)
            ScrollView {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        }
        .padding(14)
        .frame(width: 560, height: 320)
    }
}

// MARK: - Side panel

private struct MapSidePanel: View {
    @ObservedObject var model: ScanModel
    let map: NetMap
    let node: MapNode?

    var body: some View {
        ScrollView {
            if let n = node {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(n.name.isEmpty ? n.model : n.name).font(.title3).bold().textSelection(.enabled)
                        Text([n.model, n.firmware.isEmpty ? "" : "firmware \(n.firmware)"].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !n.note.isEmpty {
                        Label(n.note, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                        row("IP", n.ip)
                        row("MAC", n.mac)
                        row("Uplink", uplinkText(n))
                        row("Channels", n.channels)
                        row("PoE", n.poeWatts.map { String(format: "%.1f W in use", $0) } ?? "")
                        row("Status", n.guessed ? "Guessed" : n.online ? "Online" : "Offline")
                    }
                    .font(.callout)
                    if !n.ip.isEmpty {
                        HStack {
                            if let d = model.devices.first(where: { $0.ip.description == n.ip }) {
                                Button("Open in Browser") { model.perform(DeviceActions.openWeb, on: d) }
                                Button("Scan Ports…") { model.portScanTarget = d }
                            } else {
                                Button("Open in Browser") { if let u = URL(string: "https://\(n.ip)") { NSWorkspace.shared.open(u) } }
                            }
                        }
                        .controlSize(.small)
                    }
                    if !n.ports.isEmpty { portsTable(n) }
                    if !n.wiredClients.isEmpty { clientList("Wired (\(n.wiredClients.count))", n.wiredClients) }
                    if !n.wifiClients.isEmpty { clientList("Wi-Fi (\(n.wifiClients.count))", n.wifiClients) }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func uplinkText(_ n: MapNode) -> String {
        guard let parent = map.node(n.parent) else { return "" }
        if n.wireless { return "Wireless to \(parent.name)" + (n.signal.map { ", \($0) dBm" } ?? "") }
        var s = parent.name
        if let p = n.parentPort { s += " port \(p)" }
        if let u = n.uplinkPort { s = "Port \(u) → " + s }
        if let l = n.linkMbps, l > 0 { s += " · " + MapNode.speed(l) }
        return s
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(value).textSelection(.enabled)
            }
        }
    }

    private func portsTable(_ n: MapNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Ports").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("Port").foregroundStyle(.secondary)
                    Text("Speed").foregroundStyle(.secondary)
                    Text("Connected").foregroundStyle(.secondary)
                }
                .font(.caption.weight(.semibold))
                ForEach(n.ports) { p in
                    GridRow {
                        Text(String(p.idx)).monospacedDigit().foregroundStyle(p.up ? .primary : .secondary)
                        Text(p.up ? (p.mbps > 0 ? MapNode.speed(p.mbps) : "Up") : "—")
                            .monospacedDigit()
                            .foregroundStyle(p.up && p.mbps > 0 ? LinkSpeed.color(p.mbps) : p.up ? .primary : .secondary)
                        Text(p.connected + (p.poeWatts.map { String(format: "  ⚡︎%.1f W", $0) } ?? ""))
                            .lineLimit(1).foregroundStyle(p.up ? .primary : .secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func clientList(_ title: String, _ list: [MapClient]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ForEach(list) { c in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let p = c.port { Text("P\(p)").monospacedDigit().foregroundStyle(.secondary).frame(width: 30, alignment: .leading) }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.displayName).lineLimit(1)
                        Text([c.ip, c.ssid].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let s = c.signal {
                        Text("\(s) dBm").monospacedDigit().foregroundStyle(s < -75 ? Color.orange : .secondary)
                    }
                }
                .font(.caption)
                .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Connect / edit a controller

struct UniFiControllerSheet: View {
    let orgID: UUID?
    let existing: UniFiController?
    let suggested: String
    var onSave: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var key = ""
    @State private var sites: [UniFiClient.Site] = []
    @State private var site = ""
    @State private var testing = false
    @State private var result: String? = nil
    @State private var failed = false
    @State private var log = ""
    @State private var showLog = false
    @State private var saveProblem: String? = nil

    private var org: Organization? { OrgStore.shared.org(orgID) }
    private var hasSavedKey: Bool { existing.map { UniFiStore.shared.hasKey($0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("UniFi Controller").font(.title2).bold()
            Text("ARPradar reads how your UniFi switches and access points are connected, and which devices are on each port and access point. It only reads; it never changes anything on the controller.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("Address").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    TextField("", text: $address, prompt: Text("https://10.0.0.5"))
                        .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("API key").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        SecureField("", text: $key, prompt: Text(hasSavedKey ? "Saved in the Keychain (leave blank to keep it)" : "Paste the key"))
                            .textFieldStyle(.roundedBorder)
                        Text("In UniFi Network: Settings › Control Plane › Integrations › Create API Key. It’s kept in this Mac’s Keychain, never in ARPradar’s files or exports.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if sites.count > 1 {
                    GridRow {
                        Text("Site").foregroundStyle(.secondary)
                        Picker("", selection: $site) {
                            ForEach(sites) { s in Text(s.name.isEmpty ? s.ref : s.name).tag(s.ref) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                GridRow {
                    Text("Used for").foregroundStyle(.secondary)
                    Text(org.map { "Every scan in \($0.name)" } ?? "Scans of the network it’s on")
                }
            }
            HStack(spacing: 8) {
                Button("Test") { Task { await test() } }.disabled(testing || address.isEmpty || (key.isEmpty && !hasSavedKey))
                if testing { ProgressView().controlSize(.small) }
                if let result {
                    Text(result).font(.callout).foregroundStyle(failed ? Color.orange : Color.green).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !log.isEmpty {
                    Button("Details") { showLog = true }.buttonStyle(.link)
                        .popover(isPresented: $showLog) { LogPopover(text: log) }
                }
            }
            if let e = existing, let fp = e.certFingerprint {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Certificate remembered: \(fp)")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text("ARPradar refuses to connect if the controller’s certificate changes.").font(.caption).foregroundStyle(.secondary)
                        Button("Forget Certificate") { UniFiStore.shared.forgetCertificate(for: e.id); result = "Certificate forgotten; the next connection remembers the new one."; failed = false }
                            .buttonStyle(.link).font(.caption)
                            .help("Only after you replaced the controller or its certificate on purpose")
                    }
                }
            }
            if let problem = saveProblem {
                Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let e = existing {
                    Button("Remove", role: .destructive) { UniFiStore.shared.remove(e.id); dismiss(); onSave() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(address.isEmpty || (key.isEmpty && !hasSavedKey))
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            address = existing?.address ?? suggested
            site = existing?.site ?? ""
        }
    }

    private var keyToUse: String {
        if !key.isEmpty { return key.trimmingCharacters(in: .whitespacesAndNewlines) }
        return existing.flatMap { UniFiStore.shared.key($0) } ?? ""
    }

    private func test() async {
        testing = true; result = nil; failed = false
        defer { testing = false }
        let client = UniFiClient(address: address, key: keyToUse)
        do {
            let found = try await client.sites()
            sites = found.sites
            if !sites.contains(where: { $0.ref == site }) { site = sites.first?.ref ?? "" }
            let r = try await client.fetch(siteRef: site)
            let wired = r.clients.filter(\.wired).count
            result = "Connected · \(r.devices.count) UniFi devices, \(r.clients.count) clients (\(wired) wired) · \(r.api)"
        } catch {
            failed = true
            result = error.localizedDescription
        }
        log = client.log.text
    }

    private func save() {
        var c = existing ?? UniFiController()
        c.address = UniFiClient.normalized(address)
        c.site = site
        c.siteName = sites.first { $0.ref == site }?.name ?? c.siteName
        c.orgID = orgID
        if let problem = UniFiStore.shared.upsert(c, key: key.isEmpty ? nil : key.trimmingCharacters(in: .whitespacesAndNewlines)) {
            saveProblem = problem      // the Keychain refused the key: stay open so it's seen
            return
        }
        dismiss()
        onSave()
    }
}

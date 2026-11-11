import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Opening a particular heatmap from elsewhere (an organization's saved entry).
enum HeatmapWindow {
    @MainActor static func show(_ id: UUID, linking entry: UUID? = nil) {
        UserDefaults.standard.set(id.uuidString, forKey: "heatmap.current")
        // An entry saved before heatmaps were linked gets linked now, so saving again updates it.
        if let entry, OrgStore.shared.item(entry)?.heatmapID == nil { OrgStore.shared.updateItem(entry) { $0.heatmapID = id } }
    }
}

/// Tools › Wi-Fi Heatmap: load a floor plan, click where you're standing to measure, then see the map.
struct HeatmapView: View {
    @ObservedObject private var store = HeatmapStore.shared
    @ObservedObject private var orgs = OrgStore.shared
    @StateObject private var meter = HeatMeter()
    @ObservedObject private var location = LocationPermission.shared
    @AppStorage("heatmap.current") private var currentID = ""
    @AppStorage("heatmap.ping") private var pingEachSpot = false

    enum Tab: String { case walk = "Walk", map = "Map" }
    @State private var tab: Tab = .walk
    @State private var mode: HeatMode = .signal
    @State private var band: HeatBand = .all
    @State private var apBSSID: String? = nil
    @State private var selected: UUID? = nil

    @State private var scaling = false
    @State private var scalePoints: [CGPoint] = []
    @State private var askLength = false
    @State private var lengthText = ""
    @State private var lengthMetres = false

    @State private var naming: NameAsk? = nil
    @State private var nameText = ""
    @State private var confirmDelete = false
    @State private var errorText: String? = nil

    @State private var heat: HeatResult? = nil
    @State private var dragging: (id: UUID, to: CGPoint)? = nil

    enum NameAsk: Identifiable { case new, rename, copy, ap(String); var id: String { "\(self)" } }

    private var survey: HeatSurvey? { store.survey(UUID(uuidString: currentID)) ?? store.surveys.first }
    private var filter: HeatFilter {
        HeatFilter(ssid: survey?.shownNetwork, band: band, bssid: mode == .oneAP ? apBSSID : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let s = survey {
                HStack(spacing: 0) {
                    planArea(s).frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    ScrollView {
                        sidebar(s).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 310)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            } else {
                empty
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task(id: heatKey) { await recompute() }
        .sheet(isPresented: $askLength) { scaleSheet }
        .alert(nameTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $nameText)
            Button("OK") { finishNaming() }
            Button("Cancel", role: .cancel) { naming = nil }
        }
        .confirmationDialog("Move “\(survey?.name ?? "")” to the Trash?", isPresented: $confirmDelete) {
            Button("Move to Trash", role: .destructive) {
                if let s = survey { store.delete(s.id); currentID = store.surveys.first?.id.uuidString ?? "" }
            }
        } message: {
            Text("Its floor plan and every spot measured go with it. You can get it back from the Trash.")
        }
        .alert("Heatmap", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK") { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Menu(survey?.name ?? "No heatmap") {
                // Grouped like saved scans: each organization's heatmaps, then the standalone ones.
                ForEach(orgs.sortedOrgs.filter { o in store.surveys.contains { $0.orgID == o.id } }) { o in
                    Section(o.name) { ForEach(store.surveys.filter { $0.orgID == o.id }) { s in pick(s) } }
                }
                let loose = store.surveys.filter { $0.orgID == nil || orgs.org($0.orgID) == nil }
                if !loose.isEmpty { Section("Standalone") { ForEach(loose) { s in pick(s) } } }
                if !store.surveys.isEmpty { Divider() }
                Button("New Heatmap…") { nameText = store.uniqueName("Floor 1"); naming = .new }
                if let s = survey {
                    Button("Save as New Heatmap…") { nameText = store.uniqueName(s.name + " copy"); naming = .copy }
                        .help("A separate copy with the same floor plan and spots, standalone until you save it to an organization")
                    Button("Rename…") { nameText = s.name; naming = .rename }
                    Button("Move to Trash…") { confirmDelete = true }
                }
            }
            .fixedSize()
            if let s = survey {
                Text(orgs.org(s.orgID).map { "in \($0.name)" } ?? "standalone")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Heatmaps save themselves as you measure. Save to Organization files it with an organization; saving again updates that entry.")
            }
            if survey != nil {
                Button("Floor Plan…") { pickPlan() }
                Button(scaling ? "Cancel Scale" : "Set Scale") {
                    scaling.toggle(); scalePoints = []
                }
                Picker("", selection: $tab) {
                    Text("Walk").tag(Tab.walk)
                    Text("Map").tag(Tab.map)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Spacer()
            if let s = survey {
                if tab == .walk {
                    Button("Undo Last Spot") { store.update(s.id) { _ = $0.spots.popLast() }; selected = nil }
                        .disabled(s.spots.isEmpty || meter.busy != nil)
                    Button("Done Walking") { tab = .map }.keyboardShortcut(.defaultAction).disabled(s.spots.isEmpty)
                } else {
                    Button("Export PNG…") { exportPNG(s) }.disabled(s.spots.isEmpty)
                    if let o = orgs.org(s.orgID) {
                        // Already filed with an organization: one click brings its entry up to date.
                        Button("Update in \(o.name)") {
                            if let d = Heatmap.draft(s, filter: filter, coverage: heat?.coverage ?? HeatCoverage()) { orgs.save(d, to: o.id) }
                        }
                        .disabled(s.spots.isEmpty)
                        .help("Saves the spots measured since, over the entry already in \(o.name)")
                    }
                    SaveToOrgButton(enabled: !s.spots.isEmpty, auto: false) {
                        Heatmap.draft(s, filter: filter, coverage: heat?.coverage ?? HeatCoverage())
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "map").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Wi-Fi Heatmap").font(.title2.weight(.semibold))
            Text("Load a floor plan, walk the building with this Mac and click where you’re standing. ARPradar measures every network it hears there and colors the map.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            Button("New Heatmap…") { nameText = store.uniqueName("Floor 1"); naming = .new }.keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Plan

    private func fit(_ s: HeatSurvey, in size: CGSize) -> (origin: CGPoint, k: Double) {
        let k = min(size.width / s.planWidth, size.height / s.planHeight)
        return (CGPoint(x: (size.width - s.planWidth * k) / 2, y: (size.height - s.planHeight * k) / 2), k)
    }

    private func planArea(_ s: HeatSurvey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            banner(s)
            GeometryReader { geo in
                let f = fit(s, in: geo.size)
                let view = { (x: Double, y: Double) in CGPoint(x: f.origin.x + x * f.k, y: f.origin.y + y * f.k) }
                ZStack(alignment: .topLeading) {
                    Color.clear
                    planPicture(s)
                        .frame(width: s.planWidth * f.k, height: s.planHeight * f.k)
                        .offset(x: f.origin.x, y: f.origin.y)
                    if tab == .map, let img = heat?.image {
                        Image(decorative: img, scale: 1).resizable().interpolation(.high)
                            .frame(width: s.planWidth * f.k, height: s.planHeight * f.k)
                            .offset(x: f.origin.x, y: f.origin.y)
                            .allowsHitTesting(false)
                        // The plan again on top, multiplied: walls and labels stay dark, open floor takes the color.
                        planPicture(s, labels: false)
                            .frame(width: s.planWidth * f.k, height: s.planHeight * f.k)
                            .offset(x: f.origin.x, y: f.origin.y)
                            .blendMode(.multiply)
                            .allowsHitTesting(false)
                    }
                    if tab == .walk, s.spots.count > 1 {
                        Path { p in
                            p.addLines(s.spots.map { view($0.x, $0.y) })
                        }
                        .stroke(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                        .allowsHitTesting(false)
                    }
                    if tab == .map, s.shownNetwork != nil {
                        ForEach(heat?.aps ?? []) { ap in
                            apMarker(s.apName(ap.bssid, ssid: ap.ssid), highlighted: ap.bssid == apBSSID && mode == .oneAP)
                                .position(view(ap.x, ap.y))
                                .allowsHitTesting(false)
                        }
                    }
                    ForEach(s.spots) { spot in
                        spotDot(spot, s)
                            .position(dragging?.id == spot.id ? dragging!.to : view(spot.x, spot.y))
                            .gesture(tab == .walk ? moveGesture(spot, s, f) : nil)
                            .onTapGesture { selected = spot.id }
                            .contextMenu {
                                Button("Delete Spot") { store.update(s.id) { $0.spots.removeAll { $0.id == spot.id } }; if selected == spot.id { selected = nil } }
                            }
                    }
                    if tab == .map, let weak = heat?.findings.first(where: { $0.spot != nil }), let spot = s.spots.first(where: { $0.id == weak.spot }) {
                        weakLabel(spot).position(x: view(spot.x, spot.y).x, y: view(spot.x, spot.y).y - 26).allowsHitTesting(false)
                    }
                    if scaling, !scalePoints.isEmpty {
                        Path { p in
                            let pts = scalePoints.map { view($0.x, $0.y) }
                            p.move(to: pts[0]); if pts.count > 1 { p.addLine(to: pts[1]) }
                        }
                        .stroke(Color.accentColor, lineWidth: 3)
                        ForEach(Array(scalePoints.enumerated()), id: \.offset) { _, p in
                            Circle().fill(Color.accentColor).frame(width: 10, height: 10).position(view(p.x, p.y))
                        }
                    }
                    if let b = meter.busy {
                        measuringCard(b).position(x: view(b.x, b.y).x, y: max(40, view(b.x, b.y).y - 52))
                        Circle().fill(Color.accentColor).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .position(view(b.x, b.y))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    let plan = CGPoint(x: (p.x - f.origin.x) / f.k, y: (p.y - f.origin.y) / f.k)
                    guard plan.x >= 0, plan.y >= 0, plan.x <= s.planWidth, plan.y <= s.planHeight else { return }
                    tapped(plan, s)
                }
                .coordinateSpace(name: "plan")
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            legend(s)
        }
        .padding(16)
    }

    @ViewBuilder private func planPicture(_ s: HeatSurvey, labels: Bool = true) -> some View {
        if let img = store.plan(s) {
            Image(nsImage: img).resizable().interpolation(.high)
        } else {
            Canvas { ctx, size in
                let step = size.width / 32
                var p = Path()
                var x = 0.0; while x <= size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                var y = 0.0; while y <= size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                ctx.stroke(p, with: .color(.secondary.opacity(0.15)), lineWidth: 1)
            }
            .overlay(alignment: .center) {
                if s.spots.isEmpty && labels {
                    Text("No floor plan yet: use Floor Plan… or just measure on the grid.")
                        .foregroundStyle(.secondary).padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                }
            }
        }
    }

    private func spotColor(_ spot: HeatSpot) -> Color {
        let v = Heatmap.value(spot, mode: tab == .map ? mode : .signal, filter: tab == .map ? filter : HeatFilter(ssid: survey?.shownNetwork))
        guard let v else { return .gray }
        let c = Heatmap.color(Heatmap.level(v, mode: tab == .map ? mode : .signal))
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    private func spotDot(_ spot: HeatSpot, _ s: HeatSurvey) -> some View {
        let isSel = selected == spot.id
        return Group {
            if tab == .walk {
                Circle().fill(spotColor(spot)).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(isSel ? Color.accentColor : .white, lineWidth: isSel ? 3 : 2))
            } else {
                Circle().fill(Color.primary.opacity(0.85)).frame(width: isSel ? 10 : 7, height: isSel ? 10 : 7)
                    .overlay(Circle().stroke(isSel ? Color.accentColor : .clear, lineWidth: 2))
            }
        }
        .frame(width: 24, height: 24)
        .contentShape(Circle())
        .help(spotHelp(spot, s))
    }

    private func spotHelp(_ spot: HeatSpot, _ s: HeatSurvey) -> String {
        let mine = spot.readings.filter(HeatFilter(ssid: s.shownNetwork).matches)
        let best = mine.first.map { "\(s.apName($0.bssid, ssid: $0.ssid)) \(dBm($0.rssi))" } ?? "Your network wasn’t heard"
        return "\(best) · \(spot.readings.count) networks heard · \(spot.date.formatted(date: .omitted, time: .shortened))"
    }

    private func moveGesture(_ spot: HeatSpot, _ s: HeatSurvey, _ f: (origin: CGPoint, k: Double)) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("plan"))
            .onChanged { v in dragging = (spot.id, v.location) }
            .onEnded { v in
                let x = min(max((v.location.x - f.origin.x) / f.k, 0), s.planWidth)
                let y = min(max((v.location.y - f.origin.y) / f.k, 0), s.planHeight)
                store.update(s.id) { sv in
                    if let i = sv.spots.firstIndex(where: { $0.id == spot.id }) { sv.spots[i].x = x; sv.spots[i].y = y }
                }
                dragging = nil
            }
    }

    private func apMarker(_ name: String, highlighted: Bool) -> some View {
        VStack(spacing: 2) {
            Text("AP").font(.caption2.weight(.bold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(highlighted ? Color.accentColor : Color(nsColor: .textBackgroundColor)))
                .foregroundStyle(highlighted ? Color.white : Color.primary)
                .overlay(Capsule().stroke(Color.primary, lineWidth: 1.2))
            Text(name).font(.caption2.weight(.semibold))
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color(nsColor: .textBackgroundColor).opacity(0.8)))
        }
    }

    private func weakLabel(_ spot: HeatSpot) -> some View {
        let v = Heatmap.value(spot, mode: .signal, filter: filter) ?? Heatmap.silent
        return Text(v <= Heatmap.silent ? "Not heard" : "Weak: \(dBm(Int(v)))")
            .font(.caption.weight(.semibold)).foregroundStyle(Color(red: 0.64, green: 0.14, blue: 0.11))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(red: 0.78, green: 0.18, blue: 0.15), lineWidth: 1.2))
    }

    private func measuringCard(_ b: HeatMeter.Busy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Measuring… hold still").font(.callout.weight(.semibold))
            Text("Scan \(b.scan) of \(HeatMeter.scans)" + (b.heard > 0 ? " · \(b.heard) networks" : "")).font(.caption).foregroundStyle(.secondary)
            ProgressView(value: Double(b.scan - 1) + 0.5, total: Double(HeatMeter.scans)).frame(width: 160)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)).shadow(radius: 3))
    }

    @ViewBuilder private func banner(_ s: HeatSurvey) -> some View {
        if scaling {
            note(scalePoints.isEmpty ? "Click one end of a wall or doorway you know the length of." : "Now click the other end.", symbol: "ruler")
        } else if tab == .walk {
            if let p = meter.problem {
                note(p, symbol: "exclamationmark.triangle")
            } else {
                note("Click the plan where you’re standing, then hold still for about 5 seconds. Every 10–15 ft is plenty.", symbol: "scope")
            }
        }
        if !location.allowed { LocationNote(location: location) }
    }

    private func note(_ text: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
    }

    private func legend(_ s: HeatSurvey) -> some View {
        HStack(spacing: 22) {
            if tab == .map {
                HStack(spacing: 8) {
                    Text(mode == .signal || mode == .oneAP ? "SIGNAL" : mode.rawValue.uppercased())
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    VStack(spacing: 2) {
                        LinearGradient(stops: stride(from: 0.0, through: 1.0, by: 0.25).map { l in
                            let c = Heatmap.color(l); return .init(color: Color(red: c.r, green: c.g, blue: c.b), location: l)
                        }, startPoint: .leading, endPoint: .trailing)
                        .frame(width: 260, height: 9).clipShape(Capsule())
                        HStack {
                            ForEach(Array(mode.legend.enumerated()), id: \.offset) { i, t in
                                Text(t); if i < mode.legend.count - 1 { Spacer() }
                            }
                        }
                        .font(.caption2).foregroundStyle(.secondary).monospacedDigit().frame(width: 260)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    ForEach([("Good", 0.9), ("Fair", 0.4), ("Poor", 0.1)], id: \.0) { t, l in
                        let c = Heatmap.color(l)
                        HStack(spacing: 4) { Circle().fill(Color(red: c.r, green: c.g, blue: c.b)).frame(width: 9, height: 9); Text(t) }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if let sc = s.scale {
                Label("Plan is \(Int((s.planWidth / sc.pixelsPerUnit).rounded())) × \(Int((s.planHeight / sc.pixelsPerUnit).rounded())) \(sc.unit)", systemImage: "ruler")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(s.spots.count) spots measured").font(.caption).foregroundStyle(.secondary)
            if tab == .walk { Text("Drag a spot to move it · right-click to delete").font(.caption).foregroundStyle(.secondary) }
            Spacer()
        }
    }

    private func tapped(_ p: CGPoint, _ s: HeatSurvey) {
        if scaling {
            scalePoints.append(p)
            if scalePoints.count == 2 { lengthText = ""; lengthMetres = s.scale?.metres ?? false; askLength = true }
            return
        }
        guard tab == .walk, meter.busy == nil else { return }
        if !location.allowed && location.undecided { location.ask() }
        let id = s.id
        Task {
            if let spot = await meter.measure(x: p.x, y: p.y, ping: pingEachSpot) {
                store.update(id) { $0.spots.append(spot) }
                selected = spot.id
            }
        }
    }

    private var scaleSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How long is the line you drew?").font(.headline)
            HStack {
                TextField("Length", text: $lengthText).frame(width: 100)
                Picker("", selection: $lengthMetres) { Text("feet").tag(false); Text("metres").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            HStack {
                Spacer()
                Button("Cancel") { askLength = false; scaling = false; scalePoints = [] }.keyboardShortcut(.cancelAction)
                Button("Set Scale") {
                    if let s = survey, scalePoints.count == 2, let len = Double(lengthText.replacingOccurrences(of: ",", with: ".")), len > 0 {
                        let px = hypot(scalePoints[1].x - scalePoints[0].x, scalePoints[1].y - scalePoints[0].y)
                        if px > 2 { store.update(s.id) { $0.scale = HeatScale(pixelsPerUnit: px / len, metres: lengthMetres) } }
                    }
                    askLength = false; scaling = false; scalePoints = []
                }
                .keyboardShortcut(.defaultAction)
                .disabled((Double(lengthText.replacingOccurrences(of: ",", with: ".")) ?? 0) <= 0)
            }
        }
        .padding(20).frame(width: 340)
    }

    // MARK: Sidebar

    @ViewBuilder private func sidebar(_ s: HeatSurvey) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if tab == .walk { walkSidebar(s) } else { mapSidebar(s) }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).tracking(0.6)
    }

    @ViewBuilder private func walkSidebar(_ s: HeatSurvey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            section("Measure with")
            Label("This Mac’s Wi-Fi", systemImage: "laptopcomputer")
            Text("The ARPradar Sensor (Pi) will show up here later, for 6 GHz and for iPhone.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Ping the router at each spot", isOn: $pingEachSpot)
            Text("Each spot takes \(HeatMeter.scans) scans and keeps the average. The Mac’s own Wi-Fi pauses for a moment during each scan.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        spotDetail(s)
        if s.planFile == nil || s.scale == nil {
            VStack(alignment: .leading, spacing: 6) {
                Text("Before you start").font(.callout.weight(.semibold))
                if s.planFile == nil { Text("Floor Plan… loads a picture or PDF of the building.").font(.caption) }
                if s.scale == nil { Text("Set Scale: click both ends of a wall and type its length. Then sizes and distances are in feet.").font(.caption) }
            }
            .foregroundStyle(.secondary)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        }
    }

    @ViewBuilder private func spotDetail(_ s: HeatSurvey) -> some View {
        let spot = s.spots.first { $0.id == selected } ?? s.spots.last
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                section(spot?.id == selected || spot == nil ? "This spot" : "Last spot")
                Spacer()
                if let spot, let i = s.spots.firstIndex(of: spot) {
                    Text("#\(i + 1) · \(spot.date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let spot {
                let mineSSID = s.shownNetwork
                VStack(spacing: 0) {
                    HStack { Text("Network · AP"); Spacer(); Text("Channel").frame(width: 62, alignment: .leading); Text("dBm").frame(width: 36, alignment: .trailing) }
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
                    Divider()
                    ForEach(Array(spot.readings.prefix(12).enumerated()), id: \.offset) { _, r in
                        let mine = mineSSID == nil || r.ssid == mineSSID
                        HStack {
                            Text(mine ? s.apName(r.bssid, ssid: r.ssid) : (r.ssid.isEmpty ? "(hidden)" : r.ssid))
                                .lineLimit(1).foregroundStyle(mine ? Color.primary : Color.secondary)
                            Spacer()
                            Text("\(r.channel) · \(r.band.replacingOccurrences(of: " GHz", with: ""))").frame(width: 62, alignment: .leading).foregroundStyle(.secondary)
                            Text(dBm(r.rssi)).frame(width: 36, alignment: .trailing).monospacedDigit()
                                .fontWeight(mine ? .semibold : .regular)
                                .foregroundStyle(mine ? signalColor(r.rssi) : Color.secondary)
                        }
                        .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    if spot.readings.count > 12 {
                        Text("+ \(spot.readings.count - 12) more").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 4)
                    }
                    if let ms = spot.pingMs {
                        Divider()
                        HStack { Text("Ping to router"); Spacer(); Text(String(format: "%.0f ms", ms)).monospacedDigit() }
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 5)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                Text(mineSSID.map { "\($0) in black, neighbors in grey. Right-click an AP in Map to name it." } ?? "")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Nothing measured yet.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func mapSidebar(_ s: HeatSurvey) -> some View {
        let aps = heat?.aps ?? []
        VStack(alignment: .leading, spacing: 8) {
            section("Show")
            Picker("Map of", selection: $mode) { ForEach(HeatMode.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Network", selection: Binding(get: { s.shownNetwork ?? "" }, set: { v in store.update(s.id) { $0.network = v } })) {
                ForEach(s.networkNames, id: \.self) { Text($0).tag($0) }
                Divider()
                Text("All networks").tag("")
            }
            if mode == .oneAP {
                Picker("Access point", selection: Binding(get: { apBSSID ?? aps.first?.bssid ?? "" }, set: { apBSSID = $0 })) {
                    ForEach(aps) { Text(s.apName($0.bssid, ssid: $0.ssid)).tag($0.bssid) }
                }
            }
            Picker("Band", selection: $band) { ForEach(HeatBand.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
        }
        if mode.isSignal, let c = heat?.coverage, c.measured {
            VStack(alignment: .leading, spacing: 8) {
                section("Coverage")
                GeometryReader { g in
                    HStack(spacing: 0) {
                        Rectangle().fill(swatch(0.95)).frame(width: g.size.width * c.good)
                        Rectangle().fill(swatch(0.5)).frame(width: g.size.width * c.fair)
                        Rectangle().fill(swatch(0.05)).frame(width: g.size.width * c.poor)
                    }
                }
                .frame(height: 9).clipShape(Capsule())
                HStack(alignment: .top) {
                    stat(c.good, "Good, −67 or better"); stat(c.fair, "Fair, to −75"); stat(c.poor, "Poor, below −75")
                }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            section("Access points heard")
            if aps.isEmpty {
                Text(s.spots.isEmpty ? "Nothing measured yet." : "None on this network and band.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(aps.prefix(10).enumerated()), id: \.element.id) { i, ap in
                        Button {
                            mode = .oneAP; apBSSID = ap.bssid
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.apName(ap.bssid, ssid: ap.ssid)).fontWeight(.medium)
                                    Text("ch \(ap.channel) · \(ap.band) · \(ap.widthMHz) MHz").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(dBm(ap.best)).monospacedDigit().fontWeight(.semibold).foregroundStyle(signalColor(ap.best))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(mode == .oneAP && apBSSID == ap.bssid ? Color.accentColor.opacity(0.12) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Name This Access Point…") { nameText = s.apNames[ap.bssid] ?? ""; naming = .ap(ap.bssid) }
                            Button("Copy BSSID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ap.bssid, forType: .string) }
                        }
                        if i < min(aps.count, 10) - 1 { Divider() }
                    }
                    let neighbors = Heatmap.neighborCount(s.spots, filter: filter)
                    if neighbors > 0 {
                        Divider()
                        HStack { Text("Neighbor networks"); Spacer(); Text("\(neighbors)") }
                            .foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 6)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                Text("Click an AP to map it alone. Right-click to give it a name.").font(.caption).foregroundStyle(.secondary)
            }
        }
        if let f = heat?.findings, !f.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                section("Findings")
                ForEach(f, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.level == .good ? "checkmark.circle" : item.level == .info ? "info.circle" : "exclamationmark.circle")
                            .foregroundStyle(item.level == .bad ? Color.red : item.level == .warn ? Color.orange : item.level == .good ? Color.green : Color.secondary)
                        Text(item.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if let first = s.spots.first {
            Text("Measured \(first.date.formatted(date: .abbreviated, time: .omitted)) with this Mac’s Wi-Fi. Measure again after moving or adding an AP and compare.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ v: Double, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(Int((v * 100).rounded()))%").font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func swatch(_ l: Double) -> Color { let c = Heatmap.color(l); return Color(red: c.r, green: c.g, blue: c.b) }
    private func signalColor(_ rssi: Int) -> Color { rssi >= -67 ? Color(red: 0.07, green: 0.47, blue: 0.23) : rssi >= -75 ? .orange : .red }
    private func dBm(_ v: Int) -> String { String(v).replacingOccurrences(of: "-", with: "−") }

    // MARK: Heat

    struct HeatResult { var image: CGImage?; var coverage: HeatCoverage; var aps: [HeatAP]; var findings: [HeatFinding] }

    private struct HeatKey: Hashable { var survey: HeatSurvey?; var mode: HeatMode; var filter: HeatFilter }
    private var heatKey: HeatKey { HeatKey(survey: survey, mode: mode, filter: filter) }

    private func recompute() async {
        guard let s = survey else { heat = nil; return }
        let mode = mode, filter = filter
        let parts = await offMain { () -> (HeatGrid, HeatCoverage, [HeatAP], [HeatFinding]) in
            let g = Heatmap.grid(s, mode: mode, filter: filter)
            // Findings are about the whole network; the Coverage box follows the map (one AP alone when that's shown).
            let best = mode == .signal ? g : Heatmap.grid(s, mode: .signal, filter: filter)
            let shown = Heatmap.coverage(mode.isSignal ? g : best)
            return (g, shown, Heatmap.accessPoints(s.spots, filter: HeatFilter(ssid: filter.ssid, band: filter.band)),
                    Heatmap.findings(s, filter: filter, coverage: Heatmap.coverage(best)))
        }
        heat = HeatResult(image: HeatImage.make(parts.0, mode: mode), coverage: parts.1, aps: parts.2, findings: parts.3)
    }

    // MARK: Actions

    private var nameTitle: String {
        switch naming {
        case .new: return "New Heatmap"
        case .copy: return "Save as New Heatmap"
        case .rename: return "Rename Heatmap"
        case .ap: return "Name This Access Point"
        case nil: return ""
        }
    }

    private func finishNaming() {
        let name = nameText.trimmingCharacters(in: .whitespaces)
        switch naming {
        case .new:
            let id = store.create(name: name.isEmpty ? "Floor 1" : name)
            currentID = id.uuidString; tab = .walk; selected = nil
        case .copy:
            if let s = survey, let id = store.duplicate(s.id, name: name.isEmpty ? s.name + " copy" : name) {
                currentID = id.uuidString; tab = .walk; selected = nil
            }
        case .rename:
            if let s = survey, !name.isEmpty { store.update(s.id) { $0.name = name } }
        case .ap(let bssid):
            if let s = survey { store.update(s.id) { $0.apNames[bssid] = name.isEmpty ? nil : name } }
        case nil: break
        }
        naming = nil
    }

    @ViewBuilder private func pick(_ s: HeatSurvey) -> some View {
        Button { currentID = s.id.uuidString; selected = nil } label: {
            if s.id == survey?.id { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
        }
    }

    private func pickPlan() {
        guard let s = survey else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.message = "Choose a floor plan: a picture or PDF of the building."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.setPlan(s.id, from: url) } catch { errorText = error.localizedDescription }
    }

    private func exportPNG(_ s: HeatSurvey) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(s.name) heatmap.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let view = HeatExport(survey: s, plan: store.plan(s), heat: heat, mode: mode, filter: filter)
        let r = ImageRenderer(content: view)
        r.scale = 1
        guard let cg = r.cgImage, let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            errorText = "Couldn’t make the picture."; return
        }
        do { try data.write(to: url, options: .atomic) } catch { errorText = error.localizedDescription }
    }
}

// MARK: - Drawing

enum HeatImage {
    /// The grid as a picture (one pixel per cell; shown scaled up and smoothed).
    static func make(_ g: HeatGrid, mode: HeatMode, opacity: Double = 0.62) -> CGImage? {
        var px = [UInt8](repeating: 0, count: g.cols * g.rows * 4)
        for i in 0..<(g.cols * g.rows) {
            guard let v = g.values[i] else { continue }
            let c = Heatmap.color(Heatmap.level(v, mode: mode))
            let a = g.alpha[i] * opacity
            px[i * 4] = UInt8(c.r * a * 255); px[i * 4 + 1] = UInt8(c.g * a * 255); px[i * 4 + 2] = UInt8(c.b * a * 255)
            px[i * 4 + 3] = UInt8(a * 255)
        }
        guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: g.cols, height: g.rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: g.cols * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The picture Export PNG saves: the plan, the map, the spots, AP markers and a legend.
private struct HeatExport: View {
    let survey: HeatSurvey
    let plan: NSImage?
    let heat: HeatmapView.HeatResult?
    let mode: HeatMode
    let filter: HeatFilter

    var body: some View {
        let k = min(1, 2400 / max(survey.planWidth, survey.planHeight))
        let w = survey.planWidth * k, h = survey.planHeight * k
        VStack(alignment: .leading, spacing: 12) {
            Text("\(survey.name) · \(mode.rawValue)" + (filter.ssid.map { " · \($0)" } ?? "") + (filter.band == .all ? "" : " · \(filter.band.rawValue)\(filter.band == .b6 ? "" : " GHz")"))
                .font(.system(size: 20, weight: .semibold))
            ZStack(alignment: .topLeading) {
                if let plan { Image(nsImage: plan).resizable().frame(width: w, height: h) } else { Color.white.frame(width: w, height: h) }
                if let img = heat?.image {
                    Image(decorative: img, scale: 1).resizable().interpolation(.high).frame(width: w, height: h)
                    if let plan { Image(nsImage: plan).resizable().frame(width: w, height: h).blendMode(.multiply) }
                }
                ForEach(survey.spots) { s in Circle().fill(Color.black.opacity(0.85)).frame(width: 8, height: 8).position(x: s.x * k, y: s.y * k) }
                if filter.ssid != nil {
                    ForEach(heat?.aps ?? []) { ap in
                        Text("AP · \(survey.apName(ap.bssid, ssid: ap.ssid))").font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.white)).overlay(Capsule().stroke(Color.black, lineWidth: 1))
                            .position(x: ap.x * k, y: ap.y * k)
                    }
                }
            }
            .frame(width: w, height: h)
            HStack(spacing: 10) {
                LinearGradient(stops: stride(from: 0.0, through: 1.0, by: 0.25).map { l in
                    let c = Heatmap.color(l); return .init(color: Color(red: c.r, green: c.g, blue: c.b), location: l)
                }, startPoint: .leading, endPoint: .trailing).frame(width: 300, height: 10)
                Text(mode.legend.joined(separator: "  ·  ")).font(.system(size: 12))
                Spacer()
                if let c = heat?.coverage, c.measured, mode.isSignal {
                    Text(String(format: "%.0f%% good · %.0f%% fair · %.0f%% poor", c.good * 100, c.fair * 100, c.poor * 100)).font(.system(size: 12))
                }
                Text("\(survey.spots.count) spots · ARPradar").font(.system(size: 12)).foregroundStyle(.gray)
            }
            .frame(width: w)
        }
        .padding(24)
        .foregroundStyle(Color.black)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }
}

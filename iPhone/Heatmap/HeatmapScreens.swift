import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static let arpHeatmap = UTType(exportedAs: HeatmapFile.typeIdentifier, conformingTo: .json)
}

/// One heatmap: the plan, the map filling in as you walk, where you are, and the walk controls.
struct HeatmapScreen: View {
    let id: UUID
    @ObservedObject private var store = PhoneHeatmapStore.shared
    @ObservedObject private var link = SensorLink.shared
    @StateObject private var walk = WalkSession()
    @AppStorage("heatmap.metres") private var metres = false

    @State private var network: String? = nil
    @State private var heat: CGImage? = nil
    @State private var heatSpots = -1
    @State private var tapMode = false
    @State private var scanningRoom = false
    @State private var finishRoom = false
    @State private var pickingMap = false
    @State private var confirmDelete = false
    @State private var problem: String? = nil
    @State private var zoom: CGFloat = 1
    @State private var pinch: CGFloat = 1
    @State private var shareURL: URL? = nil
    @Environment(\.dismiss) private var dismiss

    private var survey: HeatSurvey? { store.survey(id) }
    private var filter: HeatFilter { HeatFilter(ssid: network ?? survey?.shownNetwork) }
    private var source: WalkSession.Source { survey?.geo != nil ? .gps : .room }

    var body: some View {
        Group {
            if let s = survey {
                if s.planFile == nil && s.spots.isEmpty { choosePlan } else { planView(s) }
            } else {
                Text("This heatmap was deleted.").foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .bottom) { if survey?.planFile != nil { controls } }
        .navigationTitle(survey?.name ?? "Heatmap")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear { startTracking() }
        .onDisappear {
            if walk.walking { link.stopSurvey() }
            walk.end()
            link.onWiFi = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: survey?.geo != nil) { _, _ in startTracking() }
        .fullScreenCover(isPresented: $scanningRoom) { roomScanner }
        .sheet(isPresented: $pickingMap) {
            PhoneMapPicker { png, size, metresWide, geo in
                let ppu = Heatmap.pixelsPerUnit(planWidth: size.width, metresWide: metresWide, metres: metres)
                do {
                    try store.setPlan(id, png: png, size: size, scale: HeatScale(pixelsPerUnit: ppu, metres: metres),
                                      geo: geo, align: nil, keepAsBase: true)
                } catch { problem = error.localizedDescription }
            }
        }
        .confirmationDialog("Delete this heatmap?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete(id); dismiss() }
        } message: { Text("Its floor plan and every measurement go with it.") }
        .alert("Heatmap", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }

    // MARK: Plan choice

    private var choosePlan: some View {
        List {
            Section {
                Button { scanningRoom = true } label: {
                    Label { VStack(alignment: .leading, spacing: 2) {
                        Text("Scan the Rooms")
                        Text("Indoors. Walk through with the camera up; the LiDAR draws the walls, doors and windows to scale.")
                            .font(.caption).foregroundStyle(.secondary)
                    } } icon: { Image(systemName: "camera.metering.matrix") }
                }
                .disabled(!RoomScanView.isSupported)
                Button { pickingMap = true } label: {
                    Label { VStack(alignment: .leading, spacing: 2) {
                        Text("Outdoor Map")
                        Text("Outside. A satellite picture of the area; GPS places each measurement.")
                            .font(.caption).foregroundStyle(.secondary)
                    } } icon: { Image(systemName: "map") }
                }
            } header: { Text("Floor plan") } footer: {
                Text("You can also make a plan on the Mac (a picture or PDF), then send it here: Export Heatmap on the Mac, then open the file on this iPhone.")
            }
            Section {
                Picker("Units", selection: $metres) { Text("Feet").tag(false); Text("Metres").tag(true) }
                    .pickerStyle(.segmented)
            }
        }
    }

    private var roomScanner: some View {
        ZStack(alignment: .bottom) {
            RoomScanView(session: walk.arSession, finishRequested: $finishRoom) { room in
                guard let plan = FloorPlanRenderer.render(room) else {
                    problem = "No walls were found. Try again, moving slowly along each wall."
                    scanningRoom = false; finishRoom = false
                    return
                }
                let k = plan.align.pixelsPerMetre
                do {
                    try store.setPlan(id, png: plan.png, size: plan.size,
                                      scale: HeatScale(pixelsPerUnit: metres ? k : k / 3.280839895, metres: metres),
                                      geo: nil, align: plan.align, keepAsBase: false)
                    if let s = store.survey(id) { walk.continueAfterRoomScan(s); walk.saveWorldMap() }
                } catch { problem = error.localizedDescription }
                scanningRoom = false; finishRoom = false
            } onError: { why in
                problem = "The room scan didn’t finish: \(why)"
                scanningRoom = false; finishRoom = false
            }
            .ignoresSafeArea()
            HStack {
                Button("Cancel") { scanningRoom = false; startTracking() }
                    .buttonStyle(.bordered).tint(.white)
                Spacer()
                Button(finishRoom ? "Drawing the plan…" : "Done") { finishRoom = true }
                    .buttonStyle(.borderedProminent).disabled(finishRoom)
            }
            .padding()
        }
    }

    // MARK: Plan and map

    private func planView(_ s: HeatSurvey) -> some View {
        GeometryReader { g in
            let fit = min(g.size.width / max(s.planWidth, 1), g.size.height / max(s.planHeight, 1))
            let k = fit * zoom * pinch
            let size = CGSize(width: s.planWidth * k, height: s.planHeight * k)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    if let img = store.plan(s) {
                        Image(uiImage: img).resizable().frame(width: size.width, height: size.height)
                    } else {
                        Color(white: 0.96).frame(width: size.width, height: size.height)
                    }
                    if let heat {
                        Image(decorative: heat, scale: 1).resizable().interpolation(.high)
                            .frame(width: size.width, height: size.width * CGFloat(heat.height) / CGFloat(max(heat.width, 1)))
                            .frame(width: size.width, height: size.height, alignment: .top).clipped()
                            .allowsHitTesting(false)
                    }
                    Canvas { ctx, _ in
                        for spot in s.spots {
                            let v = Heatmap.value(spot, mode: .signal, filter: filter)
                            let c = v.map { Heatmap.color(Heatmap.level($0, mode: .signal)) } ?? (r: 0.5, g: 0.5, b: 0.5)
                            let r = CGRect(x: spot.x * k - 3, y: spot.y * k - 3, width: 6, height: 6)
                            ctx.fill(Path(ellipseIn: r), with: .color(Color(red: c.r, green: c.g, blue: c.b)))
                            ctx.stroke(Path(ellipseIn: r), with: .color(.white.opacity(0.8)), lineWidth: 1)
                        }
                        if let here = walk.here {
                            let r = CGRect(x: here.x * k - 9, y: here.y * k - 9, width: 18, height: 18)
                            ctx.fill(Path(ellipseIn: r), with: .color(.blue))
                            ctx.stroke(Path(ellipseIn: r), with: .color(.white), lineWidth: 3)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
                }
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
                .onTapGesture { p in
                    guard tapMode else { return }
                    walk.imHere(CGPoint(x: p.x / k, y: p.y / k))
                    tapMode = walk.tapsNeeded > 0
                }
                .frame(minWidth: g.size.width, minHeight: g.size.height)
            }
            .gesture(MagnifyGesture()
                .onChanged { pinch = $0.magnification }
                .onEnded { _ in zoom = min(max(zoom * pinch, 1), 8); pinch = 1 })
        }
        .task(id: "\(s.spots.count / 3)|\(filter.ssid ?? "")|\(s.planWidth)") { await redraw(s) }
    }

    private func redraw(_ s: HeatSurvey) async {
        let f = filter
        let img = await Task.detached(priority: .utility) { () -> CGImage? in
            guard !s.spots.isEmpty else { return nil }
            return HeatImage.make(Heatmap.grid(s, mode: .signal, filter: f, cols: 140), mode: .signal)
        }.value
        heat = img
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !walk.message.isEmpty || tapMode {
                Text(tapMode ? (walk.tapsNeeded > 1 || survey?.align == nil ? "Tap where you’re standing on the plan." : "Tap where you’re standing on the plan.") : walk.message)
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Circle().fill(trackingColor).frame(width: 9, height: 9)
                Text(trackingText).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Text(sensorText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 10) {
                if walk.walking {
                    Button(role: .destructive) { stopWalk() } label: {
                        Label("Stop · \(walk.spotsThisWalk)", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button { startWalk() } label: {
                        Label("Start Walking", systemImage: "figure.walk").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!link.canScan)
                }
                if source == .room {
                    Button { tapMode.toggle() } label: { Label("I’m Here", systemImage: "mappin.and.ellipse") }
                        .buttonStyle(.bordered)
                        .tint(tapMode ? .orange : nil)
                }
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var trackingColor: Color {
        switch walk.tracking {
        case .good: return walk.tapsNeeded > 0 && source == .room ? .orange : .green
        case .limited, .gpsWeak, .starting: return .orange
        case .failed: return .red
        case .off: return .secondary
        }
    }

    private var trackingText: String {
        switch walk.tracking {
        case .off: return "Not tracking"
        case .starting: return source == .gps ? "Finding GPS…" : "Starting room tracking… hold the phone up."
        case .good:
            if source == .room && walk.tapsNeeded > 0 { return "Tap I’m Here, then your spot on the plan, to line up." }
            return source == .gps ? "GPS good" : "Tracking"
        case .limited(let why): return why
        case .gpsWeak(let acc): return "GPS rough (±\(Int(acc)) m)"
        case .failed(let why): return why
        }
    }

    private var sensorText: String {
        if link.surveying { return "Sensor measuring · \(link.surveyReadings)" }
        switch link.phase {
        case .ready: return link.sensorName.isEmpty ? "Sensor ready" : link.sensorName
        case .connecting: return "Connecting…"
        case .ownedByOther: return "Sensor belongs to another app"
        case .bluetoothOff: return "Bluetooth off"
        case .failed: return "Sensor lost"
        case .working: return "Sensor busy"
        case .idle: return "Pick a sensor ↗"
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Section("Sensor") {
                    if link.nearby.isEmpty { Text("Looking for sensors…") }
                    ForEach(link.nearby) { n in
                        Button { link.select(n.id) } label: {
                            if link.selected == n.id { Label(n.name, systemImage: "checkmark") } else { Text(n.name) }
                        }
                    }
                }
            } label: { Image(systemName: "antenna.radiowaves.left.and.right") }
            .accessibilityLabel("Sensor")
            Menu {
                if let s = survey, !s.networkNames.isEmpty {
                    Picker("Network shown", selection: Binding(get: { network ?? s.shownNetwork ?? "" }, set: { network = $0 })) {
                        ForEach(s.networkNames, id: \.self) { Text($0).tag($0) }
                    }
                }
                Button { share() } label: { Label("Send to Mac…", systemImage: "square.and.arrow.up") }
                Menu("Floor Plan") {
                    Button("Scan the Rooms Again") { scanningRoom = true }.disabled(!RoomScanView.isSupported)
                    Button("Outdoor Map…") { pickingMap = true }
                }
                Button("Delete Heatmap…", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }

    // MARK: Actions

    private func startTracking() {
        guard let s = survey, s.planFile != nil, !scanningRoom else { return }
        walk.begin(s, source: source)
        if link.selected == nil, link.nearby.count == 1, let only = link.nearby.first { link.select(only.id) }
    }

    private func startWalk() {
        guard survey != nil else { return }
        walk.startWalk()
        link.onWiFi = { [weak walk] r in walk?.handle(r, joined: SensorLink.shared.ssid) }
        link.startSurvey()
        UIApplication.shared.isIdleTimerDisabled = true
        if source == .room && walk.tapsNeeded > 0 { tapMode = true }
    }

    private func stopWalk() {
        link.stopSurvey()
        walk.stopWalk()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func share() {
        do {
            let url = try store.exportFile(id)
            let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let root = scene.keyWindow?.rootViewController else { return }
            var top = root
            while let p = top.presentedViewController { top = p }
            vc.popoverPresentationController?.sourceView = top.view
            top.present(vc, animated: true)
        } catch { problem = error.localizedDescription }
    }
}

/// Home screen section: the heatmaps on this phone, New Heatmap, and Open a File.
struct HeatmapSection: View {
    @ObservedObject private var store = PhoneHeatmapStore.shared
    @EnvironmentObject private var router: Router
    @State private var naming = false
    @State private var name = ""
    @State private var importing = false
    @State private var problem: String? = nil

    var body: some View {
        Section {
            ForEach(store.surveys) { s in
                NavigationLink(value: Route.heatmap(s.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name)
                        Text("\(s.spots.count) measurements · \(s.created.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button { name = store.uniqueName("Floor 1"); naming = true } label: { Label("New Heatmap", systemImage: "plus") }
            Button { importing = true } label: { Label("Open a Heatmap File…", systemImage: "folder") }
        } header: {
            Text("Wi-Fi heatmaps")
        } footer: {
            Text("Carry the sensor while you walk; this iPhone tracks where you are and the sensor measures the Wi-Fi.")
        }
        .alert("New Heatmap", isPresented: $naming) {
            TextField("Name", text: $name)
            Button("Create") {
                let id = store.create(name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Floor 1" : name)
                router.path.append(.heatmap(id))
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.arpHeatmap, .json]) { result in
            do {
                let url = try result.get()
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                let id = try store.importFile(Data(contentsOf: url))
                router.path.append(.heatmap(id))
            } catch { problem = error.localizedDescription }
        }
        .alert("Heatmap", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") { problem = nil }
        } message: { Text(problem ?? "") }
    }
}

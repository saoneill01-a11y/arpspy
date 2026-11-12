import ARKit
import CoreLocation
import Foundation

/// Walking a heatmap: knows where the phone is (LiDAR room tracking indoors, GPS outdoors) and turns each Wi-Fi
/// reading from the sensor into a spot on the plan, at the place the phone was when the sensor heard it.
@MainActor
final class WalkSession: NSObject, ObservableObject {
    enum Source: String { case room, gps }
    enum Tracking: Equatable {
        case off
        case starting
        case good
        /// Room tracking is unsure (moving too fast, too dark, a blank wall) or still recognising the room.
        case limited(String)
        case gpsWeak(Double)
        case failed(String)
    }

    let arSession = ARSession()
    @Published private(set) var source: Source = .room
    @Published private(set) var walking = false
    @Published private(set) var tracking: Tracking = .off
    /// Where the phone is on the plan right now (plan pixels), when known.
    @Published private(set) var here: CGPoint? = nil
    @Published private(set) var spotsThisWalk = 0
    /// "I'm here" taps still needed before room tracking is lined up with the plan (0 when it is).
    @Published private(set) var tapsNeeded = 0
    @Published var message = ""

    private var surveyID: UUID?
    private let store = PhoneHeatmapStore.shared
    private let location = CLLocationManager()
    /// Recent positions: room metres (x, z) or GPS (lat, lon), newest last, about 10 a second.
    private var history: [(t: Date, a: Double, b: Double)] = []
    private var lastSample = Date.distantPast
    private var gpsAccuracy = 999.0
    /// This walk's spots with where they were in room metres, so a correction ("I'm here") moves all of them.
    private var walkSpots: [(id: UUID, x: Double, z: Double, spot: HeatSpot)] = []
    /// "I'm here" taps: room metres → plan pixels.
    private var anchors: [(world: (x: Double, z: Double), plan: (x: Double, y: Double))] = []

    override init() {
        super.init()
        arSession.delegate = self
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.activityType = .fitness
    }

    static var roomTrackingWorks: Bool { ARWorldTrackingConfiguration.isSupported }

    /// Starts tracking for a heatmap (before walking, so the dot shows where you are).
    func begin(_ survey: HeatSurvey, source: Source) {
        surveyID = survey.id
        self.source = source
        history = []; here = nil; anchors = []
        switch source {
        case .gps:
            arSession.pause()
            tracking = .starting
            if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
            location.startUpdatingLocation()
        case .room:
            location.stopUpdatingLocation()
            arSession.delegate = self
            let config = ARWorldTrackingConfiguration()
            config.worldAlignment = .gravity
            if let d = try? Data(contentsOf: store.worldMapURL(survey.id)),
               let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: d) {
                config.initialWorldMap = map
                tracking = .limited("Look around slowly so the phone recognises the room…")
            } else {
                tracking = .starting
            }
            tapsNeeded = survey.align == nil ? 2 : 0
            arSession.run(config, options: config.initialWorldMap == nil ? [.resetTracking, .removeExistingAnchors] : [])
        }
    }

    /// Carries on in the session the room scan just used (same room coordinates, already lined up).
    func continueAfterRoomScan(_ survey: HeatSurvey) {
        surveyID = survey.id
        source = .room
        arSession.delegate = self
        tapsNeeded = survey.align == nil ? 2 : 0
        tracking = .starting
    }

    func end() {
        if walking { stopWalk() }
        location.stopUpdatingLocation()
        arSession.pause()
        tracking = .off
        here = nil
    }

    func startWalk() {
        walking = true
        spotsThisWalk = 0
        walkSpots = []
        message = ""
    }

    func stopWalk() {
        walking = false
        if let id = surveyID { store.update(id) { _ in } }   // save now
        if source == .room { saveWorldMap() }
    }

    /// Remembers the room so a later walk lines up again (the plan from a room scan, or "I'm here" taps).
    func saveWorldMap() {
        guard let id = surveyID else { return }
        let url = store.worldMapURL(id)
        arSession.getCurrentWorldMap { map, _ in
            guard let map, let d = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true) else { return }
            try? d.write(to: url, options: .atomic)
        }
    }

    // MARK: Readings

    /// A Wi-Fi reading from the sensor: placed where the phone was halfway through the sensor's sweep.
    func handle(_ r: SensorWiFiReading, joined: String) {
        guard walking, let id = surveyID, let survey = store.survey(id), !r.readings.isEmpty else { return }
        guard let pos = position(at: r.middle) else { message = "Waiting for a position…"; return }
        var spot = HeatSpot(x: 0, y: 0, readings: r.readings.sorted { $0.rssi > $1.rssi })
        spot.date = r.middle
        spot.joinedSSID = joined
        switch source {
        case .gps:
            guard gpsAccuracy <= 20, let geo = survey.geo else { message = "GPS is too rough here (±\(Int(gpsAccuracy)) m)."; return }
            let p = geo.pixel(lat: pos.a, lon: pos.b, width: survey.planWidth, height: survey.planHeight)
            spot.x = p.x; spot.y = p.y
            store.update(id, now: false) { $0.spots.append(spot) }
        case .room:
            if let al = survey.align {
                let p = al.pixel(x: pos.a, z: pos.b)
                spot.x = p.x; spot.y = p.y
                store.update(id, now: false) { $0.spots.append(spot) }
            }
            // Not lined up yet: kept, and placed once it is.
            walkSpots.append((spot.id, pos.a, pos.b, spot))
        }
        spotsThisWalk += 1
        message = ""
    }

    /// "I'm here": the phone is at `point` on the plan. One tap moves this walk into place; a second one, a few
    /// metres away, also turns it. Every spot of this walk moves with it.
    func imHere(_ point: CGPoint) {
        guard source == .room, let id = surveyID, let s = store.survey(id), let now = history.last else { return }
        guard let k = pixelsPerMetre(s) else {
            message = "This plan has no scale. Set the scale on the Mac, or scan the rooms with this iPhone."
            return
        }
        anchors.append(((now.a, now.b), (Double(point.x), Double(point.y))))
        // The last few taps: older ones may have drifted.
        let use = Array(anchors.suffix(4))
        let spread = use.count >= 2 ? hypot(use.first!.world.x - use.last!.world.x, use.first!.world.z - use.last!.world.z) : 0
        let fit = HeatAlign.fit(spread >= 2 ? use : [use.last!], pixelsPerMetre: k, keepAngle: s.align?.angle ?? 0)
        tapsNeeded = s.align == nil && spread < 2 ? 1 : 0
        let placed = walkSpots.map { w -> HeatSpot in
            var spot = w.spot
            let p = fit.pixel(x: w.x, z: w.z)
            spot.x = p.x; spot.y = p.y
            return spot
        }
        let ids = Set(walkSpots.map(\.id))
        store.update(id) {
            $0.align = fit
            $0.spots.removeAll { ids.contains($0.id) }
            $0.spots += placed
        }
        here = point
        message = tapsNeeded > 0 ? "Now walk a few metres in a straight line and tap where you are again." : ""
    }

    private func pixelsPerMetre(_ s: HeatSurvey) -> Double? {
        if let al = s.align { return al.pixelsPerMetre }
        guard let sc = s.scale else { return nil }
        return sc.metres ? sc.pixelsPerUnit : sc.pixelsPerUnit * 3.280839895
    }

    /// Where the phone was at `t`, from the recorded track (between the two samples around it).
    private func position(at t: Date) -> (a: Double, b: Double)? {
        guard let last = history.last else { return nil }
        if t >= last.t { return t.timeIntervalSince(last.t) < 2 ? (last.a, last.b) : nil }
        guard let i = history.lastIndex(where: { $0.t <= t }) else { return nil }
        let p = history[i], q = history[min(i + 1, history.count - 1)]
        let span = q.t.timeIntervalSince(p.t)
        let f = span > 0 ? t.timeIntervalSince(p.t) / span : 0
        return (p.a + (q.a - p.a) * f, p.b + (q.b - p.b) * f)
    }

    private func record(_ a: Double, _ b: Double, at t: Date) {
        history.append((t, a, b))
        if history.count > 600 { history.removeFirst(history.count - 600) }
        guard let id = surveyID, let s = store.survey(id) else { return }
        switch source {
        case .room:
            if let al = s.align { let p = al.pixel(x: a, z: b); here = CGPoint(x: p.x, y: p.y) }
        case .gps:
            if let geo = s.geo {
                let p = geo.pixel(lat: a, lon: b, width: s.planWidth, height: s.planHeight)
                here = CGPoint(x: p.x, y: p.y)
            }
        }
    }
}

extension WalkSession: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t = frame.camera.transform.columns.3
        let x = Double(t.x), z = Double(t.z)
        let state = frame.camera.trackingState
        let now = Date()
        MainActor.assumeIsolated {
            switch state {
            case .normal: tracking = .good
            case .notAvailable: tracking = .failed("Room tracking isn’t available.")
            case .limited(let why):
                switch why {
                case .relocalizing: tracking = .limited("Look around slowly so the phone recognises the room…")
                case .excessiveMotion: tracking = .limited("Slow down a little.")
                case .insufficientFeatures: tracking = .limited("Point the camera at something with detail, not a blank wall.")
                case .initializing: tracking = .limited("Starting… move the phone a little.")
                default: tracking = .limited("Tracking is unsure.")
                }
            }
            guard state == .normal, now.timeIntervalSince(lastSample) >= 0.1 else { return }
            lastSample = now
            record(x, z, at: now)
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let why = error.localizedDescription
        MainActor.assumeIsolated { tracking = .failed("Room tracking stopped: \(why)") }
    }
}

extension WalkSession: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let list = locations.map { ($0.timestamp, $0.coordinate.latitude, $0.coordinate.longitude, $0.horizontalAccuracy) }
        MainActor.assumeIsolated {
            for (t, lat, lon, acc) in list where acc >= 0 {
                gpsAccuracy = acc
                tracking = acc <= 20 ? .good : .gpsWeak(acc)
                record(lat, lon, at: t)
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            if status == .denied || status == .restricted {
                tracking = .failed("ARPradar isn’t allowed to use Location. Turn it on in Settings › Privacy & Security › Location Services.")
            }
        }
    }
}

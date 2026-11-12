import MapKit
import SwiftUI
import UIKit

/// Floor Plan › Outdoor Map: zoom Apple Maps to the area you'll walk; that picture becomes the plan, with its scale
/// and its place on Earth, so GPS puts each measurement in the right spot.
struct PhoneMapPicker: View {
    let onUse: (_ png: Data, _ size: CGSize, _ metresWide: Double, _ geo: HeatGeo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var region: MKCoordinateRegion? = nil
    @State private var mapSize: CGSize = .zero
    @State private var query = ""
    @State private var busy = false
    @State private var problem: String? = nil
    @State private var location = CLLocationManager()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Map(position: $position) { UserAnnotation() }
                    .mapStyle(.imagery(elevation: .flat))
                    .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
                    .onMapCameraChange(frequency: .onEnd) { ctx in region = ctx.region }
                    .background(GeometryReader { g in
                        Color.clear.onAppear { mapSize = g.size }.onChange(of: g.size) { _, s in mapSize = s }
                    })
                VStack(alignment: .leading, spacing: 8) {
                    if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
                    Text("Zoom until the area you’ll walk fills the map, with north up. Everything you see becomes the plan.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button {
                        Task { await use() }
                    } label: {
                        Text(busy ? "Taking the picture…" : "Use This Area").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(region == nil || busy || mapSize.width < 50)
                }
                .padding()
            }
            .searchable(text: $query, prompt: "Address or place")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationTitle("Outdoor Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() } }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let region { request.region = region }
        do {
            guard let item = try await MKLocalSearch(request: request).start().mapItems.first else { problem = "Nothing found for “\(q)”."; return }
            problem = nil
            position = .region(MKCoordinateRegion(center: item.placemark.coordinate, latitudinalMeters: 150, longitudinalMeters: 150))
        } catch { problem = "Couldn’t search Apple Maps: \(error.localizedDescription)" }
    }

    private func use() async {
        guard let region else { return }
        busy = true; problem = nil
        defer { busy = false }
        do {
            let r = try await Self.snapshot(region: region, viewSize: mapSize)
            onUse(r.png, r.size, r.metresWide, r.geo)
            dismiss()
        } catch { problem = "Couldn’t get the map picture: \(error.localizedDescription)" }
    }

    /// The area at the size it was on screen (asked for more, Apple Maps stops at its closest zoom and shows more),
    /// with an "Apple Maps" credit; its edges and width are measured from points on the picture.
    static func snapshot(region: MKCoordinateRegion, viewSize: CGSize) async throws -> (png: Data, size: CGSize, metresWide: Double, geo: HeatGeo) {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = CGSize(width: viewSize.width.rounded(), height: viewSize.height.rounded())
        options.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)
        let snap = try await MKMapSnapshotter(options: options).start()
        let img = snap.image
        let pts = img.size   // points
        let c = region.center
        let dLon = region.span.longitudeDelta / 4, dLat = region.span.latitudeDelta / 4
        let a = CLLocationCoordinate2D(latitude: c.latitude - dLat, longitude: c.longitude - dLon)
        let b = CLLocationCoordinate2D(latitude: c.latitude + dLat, longitude: c.longitude + dLon)
        let pa = snap.point(for: a), pb = snap.point(for: b)
        guard abs(pb.x - pa.x) > 1, abs(pb.y - pa.y) > 1 else {
            throw NSError(domain: "ARPradar", code: 2, userInfo: [NSLocalizedDescriptionKey: "The map area is too small."])
        }
        // Longitude is linear across the picture; latitude is linear in Mercator y.
        func merc(_ lat: Double) -> Double { log(tan(.pi / 4 + lat * .pi / 360)) }
        func unmerc(_ m: Double) -> Double { (2 * atan(exp(m)) - .pi / 2) * 180 / .pi }
        let lonPerPt = (b.longitude - a.longitude) / Double(pb.x - pa.x)
        let west = a.longitude - Double(pa.x) * lonPerPt
        let mercPerPt = (merc(b.latitude) - merc(a.latitude)) / Double(pb.y - pa.y)   // negative: north is up
        let north = unmerc(merc(a.latitude) - Double(pa.y) * mercPerPt)
        let south = unmerc(merc(a.latitude) + Double(pts.height - pa.y) * mercPerPt)
        let geo = HeatGeo(north: north, south: south, west: west, east: west + Double(pts.width) * lonPerPt)
        let mid = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude)
        let midE = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude + dLon)
        let metresPerPt = MKMapPoint(mid).distance(to: MKMapPoint(midE)) / Double(abs(snap.point(for: midE).x - snap.point(for: mid).x))

        // Draw at the picture's real pixels, with the credit.
        let format = UIGraphicsImageRendererFormat(); format.scale = img.scale; format.opaque = true
        let out = UIGraphicsImageRenderer(size: pts, format: format).image { _ in
            img.draw(at: .zero)
            let text = NSAttributedString(string: " Apple Maps ", attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: UIColor.white,
                .backgroundColor: UIColor.black.withAlphaComponent(0.45)])
            let s = text.size()
            text.draw(at: CGPoint(x: pts.width - s.width - 6, y: pts.height - s.height - 6))
        }
        guard let png = out.pngData() else { throw NSError(domain: "ARPradar", code: 3) }
        let pixels = CGSize(width: pts.width * img.scale, height: pts.height * img.scale)
        return (png, pixels, Double(pts.width) * metresPerPt, geo)
    }
}

import SwiftUI
import MapKit
import AppKit

/// Floor Plan › From Apple Maps…: find the place, zoom to the area, and use what's on screen as the plan.
/// The scale comes from the map itself, so there's nothing to measure.
struct MapPlanPicker: View {
    /// The picture, how many metres wide it is, and whether to show metres (else feet).
    let onUse: (NSImage, Double, Bool) -> Void

    enum Style: String, CaseIterable, Identifiable {
        case satellite = "Satellite", hybrid = "Satellite with labels", map = "Map"
        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @AppStorage("heatmap.mapStyle") private var style = Style.satellite
    @AppStorage("heatmap.mapMetres") private var metres = false
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var region: MKCoordinateRegion? = nil
    @State private var mapSize: CGSize = .zero
    @State private var query = ""
    @State private var searching = false
    @State private var busy = false
    @State private var problem: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("Search for an address or place", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }.disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || searching)
                if searching { ProgressView().controlSize(.small) }
                Picker("", selection: $style) { ForEach(Style.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Map(position: $position) {
                UserAnnotation()
            }
            .mapStyle(mapStyle)
            .mapControls {
                MapUserLocationButton()
                MapZoomStepper()
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { ctx in region = ctx.region }
            .background(GeometryReader { g in
                Color.clear.onAppear { mapSize = g.size }.onChange(of: g.size) { _, s in mapSize = s }
            })
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            HStack(spacing: 10) {
                Text("Zoom and drag until the area you’ll walk fills the map. Everything you see becomes the plan, with the scale set from the map.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Picker("", selection: $metres) { Text("feet").tag(false); Text("metres").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(busy ? "Taking the picture…" : "Use This Area") { Task { await use() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(region == nil || busy || mapSize.width < 50)
            }
        }
        .padding(16)
        .frame(minWidth: 860, idealWidth: 980, minHeight: 640, idealHeight: 720)
    }

    private var mapStyle: _MapKit_SwiftUI.MapStyle {
        switch style {
        case .satellite: return .imagery(elevation: .flat)
        case .hybrid: return .hybrid(elevation: .flat, pointsOfInterest: .excludingAll)
        case .map: return .standard(elevation: .flat, pointsOfInterest: .excludingAll)
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true; problem = nil
        defer { searching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q
        if let region { request.region = region }
        do {
            let result = try await MKLocalSearch(request: request).start()
            guard let item = result.mapItems.first else { problem = "Nothing found for “\(q)”."; return }
            // About a 150 m (500 ft) square around it: a house and its yard, or a small office building.
            position = .region(MKCoordinateRegion(center: item.placemark.coordinate, latitudinalMeters: 150, longitudinalMeters: 150))
        } catch {
            problem = "Couldn’t search Apple Maps: \(error.localizedDescription)"
        }
    }

    /// A sharp picture of exactly the area on screen, and its real width.
    private func use() async {
        guard let region, mapSize.width > 0 else { return }
        busy = true; problem = nil
        defer { busy = false }
        do {
            let (image, metresWide) = try await Self.snapshot(region: region, viewSize: mapSize, style: style)
            onUse(image, metresWide, metres)
            dismiss()
        } catch {
            problem = "Couldn’t get the map picture: \(error.localizedDescription)"
        }
    }

    /// Renders `region` at the map's on-screen size (twice that in pixels on a Retina screen), so it's the same zoom
    /// you were looking at: asked for a bigger picture of a small area, Apple Maps stops at its closest zoom and shows
    /// more than was on screen. Adds a small Apple Maps credit. The width comes from two points on the picture and the
    /// real distance between them, so it's right even if MapKit adjusts the area.
    @MainActor static func snapshot(region: MKCoordinateRegion, viewSize: CGSize, style: Style) async throws -> (NSImage, Double) {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = NSSize(width: viewSize.width.rounded(), height: viewSize.height.rounded())
        switch style {
        case .satellite: options.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
        case .hybrid:
            let c = MKHybridMapConfiguration(elevationStyle: .flat); c.pointOfInterestFilter = .excludingAll
            options.preferredConfiguration = c
        case .map:
            let c = MKStandardMapConfiguration(elevationStyle: .flat); c.pointOfInterestFilter = .excludingAll
            options.preferredConfiguration = c
        }
        options.appearance = NSAppearance(named: .aqua)
        let snap = try await MKMapSnapshotter(options: options).start()
        // Metres per point across the middle of the picture.
        let c = region.center
        let lon = region.span.longitudeDelta / 4
        let a = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude - lon)
        let b = CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude + lon)
        let pa = snap.point(for: a), pb = snap.point(for: b)
        let points = hypot(pb.x - pa.x, pb.y - pa.y)
        guard points > 1 else { throw NSError(domain: "ARPradar", code: 2, userInfo: [NSLocalizedDescriptionKey: "The map area is too small."]) }
        let metresPerPoint = MKMapPoint(a).distance(to: MKMapPoint(b)) / points
        let image = credited(snap.image)
        return (image, Double(snap.image.size.width) * metresPerPoint)
    }

    /// The picture with "Apple Maps" in the bottom-right corner (Apple's maps need their credit shown).
    static func credited(_ img: NSImage) -> NSImage {
        let out = NSImage(size: img.size)
        out.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: img.size))
        let text = NSAttributedString(string: " Apple Maps ", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.45),
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: img.size.width - size.width - 8, y: 8))
        out.unlockFocus()
        return out
    }
}

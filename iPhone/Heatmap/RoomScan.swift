import ARKit
import RoomPlan
import SwiftUI
import UIKit

/// Floor Plan › Scan the Rooms: Apple's RoomPlan finds walls, doors and windows with the LiDAR as you walk through.
/// It runs in the walk's own room-tracking session, so the plan it draws is already lined up for measuring.
struct RoomScanView: UIViewRepresentable {
    let session: ARSession
    @Binding var finishRequested: Bool
    let onRoom: (CapturedRoom) -> Void
    let onError: (String) -> Void

    static var isSupported: Bool { RoomCaptureSession.isSupported }

    func makeCoordinator() -> Coordinator { Coordinator(onRoom: onRoom, onError: onError) }

    func makeUIView(context: Context) -> RoomCaptureView {
        let v = RoomCaptureView(frame: .zero, arSession: session)
        v.delegate = context.coordinator
        v.captureSession.run(configuration: RoomCaptureSession.Configuration())
        return v
    }

    func updateUIView(_ v: RoomCaptureView, context: Context) {
        if finishRequested, !context.coordinator.stopped {
            context.coordinator.stopped = true
            // Keep room tracking running: the walk carries on in the same room coordinates.
            v.captureSession.stop(pauseARSession: false)
        }
    }

    @objc(ARPRoomScanCoordinator) final class Coordinator: NSObject, RoomCaptureViewDelegate {
        let onRoom: (CapturedRoom) -> Void
        let onError: (String) -> Void
        var stopped = false

        init(onRoom: @escaping (CapturedRoom) -> Void, onError: @escaping (String) -> Void) {
            self.onRoom = onRoom; self.onError = onError
        }
        // RoomCaptureViewDelegate requires NSCoding; nothing here is ever archived.
        required init?(coder: NSCoder) { nil }
        func encode(with coder: NSCoder) {}

        func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }

        func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
            if let error { onError(error.localizedDescription) } else { onRoom(processedResult) }
        }
    }
}

/// A scanned room drawn from above as a floor plan picture, and how room coordinates land on it.
enum FloorPlanRenderer {
    /// Pixels per metre of the picture (a 20 m house → about 1,300 pixels across).
    static let pixelsPerMetre = 60.0
    static let margin = 1.5   // metres around the walls

    struct Plan { var png: Data; var size: CGSize; var align: HeatAlign }

    static func render(_ room: CapturedRoom) -> Plan? {
        typealias Seg = (a: SIMD2<Double>, b: SIMD2<Double>)
        func segment(_ t: simd_float4x4, length: Float) -> Seg {
            let c = SIMD2(Double(t.columns.3.x), Double(t.columns.3.z))
            var d = SIMD2(Double(t.columns.0.x), Double(t.columns.0.z))
            let n = (d * d).sum().squareRoot()
            d = n > 0 ? d / n : SIMD2(1, 0)
            let h = Double(length) / 2
            return (c - d * h, c + d * h)
        }
        let walls = room.walls.map { segment($0.transform, length: $0.dimensions.x) }
        guard !walls.isEmpty else { return nil }
        let doors = room.doors.map { segment($0.transform, length: $0.dimensions.x) }
        let openings = room.openings.map { segment($0.transform, length: $0.dimensions.x) }
        let windows = room.windows.map { segment($0.transform, length: $0.dimensions.x) }
        // Furniture and fixtures as outlines from above.
        let objects: [[SIMD2<Double>]] = room.objects.map { o in
            let t = o.transform
            let c = SIMD2(Double(t.columns.3.x), Double(t.columns.3.z))
            let ax = SIMD2(Double(t.columns.0.x), Double(t.columns.0.z)) * Double(o.dimensions.x) / 2
            let az = SIMD2(Double(t.columns.2.x), Double(t.columns.2.z)) * Double(o.dimensions.z) / 2
            return [c - ax - az, c + ax - az, c + ax + az, c - ax + az]
        }

        let pts = walls.flatMap { [$0.a, $0.b] }
        let minX = pts.map(\.x).min()! - margin, maxX = pts.map(\.x).max()! + margin
        let minZ = pts.map(\.y).min()! - margin, maxZ = pts.map(\.y).max()! + margin
        let k = pixelsPerMetre
        let size = CGSize(width: ((maxX - minX) * k).rounded(), height: ((maxZ - minZ) * k).rounded())
        guard size.width > 10, size.height > 10, size.width < 12000, size.height < 12000 else { return nil }
        func p(_ v: SIMD2<Double>) -> CGPoint { CGPoint(x: (v.x - minX) * k, y: (v.y - minZ) * k) }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            UIColor.white.setFill(); g.fill(CGRect(origin: .zero, size: size))
            g.setLineCap(.butt)
            func stroke(_ segs: [Seg], _ color: UIColor, _ width: Double) {
                g.setStrokeColor(color.cgColor); g.setLineWidth(width)
                for s in segs { g.move(to: p(s.a)); g.addLine(to: p(s.b)) }
                g.strokePath()
            }
            g.setStrokeColor(UIColor(white: 0.75, alpha: 1).cgColor); g.setLineWidth(1.5)
            for o in objects { g.addLines(between: o.map(p)); g.closePath() }
            g.strokePath()
            stroke(walls, UIColor(white: 0.12, alpha: 1), 0.15 * k)
            stroke(doors + openings, .white, 0.17 * k)          // gaps in the walls
            stroke(doors, UIColor(white: 0.55, alpha: 1), 2)     // a thin line where the door is
            stroke(windows, UIColor(red: 0.45, green: 0.7, blue: 0.95, alpha: 1), 0.07 * k)
        }
        guard let png = image.pngData() else { return nil }
        return Plan(png: png, size: size, align: HeatAlign(angle: 0, pixelsPerMetre: k, tx: -minX * k, ty: -minZ * k))
    }
}

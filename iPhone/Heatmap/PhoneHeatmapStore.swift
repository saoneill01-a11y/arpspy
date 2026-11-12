import Foundation
import UIKit

/// Heatmaps kept on the iPhone: Application Support/Heatmaps/<id>/heatmap.json + plan.png (+ base.png), the same
/// layout and JSON as the Mac, so .arpheatmap files move both ways. worldmap.arexperience (the room tracking's memory,
/// so a later walk lines up again) stays on the phone.
@MainActor
final class PhoneHeatmapStore: ObservableObject {
    static let shared = PhoneHeatmapStore()

    @Published private(set) var surveys: [HeatSurvey] = []
    private var plans: [UUID: UIImage] = [:]
    private var saveTasks: [UUID: Task<Void, Never>] = [:]
    let folder: URL

    init(folder: URL? = nil) {
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heatmaps", isDirectory: true)
        load()
    }

    func dir(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString, isDirectory: true) }
    func worldMapURL(_ id: UUID) -> URL { dir(id).appendingPathComponent("worldmap.arexperience") }

    func load() {
        let subs = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        surveys = subs.compactMap { d in
            (try? Data(contentsOf: d.appendingPathComponent("heatmap.json"))).flatMap { try? dec.decode(HeatSurvey.self, from: $0) }
        }
        .sorted { $0.created > $1.created }
    }

    func survey(_ id: UUID?) -> HeatSurvey? { surveys.first { $0.id == id } }

    @discardableResult
    func create(name: String) -> UUID {
        let s = HeatSurvey(name: uniqueName(name))
        surveys.insert(s, at: 0)
        write(s)
        return s.id
    }

    func uniqueName(_ base: String) -> String {
        let names = Set(surveys.map(\.name))
        guard names.contains(base) else { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Changes a heatmap. `now: false` (spots arriving every second while walking) saves a few seconds later.
    func update(_ id: UUID, now: Bool = true, _ change: (inout HeatSurvey) -> Void) {
        guard let i = surveys.firstIndex(where: { $0.id == id }) else { return }
        change(&surveys[i])
        if now { saveTasks[id]?.cancel(); saveTasks[id] = nil; write(surveys[i]); return }
        guard saveTasks[id] == nil else { return }
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.saveTasks[id] = nil
            if let s = self.survey(id) { self.write(s) }
        }
    }

    func delete(_ id: UUID) {
        saveTasks[id]?.cancel(); saveTasks[id] = nil
        surveys.removeAll { $0.id == id }
        plans[id] = nil
        try? FileManager.default.removeItem(at: dir(id))
    }

    private func write(_ s: HeatSurvey) {
        try? FileManager.default.createDirectory(at: dir(s.id), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        if let d = try? enc.encode(s) {
            try? d.write(to: dir(s.id).appendingPathComponent("heatmap.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    // MARK: Plan

    func plan(_ s: HeatSurvey) -> UIImage? {
        guard let file = s.planFile else { return nil }
        if let p = plans[s.id] { return p }
        let img = UIImage(contentsOfFile: dir(s.id).appendingPathComponent(file).path)
        plans[s.id] = img
        return img
    }

    /// A new floor plan picture (PNG) with what goes with it. Spots measured on an earlier plan are cleared, since
    /// they wouldn't line up with the new one.
    func setPlan(_ id: UUID, png: Data, size: CGSize, scale: HeatScale?, geo: HeatGeo?, align: HeatAlign?, keepAsBase: Bool) throws {
        try FileManager.default.createDirectory(at: dir(id), withIntermediateDirectories: true)
        try png.write(to: dir(id).appendingPathComponent("plan.png"), options: .atomic)
        if keepAsBase { try png.write(to: dir(id).appendingPathComponent("base.png"), options: .atomic) }
        plans[id] = nil
        update(id) {
            $0.planFile = "plan.png"; $0.planWidth = size.width; $0.planHeight = size.height
            $0.scale = scale; $0.geo = geo; $0.align = align
            $0.baseFile = keepAsBase ? "base.png" : nil; $0.overlay = nil
            $0.spots = []; $0.apPlaces = [:]
        }
    }

    // MARK: Files

    func exportFile(_ id: UUID) throws -> URL {
        guard let s = survey(id) else { throw HeatmapFile.Problem(text: "That heatmap is gone.") }
        var files: [String: Data] = [:]
        for name in HeatmapFile.pictureNames {
            if let d = try? Data(contentsOf: dir(id).appendingPathComponent(name)) { files[name] = d }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(HeatmapFile.fileName(s))
        try HeatmapFile.encode(s, files: files).write(to: url, options: .atomic)
        return url
    }

    /// Adds a heatmap from an .arpheatmap file; one with the same id is replaced (it's a newer copy of the same heatmap).
    @discardableResult
    func importFile(_ data: Data) throws -> UUID {
        var (s, files) = try HeatmapFile.decode(data)
        s.orgID = nil
        let fm = FileManager.default
        if survey(s.id) != nil {
            for name in HeatmapFile.pictureNames { try? fm.removeItem(at: dir(s.id).appendingPathComponent(name)) }
        }
        try fm.createDirectory(at: dir(s.id), withIntermediateDirectories: true)
        for (name, d) in files { try d.write(to: dir(s.id).appendingPathComponent(name), options: .atomic) }
        plans[s.id] = nil
        surveys.removeAll { $0.id == s.id }
        surveys.insert(s, at: 0)
        write(s)
        return s.id
    }
}

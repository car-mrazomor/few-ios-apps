import Foundation

struct LocalModel: Codable, Identifiable, Hashable {
    var id: String
    var repo: String?
    var name: String
    var quant: String?
    var files: [String]
    var projector: String?
    var sizeBytes: Int64
    var projectorBytes: Int64
    var info: GGUFInfo?
    var addedAt: Date

    var url: URL { Paths.models.appendingPathComponent(files[0]) }
    var projectorURL: URL? { projector.map { Paths.models.appendingPathComponent($0) } }
    var hasVision: Bool { projector != nil }
    var title: String { (name as NSString).lastPathComponent }
}

final class Library: ObservableObject {
    @Published private(set) var models: [LocalModel] = []

    private let file = Paths.root.appendingPathComponent("library.json")

    init() {
        if let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([LocalModel].self, from: data) {
            models = list.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        }
    }

    var totalBytes: Int64 { models.reduce(0) { $0 + $1.sizeBytes + $1.projectorBytes } }

    func model(_ id: String?) -> LocalModel? { models.first { $0.id == id } }

    func contains(_ id: String) -> Bool { models.contains { $0.id == id } }

    func add(_ model: LocalModel) {
        models.removeAll { $0.id == model.id }
        models.insert(model, at: 0)
        save()
    }

    func delete(_ model: LocalModel) {
        let shared = Set(models.filter { $0.id != model.id }.flatMap { $0.files + [$0.projector].compactMap { $0 } })
        for path in model.files + [model.projector].compactMap({ $0 }) where !shared.contains(path) {
            try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(path))
        }
        models.removeAll { $0.id == model.id }
        save()
    }

    func importModel(from source: URL) throws -> LocalModel {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let info = try? GGUFParser.parse(file: source)
        guard let info, info.architecture != nil else { throw HFError.notGGUF }
        let folder = "Imported"
        try FileManager.default.createDirectory(at: Paths.models.appendingPathComponent(folder), withIntermediateDirectories: true)
        let relative = "\(folder)/\(source.lastPathComponent)"
        let dest = Paths.models.appendingPathComponent(relative)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
        let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        let stem = (source.lastPathComponent as NSString).deletingPathExtension
        let model = LocalModel(id: "imported/\(stem)", repo: nil, name: stem, quant: GGUFVariant.quantLabel(stem),
                               files: [relative], projector: nil, sizeBytes: Int64(size), projectorBytes: 0,
                               info: info, addedAt: Date())
        add(model)
        return model
    }

    func attachProjector(to model: LocalModel, from source: URL) throws {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard (try? GGUFParser.parse(file: source))?.architecture == "clip" else { throw HFError.notGGUF }
        let relative = "Imported/\(source.lastPathComponent)"
        let dest = Paths.models.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
        var updated = model
        updated.projector = relative
        updated.projectorBytes = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0)
        add(updated)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(models) { try? data.write(to: file, options: .atomic) }
    }
}

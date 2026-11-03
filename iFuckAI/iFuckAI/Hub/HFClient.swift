import Foundation

struct HFModel: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let downloads: Int?
    let likes: Int?
    let pipelineTag: String?
    let tags: [String]?
    let gated: Gated?
    let lastModified: String?
    let cardData: CardData?

    struct CardData: Decodable, Hashable, Sendable {
        let license: String?
    }

    enum Gated: Decodable, Hashable, Sendable {
        case open
        case gated(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) {
                self = b ? .gated("manual") : .open
            } else {
                self = .gated((try? c.decode(String.self)) ?? "manual")
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, downloads, likes, tags, gated, lastModified, cardData
        case pipelineTag = "pipeline_tag"
    }

    var author: String { id.split(separator: "/").first.map(String.init) ?? "" }
    var name: String { id.split(separator: "/").dropFirst().joined(separator: "/") }
    var isGated: Bool { if case .gated = gated { true } else { false } }
    var isVision: Bool { pipelineTag == "image-text-to-text" || pipelineTag == "any-to-any" }
    var isChat: Bool { pipelineTag.map { !Fit.nonChatPipelines.contains($0) } ?? true }
}

struct HFFile: Decodable, Hashable, Sendable {
    let type: String
    let path: String
    let size: Int64
}

struct GGUFVariant: Identifiable, Hashable, Sendable {
    let id: String
    let files: [HFFile]
    let quant: String
    let isProjector: Bool

    var size: Int64 { files.reduce(0) { $0 + $1.size } }
    var primary: HFFile { files[0] }
    var isSplit: Bool { files.count > 1 }

    static func group(_ files: [HFFile]) -> (models: [GGUFVariant], projectors: [GGUFVariant]) {
        let split = try! NSRegularExpression(pattern: #"^(.*)-(\d{5})-of-(\d{5})\.gguf$"#)
        var groups: [String: [HFFile]] = [:]
        for file in files where file.type == "file" && file.path.lowercased().hasSuffix(".gguf") {
            let ns = file.path as NSString
            var stem = ns.deletingPathExtension
            if let m = split.firstMatch(in: file.path, range: NSRange(location: 0, length: ns.length)) {
                stem = ns.substring(with: m.range(at: 1))
            }
            groups[stem, default: []].append(file)
        }
        let all = groups.map { stem, parts in
            let sorted = parts.sorted { $0.path < $1.path }
            let projector = (stem as NSString).lastPathComponent.lowercased().contains("mmproj")
            return GGUFVariant(id: stem, files: sorted, quant: quantLabel(stem), isProjector: projector)
        }
        let models = all.filter { !$0.isProjector }.sorted { $0.size < $1.size }
        let projectors = all.filter(\.isProjector).sorted { $0.size < $1.size }
        return (models, projectors)
    }

    static func quantLabel(_ stem: String) -> String {
        let name = (stem as NSString).lastPathComponent
        let pattern = #"(?i)(UD-)?(IQ\d_[A-Z]+|Q\d_K_[A-Z]+|Q\d_K|Q\d_\d|TQ\d_\d|MXFP4(_MOE)?|NVFP4|BF16|F16|F32)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = name as NSString
        if let m = regex.matches(in: name, range: NSRange(location: 0, length: ns.length)).last {
            return ns.substring(with: m.range).uppercased()
        }
        return name
    }

    static func preferredProjector(_ projectors: [GGUFVariant]) -> GGUFVariant? {
        func rank(_ v: GGUFVariant) -> Int {
            let q = v.quant.uppercased()
            if q == "F16" { return 0 }
            if q == "BF16" { return 1 }
            if q.hasPrefix("Q8") { return 2 }
            if q == "F32" { return 4 }
            return 3
        }
        return projectors.min { rank($0) < rank($1) || (rank($0) == rank($1) && $0.size < $1.size) }
    }

    var isRecommended: Bool { quant == "Q4_K_M" }
}

enum HFError: LocalizedError {
    case unauthorized
    case notFound
    case http(Int)
    case notGGUF

    var errorDescription: String? {
        switch self {
        case .unauthorized: "This repository is gated. Accept its license on huggingface.co and add an access token in Settings."
        case .notFound: "Not found on Hugging Face."
        case .http(let code): "Hugging Face returned HTTP \(code)."
        case .notGGUF: "The file is not a valid GGUF model."
        }
    }
}

struct HFClient: Sendable {
    var token: String?
    var session: URLSession = .shared

    static let base = URL(string: "https://huggingface.co")!

    func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("iFuckAI/0.1", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: request(url))
        try check(response)
        return data
    }

    private func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw HFError.unauthorized
        case 404: throw HFError.notFound
        default: throw HFError.http(http.statusCode)
        }
    }

    func search(_ query: String, limit: Int = 50) async throws -> [HFModel] {
        var components = URLComponents(url: Self.base.appendingPathComponent("api/models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "full", value: "false"),
        ] + (query.isEmpty ? [] : [URLQueryItem(name: "search", value: query)])
        return try JSONDecoder().decode([HFModel].self, from: try await get(components.url!))
    }

    func model(_ id: String) async throws -> HFModel {
        try JSONDecoder().decode(HFModel.self, from: try await get(Self.base.appendingPathComponent("api/models/\(id)")))
    }

    func files(_ id: String) async throws -> [HFFile] {
        var components = URLComponents(url: Self.base.appendingPathComponent("api/models/\(id)/tree/main"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "recursive", value: "true")]
        return try JSONDecoder().decode([HFFile].self, from: try await get(components.url!))
    }

    func readme(_ id: String) async throws -> String {
        let data = try await get(Self.base.appendingPathComponent(id).appendingPathComponent("raw/main/README.md"))
        return String(decoding: data, as: UTF8.self)
    }

    func downloadURL(repo: String, path: String) -> URL {
        var url = Self.base.appendingPathComponent(repo).appendingPathComponent("resolve/main")
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        return url
    }

    func ggufInfo(repo: String, path: String) async throws -> GGUFInfo {
        var size = 1 << 18
        while size <= 1 << 25 {
            var request = request(downloadURL(repo: repo, path: path))
            request.setValue("bytes=0-\(size - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            try check(response)
            do {
                return try GGUFParser.parse(data)
            } catch GGUFError.needMore {
                if data.count < size { throw HFError.notGGUF }
                size *= 4
            } catch {
                throw HFError.notGGUF
            }
        }
        throw HFError.notGGUF
    }
}

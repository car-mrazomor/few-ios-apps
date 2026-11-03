import Foundation

var llamaLogging = false

struct EngineImage: Sendable {
    let width: Int
    let height: Int
    let rgb: Data
}

struct EngineTurn: Sendable, Equatable {
    enum Role: String, Sendable { case system, user, assistant }

    let id: UUID
    let role: Role
    let text: String
    let images: [EngineImage]

    init(id: UUID = UUID(), role: Role, text: String, images: [EngineImage] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
    }

    static func == (a: EngineTurn, b: EngineTurn) -> Bool {
        a.id == b.id && a.role == b.role && a.text == b.text && a.images.count == b.images.count
    }
}

struct EngineSettings: Sendable, Equatable {
    var temperature: Float = 0.7
    var topK: Int32 = 40
    var topP: Float = 0.95
    var minP: Float = 0.05
    var repeatPenalty: Float = 1.1
    var maxTokens = 2048
}

struct GenerationStats: Sendable, Codable, Hashable {
    var promptTokens = 0
    var promptSeconds = 0.0
    var tokens = 0
    var seconds = 0.0
    var stopped: Bool?

    var tokensPerSecond: Double { seconds > 0 ? Double(tokens) / seconds : 0 }
    var promptTokensPerSecond: Double { promptSeconds > 0 ? Double(promptTokens) / promptSeconds : 0 }
}

enum EngineEvent: Sendable {
    case text(String)
    case notice(String)
    case done(GenerationStats)
}

struct LoadedModelInfo: Sendable {
    let description: String
    let parameters: UInt64
    let sizeBytes: UInt64
    let contextLength: Int
    let trainContextLength: Int
    let vision: Bool
    let template: String?
}

enum EngineError: LocalizedError {
    case notLoaded, modelLoad, contextInit, visionLoad, noVision, tokenize, imageTokenize(Int32), decode(Int32), tooLong, template

    var errorDescription: String? {
        switch self {
        case .notLoaded: "No model is loaded."
        case .modelLoad: "The model could not be loaded. The file may be damaged, or its architecture is not supported."
        case .contextInit: "Not enough memory to create the context. Try a smaller model or a shorter context length."
        case .visionLoad: "The vision projector could not be loaded."
        case .noVision: "This model can't see images. Load a model with vision support."
        case .tokenize: "The prompt could not be tokenized."
        case .imageTokenize(let code): "The image could not be processed (code \(code))."
        case .decode(let code): "Inference failed (code \(code)). The device may be out of memory."
        case .tooLong: "This message is too long for the context window. Increase the context length or shorten the input."
        case .template: "The model's chat template could not be applied."
        }
    }
}

struct UTF8Stream {
    private var pending: [UInt8] = []

    mutating func push(_ bytes: [UInt8]) -> String {
        pending += bytes
        var cut = pending.count
        var i = pending.count - 1
        var back = 0
        while i >= 0 && back < 4 {
            let b = pending[i]
            if b & 0xC0 == 0x80 {
                i -= 1
                back += 1
                continue
            }
            let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            if pending.count - i < need { cut = i }
            break
        }
        let out = String(decoding: pending[0..<cut], as: UTF8.self)
        pending.removeFirst(cut)
        return out
    }

    mutating func flush() -> String {
        defer { pending = [] }
        return String(decoding: pending, as: UTF8.self)
    }
}

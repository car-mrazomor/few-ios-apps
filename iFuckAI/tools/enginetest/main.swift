import CoreGraphics
import Foundation

func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS" : "FAIL", what)
    if !ok { exit(1) }
}

func download(_ url: URL, to dest: URL) async throws {
    if FileManager.default.fileExists(atPath: dest.path) { return }
    let (tmp, response) = try await URLSession.shared.download(from: url)
    check((response as? HTTPURLResponse)?.statusCode == 200, "download \(url.lastPathComponent)")
    try FileManager.default.moveItem(at: tmp, to: dest)
}

func image(red: Bool, size: Int = 256) -> EngineImage {
    var rgb = [UInt8](repeating: 255, count: size * size * 3)
    for y in 0..<size {
        for x in 0..<size {
            let i = (y * size + x) * 3
            let inside = (x - size / 2) * (x - size / 2) + (y - size / 2) * (y - size / 2) < (size / 3) * (size / 3)
            if inside {
                rgb[i] = red ? 230 : 20
                rgb[i + 1] = 20
                rgb[i + 2] = red ? 20 : 230
            }
        }
    }
    return EngineImage(width: size, height: size, rgb: Data(rgb))
}

func collect(_ engine: LlamaEngine, _ conversation: [EngineTurn], reply: UUID = UUID(), settings: EngineSettings) async throws -> (String, GenerationStats) {
    var text = ""
    var stats = GenerationStats()
    for try await event in engine.generate(conversation: conversation, replyID: reply, settings: settings) {
        switch event {
        case .text(let t): text += t
        case .notice(let n): print("  notice:", n)
        case .done(let s): stats = s
        }
    }
    return (text, stats)
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
llamaLogging = ProcessInfo.processInfo.environment["LLAMA_LOG"] != nil
let hf = HFClient()
let repo = "ggml-org/SmolVLM-256M-Instruct-GGUF"

let results = try await hf.search("SmolVLM", limit: 5)
check(!results.isEmpty, "search returned \(results.count) repos, first \(results[0].id)")

let files = try await hf.files(repo)
let groups = GGUFVariant.group(files)
check(groups.models.count == 2 && groups.projectors.count == 2, "grouped \(groups.models.map(\.quant)) + projectors \(groups.projectors.map(\.quant))")
check(GGUFVariant.preferredProjector(groups.projectors)?.quant == "F16", "preferred projector is F16")

let splitFiles = [
    HFFile(type: "file", path: "Q4_K_M/Big-Q4_K_M-00001-of-00002.gguf", size: 10),
    HFFile(type: "file", path: "Q4_K_M/Big-Q4_K_M-00002-of-00002.gguf", size: 20),
    HFFile(type: "file", path: "Big-UD-Q2_K_XL.gguf", size: 5),
]
let splitGroups = GGUFVariant.group(splitFiles).models
check(splitGroups.count == 2 && splitGroups.first(where: \.isSplit)?.size == 30, "split files grouped, quants \(splitGroups.map(\.quant))")

let model = groups.models.first { $0.quant == "Q8_0" }!
let info = try await hf.ggufInfo(repo: repo, path: model.primary.path)
check(info.architecture == "llama" && info.blockCount != nil, "remote header: arch \(info.architecture ?? "-"), layers \(info.blockCount ?? 0), ctx \(info.contextLength ?? 0)")
let fit = Fit.evaluate(weights: model.size, info: info, context: 4096)
check(fit.level == .good, "fit \(fit.level), kv \(Format.bytes(fit.kvBytes)), need \(Format.bytes(fit.needBytes))")
check(Fit.evaluate(weights: 1 << 40, info: info, context: 4096).level == .tooBig, "huge model rejected")
var alien = info
alien.architecture = "not-a-real-arch"
check(Fit.evaluate(weights: 1, info: alien, context: 4096).level == .unsupported, "unknown arch rejected")

for big in ["unsloth/Qwen3.5-4B-GGUF", "unsloth/gemma-4-E4B-it-GGUF", "LiquidAI/LFM2.5-VL-1.6B-GGUF"] {
    let g = GGUFVariant.group(try await hf.files(big))
    let v = g.models.first(where: \.isRecommended) ?? g.models[g.models.count / 2]
    let i = try await hf.ggufInfo(repo: big, path: v.primary.path)
    let p = GGUFVariant.preferredProjector(g.projectors)
    let f = Fit.evaluate(weights: v.size, projector: p?.size ?? 0, info: i, context: 4096)
    print("INFO", big, v.quant, Format.bytes(v.size), "arch", i.architecture ?? "-", "kv", Format.bytes(f.kvBytes), "projector", p?.quant ?? "none", "supported", Architectures.supported.contains(i.architecture ?? ""))
}

let modelURL = dir.appendingPathComponent(model.primary.path)
let projectorFile = GGUFVariant.preferredProjector(groups.projectors)!.primary
let projectorURL = dir.appendingPathComponent(projectorFile.path)
try await download(hf.downloadURL(repo: repo, path: model.primary.path), to: modelURL)
try await download(hf.downloadURL(repo: repo, path: projectorFile.path), to: projectorURL)
let local = try GGUFParser.parse(file: modelURL)
check(local == info, "local header matches remote")

let engine = LlamaEngine()
var settings = EngineSettings()
settings.temperature = 0
settings.maxTokens = 48

let loaded = try await engine.load(model: modelURL.path, projector: nil, contextLength: 2048)
check(!loaded.vision && loaded.contextLength == 2048, "text load: \(loaded.description), \(Format.parameters(loaded.parameters)), template \(loaded.template != nil)")

let system = EngineTurn(role: .system, text: "You are a helpful assistant. Answer briefly.")
let q1 = EngineTurn(role: .user, text: "What is the capital of France?")
let r1 = UUID()
let (a1, s1) = try await collect(engine, [system, q1], reply: r1, settings: settings)
print("  answer:", a1.replacingOccurrences(of: "\n", with: " "))
check(a1.lowercased().contains("paris"), "text answer mentions Paris, \(s1.tokens) tok at \(String(format: "%.0f", s1.tokensPerSecond)) tok/s, prompt \(s1.promptTokens) tok")

let q2 = EngineTurn(role: .user, text: "And of Germany?")
let (a2, s2) = try await collect(engine, [system, q1, EngineTurn(id: r1, role: .assistant, text: a1), q2], settings: settings)
print("  answer:", a2.replacingOccurrences(of: "\n", with: " "))
check(s2.promptTokens < s1.promptTokens + 10, "second turn reused KV cache (prompt \(s2.promptTokens) tok)")
check(a2.lowercased().contains("berlin"), "follow-up answer mentions Berlin")

let (a3, s3) = try await collect(engine, [system, EngineTurn(role: .user, text: "Say hello.")], settings: settings)
check(!a3.isEmpty && s3.promptTokens > s2.promptTokens, "new conversation re-evaluated from scratch (\(s3.promptTokens) tok)")

var stopSettings = settings
stopSettings.maxTokens = 1000
let stream = engine.generate(conversation: [EngineTurn(role: .user, text: "Count from 1 to 500.")], replyID: UUID(), settings: stopSettings)
var received = 0
var stopTokens = 0
for try await event in stream {
    if case .text = event {
        received += 1
        if received == 5 { engine.stop() }
    }
    if case .done(let s) = event { stopTokens = s.tokens }
}
check(stopTokens < 20, "stop() ends generation early (\(stopTokens) tokens)")

let countReply = UUID()
var partial = ""
var stoppedFlag = false
for try await event in engine.generate(conversation: [EngineTurn(role: .user, text: "List the numbers from 1 to 30, separated by commas.")], replyID: countReply, settings: stopSettings) {
    if case .text(let t) = event {
        partial += t
        if partial.count > 12 { engine.stop() }
    }
    if case .done(let s) = event { stoppedFlag = s.stopped == true }
}
check(stoppedFlag, "stats report stopped generation")
var resumed = ""
var resumedStopped = true
for try await event in engine.resume(replyID: countReply, settings: stopSettings) {
    if case .text(let t) = event { resumed += t }
    if case .done(let s) = event { resumedStopped = s.stopped == true }
}
let full = (partial + resumed).replacingOccurrences(of: " ", with: "")
print("  paused:", partial.replacingOccurrences(of: "\n", with: " "), "| resumed:", resumed.prefix(60).replacingOccurrences(of: "\n", with: " "))
check(!resumedStopped && !resumed.isEmpty && full.contains("10"), "resume continues the same reply to the end")

let web = try await WebSearch.search("llama.cpp github", limit: 5)
check(web.count >= 3 && web.contains { $0.url.contains("github.com") }, "web search returns results (\(web.count)), first \(web[0].url)")
let ctx = try await WebSearch.context(for: "who created llama.cpp")
check(ctx.context.contains("[1]") && ctx.context.count > 400, "web context built (\(ctx.context.count) chars, \(ctx.sources.count) sources)")

do {
    _ = try await collect(engine, [EngineTurn(role: .user, text: "What is this?", images: [image(red: true)])], settings: settings)
    check(false, "images without projector should fail")
} catch EngineError.noVision {
    check(true, "images rejected without vision projector")
}

let tooLong = String(repeating: "hello world ", count: 3000)
do {
    _ = try await collect(engine, [EngineTurn(role: .user, text: tooLong)], settings: settings)
    check(false, "overlong prompt should fail")
} catch EngineError.tooLong {
    check(true, "overlong prompt reports tooLong")
}

let vloaded = try await engine.load(model: modelURL.path, projector: projectorURL.path, contextLength: 4096)
check(vloaded.vision, "vision load")
for red in [true, false] {
    let q = EngineTurn(role: .user, text: "What color is the circle in this image? Answer with one word.", images: [image(red: red)])
    let (a, s) = try await collect(engine, [q], settings: settings)
    print("  vision answer:", a.trimmingCharacters(in: .whitespacesAndNewlines))
    check(a.lowercased().contains(red ? "red" : "blue"), "vision sees \(red ? "red" : "blue") circle (\(s.promptTokens) prompt tok)")
}

var utf = UTF8Stream()
let bytes = Array("héllo 🌍".utf8)
var out = ""
for b in bytes { out += utf.push([b]) }
out += utf.flush()
check(out == "héllo 🌍", "UTF-8 stream reassembles split characters")

await engine.unload()
print("ALL PASSED")

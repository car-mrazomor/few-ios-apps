#if !canImport(llama)
import Foundation

final class LlamaEngine: @unchecked Sendable {
    private var loaded = false
    private var vision = false
    private var stopped = false
    private var remaining: [String] = []
    private var lastReply: UUID?

    func load(model path: String, projector: String?, contextLength: Int, gpu: Bool = true) async throws -> LoadedModelInfo {
        try await Task.sleep(for: .milliseconds(400))
        loaded = true
        vision = projector != nil
        return LoadedModelInfo(description: "simulator stub", parameters: 0, sizeBytes: 0, contextLength: contextLength,
                               trainContextLength: contextLength, vision: vision, template: nil)
    }

    func unload() async { loaded = false }
    func reset() {}
    func stop() { stopped = true }

    func generate(conversation: [EngineTurn], replyID: UUID, settings: EngineSettings) -> AsyncThrowingStream<EngineEvent, Error> {
        let last = conversation.last
        let images = last?.images.count ?? 0
        let web = last?.text.contains("Web search results") == true
        var reply = "<think>The simulator has no llama.cpp, so this is a scripted reply. Let me think step by step about what to say here and pretend to reason for a while.</think>"
        reply += "## Simulator reply\n\nThe simulator can't run models. Install on an iPhone to chat. You sent **\(images) image(s)**\(web ? " with web results [1]" : "").\n\n- first point\n- second point\n\n```swift\nprint(\"hello\")\n```\n\nThat's all."
        var pieces: [String] = []
        var i = reply.startIndex
        while i < reply.endIndex {
            let j = reply.index(i, offsetBy: 3, limitedBy: reply.endIndex) ?? reply.endIndex
            pieces.append(String(reply[i..<j]))
            i = j
        }
        remaining = pieces
        lastReply = replyID
        return play(images: images)
    }

    func resume(replyID: UUID, settings: EngineSettings) -> AsyncThrowingStream<EngineEvent, Error> {
        play(images: 0)
    }

    private func play(images: Int) -> AsyncThrowingStream<EngineEvent, Error> {
        stopped = false
        return AsyncThrowingStream { continuation in
            Task {
                guard self.loaded else { return continuation.finish(throwing: EngineError.notLoaded) }
                if images > 0 && !self.vision { return continuation.finish(throwing: EngineError.noVision) }
                var count = 0
                while !self.remaining.isEmpty && !self.stopped {
                    continuation.yield(.text(self.remaining.removeFirst()))
                    count += 1
                    try? await Task.sleep(for: .milliseconds(30))
                }
                var stats = GenerationStats(tokens: count, seconds: Double(count) * 0.03)
                stats.stopped = !self.remaining.isEmpty
                continuation.yield(.done(stats))
                continuation.finish()
            }
        }
    }
}
#endif

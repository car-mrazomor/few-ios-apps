#if canImport(llama)
import Foundation
import llama

private enum ContextOverflow: Error { case full }

final class LlamaEngine: @unchecked Sendable {
    private static let backend: Void = {
        llama_log_set({ _, text, _ in
            if llamaLogging, let text { fputs(String(cString: text), stderr) }
        }, nil)
        mtmd_helper_log_set({ _, text, _ in
            if llamaLogging, let text { fputs(String(cString: text), stderr) }
        }, nil)
        llama_backend_init()
    }()

    private let queue = DispatchQueue(label: "pocketlm.engine", qos: .userInitiated)
    private let flagLock = NSLock()
    private var stopRequested = false

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vision: OpaquePointer?
    private var vocab: OpaquePointer?
    private var template: String?
    private var nCtx: Int32 = 0
    private var history: [EngineTurn] = []
    private var lastFormatted = ""
    private var nPast: llama_pos = 0

    private let batchSize: Int32 = 512
    private let replyReserve: Int32 = 256

    init() {
        _ = Self.backend
    }

    deinit {
        freeSync()
    }

    func load(model path: String, projector: String?, contextLength: Int, gpu: Bool = true) async throws -> LoadedModelInfo {
        try await run { try self.loadSync(path: path, projector: projector, contextLength: contextLength, gpu: gpu) }
    }

    func unload() async {
        _ = try? await run { self.freeSync() }
    }

    func reset() {
        queue.async { self.resetSync() }
    }

    func stop() {
        flagLock.withLock { stopRequested = true }
    }

    func generate(conversation: [EngineTurn], replyID: UUID, settings: EngineSettings) -> AsyncThrowingStream<EngineEvent, Error> {
        stream { emit in try self.generateSync(conversation, replyID: replyID, settings: settings, emit: emit) }
    }

    func resume(replyID: UUID, settings: EngineSettings) -> AsyncThrowingStream<EngineEvent, Error> {
        stream { emit in try self.resumeSync(replyID: replyID, settings: settings, emit: emit) }
    }

    private func stream(_ work: @escaping (@escaping (EngineEvent) -> Void) throws -> Void) -> AsyncThrowingStream<EngineEvent, Error> {
        flagLock.withLock { stopRequested = false }
        return AsyncThrowingStream { continuation in
            queue.async {
                do {
                    try work { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.stop() }
            }
        }
    }

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private var shouldStop: Bool { flagLock.withLock { stopRequested } }

    private func loadSync(path: String, projector: String?, contextLength: Int, gpu: Bool) throws -> LoadedModelInfo {
        freeSync()
        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        let useGPU = false
        #else
        let useGPU = gpu
        #endif
        modelParams.n_gpu_layers = useGPU ? 999 : 0
        guard let model = llama_model_load_from_file(path, modelParams) else { throw EngineError.modelLoad }

        let train = Int(llama_model_n_ctx_train(model))
        let length = max(512, train > 0 ? min(contextLength, train) : contextLength)
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(length)
        contextParams.n_batch = 2048
        contextParams.n_ubatch = UInt32(batchSize)
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw EngineError.contextInit
        }

        var vision: OpaquePointer?
        if let projector {
            var visionParams = mtmd_context_params_default()
            visionParams.use_gpu = useGPU
            visionParams.n_threads = threads
            visionParams.print_timings = false
            guard let ctx = mtmd_init_from_file(projector, model, visionParams) else {
                llama_free(context)
                llama_model_free(model)
                throw EngineError.visionLoad
            }
            vision = ctx
        }

        self.model = model
        self.context = context
        self.vision = vision
        self.vocab = llama_model_get_vocab(model)
        self.nCtx = Int32(llama_n_ctx(context))
        self.template = llama_model_chat_template(model, nil).map { String(cString: $0) }
        resetSync()

        var desc = [CChar](repeating: 0, count: 256)
        llama_model_desc(model, &desc, desc.count)
        return LoadedModelInfo(
            description: String(cString: desc),
            parameters: llama_model_n_params(model),
            sizeBytes: llama_model_size(model),
            contextLength: Int(nCtx),
            trainContextLength: train,
            vision: vision.map { mtmd_support_vision($0) } ?? false,
            template: template
        )
    }

    private func freeSync() {
        if let vision { mtmd_free(vision) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        vision = nil
        context = nil
        model = nil
        vocab = nil
        template = nil
        history = []
        lastFormatted = ""
        nPast = 0
    }

    private func resetSync() {
        if let context { llama_memory_clear(llama_get_memory(context), true) }
        history = []
        lastFormatted = ""
        nPast = 0
    }

    private func generateSync(_ input: [EngineTurn], replyID: UUID, settings: EngineSettings, emit: (EngineEvent) -> Void) throws {
        guard let context, let vocab else { throw EngineError.notLoaded }
        guard let last = input.last else { return }
        if vision == nil && !last.images.isEmpty { throw EngineError.noVision }
        var conversation = vision == nil ? input.map { EngineTurn(id: $0.id, role: $0.role, text: $0.text) } : input

        let promptStart = DispatchTime.now()
        var promptTokens = 0
        do {
            promptTokens = try prefill(conversation)
        } catch ContextOverflow.full {
            conversation = conversation.filter { $0.role == .system } + [conversation[conversation.count - 1]]
            resetSync()
            do {
                promptTokens = try prefill(conversation)
            } catch ContextOverflow.full {
                resetSync()
                throw EngineError.tooLong
            }
            emit(.notice("The context was full, so earlier messages were dropped."))
        }
        var stats = GenerationStats(promptTokens: promptTokens, promptSeconds: seconds(since: promptStart))
        var reply = ""
        if promptTail.hasSuffix("<think>") {
            reply = "<think>\n"
            emit(.text(reply))
        }
        history = conversation + [EngineTurn(id: replyID, role: .assistant, text: reply)]
        try sample(context: context, vocab: vocab, settings: settings, reply: reply, stats: &stats, emit: emit)
    }

    private func resumeSync(replyID: UUID, settings: EngineSettings, emit: (EngineEvent) -> Void) throws {
        guard let context, let vocab else { throw EngineError.notLoaded }
        guard let last = history.last, last.id == replyID, last.role == .assistant else { throw EngineError.notLoaded }
        var stats = GenerationStats()
        try sample(context: context, vocab: vocab, settings: settings, reply: last.text, stats: &stats, emit: emit)
    }

    private func sample(context: OpaquePointer, vocab: OpaquePointer, settings: EngineSettings, reply start: String,
                        stats: inout GenerationStats, emit: (EngineEvent) -> Void) throws {
        let sampler = makeSampler(settings)
        defer { llama_sampler_free(sampler) }
        var decoder = UTF8Stream()
        var reply = start
        var finished = false
        let genStart = DispatchTime.now()
        defer {
            if let last = history.last, last.role == .assistant {
                history[history.count - 1] = EngineTurn(id: last.id, role: .assistant, text: reply)
                lastFormatted = (try? format(history, addAssistant: false)) ?? ""
            }
        }
        while !shouldStop {
            if stats.tokens >= settings.maxTokens {
                finished = true
                break
            }
            if nPast >= nCtx - 1 {
                emit(.notice("The context window is full. Start a new chat to continue."))
                finished = true
                break
            }
            var token = llama_sampler_sample(sampler, context, -1)
            let end = llama_vocab_is_eog(vocab, token)
            if !end {
                let text = decoder.push(piece(token))
                if !text.isEmpty {
                    reply += text
                    emit(.text(text))
                }
            }
            let rc = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
            if rc != 0 { throw EngineError.decode(rc) }
            nPast += 1
            if end {
                finished = true
                break
            }
            stats.tokens += 1
        }
        let tail = decoder.flush()
        if !tail.isEmpty {
            reply += tail
            emit(.text(tail))
        }
        stats.seconds = seconds(since: genStart)
        stats.stopped = !finished
        emit(.done(stats))
    }

    private var promptTail = ""

    private func prefill(_ conversation: [EngineTurn]) throws -> Int {
        let formatted = try format(conversation, addAssistant: true)
        promptTail = String(formatted.suffix(24)).trimmingCharacters(in: .whitespacesAndNewlines)
        let incremental = !history.isEmpty
            && Array(conversation.dropLast()) == history
            && !lastFormatted.isEmpty
            && formatted.hasPrefix(lastFormatted)
        if incremental {
            let delta = String(decoding: Array(formatted.utf8.dropFirst(lastFormatted.utf8.count)), as: UTF8.self)
            return try evaluate(delta, images: conversation.last?.images ?? [])
        }
        resetSync()
        return try evaluate(formatted, images: conversation.flatMap(\.images))
    }

    private func evaluate(_ text: String, images: [EngineImage]) throws -> Int {
        guard let context else { throw EngineError.notLoaded }
        let first = nPast == 0
        if let vision {
            guard let chunks = mtmd_input_chunks_init() else { throw EngineError.tokenize }
            defer { mtmd_input_chunks_free(chunks) }
            let bitmaps: [OpaquePointer?] = images.map { image in
                image.rgb.withUnsafeBytes { mtmd_bitmap_init(UInt32(image.width), UInt32(image.height), $0.bindMemory(to: UInt8.self).baseAddress) }
            }
            defer { bitmaps.forEach { if let b = $0 { mtmd_bitmap_free(b) } } }
            let rc = text.withCString { cText -> Int32 in
                var input = mtmd_input_text(text: cText, text_len: text.utf8.count, add_special: first, parse_special: true)
                return bitmaps.withUnsafeBufferPointer { mtmd_tokenize(vision, chunks, &input, $0.baseAddress, $0.count) }
            }
            if rc != 0 { throw EngineError.imageTokenize(rc) }
            let positions = mtmd_helper_get_n_pos(chunks)
            if nPast + positions > nCtx - replyReserve { throw ContextOverflow.full }
            var newPast: llama_pos = 0
            let result = mtmd_helper_eval_chunks(vision, context, chunks, nPast, 0, 2048, true, &newPast)
            if result != 0 { throw EngineError.decode(result) }
            nPast = newPast
            return Int(mtmd_helper_get_n_tokens(chunks))
        }

        var tokens = try tokenize(text, addSpecial: first)
        if nPast + Int32(tokens.count) > nCtx - replyReserve { throw ContextOverflow.full }
        var offset = 0
        while offset < tokens.count {
            let n = min(Int(batchSize), tokens.count - offset)
            let rc = tokens.withUnsafeMutableBufferPointer { llama_decode(context, llama_batch_get_one($0.baseAddress! + offset, Int32(n))) }
            if rc != 0 { throw EngineError.decode(rc) }
            offset += n
        }
        nPast += Int32(tokens.count)
        return tokens.count
    }

    private func tokenize(_ text: String, addSpecial: Bool) throws -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 8)
        var n = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), addSpecial, true)
        if n < 0 && n != Int32.min {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), addSpecial, true)
        }
        guard n >= 0 else { throw EngineError.tokenize }
        return Array(tokens.prefix(Int(n)))
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(max(0, Int(n))).map { UInt8(bitPattern: $0) }
    }

    private func format(_ turns: [EngineTurn], addAssistant: Bool) throws -> String {
        let marker = vision != nil ? String(cString: mtmd_default_marker()) + "\n" : ""
        let roles = turns.map { strdup($0.role.rawValue) }
        let contents = turns.map { strdup(String(repeating: marker, count: $0.images.count) + $0.text) }
        defer {
            roles.forEach { free($0) }
            contents.forEach { free($0) }
        }
        let messages = zip(roles, contents).map { llama_chat_message(role: $0, content: $1) }
        let totalLength = turns.reduce(0) { $0 + $1.text.utf8.count }

        func apply(_ tmpl: String) -> String? {
            var capacity = 4096 + totalLength * 2
            while true {
                var buffer = [CChar](repeating: 0, count: capacity)
                let n = llama_chat_apply_template(tmpl, messages, messages.count, addAssistant, &buffer, Int32(capacity))
                if n < 0 { return nil }
                if Int(n) <= capacity {
                    return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
                capacity = Int(n) + 1
            }
        }

        if let template, let result = apply(template) { return result }
        if let result = apply("chatml") { return result }
        throw EngineError.template
    }

    private func makeSampler(_ s: EngineSettings) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(s.topK))
        if s.repeatPenalty != 1 {
            llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, s.repeatPenalty, 0, 0))
        }
        if s.temperature <= 0 {
            llama_sampler_chain_add(chain, llama_sampler_init_greedy())
        } else {
            llama_sampler_chain_add(chain, llama_sampler_init_top_p(s.topP, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_min_p(s.minP, 1))
            llama_sampler_chain_add(chain, llama_sampler_init_temp(s.temperature))
            llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        }
        return chain
    }

    private func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
    }
}
#endif

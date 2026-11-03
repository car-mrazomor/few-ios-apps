import Foundation
#if canImport(os)
import os
#endif

struct FitReport: Sendable, Equatable {
    enum Level: Sendable, Equatable {
        case good, tight, tooBig, unsupported, notChat
    }

    let level: Level
    let needBytes: Int64
    let budgetBytes: Int64
    let kvBytes: Int64
    let tokensPerSecond: Double?
    let message: String
}

enum Fit {
    static let nonChatPipelines: Set<String> = [
        "text-to-speech", "automatic-speech-recognition", "feature-extraction", "sentence-similarity",
        "text-to-image", "image-to-image", "text-to-video", "image-text-to-video", "image-to-video",
        "text-to-audio", "audio-to-audio", "object-detection", "image-classification", "text-classification",
        "token-classification", "depth-estimation", "image-segmentation", "zero-shot-classification",
        "audio-classification", "voice-activity-detection", "fill-mask", "text-ranking",
    ]

    static let nonChatArchitectures: Set<String> = [
        "clip", "bert", "modern-bert", "nomic-bert", "nomic-bert-moe", "neo-bert", "jina-bert-v2", "jina-bert-v3",
        "eurobert", "t5encoder", "wavtokenizer-dec", "gemma-embedding", "gemma-embedding2", "llama-embed",
        "qwen3tts", "pockettts",
    ]

    static let overheadBytes: Int64 = 400 << 20

    static var memoryBudget: Int64 {
        let stored = Int64(UserDefaults.standard.integer(forKey: "memoryBudget"))
        return stored > 0 ? stored : defaultBudget
    }

    static var defaultBudget: Int64 {
        Int64(Double(ProcessInfo.processInfo.physicalMemory) * 0.6)
    }

    static func recordMemoryBudget() {
        #if os(iOS)
        let available = Int64(os_proc_available_memory())
        if available > 0 {
            UserDefaults.standard.set(Int(available), forKey: "memoryBudget")
        }
        #endif
    }

    static var bandwidth: Double {
        let stored = UserDefaults.standard.double(forKey: "bandwidth")
        #if os(iOS)
        return stored > 0 ? stored : 25e9
        #else
        return stored > 0 ? stored : 60e9
        #endif
    }

    static func recordSpeed(weights: Int64, tokensPerSecond: Double, tokens: Int) {
        guard tokens >= 16, tokensPerSecond > 0, weights > 0 else { return }
        let measured = Double(weights) * tokensPerSecond
        let next = UserDefaults.standard.double(forKey: "bandwidth") > 0 ? bandwidth * 0.7 + measured * 0.3 : measured
        UserDefaults.standard.set(next, forKey: "bandwidth")
    }

    static func evaluate(weights: Int64, projector: Int64 = 0, info: GGUFInfo?, context: Int, pipeline: String? = nil) -> FitReport {
        let budget = memoryBudget
        if let arch = info?.architecture {
            if !Architectures.supported.contains(arch) {
                return FitReport(level: .unsupported, needBytes: 0, budgetBytes: budget, kvBytes: 0, tokensPerSecond: nil,
                                 message: "Architecture “\(arch)” is not supported by llama.cpp \(Architectures.llamaBuild).")
            }
            if nonChatArchitectures.contains(arch) {
                return FitReport(level: .notChat, needBytes: 0, budgetBytes: budget, kvBytes: 0, tokensPerSecond: nil,
                                 message: "“\(arch)” is not a chat model.")
            }
        }
        if let pipeline, nonChatPipelines.contains(pipeline) {
            return FitReport(level: .notChat, needBytes: 0, budgetBytes: budget, kvBytes: 0, tokensPerSecond: nil,
                             message: "This is a \(pipeline.replacingOccurrences(of: "-", with: " ")) model, not a chat model.")
        }
        let effectiveContext = min(context, info?.contextLength ?? context)
        let kv = info?.kvCacheBytes(context: effectiveContext) ?? Int64(Double(weights) * 0.15)
        let need = weights + projector + kv + overheadBytes
        let speed = bandwidth / Double(max(weights, 1))
        let level: FitReport.Level
        let message: String
        if Double(need) <= Double(budget) * 0.75 {
            level = .good
            message = "Runs well on this device."
        } else if need <= budget {
            level = .tight
            message = "Fits, but close to the memory limit. Close other apps first."
        } else {
            level = .tooBig
            message = "Needs about \(Format.bytes(need)) but this device allows about \(Format.bytes(budget))."
        }
        return FitReport(level: level, needBytes: need, budgetBytes: budget, kvBytes: kv, tokensPerSecond: speed, message: message)
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    static func count(_ value: Int) -> String {
        switch value {
        case 1_000_000...: String(format: "%.1fM", Double(value) / 1e6)
        case 1_000...: String(format: "%.1fk", Double(value) / 1e3)
        default: "\(value)"
        }
    }

    static func parameters(_ value: UInt64) -> String {
        value >= 1_000_000_000 ? String(format: "%.1fB", Double(value) / 1e9) : String(format: "%.0fM", Double(value) / 1e6)
    }
}

import Foundation

struct GGUFInfo: Codable, Sendable, Equatable, Hashable {
    var architecture: String?
    var name: String?
    var blockCount: Int?
    var contextLength: Int?
    var embeddingLength: Int?
    var headCount: Int?
    var headCountKV: [Int]?
    var keyLength: Int?
    var valueLength: Int?
    var slidingWindow: Int?

    func kvCacheBytes(context: Int) -> Int64? {
        guard let blocks = blockCount, blocks > 0, let embedding = embeddingLength, let heads = headCount, heads > 0 else { return nil }
        let k = keyLength ?? embedding / heads
        let v = valueLength ?? embedding / heads
        let perLayer: [Int]
        if let kv = headCountKV, kv.count == blocks {
            perLayer = kv
        } else {
            perLayer = Array(repeating: headCountKV?.first ?? heads, count: blocks)
        }
        let headsTotal = perLayer.reduce(0, +)
        return Int64(context) * Int64(headsTotal) * Int64(k + v) * 2
    }
}

enum GGUFError: Error {
    case needMore
    case invalid
}

enum GGUFParser {
    static func parse(_ data: Data) throws -> GGUFInfo {
        var r = Reader(data: data)
        guard try r.bytes(4) == Array("GGUF".utf8) else { throw GGUFError.invalid }
        let version = try r.u32()
        guard version >= 2 else { throw GGUFError.invalid }
        _ = try r.u64()
        let kvCount = try r.u64()

        var strings: [String: String] = [:]
        var ints: [String: [Int]] = [:]
        for _ in 0..<kvCount {
            let key = try r.string()
            let type = try r.u32()
            if key.hasPrefix("tokenizer.") && strings["general.architecture"] != nil { break }
            switch try r.value(type) {
            case .string(let s): strings[key] = s
            case .ints(let v): ints[key] = v
            case .other: break
            }
        }

        var info = GGUFInfo()
        info.architecture = strings["general.architecture"]
        info.name = strings["general.name"]
        guard let arch = info.architecture else { return info }
        func int(_ suffix: String) -> Int? { ints["\(arch).\(suffix)"].flatMap { $0.max() } }
        info.blockCount = int("block_count")
        info.contextLength = int("context_length")
        info.embeddingLength = int("embedding_length")
        info.headCount = int("attention.head_count")
        info.headCountKV = ints["\(arch).attention.head_count_kv"]
        info.keyLength = int("attention.key_length")
        info.valueLength = int("attention.value_length")
        info.slidingWindow = int("attention.sliding_window")
        return info
    }

    static func parse(file url: URL) throws -> GGUFInfo {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        for size in [1 << 18, 1 << 21, 1 << 23, 1 << 25] {
            try handle.seek(toOffset: 0)
            let data = try handle.read(upToCount: size) ?? Data()
            do {
                return try parse(data)
            } catch GGUFError.needMore {
                if data.count < size { throw GGUFError.invalid }
            }
        }
        throw GGUFError.invalid
    }

    private enum Value {
        case string(String)
        case ints([Int])
        case other
    }

    private struct Reader {
        let data: Data
        var pos = 0

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard n >= 0, pos + n <= data.count else { throw GGUFError.needMore }
            defer { pos += n }
            return Array(data[data.startIndex + pos ..< data.startIndex + pos + n])
        }

        mutating func skip(_ n: Int) throws {
            guard n >= 0, pos + n <= data.count else { throw GGUFError.needMore }
            pos += n
        }

        mutating func uint(_ n: Int) throws -> UInt64 {
            let b = try bytes(n)
            var v: UInt64 = 0
            for (i, byte) in b.enumerated() { v |= UInt64(byte) << (8 * UInt64(i)) }
            return v
        }

        mutating func u32() throws -> UInt32 { UInt32(try uint(4)) }
        mutating func u64() throws -> UInt64 { try uint(8) }

        mutating func string() throws -> String {
            let n = try u64()
            guard n < 1 << 24 else { throw GGUFError.invalid }
            return String(decoding: try bytes(Int(n)), as: UTF8.self)
        }

        static func size(_ type: UInt32) -> Int? {
            switch type {
            case 0, 1, 7: 1
            case 2, 3: 2
            case 4, 5, 6: 4
            case 10, 11, 12: 8
            default: nil
            }
        }

        mutating func integer(_ type: UInt32) throws -> Int? {
            switch type {
            case 0: Int(try uint(1))
            case 1: Int(Int8(truncatingIfNeeded: try uint(1)))
            case 2: Int(try uint(2))
            case 3: Int(Int16(truncatingIfNeeded: try uint(2)))
            case 4: Int(try uint(4))
            case 5: Int(Int32(truncatingIfNeeded: try uint(4)))
            case 7: Int(try uint(1))
            case 10: Int(truncatingIfNeeded: try uint(8))
            case 11: Int(Int64(bitPattern: try uint(8)))
            default: nil
            }
        }

        mutating func value(_ type: UInt32) throws -> Value {
            switch type {
            case 8:
                return .string(try string())
            case 9:
                let elementType = try u32()
                let count = try u64()
                guard count < 1 << 32 else { throw GGUFError.invalid }
                if elementType == 8 {
                    for _ in 0..<count {
                        let n = try u64()
                        try skip(Int(n))
                    }
                    return .other
                }
                guard let size = Self.size(elementType) else { throw GGUFError.invalid }
                if count <= 4096, elementType != 6, elementType != 12 {
                    var values: [Int] = []
                    values.reserveCapacity(Int(count))
                    for _ in 0..<count { values.append(try integer(elementType) ?? 0) }
                    return .ints(values)
                }
                try skip(Int(count) * size)
                return .other
            default:
                guard let size = Self.size(type) else { throw GGUFError.invalid }
                if let v = try integer(type) { return .ints([v]) }
                try skip(size)
                return .other
            }
        }
    }
}

import CryptoKit
import Foundation

/// OpenBSD `bcrypt_pbkdf`, used by OpenSSH to derive the cipher key for passphrase-protected private keys.
/// Ported from OpenBSD bcrypt_pbkdf.c / blf.c.
enum BcryptPBKDF {
    static func derive(password: Data, salt: Data, keyLength: Int, rounds: Int) -> Data? {
        guard rounds >= 1, !password.isEmpty, !salt.isEmpty, keyLength > 0, keyLength <= 32 * 32 else { return nil }

        let hashSize = 32
        let stride = (keyLength + hashSize - 1) / hashSize
        var amount = (keyLength + stride - 1) / stride
        var key = [UInt8](repeating: 0, count: keyLength)
        var remaining = keyLength

        let sha2pass = [UInt8](SHA512.hash(data: password))
        var countSalt = [UInt8](salt) + [0, 0, 0, 0]
        var count: UInt32 = 1

        while remaining > 0 {
            countSalt[salt.count + 0] = UInt8(truncatingIfNeeded: count >> 24)
            countSalt[salt.count + 1] = UInt8(truncatingIfNeeded: count >> 16)
            countSalt[salt.count + 2] = UInt8(truncatingIfNeeded: count >> 8)
            countSalt[salt.count + 3] = UInt8(truncatingIfNeeded: count)

            var sha2salt = [UInt8](SHA512.hash(data: countSalt))
            var tmp = bcryptHash(sha2pass: sha2pass, sha2salt: sha2salt)
            var out = tmp

            for _ in 1..<rounds {
                sha2salt = [UInt8](SHA512.hash(data: tmp))
                tmp = bcryptHash(sha2pass: sha2pass, sha2salt: sha2salt)
                for j in 0..<hashSize { out[j] ^= tmp[j] }
            }

            // pbkdf2 deviation: key material is output non-linearly.
            amount = min(amount, remaining)
            var written = 0
            while written < amount {
                let dest = written * stride + Int(count - 1)
                if dest >= keyLength { break }
                key[dest] = out[written]
                written += 1
            }
            remaining -= written
            count += 1
        }
        return Data(key)
    }

    private static func bcryptHash(sha2pass: [UInt8], sha2salt: [UInt8]) -> [UInt8] {
        var state = Blowfish()
        state.expandState(data: sha2salt, key: sha2pass)
        for _ in 0..<64 {
            state.expand0State(key: sha2salt)
            state.expand0State(key: sha2pass)
        }

        let ciphertext = Array("OxychromaticBlowfishSwatDynamite".utf8)
        var cdata = [UInt32](repeating: 0, count: 8)
        var j = 0
        for i in 0..<8 { cdata[i] = Blowfish.streamToWord(ciphertext, &j) }
        for _ in 0..<64 {
            for block in 0..<4 {
                var l = cdata[2 * block], r = cdata[2 * block + 1]
                state.encipher(&l, &r)
                cdata[2 * block] = l
                cdata[2 * block + 1] = r
            }
        }

        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            out[4 * i + 3] = UInt8(truncatingIfNeeded: cdata[i] >> 24)
            out[4 * i + 2] = UInt8(truncatingIfNeeded: cdata[i] >> 16)
            out[4 * i + 1] = UInt8(truncatingIfNeeded: cdata[i] >> 8)
            out[4 * i + 0] = UInt8(truncatingIfNeeded: cdata[i])
        }
        return out
    }
}

private struct Blowfish {
    var s = BlowfishTables.s
    var p = BlowfishTables.p

    static func streamToWord(_ data: [UInt8], _ current: inout Int) -> UInt32 {
        var word: UInt32 = 0
        for _ in 0..<4 {
            if current >= data.count { current = 0 }
            word = (word << 8) | UInt32(data[current])
            current += 1
        }
        return word
    }

    @inline(__always)
    private func f(_ x: UInt32) -> UInt32 {
        ((s[Int(x >> 24)] &+ s[0x100 + Int((x >> 16) & 0xFF)]) ^ s[0x200 + Int((x >> 8) & 0xFF)]) &+ s[0x300 + Int(x & 0xFF)]
    }

    func encipher(_ xl: inout UInt32, _ xr: inout UInt32) {
        var l = xl ^ p[0]
        var r = xr
        var i = 1
        while i <= 16 {
            r ^= f(l) ^ p[i]
            l ^= f(r) ^ p[i + 1]
            i += 2
        }
        xl = r ^ p[17]
        xr = l
    }

    mutating func expand0State(key: [UInt8]) {
        var j = 0
        for i in 0..<18 { p[i] ^= Self.streamToWord(key, &j) }

        var l: UInt32 = 0, r: UInt32 = 0
        for i in Swift.stride(from: 0, to: 18, by: 2) {
            encipher(&l, &r)
            p[i] = l
            p[i + 1] = r
        }
        for i in Swift.stride(from: 0, to: 1024, by: 2) {
            encipher(&l, &r)
            s[i] = l
            s[i + 1] = r
        }
    }

    mutating func expandState(data: [UInt8], key: [UInt8]) {
        var j = 0
        for i in 0..<18 { p[i] ^= Self.streamToWord(key, &j) }

        j = 0
        var l: UInt32 = 0, r: UInt32 = 0
        for i in Swift.stride(from: 0, to: 18, by: 2) {
            l ^= Self.streamToWord(data, &j)
            r ^= Self.streamToWord(data, &j)
            encipher(&l, &r)
            p[i] = l
            p[i + 1] = r
        }
        for i in Swift.stride(from: 0, to: 1024, by: 2) {
            l ^= Self.streamToWord(data, &j)
            r ^= Self.streamToWord(data, &j)
            encipher(&l, &r)
            s[i] = l
            s[i + 1] = r
        }
    }
}

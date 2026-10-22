import _CryptoExtras
import CommonCrypto
import Crypto
import Foundation
import NIOCore
import NIOSSH

enum KeyImportError: LocalizedError, Equatable {
    case passphraseRequired
    case wrongPassphrase
    case publicKeyNotPrivate
    case puttyFormat
    case encryptedPKCS8
    case unsupportedCipher(String)
    case unsupportedType(String)
    case rsaTooSmall
    case unrecognized
    case corrupt

    var errorDescription: String? {
        switch self {
        case .passphraseRequired: "This key is protected with a passphrase. Enter it below."
        case .wrongPassphrase: "Wrong passphrase."
        case .publicKeyNotPrivate: "That's a public key (.pub). Import the private key file instead, e.g. ~/.ssh/id_ed25519 without .pub."
        case .puttyFormat: "PuTTY .ppk keys aren't supported. In PuTTYgen choose Conversions → Export OpenSSH key, then import that file."
        case .encryptedPKCS8: "Encrypted PKCS#8 keys aren't supported. Convert it on a computer with: ssh-keygen -p -f <keyfile>"
        case .unsupportedCipher(let c): "Unsupported key encryption \(c). Re-encrypt it with: ssh-keygen -p -f <keyfile>"
        case .unsupportedType(let t): "Unsupported key type \(t). Supported: ed25519, RSA, ECDSA."
        case .rsaTooSmall: "RSA keys smaller than 2048 bits are insecure and not supported."
        case .unrecognized: "Not a recognized private key. Paste the whole file including the -----BEGIN … PRIVATE KEY----- lines."
        case .corrupt: "The key file is damaged or incomplete."
        }
    }
}

/// A decrypted private key from any supported file format.
enum ParsedKey {
    case ed25519(Curve25519.Signing.PrivateKey)
    case rsa(_RSA.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)

    var typeName: String {
        switch self {
        case .ed25519: "ed25519"
        case .rsa(let k): "rsa-\(k.keySizeInBits)"
        case .p256: "ecdsa-p256"
        case .p384: "ecdsa-p384"
        case .p521: "ecdsa-p521"
        }
    }

    /// OpenSSH single-line public key, without comment.
    func openSSHPublicKey() throws -> String {
        switch self {
        case .ed25519(let k): return String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: k).publicKey)
        case .p256(let k): return String(openSSHPublicKey: NIOSSHPrivateKey(p256Key: k).publicKey)
        case .p384(let k): return String(openSSHPublicKey: NIOSSHPrivateKey(p384Key: k).publicKey)
        case .p521(let k): return String(openSSHPublicKey: NIOSSHPrivateKey(p521Key: k).publicKey)
        case .rsa(let k):
            let primitives = try k.publicKey.getKeyPrimitives()
            var buffer = ByteBuffer()
            buffer.writeInteger(UInt32(7))
            buffer.writeString("ssh-rsa")
            buffer.writeSSHMPInt(primitives.publicExponent)
            buffer.writeSSHMPInt(primitives.modulus)
            return "ssh-rsa " + Data(buffer.readableBytesView).base64EncodedString()
        }
    }
}

enum PrivateKeyParser {
    /// Parses any supported private key text. Throws `.passphraseRequired` when the key is encrypted and no passphrase was given.
    static func parse(_ text: String, passphrase: String?) throws -> (key: ParsedKey, comment: String?) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let passphrase = passphrase?.isEmpty == true ? nil : passphrase

        if text.hasPrefix("PuTTY-User-Key-File") { throw KeyImportError.puttyFormat }
        if !text.contains("-----BEGIN"),
           ["ssh-", "ecdsa-", "sk-"].contains(where: text.hasPrefix) {
            throw KeyImportError.publicKeyNotPrivate
        }

        let pem = try PEM(text)
        switch pem.label {
        case "OPENSSH PRIVATE KEY":
            return try OpenSSHFormat.parse(pem.body, passphrase: passphrase)
        case "RSA PRIVATE KEY":
            return (try pem.withDecryptedBody(passphrase: passphrase) { .rsa(try rsa(der: $0)) }, nil)
        case "EC PRIVATE KEY":
            return (try pem.withDecryptedBody(passphrase: passphrase) { try sec1(der: $0) }, nil)
        case "PRIVATE KEY":
            return (try pkcs8(pem.body), nil)
        case "ENCRYPTED PRIVATE KEY":
            throw KeyImportError.encryptedPKCS8
        default:
            throw KeyImportError.unrecognized
        }
    }

    static func rsa(der: Data) throws -> _RSA.Signing.PrivateKey {
        do {
            return try _RSA.Signing.PrivateKey(derRepresentation: der)
        } catch {
            if let small = try? _RSA.Signing.PrivateKey(unsafeDERRepresentation: der), small.keySizeInBits < 2048 {
                throw KeyImportError.rsaTooSmall
            }
            throw KeyImportError.corrupt
        }
    }

    /// SEC1 `ECPrivateKey` (RFC 5915): SEQUENCE { INTEGER 1, OCTET STRING d, [0] curve, [1] public key }.
    /// CryptoKit's DER initializers only take PKCS#8, so read the scalar directly; its length identifies the curve.
    static func sec1(der: Data) throws -> ParsedKey {
        var d = DERReader(der)
        guard var seq = d.element(tag: 0x30), let version = seq.element(tag: 0x02), version.bytes == Data([1]),
              let scalar = seq.element(tag: 0x04)?.bytes else {
            return try ecdsa(der: der)
        }
        switch scalar.count {
        case 32: return .p256(try P256.Signing.PrivateKey(rawRepresentation: scalar))
        case 48: return .p384(try P384.Signing.PrivateKey(rawRepresentation: scalar))
        case 65, 66: return .p521(try P521.Signing.PrivateKey(rawRepresentation: scalar.leftPadded(to: 66)))
        default: throw KeyImportError.corrupt
        }
    }

    static func ecdsa(der: Data) throws -> ParsedKey {
        if let k = try? P256.Signing.PrivateKey(derRepresentation: der) { return .p256(k) }
        if let k = try? P384.Signing.PrivateKey(derRepresentation: der) { return .p384(k) }
        if let k = try? P521.Signing.PrivateKey(derRepresentation: der) { return .p521(k) }
        throw KeyImportError.corrupt
    }

    private static func pkcs8(_ der: Data) throws -> ParsedKey {
        // Ed25519 PKCS#8 (RFC 8410) is a fixed 16-byte prefix followed by the 32-byte seed.
        let ed25519Prefix = Data([0x30, 0x2E, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2B, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20])
        if der.count == 48, der.prefix(16) == ed25519Prefix {
            return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: der.suffix(32)))
        }
        if let k = try? ecdsa(der: der) { return k }
        return .rsa(try rsa(der: der))
    }
}

// MARK: - PEM

private struct PEM {
    let label: String
    let headers: [String: String]
    let body: Data

    init(_ text: String) throws {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") }),
              let end = lines.lastIndex(where: { $0.hasPrefix("-----END ") }), end > begin else {
            throw KeyImportError.unrecognized
        }
        label = String(lines[begin].dropFirst("-----BEGIN ".count).dropLast(5))

        var headers: [String: String] = [:]
        var bodyLines: [String] = []
        for line in lines[(begin + 1)..<end] where !line.isEmpty {
            if bodyLines.isEmpty, let colon = line.firstIndex(of: ":") {
                headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                bodyLines.append(line)
            }
        }
        guard let body = Data(base64Encoded: bodyLines.joined()) else { throw KeyImportError.corrupt }
        self.headers = headers
        self.body = body
    }

    var isEncrypted: Bool { headers["Proc-Type"]?.contains("ENCRYPTED") == true }

    /// Decodes the (possibly encrypted) body. A wrong passphrase on legacy PEM usually yields garbage rather than
    /// a padding error, so a body that then fails to parse is reported as a wrong passphrase.
    func withDecryptedBody<T>(passphrase: String?, _ parse: (Data) throws -> T) throws -> T {
        let der = try decryptedBody(passphrase: passphrase)
        do {
            return try parse(der)
        } catch KeyImportError.corrupt where isEncrypted {
            throw KeyImportError.wrongPassphrase
        }
    }

    /// Decrypts legacy OpenSSL PEM encryption (`Proc-Type: 4,ENCRYPTED` + `DEK-Info`).
    private func decryptedBody(passphrase: String?) throws -> Data {
        guard isEncrypted else { return body }
        guard let passphrase else { throw KeyImportError.passphraseRequired }
        guard let dek = headers["DEK-Info"]?.split(separator: ","), dek.count == 2,
              let iv = Data(hex: String(dek[1])) else { throw KeyImportError.corrupt }

        let cipher = String(dek[0]).uppercased()
        let (algorithm, keySize): (CCAlgorithm, Int) = switch cipher {
        case "AES-128-CBC": (CCAlgorithm(kCCAlgorithmAES), 16)
        case "AES-192-CBC": (CCAlgorithm(kCCAlgorithmAES), 24)
        case "AES-256-CBC": (CCAlgorithm(kCCAlgorithmAES), 32)
        case "DES-EDE3-CBC": (CCAlgorithm(kCCAlgorithm3DES), 24)
        default: throw KeyImportError.unsupportedCipher(cipher)
        }

        // OpenSSL EVP_BytesToKey with MD5, one iteration, salt = first 8 bytes of the IV.
        var key = Data()
        var previous = Data()
        while key.count < keySize {
            previous = Data(Insecure.MD5.hash(data: previous + Data(passphrase.utf8) + iv.prefix(8)))
            key += previous
        }
        guard let plain = try? Cipher.cbcDecrypt(body, key: key.prefix(keySize), iv: iv, algorithm: algorithm, padding: true) else {
            throw KeyImportError.wrongPassphrase
        }
        return plain
    }
}

// MARK: - OpenSSH format

private enum OpenSSHFormat {
    static func parse(_ data: Data, passphrase: String?) throws -> (key: ParsedKey, comment: String?) {
        var reader = SSHReader(data)
        let magic = Data("openssh-key-v1\0".utf8)
        guard reader.bytes(magic.count) == magic,
              let cipher = reader.string(), let kdf = reader.string(), var kdfOptions = reader.nested(),
              reader.uint32() == 1, reader.buffer() != nil,
              let encrypted = reader.buffer() else { throw KeyImportError.corrupt }

        var plain: Data
        if cipher == "none" {
            plain = encrypted
        } else {
            guard let passphrase else { throw KeyImportError.passphraseRequired }
            guard kdf == "bcrypt", let salt = kdfOptions.buffer(), let rounds = kdfOptions.uint32() else {
                throw KeyImportError.unsupportedCipher("\(cipher)/\(kdf)")
            }
            let spec = try CipherSpec(cipher)
            guard let derived = BcryptPBKDF.derive(password: Data(passphrase.utf8), salt: salt,
                                                   keyLength: spec.keySize + spec.ivSize, rounds: Int(rounds)) else {
                throw KeyImportError.corrupt
            }
            let key = derived.prefix(spec.keySize)
            let iv = derived.dropFirst(spec.keySize)
            switch spec.mode {
            case .ctr:
                plain = try Cipher.ctrDecrypt(encrypted, key: key, iv: iv)
            case .cbc:
                plain = try Cipher.cbcDecrypt(encrypted, key: key, iv: iv, algorithm: CCAlgorithm(kCCAlgorithmAES), padding: false)
            case .gcm:
                guard let tag = reader.bytes(16),
                      let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: encrypted, tag: tag),
                      let opened = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else {
                    throw KeyImportError.wrongPassphrase
                }
                plain = opened
            }
        }

        var priv = SSHReader(plain)
        guard let check1 = priv.uint32(), let check2 = priv.uint32() else { throw KeyImportError.corrupt }
        guard check1 == check2 else {
            throw cipher == "none" ? KeyImportError.corrupt : KeyImportError.wrongPassphrase
        }
        guard let type = priv.string() else { throw KeyImportError.corrupt }

        let key: ParsedKey
        switch type {
        case "ssh-ed25519":
            guard priv.buffer() != nil, let secret = priv.buffer(), secret.count == 64 else { throw KeyImportError.corrupt }
            key = .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: secret.prefix(32)))
        case "ssh-rsa":
            guard let n = priv.buffer(), let e = priv.buffer(), let d = priv.buffer(),
                  priv.buffer() != nil, let p = priv.buffer(), let q = priv.buffer() else { throw KeyImportError.corrupt }
            if n.drop(while: { $0 == 0 }).count * 8 < 2048 { throw KeyImportError.rsaTooSmall }
            do {
                key = .rsa(try _RSA.Signing.PrivateKey(n: n.trimmed, e: e.trimmed, d: d.trimmed, p: p.trimmed, q: q.trimmed))
            } catch {
                throw KeyImportError.corrupt
            }
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard priv.string() != nil, priv.buffer() != nil, let d = priv.buffer() else { throw KeyImportError.corrupt }
            switch type {
            case "ecdsa-sha2-nistp256": key = .p256(try P256.Signing.PrivateKey(rawRepresentation: d.leftPadded(to: 32)))
            case "ecdsa-sha2-nistp384": key = .p384(try P384.Signing.PrivateKey(rawRepresentation: d.leftPadded(to: 48)))
            default: key = .p521(try P521.Signing.PrivateKey(rawRepresentation: d.leftPadded(to: 66)))
            }
        default:
            throw KeyImportError.unsupportedType(type)
        }
        let comment = priv.string().flatMap { $0.isEmpty ? nil : $0 }
        return (key, comment)
    }

    private struct CipherSpec {
        enum Mode { case ctr, cbc, gcm }
        let keySize: Int
        let ivSize: Int
        let mode: Mode

        init(_ name: String) throws {
            switch name {
            case "aes128-ctr": (keySize, ivSize, mode) = (16, 16, .ctr)
            case "aes192-ctr": (keySize, ivSize, mode) = (24, 16, .ctr)
            case "aes256-ctr": (keySize, ivSize, mode) = (32, 16, .ctr)
            case "aes128-cbc": (keySize, ivSize, mode) = (16, 16, .cbc)
            case "aes192-cbc": (keySize, ivSize, mode) = (24, 16, .cbc)
            case "aes256-cbc": (keySize, ivSize, mode) = (32, 16, .cbc)
            case "aes128-gcm@openssh.com": (keySize, ivSize, mode) = (16, 12, .gcm)
            case "aes256-gcm@openssh.com": (keySize, ivSize, mode) = (32, 12, .gcm)
            default: throw KeyImportError.unsupportedCipher(name)
            }
        }
    }
}

// MARK: - Helpers

private struct SSHReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = Data(data) }

    mutating func bytes(_ n: Int) -> Data? {
        guard n >= 0, offset + n <= data.count else { return nil }
        defer { offset += n }
        return data.subdata(in: offset..<offset + n)
    }

    mutating func uint32() -> UInt32? {
        bytes(4).map { $0.reduce(0) { $0 << 8 | UInt32($1) } }
    }

    mutating func buffer() -> Data? {
        uint32().flatMap { bytes(Int($0)) }
    }

    mutating func nested() -> SSHReader? {
        buffer().map(SSHReader.init)
    }

    mutating func string() -> String? {
        buffer().flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// Minimal DER reader: just enough to walk a SEC1 ECPrivateKey.
private struct DERReader {
    let bytes: Data
    private var offset = 0

    init(_ data: Data) { bytes = Data(data) }

    mutating func element(tag: UInt8) -> DERReader? {
        guard offset + 2 <= bytes.count, bytes[offset] == tag else { return nil }
        var length = Int(bytes[offset + 1])
        var header = 2
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count <= 3, offset + 2 + count <= bytes.count else { return nil }
            length = bytes[(offset + 2)..<(offset + 2 + count)].reduce(0) { $0 << 8 | Int($1) }
            header += count
        }
        guard offset + header + length <= bytes.count else { return nil }
        defer { offset += header + length }
        return DERReader(bytes.subdata(in: (offset + header)..<(offset + header + length)))
    }
}

private enum Cipher {
    struct Failed: Error {}

    static func cbcDecrypt(_ data: Data, key: Data, iv: Data, algorithm: CCAlgorithm, padding: Bool) throws -> Data {
        var out = Data(count: data.count + 32)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCDecrypt), algorithm, CCOptions(padding ? kCCOptionPKCS7Padding : 0),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                inPtr.baseAddress, data.count, outPtr.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failed() }
        return out.prefix(moved)
    }

    static func ctrDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var cryptor: CCCryptorRef?
        let created = key.withUnsafeBytes { keyPtr in
            iv.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), ivPtr.baseAddress, keyPtr.baseAddress, key.count,
                                        nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else { throw Failed() }
        defer { CCCryptorRelease(cryptor) }

        var out = Data(count: data.count)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                CCCryptorUpdate(cryptor, inPtr.baseAddress, data.count, outPtr.baseAddress, outCount, &moved)
            }
        }
        guard status == kCCSuccess else { throw Failed() }
        return out.prefix(moved)
    }
}

private extension Data {
    init?(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex),
                  let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var trimmed: Data { Data(drop { $0 == 0 }) }

    func leftPadded(to size: Int) -> Data {
        let t = trimmed
        return t.count >= size ? t.suffix(size) : Data(repeating: 0, count: size - t.count) + t
    }
}

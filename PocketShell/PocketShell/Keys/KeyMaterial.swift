import _CryptoExtras
import Citadel
import Crypto
import Foundation
import NIOSSH

/// Private key material as stored in the Keychain. Only metadata (`SSHKey`) lives in the JSON store.
/// Imported keys are stored decrypted (Keychain, this device only) so connecting never asks for the passphrase.
enum KeyMaterial: Codable {
    /// Raw 32-byte Ed25519 seed.
    case ed25519(Data)
    /// RSA private key, DER.
    case rsa(Data)
    /// ECDSA private scalar; curve is 256, 384 or 521.
    case ecdsa(curve: Int, raw: Data)
    /// Imported by v0.1: the original OpenSSH file, decoded on use.
    case openSSH(text: String, passphrase: String?)

    enum KeyError: LocalizedError {
        case missing
        var errorDescription: String? { "Private key not found in Keychain." }
    }

    enum Generated: String, CaseIterable, Identifiable {
        case ed25519, ecdsaP256, rsa4096
        var id: String { rawValue }

        var title: String {
            switch self {
            case .ed25519: "Ed25519 (recommended)"
            case .ecdsaP256: "ECDSA P-256"
            case .rsa4096: "RSA 4096"
            }
        }

        var detail: String {
            switch self {
            case .ed25519: "Modern, fast and short. Works with OpenSSH 6.5+ (2014)."
            case .ecdsaP256: "For servers or policies that don't accept Ed25519."
            case .rsa4096: "Maximum compatibility with older servers and network gear."
            }
        }
    }

    init(_ key: ParsedKey) {
        switch key {
        case .ed25519(let k): self = .ed25519(k.rawRepresentation)
        case .rsa(let k): self = .rsa(k.derRepresentation)
        case .p256(let k): self = .ecdsa(curve: 256, raw: k.rawRepresentation)
        case .p384(let k): self = .ecdsa(curve: 384, raw: k.rawRepresentation)
        case .p521(let k): self = .ecdsa(curve: 521, raw: k.rawRepresentation)
        }
    }

    func parsed() throws -> ParsedKey {
        switch self {
        case .ed25519(let raw): return .ed25519(try .init(rawRepresentation: raw))
        case .rsa(let der): return .rsa(try .init(derRepresentation: der))
        case .ecdsa(256, let raw): return .p256(try .init(rawRepresentation: raw))
        case .ecdsa(384, let raw): return .p384(try .init(rawRepresentation: raw))
        case .ecdsa(_, let raw): return .p521(try .init(rawRepresentation: raw))
        case .openSSH(let text, let passphrase): return try PrivateKeyParser.parse(text, passphrase: passphrase).key
        }
    }

    // MARK: Keychain

    static func load(_ id: UUID) throws -> KeyMaterial {
        guard let data = Keychain.get("key.\(id)") else { throw KeyError.missing }
        return try JSONDecoder().decode(KeyMaterial.self, from: data)
    }

    func save(as id: UUID) throws {
        try Keychain.set(try JSONEncoder().encode(self), for: "key.\(id)")
    }

    static func delete(_ id: UUID) {
        Keychain.delete("key.\(id)")
    }

    // MARK: Creation

    /// Generates a new key. RSA generation takes a few seconds; call off the main thread.
    static func generate(_ type: Generated, name: String) throws -> SSHKey {
        let key: ParsedKey = switch type {
        case .ed25519: .ed25519(Curve25519.Signing.PrivateKey())
        case .ecdsaP256: .p256(P256.Signing.PrivateKey())
        case .rsa4096: .rsa(try _RSA.Signing.PrivateKey(keySize: .bits4096))
        }
        return try store(key, name: name)
    }

    /// Imports a private key in OpenSSH, PEM or PKCS#8 format. Slow for passphrase-protected OpenSSH keys
    /// (bcrypt KDF); call off the main thread.
    static func importKey(name: String?, text: String, passphrase: String?, fallbackName: String? = nil) throws -> SSHKey {
        let (key, comment) = try PrivateKeyParser.parse(text, passphrase: passphrase)
        let name = [name, comment, fallbackName].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "imported"
        return try store(key, name: name)
    }

    private static func store(_ key: ParsedKey, name: String) throws -> SSHKey {
        let publicKey = try key.openSSHPublicKey()
        let meta = SSHKey(name: name, type: key.typeName, publicKey: "\(publicKey) \(name.replacingOccurrences(of: " ", with: "-"))")
        try KeyMaterial(key).save(as: meta.id)
        return meta
    }

    // MARK: Auth

    /// Auth methods to try in order, one connection attempt each. RSA offers rsa-sha2-512, then rsa-sha2-256.
    func authenticationMethods(username: String) throws -> [SSHAuthenticationMethod] {
        switch try parsed() {
        case .ed25519(let k): return [.ed25519(username: username, privateKey: k)]
        case .p256(let k): return [.p256(username: username, privateKey: k)]
        case .p384(let k): return [.p384(username: username, privateKey: k)]
        case .p521(let k): return [.p521(username: username, privateKey: k)]
        case .rsa(let k):
            return [
                .custom(SingleKeyOffer(username: username, key: NIOSSHPrivateKey(custom: try RSASHA2PrivateKey<RSASHA512>(k)))),
                .custom(SingleKeyOffer(username: username, key: NIOSSHPrivateKey(custom: try RSASHA2PrivateKey<RSASHA256>(k)))),
            ]
        }
    }
}

enum HostKeyFingerprint {
    /// OpenSSH-style `SHA256:...` fingerprint of a single-line public key.
    static func sha256(_ openSSHPublicKey: String) -> String {
        let parts = openSSHPublicKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "?" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}

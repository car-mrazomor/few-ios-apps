import _CryptoExtras
import Crypto
import Foundation
import NIOCore
import NIOSSH

/// RSA user-auth key that signs with `rsa-sha2-512` / `rsa-sha2-256` (RFC 8332).
///
/// swift-nio-ssh uses the key prefix both as the userauth algorithm name and as the type string in
/// the key blob. OpenSSH maps the `rsa-sha2-*` names back to plain RSA when parsing the blob, so
/// advertising the signature algorithm as the prefix authenticates correctly.
protocol RSAHashVariant {
    static var name: String { get }
    static func sign(_ key: _RSA.Signing.PrivateKey, _ data: some DataProtocol) throws -> Data
}

enum RSASHA512: RSAHashVariant {
    static let name = "rsa-sha2-512"
    static func sign(_ key: _RSA.Signing.PrivateKey, _ data: some DataProtocol) throws -> Data {
        try key.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
    }
}

enum RSASHA256: RSAHashVariant {
    static let name = "rsa-sha2-256"
    static func sign(_ key: _RSA.Signing.PrivateKey, _ data: some DataProtocol) throws -> Data {
        try key.signature(for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
    }
}

struct RSASHA2PrivateKey<Hash: RSAHashVariant>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { Hash.name }

    let key: _RSA.Signing.PrivateKey
    let publicKey: NIOSSHPublicKeyProtocol

    init(_ key: _RSA.Signing.PrivateKey) throws {
        self.key = key
        let primitives = try key.publicKey.getKeyPrimitives()
        publicKey = RSASHA2PublicKey<Hash>(modulus: primitives.modulus, exponent: primitives.publicExponent)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        RSASHA2Signature<Hash>(rawRepresentation: try Hash.sign(key, data))
    }
}

struct RSASHA2PublicKey<Hash: RSAHashVariant>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { Hash.name }

    let modulus: Data
    let exponent: Data

    var rawRepresentation: Data { exponent + modulus }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        false // Only used for signing on the client side.
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHMPInt(exponent) + buffer.writeSSHMPInt(modulus)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        throw KeyImportError.corrupt
    }
}

struct RSASHA2Signature<Hash: RSAHashVariant>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { Hash.name }

    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeInteger(UInt32(rawRepresentation.count)) + buffer.writeBytes(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        throw KeyImportError.corrupt
    }
}

/// Offers a single custom private key. Citadel consults a custom delegate once per connection,
/// so alternatives (rsa-sha2-512 → rsa-sha2-256) are tried as separate connection attempts.
final class SingleKeyOffer: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var key: NIOSSHPrivateKey?

    init(username: String, key: NIOSSHPrivateKey) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey), let key else {
            nextChallengePromise.succeed(nil)
            return
        }
        self.key = nil
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

extension ByteBuffer {
    /// SSH `mpint`: big-endian two's complement, minimal length, with a leading zero if the top bit is set.
    @discardableResult
    mutating func writeSSHMPInt(_ magnitude: Data) -> Int {
        var bytes = Array(magnitude.drop { $0 == 0 })
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return writeInteger(UInt32(bytes.count)) + writeBytes(bytes)
    }
}

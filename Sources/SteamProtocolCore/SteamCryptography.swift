import Foundation
import Security
#if canImport(SteamCrypto)
import SteamCrypto
#endif

enum SteamCryptoError: Error { case random(OSStatus), symmetric(Int32), keyImport, encryption, invalidKey }

enum SteamCryptography {
    static func random(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else { throw SteamCryptoError.random(status) }
        return Data(bytes)
    }
    static func encrypt(_ data: Data, key: Data, iv: Data? = nil) throws -> Data {
        guard key.count == 32 else { throw SteamCryptoError.invalidKey }
        let initialization = try iv ?? random(count: 16)
        guard initialization.count == 16 else { throw SteamCryptoError.invalidKey }
        var output = [UInt8](repeating: 0, count: data.count + 32)
        var length = output.count
        let result = data.withUnsafeBytes { input in
            key.withUnsafeBytes { key in
                initialization.withUnsafeBytes { iv in
                    steam_encrypt(input.bindMemory(to: UInt8.self).baseAddress, input.count,
                        key.bindMemory(to: UInt8.self).baseAddress, iv.bindMemory(to: UInt8.self).baseAddress,
                        &output, &length)
                }
            }
        }
        guard result == 0 else { throw SteamCryptoError.symmetric(result) }
        return Data(output.prefix(length))
    }
    static func decrypt(_ data: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw SteamCryptoError.invalidKey }
        var output = [UInt8](repeating: 0, count: max(1, data.count))
        var length = output.count
        let result = data.withUnsafeBytes { input in
            key.withUnsafeBytes { key in
                steam_decrypt(input.bindMemory(to: UInt8.self).baseAddress, input.count,
                    key.bindMemory(to: UInt8.self).baseAddress, &output, &length)
            }
        }
        guard result == 0 else { throw SteamCryptoError.symmetric(result) }
        return Data(output.prefix(length))
    }
    static func encryptTicket(_ data: Data) throws -> Data {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateWithData(SteamPublicKey.pkcs1 as CFData, attributes as CFDictionary, nil) else {
            throw SteamCryptoError.keyImport
        }
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionOAEPSHA1, data as CFData, nil) else {
            throw SteamCryptoError.encryption
        }
        return encrypted as Data
    }
}

import CryptoKit

/// Current Steam PIN exchange: the public key is XOR-masked with SHA256(PIN),
/// and SHA256(X25519 shared secret) becomes the per-host authorization secret.
/// Derived from the current Steam Link 1.3.32.316 authorization path.
struct SteamPINKeyExchange {
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let mask: Data

    init(pin: String, privateKey: Data? = nil) throws {
        guard pin.count == 4, pin.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            throw SteamCryptoError.invalidKey
        }
        self.privateKey = try privateKey.map { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
            ?? Curve25519.KeyAgreement.PrivateKey()
        mask = Data(SHA256.hash(data: Data(pin.utf8)))
    }
    var authorizationKey: Data {
        Data(zip(privateKey.publicKey.rawRepresentation, mask).map { $0 ^ $1 })
    }
    func sharedSecret(peerAuthorizationKey: Data) throws -> Data {
        guard peerAuthorizationKey.count == 32 else { throw SteamCryptoError.invalidKey }
        let raw = Data(zip(peerAuthorizationKey, mask).map { $0 ^ $1 })
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.withUnsafeBytes { Data(SHA256.hash(data: Data($0))) }
    }
    func verify(peerAuthorizationKey: Data, token: Data, clientID: UInt64) throws -> Data {
        let secret = try sharedSecret(peerAuthorizationKey: peerAuthorizationKey)
        let expected = Data((0..<8).map { UInt8(truncatingIfNeeded: clientID >> ($0 * 8)) })
        guard try SteamCryptography.decrypt(token, key: secret) == expected else {
            throw SteamCryptoError.invalidKey
        }
        return secret
    }
}

extension SteamCryptography {
    static func decryptFrame(_ data: Data, key: Data) throws -> (sequence: UInt64, payload: Data) {
        guard key.count == 16 || key.count == 32 else { throw SteamCryptoError.invalidKey }
        var output = [UInt8](repeating: 0, count: max(1, data.count))
        var length = output.count
        let result = data.withUnsafeBytes { input in
            key.withUnsafeBytes { key in
                steam_frame_decrypt(input.bindMemory(to: UInt8.self).baseAddress, input.count,
                    key.bindMemory(to: UInt8.self).baseAddress, key.count, &output, &length)
            }
        }
        guard result == 0, length >= 8 else { throw SteamCryptoError.symmetric(result) }
        let sequence = (0..<8).reduce(UInt64(0)) { $0 | UInt64(output[$1]) << ($1 * 8) }
        return (sequence, Data(output[8..<length]))
    }
    static func authenticationToken(key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("Steam In-Home Streaming".utf8), using: SymmetricKey(data: key)))
    }
}

extension SteamCryptography {
    static func encryptFrame(_ payload: Data, sequence: UInt64, key: Data) throws -> Data {
        guard key.count == 16 || key.count == 32 else { throw SteamCryptoError.invalidKey }
        let data = SteamSessionPacket.littleEndian(sequence) + payload
        var output = [UInt8](repeating: 0, count: data.count + 32)
        var length = output.count
        let result = data.withUnsafeBytes { input in
            key.withUnsafeBytes { key in
                steam_frame_encrypt(input.bindMemory(to: UInt8.self).baseAddress, input.count,
                    key.bindMemory(to: UInt8.self).baseAddress, key.count, &output, &length)
            }
        }
        guard result == 0 else { throw SteamCryptoError.symmetric(result) }
        return Data(output.prefix(length))
    }
}

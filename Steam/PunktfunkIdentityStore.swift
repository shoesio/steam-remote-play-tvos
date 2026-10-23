import Foundation
import PunktfunkKit
import Security

final class PunktfunkIdentityStore: @unchecked Sendable {
    static let shared = PunktfunkIdentityStore()

    enum IdentityError: Error {
        case keychain(OSStatus)
        case notPersisted
    }

    private let lock = NSLock()
    private var cached: (identity: ClientIdentity, persisted: Bool)?

    private init() {}

    func load() throws -> (identity: ClientIdentity, persisted: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if let cached { return cached }

        switch copyStored() {
        case .found(let identity):
            let hit = (identity, true)
            cached = hit
            return hit

        case .absent:
            break

        case .corrupt:
            SecItemDelete(Self.query(dataProtection: true) as CFDictionary)
            SecItemDelete(Self.query(dataProtection: false) as CFDictionary)

        case .denied(let status):
            throw IdentityError.keychain(status)
        }

        let fresh = try generateIdentity()

        let entry: (ClientIdentity, Bool)

        switch add(fresh) {
        case errSecSuccess:
            entry = (fresh, true)

        case errSecDuplicateItem:
            if case .found(let identity) = copyStored() {
                entry = (identity, true)
            } else {
                entry = (fresh, false)
            }

        default:
            entry = (fresh, false)
        }

        cached = entry
        return entry
    }

    func loadForPairing() throws -> ClientIdentity {
        let (identity, persisted) = try load()
        guard persisted else { throw IdentityError.notPersisted }
        return identity
    }

    private struct Stored: Codable {
        var certPEM: String
        var keyPEM: String
    }

    private enum ReadResult {
        case found(ClientIdentity)
        case absent
        case corrupt
        case denied(OSStatus)
    }

    private static func query(dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.owenselles.CloudNow.punktfunk",
            kSecAttrAccount as String: "client-identity"
        ]

        if dataProtection {
            q[kSecUseDataProtectionKeychain as String] = true
        }

        return q
    }

    private func copyStored() -> ReadResult {
        let result = read(dataProtection: true)

        if case .denied(errSecMissingEntitlement) = result {
            return read(dataProtection: false)
        }

        return result
    }

    private func read(dataProtection: Bool) -> ReadResult {
        var query = Self.query(dataProtection: dataProtection)
        query[kSecReturnData as String] = true

        var out: CFTypeRef?

        switch SecItemCopyMatching(query as CFDictionary, &out) {
        case errSecSuccess:
            guard
                let data = out as? Data,
                let stored = try? JSONDecoder().decode(Stored.self, from: data)
            else {
                return .corrupt
            }

            return .found(
                ClientIdentity(
                    certPEM: stored.certPEM,
                    keyPEM: stored.keyPEM
                )
            )

        case errSecItemNotFound:
            return .absent

        case let status:
            return .denied(status)
        }
    }

    private func add(_ identity: ClientIdentity) -> OSStatus {
        guard let data = try? JSONEncoder().encode(
            Stored(
                certPEM: identity.certPEM,
                keyPEM: identity.keyPEM
            )
        ) else {
            return errSecParam
        }

        var add = Self.query(dataProtection: true)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(add as CFDictionary, nil)

        guard status == errSecMissingEntitlement else {
            return status
        }

        var legacy = Self.query(dataProtection: false)
        legacy[kSecValueData as String] = data

        return SecItemAdd(legacy as CFDictionary, nil)
    }
}

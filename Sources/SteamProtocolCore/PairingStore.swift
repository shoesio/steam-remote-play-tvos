import Foundation
import Security

public struct SteamDeviceIdentity: Codable, Equatable, Sendable {
    public let clientID: UInt64
    public let secret: Data
    static func generate(clientID: UInt64) throws -> Self {
        Self(clientID: clientID, secret: try SteamCryptography.random(count: 32))
    }
}

public struct PairedSteamHost: Codable, Sendable {
    public let hostID: UInt64
    public let steamID: UInt64
    public let authKey: Data?
    public let deviceToken: Data?
    public var sharedSecret: Data? = nil
}

public struct PairingStore {
    private let service: String
    private let accessGroup: String?
    public init(service: String = "dev.steamtv.client.pairing", accessGroup: String? = nil) { self.service = service; self.accessGroup = accessGroup }
    public func identity(clientID: UInt64) throws -> SteamDeviceIdentity {
        if let data = try read(account: "identity") {
            let identity = try JSONDecoder().decode(SteamDeviceIdentity.self, from: data)
            guard identity.clientID != 0, identity.secret.count == 32 else { throw SteamCryptoError.invalidKey }
            return identity
        }
        let identity = try SteamDeviceIdentity.generate(clientID: clientID)
        try write(JSONEncoder().encode(identity), account: "identity")
        return identity
    }
    public func pairedHost(_ hostID: UInt64) throws -> PairedSteamHost? {
        guard let data = try read(account: "host.\(hostID)") else { return nil }
        return try JSONDecoder().decode(PairedSteamHost.self, from: data)
    }
    public func save(_ host: PairedSteamHost) throws {
        try write(JSONEncoder().encode(host), account: "host.\(host.hostID)")
    }
    private func query(account: String) -> [CFString: Any] {
        var result: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: account, kSecAttrSynchronizable: false]
        if let accessGroup { result[kSecAttrAccessGroup] = accessGroup }
        return result
    }
    private func read(account: String) throws -> Data? {
        var query = query(account: account)
        query[kSecReturnData] = true; query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return data
    }
    private func write(_ data: Data, account: String) throws {
        let query = query(account: account)
        let updates: [CFString: Any] = [kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            let status = SecItemAdd(query.merging(updates) { _, new in new } as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))" }
}

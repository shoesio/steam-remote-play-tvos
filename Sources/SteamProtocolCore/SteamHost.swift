import Foundation

public struct SteamHost: Identifiable, Equatable, Sendable {
    public var id: UInt64 { status.clientID }
    public var status: SteamHostStatus
    public var address: String
    /// UDP source port is the discovery/pairing endpoint; connectPort is distinct.
    public var discoveryPort: UInt16
    public var lastSeen: TimeInterval
    public var online: Bool
}

/// Separates host liveness from transport and UI, using monotonic time.
public struct HostRegistry {
    public private(set) var hosts: [UInt64: SteamHost] = [:]
    public let timeout: TimeInterval
    public init(timeout: TimeInterval = 15) { self.timeout = timeout }
    public mutating func receive(_ event: DiscoveryEvent, address: String, port: UInt16, now: TimeInterval) {
        switch event {
        case .status(let status):
            hosts[status.clientID] = SteamHost(status: status, address: address,
                discoveryPort: port, lastSeen: now, online: true)
        case .offline(let id): hosts[id]?.online = false
        case .ignored: break
        }
    }
    public mutating func expire(now: TimeInterval) {
        for id in hosts.keys where now - hosts[id]!.lastSeen >= timeout { hosts[id]?.online = false }
    }
}

public enum SteamVideoCodec: UInt64, Codable, Sendable {
    case h264 = 4, hevc = 5, pyrowave = 9
    public static let supported: [SteamVideoCodec] = [.hevc]
    // PyroWave is supported by the optional Metal backend; callers still select
    // it explicitly because its bandwidth and host encoder requirements differ.
}

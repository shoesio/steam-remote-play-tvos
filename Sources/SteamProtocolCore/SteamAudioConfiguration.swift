import Foundation

public struct SteamAudioConfiguration: Sendable {
    public let codec: UInt64
    public let sampleRate: UInt32
    public let channels: UInt32
    public let codecData: Data
}

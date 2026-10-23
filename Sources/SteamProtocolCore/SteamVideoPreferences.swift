import Foundation

/// Only user choices are replayed. Decoder limits, FEC and transport state stay fresh.
public struct SteamVideoPreferences: Sendable {
    public let data: Data
    private static let allowed: Set<Int> = [1,2,3,4,5,6,22,36,37,38,39,40]
    public init(_ configuration: Data) throws {
        data = try Self.fields(configuration).filter { Self.allowed.contains($0.0) }.reduce(Data()) { $0 + $1.1 }
    }
    public func applying(to configuration: Data) throws -> Data {
        let saved = try Self.fields(data)
        let replaced = Set(saved.map { $0.0 })
        return try Self.fields(configuration).filter { !replaced.contains($0.0) }.reduce(Data()) { $0 + $1.1 } + data
    }
    public func merging(_ changes: SteamVideoPreferences) throws -> SteamVideoPreferences {
        try SteamVideoPreferences(changes.applying(to: data))
    }
    private static func fields(_ data: Data) throws -> [(Int, Data)] {
        guard data.count <= 65536 else { throw DiscoveryError.malformed }
        let bytes = Array(data); var offset = 0; var result: [(Int,Data)] = []
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { throw DiscoveryError.malformed }
                let byte = bytes[offset]; offset += 1
                guard shift != 63 || byte <= 1 else { throw DiscoveryError.malformed }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw DiscoveryError.malformed
        }
        while offset < bytes.count {
            let start = offset, tag = try varint(), field = tag >> 3
            guard field > 0, field <= 0x1fffffff else { throw DiscoveryError.malformed }
            var size = 0
            switch tag & 7 {
            case 0: _ = try varint()
            case 1: size = 8
            case 2:
                let count = try varint()
                guard count <= UInt64(bytes.count - offset) else { throw DiscoveryError.malformed }
                size = Int(count)
            case 5: size = 4
            default: throw DiscoveryError.malformed
            }
            guard size <= bytes.count - offset else { throw DiscoveryError.malformed }
            offset += size
            result.append((Int(field), Data(bytes[start..<offset])))
        }
        return result
    }
}

import Foundation
#if canImport(SteamCrypto)
import SteamCrypto
#endif

/// Bounded Steam Remote Play UDP header and Castagnoli checksum.
struct SteamSessionPacket {
    var type: UInt8
    var retry: UInt8 = 0
    var source: UInt8
    var destination: UInt8
    var channel: UInt8
    var fragment: Int16 = 0
    var id: UInt16 = 0
    var timestamp: UInt32 = UInt32(truncatingIfNeeded: UInt64(ProcessInfo.processInfo.systemUptime * 65536))
    var body: Data
    static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        Data((0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func crc32c(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { steam_crc32c($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
    }
    func encoded() -> Data {
        var result = Data([type | 0x80, retry, source, destination, channel])
        result += Self.littleEndian(fragment)
        result += Self.littleEndian(id)
        result += Self.littleEndian(timestamp)
        result += body
        result += Self.littleEndian(Self.crc32c(result))
        return result
    }
    init(type: UInt8, source: UInt8, destination: UInt8, channel: UInt8, id: UInt16 = 0, body: Data) {
        self.type = type; self.source = source; self.destination = destination
        self.channel = channel; self.id = id; self.body = body
    }
    init(_ data: Data) throws {
        guard (13...65507).contains(data.count) else { throw DiscoveryError.malformed }
        self = try data.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        func number(_ offset: Int, _ count: Int) -> UInt32 {
            (0..<count).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
        }
        let hasCRC = bytes[0] & 0x80 != 0
        guard !hasCRC || bytes.count >= 17 else { throw DiscoveryError.malformed }
        let end = bytes.count - (hasCRC ? 4 : 0)
        guard !hasCRC || steam_crc32c(bytes.baseAddress, end) == number(end, 4) else { throw DiscoveryError.malformed }
        var packet = SteamSessionPacket(type: bytes[0] & 0x7f, source: bytes[2], destination: bytes[3], channel: bytes[4],
            id: UInt16(number(7, 2)), body: Data(bytes: bytes.baseAddress!.advanced(by: 13), count: end - 13))
        packet.retry = bytes[1]
        packet.fragment = Int16(bitPattern: UInt16(number(5, 2)))
        packet.timestamp = number(9, 4)
        return packet
        }
    }
}

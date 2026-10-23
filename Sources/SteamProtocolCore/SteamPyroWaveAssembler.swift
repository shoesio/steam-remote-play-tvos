import Foundation

/// Reconstructs an image by Steam's 16-bit data-packet IDs. The 8-bit
/// transport-fragment offset wraps at 256 and can restart inside a codec block;
/// transport group boundaries are therefore not codec packet boundaries.
struct SteamPyroWaveAssembler {
    static func sequenceDimensions(_ packet: Data) -> (width: UInt64, height: UInt64)? {
        guard packet.count >= 8 else { return nil }
        let word = packet.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[$1]) << ($1 * 8) }
        }
        guard word & 0x80000000 != 0 else { return nil }
        return (UInt64((word & 0x3fff) + 1), UInt64(((word >> 14) & 0x3fff) + 1))
    }
    private var packets: [UInt16: Data] = [:]
    private var frameTimestamp: UInt32?
    private var expectedPackets: UInt16?
    private var completed = false
    private var byteCount = 0
    private let maximumBytes = 4 * 1024 * 1024
    private(set) var incompleteGroups = 0

    mutating func add(_ body: Data) throws -> Data? {
        guard body.count >= 19 else { throw DiscoveryError.malformed }
        let (timestamp, flags, id, length) = try body.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            guard b[0] == 1 else { throw DiscoveryError.malformed }
            let timestamp = (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[3 + $1]) << ($1 * 8) }
            return (timestamp, b[13], UInt16(b[15]) | UInt16(b[16]) << 8, Int(b[17]) | Int(b[18]) << 8)
        }
        if let previous = frameTimestamp, timestamp != previous {
            guard Int32(bitPattern: timestamp &- previous) > 0 else { return nil }
            if !completed && !packets.isEmpty { incompleteGroups += 1 }
            packets.removeAll(keepingCapacity: true)
            expectedPackets = nil; completed = false; byteCount = 0
        }
        frameTimestamp = timestamp
        guard !completed else { return nil }
        // Redundancy shards use a separate index space. They do not contribute
        // bytes to the codec stream; packet-loss recovery remains separate.
        if flags == 1 { return nil }
        guard length == body.count - 19, id < 8192 else { throw DiscoveryError.malformed }
        if flags == 0x10 {
            guard length == 0 else { throw DiscoveryError.malformed }
            expectedPackets = id
        } else {
            guard flags & ~6 == 0 else { throw DiscoveryError.malformed }
            if packets[id] == nil {
                guard length <= maximumBytes - byteCount else { throw DiscoveryError.malformed }
                packets[id] = Data(body.suffix(length)); byteCount += length
            }
        }
        guard let expectedPackets, expectedPackets > 0,
              packets.count == Int(expectedPackets),
              (0..<expectedPackets).allSatisfy({ packets[$0] != nil }) else { return nil }
        var image = Data(); image.reserveCapacity(byteCount)
        for id in 0..<expectedPackets { image += packets[id]! }
        packets.removeAll(keepingCapacity: true); byteCount = 0; completed = true
        // Steam's first image packet carries a ten-byte descriptor. Verify it
        // against the following PyroWave sequence header before stripping it.
        if image.count >= 18, image[0] == 0x0a, image[1] == 2 {
            let width = UInt32(image[2]) | UInt32(image[3]) << 8
            let height = UInt32(image[4]) | UInt32(image[5]) << 8
            let sequence = (0..<4).reduce(UInt32(0)) { $0 | UInt32(image[10 + $1]) << ($1 * 8) }
            if sequence & 0x80000000 != 0, (sequence & 0x3fff) + 1 == width,
               ((sequence >> 14) & 0x3fff) + 1 == height { image = Data(image.dropFirst(10)) }
        }
        return image
    }
}

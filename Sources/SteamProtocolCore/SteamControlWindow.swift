import Foundation

/// Ordered, bounded reassembly for reliable Steam control packets.
struct SteamControlWindow {
    private(set) var nextID: UInt16 = 0
    private var packets: [UInt16: SteamSessionPacket] = [:]
    private let capacity: Int
    private let maximumFrameBytes: Int
    private let firstType: UInt8
    private let fragmentType: UInt8
    init(firstType: UInt8 = 5, fragmentType: UInt8 = 6, capacity: Int = 512, maximumFrameBytes: Int = 1024 * 1024) {
        self.firstType = firstType; self.fragmentType = fragmentType
        self.capacity = capacity; self.maximumFrameBytes = maximumFrameBytes
    }
    var hasPendingPackets: Bool { !packets.isEmpty }
    mutating func reset(nextID: UInt16) {
        self.nextID = nextID; packets.removeAll(keepingCapacity: true)
    }
    mutating func add(_ packet: SteamSessionPacket) throws -> [Data] {
        guard packet.type == firstType || packet.type == fragmentType, packet.fragment >= 0,
              packet.fragment < capacity else { throw DiscoveryError.malformed }
        let distance = Int16(bitPattern: packet.id &- nextID)
        if distance < 0 { return [] }
        guard distance < capacity else { throw DiscoveryError.malformed }
        if packets[packet.id] == nil { packets[packet.id] = packet }
        var frames: [Data] = []
        while let first = packets[nextID] {
            guard first.type == firstType else { throw DiscoveryError.malformed }
            let count = Int(first.fragment) + 1
            guard packets[nextID &+ UInt16(count - 1)] != nil else { break }
            var parts: [Data] = []
            var totalBytes = 0
            var complete = true
            for index in 0..<count {
                guard let part = packets[nextID &+ UInt16(index)] else { complete = false; break }
                if index > 0 {
                    guard part.type == fragmentType, part.fragment == index - 1 else { throw DiscoveryError.malformed }
                }
                guard part.body.count <= maximumFrameBytes - totalBytes else { throw DiscoveryError.malformed }
                totalBytes += part.body.count; parts.append(part.body)
            }
            guard complete else { break }
            var body = Data(); body.reserveCapacity(totalBytes)
            for part in parts { body += part }
            for index in 0..<count { packets.removeValue(forKey: nextID &+ UInt16(index)) }
            nextID &+= UInt16(count)
            frames.append(body)
        }
        return frames
    }
}

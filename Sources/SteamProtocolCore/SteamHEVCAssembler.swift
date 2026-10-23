import Foundation

/// Steam's video subframe header precedes each HEVC NAL fragment.
/// This initial receiver deliberately fails on missing/encrypted subframes;
/// packet-loss recovery is implemented before it becomes a playback transport.
struct SteamHEVCAssembler {
    var hasPartialFrame: Bool { !buffer.isEmpty }
    private(set) var timestamp: UInt32 = 0
    mutating func reset() { sequence = nil; nextSubframe = 0; buffer.removeAll(keepingCapacity: true) }
    private var sequence: UInt16?
    private var nextSubframe: UInt16 = 0
    private var buffer = Data()
    private let maximumBytes = 2 * 1024 * 1024
    mutating func add(_ data: Data) throws -> Data? {
        let bytes = Array(data)
        guard bytes.count >= 20, bytes[0] == 1 else { throw DiscoveryError.malformed }
        func word(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
        if buffer.isEmpty { timestamp = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[3 + $1]) << ($1 * 8) } }
        let current = word(13), flags = bytes[15], start = word(16), end = word(18)
        if flags & 0x10 != 0 { sequence = current; nextSubframe = 0; buffer.removeAll(keepingCapacity: true) }
        guard sequence == nil || sequence == current, flags & 0x20 == 0,
              end == 0 || start == nextSubframe else { throw DiscoveryError.malformed }
        sequence = current &+ 1
        var payload = Array(bytes.dropFirst(20))
        if flags & 2 != 0 {
            var escaped: [UInt8] = []
            for byte in payload {
                if escaped.count >= 2, byte <= 3, escaped[escaped.count - 1] == 0, escaped[escaped.count - 2] == 0 { escaped.append(3) }
                escaped.append(byte)
            }
            payload = escaped
            if flags & 1 != 0 { payload.insert(contentsOf: [0, 0, 0, 1], at: 0) }
        }
        guard payload.count <= maximumBytes - buffer.count else { throw DiscoveryError.malformed }
        buffer += Data(payload)
        if end != 0, flags & 4 != 0 { nextSubframe = flags & 8 != 0 ? 0 : end &+ 1 }
        guard flags & 8 != 0 else { return nil }
        let frame = buffer; buffer.removeAll(keepingCapacity: true)
        return frame
    }
    static func nalTypes(_ data: Data) -> [UInt8] {
        annexBNALs(data).compactMap { $0.first.map { ($0 >> 1) & 63 } }
    }
    static func annexBNALs(_ data: Data) -> [Data] {
        let bytes = Array(data)
        var starts: [(Int, Int)] = [], i = 0
        while i + 3 <= bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 { starts.append((i, i + 3)); i += 3; continue }
                if i + 4 <= bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 { starts.append((i, i + 4)); i += 4; continue }
            }
            i += 1
        }
        return starts.enumerated().compactMap { index, start in
            let end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            guard start.1 < end else { return nil }
            return Data(bytes[start.1..<end])
        }
    }
}

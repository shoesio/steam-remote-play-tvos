import Foundation

/// The small proto2 wire subset needed for Steam discovery. Unknown scalar fields
/// are skipped; groups and malformed lengths are rejected before allocation.
struct ProtoMessage {
    enum Value { case integer(UInt64), bytes(Data) }
    var fields: [Int: [Value]] = [:]

    init(_ data: Data) throws {
        let bytes = Array(data)
        var offset = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { throw DiscoveryError.malformed }
                let byte = bytes[offset]; offset += 1
                if shift == 63 && byte > 1 { throw DiscoveryError.malformed }
                result |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return result }
            }
            throw DiscoveryError.malformed
        }
        func read(_ count: Int) throws -> Data {
            guard count >= 0, count <= bytes.count - offset else { throw DiscoveryError.malformed }
            defer { offset += count }
            return Data(bytes[offset..<(offset + count)])
        }
        while offset < bytes.count {
            let tag = try varint()
            guard tag >> 3 > 0, tag >> 3 <= 0x1fff_ffff else { throw DiscoveryError.malformed }
            let field = Int(tag >> 3)
            let value: Value
            switch tag & 7 {
            case 0: value = .integer(try varint())
            case 1: value = .bytes(try read(8))
            case 2:
                let count = try varint()
                guard count <= UInt64(bytes.count - offset) else { throw DiscoveryError.malformed }
                value = .bytes(try read(Int(count)))
            case 5: value = .bytes(try read(4))
            default: throw DiscoveryError.malformed
            }
            fields[field, default: []].append(value)
        }
    }
    func integer(_ field: Int) -> UInt64? {
        guard case .integer(let value) = fields[field]?.last else { return nil }
        return value
    }
    func string(_ field: Int) -> String? {
        guard case .bytes(let data) = fields[field]?.last else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func bytes(_ field: Int) -> Data? {
        guard case .bytes(let data) = fields[field]?.last else { return nil }
        return data
    }
    func fixed64(_ field: Int) -> UInt64? {
        guard let data = bytes(field), data.count == 8 else { return nil }
        return data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
    }
    static func varint(_ input: UInt64) -> Data {
        var value = input; var result = Data()
        while value >= 128 { result.append(UInt8(value & 127) | 128); value >>= 7 }
        result.append(UInt8(value)); return result
    }
    static func integer(_ field: Int, _ value: UInt64) -> Data {
        varint(UInt64(field << 3)) + varint(value)
    }
    static func bytes(_ field: Int, _ value: Data) -> Data {
        varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value
    }
}

public enum DiscoveryError: Error { case malformed, invalidStatus }

public struct SteamHostStatus: Equatable, Sendable {
    public let clientID: UInt64
    public let instanceID: UInt64
    public let hostname: String
    public let protocolVersion: UInt64
    public let minimumVersion: UInt64
    public let connectPort: UInt16?
    public let enabledServices: UInt64
    public let universe: UInt64
    public var gamesRunning: Bool? = nil
}

public enum DiscoveryEvent: Equatable, Sendable {
    case status(SteamHostStatus)
    case offline(UInt64)
    case ignored
}

public enum DiscoveryPacket {
    public static let magic = Data([0xff, 0xff, 0xff, 0xff, 0x21, 0x4c, 0x5f, 0xa0])
    public static func request(clientID: UInt64, sequence: UInt32) -> Data {
        envelope(header: ProtoMessage.integer(1, clientID) + ProtoMessage.integer(2, 0),
                 payload: ProtoMessage.integer(1, UInt64(sequence)))
    }
    static func envelope(header: Data, payload: Data) -> Data {
        func length(_ value: Int) -> Data {
            let n = UInt32(value)
            return Data((0..<4).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) })
        }
        return magic + length(header.count) + header + length(payload.count) + payload
    }
    static func decode(_ data: Data) throws -> (header: ProtoMessage, payload: Data) {
        let bytes = Array(data)
        guard bytes.count >= 16, Data(bytes.prefix(8)) == magic else { throw DiscoveryError.malformed }
        var offset = 8
        func blob() throws -> Data {
            guard bytes.count - offset >= 4 else { throw DiscoveryError.malformed }
            let count = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
            offset += 4
            guard UInt64(count) <= UInt64(bytes.count - offset) else { throw DiscoveryError.malformed }
            defer { offset += Int(count) }
            return Data(bytes[offset..<(offset + Int(count))])
        }
        let header = try ProtoMessage(blob())
        let payload = try blob()
        guard offset == bytes.count else { throw DiscoveryError.malformed }
        return (header, payload)
    }
    public static func parse(_ data: Data) throws -> DiscoveryEvent {
        let (header, payload) = try decode(data)
        switch header.integer(2) ?? 0 {
        case 1:
            let status = try ProtoMessage(payload)
            guard let id = header.integer(1), id != 0,
                  let hostname = status.string(4), !hostname.isEmpty,
                  let services = status.integer(6) else { throw DiscoveryError.invalidStatus }
            guard services & 2 != 0 else { return .ignored }
            let port = status.integer(3).flatMap { $0 > 0 && $0 <= 65535 ? UInt16($0) : nil }
            return .status(SteamHostStatus(clientID: id, instanceID: header.integer(3) ?? 0,
                hostname: hostname, protocolVersion: status.integer(1) ?? 0,
                minimumVersion: status.integer(2) ?? 0, connectPort: port,
                enabledServices: services, universe: status.integer(11) ?? 0,
                gamesRunning: status.integer(14).map { $0 != 0 }))
        case 2:
            guard let id = header.integer(1), id != 0 else { throw DiscoveryError.malformed }
            return .offline(id)
        default: return .ignored
        }
    }
}

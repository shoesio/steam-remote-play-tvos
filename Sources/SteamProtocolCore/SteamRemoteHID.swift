import Foundation

/// Steam's generic SDL gamepad report, shared by RemoteHID implementations.
public struct SteamGamepadState: Equatable, Sendable {
    public var axes: [Int16]
    public var buttons: UInt16
    public init(axes: [Int16] = Array(repeating: 0, count: 6), buttons: UInt16 = 0) {
        self.axes = Array((axes + Array(repeating: 0, count: 6)).prefix(6)); self.buttons = buttons
    }
    public func report(version: UInt8 = 0, length: Int = 48) -> Data {
        var bytes = [UInt8](repeating: 0, count: 48)
        for (i, axis) in axes.enumerated() {
            let value = UInt16(bitPattern: axis)
            bytes[i * 2] = UInt8(truncatingIfNeeded: value); bytes[i * 2 + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        bytes[16] = UInt8(truncatingIfNeeded: buttons); bytes[17] = UInt8(truncatingIfNeeded: buttons >> 8)
        bytes[27] = version
        return Data(bytes.prefix(min(48, max(0, length))))
    }
    public static func axis(_ value: Float, deadzone: Float) -> Int16 {
        guard value.isFinite, deadzone.isFinite else { return 0 }
        let threshold = min(0.95, max(0, deadzone))
        let magnitude = min(1, abs(value))
        guard magnitude > threshold else { return 0 }
        let mapped = (magnitude - threshold) / (1 - threshold)
        return Int16((value < 0 ? -mapped * 32768 : mapped * 32767).rounded())
    }
}

/// Confined to the Steam session queue. No platform controller objects cross it.
struct SteamRemoteHID {
    private struct Device {
        var state = SteamGamepadState()
        var handle: UInt64?
        var reportLength = 0
        var version: UInt8 = 0
    }
    private var devices: [Int: Device] = [:]
    private var nextHandle: UInt64 = 1
    mutating func setSlots(_ slots: [Int]) -> Data {
        let available = Set(slots.filter { (0..<4).contains($0) })
        devices = devices.filter { available.contains($0.key) }
        for slot in available where devices[slot] == nil { devices[slot] = Device() }
        let list = devices.keys.sorted().reduce(Data()) { $0 + ProtoMessage.bytes(1, Self.info(slot: $1)) }
        return ProtoMessage.bytes(1, list)
    }
    static func info(slot: Int) -> Data {
        var data = Data()
        for (field, value): (Int, UInt64) in [(1, 2), (3, 0x045e), (4, 0x028e), (9, 1), (10, 5), (13, 1), (15, 0)] {
            data += ProtoMessage.integer(field, value)
        }
        for (field, value) in [(2, "sdl://steamtv/\(slot)"), (5, "SteamTV-\(slot)"), (7, "Apple"), (8, "Apple TV Gamepad \(slot + 1)")] {
            data += ProtoMessage.bytes(field, Data(value.utf8))
        }
        return data
    }
    mutating func update(slot: Int, state: SteamGamepadState) -> Data? {
        guard var device = devices[slot], device.state != state else { return nil }
        device.state = state; devices[slot] = device
        return report(device)
    }
    private func report(_ device: Device) -> Data? {
        guard let handle = device.handle, device.reportLength > 0 else { return nil }
        let full = ProtoMessage.bytes(1, device.state.report(version: device.version, length: device.reportLength))
        let deviceReport = ProtoMessage.integer(1, handle) + ProtoMessage.bytes(2, full)
        return ProtoMessage.bytes(3, ProtoMessage.bytes(1, deviceReport))
    }
    private func response(_ id: UInt64, result: UInt64 = 0, data: Data? = nil) -> Data {
        var response = ProtoMessage.integer(1, id) + ProtoMessage.integer(2, result)
        if let data { response += ProtoMessage.bytes(3, data) }
        return ProtoMessage.bytes(2, response)
    }
    mutating func receive(_ data: Data) throws -> [Data] {
        let message = try ProtoMessage(data)
        let request = message.integer(1) ?? 0
        guard let command = (2...13).first(where: { message.bytes($0) != nil }), let body = message.bytes(command) else { return [] }
        let parameters = try ProtoMessage(body)
        if command == 2 {
            guard let encoded = parameters.bytes(1), let path = try ProtoMessage(encoded).bytes(2),
                  let slot = devices.keys.first(where: { path == Data("sdl://steamtv/\($0)".utf8) }) else {
                return [response(request, result: UInt64.max)]
            }
            devices[slot]?.handle = nextHandle; nextHandle += 1
            return [response(request, result: devices[slot]!.handle!)]
        }
        guard let handle = parameters.integer(1), let slot = devices.keys.first(where: { devices[$0]?.handle == handle }), var device = devices[slot] else {
            return [response(request, result: UInt64.max)]
        }
        switch command {
        case 3, 13:
            device.handle = nil; device.reportLength = 0; devices[slot] = device; return []
        case 4:
            let bytes = Array(parameters.bytes(2) ?? Data())
            if bytes.count >= 2, bytes[0] == 9 { device.version = bytes[1]; devices[slot] = device }
            return []
        case 5:
            return [response(request, data: device.state.report(version: device.version, length: Int(min(48, parameters.integer(2) ?? 48))))]
        case 7:
            guard let number = parameters.bytes(2)?.first else { return [response(request, result: UInt64.max)] }
            var data: Data
            switch number {
            case 4:
                // valid, non-XInput, Xbox360 mapping, player index, non-HID, padding.
                data = Data([4, 1, 0, 31, 0, 0, 0, UInt8(slot), 0, 0, 0, 0] + Array(repeating: 0, count: 9))
            case 2: data = Data([2, 3]) // SDL wired power state
            case 7: data = Data([7]) + Data("SteamTV-\(slot)\0".utf8)
            default: return [response(request, result: UInt64.max)]
            }
            data = Data(data.prefix(Int(min(256, parameters.integer(3) ?? 256))))
            return [response(request, data: data)]
        case 8, 9, 10:
            let string = command == 8 ? "Apple" : command == 9 ? "Apple TV Gamepad" : "SteamTV-\(slot)"
            return [response(request, data: Data((string + "\0").utf8))]
        case 11:
            device.reportLength = Int(min(48, parameters.integer(2) ?? 48)); devices[slot] = device
            return report(device).map { [$0] } ?? []
        case 12: return report(device).map { [$0] } ?? []
        default: return [response(request, result: UInt64.max)]
        }
    }
}

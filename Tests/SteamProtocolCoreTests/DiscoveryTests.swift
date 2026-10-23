import XCTest
@testable import SteamProtocolCore

final class DiscoveryTests: XCTestCase {
    private func string(_ field: Int, _ value: String) -> Data {
        let data = Data(value.utf8)
        return ProtoMessage.varint(UInt64(field << 3 | 2)) + ProtoMessage.varint(UInt64(data.count)) + data
    }
    private func status(services: UInt64 = 2, gamesRunning: Bool? = nil) -> Data {
        let header = ProtoMessage.integer(1, 123456) + ProtoMessage.integer(2, 1) + ProtoMessage.integer(3, 99)
        var payload = ProtoMessage.integer(1, 10) + ProtoMessage.integer(2, 6)
            + ProtoMessage.integer(3, 27037) + string(4, "BC-250")
            + ProtoMessage.integer(6, services) + ProtoMessage.integer(11, 1)
            + string(100, "unknown extension")
        if let gamesRunning { payload += ProtoMessage.integer(14, gamesRunning ? 1 : 0) }
        return DiscoveryPacket.envelope(header: header, payload: payload)
    }
    func testRequestWireBytes() throws {
        XCTAssertEqual(DiscoveryPacket.request(clientID: 1, sequence: 7),
            Data([255,255,255,255,33,76,95,160,4,0,0,0,8,1,16,0,2,0,0,0,8,7]))
    }
    func testStatusAndUnknownFields() throws {
        guard case .status(let host) = try DiscoveryPacket.parse(status()) else { return XCTFail() }
        XCTAssertEqual(host.hostname, "BC-250")
        XCTAssertEqual(host.clientID, 123456)
        XCTAssertEqual(host.instanceID, 99)
        XCTAssertEqual(host.protocolVersion, 10)
        XCTAssertEqual(host.minimumVersion, 6)
        XCTAssertEqual(host.connectPort, 27037)
        XCTAssertEqual(host.universe, 1)
    }
    func testGameRunningStatusDistinguishesUnknownFromStopped() throws {
        for value: Bool? in [nil, false, true] {
            guard case .status(let host) = try DiscoveryPacket.parse(status(gamesRunning: value)) else { return XCTFail() }
            XCTAssertEqual(host.gamesRunning, value)
        }
    }
    func testNonStreamingSteamClientsIgnored() throws {
        XCTAssertEqual(try DiscoveryPacket.parse(status(services: 1)), .ignored)
    }
    func testEveryTruncationRejected() {
        let packet = status()
        for length in 0..<packet.count {
            XCTAssertThrowsError(try DiscoveryPacket.parse(Data(packet.prefix(length))), "length \(length)")
        }
    }
    func testOversizeAndTrailingDataRejected() {
        var packet = status()
        packet.replaceSubrange(8..<12, with: [255,255,255,255])
        XCTAssertThrowsError(try DiscoveryPacket.parse(packet))
        XCTAssertThrowsError(try DiscoveryPacket.parse(status() + Data([0])))
    }
    func testVarintOverflowAndIllegalFieldRejected() {
        XCTAssertThrowsError(try ProtoMessage(Data([8] + Array(repeating: 255, count: 9) + [2])))
        XCTAssertThrowsError(try ProtoMessage(Data([0, 1])))
        XCTAssertThrowsError(try ProtoMessage(Data([11]))) // unsupported group
    }
    func testOfflineAndExpiryAndReconnect() throws {
        let event = try DiscoveryPacket.parse(status())
        var registry = HostRegistry(timeout: 15)
        registry.receive(event, address: "192.0.2.1", port: 27036, now: 0)
        XCTAssertEqual(registry.hosts.count, 1)
        registry.receive(event, address: "192.0.2.2", port: 27036, now: 3)
        XCTAssertEqual(registry.hosts.count, 1)
        XCTAssertEqual(registry.hosts[123456]?.address, "192.0.2.2")
        registry.expire(now: 17.9)
        XCTAssertEqual(registry.hosts[123456]?.online, true)
        registry.expire(now: 18)
        XCTAssertEqual(registry.hosts[123456]?.online, false)
        registry.receive(event, address: "192.0.2.2", port: 27036, now: 19)
        XCTAssertEqual(registry.hosts[123456]?.online, true)
        let offline = DiscoveryPacket.envelope(header: ProtoMessage.integer(1, 123456) + ProtoMessage.integer(2, 2), payload: Data())
        registry.receive(try DiscoveryPacket.parse(offline), address: "192.0.2.2", port: 27036, now: 20)
        XCTAssertEqual(registry.hosts[123456]?.online, false)
    }
    func testRandomDatagramsDoNotCrash() {
        var generator: UInt64 = 0x7654321
        for count in 0..<512 {
            let data = Data((0..<count).map { _ in
                generator = generator &* 6364136223846793005 &+ 1
                return UInt8(truncatingIfNeeded: generator >> 32)
            })
            _ = try? DiscoveryPacket.parse(data)
            _ = try? ProtoMessage(data)
        }
    }
    func testOnlyHEVCAdvertised() {
        XCTAssertEqual(SteamVideoCodec.supported, [.hevc])
    }
}

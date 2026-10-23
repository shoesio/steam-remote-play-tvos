import XCTest
@testable import SteamProtocolCore

final class SessionPacketTests: XCTestCase {
    func testNativeCRCHandlesWordBoundariesAndDatagramLengths() {
        for count in [0, 1, 7, 8, 9, 17, 1420, 65500] {
            let data = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 17) })
            var expected = UInt32.max
            for byte in data {
                expected ^= UInt32(byte)
                for _ in 0..<8 { expected = (expected >> 1) ^ (expected & 1 == 0 ? 0 : 0x82f63b78) }
            }
            XCTAssertEqual(SteamSessionPacket.crc32c(data), ~expected)
        }
    }
    func testModernMediaTypeStillValidatesChecksumAndBounds() throws {
        let packet = SteamSessionPacket(type: 12, source: 1, destination: 2, channel: 4,
                                        body: Data(repeating: 1, count: 1400))
        let decoded = try SteamSessionPacket(packet.encoded())
        XCTAssertEqual(decoded.type, 12)
        XCTAssertEqual(decoded.channel, 4)
        XCTAssertEqual(decoded.body, packet.body)
        var corrupted = packet.encoded(); corrupted[20] ^= 1
        XCTAssertThrowsError(try SteamSessionPacket(corrupted))
        XCTAssertThrowsError(try SteamSessionPacket(Data(repeating: 12, count: 65508)))
    }
    func testCRC32CAndMalformedPackets() throws {
        XCTAssertEqual(SteamSessionPacket.crc32c(Data("123456789".utf8)), 0xe3069283)
        let packet = SteamSessionPacket(type: 1, source: 7, destination: 0, channel: 0, body: Data([0xc7, 0x3d, 0x8f, 0x3c]))
        let decoded = try SteamSessionPacket(packet.encoded())
        XCTAssertEqual(decoded.type, 1)
        XCTAssertEqual(decoded.source, 7)
        XCTAssertEqual(decoded.body, packet.body)
        for length in 0..<17 { XCTAssertThrowsError(try SteamSessionPacket(Data(repeating: 0x81, count: length))) }
        var corrupted = packet.encoded(); corrupted[13] ^= 1
        XCTAssertThrowsError(try SteamSessionPacket(corrupted))
    }
    func testAuthenticatedFrameAgainstOpenSSLVector() throws {
        let hex = "ce175a955097c66e4de939eeb02ddf652fbbe3aa4928dd31342a8b9912fc1646"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        let key = Data(0..<16)
        XCTAssertEqual(try SteamCryptography.encryptFrame(Data([24, 5]), sequence: 0, key: key), Data(bytes))
        let frame = try SteamCryptography.decryptFrame(Data(bytes), key: key)
        XCTAssertEqual(frame.sequence, 0)
        XCTAssertEqual(frame.payload, Data([24, 5]))
        var tampered = Data(bytes); tampered[0] ^= 1
        XCTAssertThrowsError(try SteamCryptography.decryptFrame(tampered, key: key))
        XCTAssertThrowsError(try SteamCryptography.decryptFrame(Data(bytes), key: Data(repeating: 0, count: 16)))
    }
}

extension SessionPacketTests {
    func testControlFragmentsReassembleInOrderAndIgnoreDuplicates() throws {
        var window = SteamControlWindow()
        var first = SteamSessionPacket(type: 5, source: 1, destination: 2, channel: 1, id: 0, body: Data([1, 2]))
        first.fragment = 2
        var middle = SteamSessionPacket(type: 6, source: 1, destination: 2, channel: 1, id: 1, body: Data([3, 4]))
        middle.fragment = 0
        var last = SteamSessionPacket(type: 6, source: 1, destination: 2, channel: 1, id: 2, body: Data([5]))
        last.fragment = 1
        XCTAssertEqual(try window.add(last), [])
        XCTAssertEqual(try window.add(first), [])
        XCTAssertEqual(try window.add(middle), [Data([1, 2, 3, 4, 5])])
        XCTAssertEqual(window.nextID, 3)
        XCTAssertEqual(try window.add(first), [])
        var oversized = first; oversized.id = 3; oversized.fragment = 512
        XCTAssertThrowsError(try window.add(oversized))
    }
    func testPyroWaveConfigurationAdvertisesCodec9AndExplicitEnable() throws {
        let request = try ProtoMessage(SteamStreamingSession.videoConfiguration(codec: .pyrowave))
        let client = try ProtoMessage(XCTUnwrap(request.bytes(2)))
        let caps = try ProtoMessage(XCTUnwrap(request.bytes(3)))
        XCTAssertEqual(try ProtoMessage(XCTUnwrap(request.bytes(1))).integer(3), 9)
        XCTAssertEqual(client.integer(35), 1)
        XCTAssertEqual(caps.integer(15), 9)
        XCTAssertEqual(try ProtoMessage(XCTUnwrap(client.bytes(21))).integer(3), 300000)
    }
    func test4KPyroWaveCustomBitrateRequest() throws {
        let request = try ProtoMessage(SteamStreamingSession.videoConfiguration(codec: .pyrowave, width: 3840, height: 2160, bitrateKbps: 300000))
        let client = try ProtoMessage(XCTUnwrap(request.bytes(2)))
        XCTAssertEqual(client.integer(2), 3840)
        XCTAssertEqual(client.integer(3), 2160)
        XCTAssertEqual(client.integer(6), 300000)
        XCTAssertEqual(client.integer(36), 1)
        XCTAssertEqual(client.integer(37), 300000)
    }
    func testWiredPyroRateOverridesSavedAutomaticRateWithoutChangingQuality() throws {
        let saved = try SteamVideoPreferences(ProtoMessage.integer(1, 1) + ProtoMessage.integer(2, 1920) + ProtoMessage.integer(3, 1080) + ProtoMessage.integer(6, UInt64.max) + ProtoMessage.integer(36, 0) + ProtoMessage.integer(37, 100000))
        let request = try ProtoMessage(SteamStreamingSession.videoConfiguration(codec: .pyrowave, width: 3840, height: 2160, hostManaged: true, wiredPyroBitrateKbps: 250000, videoPreferences: saved))
        let client = try ProtoMessage(XCTUnwrap(request.bytes(2)))
        XCTAssertEqual(client.integer(1), 1)
        XCTAssertEqual(client.integer(2), 3840)
        XCTAssertEqual(client.integer(3), 2160)
        XCTAssertEqual(client.integer(6), 250000)
        XCTAssertEqual(client.integer(36), 1)
        XCTAssertEqual(client.integer(37), 250000)
        XCTAssertEqual(client.fields[36]?.count, 1)
        for field in [21, 22, 23, 24] {
            let limit = try ProtoMessage(XCTUnwrap(client.bytes(field)))
            let mode = try ProtoMessage(XCTUnwrap(limit.bytes(2)))
            XCTAssertEqual(mode.integer(1), 3840)
            XCTAssertEqual(mode.integer(2), 2160)
        }
        XCTAssertEqual(client.fields[22]?.count, 1)
        let hevc = try ProtoMessage(SteamStreamingSession.videoConfiguration(codec: .hevc, hostManaged: true, wiredPyroBitrateKbps: 250000))
        let hevcClient = try ProtoMessage(XCTUnwrap(hevc.bytes(2)))
        XCTAssertNil(hevcClient.integer(36))
        XCTAssertEqual(hevcClient.integer(6), UInt64.max)
    }
    func testModernHEVCCapabilitiesAndExactVideoSettings() throws {
        let request = try ProtoMessage(SteamStreamingSession.hevcConfiguration())
        let config = try ProtoMessage(XCTUnwrap(request.bytes(1)))
        let client = try ProtoMessage(XCTUnwrap(request.bytes(2)))
        let caps = try ProtoMessage(XCTUnwrap(request.bytes(3)))
        XCTAssertEqual(config.integer(3), SteamVideoCodec.hevc.rawValue)
        XCTAssertEqual(caps.integer(15), SteamVideoCodec.hevc.rawValue)
        XCTAssertEqual(caps.integer(14), 3)
        XCTAssertEqual(client.integer(2), 1920)
        XCTAssertEqual(client.integer(3), 1080)
        XCTAssertEqual(client.integer(4), 60)
        XCTAssertEqual(client.integer(5), 1)
        XCTAssertEqual(client.integer(12), 2)
        XCTAssertEqual(client.integer(13), 1)
        XCTAssertEqual(client.integer(26), 0)
        XCTAssertEqual(client.integer(35), 0)
    }
    func testCodecListsAcceptPackedAndUnpackedFields() throws {
        let unpacked = try ProtoMessage(ProtoMessage.integer(3, 4) + ProtoMessage.integer(3, 5))
        XCTAssertEqual(try SteamStreamingSession.codecs(unpacked), [4, 5])
        let packed = try ProtoMessage(ProtoMessage.bytes(3, Data([4, 5])))
        XCTAssertEqual(try SteamStreamingSession.codecs(packed), [4, 5])
        let malformed = try ProtoMessage(ProtoMessage.bytes(3, Data([128])))
        XCTAssertThrowsError(try SteamStreamingSession.codecs(malformed))
    }
}

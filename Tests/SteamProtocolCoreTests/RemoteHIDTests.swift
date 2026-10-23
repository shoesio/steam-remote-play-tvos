import XCTest
@testable import SteamProtocolCore

final class RemoteHIDTests: XCTestCase {
    func testHostManagedVideoHasCapabilitiesWithoutLocalQualityOverrides() throws {
        let payload = SteamStreamingSession.videoConfiguration(codec: .pyrowave, width: 3840, height: 2160, hostManaged: true)
        let message = try ProtoMessage(payload)
        let client = try ProtoMessage(message.bytes(2)!)
        XCTAssertEqual(client.integer(2), 3840); XCTAssertEqual(client.integer(3), 2160); XCTAssertEqual(client.integer(4), 60)
        XCTAssertEqual(client.integer(6), UInt64.max)
        XCTAssertEqual(client.integer(36), 0); XCTAssertNil(client.integer(37))
        let mode = try ProtoMessage(try ProtoMessage(client.bytes(21)!).bytes(2)!)
        XCTAssertEqual(mode.integer(1), 3840); XCTAssertEqual(mode.integer(2), 2160)
        XCTAssertEqual(try ProtoMessage(message.bytes(1)!).integer(5), 1)
    }
    func testReportLayoutAndDeadzone() {
        let report = Array(SteamGamepadState(axes: [-32768, 32767, 1, -1, 0, 32000], buttons: 0x4001).report(version: 3))
        XCTAssertEqual(report.count, 48)
        XCTAssertEqual(Array(report[0..<4]), [0, 128, 255, 127])
        XCTAssertEqual(Array(report[16..<18]), [1, 64]); XCTAssertEqual(report[27], 3)
        XCTAssertEqual(SteamGamepadState.axis(0.10, deadzone: 0.15), 0)
        XCTAssertEqual(SteamGamepadState.axis(-1, deadzone: 0.15), -32768)
        XCTAssertEqual(SteamGamepadState.axis(1, deadzone: 0.15), 32767)
        XCTAssertEqual(SteamGamepadState.axis(.nan, deadzone: 0.15), 0)
    }
    func testDeviceOpenVersionCapsAndFullReports() throws {
        var hid = SteamRemoteHID()
        let list = try ProtoMessage(try ProtoMessage(hid.setSlots([0])).bytes(1)!)
        let info = try ProtoMessage(list.bytes(1)!)
        XCTAssertEqual(info.integer(13), 1)
        let open = ProtoMessage.integer(1, 7) + ProtoMessage.bytes(2, ProtoMessage.bytes(1, list.bytes(1)!))
        let responses = try hid.receive(open)
        let response = try ProtoMessage(try ProtoMessage(responses[0]).bytes(2)!)
        XCTAssertEqual(response.integer(1), 7); XCTAssertEqual(response.integer(2), 1)
        let version = ProtoMessage.bytes(4, ProtoMessage.integer(1, 1) + ProtoMessage.bytes(2, Data([9, 3])))
        XCTAssertTrue(try hid.receive(version).isEmpty)
        let caps = ProtoMessage.integer(1, 8) + ProtoMessage.bytes(7, ProtoMessage.integer(1, 1) + ProtoMessage.bytes(2, Data([4])) + ProtoMessage.integer(3, 21))
        let capsResponse = try ProtoMessage(try ProtoMessage(hid.receive(caps)[0]).bytes(2)!)
        XCTAssertEqual(capsResponse.bytes(3)?.count, 21); XCTAssertEqual(capsResponse.bytes(3)?[3], 31)
        let begin = ProtoMessage.bytes(11, ProtoMessage.integer(1, 1) + ProtoMessage.integer(2, 48))
        XCTAssertEqual(try hid.receive(begin).count, 1)
        let updated = hid.update(slot: 0, state: SteamGamepadState(buttons: 1))!
        let reports = try ProtoMessage(try ProtoMessage(updated).bytes(3)!)
        let device = try ProtoMessage(reports.bytes(1)!)
        XCTAssertEqual(device.integer(1), 1)
        let report = try ProtoMessage(device.bytes(2)!).bytes(1)!
        XCTAssertEqual(report[16], 1); XCTAssertEqual(report[27], 3)
        XCTAssertNil(hid.update(slot: 0, state: SteamGamepadState(buttons: 1)))
        _ = hid.setSlots([])
        XCTAssertNil(hid.update(slot: 0, state: SteamGamepadState(buttons: 2)))
    }
    func testExitChordSurvivesDelayedDeviceRegistrationAndReleases() throws {
        var hid = SteamRemoteHID()
        let list = try ProtoMessage(try ProtoMessage(hid.setSlots([0])).bytes(1)!)
        XCTAssertNil(hid.update(slot: 0, state: SteamGamepadState(buttons: (1 << 6) | (1 << 4))))
        _ = try hid.receive(ProtoMessage.integer(1, 7) + ProtoMessage.bytes(2, ProtoMessage.bytes(1, list.bytes(1)!)))
        let begin = ProtoMessage.bytes(11, ProtoMessage.integer(1, 1) + ProtoMessage.integer(2, 48))
        func report(_ data: Data) throws -> Data {
            let reports = try ProtoMessage(try ProtoMessage(data).bytes(3)!)
            let device = try ProtoMessage(reports.bytes(1)!)
            return try ProtoMessage(device.bytes(2)!).bytes(1)!
        }
        XCTAssertEqual(try report(hid.receive(begin)[0])[16], 0x50)
        XCTAssertEqual(try report(XCTUnwrap(hid.update(slot: 0, state: SteamGamepadState())))[16], 0)
    }
    func testUnknownDeviceAndFeatureAreRejected() throws {
        var hid = SteamRemoteHID()
        let request = ProtoMessage.integer(1, 9) + ProtoMessage.bytes(7, ProtoMessage.integer(1, 42))
        let response = try ProtoMessage(try ProtoMessage(hid.receive(request)[0]).bytes(2)!)
        XCTAssertEqual(response.integer(2), UInt64.max)
    }
}

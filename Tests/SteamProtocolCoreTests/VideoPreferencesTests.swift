import XCTest
@testable import SteamProtocolCore

final class VideoPreferencesTests: XCTestCase {
    func testOnlyUserChoicesSurviveIncludingCurrentPyroBitrateAndFloat() throws {
        let float = Data([0xb5, 0x02, 0, 0, 0x80, 0x3f]) // field 38, fixed32
        let source = ProtoMessage.integer(1, 3) + ProtoMessage.integer(6, 0)
            + ProtoMessage.integer(25, 1) + ProtoMessage.integer(40, UInt64.max) + float
        let profile = try SteamVideoPreferences(source)
        let parsed = try ProtoMessage(profile.data)
        XCTAssertEqual(parsed.integer(1), 3)
        XCTAssertEqual(parsed.integer(40), UInt64.max)
        XCTAssertNil(parsed.integer(25))
        XCTAssertTrue(profile.data.suffix(float.count) == float)
    }
    func testRestoreKeepsFreshCapabilitiesAndPartialChanges() throws {
        let resolution = ProtoMessage.bytes(22, ProtoMessage.bytes(2, ProtoMessage.integer(1,3840) + ProtoMessage.integer(2,2160)))
        let saved = try SteamVideoPreferences(ProtoMessage.integer(1,3) + ProtoMessage.integer(6,0) + resolution)
        let latest = try saved.merging(SteamVideoPreferences(ProtoMessage.integer(6,300000)))
        let base = try ProtoMessage(SteamStreamingSession.videoConfiguration(codec: .pyrowave, hostManaged: true))
        let client = try ProtoMessage(XCTUnwrap(base.bytes(2)))
        let restored = try ProtoMessage(latest.applying(to: XCTUnwrap(base.bytes(2))))
        XCTAssertEqual(restored.integer(1),3)
        XCTAssertEqual(restored.integer(6),300000)
        XCTAssertNotNil(restored.bytes(22))
        XCTAssertEqual(restored.bytes(24),client.bytes(24))
        XCTAssertEqual(restored.integer(35),1)
    }
    func testRejectsTruncatedAndOversizedProfiles() {
        XCTAssertThrowsError(try SteamVideoPreferences(Data([0x32,0x80])))
        XCTAssertThrowsError(try SteamVideoPreferences(Data(repeating:0,count:65537)))
    }
}

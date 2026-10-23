import XCTest
@testable import SteamProtocolCore

final class AudioDecoderTests: XCTestCase {
    func testNativeOpusStereoSilenceAndPacketBounds() throws {
        let decoder = try OpusStereoDecoder()
        let silence = Data([0xf4, 0xff, 0xfe])
        for _ in 0..<3 {
            let samples = try decoder.decode(silence)
            XCTAssertGreaterThan(samples.count, 0)
            XCTAssertLessThanOrEqual(samples.count, 960)
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && abs($0) < 0.001 })
        }
        XCTAssertThrowsError(try decoder.decode(Data()))
        XCTAssertThrowsError(try decoder.decode(Data(repeating: 0, count: 65536)))
        XCTAssertThrowsError(try OpusStereoDecoder(channels: 6))
    }
}

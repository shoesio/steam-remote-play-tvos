import XCTest
import CoreMedia
@testable import SteamProtocolCore

final class VideoDecoderTests: XCTestCase {
    func testDecoderRejectsOtherCodecsAndIncompleteHEVC() {
        let decoder = HEVCVideoDecoder { _ in XCTFail("Invalid input produced a picture") }
        XCTAssertThrowsError(try decoder.submit(EncodedVideoFrame(codec: .h264, data: Data(), presentationTime: .zero))) { error in
            guard case VideoDecoderError.unsupportedCodec = error else { return XCTFail("Wrong codec rejection") }
        }
        XCTAssertThrowsError(try decoder.submit(EncodedVideoFrame(codec: .hevc, data: Data([0, 0, 1, 0x40, 1]), presentationTime: .zero))) { error in
            guard case VideoDecoderError.missingParameterSets = error else { return XCTFail("Missing parameter sets were not detected") }
        }
        decoder.reset()
        XCTAssertThrowsError(try decoder.submit(EncodedVideoFrame(codec: .hevc, data: Data([0, 0, 1, 0x40]), presentationTime: .zero))) { error in
            guard case VideoDecoderError.malformedFrame = error else { return XCTFail("Truncated NAL was not detected") }
        }
    }
}

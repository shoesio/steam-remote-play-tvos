import XCTest
@testable import SteamProtocolCore

final class VideoAssemblyTests: XCTestCase {
    private func pyroFragment(_ id: UInt16, fragment: UInt8, flags: UInt8, payload: Data) -> Data {
        Data([1]) + Data(repeating: 0, count: 12) + Data([flags, fragment])
            + SteamSessionPacket.littleEndian(id) + SteamSessionPacket.littleEndian(UInt16(payload.count)) + payload
    }
    func testSteamPyroFragmentsAndIndependentPacketsArriveOutOfOrder() throws {
        var assembler = SteamPyroWaveAssembler()
        let independent = pyroFragment(3, fragment: 0, flags: 6, payload: Data([8, 9]))
        XCTAssertNil(try assembler.add(independent))
        XCTAssertNil(try assembler.add(pyroFragment(4, fragment: 0, flags: 0x10, payload: Data())))
        XCTAssertNil(try assembler.add(pyroFragment(2, fragment: 2, flags: 4, payload: Data([5, 6]))))
        XCTAssertNil(try assembler.add(pyroFragment(0, fragment: 0, flags: 2, payload: Data([1, 2]))))
        XCTAssertEqual(try assembler.add(pyroFragment(1, fragment: 1, flags: 0, payload: Data([3, 4]))), Data([1, 2, 3, 4, 5, 6, 8, 9]))
    }
    func testSteamPyroDescriptorRemovedOnlyWhenDimensionsMatchSequence() throws {
        var assembler = SteamPyroWaveAssembler()
        let descriptor = Data([0x0a, 2, 0x80, 7, 0x38, 4, 0, 0, 0, 0])
        let sequence = Data([0x7f, 0xc7, 0x0d, 0x91, 0x0e, 1, 0, 0])
        XCTAssertNil(try assembler.add(pyroFragment(0, fragment: 0, flags: 6, payload: descriptor + sequence)))
        XCTAssertEqual(try assembler.add(pyroFragment(1, fragment: 0, flags: 0x10, payload: Data())), sequence)
        assembler = SteamPyroWaveAssembler()
        var invalid = pyroFragment(1, fragment: 0, flags: 6, payload: sequence)
        invalid[17] ^= 1
        XCTAssertThrowsError(try assembler.add(invalid))
    }
    func testSteamPyroDuplicatesRedundancyAndOldImagesDoNotMix() throws {
        var assembler = SteamPyroWaveAssembler()
        let complete = pyroFragment(0, fragment: 0, flags: 6, payload: Data([7, 8]))
        XCTAssertNil(try assembler.add(complete))
        XCTAssertNil(try assembler.add(complete))
        XCTAssertNil(try assembler.add(pyroFragment(1, fragment: 0, flags: 1, payload: Data([9]))))
        let end = pyroFragment(1, fragment: 0, flags: 0x10, payload: Data())
        XCTAssertEqual(try assembler.add(end), Data([7, 8]))
        var next = complete; next[3] = 1
        XCTAssertNil(try assembler.add(next))
        var nextEnd = end; nextEnd[3] = 1
        XCTAssertEqual(try assembler.add(nextEnd), Data([7, 8]))
        XCTAssertNil(try assembler.add(complete))
    }
    func testLargeImageContinuesAcrossFragmentCounterWrap() throws {
        var assembler = SteamPyroWaveAssembler()
        var expected = Data()
        // A priority packet and the end marker can precede the large group.
        XCTAssertNil(try assembler.add(pyroFragment(279, fragment: 0, flags: 6, payload: Data([99, 100]))))
        XCTAssertNil(try assembler.add(pyroFragment(280, fragment: 0, flags: 0x10, payload: Data())))
        for id in 0..<279 {
            let payload = SteamSessionPacket.littleEndian(UInt16(id))
            expected += payload
            let flags: UInt8 = id == 0 || id == 256 ? 2 : (id == 278 ? 4 : 0)
            let result = try assembler.add(pyroFragment(UInt16(id), fragment: UInt8(truncatingIfNeeded: id), flags: flags, payload: payload))
            if id == 278 { XCTAssertEqual(result, expected + Data([99, 100])) }
            else { XCTAssertNil(result) }
        }
        XCTAssertEqual(assembler.incompleteGroups, 0)
    }
    private func subframe(_ sequence: UInt16, flags: UInt8, start: UInt16 = 0, end: UInt16 = 0, payload: [UInt8]) -> Data {
        Data([1]) + Data(repeating: 0, count: 12) + SteamSessionPacket.littleEndian(sequence)
            + Data([flags]) + SteamSessionPacket.littleEndian(start) + SteamSessionPacket.littleEndian(end) + Data(payload)
    }
    func testHEVCSubframeAssemblyAndEmulationPrevention() throws {
        var assembler = SteamHEVCAssembler()
        XCTAssertNil(try assembler.add(subframe(0, flags: 0x17, start: 0, end: 1, payload: [0x40, 1, 0, 0, 1])))
        let frame = try XCTUnwrap(assembler.add(subframe(1, flags: 0x0f, start: 2, end: 3, payload: [0x26, 1, 0, 0, 2])))
        XCTAssertEqual(frame, Data([0, 0, 0, 1, 0x40, 1, 0, 0, 3, 1, 0, 0, 0, 1, 0x26, 1, 0, 0, 3, 2]))
        XCTAssertEqual(SteamHEVCAssembler.nalTypes(frame), [32, 19])
    }
    func testLossAndInvalidVideoHeadersAreRejected() throws {
        var assembler = SteamHEVCAssembler()
        XCTAssertNil(try assembler.add(subframe(0, flags: 0x10, payload: [0x40, 1])))
        XCTAssertThrowsError(try assembler.add(subframe(2, flags: 8, payload: [0x26, 1])))
        XCTAssertThrowsError(try assembler.add(Data(repeating: 0, count: 19)))
        XCTAssertThrowsError(try assembler.add(subframe(1, flags: 0x20, payload: [0x26, 1])))
    }
    func testUnreliableVideoFragmentReordering() throws {
        var window = SteamControlWindow(firstType: 3, fragmentType: 4, capacity: 2048, maximumFrameBytes: 2 * 1024 * 1024)
        var first = SteamSessionPacket(type: 3, source: 1, destination: 2, channel: 4, id: 0, body: Data([1]))
        first.fragment = 1
        let last = SteamSessionPacket(type: 4, source: 1, destination: 2, channel: 4, id: 1, body: Data([2]))
        XCTAssertEqual(try window.add(last), [])
        XCTAssertEqual(try window.add(first), [Data([1, 2])])
        XCTAssertEqual(try window.add(last), [])
    }
}

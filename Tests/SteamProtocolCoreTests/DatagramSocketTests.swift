import XCTest
import Darwin
@testable import SteamProtocolCore

final class DatagramSocketTests: XCTestCase {
    func testBatchedReceiverDrainsBeyondOneBatchAndCancels() throws {
        let server = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(server, 0)
        defer { Darwin.close(server) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        XCTAssertEqual(withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }, 0)
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &size) }
        }, 0)
        let queue = DispatchQueue(label: "SteamTV.tests.batchedUDP")
        let all = expectation(description: "all 400 datagrams received")
        var received = Set<UInt16>()
        let socket = try SteamDatagramSocket(address: "127.0.0.1", port: UInt16(bigEndian: address.sin_port), queue: queue,
            received: { data in
                guard data.count == 2 else { XCTFail("bad datagram"); return }
                received.insert(UInt16(data[0]) | UInt16(data[1]) << 8)
                if received.count == 400 { all.fulfill() }
            }, failed: { XCTFail($0) })
        try socket.send(Data([1]))
        var byte: UInt8 = 0, peer = sockaddr_in()
        var peerSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(server, &byte, 1, 0, $0, &peerSize) }
        }, 1)
        for id in 0..<400 {
            let data = SteamSessionPacket.littleEndian(UInt16(id))
            XCTAssertEqual(data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(server, bytes.baseAddress, bytes.count, 0, $0, peerSize) }
                }
            }, 2)
        }
        wait(for: [all], timeout: 5)
        queue.sync { socket.cancel() }
        XCTAssertNoThrow(try socket.send(Data([2])))
    }
}

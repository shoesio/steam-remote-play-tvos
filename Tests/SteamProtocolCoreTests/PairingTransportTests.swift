import XCTest
import Network
@testable import SteamProtocolCore

final class PairingTransportTests: XCTestCase {
    /// Exercises the actual UDP path with a local protocol fixture. This is not
    /// evidence that a real Steam host approved pairing.
    func testAuthorizationOverUDPRejectsWrongHostAndAcceptsSuccess() throws {
        let queue = DispatchQueue(label: "SteamTV.tests.pairing")
        let ready = expectation(description: "listener ready")
        let requestReceived = expectation(description: "encrypted request received")
        let awaitingPIN = expectation(description: "PIN shown")
        let paired = expectation(description: "success parsed")
        let listener = try NWListener(using: .udp, on: .any)
        var server: NWConnection?
        var pairingPIN = ""
        let confirmed = expectation(description: "authorization confirmed")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            server = connection
            connection.start(queue: queue)
            connection.receiveMessage { data, _, _, error in
                XCTAssertNil(error)
                do {
                    let (header, _) = try DiscoveryPacket.decode(XCTUnwrap(data))
                    XCTAssertEqual(header.integer(2), 0)
                    let status = ProtoMessage.integer(1, 8) + ProtoMessage.bytes(4, Data("fixture".utf8)) + ProtoMessage.integer(6, 2)
                    let reply = DiscoveryPacket.envelope(header: ProtoMessage.integer(1, 123) + ProtoMessage.integer(2, 1), payload: status)
                    connection.send(content: reply, completion: .contentProcessed { error in XCTAssertNil(error) })
                } catch { XCTFail("\(error)") }
                connection.receiveMessage { data, _, _, error in
                XCTAssertNil(error)
                do {
                    let (header, payload) = try DiscoveryPacket.decode(XCTUnwrap(data))
                    XCTAssertEqual(header.integer(2), 3)
                    XCTAssertEqual(header.integer(1), 321)
                    let request = try ProtoMessage(payload)
                    XCTAssertEqual(request.bytes(1)?.count, 32)
                    XCTAssertEqual(request.bytes(3)?.count, 256)
                    requestReceived.fulfill()
                    // A different client ID must not be allowed to fail this operation.
                    let wrongHost = DiscoveryPacket.envelope(header: ProtoMessage.integer(1, 999) + ProtoMessage.integer(2, 4),
                        payload: ProtoMessage.integer(1, 1))
                    connection.send(content: wrongHost, completion: .contentProcessed { error in XCTAssertNil(error) })
                    let exchange = try SteamPINKeyExchange(pin: pairingPIN)
                    let secret = try exchange.sharedSecret(peerAuthorizationKey: XCTUnwrap(request.bytes(4)))
                    let token = try SteamCryptography.encrypt(Data([65, 1, 0, 0, 0, 0, 0, 0]), key: secret)
                    let response = ProtoMessage.integer(1, 0) + Data([17, 42, 0, 0, 0, 0, 0, 0, 0])
                        + ProtoMessage.bytes(3, exchange.authorizationKey) + ProtoMessage.bytes(4, token)
                    let success = DiscoveryPacket.envelope(header: ProtoMessage.integer(1, 123) + ProtoMessage.integer(2, 4), payload: response)
                    connection.send(content: success, completion: .contentProcessed { error in XCTAssertNil(error) })
                    connection.receiveMessage { data, _, _, error in
                        XCTAssertNil(error)
                        do {
                            let (header, payload) = try DiscoveryPacket.decode(XCTUnwrap(data))
                            XCTAssertEqual(header.integer(2), 14)
                            XCTAssertEqual(try ProtoMessage(payload).integer(1), 0)
                            confirmed.fulfill()
                        } catch { XCTFail("\(error)") }
                    }
                } catch { XCTFail("\(error)") }
                }
            }
        }
        listener.start(queue: queue)
        defer { server?.cancel(); listener.cancel() }
        wait(for: [ready], timeout: 3)
        let status = SteamHostStatus(clientID: 123, instanceID: 1, hostname: "fixture",
            protocolVersion: 8, minimumVersion: 6, connectPort: nil, enabledServices: 2, universe: 1)
        let host = SteamHost(status: status, address: "127.0.0.1", discoveryPort: try XCTUnwrap(listener.port).rawValue,
            lastSeen: 0, online: true)
        let operation = SteamPairing(host: host,
            identity: SteamDeviceIdentity(clientID: 321, secret: Data(repeating: 7, count: 32))) { update in
            switch update {
            case .awaitingApproval(let pin): pairingPIN = pin; XCTAssertEqual(pin.count, 4); awaitingPIN.fulfill()
            case .succeeded(let host):
                XCTAssertEqual(host.hostID, 123)
                XCTAssertEqual(host.steamID, 42)
                XCTAssertEqual(host.authKey?.count, 32)
                XCTAssertEqual(host.deviceToken?.count, 32)
                XCTAssertEqual(host.sharedSecret?.count, 32)
                paired.fulfill()
            case .failed(let message): XCTFail(message)
            default: break
            }
        }
        operation.start()
        wait(for: [awaitingPIN, requestReceived, paired, confirmed], timeout: 5)
        withExtendedLifetime(operation) {}
    }
}

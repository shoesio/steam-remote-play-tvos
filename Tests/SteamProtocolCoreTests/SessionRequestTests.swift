import XCTest
import Network
@testable import SteamProtocolCore

final class SessionRequestTests: XCTestCase {
    func testRequestsBigPicture1080p60StereoUDP() throws {
        let message = try ProtoMessage(SteamSessionRequest.requestPayload(requestID: 42, hostID: 123, token: Data(repeating: 7, count: 32)))
        XCTAssertEqual(message.integer(1), 42)
        XCTAssertEqual(message.integer(2), 1920)
        XCTAssertEqual(message.integer(3), 1080)
        XCTAssertEqual(message.integer(4), 2)
        XCTAssertEqual(message.integer(14), 1)
        XCTAssertEqual(message.integer(20), 2)
        XCTAssertEqual(message.integer(21), 60)
        XCTAssertEqual(message.integer(22), 1)
    }
    func testRequestsOnlyConfiguredGameIncluding64BitShortcutIDs() throws {
        for gameID: UInt64 in [1126750, 14282089216534904832] {
            let message = try ProtoMessage(SteamSessionRequest.requestPayload(requestID: 42, hostID: 123,
                token: Data(repeating: 7, count: 32), gameID: gameID))
            XCTAssertEqual(message.integer(19), gameID)
            XCTAssertEqual(message.integer(6), 0)
            XCTAssertEqual(message.integer(20), 0)
        }
    }
    func testDesktopCaptureOmitsLaunchTarget() throws {
        let message = try ProtoMessage(SteamSessionRequest.requestPayload(requestID: 43, hostID: 123,
            token: Data(repeating: 7, count: 32), width: 3840, height: 2160, streamInterface: 3))
        XCTAssertNil(message.integer(19))
        XCTAssertEqual(message.integer(6), 1)
        XCTAssertEqual(message.integer(20), 3)
    }
    func testRequests4KBigPictureCapture() throws {
        let message = try ProtoMessage(SteamSessionRequest.requestPayload(requestID: 42, hostID: 123,
            token: Data(repeating: 7, count: 32), width: 3840, height: 2160))
        XCTAssertEqual(message.integer(2), 3840)
        XCTAssertEqual(message.integer(3), 2160)
        XCTAssertEqual(message.integer(21), 60)
    }
    func testUDPProofAndEncryptedSessionKey() throws {
        let queue = DispatchQueue(label: "SteamTV.tests.sessionRequest")
        let ready = expectation(description: "listener ready")
        let authenticated = expectation(description: "proof verified")
        let completed = expectation(description: "session key verified")
        let listener = try NWListener(using: .udp, on: .any)
        let secret = Data(repeating: 7, count: 32)
        let sessionKey = Data(repeating: 9, count: 16)
        let challenge = Data("fixture challenge".utf8)
        var server: NWConnection?
        func reply(_ connection: NWConnection, type: UInt64, payload: Data) {
            connection.send(content: DiscoveryPacket.envelope(header: ProtoMessage.integer(1, 123)
                + ProtoMessage.integer(2, type), payload: payload), completion: .contentProcessed { error in XCTAssertNil(error) })
        }
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            server = connection; connection.start(queue: queue)
            connection.receiveMessage { data, _, _, error in
                XCTAssertNil(error)
                reply(connection, type: 1, payload: Data())
                connection.receiveMessage { data, _, _, error in
                    XCTAssertNil(error)
                    do {
                        let (header, payload) = try DiscoveryPacket.decode(XCTUnwrap(data))
                        XCTAssertEqual(header.integer(2), 5)
                        let requestID = try XCTUnwrap(ProtoMessage(payload).integer(1))
                        reply(connection, type: 7, payload: ProtoMessage.bytes(1, challenge) + ProtoMessage.integer(2, requestID))
                        connection.receiveMessage { data, _, _, error in
                            XCTAssertNil(error)
                            do {
                                let (header, payload) = try DiscoveryPacket.decode(XCTUnwrap(data))
                                XCTAssertEqual(header.integer(2), 8)
                                let proof = try ProtoMessage(payload)
                                XCTAssertEqual(proof.integer(2), requestID)
                                XCTAssertEqual(try SteamCryptography.decrypt(XCTUnwrap(proof.bytes(1)), key: secret), challenge)
                                authenticated.fulfill()
                                reply(connection, type: 6, payload: ProtoMessage.integer(1, requestID)
                                    + ProtoMessage.integer(2, 0) + ProtoMessage.integer(3, 27031)
                                    + ProtoMessage.bytes(4, try SteamCryptography.encrypt(sessionKey, key: secret))
                                    + ProtoMessage.integer(6, 1))
                            } catch { XCTFail("\(error)") }
                        }
                    } catch { XCTFail("\(error)") }
                }
            }
        }
        listener.start(queue: queue)
        defer { server?.cancel(); listener.cancel() }
        wait(for: [ready], timeout: 3)
        let status = SteamHostStatus(clientID: 123, instanceID: 1, hostname: "fixture", protocolVersion: 8,
            minimumVersion: 6, connectPort: nil, enabledServices: 2, universe: 1)
        let host = SteamHost(status: status, address: "127.0.0.1", discoveryPort: try XCTUnwrap(listener.port).rawValue,
            lastSeen: 0, online: true)
        let operation = SteamSessionRequest(host: host, identity: SteamDeviceIdentity(clientID: 321, secret: secret),
            paired: PairedSteamHost(hostID: 123, steamID: 42, authKey: nil, deviceToken: Data(repeating: 8, count: 32), sharedSecret: secret)) { update in
            switch update {
            case .ready(let endpoint):
                XCTAssertEqual(endpoint.port, 27031)
                XCTAssertEqual(endpoint.sessionKey, sessionKey)
                completed.fulfill()
            case .failed(let reason): XCTFail(reason)
            default: break
            }
        }
        operation.start()
        wait(for: [authenticated, completed], timeout: 5)
        withExtendedLifetime(operation) {}
    }
}

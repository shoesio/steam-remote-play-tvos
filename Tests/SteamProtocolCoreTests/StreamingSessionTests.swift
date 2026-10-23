import XCTest
import Network
@testable import SteamProtocolCore

final class StreamingSessionTests: XCTestCase {
    func testPyroWaveSequenceSizeChangesWithoutControlRestart() {
        func header(width: UInt32, height: UInt32) -> Data {
            let word = UInt32(0x80000000) | (width - 1) | ((height - 1) << 14)
            return Data((0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) }) + Data(repeating: 0, count: 4)
        }
        let hd = SteamPyroWaveAssembler.sequenceDimensions(header(width: 1920, height: 1080))
        let uhd = SteamPyroWaveAssembler.sequenceDimensions(header(width: 3840, height: 2160))
        XCTAssertEqual(hd?.width, 1920); XCTAssertEqual(hd?.height, 1080)
        XCTAssertEqual(uhd?.width, 3840); XCTAssertEqual(uhd?.height, 2160)
        XCTAssertNil(SteamPyroWaveAssembler.sequenceDimensions(Data(repeating: 0, count: 8)))
        XCTAssertNil(SteamPyroWaveAssembler.sequenceDimensions(Data([0xff])))
    }
    func testMissingHandshakeStartupHIDAndKeepaliveACKsDoNotAbortActiveMedia() throws {
        try exerciseSession(quitOnNegotiation: false)
    }
    func testHandoverQuitsAfterNegotiationWithoutWaitingForVideo() throws {
        try exerciseSession(quitOnNegotiation: true)
    }
    private func exerciseSession(quitOnNegotiation: Bool) throws {
        let queue = DispatchQueue(label: "SteamTV.tests.streaming")
        let ready = expectation(description: "listener ready")
        let audio = expectation(description: "Opus stereo packet received")
        audio.assertForOverFulfill = false
        let frame = expectation(description: "HEVC frame received")
        let survived = expectation(description: "session survives former handshake retry timeout")
        let hidExpired = expectation(description: "unacknowledged HID has bounded retries")
        let keepaliveExpired = expectation(description: "missing keepalive ACK is tolerated with active media")
        keepaliveExpired.assertForOverFulfill = false
        let quitRequested = expectation(description: "encrypted native Steam quit request")
        let ended = expectation(description: "requested stop is not a connection failure")
        let listener = try NWListener(using: .udp, on: .any)
        let key = Data(repeating: 9, count: 16)
        var server: NWConnection?
        var client: UInt8 = 0, nextID: UInt16 = 0, sequence: UInt64 = 0
        var seen: Set<UInt16> = []
        var tearingDown = false
        var keepalive: DispatchSourceTimer?
        func send(_ packet: SteamSessionPacket) {
            server?.send(content: packet.encoded(), completion: .contentProcessed { error in
                // Teardown closes both UDP endpoints with sends still in flight.
                if tearingDown { return }
                if case .posix(.ECANCELED)? = error { return }
                XCTAssertNil(error)
            })
        }
        func control(_ type: UInt8, _ payload: Data) throws {
            let plain = [UInt8(2), 7].contains(type)
            let body = plain ? payload : try SteamCryptography.encryptFrame(payload, sequence: sequence, key: key)
            if !plain { sequence += 1 }
            send(SteamSessionPacket(type: 5, source: 9, destination: client, channel: 1, id: nextID, body: Data([type]) + body))
            nextID &+= 1
        }
        func receive(_ connection: NWConnection) {
            connection.receiveMessage { data, _, _, error in
                guard error == nil, let data else { return }
                do {
                    let packet = try SteamSessionPacket(data)
                    if packet.type == 1 {
                        client = packet.source
                        send(SteamSessionPacket(type: 2, source: 9, destination: client, channel: 0, body: Data()))
                    } else if packet.type == 5 {
                        // Current host omits ACKs for handshake, stream startup and some HID traffic.
                        if packet.body.first != 6 && packet.body.first != 5 && packet.body.first != 9 && packet.body.first != 106 {
                            send(SteamSessionPacket(type: 7, source: 9, destination: client, channel: 1, id: packet.id, body: Data(repeating: 0, count: 4)))
                        }
                        if seen.insert(packet.id).inserted {
                            switch packet.body.first {
                            case 83:
                                let decoded = try SteamCryptography.decryptFrame(Data(packet.body.dropFirst()), key: key)
                                XCTAssertTrue(decoded.payload.isEmpty)
                                quitRequested.fulfill()
                                try control(129, Data())
                            case 6: try control(7, ProtoMessage.bytes(1, Data()))
                            case 1:
                                try control(2, ProtoMessage.integer(1, 0))
                                try control(3, ProtoMessage.integer(3, 4))
                            case 4: try control(4, ProtoMessage.bytes(1, ProtoMessage.integer(3, 5)))
                            case 5:
                                if quitOnNegotiation { break }
                                try control(50, ProtoMessage.integer(2, 3) + ProtoMessage.integer(3, 3) + ProtoMessage.integer(5, 48000) + ProtoMessage.integer(6, 2))
                                send(SteamSessionPacket(type: 3, source: 9, destination: client, channel: 3,
                                    body: Data([1]) + Data(repeating: 0, count: 12) + Data([0xf8, 0xff, 0xfe])))
                                try control(52, ProtoMessage.integer(1, 4) + ProtoMessage.integer(2, 5)
                                    + ProtoMessage.integer(4, 1920) + ProtoMessage.integer(5, 1080))
                                let body = Data([1]) + Data(repeating: 0, count: 14) + Data([0x18])
                                    + Data(repeating: 0, count: 4) + Data([0, 0, 0, 1, 0x26, 1])
                                send(SteamSessionPacket(type: 3, source: 9, destination: client, channel: 4, body: body))
                                let timer = DispatchSource.makeTimerSource(queue: queue)
                                timer.schedule(deadline: .now() + 1, repeating: 1)
                                timer.setEventHandler {
                                    do {
                                        try control(9, Data())
                                        send(SteamSessionPacket(type: 3, source: 9, destination: client, channel: 3,
                                            id: nextID, body: Data([1]) + Data(repeating: 0, count: 12) + Data([0xf8, 0xff, 0xfe])))
                                    } catch { XCTFail("\(error)") }
                                }
                                keepalive = timer; timer.resume()
                            default: break
                            }
                        }
                    }
                } catch { XCTFail("Fixture failed: \(error)") }
                receive(connection)
            }
        }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in server = connection; connection.start(queue: queue); receive(connection) }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 3)
        let session = SteamStreamingSession(endpoint: SteamSessionEndpoint(address: "127.0.0.1", port: try XCTUnwrap(listener.port).rawValue,
            sessionKey: key, steamID: 42), quitGameAfterNegotiation: quitOnNegotiation) { update in
            switch update {
            case .startedAudio(let config):
                XCTAssertEqual(config.codec, 3); XCTAssertEqual(config.sampleRate, 48000); XCTAssertEqual(config.channels, 2)
            case .audioFrame(let packet):
                XCTAssertEqual(packet, Data([0xf8, 0xff, 0xfe])); audio.fulfill()
            case .videoFrame(let received): XCTAssertEqual(received.data, Data([0, 0, 0, 1, 0x26, 1])); frame.fulfill()
            case .diagnostic(let trace):
                if trace.contains("exhausted acknowledgement retries") { hidExpired.fulfill() }
                if trace.contains("recent media confirms the connection is alive") { keepaliveExpired.fulfill() }
            case .ended: ended.fulfill()
            case .failed(let reason): if !reason.contains("cancelled") { XCTFail(reason) }
            default: break
            }
        }
        session.start()
        if !quitOnNegotiation { queue.asyncAfter(deadline: .now() + 12) {
            survived.fulfill()
            session.requestGameExit()
        }
        } else {
            frame.fulfill(); audio.fulfill(); survived.fulfill(); hidExpired.fulfill(); keepaliveExpired.fulfill()
        }
        wait(for: [frame, audio, survived, hidExpired, keepaliveExpired, quitRequested, ended], timeout: 15)
        session.cancel()
        queue.sync { tearingDown = true; keepalive?.cancel(); server?.cancel(); listener.cancel() }
        withExtendedLifetime(session) {}
    }
}

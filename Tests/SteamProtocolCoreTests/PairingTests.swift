import XCTest
@testable import SteamProtocolCore

final class PairingTests: XCTestCase {
    func testSteamSymmetricEnvelopeAndRoundTrip() throws {
        let key = Data(repeating: 0, count: 32)
        let iv = Data(repeating: 0, count: 16)
        let input = Data([1, 0, 0, 0, 0, 0, 0, 0])
        let output = try SteamCryptography.encrypt(input, key: key, iv: iv)
        // AES-256 ECB encryption of a zero block, independent published vector.
        XCTAssertEqual(output.prefix(16).map { String(format: "%02x", $0) }.joined(),
                       "dc95c078a2408989ad48a21492842087")
        XCTAssertEqual(output.count, 32)
        XCTAssertEqual(try SteamCryptography.decrypt(output, key: key), input)
        for length in [0, 1, 15, 16, 17, 32, 1024] {
            let input = Data((0..<length).map { UInt8(truncatingIfNeeded: $0) })
            XCTAssertEqual(try SteamCryptography.decrypt(SteamCryptography.encrypt(input, key: key), key: key), input)
        }
    }
    func testInvalidCiphertextAndKeysRejected() {
        let key = Data(repeating: 0, count: 32)
        for length in [0, 1, 16, 31, 33] {
            XCTAssertThrowsError(try SteamCryptography.decrypt(Data(repeating: 0, count: length), key: key))
        }
        XCTAssertThrowsError(try SteamCryptography.encrypt(Data([1]), key: Data([0])))
        XCTAssertThrowsError(try SteamCryptography.encrypt(Data([1]), key: key, iv: Data([0])))
    }
    func testRSAEscrowAndAuthorizationWireFormat() throws {
        let identity = SteamDeviceIdentity(clientID: 0x0123456789abcdef, secret: Data(repeating: 7, count: 32))
        let packet = try SteamPairing.authorizationPacket(identity: identity, pin: "0042")
        let (header, payload) = try DiscoveryPacket.decode(packet)
        XCTAssertEqual(header.integer(1), identity.clientID)
        XCTAssertEqual(header.integer(2), 3)
        let request = try ProtoMessage(payload)
        XCTAssertEqual(request.string(2), "SteamTV Apple TV")
        XCTAssertEqual(request.bytes(3)?.count, 256)
        let token = try XCTUnwrap(request.bytes(1))
        XCTAssertEqual(try SteamCryptography.decrypt(token, key: identity.secret),
                       Data([239,205,171,137,103,69,35,1]))
        XCTAssertThrowsError(try SteamPairing.authorizationPacket(identity: identity, pin: "42"))
        XCTAssertThrowsError(try SteamPairing.authorizationPacket(identity: identity, pin: "abcd"))
    }
    func testKeyExchangeMatchesRFC7748Vector() throws {
        func hex(_ value: String) -> Data {
            Data(stride(from: 0, to: value.count, by: 2).map {
                let start = value.index(value.startIndex, offsetBy: $0)
                return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
            })
        }
        let alice = try SteamPINKeyExchange(pin: "0042", privateKey: hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
        let bob = try SteamPINKeyExchange(pin: "0042", privateKey: hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"))
        XCTAssertEqual(try alice.sharedSecret(peerAuthorizationKey: bob.authorizationKey), hex("dead45a1d43d6902aa9240b43c0d75a0b5fc750660590d6d45461cbfc4010684"))
    }
    func testPINKeyExchangeVerifiesIdentityAndRejectsWrongPIN() throws {
        let client = try SteamPINKeyExchange(pin: "0042")
        let host = try SteamPINKeyExchange(pin: "0042")
        let shared = try host.sharedSecret(peerAuthorizationKey: client.authorizationKey)
        let token = try SteamCryptography.encrypt(Data([123, 0, 0, 0, 0, 0, 0, 0]), key: shared)
        XCTAssertEqual(try client.verify(peerAuthorizationKey: host.authorizationKey, token: token, clientID: 123), shared)
        XCTAssertThrowsError(try client.verify(peerAuthorizationKey: host.authorizationKey, token: token, clientID: 124))
        let wrongPIN = try SteamPINKeyExchange(pin: "0043")
        XCTAssertThrowsError(try wrongPIN.verify(peerAuthorizationKey: host.authorizationKey, token: token, clientID: 123))
        XCTAssertThrowsError(try client.sharedSecret(peerAuthorizationKey: Data([1])))
    }
    func testDeviceIdentitySurvivesSerialization() throws {
        let identity = try SteamDeviceIdentity.generate(clientID: 123)
        XCTAssertEqual(identity.secret.count, 32)
        XCTAssertEqual(try JSONDecoder().decode(SteamDeviceIdentity.self,
            from: JSONEncoder().encode(identity)), identity)
    }
}

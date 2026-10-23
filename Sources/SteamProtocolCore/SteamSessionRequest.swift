import Foundation
import Network

public struct SteamSessionEndpoint: Sendable {
    public let address: String
    public let port: UInt16
    public let sessionKey: Data
    public let steamID: UInt64
}

public enum SteamSessionRequestUpdate: Sendable {
    case diagnostic(String)
    case ready(SteamSessionEndpoint)
    case failed(String)
}

/// Launches Steam's own Big Picture UI and obtains the authenticated UDP session.
/// Codec selection takes place on the session control channel, after this step.
public final class SteamSessionRequest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SteamTV.sessionRequest")
    private let host: SteamHost
    private let identity: SteamDeviceIdentity
    private let paired: PairedSteamHost
    private let gameID: UInt64?
    private let streamInterface: UInt64?
    private let width: UInt64
    private let height: UInt64
    private let update: @Sendable (SteamSessionRequestUpdate) -> Void
    private let requestID = UInt32.random(in: 1...UInt32.max)
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var terminal = false
    private var confirmed = false
    private var deadline: TimeInterval = 0
    private var lastTrace = ""

    public init(host: SteamHost, identity: SteamDeviceIdentity, paired: PairedSteamHost,
                width: UInt64 = 1920, height: UInt64 = 1080, gameID: UInt64? = nil, streamInterface: UInt64? = nil,
                update: @escaping @Sendable (SteamSessionRequestUpdate) -> Void) {
        self.host = host; self.identity = identity; self.paired = paired; self.update = update
        self.gameID = gameID; self.streamInterface = streamInterface
        self.width = min(3840, max(640, width)); self.height = min(2160, max(360, height))
    }
    public func start() { queue.async { [self] in begin() } }
    public func cancel() { queue.async { [self] in cancelOnQueue() } }
    private func begin() {
        guard connection == nil, !terminal else { return }
        guard host.online, paired.hostID == host.id, paired.sharedSecret?.count == 32,
              paired.deviceToken?.count == 32 else {
            finish(.failed("This host needs to be paired before connecting.")); return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host.address),
            port: NWEndpoint.Port(rawValue: host.discoveryPort)!, using: .udp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.terminal else { return }
            switch state {
            case .ready:
                self.deadline = ProcessInfo.processInfo.systemUptime + 45
                self.receive()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: 3)
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer; timer.resume()
            case .failed(let error): self.finish(.failed("Steam connection: \(error.localizedDescription)"))
            case .waiting(let error): self.finish(.failed("Steam unavailable: \(error.localizedDescription)"))
            default: break
            }
        }
        connection.start(queue: queue)
    }
    static func requestPayload(requestID: UInt32, hostID: UInt64, token: Data,
                               width: UInt64 = 1920, height: UInt64 = 1080, gameID: UInt64? = nil, streamInterface: UInt64? = nil) -> Data {
        let integers: [(Int, UInt64)] = [(1, UInt64(requestID)), (2, width), (3, height), (4, 2),
            (6, gameID == nil ? 1 : 0), (9, 1), (10, 1), (11, 1), (13, hostID), (14, 1), (15, 0), (16, 4),
            (20, streamInterface ?? (gameID == nil ? 2 : 0)), (21, 60), (22, 1)]
        var payload = Data()
        for (field, value) in integers { payload += ProtoMessage.integer(field, value) }
        if let gameID { payload += ProtoMessage.integer(19, gameID) }
        payload += ProtoMessage.bytes(5, Data("SteamTV v0.1".utf8))
        payload += ProtoMessage.bytes(7, token)
        return payload
    }
    private func tick() {
        guard !terminal else { return }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            cancelOnQueue(message: "Steam session request timed out."); return
        }
        if confirmed {
            trace("Requesting \(gameID.map { "game \($0)" } ?? "Big Picture"), \(width)×\(height) at 60 fps, stereo, UDP")
            send(type: 5, payload: Self.requestPayload(requestID: requestID, hostID: host.id, token: paired.deviceToken!, width: width, height: height, gameID: gameID, streamInterface: streamInterface))
        } else {
            send(packet: DiscoveryPacket.request(clientID: identity.clientID, sequence: 0))
        }
    }
    private func receive() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.terminal else { return }
            if let error { self.finish(.failed("Steam receive: \(error.localizedDescription)")); return }
            if let data {
                do {
                    let (header, payload) = try DiscoveryPacket.decode(data)
                    guard header.integer(1) == self.host.id else { self.receive(); return }
                    let type = header.integer(2) ?? 0
                    if type == 1, !self.confirmed {
                        self.confirmed = true; self.tick()
                    } else if type == 7 {
                        let proof = try ProtoMessage(payload)
                        guard proof.integer(2) == UInt64(self.requestID) else { self.receive(); return }
                        guard let challenge = proof.bytes(1), challenge.count <= 512 else { throw DiscoveryError.malformed }
                        let encrypted = try SteamCryptography.encrypt(challenge, key: self.paired.sharedSecret!)
                        self.trace("Answering Steam session proof challenge")
                        self.send(type: 8, payload: ProtoMessage.bytes(1, encrypted)
                            + ProtoMessage.integer(2, UInt64(self.requestID)) + ProtoMessage.integer(3, 0))
                    } else if type == 6 {
                        let response = try ProtoMessage(payload)
                        guard response.integer(1) == UInt64(self.requestID) else { self.receive(); return }
                        guard let result = response.integer(2) else { throw DiscoveryError.malformed }
                        self.trace("Steam session request result \(result)")
                        if result == 5 { self.receive(); return }
                        guard result == 0 else { self.finish(.failed("Steam session request failed (result \(result)).")); return }
                        guard let port = response.integer(3), port > 0, port <= 65535,
                              (response.integer(6) ?? 1) == 1,
                              let encrypted = response.bytes(4) else { throw DiscoveryError.malformed }
                        let key = try SteamCryptography.decrypt(encrypted, key: self.paired.sharedSecret!)
                        self.trace("Steam returned a \(key.count)-byte session key")
                        guard key.count == 16 || key.count == 32 else { throw SteamCryptoError.invalidKey }
                        self.trace("Verified Steam session key and UDP endpoint")
                        self.finish(.ready(SteamSessionEndpoint(address: self.host.address, port: UInt16(port),
                            sessionKey: key, steamID: self.paired.steamID))); return
                    }
                } catch {
                    self.trace("Rejected Steam session response: \(error.localizedDescription)")
                    self.finish(.failed("Steam session response could not be verified.")); return
                }
            }
            self.receive()
        }
    }
    private func send(type: UInt64, payload: Data) {
        send(packet: DiscoveryPacket.envelope(header: ProtoMessage.integer(1, identity.clientID)
            + ProtoMessage.integer(2, type), payload: payload))
    }
    private func send(packet: Data) {
        connection?.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(.failed("Steam send: \(error.localizedDescription)")) }
        })
    }
    private func cancelOnQueue(message: String = "Connection cancelled") {
        guard !terminal else { return }
        send(type: 10, payload: ProtoMessage.integer(1, UInt64(requestID)))
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.finish(.failed(message)) }
    }
    private func finish(_ result: SteamSessionRequestUpdate) {
        guard !terminal else { return }
        terminal = true; timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        update(result)
    }
    private func trace(_ message: String) {
        guard message != lastTrace else { return }
        lastTrace = message; update(.diagnostic(message))
    }
}

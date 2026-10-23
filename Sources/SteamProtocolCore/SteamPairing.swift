import Foundation
import Network
import OSLog

public enum PairingUpdate: Sendable {
    case awaitingApproval(pin: String)
    case inProgress
    case succeeded(PairedSteamHost)
    case failed(String)
    case cancelled
    case diagnostic(String)
}

/// Steam's normal PIN authorization, without any alternative host service.
/// The escrow request includes the current PIN-protected X25519 exchange.
/// The host token must verify before confirmation and credential persistence.
public final class SteamPairing: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SteamTV.pairing")
    private let logger = Logger(subsystem: "local.SteamTV", category: "Pairing")
    private let host: SteamHost
    private let identity: SteamDeviceIdentity
    private let update: @Sendable (PairingUpdate) -> Void
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var terminal = false
    private var packet = Data()
    private var deadline: TimeInterval = 0
    private var hostConfirmed = false
    private var exchange: SteamPINKeyExchange?
    private var lastTrace = ""

    public init(host: SteamHost, identity: SteamDeviceIdentity, update: @escaping @Sendable (PairingUpdate) -> Void) {
        self.host = host; self.identity = identity; self.update = update
    }
    public func start() { queue.async { [self] in begin() } }
    public func cancel() { queue.async { [self] in cancelOnQueue() } }

    private func begin() {
        guard connection == nil, !terminal else { return }
        guard host.online, host.status.universe == 1 else {
            finish(.failed("Pairing requires an online host in Steam’s public universe.")); return
        }
        do {
            // A secure, unbiased four-digit PIN including leading zeroes.
            let pin = String(format: "%04u", arc4random_uniform(10000))
            let exchange = try SteamPINKeyExchange(pin: pin)
            self.exchange = exchange
            packet = try Self.authorizationPacket(identity: identity, pin: pin, authorizationKey: exchange.authorizationKey)
            let connection = NWConnection(host: NWEndpoint.Host(host.address),
                port: NWEndpoint.Port(rawValue: host.discoveryPort)!, using: .udp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.terminal else { return }
                switch state {
                case .ready:
                    self.logger.info("Pairing requested for \(self.host.status.hostname, privacy: .public)")
                    self.update(.awaitingApproval(pin: pin))
                    self.deadline = ProcessInfo.processInfo.systemUptime + 90
                    self.receive()
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now(), repeating: 1)
                    timer.setEventHandler { [weak self] in self?.tick() }
                    self.timer = timer; timer.resume()
                case .failed(let error): self.finish(.failed("Pairing connection: \(error.localizedDescription)"))
                case .waiting(let error): self.finish(.failed("Pairing connection unavailable: \(error.localizedDescription)"))
                default: break
                }
            }
            connection.start(queue: queue)
        } catch {
            finish(.failed("Cannot prepare Steam pairing: \(error.localizedDescription)"))
        }
    }
    static func authorizationPacket(identity: SteamDeviceIdentity, pin: String, authorizationKey: Data? = nil) throws -> Data {
        guard pin.count == 4, pin.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
            throw DiscoveryError.malformed
        }
        let name = Data("SteamTV Apple TV".utf8)
        let ticket = ProtoMessage.bytes(1, Data(pin.utf8))
            + ProtoMessage.integer(2, identity.clientID)
            + ProtoMessage.bytes(3, identity.secret)
            + ProtoMessage.integer(4, UInt64(Date().timeIntervalSince1970))
            + ProtoMessage.integer(5, 0) + ProtoMessage.bytes(6, name)
        let encrypted = try SteamCryptography.encryptTicket(ticket)
        let idBytes = Data((0..<8).map { UInt8(truncatingIfNeeded: identity.clientID >> ($0 * 8)) })
        let token = try SteamCryptography.encrypt(idBytes, key: identity.secret)
        var request = ProtoMessage.bytes(1, token) + ProtoMessage.bytes(2, name) + ProtoMessage.bytes(3, encrypted)
        if let authorizationKey {
            guard authorizationKey.count == 32 else { throw SteamCryptoError.invalidKey }
            request += ProtoMessage.bytes(4, authorizationKey)
        }
        return DiscoveryPacket.envelope(header: ProtoMessage.integer(1, identity.clientID) + ProtoMessage.integer(2, 3),
                                        payload: request)
    }
    private func tick() {
        guard !terminal else { return }
        if ProcessInfo.processInfo.systemUptime >= deadline {
            cancelOnQueue(result: .failed("Pairing timed out. Check Steam → Settings → Remote Play → Pair Steam Link."))
            return
        }
        // IHSlib sends discovery on its authorization socket first. Steam must
        // learn this socket's source port before receiving the escrow ticket.
        let outbound = hostConfirmed ? packet : DiscoveryPacket.request(clientID: identity.clientID, sequence: 0)
        connection?.send(content: outbound, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(.failed("Pairing send: \(error.localizedDescription)")) }
        })
    }
    private func receive() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.terminal else { return }
            if let error { self.finish(.failed("Pairing receive: \(error.localizedDescription)")); return }
            if let data {
                do {
                    let (header, payload) = try DiscoveryPacket.decode(data)
                    let type = header.integer(2) ?? 0
                    self.trace("Received type \(type), sender client ID \(header.integer(1) ?? 0), expected \(self.host.id)")
                    guard header.integer(1) == self.host.id else { self.receive(); return }
                    if type == 1 {
                        if !self.hostConfirmed {
                            self.hostConfirmed = true
                            self.trace("Host confirmed the pairing socket; sending authorization")
                            self.tick()
                        }
                    } else if type == 4 {
                        let response = try ProtoMessage(payload)
                        guard let result = response.integer(1) else { throw DiscoveryError.malformed }
                        self.trace("Steam authorization result \(result); account ID present: \(response.fixed64(2) != nil)")
                        if result == 5 { self.update(.inProgress) }
                        else if result == 0 {
                            guard let steamID = response.fixed64(2), steamID != 0 else { throw DiscoveryError.malformed }
                            guard let exchange = self.exchange, let peerKey = response.bytes(3),
                                  let token = response.bytes(4) else { throw SteamCryptoError.invalidKey }
                            let secret = try exchange.verify(peerAuthorizationKey: peerKey, token: token, clientID: self.identity.clientID)
                            self.trace("Verified Steam key exchange; sending authorization confirmation")
                            self.timer?.cancel(); self.timer = nil
                            let confirmation = DiscoveryPacket.envelope(
                                header: ProtoMessage.integer(1, self.identity.clientID) + ProtoMessage.integer(2, 14),
                                payload: ProtoMessage.integer(1, 0))
                            self.connection?.send(content: confirmation, completion: .contentProcessed { [weak self] error in
                                guard let self else { return }
                                if let error { self.finish(.failed("Pairing confirmation: \(error.localizedDescription)")) }
                                else { self.finish(.succeeded(PairedSteamHost(hostID: self.host.id, steamID: steamID,
                                    authKey: peerKey, deviceToken: token, sharedSecret: secret))) }
                            })
                            return
                        } else {
                            self.finish(.failed(Self.reason(result))); return
                        }
                    }
                } catch {
                    self.trace("Rejected pairing response: \(error.localizedDescription)")
                    self.finish(.failed("Steam pairing response could not be verified.")); return
                }
            }
            self.receive()
        }
    }
    private func cancelOnQueue(result: PairingUpdate = .cancelled) {
        guard !terminal else { return }
        timer?.cancel(); timer = nil
        let packet = DiscoveryPacket.envelope(header: ProtoMessage.integer(1, identity.clientID) + ProtoMessage.integer(2, 9), payload: Data())
        // Send the protocol cancellation before closing the connected UDP socket.
        connection?.send(content: packet, completion: .contentProcessed { [weak self] _ in self?.finish(result) })
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.finish(result) }
    }
    private func finish(_ result: PairingUpdate) {
        guard !terminal else { return }
        terminal = true
        timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        logger.info("Pairing operation ended")
        update(result)
    }
    private func trace(_ message: String) {
        guard message != lastTrace else { return }
        lastTrace = message
        logger.info("\(message, privacy: .public)")
        update(.diagnostic(message))
    }
    private static func reason(_ result: UInt64) -> String {
        switch result {
        case 1: return "Steam denied pairing."
        case 2: return "Sign in to Steam on the host."
        case 3: return "The Steam host is offline."
        case 4: return "Steam is busy. Try again."
        case 6: return "Steam pairing timed out."
        case 8: return "Steam cancelled pairing."
        default: return "Steam pairing failed (result \(result))."
        }
    }
}

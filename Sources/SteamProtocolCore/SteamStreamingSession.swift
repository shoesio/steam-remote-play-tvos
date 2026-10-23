import Foundation
import Network
import CoreMedia

public enum SteamStreamUpdate: Sendable {
    case diagnostic(String)
    case gameQuitRequested
    case offeredVideoCodecs([UInt64])
    case startedVideo(codec: UInt64, width: UInt64, height: UInt64)
    case videoFrame(EncodedVideoFrame)
    case pyrowavePacket(Data)
    case startedAudio(SteamAudioConfiguration)
    case audioFrame(Data)
    case videoPreferences(SteamVideoPreferences)
    case title(String)
    case ended(String)
    case failed(String)
}

/// Authenticated Steam control transport and bounded HEVC video reception.
public final class SteamStreamingSession: @unchecked Sendable {
    private let endpoint: SteamSessionEndpoint
    public let preferredCodec: SteamVideoCodec
    private let width: UInt64
    private let height: UInt64
    private let quitGameAfterNegotiation: Bool
    private let bitrateKbps: UInt64
    private let wiredPyroBitrateKbps: UInt64?
    private let hostManagedVideo: Bool
    private let videoPreferences: SteamVideoPreferences?
    private let update: @Sendable (SteamStreamUpdate) -> Void
    private let queue = DispatchQueue(label: "SteamTV.codecProbe")
    private var connection: SteamDatagramSocket?
    private var timer: DispatchSourceTimer?
    private var terminal = false
    private let localID = UInt8.random(in: 1...255)
    private var remoteID: UInt8 = 0
    private var state = 0
    private var nextSend: UInt16 = 0
    private var controlWindow = SteamControlWindow()
    private var audioChannel: UInt8?
    private var audioConfiguration: SteamAudioConfiguration?
    private var audioWindow = SteamControlWindow(firstType: 3, fragmentType: 4, capacity: 256, maximumFrameBytes: 64 * 1024)
    private var reportedFirstAudio = false
    private var audioProgress: UInt32?
    private var waitingForAudioHead = false
    private var videoChannel: UInt8?
    private var activeVideoWidth: UInt64 = 0
    private var activeVideoHeight: UInt64 = 0
    private var videoWindow = SteamControlWindow(firstType: 3, fragmentType: 4, capacity: 2048, maximumFrameBytes: 2 * 1024 * 1024)
    private var videoAssembler = SteamHEVCAssembler()
    private var mediaTraceCount = 0
    private var lastMediaProgress: UInt32?
    private var waitingForVideoHead = false
    private var waitingForKeyframe = false
    private var nextVideoSendID: UInt16 = 0
    private var lastKeyframeRequest: TimeInterval = 0
    private var lastMediaPacketAt: TimeInterval = -.infinity
    private var lastKeepalive: TimeInterval = 0
    private var framesReceived = 0
    private var statisticsTime = ProcessInfo.processInfo.systemUptime
    private var encryptedSequence: UInt64 = 0
    private var sendEncryptedSequence: UInt64 = 0
    private var pending: [UInt16: SteamSessionPacket] = [:]
    private var deadline: TimeInterval = 0
    private var videoStartupDeadline: TimeInterval?
    private var packetTraceCount = 0
    private var newerPacketTraceCount = 0
    private var unknownPacketTraceCount = 0
    private var largeFragmentTraceCount = 0
    private var pyroAssembler = SteamPyroWaveAssembler()
    private var hid = SteamRemoteHID()
    private var controllerSlots: [Int] = []
    private var mediaDatagrams = 0
    private var mediaBytes = 0
    private var mediaStatisticsTime = ProcessInfo.processInfo.systemUptime
    public init(endpoint: SteamSessionEndpoint, preferredCodec: SteamVideoCodec = .hevc,
                width: UInt64 = 1920, height: UInt64 = 1080, bitrateKbps: UInt64 = 30000, hostManagedVideo: Bool = false, wiredPyroBitrateKbps: UInt64? = nil, videoPreferences: SteamVideoPreferences? = nil, quitGameAfterNegotiation: Bool = false,
                update: @escaping @Sendable (SteamStreamUpdate) -> Void) {
        self.quitGameAfterNegotiation = quitGameAfterNegotiation
        self.endpoint = endpoint; self.preferredCodec = preferredCodec; self.update = update
        self.width = min(3840, max(640, width)); self.height = min(2160, max(360, height))
        self.bitrateKbps = min(500000, max(10000, bitrateKbps))
        self.wiredPyroBitrateKbps = wiredPyroBitrateKbps.map { min(500000, max(10000, $0)) }
        self.hostManagedVideo = hostManagedVideo
        self.videoPreferences = videoPreferences
    }
    public func setControllerSlots(_ slots: [Int]) {
        queue.async { [self] in
            controllerSlots = slots
            let list = hid.setSlots(slots)
            if state >= 5, !terminal {
                update(.diagnostic("Steam RemoteHID: \(slots.count) controllers connected"))
                sendHID(list)
            }
        }
    }
    public func sendGamepad(slot: Int, state: SteamGamepadState) {
        queue.async { [self] in
            guard self.state >= 5, !terminal, let report = hid.update(slot: slot, state: state) else { return }
            sendHID(report)
        }
    }
    private var exitControllerReportPending = false
    private func sendHID(_ data: Data) {
        control(106, payload: ProtoMessage.bytes(1, data) + ProtoMessage.integer(2, 1))
        if exitControllerReportPending, (try? ProtoMessage(data).bytes(3)) != nil {
            exitControllerReportPending = false
            queue.asyncAfter(deadline: .now() + 1) { [self] in
                guard !terminal else { return }
                if let report = hid.update(slot: 0, state: SteamGamepadState()) { sendHID(report) }
            }
        }
    }
    public func requestConfiguredControllerExit() {
        queue.async { [self] in
            guard state >= 5, !terminal else { return }
            update(.diagnostic("Requesting configured Start + Select application exit"))
            if !controllerSlots.contains(0) {
                controllerSlots.append(0)
                sendHID(hid.setSlots(controllerSlots))
            }
            exitControllerReportPending = true
            if let report = hid.update(slot: 0, state: SteamGamepadState(buttons: (1 << 6) | (1 << 4))) { sendHID(report) }
        }
    }
    public func requestGameExit() {
        queue.async { [self] in
            guard state >= 5, !terminal else { return }
            update(.diagnostic("Requesting Steam game exit (control 83)"))
            control(83, payload: Data())
        }
    }
    public func start() { queue.async { [self] in begin() } }
    public func cancel() { queue.async { [self] in finish(.failed("Session probe cancelled")) } }
    private func begin() {
        guard connection == nil, !terminal else { return }
        do {
            let connection = try SteamDatagramSocket(address: endpoint.address, port: endpoint.port, queue: queue,
                received: { [weak self] in self?.receive($0) },
                failed: { [weak self] in self?.finish(.failed($0)) })
            self.connection = connection
            update(.diagnostic("Steam UDP receive buffer: \(connection.receiveBufferBytes) bytes; batched receiver"))
            deadline = ProcessInfo.processInfo.systemUptime + 20
            sendConnect()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer; timer.resume()
        } catch {
            finish(.failed("Steam UDP connection failed: \(error.localizedDescription)"))
        }
    }
    private func sendConnect() {
        send(SteamSessionPacket(type: 1, source: localID, destination: 0, channel: 0,
            body: Data([0xc7, 0x3d, 0x8f, 0x3c])))
    }
    private func tick() {
        guard !terminal else { return }
        if let videoStartupDeadline, ProcessInfo.processInfo.systemUptime >= videoStartupDeadline {
            finish(.failed("Steam connected with audio but did not start video")); return
        }
        if ProcessInfo.processInfo.systemUptime >= deadline { finish(.failed("Session codec probe timed out at step \(state)")); return }
        if state == 0 { sendConnect() }
        if state >= 5, ProcessInfo.processInfo.systemUptime - lastKeepalive > 2 {
            lastKeepalive = ProcessInfo.processInfo.systemUptime; control(9, payload: Data())
        }
        for id in pending.keys {
            guard var packet = pending[id] else { continue }
            if packet.retry >= 20, packet.body.first == 106 {
                // Match IHSlib's bounded retransmission: exhausted HID packets
                // are discarded rather than terminating a healthy media session.
                pending.removeValue(forKey: id)
                update(.diagnostic("RemoteHID packet \(id) exhausted acknowledgement retries; streaming continues"))
                continue
            }
            if packet.retry >= 20, packet.body.first == 9,
               ProcessInfo.processInfo.systemUptime - lastMediaPacketAt < 3 {
                pending.removeValue(forKey: id)
                update(.diagnostic("Keepalive packet \(id) missed its acknowledgement; recent media confirms the connection is alive"))
                continue
            }
            guard packet.retry < 20 else { finish(.failed("Session control acknowledgement timed out for packet \(id), message \(packet.body.first ?? 0); pending \(pending.keys.sorted()); local \(localID), remote \(remoteID)")); return }
            packet.retry += 1; guard !terminal else { return }
        pending[id] = packet; send(packet)
        }
    }
    private func send(_ packet: SteamSessionPacket) {
        do { try connection?.send(packet.encoded()) }
        catch { finish(.failed("Steam UDP send failed: \(error.localizedDescription)")) }
    }
    private func control(_ type: UInt8, payload: Data) {
        let id = nextSend; nextSend &+= 1
        let packet = SteamSessionPacket(type: 5, source: localID, destination: remoteID, channel: 1,
            id: id, body: Data([type]) + encodedControlPayload(type, payload: payload))
        guard !terminal else { return }
        pending[id] = packet; send(packet)
    }
    private func encodedControlPayload(_ type: UInt8, payload: Data) -> Data {
        guard ![1, 2, 6, 7].contains(type) else { return payload }
        do {
            let encoded = try SteamCryptography.encryptFrame(payload, sequence: sendEncryptedSequence, key: endpoint.sessionKey)
            sendEncryptedSequence += 1
            return encoded
        } catch { finish(.failed("Cannot encrypt Steam control message")); return Data() }
    }
    static func videoConfiguration(codec: SteamVideoCodec, width: UInt64 = 1920, height: UInt64 = 1080, bitrateKbps: UInt64 = 30000, hostManaged: Bool = false, wiredPyroBitrateKbps: UInt64? = nil, videoPreferences: SteamVideoPreferences? = nil) -> Data {
        func integers(_ fields: [(Int, UInt64)]) -> Data {
            var data = Data()
            for (field, value) in fields { data += ProtoMessage.integer(field, value) }
            return data
        }
        let mode = integers([(1, width), (2, height), (4, 60), (5, 1)])
        let codecID = codec.rawValue
        let config = integers([(1, 0), (2, 3), (3, codecID), (5, 1)]) + ProtoMessage.bytes(4, mode)
        // Advertise display/decoder limits separately from user preferences. In the
        // launcher, Steam chooses video quality and rate; diagnostics can override.
        let preferences: [(Int, UInt64)] = hostManaged ? [(1, UInt64.max), (2, width), (3, height), (4, 60), (5, 1), (6, UInt64.max)]
            : [(1, 2), (2, width), (3, height), (4, 60), (5, 1), (6, bitrateKbps)]
        var client = integers(preferences + [
            (7, 1), (8, 0), (9, 1), (10, 1), (11, 1), (12, 2), (13, 1), (14, 0), (15, 0), (26, 0), (35, 0)])
        let limit = integers([(1, codecID), (3, codec == .pyrowave ? 300000 : 30000), (4, codec == .pyrowave ? 500000 : 90000)]) + ProtoMessage.bytes(2, mode)
        client += ProtoMessage.bytes(21, limit)
        client += ProtoMessage.bytes(24, limit)
        let caps = integers([(2, 1), (3, codec == .pyrowave ? 500000 : 30000), (4, codec == .pyrowave ? 750000 : 90000), (5, 1), (11, 4), (13, 3), (14, 3), (15, codecID)])
        if codec == .pyrowave {
            client += ProtoMessage.integer(35, 1)
            client += ProtoMessage.integer(36, hostManaged ? 0 : 1)
            if !hostManaged { client += ProtoMessage.integer(37, bitrateKbps) }
        }
        if let videoPreferences, hostManaged, let restored = try? videoPreferences.applying(to: client) { client = restored }
        // Apply the wired policy after saved host choices so an old automatic
        // profile cannot restore the slow 15 Mbps startup ramp.
        if codec == .pyrowave, let wiredPyroBitrateKbps {
            let rate = min(500000, max(10000, wiredPyroBitrateKbps))
            let wired = integers([(2, width), (3, height), (6, rate), (36, 1), (37, rate)]) + ProtoMessage.bytes(22, limit)
            if let preferences = try? SteamVideoPreferences(wired), let applied = try? preferences.applying(to: client) { client = applied }
            // Keep runtime, quality, display and decoder limits consistent with
            // the wired resolution request instead of leaving runtime sizing implicit.
            client += ProtoMessage.bytes(23, limit)
        }
        return ProtoMessage.bytes(1, config) + ProtoMessage.bytes(2, client) + ProtoMessage.bytes(3, caps)
    }
    static func hevcConfiguration() -> Data { videoConfiguration(codec: .hevc) }
    private func receive(_ data: Data) {
            guard !terminal else { return }
                let packet: SteamSessionPacket
                do { packet = try SteamSessionPacket(data) }
                catch { self.finish(.failed("Steam UDP header rejected: \(data.count) bytes, prefix \(data.prefix(13).map { String(format: "%02x", $0) }.joined()): \(error)")); return }
                do { try self.handle(packet) }
                catch { self.finish(.failed("Steam packet handler rejected type \(packet.type), channel \(packet.channel), id \(packet.id), body \(packet.body.count) bytes: \(error)")); return }
    }
    private func handle(_ packet: SteamSessionPacket) throws {
        if packetTraceCount < 12 {
            packetTraceCount += 1
            update(.diagnostic("Session packet type \(packet.type), channel \(packet.channel), source \(packet.source), destination \(packet.destination), id \(packet.id), fragment \(packet.fragment), body bytes \(packet.body.count)"))
        }
        if packet.type == 0, packet.channel == 0 {
            let bytes = Array(packet.body)
            guard bytes.count >= 5, bytes[0] == 1 else { return }
            let size = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[1 + $1]) << ($1 * 8) }
            guard size <= bytes.count - 5 else { throw DiscoveryError.malformed }
            let ping = try ProtoMessage(Data(bytes[5..<(5 + Int(size))]))
            let payload = ProtoMessage.integer(1, ping.integer(1) ?? 0)
                + ProtoMessage.integer(2, UInt64(packet.body.count + 13))
            var body = Data([2]) + SteamSessionPacket.littleEndian(UInt32(payload.count)) + payload
            let requested = min(ping.integer(2) ?? 0, 65507)
            if requested > UInt64(body.count + 13) {
                body += Data(repeating: 0xfe, count: Int(requested) - body.count - 13)
            }
            send(SteamSessionPacket(type: 0, source: 0, destination: 0, channel: 0, body: body))
            return
        }
        guard packet.destination == localID else { return }
        if packet.type == 2 && state == 0 {
            remoteID = packet.source; state = 1
            update(.diagnostic("Steam transport connected; sending client handshake"))
            control(6, payload: ProtoMessage.bytes(1, Data())); return
        }
        guard packet.source == remoteID, remoteID != 0 else { return }
        if packet.type == 9 { finish(state >= 5 ? .ended("Steam ended the session (disconnect packet type 9)") : .failed("Steam rejected the session")); return }
        deadline = ProcessInfo.processInfo.systemUptime + 10
        if (packet.channel == audioChannel || packet.channel == videoChannel),
           [UInt8(3), 4, 12].contains(packet.type), !packet.body.isEmpty {
            lastMediaPacketAt = ProcessInfo.processInfo.systemUptime
        }
        if packet.type > 10 {
            if packet.type != 12, unknownPacketTraceCount < 8 {
                unknownPacketTraceCount += 1
                update(.diagnostic("Unknown Steam UDP type \(packet.type), channel \(packet.channel), id \(packet.id), fragment \(packet.fragment), body \(packet.body.prefix(64).map { String(format: "%02x", $0) }.joined())"))
            }
            if packet.type == 12 {
                mediaDatagrams += 1; mediaBytes += packet.body.count
                let now = ProcessInfo.processInfo.systemUptime
                if now - mediaStatisticsTime >= 1 {
                    update(.diagnostic(String(format: "Steam UDP media: %.1f Mbps, %d packets; incomplete Pyro images %d",
                        Double(mediaBytes) * 8 / (now - mediaStatisticsTime) / 1_000_000, mediaDatagrams, pyroAssembler.incompleteGroups)))
                    mediaBytes = 0; mediaDatagrams = 0; mediaStatisticsTime = now
                }
            }
            if newerPacketTraceCount < 6 {
                newerPacketTraceCount += 1
                update(.diagnostic("New Steam packet type \(packet.type), channel \(packet.channel), bytes \(packet.body.count), header \(packet.body.prefix(19).map { String(format: "%02x", $0) }.joined())"))
            }
            // Current Steam uses type 12 for independent, unfragmented media
            // datagrams. These do not participate in the reliable data window.
            if packet.type == 12, packet.body.count > 13, packet.body[0] == 1 {
                if packet.channel == audioChannel { update(.audioFrame(Data(packet.body.dropFirst(13)))) }
                else if packet.channel == videoChannel, preferredCodec == .pyrowave {
                    if packet.body.count >= 19, largeFragmentTraceCount < 32 {
                        let flags = packet.body[13]
                        let id = UInt16(packet.body[15]) | UInt16(packet.body[16]) << 8
                        if flags == 2 || flags == 4 || flags != 1 && (245...270).contains(id) {
                            largeFragmentTraceCount += 1
                            update(.diagnostic("Pyro fragment flags \(flags), offset \(packet.body[14]), id \(id), bytes \(packet.body.count), head \(packet.body.dropFirst(19).prefix(16).map { String(format: "%02x", $0) }.joined())"))
                        }
                    }
                    do {
                        if let codecPacket = try pyroAssembler.add(packet.body) {
                            deliverPyroWave(codecPacket)
                        }
                    } catch {
                        if newerPacketTraceCount < 12 {
                            newerPacketTraceCount += 1
                            update(.diagnostic("Skipped PyroWave fragment: \(packet.body.count) bytes, header \(packet.body.prefix(19).map { String(format: "%02x", $0) }.joined())"))
                        }
                    }
                }
            }
            return
        }
        if packet.channel == audioChannel, packet.type == 3 || packet.type == 4 {
            do {
                if audioWindow.hasPendingPackets, let previous = audioProgress,
                   Int32(bitPattern: packet.timestamp &- previous) > 13107 { waitingForAudioHead = true }
                if waitingForAudioHead {
                    guard packet.type == 3 else { return }
                    audioWindow.reset(nextID: packet.id); waitingForAudioHead = false
                }
                if audioProgress == nil { audioProgress = packet.timestamp }
                for body in try audioWindow.add(packet) {
                    guard body.count > 13, body[0] == 1 else { throw DiscoveryError.malformed }
                    audioProgress = packet.timestamp
                    if !reportedFirstAudio {
                        reportedFirstAudio = true
                        update(.diagnostic("First Steam Opus packet: \(body.count - 13) bytes"))
                    }
                    update(.audioFrame(Data(body.dropFirst(13))))
                }
            } catch { waitingForAudioHead = true }
            return
        }
        if packet.channel == videoChannel, packet.type == 3 || packet.type == 4 {
            do {
                if videoWindow.hasPendingPackets || videoAssembler.hasPartialFrame, let previous = lastMediaProgress, Int32(bitPattern: packet.timestamp &- previous) > 13107 {
                    videoLost(); lastMediaProgress = packet.timestamp
                }
                if waitingForVideoHead {
                    guard packet.type == 3 else { return }
                    videoWindow.reset(nextID: packet.id); waitingForVideoHead = false
                }
                if mediaTraceCount < 8 {
                    mediaTraceCount += 1
                    update(.diagnostic("Video packet id \(packet.id), fragment \(packet.fragment), bytes \(packet.body.count)"))
                }
                if lastMediaProgress == nil { lastMediaProgress = packet.timestamp }
                for body in try videoWindow.add(packet) {
                    lastMediaProgress = packet.timestamp
                    if preferredCodec == .pyrowave {
                        // PyroWave packets have the common media envelope (type,
                        // timestamp and frame metadata) but no HEVC subframe/NAL
                        // header. Feed the codec payload directly to its decoder.
                        guard body.count > 13, body[0] == 1 else {
                            update(.diagnostic("Invalid PyroWave media envelope: \(body.count) bytes"))
                            continue
                        }
                        deliverPyroWave(Data(body.dropFirst(13)))
                        continue
                    }
                    if waitingForKeyframe {
                        guard body.count >= 20, body[15] & 0x10 != 0 else { requestKeyframe(); continue }
                        waitingForKeyframe = false
                    }
                    if let frame = try videoAssembler.add(body) {
                        framesReceived += 1
                        if framesReceived == 1 { update(.diagnostic("Complete HEVC access unit: \(frame.count) bytes, NAL types \(SteamHEVCAssembler.nalTypes(frame))")) }
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - statisticsTime >= 1 {
                            update(.diagnostic("HEVC frames received: \(framesReceived)")); statisticsTime = now
                        }
                        update(.videoFrame(EncodedVideoFrame(codec: .hevc, data: frame,
                            presentationTime: CMTime(value: Int64(videoAssembler.timestamp), timescale: 65536))))
                    }
                }
            } catch { videoLost() }
            return
        }
        guard packet.channel == 1 else { return }
        if packet.type == 7 {
            pending.removeValue(forKey: packet.id)
            return
        }
        if packet.type == 8, let pending = pending[packet.id] { send(pending); return }
        guard packet.type == 5 || packet.type == 6 else { return }
        var ack = SteamSessionPacket(type: 7, source: localID, destination: remoteID, channel: 1,
            id: packet.id, body: SteamSessionPacket.littleEndian(packet.timestamp))
        ack.fragment = packet.fragment
        send(ack)
        if packet.fragment > 0 && packet.type == 5 {
            update(.diagnostic("Control fragment id \(packet.id), type \(packet.type), fragment \(packet.fragment), bytes \(packet.body.count)"))
        }
        for body in try controlWindow.add(packet) {
            if terminal { break }
            try handleControl(body)
        }
    }

    private func videoLost() {
        waitingForVideoHead = true; waitingForKeyframe = true; videoAssembler.reset()
        requestKeyframe()
    }
    private func deliverPyroWave(_ packet: Data) {
        if let size = SteamPyroWaveAssembler.sequenceDimensions(packet),
           size.width != activeVideoWidth || size.height != activeVideoHeight {
            guard size.width <= 3840, size.height <= 2160 else {
                finish(.failed("Steam sent unsupported PyroWave dimensions \(size.width)×\(size.height)")); return
            }
            activeVideoWidth = size.width; activeVideoHeight = size.height
            // Current experimental hosts can resize capture without a new
            // StartVideoData message. Reconfigure before submitting this image.
            update(.diagnostic("PyroWave frame size changed to \(size.width)×\(size.height)"))
            update(.startedVideo(codec: SteamVideoCodec.pyrowave.rawValue, width: size.width, height: size.height))
        }
        update(.pyrowavePacket(packet))
    }
    private func requestKeyframe() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastKeyframeRequest >= 0.2, let channel = videoChannel else { return }
        lastKeyframeRequest = now
        update(.diagnostic("Video loss detected; requesting a new HEVC keyframe"))
        send(SteamSessionPacket(type: 3, source: localID, destination: remoteID, channel: channel, id: nextVideoSendID, body: Data([2])))
        nextVideoSendID &+= 1
    }
    private func handleControl(_ body: Data) throws {
        guard let type = body.first else { throw DiscoveryError.malformed }
        let payload: Data
        if [1, 2, 6, 7].contains(type) { payload = Data(body.dropFirst()) }
        else {
            let decrypted = try SteamCryptography.decryptFrame(Data(body.dropFirst()), key: endpoint.sessionKey)
            guard decrypted.sequence == encryptedSequence else { throw SteamCryptoError.invalidKey }
            encryptedSequence += 1; payload = decrypted.payload
        }
        let message = try ProtoMessage(payload)
        switch type {
        case 7 where state == 1:
            guard message.bytes(1) != nil else { throw DiscoveryError.malformed }
            // Current Steam acknowledges the first client handshake through this
            // response rather than a standalone packet ACK. Its receipt is proven.
            pending = pending.filter { $0.value.body.first != 6 }
            state = 2
            update(.diagnostic("Steam server handshake received; authenticating session"))
            let auth = ProtoMessage.bytes(1, SteamCryptography.authenticationToken(key: endpoint.sessionKey))
                + ProtoMessage.integer(2, 1) + ProtoMessage.integer(3, endpoint.steamID)
            control(1, payload: auth)
        case 2 where state == 2:
            guard message.integer(1) == 0 else { finish(.failed("Steam rejected session authentication")); return }
            state = 3; update(.diagnostic("Steam session authenticated; awaiting codec offer"))
        case 3 where state == 3:
            let codecs = try Self.codecs(message)
            update(.diagnostic("Steam advertised video codec IDs: \(codecs.map(String.init).joined(separator: ", "))"))
            update(.offeredVideoCodecs(codecs))
            state = 4
            let name = preferredCodec == .pyrowave ? "PyroWave" : "HEVC"
            update(.diagnostic("Requesting \(name) video, \(width)×\(height) at 60 fps, \(bitrateKbps) Kbps, Opus stereo"))
            control(4, payload: Self.videoConfiguration(codec: preferredCodec, width: width, height: height, bitrateKbps: bitrateKbps, hostManaged: hostManagedVideo, wiredPyroBitrateKbps: wiredPyroBitrateKbps, videoPreferences: videoPreferences))
        case 4 where state == 4:
            guard let config = message.bytes(1) else { throw DiscoveryError.malformed }
            let selected = try ProtoMessage(config).integer(3)
            update(.diagnostic("Server negotiation fields: \(message.fields.keys.sorted())"))
            if let client = message.bytes(2) {
                let settings = try ProtoMessage(client)
                update(.diagnostic("Server startup video preferences: quality \(settings.integer(1).map(String.init) ?? "absent"), bytes \(client.count)"))
            }
            update(.diagnostic("Steam negotiated bootstrap video codec \(selected.map(String.init) ?? "unspecified")"))
            state = 5
            videoStartupDeadline = ProcessInfo.processInfo.systemUptime + 30
            control(5, payload: Data())
            if quitGameAfterNegotiation {
                videoStartupDeadline = nil
                // Allow the host to enter its active state after accepting configuration.
                queue.asyncAfter(deadline: .now() + 2) { [self] in
                    guard !terminal else { return }
                    control(83, payload: Data())
                    update(.gameQuitRequested)
                }
            }
            sendHID(hid.setSlots(controllerSlots))

        case 50 where state >= 5:
            guard let channel = message.integer(2), (2...255).contains(channel),
                  message.integer(3) == 3, message.integer(5) == 48000, message.integer(6) == 2 else {
                finish(.failed("Steam did not start supported 48 kHz Opus stereo audio")); return
            }
            // Started audio proves Steam processed our start-stream request.
            // Some hosts omit its standalone ACK; stop retransmitting that request.
            pending = pending.filter { $0.value.body.first != 5 }
            audioChannel = UInt8(channel)
            audioConfiguration = SteamAudioConfiguration(codec: 3, sampleRate: 48000, channels: 2, codecData: message.bytes(4) ?? Data())
            update(.startedAudio(audioConfiguration!))
            update(.diagnostic("Steam started Opus stereo: 48000 Hz, channel \(channel), codec data \(message.bytes(4)?.count ?? 0) bytes"))
        case 52 where state >= 5:
            videoStartupDeadline = nil
            let codec = message.integer(2) ?? 0
            update(.diagnostic("Steam started video codec \(codec), \(message.integer(4) ?? 0)×\(message.integer(5) ?? 0)"))
            guard codec == preferredCodec.rawValue else {
                let detail = preferredCodec == .pyrowave && codec == SteamVideoCodec.h264.rawValue
                    ? " Host accepted the PyroWave request but fell back to its H.264 encoder."
                    : ""
                finish(.failed("Steam started codec \(codec), but this session requested codec \(preferredCodec.rawValue).\(detail)")); return
            }
            guard let channel = message.integer(1), channel > 1, channel <= 255 else { throw DiscoveryError.malformed }
            if videoChannel != nil { videoWindow.reset(nextID: 0); videoAssembler.reset(); pyroAssembler = SteamPyroWaveAssembler() }
            videoChannel = UInt8(channel)
            if preferredCodec == .hevc {
                control(80, payload: ProtoMessage.bytes(1, Data("Apple VideoToolbox HEVC".utf8)) + ProtoMessage.integer(2, 1))
            } else {
                update(.diagnostic("Steam started PyroWave; receiving codec packets for the Apple TV GPU decoder"))
            }
            activeVideoWidth = message.integer(4) ?? 0; activeVideoHeight = message.integer(5) ?? 0
            update(.startedVideo(codec: codec, width: activeVideoWidth, height: activeVideoHeight))
            update(.diagnostic("Receiving video channel \(channel), codec configuration bytes \(message.bytes(3)?.count ?? 0)"))
        case 81 where state >= 5:
            if let title = message.string(1) { update(.title(title)) }
        case 98 where state >= 5:
            update(.diagnostic("Steam activity: \(message.integer(1) ?? 1); game \(message.integer(3) ?? 0)"))
        case 147 where state >= 5:
            finish(.failed("Steam capture failed (reason \(message.integer(1) ?? 0))"))
        case 83 where state >= 5, 129 where state >= 5:
            finish(.ended("Steam requested an exit (control \(type))"))
        case 99 where state >= 3:
            // Steam sends initial settings and live changes for the current session.
            // Persist client-owned choices, without decoder or transport state.
            if let config = message.bytes(1) {
                let settings = try ProtoMessage(config)
                update(.videoPreferences(try SteamVideoPreferences(config)))
                update(.diagnostic("Steam video settings updated: resolution \(settings.integer(2) ?? 0)×\(settings.integer(3) ?? 0), quality \(settings.integer(1).map(String.init) ?? "unspecified"), fps \(settings.integer(4) ?? 0)/\(settings.integer(5) ?? 1), bitrate \(settings.integer(6).map(String.init) ?? "automatic")"))
            }
        case 106 where state >= 5:
            if let data = message.bytes(1) {
                let requests = try ProtoMessage(data)
                update(.diagnostic("Steam RemoteHID command \((2...13).first(where: { requests.bytes($0) != nil }) ?? 0)"))
                for response in try hid.receive(data) { sendHID(response) }
            }
        case 9 where state >= 5: control(9, payload: Data())
        default: update(.diagnostic("Session control message \(type) received during codec probe"))
        }
    }
    static func codecs(_ message: ProtoMessage) throws -> [UInt64] {
        var codecs: [UInt64] = []
        for value in message.fields[3] ?? [] {
            switch value {
            case .integer(let codec): codecs.append(codec)
            case .bytes(let packed):
                var current: UInt64 = 0, shift = 0
                for byte in packed {
                    guard shift < 64, shift != 63 || byte <= 1 else { throw DiscoveryError.malformed }
                    current |= UInt64(byte & 127) << shift
                    if byte & 128 == 0 { codecs.append(current); current = 0; shift = 0 }
                    else { shift += 7 }
                    guard codecs.count <= 64 else { throw DiscoveryError.malformed }
                }
                guard shift == 0 else { throw DiscoveryError.malformed }
            }
        }
        return codecs
    }
    private func finish(_ result: SteamStreamUpdate) {
        guard !terminal else { return }
        terminal = true; timer?.cancel(); timer = nil; pending = [:]
        update(result)
        if remoteID != 0 {
            let disconnect = SteamSessionPacket(type: 9, source: localID, destination: remoteID, channel: 0, body: Data())
            try? connection?.send(disconnect.encoded())
        }
        connection?.cancel(); connection = nil
    }
}

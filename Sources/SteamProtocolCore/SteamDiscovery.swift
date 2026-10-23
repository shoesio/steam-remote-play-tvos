import Foundation
import Darwin
import OSLog

/// A serial queue owns the socket, sources, sequence and registry. UI callbacks
/// arrive on this queue; the SwiftUI model explicitly hops to the main actor.
public final class SteamDiscovery: @unchecked Sendable {
    public typealias Update = @Sendable ([SteamHost]) -> Void
    public typealias Failure = @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "SteamTV.discovery")
    private let logger = Logger(subsystem: "local.SteamTV", category: "Discovery")
    private let clientID: UInt64
    private let update: Update
    private let failure: Failure
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var registry = HostRegistry()
    private var sequence: UInt32 = 0
    private var descriptor: Int32 = -1
    private var lastPublished: [SteamHost] = []

    public init(clientID: UInt64, update: @escaping Update, failure: @escaping Failure) {
        self.clientID = clientID; self.update = update; self.failure = failure
    }
    public func start() { queue.async { [self] in open() } }
    public func stop() { queue.async { [self] in closeSocket() } }

    private func open() {
        guard reader == nil else { return }
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { report("socket"); return }
        var enabled: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            report("configure socket"); Darwin.close(fd); return
        }
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        local.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { report("bind"); Darwin.close(fd); return }
        descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.receive() }
        // Cancel handler retains only this descriptor, so a subsequent start
        // cannot accidentally close the new socket.
        source.setCancelHandler { Darwin.close(fd) }
        reader = source
        source.resume()
        let ticker = DispatchSource.makeTimerSource(queue: queue)
        ticker.schedule(deadline: .now(), repeating: 3)
        ticker.setEventHandler { [weak self] in self?.tick() }
        timer = ticker
        ticker.resume()
        logger.info("Discovering normal Steam hosts using native UDP port 27036")
    }
    private func closeSocket() {
        timer?.cancel(); timer = nil
        reader?.cancel(); reader = nil
        descriptor = -1
        for host in registry.hosts.values {
            registry.receive(.offline(host.id), address: host.address, port: host.discoveryPort,
                             now: ProcessInfo.processInfo.systemUptime)
        }
        publish()
        logger.info("Discovery stopped")
    }
    private func tick() {
        guard descriptor >= 0 else { return }
        let packet = DiscoveryPacket.request(clientID: clientID, sequence: sequence)
        sequence &+= 1
        for address in broadcastAddresses() {
            var target = sockaddr_in()
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            target.sin_family = sa_family_t(AF_INET)
            target.sin_port = UInt16(27036).bigEndian
            target.sin_addr.s_addr = address
            let sent = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &target) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(descriptor, bytes.baseAddress, bytes.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if sent != packet.count { report("broadcast") }
        }
        registry.expire(now: ProcessInfo.processInfo.systemUptime)
        publish()
    }
    private func receive() {
        guard descriptor >= 0 else { return }
        // Bound work per dispatch callback even on a noisy LAN.
        for _ in 0..<32 {
            var bytes = [UInt8](repeating: 0, count: 65535)
            var sender = sockaddr_in()
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, &bytes, bytes.count, 0, $0, &size)
                }
            }
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK { report("receive") }
                return
            }
            guard sender.sin_family == AF_INET else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sender.sin_addr, &text, socklen_t(text.count)) != nil else { continue }
            let address = String(cString: text)
            do {
                let event = try DiscoveryPacket.parse(Data(bytes.prefix(count)))
                if case .status(let status) = event {
                    guard status.clientID != clientID else { continue }
                    let previous = registry.hosts[status.clientID]
                    if previous?.online != true || previous?.address != address || previous?.status != status {
                        logger.info("Host \(status.hostname, privacy: .public) at \(address, privacy: .public), protocol \(status.protocolVersion), pairing unknown")
                    }
                }
                registry.receive(event, address: address, port: UInt16(bigEndian: sender.sin_port),
                                 now: ProcessInfo.processInfo.systemUptime)
                publish()
            } catch {
                logger.debug("Ignored malformed discovery datagram")
            }
        }
    }
    private func publish() {
        let hosts = registry.hosts.values.sorted { $0.id < $1.id }
        // lastSeen changes every reply; don't redraw solely for a heartbeat.
        let meaningful = hosts.count != lastPublished.count || zip(hosts, lastPublished).contains {
            $0.id != $1.id || $0.online != $1.online || $0.address != $1.address || $0.status != $1.status
        }
        if meaningful { lastPublished = hosts; update(hosts) }
    }
    private func report(_ operation: String) {
        let message = "Steam discovery \(operation): \(String(cString: strerror(errno)))"
        logger.error("\(message, privacy: .public)")
        failure(message)
    }
    private func broadcastAddresses() -> Set<in_addr_t> {
        var addresses: Set<in_addr_t> = [INADDR_BROADCAST]
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return addresses }
        defer { freeifaddrs(interfaces) }
        var cursor = interfaces
        while let current = cursor {
            let entry = current.pointee
            defer { cursor = entry.ifa_next }
            guard entry.ifa_flags & UInt32(IFF_UP | IFF_BROADCAST) == UInt32(IFF_UP | IFF_BROADCAST),
                  let broadcast = entry.ifa_dstaddr, broadcast.pointee.sa_family == AF_INET else { continue }
            addresses.insert(UnsafeRawPointer(broadcast).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr)
        }
        return addresses
    }
}

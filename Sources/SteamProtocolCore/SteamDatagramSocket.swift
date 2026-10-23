import Foundation
import Darwin

/// Connected UDP peer, drained in bounded batches on the session queue.
/// A large receive buffer absorbs Steam's frame bursts without queueing one
/// Network.framework callback for every individual media datagram.
final class SteamDatagramSocket {
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var buffer = [UInt8](repeating: 0, count: 65536)
    let receiveBufferBytes: Int32
    init(address: String, port: UInt16, queue: DispatchQueue,
         received: @escaping (Data) -> Void, failed: @escaping (String) -> Void) throws {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var peer = sockaddr_in()
        peer.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        peer.sin_family = sa_family_t(AF_INET); peer.sin_port = port.bigEndian
        var requested: Int32 = 4 * 1024 * 1024
        if setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &requested, socklen_t(MemoryLayout<Int32>.size)) != 0 {
            requested = 256 * 1024
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &requested, socklen_t(MemoryLayout<Int32>.size))
        }
        var actual: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
        _ = getsockopt(fd, SOL_SOCKET, SO_RCVBUF, &actual, &size)
        receiveBufferBytes = actual
        let valid = address.withCString { inet_pton(AF_INET, $0, &peer.sin_addr) } == 1
        let connected = withUnsafePointer(to: &peer) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard valid, connected == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
            Darwin.close(fd); throw error
        }
        descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            for _ in 0..<256 {
                guard self.descriptor >= 0 else { break }
                let count = self.buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
                if count < 0 {
                    if errno != EAGAIN && errno != EWOULDBLOCK { failed("UDP receive: \(errno)") }
                    break
                }
                if count == 0 { continue }
                self.buffer.withUnsafeBytes { received(Data(bytes: $0.baseAddress!, count: count)) }
            }
        }
        // The descriptor belongs to this source and is closed only after all
        // previously queued read handlers finish, including cancellation.
        source.setCancelHandler { Darwin.close(fd) }
        self.source = source; source.resume()
    }
    func send(_ data: Data) throws {
        guard descriptor >= 0 else { return }
        let written = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        if written < 0, errno != EAGAIN && errno != EWOULDBLOCK {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    func cancel() { descriptor = -1; source?.cancel(); source = nil }
    deinit { cancel() }
}

import Foundation
import CoreVideo

/// One newest frame: display never builds a queue behind the live stream.
final class VideoFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var image: CVPixelBuffer?
    private var pyroFrame: CNPyroWaveGPUFrame?
    private var count = 0
    func push(_ image: CVPixelBuffer) -> Int {
        lock.lock(); defer { lock.unlock() }
        self.image = image; count += 1; return count
    }
    func latest() -> (CVPixelBuffer, Int)? {
        lock.lock(); defer { lock.unlock() }
        return image.map { ($0, count) }
    }
    func push(_ frame: CNPyroWaveGPUFrame) -> Int {
        lock.lock()
        let stale = pyroFrame
        pyroFrame = frame; count += 1
        let total = count
        lock.unlock()
        stale?.markPresentationComplete(atTime: ProcessInfo.processInfo.systemUptime)
        return total
    }
    func takePyroFrame() -> CNPyroWaveGPUFrame? {
        lock.lock(); defer { lock.unlock() }
        let frame = pyroFrame; pyroFrame = nil; return frame
    }
    func clear() {
        lock.lock(); image = nil; let stale = pyroFrame; pyroFrame = nil; count = 0; lock.unlock()
        stale?.markPresentationComplete(atTime: ProcessInfo.processInfo.systemUptime)
    }
}

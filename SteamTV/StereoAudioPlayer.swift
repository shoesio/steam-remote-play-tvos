import Foundation
import AVFAudio

/// Serialized native audio decode/playback with bounded incoming and scheduled audio.
final class StereoAudioPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SteamTV.audio")
    private let lock = NSLock()
    private var packets: [Data] = []
    private var draining = false
    private var stopped = false
    private var overflowed = false
    private var decoder: OpusStereoDecoder?
    private var engine: AVAudioEngine?
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var scheduledFrames = 0
    private var generation = 0
    private var decodedPackets = 0
    private let diagnostic: @Sendable (String) -> Void
    init(diagnostic: @escaping @Sendable (String) -> Void) { self.diagnostic = diagnostic }
    func configure(_ config: SteamAudioConfiguration) {
        queue.async { [self] in
            do {
                guard config.codec == 3, config.codecData.isEmpty else { throw AudioDecoderError.unsupportedConfiguration }
                decoder = try OpusStereoDecoder(sampleRate: config.sampleRate, channels: config.channels)
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setPreferredSampleRate(48000)
                try session.setPreferredIOBufferDuration(0.01)
                try session.setActive(true)
                let engine = AVAudioEngine()
                engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
                self.engine = engine
                try engine.start(); player.play()
                diagnostic("Apple TV native Opus stereo playback started at 48000 Hz")
            } catch { diagnostic("Stereo audio setup failed: \(error)") }
        }
    }
    func enqueue(_ packet: Data) {
        guard packet.count <= 65535 else { return }
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        if packets.count >= 32 { packets.removeAll(keepingCapacity: true); overflowed = true }
        packets.append(packet)
        let start = !draining; draining = true
        lock.unlock()
        if start { queue.async { [self] in drain() } }
    }
    func stop() {
        lock.lock(); stopped = true; packets.removeAll(); lock.unlock()
        queue.async { [self] in
            generation += 1; player.stop(); engine?.stop(); engine = nil; decoder = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    private func drain() {
        while true {
            lock.lock()
            guard !stopped, !packets.isEmpty else { draining = false; lock.unlock(); return }
            let packet = packets.removeFirst(), reset = overflowed
            overflowed = false; lock.unlock()
            if reset { resetPlayback() }
            guard let decoder else { continue }
            do {
                let samples = try decoder.decode(packet)
                let frames = samples.count / 2
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                      let channels = buffer.floatChannelData else { continue }
                buffer.frameLength = AVAudioFrameCount(frames)
                for index in 0..<frames { channels[0][index] = samples[index * 2]; channels[1][index] = samples[index * 2 + 1] }
                if scheduledFrames + frames > 5760 { resetPlayback() }
                let current = generation
                scheduledFrames += frames
                player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { if self.generation == current { self.scheduledFrames = max(0, self.scheduledFrames - frames) } }
                }
                if !player.isPlaying { player.play() }
                decodedPackets += 1
                if decodedPackets == 1 || decodedPackets % 500 == 0 {
                    let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                    diagnostic(String(format: "Opus packets decoded: %d; scheduled %.0f ms; peak %.3f", decodedPackets, Double(scheduledFrames) / 48, peak))
                }
            } catch { diagnostic("Opus packet decode failed: \(error)") }
        }
    }
    private func resetPlayback() {
        generation += 1; player.stop(); scheduledFrames = 0
        diagnostic("Audio buffer reset to keep playback delay bounded")
    }
}

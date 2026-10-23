import Foundation
import SteamProtocolCore
import CoreMedia
import CoreVideo

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--decode-opus" {
    do {
        let decoder = try OpusStereoDecoder()
        let samples = try decoder.decode(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        print("Native Opus decoded: \(samples.count / 2) frames, stereo; peak \(samples.map { abs($0) }.max() ?? 0)")
        exit(0)
    } catch { fputs("Opus decode failed: \(error)\n", stderr); exit(1) }
}
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--decode-file" {
    do {
        var decoded = false
        let decoder = HEVCVideoDecoder { result in
            switch result {
            case .success(let image):
                decoded = true
                print("Hardware HEVC decoded: \(CVPixelBufferGetWidth(image))×\(CVPixelBufferGetHeight(image))")
            case .failure(let error): fputs("HEVC decode failed: \(error)\n", stderr)
            }
        }
        try decoder.submit(EncodedVideoFrame(codec: .hevc, data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])), presentationTime: .zero))
        decoder.waitForPendingFrames()
        exit(decoded ? 0 : 1)
    } catch { fputs("HEVC decode failed: \(error)\n", stderr); exit(1) }
}

let duration = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 15
let discovery = SteamDiscovery(clientID: UInt64.random(in: 1...UInt64.max), update: { hosts in
    for host in hosts {
        print("\(host.status.hostname) \(host.address):\(host.discoveryPort) \(host.online ? "online" : "offline") protocol=\(host.status.protocolVersion) pairing=unknown gamesRunning=\(host.status.gamesRunning.map(String.init) ?? "unknown")")
    }
}, failure: { message in fputs(message + "\n", stderr) })
print("Scanning Steam native UDP discovery for \(duration) seconds…")
discovery.start()
RunLoop.main.run(until: Date().addingTimeInterval(duration))
discovery.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.1))

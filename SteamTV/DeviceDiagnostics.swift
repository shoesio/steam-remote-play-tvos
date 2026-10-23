import Foundation
import OSLog
import UIKit

/// A small, redacted checkpoint file that Xcode/devicectl can read on a device.
/// No PINs, account IDs, tokens or keys are recorded.
@MainActor
enum DeviceDiagnostics {
    private static let logger = Logger(subsystem: "local.SteamTV", category: "Lifecycle")
    /// Preserve terminal events separately from the frequently replaced checkpoint.
    static func recordEvent(reason: String, expected: Bool, frames: Int, hosts: [SteamHost], trace: [String]) {
        let event: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "app": Bundle.main.bundleIdentifier ?? "SteamTV",
            "reason": reason, "expected": expected, "decodedFrames": frames,
            "hosts": hosts.map { ["hostname": $0.status.hostname, "online": $0.online,
                                   "gamesRunning": $0.status.gamesRunning.map { $0 as Any } ?? NSNull()] as [String: Any] },
            "trace": Array(trace.suffix(30))
        ]
        do {
            let directory = try FileManager.default.url(for: .cachesDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let file = directory.appendingPathComponent("SteamTV-session-events.json")
            var events = (try? Data(contentsOf: file)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]]
            } ?? []
            events.append(event)
            try JSONSerialization.data(withJSONObject: Array(events.suffix(50)), options: [.sortedKeys])
                .write(to: file, options: .atomic)
        } catch { logger.error("Cannot save session event: \(error.localizedDescription, privacy: .public)") }
    }
    static func save(clientID: UInt64?, hosts: [SteamHost], paired: Set<UInt64>, state: String, pairingTrace: [String]) {
        logger.info("\(state, privacy: .public)")
        let snapshot: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "deviceClientID": clientID.map(String.init) ?? "unavailable",
            "state": state,
            "sharedSettingsGroup": SteamSharedSettings.group,
            "controllerDeadzone": SteamSharedSettings.defaults.double(forKey: "SteamTV.deadzone"),
            "launchGameID": Bundle.main.object(forInfoDictionaryKey: "DirectGameID") as? String ?? "Big Picture",
            "controllerCount": UserDefaults.standard.integer(forKey: "SteamTV.controllerCount"),
            "screenSaverPrevented": UIApplication.shared.isIdleTimerDisabled,
            "lastStreamFailure": UserDefaults.standard.string(forKey: "SteamTV.lastStreamFailure") ?? "none",
            "lastVideoConfiguration": [
                "codec": UserDefaults.standard.integer(forKey: "SteamTV.activeVideoCodec"),
                "width": UserDefaults.standard.integer(forKey: "SteamTV.activeVideoWidth"),
                "height": UserDefaults.standard.integer(forKey: "SteamTV.activeVideoHeight"),
                "hostManagedVideo": UserDefaults.standard.bool(forKey: "SteamTV.hostManagedVideo"),
                "diagnosticBitrateOverrideKbps": UserDefaults.standard.bool(forKey: "SteamTV.hostManagedVideo") ? 0 : UserDefaults.standard.integer(forKey: "SteamTV.pyroBitrateKbps"),
                "receiver": UserDefaults.standard.string(forKey: "SteamTV.receiverInfo") ?? "unavailable"
            ],
            "pairingTrace": pairingTrace,
            "fragmentTrace": UserDefaults.standard.stringArray(forKey: "SteamTV.fragmentTrace") ?? [],
            "hosts": hosts.map { host -> [String: Any] in [
                "id": String(host.id), "hostname": host.status.hostname,
                "address": host.address, "online": host.online,
                "pairedLocally": paired.contains(host.id),
                "protocolVersion": host.status.protocolVersion
            ] }
        ]
        do {
            // tvOS permits disposable local files in Caches; pairing credentials
            // remain in Keychain and never depend on this checkpoint file.
            let directory = try FileManager.default.url(for: .cachesDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("SteamTV-status.json"), options: .atomic)
        } catch { logger.error("Cannot save diagnostic checkpoint: \(error.localizedDescription, privacy: .public)") }
    }
}

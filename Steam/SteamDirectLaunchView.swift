import Network
import SwiftUI

private enum SteamLaunchError: LocalizedError {
    case missingHost
    case powerSwitchNotFound(String, available: [String])
    case hostTimedOut

    var errorDescription: String? {
        switch self {
        case .missingHost:
            return "Set the BC-250 address in Apple TV Settings > Apps > Steam Solarflare."
        case .powerSwitchNotFound(let name, let available):
            let choices = available.isEmpty ? "No writable switches were returned by Apple Home." : "Available controls: \(available.joined(separator: ", "))."
            return "The Apple Home switch “\(name)” could not be found. \(choices)"
        case .hostTimedOut:
            return "The BC-250 powered on, but Solarflare did not become available."
        }
    }
}

struct SteamDirectLaunchView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(HomeKitPowerOutletStore.self) private var homeKitPowerOutletStore
    @Environment(SunshineHostStore.self) private var sunshineHostStore
    @State private var streamReady = false
    @State private var streamHost: SunshineHost?
    @State private var pairingHost: SunshineHost?
    @State private var pairingPIN: String?
    @State private var status = "Opening SteamOS…"
    @State private var errorMessage: String?
    @State private var launchTask: Task<Void, Never>?
    @State private var shouldResumeWhenActive = false
    @State private var streamWasLost = false

    var body: some View {
        ZStack {
            SteamLaunchBackground()
            if let pairingPIN, let pairingHost {
                SolarflarePairingView(pin: pairingPIN, host: pairingHost) { pairedHost in
                    completePairing(with: pairedHost)
                }
            } else if streamReady, let streamHost {
                SolarflareDirectStreamView(host: streamHost, onStreamEnded: streamEnded)
            } else {
                VStack(spacing: 28) {
                    Image("SteamMark").resizable().scaledToFit().frame(width: 460, height: 276)
                    Text(errorMessage == nil ? status : "Steam could not start")
                        .font(.title.weight(.semibold))
                    if streamWasLost {
                        Text("Press Back to return to Apple TV, or turn on the BC-250 and reconnect.")
                            .foregroundStyle(.secondary)
                        Button("Turn On & Connect", action: restart).buttonStyle(.borderedProminent)
                    } else if let errorMessage {
                        Text(errorMessage)
                            .font(.title2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 950)
                        Button("Try Again", action: restart).buttonStyle(.borderedProminent)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                }
            }
        }
        .task { start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                if shouldResumeWhenActive {
                    shouldResumeWhenActive = false
                    resumeStream()
                } else if streamWasLost, launchTask == nil {
                    reconnectOnReturnIfPowered()
                } else if !streamReady, pairingPIN == nil, launchTask == nil, !streamWasLost {
                    start()
                }
            case .background:
                if streamReady {
                    shouldResumeWhenActive = true
                    streamReady = false
                    streamHost = nil
                }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onDisappear {
            launchTask?.cancel()
            launchTask = nil
        }
    }

    private func start() {
        guard launchTask == nil else { return }
        print("[SteamLaunch] start host=\(SteamTVSettings.hostAddress)")
        errorMessage = nil
        streamWasLost = false
        status = "Checking the BC-250…"
        launchTask = Task {
            do {
                try await ensureHostIsOnAndReady()
                if let host = try await prepareSolarflareHost() {
                    streamHost = host
                    streamReady = true
                    status = "Opening SteamOS…"
                }
            } catch is CancellationError {
                print("[SteamLaunch] cancelled")
                return
            } catch {
                print("[SteamLaunch] failed: \(error.localizedDescription)")
                errorMessage = error.localizedDescription
            }
            launchTask = nil
        }
    }

    private func restart() {
        launchTask?.cancel()
        launchTask = nil
        streamReady = false
        streamHost = nil
        pairingPIN = nil
        pairingHost = nil
        errorMessage = nil
        streamWasLost = false
        start()
    }

    private func streamEnded() {
        launchTask?.cancel()
        launchTask = nil
        shouldResumeWhenActive = false
        streamReady = false
        streamHost = nil
        streamWasLost = true
        errorMessage = nil
        status = "SteamOS closed"
    }

    private func resumeStream() {
        guard launchTask == nil else { return }
        errorMessage = nil
        status = "Rejoining SteamOS…"
        launchTask = Task {
            do {
                if !(await Self.solarflareIsReachable()) {
                    try await ensureHostIsOnAndReady()
                }
                if let host = try await prepareSolarflareHost() {
                    streamHost = host
                    streamReady = true
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            launchTask = nil
        }
    }

    private func reconnectOnReturnIfPowered() {
        guard launchTask == nil else { return }
        status = "Checking the BC-250…"
        errorMessage = nil
        launchTask = Task {
            await homeKitPowerOutletStore.refresh()
            let foundSwitch = homeKitPowerOutletStore.selectOutlet(matching: SteamTVSettings.homeKitOutletName)
            let switchIsOn = foundSwitch ? homeKitPowerOutletStore.selectedOutlet?.isOn : nil
            let hostIsReachable = await Self.solarflareIsReachable()
            if switchIsOn == true || hostIsReachable {
                streamWasLost = false
                do {
                    try await ensureHostIsOnAndReady()
                    if let host = try await prepareSolarflareHost() {
                        streamHost = host
                        streamReady = true
                        status = "Opening SteamOS…"
                    }
                } catch is CancellationError {
                    return
                } catch {
                    errorMessage = error.localizedDescription
                }
            } else {
                status = "SteamOS closed"
                streamWasLost = true
            }
            launchTask = nil
        }
    }

    private func ensureHostIsOnAndReady() async throws {
        guard !SteamTVSettings.hostAddress.isEmpty else { throw SteamLaunchError.missingHost }
        if await Self.solarflareIsReachable() {
            print("[SteamLaunch] Solarflare reachable")
            status = "Opening SteamOS…"
            return
        }
        print("[SteamLaunch] Solarflare unreachable; checking Apple Home switch")
        status = "Turning on the BC-250…"
        await homeKitPowerOutletStore.refresh()
        let switchName = SteamTVSettings.homeKitOutletName
        guard homeKitPowerOutletStore.selectOutlet(matching: switchName) else {
            throw SteamLaunchError.powerSwitchNotFound(switchName, available: homeKitPowerOutletStore.outlets.map(\.displayName))
        }
        if let selected = homeKitPowerOutletStore.selectedOutlet {
            print("[SteamLaunch] Home control selected=\(selected.displayName) reachable=\(selected.isReachable) state=\(String(describing: selected.isOn))")
            if selected.isOn == true {
                // Home Assistant template switches can remain logically ON
                // after the host has powered down. Since reachability was
                // already checked above, reset the stale state to create a
                // genuine rising edge for the power-on automation.
                print("[SteamLaunch] Home control is stale ON while host is unreachable; resetting it")
                try await homeKitPowerOutletStore.setSelectedOutletPower(false)
                try await Task.sleep(for: .seconds(1))
            }
        }
        try await homeKitPowerOutletStore.setSelectedOutletPower(true)
        print("[SteamLaunch] power-on requested; waiting for Solarflare")
        status = "Waiting for the BC-250…"
        for _ in 0..<180 {
            try Task.checkCancellation()
            if await Self.solarflareIsReachable() {
                print("[SteamLaunch] Solarflare became reachable")
                status = "Opening SteamOS…"
                return
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw SteamLaunchError.hostTimedOut
    }

    private static func solarflareIsReachable() async -> Bool {
        let host = NWEndpoint.Host(SteamTVSettings.hostAddress)
        let rawPort = UInt16(clamping: SunshineHost.defaultHTTPPort)
        guard let port = NWEndpoint.Port(rawValue: rawPort) else { return false }
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "SteamSolarflare.ReadinessProbe")
            let connection = NWConnection(host: host, port: port, using: .tcp)
            var completed = false
            func finish(_ reachable: Bool) {
                guard !completed else { return }
                completed = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: reachable)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.0) { finish(false) }
        }
    }

    private func prepareSolarflareHost() async throws -> SunshineHost? {
        print("[SteamLaunch] fetching Solarflare server info")
        configureHostStoreFromTVSettings()
        guard var host = sunshineHostStore.host else { throw SteamLaunchError.missingHost }
        let info = try await SunshineClient().fetchServerInfo(host: host)
        if let httpsPort = info.httpsPort, httpsPort > 0 {
            host.httpsPort = httpsPort
            sunshineHostStore.httpsPort = httpsPort
            sunshineHostStore.save()
        }
        // Solarflare reports PairStatus=0 on its unauthenticated HTTP
        // /serverinfo endpoint by design. PairStatus becomes meaningful only
        // over client-certificate HTTPS, so do not discard a saved pairing
        // merely because the reachability probe is HTTP. The following
        // authenticated app-list/launch request will reject a genuinely stale
        // certificate and surface a real re-pair requirement.
        guard host.isPaired, host.serverCertificateDER != nil else {
            print("[SteamLaunch] no saved pairing; requesting PIN")
            host.isPaired = false
            pairingHost = host
            pairingPIN = sunshineHostStore.newPairingPIN()
            status = "Pair Solarflare"
            return nil
        }
        print("[SteamLaunch] saved pairing ready")
        return host
    }

    private func configureHostStoreFromTVSettings() {
        let configured = SteamTVSettings.host(preserving: sunshineHostStore.host)
        sunshineHostStore.name = configured.name
        sunshineHostStore.address = configured.address
        sunshineHostStore.httpPort = configured.httpPort
        sunshineHostStore.httpsPort = configured.httpsPort
        sunshineHostStore.macAddress = configured.macAddress
        sunshineHostStore.save()
    }

    private func completePairing(with host: SunshineHost) {
        sunshineHostStore.name = host.name
        sunshineHostStore.address = host.address
        sunshineHostStore.httpPort = host.httpPort
        sunshineHostStore.httpsPort = host.httpsPort
        sunshineHostStore.macAddress = host.macAddress
        sunshineHostStore.uniqueId = host.uniqueId
        sunshineHostStore.serverCertificateDER = host.serverCertificateDER
        sunshineHostStore.isPaired = true
        sunshineHostStore.save()
        pairingPIN = nil
        pairingHost = nil
        streamHost = host
        streamReady = true
        status = "Opening SteamOS…"
    }
}

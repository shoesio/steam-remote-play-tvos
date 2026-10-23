import Combine
import OSLog
import SwiftUI
import UIKit

private enum SolarflareDirectError: LocalizedError {
    case noHost
    case pairingRequired
    case noSteamApp
    case pyrowaveNotAdvertised(Int)
    case videoSurfaceUnavailable

    var errorDescription: String? {
        switch self {
        case .noHost:
            return "Set the BC-250 address in Apple TV Settings."
        case .pairingRequired:
            return "This Apple TV must be paired with Solarflare."
        case .noSteamApp:
            return "Solarflare did not return the configured Steam application."
        case .pyrowaveNotAdvertised(let flags):
            return String(format: "Solarflare did not advertise SDR PyroWave (ServerCodecModeSupport 0x%08x).", flags)
        case .videoSurfaceUnavailable:
            return "The Apple TV could not prepare the PyroWave video surface."
        }
    }
}

@MainActor
private final class SolarflareDirectCoordinator: ObservableObject {
    enum Phase: Equatable {
        case starting
        case connecting
        case streaming
        case failed(String)
    }

    @Published var phase: Phase = .starting
    @Published var videoView: CNMoonlightVideoView?

    private let client = SunshineClient()
    private let logger = Logger(subsystem: "SteamSolarflare", category: "Negotiation")
    private var bridge: CNMoonlightStreamBridge?
    private var inputSender: MoonlightInputSender?
    private var launchTask: Task<Void, Never>?
    private var didLogFirstVisibleFrame = false
    var onStreamEnded: (() -> Void)?

    // Solarflare src/nvhttp.cpp and Aurora's pinned Limelight.h agree on this bit.
    private static let scmPyroWave = 0x0080_0000

    func start(host: SunshineHost) {
        guard launchTask == nil, bridge == nil else { return }
        launchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.launch(host: host)
            } catch is CancellationError {
                return
            } catch {
                self.logger.error("Solarflare direct launch failed: \(error.localizedDescription, privacy: .public)")
                self.phase = .failed(error.localizedDescription)
            }
            self.launchTask = nil
        }
    }

    func stop() {
        launchTask?.cancel()
        launchTask = nil
        AmbientLightingController.shared.restoreOriginalLightState()
        inputSender?.stop()
        inputSender = nil
        bridge?.stop()
        bridge = nil
        videoView = nil
        didLogFirstVisibleFrame = false
        phase = .starting
    }

    func retry(host: SunshineHost) {
        stop()
        start(host: host)
    }

    private func launch(host: SunshineHost) async throws {
        guard host.isPaired, host.serverCertificateDER != nil else {
            throw SolarflareDirectError.pairingRequired
        }

        logger.info("Discovered host \(host.name, privacy: .public) at \(host.address, privacy: .public); pairing state=paired")
        let info = try await client.fetchServerInfo(host: host)
        let codecFlags = info.serverCodecModeSupport ?? 0
        logger.info("Solarflare serverinfo appVersion=\(info.appVersion ?? "unknown", privacy: .public) state=\(info.state ?? "unknown", privacy: .public) codecFlags=0x\(String(codecFlags, radix: 16), privacy: .public)")
        guard codecFlags & Self.scmPyroWave != 0 else {
            throw SolarflareDirectError.pyrowaveNotAdvertised(codecFlags)
        }

        let apps = try await client.fetchAppList(host: host)
        guard let app = selectSteamApp(from: apps) else {
            throw SolarflareDirectError.noSteamApp
        }
        let settings = SteamTVSettings.streamSettings
        logger.info("Selected Solarflare app id=\(app.appId, privacy: .public) title=\(app.title, privacy: .public)")
        logger.info("Requesting PyroWave-only profile resolution=\(settings.resolution, privacy: .public) fps=\(settings.fps) bitrate=\(settings.maxBitrateKbps) SDR Rec.709 4:2:0 adaptiveFec=0 adaptiveBitrate=0")

        let busy = info.state?.hasSuffix("_SERVER_BUSY") == true
        let current = info.currentGame?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldResume = busy && current == app.appId
        let result: SunshineLaunchResult
        if shouldResume {
            logger.info("Sending /resume appid=\(app.appId, privacy: .public)")
            result = try await client.resumeApp(host: host, appId: app.appId, settings: settings)
        } else {
            if busy {
                logger.info("Solarflare is running app=\(current ?? "unknown", privacy: .public); cancelling it before direct Steam launch")
                try await client.cancelRunningApp(host: host)
                try await waitForIdle(host: host)
            }
            logger.info("Sending /launch appid=\(app.appId, privacy: .public)")
            result = try await client.launchApp(host: host, appId: app.appId, settings: settings)
        }
        logger.info("Solarflare launch response status=\(result.statusCode) message=\(result.statusMessage, privacy: .public) rtsp=\(result.sessionUrl ?? "default", privacy: .public)")

        phase = .connecting
        guard let videoView = await waitForVideoSurface() else {
            throw SolarflareDirectError.videoSurfaceUnavailable
        }
        startMoonlight(host: host, info: info, result: result, settings: settings, videoView: videoView)
    }

    private func startMoonlight(
        host: SunshineHost,
        info: SunshineServerInfo,
        result: SunshineLaunchResult,
        settings: StreamSettings,
        videoView: CNMoonlightVideoView
    ) {
        let resolution = settings.resolution.split(separator: "x").compactMap { Int($0) }
        let width = resolution.first ?? 2560
        let height = resolution.dropFirst().first ?? 1440
        let bridge = CNMoonlightStreamBridge()
        self.bridge = bridge
        logger.info("Starting RTSP negotiation: advertised client codec=PyroWave only; expected DESCRIBE rtpmap=PYROWAVE/90000; ANNOUNCE bitStreamFormat=3")
        bridge.start(
            withHostAddress: host.address,
            appVersion: info.appVersion ?? "0.0.0",
            rtspSessionUrl: result.sessionUrl,
            serverCodecModeSupport: info.serverCodecModeSupport ?? 0,
            width: width,
            height: height,
            fps: settings.fps,
            bitrateKbps: settings.maxBitrateKbps,
            riKeyHex: result.riKeyHex,
            riKeyId: result.riKeyId,
            useFramePacing: settings.sunshineSmoothFramePacing,
            adaptiveBitrateEnabled: false,
            preferredVideoCodec: .pyroWaveExperimental,
            videoView: videoView
        ) { [weak self, weak bridge] state, message, code in
            guard let self else { return }
            self.logger.info("Moonlight/Solarflare state=\(state.rawValue) code=\(code) \(message, privacy: .public)")
            switch state {
            case .started:
                self.phase = .streaming
                if let bridge { self.startInput(bridge: bridge, videoView: videoView) }
            case .stageFailed, .terminated:
                self.phase = .failed(message)
                self.onStreamEnded?()
            default:
                break
            }
        }
    }

    private func startInput(bridge: CNMoonlightStreamBridge, videoView: CNMoonlightVideoView) {
        let sender = MoonlightInputSender(bridge: bridge)
        sender.deadzone = Float(SteamTVSettings.streamSettings.controllerDeadzone)
        sender.exitComboHandler = { [weak self] in self?.onStreamEnded?() }
        sender.onStatus = { [weak self] message in
            self?.logger.debug("Input: \(message, privacy: .public)")
        }
        videoView.remoteDirectionPressHandler = { direction, pressed in
            sender.setRemoteDirection(direction, pressed: pressed)
        }
        videoView.remoteSelectPressHandler = { pressed in
            sender.setRemoteSelectPressed(pressed)
        }
        videoView.remoteBackPressHandler = { pressed in
            sender.setRemoteBackPressed(pressed)
        }
        videoView.remoteMenuPressHandler = { pressed in
            sender.setRemoteSteamPressed(pressed)
        }
        videoView.menuPressHandler = { [weak self] in self?.onStreamEnded?() }
        sender.start()
        inputSender = sender
    }

    private func selectSteamApp(from apps: [SunshineGame]) -> SunshineGame? {
        let configuredID = SteamTVSettings.configuredAppID
        if !configuredID.isEmpty, let exact = apps.first(where: { $0.appId == configuredID }) {
            return exact
        }
        let wanted = normalized(SteamTVSettings.configuredAppName)
        if !wanted.isEmpty, let exact = apps.first(where: { normalized($0.title) == wanted }) {
            return exact
        }
        return apps.first { normalized($0.title).contains("steam") }
    }

    private func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func waitForIdle(host: SunshineHost) async throws {
        for _ in 0..<40 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
            if let info = try? await client.fetchServerInfo(host: host, fastFail: true),
               info.state?.hasSuffix("_SERVER_BUSY") != true {
                return
            }
        }
    }

    private func waitForVideoSurface() async -> CNMoonlightVideoView? {
        for _ in 0..<100 {
            if let videoView { return videoView }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

struct SolarflareDirectStreamView: View {
    let host: SunshineHost
    let onStreamEnded: () -> Void
    @StateObject private var coordinator = SolarflareDirectCoordinator()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            SolarflareVideoSurface(videoView: $coordinator.videoView)
                .ignoresSafeArea()

            if coordinator.phase != .streaming {
                VStack(spacing: 24) {
                    Image("SteamMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 460, height: 276)
                    switch coordinator.phase {
                    case .starting:
                        Text("Starting Steam…")
                            .font(.title.weight(.semibold))
                        ProgressView().controlSize(.large)
                    case .connecting:
                        Text("Connecting to SteamOS…")
                            .font(.title.weight(.semibold))
                        ProgressView().controlSize(.large)
                    case .failed(let message):
                        Text("Steam could not start")
                            .font(.title.weight(.semibold))
                        Text(message).font(.title3).foregroundStyle(.secondary)
                        Button("Try Again") { coordinator.retry(host: host) }
                            .buttonStyle(.borderedProminent)
                    case .streaming:
                        EmptyView()
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 950)
            }
        }
        .task {
            coordinator.onStreamEnded = onStreamEnded
            coordinator.start(host: host)
        }
        .onDisappear { coordinator.stop() }
    }
}

private struct SolarflareVideoSurface: UIViewRepresentable {
    @Binding var videoView: CNMoonlightVideoView?

    func makeUIView(context: Context) -> CNMoonlightVideoView {
        let view = CNMoonlightVideoView(frame: .zero)
        view.backgroundColor = .black
        view.suppressesSystemPresses = true
        DispatchQueue.main.async {
            videoView = view
            view.becomeFirstResponder()
        }
        return view
    }

    func updateUIView(_ uiView: CNMoonlightVideoView, context: Context) {}

    static func dismantleUIView(_ uiView: CNMoonlightVideoView, coordinator: Void) {
        uiView.remoteDirectionPressHandler = nil
        uiView.remoteSelectPressHandler = nil
        uiView.remoteBackPressHandler = nil
        uiView.remoteMenuPressHandler = nil
        uiView.menuPressHandler = nil
    }
}

struct SolarflarePairingView: View {
    let pin: String
    let host: SunshineHost
    let onPaired: (SunshineHost) -> Void
    @State private var status = "Enter this PIN in Solarflare"
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 26) {
            Image("SteamMark")
                .resizable()
                .scaledToFit()
                .frame(width: 460, height: 276)
            Text(status).font(.title.weight(.semibold))
            HStack(spacing: 12) {
                ForEach(Array(pin.enumerated()), id: \.offset) { _, digit in
                    Text(String(digit))
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 74, height: 88)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Text("Open Solarflare’s web interface, enter the PIN, and keep this screen open.")
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.large)
            }
        }
        .frame(maxWidth: 950)
        .task { await pair() }
    }

    private func pair() async {
        do {
            let outcome = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let pairer = CNMoonlightPairer(
                        address: host.address,
                        httpPort: host.httpPort,
                        httpsPort: host.httpsPort,
                        deviceName: "Steam Solarflare tvOS"
                    )
                    do { continuation.resume(returning: try pairer.pair(withPIN: pin)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            var pairedHost = host
            pairedHost.name = outcome.hostName ?? host.name
            pairedHost.uniqueId = outcome.uniqueId ?? host.uniqueId
            pairedHost.httpsPort = outcome.httpsPort > 0 ? outcome.httpsPort : host.httpsPort
            pairedHost.serverCertificateDER = outcome.serverCertificateDER ?? host.serverCertificateDER
            pairedHost.isPaired = true
            status = "Solarflare paired"
            onPaired(pairedHost)
        } catch {
            errorMessage = error.localizedDescription
            status = "Pairing failed"
        }
    }
}

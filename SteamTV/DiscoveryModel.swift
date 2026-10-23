import Foundation
import SwiftUI
import CoreMedia
import CoreVideo
import Metal
import UIKit

private final class PyroWaveDecoderSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var decoder: SteamPyroWaveBridge?
    var value: SteamPyroWaveBridge? {
        get { lock.lock(); defer { lock.unlock() }; return decoder }
        set { lock.lock(); decoder = newValue; lock.unlock() }
    }
}

@MainActor
final class DiscoveryModel: ObservableObject {
    @Published var hosts: [SteamHost] = []
    @Published var message = "Discovering Steam hosts…"
    @Published var pairingPIN: String?
    @Published var pairedHosts: Set<UInt64> = []
    @Published var pairingHostID: UInt64?
    @Published var connecting = false
    @Published var selectedHostID: UInt64?
    private var active = false
    private let ownership = SteamSessionOwnership(container: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SteamSharedSettings.group), appID: Bundle.main.bundleIdentifier ?? "SteamTV")
    private var ownershipTask: Task<Void, Never>?
    private var mayConnectAt: TimeInterval = 0
    private var waitingForWokenHost = false
    private var coldGameLaunch = false
    private var gameCaptureTask: Task<Void, Never>?
    private var wantsConnection = true
    private var wakeTask: Task<Void, Never>?
    private let power = SteamHomePower()
    @Published var launcherError = false
    private var gameExitMonitor: SteamGameExitMonitor?
    private var gameExitHostID: UInt64?
    @Published var streamActive = false
    @Published var loadingGame: SteamRecentGame?
    private var libraryPageTask: Task<Void, Never>?
    private var requestedLibraryGameID: UInt64?
    private var requestedHostID: UInt64?
    private var requestedGameID: UInt64? = (Bundle.main.object(forInfoDictionaryKey: "DirectGameID") as? String).flatMap(UInt64.init)
    private lazy var controllerInput = SteamControllerInput { [weak self] in self?.closeGameAndExit() }

    private var requestedExitShortcut: String? {
        if let requestedGameID, Bundle.main.object(forInfoDictionaryKey: "SteamTVIsParent") as? Bool == true {
            return SteamRecentLibrary.store?.load()?.games.first(where: { $0.id == String(requestedGameID) })?.exitShortcut
        }
        return Bundle.main.object(forInfoDictionaryKey: "DirectGameExitShortcut") as? String
    }

    func open(_ url: URL) {
        let scheme = Bundle.main.object(forInfoDictionaryKey: "DirectGameURLScheme") as? String ?? "steamtv"
        guard url.scheme == scheme, url.host == "launch" || (url.host == "library" && Bundle.main.object(forInfoDictionaryKey: "SteamTVIsParent") as? Bool == true) else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if Bundle.main.object(forInfoDictionaryKey: "DirectGameID") == nil { requestedGameID = components?.queryItems?.first(where: { $0.name == "app" })?.value.flatMap(UInt64.init) }
        let selectedGameID = components?.queryItems?.first(where: { $0.name == "app" })?.value
        loadingGame = SteamRecentLibrary.store?.load()?.games.first { $0.id == selectedGameID }
        requestedLibraryGameID = url.host == "library" ? components?.queryItems?.first(where: { $0.name == "app" })?.value.flatMap(UInt64.init) : nil
        if url.host == "library" { requestedGameID = nil }
        requestedHostID = components?.queryItems?.first(where: { $0.name == "host" })?.value.flatMap(UInt64.init)
        cancelConnection(userInitiated: false)
        retry()
    }
    func retry() {
        wantsConnection = true; launcherError = false
        if !active { start() } else { connectIfReady(); scheduleWake() }
    }
    private func connectIfReady() {
        guard active, ownership.isOwner, ProcessInfo.processInfo.systemUptime >= mayConnectAt, wantsConnection, !connecting, connectionAttempt == nil, pairing == nil else { return }
        let remembered = SteamSharedSettings.defaults.string(forKey: "SteamTV.lastHostID").flatMap(UInt64.init)
        let name = SteamSharedSettings.defaults.string(forKey: "SteamTV.hostName") ?? "bc-250"
        let candidate = requestedHostID.map { target in hosts.first { $0.online && $0.id == target } }
            ?? (hosts.first { $0.online && $0.status.hostname.caseInsensitiveCompare(name) == .orderedSame }
            ?? hosts.first { $0.online && $0.id == remembered })
        if let candidate {
            if waitingForWokenHost {
                waitingForWokenHost = false
                coldGameLaunch = true
                mayConnectAt = ProcessInfo.processInfo.systemUptime + 20
                message = "Steam is starting…"; checkpoint()
                return
            }
            wakeTask?.cancel(); wakeTask = nil; play(candidate)
        }
    }
    private func scheduleWake() {
        guard wakeTask == nil, wantsConnection else { return }
        wakeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(8))
                guard let self, self.active, self.wantsConnection, self.connectionAttempt == nil, self.pairing == nil else { return }
                self.message = "Turning on your Steam PC…"; self.checkpoint()
                self.waitingForWokenHost = true
                try await self.power.turnOn(named: SteamSharedSettings.defaults.string(forKey: "SteamTV.homeSwitch") ?? "BC-250")
                self.message = "Waiting for Steam to start…"; self.checkpoint()
                try await Task.sleep(for: .seconds(150))
                guard self.connectionAttempt == nil else { return }
                self.wantsConnection = false; self.launcherError = true; self.message = "Steam is not available yet. Check the PC and try again."; self.checkpoint()
            } catch is CancellationError { } catch {
                guard let self, self.active else { return }
                self.wantsConnection = false; self.launcherError = true; self.message = error.localizedDescription; self.checkpoint()
            }
            self?.wakeTask = nil
        }
    }
    private func connectionFailed(_ reason: String) {
        DeviceDiagnostics.recordEvent(reason: reason, expected: false, frames: decodedFrames, hosts: hosts, trace: pairingTrace)
        UserDefaults.standard.set(reason, forKey: "SteamTV.lastStreamFailure")
        cancelConnection()
        guard active, ownership.isOwner else { return }
        launcherError = true
        message = "The stream disconnected. Choose Rejoin to reconnect.\n\(reason)"
        checkpoint()
    }
    private var reopenAfterExit = false
    private var gameCloseTask: Task<Void, Never>?
    private var gameHandoverTask: Task<Void, Never>?
    func closeGameAndExit() {
        guard gameCloseTask == nil else { return }
        guard let codecProbe, connectionAttempt != nil else { exitToHome(); return }
        controllerInput.pause()
        wantsConnection = false
        message = "Closing game in Steam…"; checkpoint()
        if requestedExitShortcut == "controllerStartSelect" {
            codecProbe.requestConfiguredControllerExit()
        } else {
            codecProbe.requestGameExit()
        }
        let attempt = connectionAttempt
        gameCloseTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.active, self.connectionAttempt == attempt else { return }
            self.gameCloseTask = nil
            self.connectionFailed("Steam did not confirm the game closed. Close it in Steam before launching another game.")
        }
    }
    func exitToHome(reason: String = "User returned to Home") {
        DeviceDiagnostics.recordEvent(reason: reason, expected: true, frames: decodedFrames, hosts: hosts, trace: pairingTrace)
        cancelConnection()
        stop()
        reopenAfterExit = true
        message = "Session ended"; checkpoint()
        #if DEBUG
        // Developer builds only: tvOS has no public API for opening its Home UI.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            let application = UIApplication.shared
            let selector = NSSelectorFromString("suspend")
            if application.responds(to: selector) { application.perform(selector) }
            else { Darwin.exit(0) }
        }
        #else
        message = "Session ended. Press the TV button to return Home."; checkpoint()
        #endif
    }
    private func beganStreaming() {
        streamActive = true; launcherError = false
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--test-game-exit") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                self.closeGameAndExit()
            }
        }
        #endif
        UIApplication.shared.isIdleTimerDisabled = true
    }
    private var discovery: SteamDiscovery?
    private var pairing: SteamPairing?
    private var sessionRequest: SteamSessionRequest?
    private var probedSession = false
    @Published var videoFrame: CVPixelBuffer?
    @Published var hasPyroFrame = false
    let frameMailbox = VideoFrameMailbox()
    private var decodedFrames = 0
    private var audioPlayer: StereoAudioPlayer?
    private var videoDecoder: HEVCVideoDecoder?
    private var pyroDecoder: SteamPyroWaveBridge?
    private var codecProbe: SteamStreamingSession?
    private var connectionAttempt: UUID?
    private var identity: SteamDeviceIdentity?
    private var pairingAttempt: UUID?
    private var pairingTrace: [String] = []
    private let pairingStore = PairingStore(accessGroup: "286K3K83X3.dev.steamtv.client")

    func start() {
        if active && ownership.isOwner { return }
        if active { stop() }
        SteamSharedSettings.prepare()
        if Bundle.main.object(forInfoDictionaryKey: "SteamTVIsParent") as? Bool == true {
            Task { _ = await SteamRecentLibrary.shared.refresh() }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--library-only") { wantsConnection = false }
        #endif
        if reopenAfterExit { wantsConnection = true; reopenAfterExit = false }
        do { try ownership.claim() } catch {
            launcherError = true; message = error.localizedDescription; checkpoint(); return
        }
        mayConnectAt = ProcessInfo.processInfo.systemUptime + 0.75
        ownershipTask?.cancel()
        ownershipTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.active else { return }
                guard self.ownership.isOwner else {
                    self.stop(); self.message = "Another Steam app is open"; self.checkpoint(); return
                }
                self.connectIfReady()
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--pyrowave") { SteamSharedSettings.defaults.set(9, forKey: "SteamTV.preferredVideoCodec") }
        if ProcessInfo.processInfo.arguments.contains("--hevc") { SteamSharedSettings.defaults.set(5, forKey: "SteamTV.preferredVideoCodec") }
        if ProcessInfo.processInfo.arguments.contains("--4k") { UserDefaults.standard.set(true, forKey: "SteamTV.pyro4K") }
        if ProcessInfo.processInfo.arguments.contains("--1080p") { UserDefaults.standard.set(false, forKey: "SteamTV.pyro4K") }
        if let bitrate = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--pyro-bitrate=") }).flatMap({ Int($0.dropFirst(15)) }) {
            UserDefaults.standard.set(min(500000, max(10000, bitrate)), forKey: "SteamTV.pyroBitrateKbps")
        }
        UserDefaults.standard.register(defaults: ["SteamTV.hostName": "bc-250", "SteamTV.homeSwitch": "BC-250", "SteamTV.deadzone": 0.15])
        active = true
        if wantsConnection { message = "Discovering Steam hosts…" }
        if discovery == nil {
            // This identifier is public protocol metadata. Pairing secrets will
            // belong in Keychain when milestone 2 is verified.
            let defaults = UserDefaults.standard
            let stored = defaults.string(forKey: "SteamTV.discoveryClientID").flatMap(UInt64.init)
            let candidateID = stored ?? UInt64.random(in: 1...UInt64.max)
            do { identity = try pairingStore.identity(clientID: candidateID) }
            catch {
                active = false
                launcherError = true
                message = "Cannot load pairing identity: \(error.localizedDescription)"
                return
            }
            let clientID = identity!.clientID
            defaults.set(String(clientID), forKey: "SteamTV.discoveryClientID")
            discovery = SteamDiscovery(clientID: clientID, update: { [weak self] hosts in
                Task { @MainActor in
                    guard let self, self.active else { return }
                    if let hostID = self.gameExitHostID,
                       let host = hosts.first(where: { $0.id == hostID && $0.online }),
                       self.gameExitMonitor?.update(gamesRunning: host.status.gamesRunning) == true {
                        if let gameID = self.requestedGameID { self.ownership.gameEnded(hostID: hostID, gameID: gameID) }
                        self.exitToHome(reason: "Steam confirmed the game closed (discovery)")
                        return
                    }
                    if Bundle.main.object(forInfoDictionaryKey: "SteamTVIsParent") as? Bool == true,
                       let host = hosts.first(where: { $0.online && $0.status.hostname.caseInsensitiveCompare(SteamSharedSettings.defaults.string(forKey: "SteamTV.hostName") ?? "bc-250") == .orderedSame }) {
                        SteamRecentLibrary.configure(hostAddress: host.address)
                        Task { _ = await SteamRecentLibrary.shared.refresh() }
                    }
                    self.hosts = hosts.sorted { $0.status.hostname.localizedCaseInsensitiveCompare($1.status.hostname) == .orderedAscending }
                    do {
                        self.pairedHosts = Set(try hosts.compactMap {
                            try self.pairingStore.pairedHost($0.id) != nil ? $0.id : nil
                        })
                    } catch { self.message = "Cannot read pairing state: \(error.localizedDescription)"; return }
                    if self.pairing == nil && self.connectionAttempt == nil && !self.launcherError && self.wakeTask == nil {
                        self.message = hosts.contains(where: \.online) ? "Host found" : "Discovering Steam hosts…"
                    }
                    self.checkpoint()
                    self.connectIfReady()
                    #if DEBUG
                    let target = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--pair-host=") || $0.hasPrefix("--probe-host=") })?.split(separator: "=", maxSplits: 1).last.map(String.init)
                    if let target, !self.probedSession,
                       let host = self.hosts.first(where: { $0.online && $0.status.hostname == target }) {
                        self.probedSession = true
                        self.play(host)
                    }
                    #endif
                }
            }, failure: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.active else { return }
                    self.message = message
                    self.checkpoint()
                }
            })
        }
        discovery?.start()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--test-exit-home") {
            Task { @MainActor in try? await Task.sleep(for: .seconds(1)); self.exitToHome() }
        } else { connectIfReady(); scheduleWake() }
        #else
        connectIfReady(); scheduleWake()
        #endif
        checkpoint()
    }
    func stop() {
        // A Top Shelf target belongs only to this foreground session.
        // Normal icon launches should open Steam without relaunching the previous tile.
        if Bundle.main.object(forInfoDictionaryKey: "SteamTVIsParent") as? Bool == true {
            loadingGame = nil
            requestedGameID = nil
            requestedLibraryGameID = nil
            requestedHostID = nil
            wantsConnection = true
        }
        guard active else { return }
        active = false
        ownershipTask?.cancel(); ownershipTask = nil
        wakeTask?.cancel(); wakeTask = nil
        cancelPairing()
        cancelConnection(userInitiated: false)
        discovery?.stop()
        hosts = hosts.map { var host = $0; host.online = false; return host }
        message = "Disconnected"
        checkpoint()
    }
    func play(_ host: SteamHost) {
        guard active, ownership.isOwner, host.online, pairing == nil, !connecting, let identity else { return }
        wakeTask?.cancel(); wakeTask = nil
        selectedHostID = host.id
        wantsConnection = true; launcherError = false
        SteamSharedSettings.defaults.set(String(host.id), forKey: "SteamTV.lastHostID")
        SteamSharedSettings.defaults.set(host.status.hostname, forKey: "SteamTV.hostName")
        if pairedHosts.contains(host.id) {
            probeSession(host)
            return
        }
        pairingHostID = host.id
        pairingTrace = []
        let attempt = UUID()
        pairingAttempt = attempt
        let operation = SteamPairing(host: host, identity: identity) { [weak self] update in
            Task { @MainActor in
                guard let self, self.active, self.ownership.isOwner, self.pairingAttempt == attempt else { return }
                switch update {
                case .awaitingApproval(let pin):
                    self.pairingPIN = pin
                    self.message = "Enter this PIN in Steam on \(host.status.hostname)."
                case .inProgress: self.message = "Waiting for Steam approval…"
                case .succeeded(let paired):
                    do {
                        try self.pairingStore.save(paired)
                        self.pairedHosts.insert(paired.hostID)
                        self.message = "Paired. Ready to connect."
                    } catch { self.message = "Pairing succeeded but could not be saved: \(error.localizedDescription)" }
                    self.finishPairing()
                    if self.pairedHosts.contains(host.id) { self.probeSession(host) }
                case .failed(let message): self.message = message; self.launcherError = true; self.wantsConnection = false; self.finishPairing()
                case .cancelled: self.message = "Pairing cancelled"; self.finishPairing()
                case .diagnostic(let trace):
                    self.pairingTrace.append(trace)
                    self.pairingTrace = Array(self.pairingTrace.suffix(30))
                }
                self.checkpoint()
            }
        }
        pairing = operation
        message = "Pairing…"
        operation.start()
        checkpoint()
    }
    private func closePreviousGame(_ host: SteamHost, gameID: UInt64) {
        guard let identity else { return }
        do {
            guard let paired = try pairingStore.pairedHost(host.id) else { return }
            let attempt = UUID()
            connectionAttempt = attempt; connecting = true
            message = "Closing previous game in Steam…"; checkpoint()
            let controllerExit = ownership.recordedExitShortcut(hostID: host.id) == "controllerStartSelect"
            sessionRequest = SteamSessionRequest(host: host, identity: identity, paired: paired, width: 3840, height: 2160, gameID: controllerExit ? nil : gameID, streamInterface: controllerExit ? 3 : nil) { [weak self] update in
                Task { @MainActor in
                    guard let self, self.active, self.ownership.isOwner, self.connectionAttempt == attempt else { return }
                    switch update {
                    case .diagnostic(let trace): self.pairingTrace.append(trace)
                    case .failed(let reason): self.connectionFailed(reason)
                    case .ready(let endpoint):
                        self.sessionRequest = nil
                        let codec: SteamVideoCodec = SteamSharedSettings.defaults.integer(forKey: "SteamTV.preferredVideoCodec") == 9 ? .pyrowave : .hevc
                        let preferences = SteamSharedSettings.defaults.data(forKey: SteamSharedSettings.profileKey(host: host.id, codec: codec)).flatMap { try? SteamVideoPreferences($0) }
                        self.codecProbe = SteamStreamingSession(endpoint: endpoint, preferredCodec: codec, width: 3840, height: 2160, hostManagedVideo: true, videoPreferences: preferences, quitGameAfterNegotiation: !controllerExit) { [weak self] update in
                            Task { @MainActor in
                                guard let self, self.active, self.ownership.isOwner, self.connectionAttempt == attempt else { return }
                                switch update {
                                case .startedVideo where controllerExit:
                                    guard self.gameHandoverTask == nil else { return }
                                    self.waitForPreviousGame(host, gameID: gameID, attempt: attempt, controllerExit: true)
                                case .gameQuitRequested:
                                    self.waitForPreviousGame(host, gameID: gameID, attempt: attempt)
                                case .diagnostic(let trace), .ended(let trace): self.pairingTrace.append(trace)
                                case .failed(let reason):
                                    if self.gameHandoverTask == nil { self.connectionFailed(reason) }
                                    else { self.pairingTrace.append(reason) }
                                default: break // A handover never presents or plays the old game's media.
                                }
                                self.pairingTrace = Array(self.pairingTrace.suffix(30)); self.checkpoint()
                            }
                        }
                        if controllerExit { self.codecProbe?.setControllerSlots([0]) }
                        self.codecProbe?.start()
                    }
                    self.checkpoint()
                }
            }
            sessionRequest?.start()
        } catch { connectionFailed(error.localizedDescription) }
    }
    private func waitForPreviousGame(_ host: SteamHost, gameID: UInt64, attempt: UUID, controllerExit: Bool = false) {
        guard gameHandoverTask == nil else { return }
        gameHandoverTask = Task { [weak self] in
            if controllerExit {
                // The Desktop endpoint reports video before game focus and Steam Input settle.
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, self.active, self.ownership.isOwner, self.connectionAttempt == attempt else { return }
                self.codecProbe?.requestConfiguredControllerExit()
            }
            for _ in 0..<40 {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.active, self.ownership.isOwner, self.connectionAttempt == attempt else { return }
                if let latest = self.hosts.first(where: { $0.id == host.id && $0.online }), latest.status.gamesRunning == false {
                    self.ownership.gameEnded(hostID: host.id, gameID: gameID)
                    self.cancelConnection(userInitiated: false)
                    self.probeSession(latest)
                    return
                }
            }
            self?.connectionFailed("Steam could not close the previous game. Close it in Steam, then choose Rejoin.")
        }
    }
    private func probeSession(_ host: SteamHost, desktopCapture: Bool = false) {
        guard let identity else { return }
        if let appID = requestedLibraryGameID {
            guard libraryPageTask == nil else { return }
            connecting = true
            message = "Opening Steam library entry…"; checkpoint()
            libraryPageTask = Task { [weak self] in
                do {
                    try await SteamRecentLibrary.shared.openLibrary(gameID: appID, hostAddress: host.address)
                    try await Task.sleep(for: .milliseconds(750))
                    guard let self, self.active, self.ownership.isOwner, self.requestedLibraryGameID == appID else { return }
                    self.requestedLibraryGameID = nil; self.libraryPageTask = nil; self.connecting = false
                    self.probeSession(host)
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    self.libraryPageTask = nil
                    self.connectionFailed(error.localizedDescription)
                }
            }
            return
        }
        do {
            guard let paired = try pairingStore.pairedHost(host.id) else { return }
            if !desktopCapture, let gameID = requestedGameID {
                do { try ownership.prepareGameLaunch(hostID: host.id, gameID: gameID, gamesRunning: host.status.gamesRunning, exitShortcut: requestedExitShortcut) }
                catch SteamSessionOwnership.OwnershipError.anotherGameRunning {
                    if let previous = ownership.recordedGame(hostID: host.id), previous != gameID {
                        closePreviousGame(host, gameID: previous)
                        return
                    }
                    throw SteamSessionOwnership.OwnershipError.anotherGameRunning
                }
            }
            let attempt = UUID()
            connectionAttempt = attempt; connecting = true
            UserDefaults.standard.removeObject(forKey: "SteamTV.lastStreamFailure")
            pairingTrace = []
            let preferredCodec: SteamVideoCodec = SteamSharedSettings.defaults.integer(forKey: "SteamTV.preferredVideoCodec") == 9 ? .pyrowave : .hevc
            UserDefaults.standard.set(!ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--pyro-bitrate=") }), forKey: "SteamTV.hostManagedVideo")
            let profileKey = SteamSharedSettings.profileKey(host: host.id, codec: preferredCodec)
            #if DEBUG
            if let encoded = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--restore-video-profile=") })?.dropFirst(24),
               let data = Data(base64Encoded: String(encoded)), let profile = try? SteamVideoPreferences(data) {
                SteamSharedSettings.defaults.set(profile.data, forKey: profileKey)
            }
            #endif
            let profile = SteamSharedSettings.defaults.data(forKey: profileKey).flatMap { try? SteamVideoPreferences($0) }
            let storedBitrate = UserDefaults.standard.integer(forKey: "SteamTV.pyroBitrateKbps")
            let bitrate: UInt64 = preferredCodec == .pyrowave ? UInt64(storedBitrate == 0 ? 100000 : storedBitrate) : 30000
            let fourK = true // Display capability, not a saved video-quality setting.
            let width: UInt64 = fourK ? 3840 : 1920
            let height: UInt64 = fourK ? 2160 : 1080
            sessionRequest = SteamSessionRequest(host: host, identity: identity, paired: paired, width: width, height: height, gameID: desktopCapture ? nil : requestedGameID, streamInterface: desktopCapture || ProcessInfo.processInfo.arguments.contains("--desktop-capture") ? 3 : nil) { [weak self] update in
                Task { @MainActor in
                    guard let self, self.active, self.ownership.isOwner, self.connectionAttempt == attempt else { return }
                    switch update {
                    case .diagnostic(let trace):
                        self.pairingTrace.append(trace)
                        self.pairingTrace = Array(self.pairingTrace.suffix(30))
                    case .ready(let endpoint):
                        if !desktopCapture, let gameID = self.requestedGameID, (gameID >> 24) & 0xff == 2 {
                            self.sessionRequest = nil
                            self.message = "Waiting for the game to open…"
                            let delay = self.coldGameLaunch ? 10 : 5
                            self.coldGameLaunch = false
                            self.gameCaptureTask = Task { [weak self] in
                                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                                guard let self, self.active, self.ownership.isOwner, self.connectionAttempt == attempt else { return }
                                self.gameCaptureTask = nil
                                self.probeSession(host, desktopCapture: true)
                            }
                            return
                        }
                        if desktopCapture {
                            self.gameExitMonitor = SteamGameExitMonitor()
                            self.gameExitHostID = host.id
                            _ = self.gameExitMonitor?.update(gamesRunning: self.hosts.first(where: { $0.id == host.id })?.status.gamesRunning)
                        }
                        self.pairingTrace.append("Steam session endpoint ready on port \(endpoint.port)")
                        self.message = "Steam connected. Video is not available in this development build."
                        self.sessionRequest = nil
                        self.message = "Checking video support…"
                        let audioPlayer = StereoAudioPlayer { [weak self] trace in
                            Task { @MainActor in
                                guard let self, self.active, self.ownership.isOwner, self.connectionAttempt == attempt else { return }
                                self.pairingTrace.append(trace); self.pairingTrace = Array(self.pairingTrace.suffix(30)); self.checkpoint()
                            }
                        }
                        self.audioPlayer = audioPlayer
                        self.pairingTrace.append("Requested video codec: \(preferredCodec == .pyrowave ? "PyroWave" : "HEVC")")
                        let mailbox = self.frameMailbox
                        // This decoder reference is confined to the transport's
                        // serial receive queue. Only frame summaries reach UI.
                        let transportPyroDecoder = PyroWaveDecoderSlot()
                        self.codecProbe = SteamStreamingSession(endpoint: endpoint, preferredCodec: preferredCodec,
                            width: width, height: height, bitrateKbps: bitrate, hostManagedVideo: !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--pyro-bitrate=") }), wiredPyroBitrateKbps: (Bundle.main.object(forInfoDictionaryKey: "SteamTVIsParent") as? Bool == true) && !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--pyro-bitrate=") }) ? 250000 : nil, videoPreferences: profile) { [weak self] update in
                            switch update {
                            case .startedAudio(let config): audioPlayer.configure(config)
                            case .audioFrame(let packet): audioPlayer.enqueue(packet); return
                            case .startedVideo(let codec, let width, let height) where codec == SteamVideoCodec.pyrowave.rawValue:
                                transportPyroDecoder.value?.cancel()
                                transportPyroDecoder.value = SteamPyroWaveBridge(width: Int32(width), height: Int32(height))
                            case .pyrowavePacket(let packet):
                                transportPyroDecoder.value?.submitPacket(packet) { [weak self] frame, error in
                                    let count = frame.map { mailbox.push($0) } ?? 0
                                    guard error != nil || count == 1 || count > 0 && count % 60 == 0 else { return }
                                    Task { @MainActor in
                                        self?.receivePyroFrame(count: count, error: error, attempt: attempt)
                                    }
                                }
                                return
                            default: break
                            }
                            let initializedPyroDecoder = transportPyroDecoder.value
                            Task { @MainActor in
                                guard let self, self.active, self.ownership.isOwner, self.connectionAttempt == attempt else { return }
                                var writeCheckpoint = true
                                switch update {
                                case .diagnostic(let trace):
                                    self.pairingTrace.append(trace)
                                    if trace.hasPrefix("Steam UDP receive buffer:") { UserDefaults.standard.set(trace, forKey: "SteamTV.receiverInfo") }
                                    if trace.hasPrefix("Pyro fragment") {
                                        var fragments = UserDefaults.standard.stringArray(forKey: "SteamTV.fragmentTrace") ?? []
                                        fragments.append(trace)
                                        UserDefaults.standard.set(Array(fragments.suffix(40)), forKey: "SteamTV.fragmentTrace")
                                    }
                                case .offeredVideoCodecs(let codecs):
                                    self.pairingTrace.append("Initial codec offer: \(codecs)")
                                    self.message = preferredCodec == .pyrowave
                                        ? "Requesting PyroWave video…" : "Requesting HEVC video…"
                                case .startedVideo(let codec, let width, let height):
                                    UserDefaults.standard.set(Int(codec), forKey: "SteamTV.activeVideoCodec")
                                    UserDefaults.standard.set(Int(width), forKey: "SteamTV.activeVideoWidth")
                                    UserDefaults.standard.set(Int(height), forKey: "SteamTV.activeVideoHeight")
                                    self.pairingTrace.append("Verified video start: codec \(codec), \(width)×\(height)")
                                    if codec == SteamVideoCodec.pyrowave.rawValue {
                                        guard let decoder = initializedPyroDecoder, decoder.isAvailable() else {
                                            self.message = "PyroWave decoder unavailable"
                                            self.pairingTrace.append("Could not create PyroWave Metal decoder")
                                            break
                                        }
                                        self.pyroDecoder = decoder
                                        self.message = "Receiving PyroWave video…"
                                        self.pairingTrace.append("Apple TV PyroWave decoder ready: \(decoder.statusMessage())")
                                    } else {
                                        self.message = "Receiving HEVC video…"
                                    }
                                case .startedAudio(let configuration):
                                    self.pairingTrace.append("Receiving Opus stereo at \(configuration.sampleRate) Hz")
                                    if self.decodedFrames == 0 { self.message = "Waiting for Steam video…" }
                                case .audioFrame: break
                                case .videoFrame(let frame):
                                    guard frame.codec == .hevc else { self.message = "PyroWave frame received; decoder integration is next"; break }
                                    writeCheckpoint = false
                                    if self.decodedFrames == 0 { self.pairingTrace.append("Received complete HEVC frame: \(frame.data.count) bytes") }
                                    if self.decodedFrames == 0 { self.message = "Decoding HEVC video…" }
                                    if self.videoDecoder == nil {
                                        let mailbox = self.frameMailbox
                                        self.videoDecoder = HEVCVideoDecoder { [weak self] result in
                                        let count: Int
                                        switch result {
                                        case .success(let image): count = mailbox.push(image)
                                        case .failure: count = 0
                                        }
                                        guard count <= 1 || count % 60 == 0 else { return }
                                        Task { @MainActor in
                                            guard let self, self.active, self.ownership.isOwner, self.connectionAttempt == attempt else { return }
                                            self.connecting = false
                                            switch result {
                                            case .success(let image):
                                                if self.videoFrame == nil { self.videoFrame = image; self.beganStreaming() }
                                                self.decodedFrames = count
                                                if self.decodedFrames == 1 || self.decodedFrames % 60 == 0 {
                                                    self.pairingTrace.append("Apple TV hardware HEVC decoded: \(CVPixelBufferGetWidth(image))×\(CVPixelBufferGetHeight(image)); frames \(self.decodedFrames)")
                                                    self.pairingTrace = Array(self.pairingTrace.suffix(30))
                                                    self.checkpoint()
                                                }
                                                self.message = "Streaming HEVC video"
                                            case .failure(let error): self.message = "HEVC decoding failed: \(error)"
                                            }
                                        }
                                    } }
                                    do { try self.videoDecoder?.submit(frame) }
                                    catch { self.connectionFailed("Cannot decode HEVC: \(error)") }

                                case .pyrowavePacket: writeCheckpoint = false

                                case .videoPreferences(let changes):
                                    if !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--pyro-bitrate=") }) {
                                        let old = SteamSharedSettings.defaults.data(forKey: profileKey).flatMap { try? SteamVideoPreferences($0) }
                                        let latest = (try? old?.merging(changes)) ?? changes
                                        SteamSharedSettings.defaults.set(latest.data, forKey: profileKey)
                                        self.pairingTrace.append("Shared streaming preferences updated")
                                    }
                                case .title(let title):
                                    self.pairingTrace.append("Steam capture title: \(title)")
                                    if self.gameExitMonitor?.update(title: title) == true {
                                        if let gameID = self.requestedGameID { self.ownership.gameEnded(hostID: host.id, gameID: gameID) }
                                        self.exitToHome(reason: "Steam confirmed the game closed (capture title)"); return
                                    }
                                case .gameQuitRequested: break
                                case .ended(let reason):
                                    self.pairingTrace.append(reason)
                                    if self.gameCloseTask != nil {
                                        if self.hosts.first(where: { $0.id == host.id && $0.online })?.status.gamesRunning == false,
                                           let gameID = self.requestedGameID { self.ownership.gameEnded(hostID: host.id, gameID: gameID) }
                                        self.exitToHome(reason: "User requested game exit: \(reason)")
                                    } else {
                                        self.connectionFailed(reason)
                                    }
                                case .failed(let reason):
                                    UserDefaults.standard.set(reason, forKey: "SteamTV.lastStreamFailure")
                                    self.connectionFailed(reason)
                                }
                                self.pairingTrace = Array(self.pairingTrace.suffix(30))
                                if writeCheckpoint { self.checkpoint() }
                            }
                        }
                        if let session = self.codecProbe { self.controllerInput.start(session: session) }
                        self.codecProbe?.start()
                    case .failed(let reason):
                        self.connectionFailed(reason)
                    }
                    self.checkpoint()
                }
            }
            message = "Connecting to Steam…"
            sessionRequest?.start()
        } catch { connectionFailed(error.localizedDescription) }
    }
    func videoDisplayStatistics(_ count: Int, _ fps: Double) {
        pairingTrace.append(String(format: "Metal displayed %d frames, %.1f fps", count, fps))
        pairingTrace = Array(pairingTrace.suffix(30)); checkpoint()
    }
    private func receivePyroFrame(count: Int, error: String?, attempt: UUID) {
        guard active, ownership.isOwner, connectionAttempt == attempt else { return }
        if let error {
            message = "PyroWave decode failed: \(error)"
            if pairingTrace.last != error { pairingTrace.append(error) }
        } else if count > 0 {
            if !hasPyroFrame { beganStreaming() }
            hasPyroFrame = true; connecting = false; decodedFrames = count
            message = "Streaming PyroWave video"
            pairingTrace.append("PyroWave decoded frames: \(count)")
        }
        pairingTrace = Array(pairingTrace.suffix(30)); checkpoint()
    }
    func videoPresented(_ result: Result<Void, Error>) {
        switch result {
        case .success:
            message = hasPyroFrame ? "Streaming PyroWave video" : "Streaming HEVC video"
            pairingTrace.append("Metal fullscreen presentation completed on Apple TV GPU")
        case .failure(let error):
            connectionFailed("Video display failed: \(error)")
        }
        checkpoint()
    }
    func cancelConnection(userInitiated: Bool = true) {
        libraryPageTask?.cancel(); libraryPageTask = nil
        if userInitiated {
            wantsConnection = false
            wakeTask?.cancel(); wakeTask = nil
        }
        controllerInput.stop()
        streamActive = false; UIApplication.shared.isIdleTimerDisabled = false
        gameCloseTask?.cancel(); gameCloseTask = nil
        gameHandoverTask?.cancel(); gameHandoverTask = nil
        gameCaptureTask?.cancel(); gameCaptureTask = nil
        gameExitMonitor = nil; gameExitHostID = nil
        connectionAttempt = nil; connecting = false
        sessionRequest?.cancel(); sessionRequest = nil
        codecProbe?.cancel(); codecProbe = nil
        audioPlayer?.stop(); audioPlayer = nil
        videoDecoder?.reset(); videoDecoder = nil; pyroDecoder?.cancel(); pyroDecoder = nil; hasPyroFrame = false; videoFrame = nil; decodedFrames = 0; frameMailbox.clear()
        message = "Disconnected"
        checkpoint()
    }
    func cancelPairing() {
        let wasPairing = pairing != nil
        pairing?.cancel()
        finishPairing()
        if wasPairing { message = "Pairing cancelled"; checkpoint() }
    }
    private func finishPairing() {
        pairing = nil; pairingPIN = nil; pairingHostID = nil; pairingAttempt = nil
    }
    private func checkpoint() {
        DeviceDiagnostics.save(clientID: identity?.clientID, hosts: hosts, paired: pairedHosts, state: message,
                               pairingTrace: pairingTrace)
    }
}

import OSLog
import GameController
import SwiftUI
import UIKit

struct SunshineLaunchView: View {
    let game: GameInfo
    let host: SunshineHost
    let settings: StreamSettings
    let wakeHostIfNeeded: (@escaping (String) -> Void) async throws -> Void
    let onDismiss: () -> Void

    @Environment(GamesViewModel.self) private var viewModel
    @State private var phase: SunshineLaunchPhase = .starting
    @State private var streamBridge: CNMoonlightStreamBridge?
    @State private var inputSender: MoonlightInputSender?
    @State private var moonlightVideoView: CNMoonlightVideoView?
    @State private var showStreamOverlay = true
    @State private var videoContentVisible = false
    @State private var latestStatusMessage = "Preparing Steam..."
    @State private var launchTask: Task<Void, Never>?
    @State private var shouldMountVideoSurface = false
    @State private var didRequestSunshineExitOnClose = false
    @State private var didStartSunshineApp = false
    @State private var didRetryAfterMissingVideoKeyframe = false
    @State private var waitingForIDRFrameCount = 0
    @State private var activeLaunchResult: SunshineLaunchResult?
    @State private var videoStartupWatchdogTask: Task<Void, Never>?
    @State private var hostCloseConfirmation: CheckedContinuation<Bool, Never>?
    private let client = SunshineClient()
    private let logger = Logger(subsystem: "CloudNow", category: "Moonlight")

    var body: some View {
        let viewportSize = UIScreen.main.bounds.size

        SunshineControllerEventShield(
            onMenuPress: handleMenuPress,
            onSelectPress: handleSelectPress
        ) {
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()

                launchContent
                    .frame(width: viewportSize.width, height: viewportSize.height)
                    .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .onAppear {
            viewModel.setSunshineStreamPresentationActive(true)
            startLaunchTaskIfNeeded()
        }
        .onExitCommand {
            handleExitCommand()
        }
        .onPlayPauseCommand {
            logger.debug("Suppressed Sunshine stream play/pause command: phase=\(phase.debugName, privacy: .public) visible=\(videoContentVisible, privacy: .public) mounted=\(shouldMountVideoSurface, privacy: .public)")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            // App replacement and tvOS termination do not reliably produce a
            // SwiftUI disappearance first. Release Moonlight synchronously so
            // Sunshine cannot retain an orphaned PyroWave capture session.
            logger.info("Steam tvOS is terminating; stopping Moonlight transport")
            inputSender?.stop()
            inputSender = nil
            streamBridge?.stop()
            streamBridge = nil
            videoStartupWatchdogTask?.cancel()
            videoStartupWatchdogTask = nil
        }
        .task {
            while !Task.isCancelled {
                refreshVideoVisibility()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        .onDisappear {
            logger.debug("SunshineLaunchView disappeared: phase=\(phase.debugName, privacy: .public) visible=\(videoContentVisible, privacy: .public) mounted=\(shouldMountVideoSurface, privacy: .public) latest='\(latestStatusMessage, privacy: .public)'")
            launchTask?.cancel()
            launchTask = nil
            resolveHostCloseConfirmation(false)
            inputSender?.stop()
            streamBridge?.stop()
            exitSunshineGameOnCloseIfNeeded(reason: "view closed")
            viewModel.setSunshineStreamPresentationActive(false)
        }
        .preventsTVOSScreenSaverDuringStream()
    }

    private var launchContent: some View {
        ZStack {
            StreamStartupBackground(game: game)

            if shouldMountVideoSurface {
                MoonlightStreamControllerSurface { view in
                    if moonlightVideoView !== view {
                        moonlightVideoView = view
                        logMoonlightMessage("Video surface ready")
                    }
                    view.suppressesSystemPresses = true
                    view.menuPressHandler = { requestDismiss(source: "videoMenuPress") }
                    view.controllerExitPressHandler = { requestDismiss(source: "videoControllerExitPress") }
                }
                .id("moonlight-stream-controller")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
                .clipped()
                .ignoresSafeArea()
            }

            if shouldShowLaunchChrome {
                StreamStatusSurface(
                    game: game,
                    title: title,
                    message: message,
                    tone: statusTone,
                    actionTitle: streamStatusActionTitle,
                    action: streamStatusAction,
                    cancelAction: { requestDismiss(source: "statusControllerCancel") }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: shouldShowLaunchChrome)
    }

    private var shouldShowLaunchChrome: Bool {
        !videoContentVisible
    }

    private var title: String {
        switch phase {
        case .confirmingHostClose(let runningApp):
            return "Close \(runningApp.title)?"
        case .starting:
            return latestStatusMessage
        case .launched:
            return latestStatusMessage
        case .streaming:
            return videoContentVisible ? "SteamOS ready" : latestStatusMessage
        case .failed:
            return "Steam unavailable"
        }
    }

    private var message: String {
        switch phase {
        case .confirmingHostClose(let runningApp):
            return "Steam needs to close \(runningApp.title) before it can start."
        case .starting:
            return ""
        case .launched:
            return ""
        case .streaming:
            return ""
        case .failed(let error):
            return streamErrorMessage(from: error)
        }
    }

    private var statusTone: StreamStatusTone {
        if case .confirmingHostClose = phase {
            return .attention
        }
        if case .failed = phase {
            return .error
        }
        return .loading
    }

    private var streamStatusActionTitle: String? {
        if case .confirmingHostClose = phase {
            return "Close and Start Steam"
        }
        if case .failed = phase {
            return "Restart Steam"
        }
        if didStartSunshineApp {
            return nil
        }
        if case .streaming = phase {
            return nil
        }
        return "Cancel"
    }

    private var streamStatusAction: () -> Void {
        if case .confirmingHostClose = phase {
            return confirmHostClose
        }
        return { requestDismiss(source: "statusAction") }
    }

    private func streamErrorMessage(from raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("time out") {
            return "The session did not respond in time."
        }
        if lower.contains("wake-on-lan") || lower.contains("did not respond") || lower.contains("bc-250") {
            return "The BC-250 did not wake. Please try Wake from the power menu."
        }
        if lower.contains("unavailable") || lower.contains("connection") || lower.contains("connect") {
            return "The stream is not available right now."
        }
        if lower.contains("not paired") || lower.contains("pair") {
            return "This Sunshine host needs to be paired again."
        }
        if lower.contains("surface") || lower.contains("video") {
            return "Video could not be prepared. Please try again."
        }
        return "The stream could not start. Please try again."
    }

    private func launch() async {
        guard case .starting = phase else { return }
        guard let appId = game.sunshineAppId else {
            phase = .failed("CloudNow could not find the Sunshine app ID for this tile.")
            return
        }

        do {
            let streamSettings = settings
            updateStartupStatus("Checking the BC-250…")
            try await wakeHostIfNeeded { status in
                updateStartupStatus(status)
            }
            if settings.sunshineCodec == .pyroWaveExperimental {
                logMoonlightMessage("PyroWave profile: \(streamSettings.resolution) @ \(streamSettings.fps) fps, \(streamSettings.maxBitrateKbps / 1000) Mbps")
            }
            try await closeRunningHostAppIfNeeded(targetAppId: appId)
            let shouldResume = viewModel.activeSunshineStream?.game.id == game.id
                && viewModel.activeSunshineStream?.host == host
                && viewModel.activeSunshineStream?.isExpired == false
            var resumedExistingSession = false
            var result: SunshineLaunchResult
            if shouldResume {
                updateStartupStatus("Rejoining Steam...")
                do {
                    result = try await client.resumeApp(host: host, appId: appId, settings: streamSettings)
                    resumedExistingSession = true
                } catch {
                    guard isStaleResumeError(error) else {
                        throw error
                    }
                    viewModel.clearActiveSunshineStream(for: game)
                    updateStartupStatus("Starting a fresh session...")
                    result = try await client.launchApp(host: host, appId: appId, settings: streamSettings)
                }
            } else {
                updateStartupStatus("Starting Steam...")
                do {
                    result = try await client.launchApp(host: host, appId: appId, settings: streamSettings)
                } catch {
                    guard isAlreadyRunningError(error) else {
                        throw error
                    }
                    let closedDifferentApp = try await closeRunningHostAppIfNeeded(targetAppId: appId, assumeRunningWhenUnknown: true)
                    if closedDifferentApp {
                        updateStartupStatus("Starting Steam...")
                        result = try await client.launchApp(host: host, appId: appId, settings: streamSettings)
                    } else {
                        updateStartupStatus("Rejoining Steam...")
                        result = try await client.resumeApp(host: host, appId: appId, settings: streamSettings)
                        resumedExistingSession = true
                    }
                }
            }
            logMoonlightMessage(result.rawFields["optimistic"] == "timeout"
                ? "Sunshine launch reply timed out after host accepted launch; trying stream"
                : "Sunshine accepted the launch")
            result = try await ensureRequestedSunshineAppIsRunning(targetAppId: appId, launchResult: result)
            didStartSunshineApp = true
            updateStartupStatus(resumedExistingSession ? "Rejoining Steam..." : "Steam is starting...")
            await waitForSunshineStreamWarmup(isResume: resumedExistingSession)
            phase = .launched(result)
            updateStartupStatus("Preparing video...")
            shouldMountVideoSurface = true
            await waitForVideoSurface()
            logMoonlightMessage(moonlightVideoView == nil ? "Video surface still missing" : "Video surface ready")
            await startMoonlight(result: result)
        } catch {
            if error is CancellationError {
                return
            }
            phase = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    private func closeRunningHostAppIfNeeded(targetAppId: String, assumeRunningWhenUnknown: Bool = false) async throws -> Bool {
        let runningApp: RunningSunshineApp?
        let didFetchServerInfo: Bool
        do {
            let serverInfo = try await client.fetchServerInfo(host: host, fastFail: true)
            runningApp = runningSunshineApp(from: serverInfo)
            didFetchServerInfo = true
        } catch {
            logger.warning("Sunshine running-app preflight failed: \(error.localizedDescription, privacy: .public)")
            runningApp = nil
            didFetchServerInfo = false
        }

        if let activeStream = viewModel.activeSunshineStream,
           activeStream.host == host {
            guard didFetchServerInfo else {
                if activeStream.game.id == game.id {
                    return false
                }
                return try await confirmAndCloseRunningHostApp(
                    RunningSunshineApp(
                        appId: activeStream.game.sunshineAppId,
                        title: activeStream.game.title
                    )
                )
            }

            guard let runningApp else {
                if activeStream.game.id == game.id {
                    viewModel.clearActiveSunshineStream()
                    logger.info("Cleared stale Sunshine resume state because the host reports no running app")
                    return false
                }
                logger.info("Using active Sunshine stream state for close prompt because serverinfo reported no running app")
                return try await confirmAndCloseRunningHostApp(
                    RunningSunshineApp(
                        appId: activeStream.game.sunshineAppId,
                        title: activeStream.game.title
                    )
                )
            }

            if activeStream.game.id == game.id {
                if runningApp.appId == nil || shouldTreatAsRequestedRunningApp(runningApp, targetAppId: targetAppId) {
                    return false
                }
            }
            return try await confirmAndCloseRunningHostApp(runningApp)
        }

        guard let runningApp else {
            if assumeRunningWhenUnknown {
                logger.info("Using launch rejection as close prompt evidence because serverinfo did not report a running app")
                return try await confirmAndCloseRunningHostApp(
                    RunningSunshineApp(
                        appId: nil,
                        title: "the running game"
                    )
                )
            }
            return false
        }
        if shouldTreatAsRequestedRunningApp(runningApp, targetAppId: targetAppId) {
            return false
        }

        return try await confirmAndCloseRunningHostApp(runningApp)
    }

    private func shouldTreatAsRequestedRunningApp(_ runningApp: RunningSunshineApp, targetAppId: String) -> Bool {
        if runningApp.appId == targetAppId {
            return true
        }
        return normalizedRunningAppTitle(runningApp.title) == normalizedRunningAppTitle(game.title)
    }

    private func confirmAndCloseRunningHostApp(_ runningApp: RunningSunshineApp) async throws -> Bool {
        phase = .confirmingHostClose(runningApp)
        let shouldClose = await waitForHostCloseConfirmation()
        guard shouldClose else {
            throw CancellationError()
        }

        phase = .starting
        updateStartupStatus("Closing \(runningApp.title)...")
        try await client.cancelRunningApp(host: host)
        viewModel.clearActiveSunshineStream()
        try await waitForSunshineHostIdle()
        updateStartupStatus("Starting Steam...")
        return true
    }

    private func runningSunshineApp(from info: SunshineServerInfo) -> RunningSunshineApp? {
        let isBusy = info.state?.hasSuffix("_SERVER_BUSY") == true
        guard isBusy else { return nil }

        let currentGame = info.currentGame?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currentGame, !currentGame.isEmpty, currentGame != "0" else {
            return RunningSunshineApp(appId: nil, title: "the running game")
        }

        let normalizedCurrentGame = normalizedRunningAppTitle(currentGame)
        let runningGame = viewModel.sunshineGames.first {
            $0.sunshineAppId == currentGame
                || normalizedRunningAppTitle($0.title) == normalizedCurrentGame
        }
        return RunningSunshineApp(
            appId: runningGame?.sunshineAppId ?? currentGame,
            title: runningGame?.title ?? currentGame
        )
    }

    private func ensureRequestedSunshineAppIsRunning(
        targetAppId: String,
        launchResult: SunshineLaunchResult,
        maxAttempts: Int = 8
    ) async throws -> SunshineLaunchResult {
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(500))
            }
            guard let info = try? await client.fetchServerInfo(host: host, fastFail: true),
                  let runningApp = runningSunshineApp(from: info) else {
                continue
            }
            if shouldTreatAsRequestedRunningApp(runningApp, targetAppId: targetAppId) {
                return launchResult
            }

            logger.warning("Sunshine reported a different app after launch target=\(targetAppId, privacy: .public) running=\(runningApp.appId ?? "unknown", privacy: .public)")
            let closedDifferentApp = try await closeRunningHostAppIfNeeded(targetAppId: targetAppId, assumeRunningWhenUnknown: true)
            guard closedDifferentApp else {
                return launchResult
            }
            updateStartupStatus("Starting Steam...")
            return try await client.launchApp(host: host, appId: targetAppId, settings: settings)
        }
        return launchResult
    }
    private func normalizedRunningAppTitle(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func waitForHostCloseConfirmation() async -> Bool {
        await withCheckedContinuation { continuation in
            hostCloseConfirmation = continuation
        }
    }

    private func resolveHostCloseConfirmation(_ shouldClose: Bool) {
        guard let continuation = hostCloseConfirmation else { return }
        hostCloseConfirmation = nil
        continuation.resume(returning: shouldClose)
    }

    private func waitForSunshineHostIdle(maxAttempts: Int = 60) async throws {
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(500))
            }
            guard let info = try? await client.fetchServerInfo(host: host, fastFail: true) else {
                continue
            }
            if runningSunshineApp(from: info) == nil {
                return
            }
        }
        throw SunshineClientError.launchRejected("Sunshine is still closing the running game. Please try again.")
    }

    private func isStaleResumeError(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("no running app")
    }

    private func isAlreadyRunningError(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("already running")
    }

    private func waitForVideoSurface(maxAttempts: Int = 100, announceWait: Bool = true) async {
        await Task.yield()
        var attempts = 0
        while moonlightVideoView == nil && attempts < maxAttempts {
            attempts += 1
            if announceWait && attempts == 1 {
                updateStartupStatus("Preparing video...")
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func waitForSunshineStreamWarmup(isResume: Bool) async {
        updateStartupStatus(isResume ? "Rejoining Steam..." : "Starting Steam...")
        try? await Task.sleep(for: isResume ? .milliseconds(250) : .seconds(3))
        updateStartupStatus("Connecting stream...")
    }

    private func startLaunchTaskIfNeeded() {
        guard launchTask == nil else { return }
        launchTask = Task {
            await prepareLaunch()
            await launch()
        }
    }

    private func prepareLaunch() async {
        guard case .starting = phase else { return }
        updateStartupStatus("Preparing Steam...")
        await viewModel.prepareForSunshineLaunch(game, host: host)
    }

    private func startMoonlight(result: SunshineLaunchResult) async {
        updateStartupStatus("Connecting stream...")
        activeLaunchResult = result
        waitingForIDRFrameCount = 0
        guard let videoView = moonlightVideoView else {
            logMoonlightMessage("Video surface was not ready")
            phase = .failed("CloudNow could not prepare the video surface. Please try again.")
            return
        }

        let serverInfo: SunshineServerInfo?
        do {
            serverInfo = try await client.fetchServerInfo(host: host, fastFail: true)
        } catch {
            serverInfo = nil
            logger.warning("Sunshine server info refresh failed before stream start: \(error.localizedDescription, privacy: .public)")
        }

        let bridge = CNMoonlightStreamBridge()
        streamBridge = bridge
        let streamSettings = settings
        let resolution = streamSettings.resolution.split(separator: "x").compactMap { Int($0) }
        let width = resolution.first ?? 1920
        let height = resolution.dropFirst().first ?? 1080
        bridge.start(
            withHostAddress: host.address,
            appVersion: serverInfo?.appVersion ?? "0.0.0",
            rtspSessionUrl: result.sessionUrl,
            serverCodecModeSupport: serverInfo?.serverCodecModeSupport ?? 0,
            width: width,
            height: height,
            fps: streamSettings.fps,
            bitrateKbps: streamSettings.maxBitrateKbps,
            riKeyHex: result.riKeyHex,
            riKeyId: result.riKeyId,
            useFramePacing: settings.sunshineSmoothFramePacing,
            adaptiveBitrateEnabled: settings.sunshineIsBitrateAuto,
            preferredVideoCodec: settings.sunshineCodec.moonlightPreferredVideoCodec,
            videoView: videoView
        ) { state, message, code in
            handleMoonlightProgress(state: state, message: message, code: code, bridge: bridge)
        }
    }

    private func startControllerInput(bridge: CNMoonlightStreamBridge) {
        guard inputSender == nil else { return }
        let sender = MoonlightInputSender(bridge: bridge)
        sender.deadzone = Float(settings.controllerDeadzone)
        sender.onStatus = {
            logMoonlightMessage($0)
        }
        sender.exitComboHandler = {
            logger.info("Controller Start+Select hold requested Sunshine stream exit: phase=\(phase.debugName, privacy: .public) visible=\(videoContentVisible, privacy: .public) mounted=\(shouldMountVideoSurface, privacy: .public)")
            requestDismiss(source: "controllerExitCombo", allowDuringStreaming: true)
        }
        moonlightVideoView?.remoteDirectionPressHandler = { direction, pressed in
            sender.setRemoteDirection(direction, pressed: pressed)
        }
        moonlightVideoView?.remoteSelectPressHandler = { pressed in
            sender.setRemoteSelectPressed(pressed)
        }
        moonlightVideoView?.remoteBackPressHandler = { pressed in
            sender.setRemoteBackPressed(pressed)
        }
        inputSender = sender
        sender.start()
    }

    private func handleMoonlightProgress(
        state: CNMoonlightStreamState,
        message: String,
        code: Int,
        bridge: CNMoonlightStreamBridge
    ) {
        logMoonlightMessage(code == 0 ? message : "\(message) (\(code))")

        if state == .started {
            updateStartupStatus("Connecting to SteamOS…")
            phase = .streaming
            showStreamOverlay = true
            waitingForIDRFrameCount = 0
            viewModel.markSunshineStreamActive(game: game, host: host)
            startControllerInput(bridge: bridge)
            startVideoStartupWatchdog()
            return
        }

        if state == .stageFailed || state == .terminated {
            inputSender?.stop()
            inputSender = nil
            waitingForIDRFrameCount = 0
            videoStartupWatchdogTask?.cancel()
            videoStartupWatchdogTask = nil
            showStreamOverlay = true
            if state == .terminated {
                exitSunshineGameOnCloseIfNeeded(reason: "Moonlight stream ended")
            }
            phase = .failed("\(message) (\(code))")
            return
        }

        if let friendlyStatus = friendlyMoonlightStatus(from: message) {
            updateStartupStatus(friendlyStatus)
        }
        handleMissingVideoKeyframeIfNeeded(message: message)
    }

    private func handleMissingVideoKeyframeIfNeeded(message: String) {
        guard message.localizedCaseInsensitiveContains("Waiting for IDR frame") else { return }
        waitingForIDRFrameCount += 1
        guard waitingForIDRFrameCount == 180,
              !didRetryAfterMissingVideoKeyframe,
              let result = activeLaunchResult else {
            return
        }

        didRetryAfterMissingVideoKeyframe = true
        logMoonlightMessage("Video keyframe did not arrive; reconnecting Moonlight stream")
        updateStartupStatus("Requesting fresh video...")
        Task { @MainActor in
            inputSender?.stop()
            inputSender = nil
            streamBridge?.stop()
            streamBridge = nil
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            waitingForIDRFrameCount = 0
            await startMoonlight(result: result)
        }
    }

    private func friendlyMoonlightStatus(from raw: String) -> String? {
        let lower = raw.lowercased()
        if lower.contains("video setup") || lower.contains("renderer") || lower.contains("decoder") {
            return "Preparing video..."
        }
        if lower.contains("video stream started") || lower.contains("moonlight stream connected") {
            return "Video is starting..."
        }
        if lower.contains("audio") || lower.contains("cleanup") || lower.contains("stopped") {
            return nil
        }
        if lower.contains("failed") || lower.contains("ended") {
            return nil
        }
        return "Connecting stream..."
    }

    private func updateStartupStatus(_ message: String) {
        latestStatusMessage = message
        logger.info("Sunshine startup status: \(message, privacy: .public)")
    }

    private func startVideoStartupWatchdog() {
        videoStartupWatchdogTask?.cancel()
        videoStartupWatchdogTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, !videoContentVisible, case .streaming = phase else { return }

            if !didRetryAfterMissingVideoKeyframe, let result = activeLaunchResult {
                didRetryAfterMissingVideoKeyframe = true
                updateStartupStatus("Retrying SteamOS video…")
                inputSender?.stop()
                inputSender = nil
                streamBridge?.stop()
                streamBridge = nil
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { return }
                await startMoonlight(result: result)
            } else {
                inputSender?.stop()
                inputSender = nil
                streamBridge?.stop()
                streamBridge = nil
                phase = .failed("SteamOS video did not appear in time. Please try again.")
            }
        }
    }

    private func logMoonlightMessage(_ message: String) {
        logger.debug("Sunshine startup detail: \(message, privacy: .public)")
    }

    private func refreshVideoVisibility() {
        let visible = moonlightVideoView?.hasVisibleVideoContent ?? false
        guard visible != videoContentVisible else { return }
        videoContentVisible = visible
        if visible {
            logMoonlightMessage("Video is visible")
            videoStartupWatchdogTask?.cancel()
            videoStartupWatchdogTask = nil
            showStreamOverlay = false
        } else if case .streaming = phase {
            showStreamOverlay = true
        }
    }

    private func exitSunshineGameOnCloseIfNeeded(reason: String) {
        guard didStartSunshineApp else {
            logger.info("Skipping Sunshine close-on-exit: no launch accepted reason=\(reason, privacy: .public)")
            return
        }
        guard settings.sunshineExitGameOnStreamClose else {
            logger.info("Skipping Sunshine close-on-exit: disabled reason=\(reason, privacy: .public)")
            return
        }
        guard !didRequestSunshineExitOnClose else {
            logger.info("Skipping Sunshine close-on-exit: already requested reason=\(reason, privacy: .public)")
            return
        }
        didRequestSunshineExitOnClose = true
        logMoonlightMessage("Closing Sunshine game: \(reason)")
        Task {
            do {
                try await client.cancelRunningApp(host: host)
            } catch {
                logger.warning("Sunshine close-on-exit failed: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run {
                viewModel.clearActiveSunshineStream(for: game)
            }
        }
    }

    private func requestDismiss(source: String, allowDuringStreaming: Bool = false) {
        if case .streaming = phase, !allowDuringStreaming {
            logger.debug("Suppressed Sunshine stream dismiss source=\(source, privacy: .public) phase=\(phase.debugName, privacy: .public) visible=\(videoContentVisible, privacy: .public) mounted=\(shouldMountVideoSurface, privacy: .public)")
            showStreamOverlay = true
            return
        }
        cancelLaunch(source: source)
    }

    private func cancelLaunch(source: String) {
        logger.debug("Sunshine launch exit action invoked source=\(source, privacy: .public) phase=\(phase.debugName, privacy: .public) visible=\(videoContentVisible, privacy: .public) mounted=\(shouldMountVideoSurface, privacy: .public)")
        resolveHostCloseConfirmation(false)
        onDismiss()
    }

    private func handleExitCommand() {
        requestDismiss(source: "exitCommand")
    }

    private func handleMenuPress() {
        handleExitCommand()
    }

    private func handleSelectPress() -> Bool {
        guard case .confirmingHostClose = phase else { return false }
        confirmHostClose()
        return true
    }

    private func confirmHostClose() {
        resolveHostCloseConfirmation(true)
    }
}

private enum SunshineLaunchPhase: Equatable {
    case confirmingHostClose(RunningSunshineApp)
    case starting
    case launched(SunshineLaunchResult)
    case streaming
    case failed(String)

    var debugName: String {
        switch self {
        case .confirmingHostClose:
            return "confirmingHostClose"
        case .starting:
            return "starting"
        case .launched:
            return "launched"
        case .streaming:
            return "streaming"
        case .failed:
            return "failed"
        }
    }
}

private struct RunningSunshineApp: Equatable {
    let appId: String?
    let title: String
}

private struct SunshineControllerEventShield<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let onMenuPress: () -> Void
    let onSelectPress: () -> Bool

    init(
        onMenuPress: @escaping () -> Void,
        onSelectPress: @escaping () -> Bool = { false },
        @ViewBuilder content: () -> Content
    ) {
        self.onMenuPress = onMenuPress
        self.onSelectPress = onSelectPress
        self.content = content()
    }

    func makeUIViewController(context: Context) -> SunshineControllerEventShieldController {
        let controller = SunshineControllerEventShieldController()
        controller.onMenuPress = onMenuPress
        controller.onSelectPress = onSelectPress
        controller.hostingController.rootView = AnyView(content)
        return controller
    }

    func updateUIViewController(_ uiViewController: SunshineControllerEventShieldController, context: Context) {
        uiViewController.controllerUserInteractionEnabled = false
        uiViewController.onMenuPress = onMenuPress
        uiViewController.onSelectPress = onSelectPress
        uiViewController.hostingController.rootView = AnyView(content)
    }
}

private final class SunshineControllerEventShieldController: GCEventViewController {
    let hostingController = UIHostingController(rootView: AnyView(EmptyView()))
    var onMenuPress: (() -> Void)?
    var onSelectPress: (() -> Bool)?

    override func viewDidLoad() {
        super.viewDidLoad()
        controllerUserInteractionEnabled = false
        view.backgroundColor = .black

        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        hostingController.view.backgroundColor = .clear
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingController.didMove(toParent: self)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        hostingController.preferredFocusEnvironments
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if containsMenuPress(presses) {
            onMenuPress?()
            return
        }
        if containsSelectPress(presses), onSelectPress?() == true {
            return
        }
        guard !containsStreamExitPress(presses) else { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !containsStreamExitPress(presses) else { return }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard !containsStreamExitPress(presses) else { return }
        super.pressesCancelled(presses, with: event)
    }

    private func containsStreamExitPress(_ presses: Set<UIPress>) -> Bool {
        presses.contains { press in
            press.type == .menu || press.type == .playPause
        }
    }

    private func containsMenuPress(_ presses: Set<UIPress>) -> Bool {
        presses.contains { press in
            press.type == .menu
        }
    }

    private func containsSelectPress(_ presses: Set<UIPress>) -> Bool {
        presses.contains { press in
            press.type == .select
        }
    }
}

private struct MoonlightStreamControllerSurface: UIViewRepresentable {
    let onReady: (CNMoonlightVideoView) -> Void

    func makeUIView(context: Context) -> CNMoonlightVideoView {
        let view = CNMoonlightVideoView(frame: .zero)
        view.backgroundColor = .clear
        view.clipsToBounds = true
        DispatchQueue.main.async {
            view.becomeFirstResponder()
            onReady(view)
        }
        return view
    }

    func updateUIView(_ uiView: CNMoonlightVideoView, context: Context) {
        uiView.setNeedsLayout()
    }
}

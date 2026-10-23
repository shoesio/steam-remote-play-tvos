import Charts
import OSLog
import SwiftUI

private enum LoadingPhase: Equatable {
    case authenticating
    case finding
    case resuming
    case checkingActive
    case creating
    case inQueue(Int?)
    case preparing
    case startingWebRTC
    case rebuilding(Int)
    case timedOut
}

struct StreamView: View {
    let game: GameInfo
    var settings: StreamSettings = StreamSettings()
    var existingSession: ActiveSessionInfo? = nil
    /// When set, skips CloudMatch entirely and reconnects WebRTC directly using the stored session.
    var directSession: SessionInfo? = nil
    let onDismiss: () -> Void
    /// Called when the user leaves without ending the session so the caller can offer a resume.
    var onLeave: ((GameInfo, SessionInfo) -> Void)? = nil

    @Environment(AuthManager.self) var authManager
    @Environment(GamesViewModel.self) var viewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var streamController = GFNStreamController()
    @State private var showOverlay = false
    @State private var showExitConfirmation = false
    @State private var loadingPhase: LoadingPhase = .finding
    @State private var createdSession: SessionInfo?
    @State private var sessionToken: String?
    @State private var isStartingSession = false
    @State private var didEndSession = false
    @State private var didRecordLeave = false
    // Per-ad state tracking to avoid duplicate reports
    @State private var adReportedAction: [String: AdAction] = [:]

    private let cloudMatchClient = CloudMatchClient()
    private let streamLogger = Logger(subsystem: "CloudNow", category: "Stream")

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch streamController.state {
            case .idle, .connecting:
                connectingView
            case .streaming:
                streamingView
            case .disconnected(let reason):
                disconnectedView(reason)
            case .failed(let message):
                if isStartingSession {
                    connectingView
                } else {
                    failedView(message)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            streamController.exitComboHandler = {
                streamLogger.info("Controller Start+Select hold requested GeForce stream exit")
                disconnect()
            }
        }
        .task { await startSession() }
        .onDisappear {
            recordLeaveIfNeeded()
            streamController.disconnect()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                recordLeaveIfNeeded()
            }
        }
        // During streaming, VideoSurfaceView is first responder and intercepts Menu via UIKit,
        // signaling us through menuPressCount. Loading/error screens still let Menu quietly
        // return to the game list without advertising a second exit path.
        .onChange(of: streamController.menuPressCount) { _, _ in
            toggleOverlay()
        }
        .onExitCommand {
            if streamController.state != .streaming {
                disconnect()
            }
        }
        .preventsTVOSScreenSaverDuringStream()
    }

    // MARK: Connecting

    private var connectingView: some View {
        ZStack {
            StreamStatusSurface(
                game: game,
                title: connectionMessage,
                message: startupMessage,
                tone: startupTone,
                actionTitle: "Cancel Stream",
                action: disconnect
            )
            .animation(.easeInOut, value: connectionMessage)

            // Show ad player when GFN requires watching an ad to stay in queue.
            if let adState = createdSession?.adState,
               adState.isAdsRequired,
               let ad = adState.ads.first {
                QueueAdPlayerView(
                    ad: ad,
                    onStart:  { id in reportAd(id: id, action: .start)  },
                    onPause:  { id in reportAd(id: id, action: .pause)  },
                    onResume: { id in reportAd(id: id, action: .resume) },
                    onFinish: { id, ms in reportAd(id: id, action: .finish, watchedMs: ms) },
                    message:  adState.message
                )
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 86)
            }
        }
    }

    private var loadingLabel: String {
        switch loadingPhase {
        case .authenticating:
            return "Checking your sign-in..."
        case .finding:
            return "Finding your stream..."
        case .resuming:
            return "Rejoining Steam..."
        case .checkingActive:
            return "Checking your session..."
        case .creating:
            return "Starting Steam..."
        case .inQueue(let pos):
            if pos != nil { return "Waiting in queue" }
            return "Waiting in queue..."
        case .preparing:
            return "Preparing Steam..."
        case .startingWebRTC:
            return "Connecting stream..."
        case .rebuilding:
            return "Still working on it..."
        case .timedOut:
            return "Steam unavailable"
        }
    }

    private var connectionMessage: String {
        if case .connecting = streamController.state,
           !streamController.connectionStatus.isEmpty {
            return humanReadableConnectionStatus(streamController.connectionStatus)
        }
        return loadingLabel
    }

    private var startupMessage: String? {
        if case .rebuilding(let attempt) = loadingPhase {
            return "Retrying connection \(attempt) of 2."
        }
        if case .timedOut = loadingPhase {
            return "The session did not respond in time."
        }
        if let queue = createdSession?.queuePosition, queue >= 0 {
            return "Position \(queue)"
        }
        return nil
    }

    private var startupTone: StreamStatusTone {
        if case .timedOut = loadingPhase {
            return .error
        }
        if case .inQueue = loadingPhase {
            return .waiting
        }
        return .loading
    }

    private func humanReadableConnectionStatus(_ status: String) -> String {
        let lower = status.lowercased()
        if lower.contains("media connected") { return "Video is starting..." }
        if lower.contains("failed") || lower.contains("could not") {
            return "That connection did not respond. Trying another route..."
        }
        if lower.contains("disconnected") { return "The stream paused. Reconnecting..." }
        if lower.contains("waiting for stream offer") { return "Waking the stream..." }
        if lower.contains("received stream offer") || lower.contains("preparing video") {
            return "Preparing video..."
        }
        if lower.contains("probing") || lower.contains("media route") {
            return "Finding the best video route..."
        }
        if lower.contains("answer") || lower.contains("negotiating") || lower.contains("configuring") {
            return "Setting up video and input..."
        }
        if lower.contains("opening") { return "Opening the stream..." }
        return loadingLabel
    }

    // MARK: Streaming

    private var streamingView: some View {
        ZStack {
            VideoSurfaceViewRepresentable(streamController: streamController, showOverlay: showOverlay)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .ignoresSafeArea()

            if showOverlay {
                pauseMenu
                    .transition(.opacity)
            }

            if let warning = streamController.timeWarning, !showOverlay {
                timeWarningBanner(warning)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: streamController.timeWarning)
        .animation(.easeInOut(duration: 0.2), value: showOverlay)
        .onChange(of: showOverlay) { _, showing in
            // Pause game input while overlay is open in gamepad mode so D-pad
            // navigates overlay buttons instead of moving the in-game character.
            streamController.setInputPaused(showing && streamController.remoteMode != .mouse)
        }
        .alert("End Session?", isPresented: $showExitConfirmation) {
            Button("End Session", role: .destructive) { disconnect() }
            Button("Keep Playing", role: .cancel) { }
        } message: {
            Text("This will end your GeForce NOW session. To return later, use Leave Game instead.")
        }
    }

    // MARK: Pause Menu

    private var pauseMenu: some View {
        HStack(alignment: .top, spacing: 40) {
            // Actions
            VStack(spacing: 16) {
                Button {
                    toggleOverlay()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(AppActionButtonStyle(tone: .primary))

                Button {
                    streamController.toggleRemoteMode()
                } label: {
                    Label(remoteModeLabel, systemImage: remoteModeIcon)
                }
                .buttonStyle(AppActionButtonStyle(tone: .secondary))

                Button {
                    leave()
                } label: {
                    Label("Leave Game", systemImage: "house")
                }
                .buttonStyle(AppActionButtonStyle(tone: .secondary))

                Button(role: .destructive) {
                    showExitConfirmation = true
                } label: {
                    Label("End Session", systemImage: "xmark.circle")
                }
                .buttonStyle(AppActionButtonStyle(tone: .destructive))
            }

            // Live stats
            VStack(alignment: .leading, spacing: 10) {
                metricRow(
                    icon: "network",
                    label: "RTT",
                    value: "\(Int(streamController.stats.rttMs)) ms",
                    history: streamController.pingHistory,
                    color: pingColor(streamController.stats.rttMs)
                )
                metricRow(
                    icon: "speedometer",
                    label: "FPS",
                    value: "\(Int(streamController.stats.fps))",
                    history: streamController.fpsHistory,
                    color: fpsColor(streamController.stats.fps)
                )
                metricRow(
                    icon: "wifi",
                    label: "Bitrate",
                    value: "\(streamController.stats.bitrateKbps / 1000) Mbps",
                    history: streamController.bitrateHistory,
                    color: .cyan
                )
                Divider().overlay(.white.opacity(0.4))
                Label("\(streamController.stats.resolutionWidth)×\(streamController.stats.resolutionHeight) @ \(Int(streamController.stats.fps))fps", systemImage: "tv")
                Label("Loss \(String(format: "%.1f", streamController.stats.packetLossPercent))%", systemImage: "arrow.triangle.2.circlepath")
                if !streamController.stats.gpuType.isEmpty {
                    Label(streamController.stats.gpuType, systemImage: "cpu")
                }
                if let sub = viewModel.subscription, !sub.isUnlimited, let rem = sub.remainingMinutes {
                    Divider().overlay(.white.opacity(0.4))
                    Label {
                        Text(rem >= 60 ? "\(rem / 60)h \(rem % 60)m remaining" : "\(rem)m remaining")
                    } icon: {
                        Image(systemName: "clock")
                            .foregroundStyle(rem < 30 ? .orange : .white.opacity(0.7))
                    }
                    .foregroundStyle(rem < 30 ? .orange : .white)
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.white)
        }
        .padding(32)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(60)
    }

    private var remoteModeLabel: String {
        switch streamController.remoteMode {
        case .mouse:     return "Remote: Mouse"
        case .gamepad:   return "Remote: Gamepad"
        case .dualsense: return "Remote: DualSense"
        }
    }

    private var remoteModeIcon: String {
        switch streamController.remoteMode {
        case .mouse:     return "cursorarrow"
        case .gamepad:   return "gamecontroller"
        case .dualsense: return "hand.point.up.left"
        }
    }

    private func metricRow(icon: String, label: String, value: String, history: [Double], color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 16)
            Text("\(label): \(value)")
                .foregroundStyle(color)
                .frame(width: 130, alignment: .leading)
            if history.count > 1 {
                Chart {
                    ForEach(Array(history.enumerated()), id: \.offset) { (idx, val) in
                        LineMark(x: .value("t", idx), y: .value("v", val))
                            .foregroundStyle(color)
                    }
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(width: 80, height: 24)
            }
        }
    }

    private func pingColor(_ ms: Double) -> Color {
        if ms < 30  { return .green }
        if ms < 80  { return .yellow }
        if ms < 150 { return .orange }
        return .red
    }

    private func fpsColor(_ fps: Double) -> Color {
        if fps >= 55 { return .green }
        if fps >= 30 { return .yellow }
        return .red
    }

    // MARK: Time Warning Banner

    private func timeWarningBanner(_ warning: StreamTimeWarning) -> some View {
        let (color, icon, message): (Color, String, String) = {
            let timeText = warning.secondsLeft.map { " (\($0)s left)" } ?? ""
            switch warning.code {
            case 3: return (.red,    "clock.badge.xmark",     "Session ending soon\(timeText)")
            case 2: return (.orange, "clock.badge.exclamationmark", "~5 minutes remaining\(timeText)")
            default: return (.yellow, "clock",                "Session limit approaching\(timeText)")
            }
        }()
        return Label(message, systemImage: icon)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(color.opacity(0.85), in: Capsule())
            .padding(.top, 40)
    }

    // MARK: Disconnected / Failed

    private func disconnectedView(_ reason: String) -> some View {
        StreamStatusSurface(
            game: game,
            title: "Steam disconnected",
            message: streamErrorMessage(from: reason),
            tone: .warning,
            actionTitle: "Restart Steam",
            action: disconnect
        )
    }

    private func failedView(_ message: String) -> some View {
        if isSessionLimitError(message), let resumable = matchingResumableSession {
            return AnyView(StreamStatusSurface(
                game: game,
                title: "Rejoining Steam...",
                message: nil,
                tone: .loading,
                actionTitle: "Cancel",
                action: disconnect
            )
            .task(id: resumable.session.sessionId) {
                createdSession = resumable.session
                await startSession()
            })
        }

        return AnyView(StreamStatusSurface(
            game: game,
            title: streamErrorTitle(from: message),
            message: entitlementMessage(from: message),
            tone: .error,
            actionTitle: "Restart Steam",
            action: disconnect
        ))
    }

    private func isSessionLimitError(_ raw: String) -> Bool {
        let uppercased = raw.uppercased()
        return uppercased.contains("SESSION_LIMIT_EXCEEDED")
            || uppercased.contains("REQUEST_LIMIT_EXCEEDED")
            || uppercased.contains("LIMIT_EXCEEDED")
    }

    private var matchingResumableSession: ResumableSession? {
        guard let resumable = viewModel.resumableSession, !resumable.isExpired else { return nil }
        return resumable.game.id == game.id ? resumable : nil
    }

    private func entitlementMessage(from raw: String) -> String {
        if raw.uppercased().contains("ENTITLEMENT") || raw.contains("3237093650") {
            return "\(game.title) is not in your GeForce NOW library."
        }
        if isSessionLimitError(raw) {
            return "Your previous GeForce NOW session is still active."
        }
        return streamErrorMessage(from: raw)
    }

    private func streamErrorTitle(from raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("time out") {
            return "Steam unavailable"
        }
        if lower.contains("not in your") || lower.contains("entitlement") || raw.contains("3237093650") {
            return "Steam unavailable"
        }
        return "Steam unavailable"
    }

    private func streamErrorMessage(from raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("time out") {
            return "The session did not respond in time."
        }
        if lower.contains("unavailable") || lower.contains("could not finish connecting") {
            return "The stream is not available right now."
        }
        if lower.contains("disconnected") || lower.contains("closed") {
            return "The connection closed."
        }
        if raw.contains(#""session""#) || raw.contains(#""requestStatus""#) {
            return "The session could not be completed."
        }
        return raw
    }

    // MARK: Actions

    private func startSession() async {
        guard !isStartingSession else { return }
        isStartingSession = true
        defer { isStartingSession = false }

        // Reset stream controller (handles retry from failed/disconnected state)
        streamController.disconnect()
        loadingPhase = .authenticating

        // Reconnect path — RESUME PUT tells the server to rebuild its media endpoint.
        // If NVIDIA only gives us an empty status=0 placeholder, discard it and fall
        // through to normal fresh-session creation.
        if let direct = directSession, !direct.isEmptyPlaceholder, direct.hasValidResumeEndpoint {
            loadingPhase = .resuming
            do {
                let token = try await authManager.resolveToken()
                sessionToken = token
                let provider = authManager.session?.provider
                let streamingBaseUrl = provider?.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
                let base = streamingBaseUrl.hasSuffix("/") ? String(streamingBaseUrl.dropLast()) : streamingBaseUrl

                let connected = try await resumeAndConnect(
                    seed: direct,
                    token: token,
                    base: base,
                    appId: game.variants.first?.appId ?? game.variants.first?.id,
                    maxIceRetries: 2
                )
                if connected {
                    return
                }
            } catch {
                streamLogger.error("Direct session resume failed: \(error.localizedDescription, privacy: .public)")
                streamController.disconnect()
            }
        } else if directSession != nil {
            streamLogger.error("Discarding invalid persisted resume session before starting stream")
            viewModel.resumableSession = nil
        }

        loadingPhase = .authenticating
        do {
            let token = try await authManager.resolveToken()
            sessionToken = token
            let provider = authManager.session?.provider
            let streamingBaseUrl = provider?.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingBaseUrl.hasSuffix("/") ? String(streamingBaseUrl.dropLast()) : streamingBaseUrl
            guard let appId = game.variants.first?.appId ?? game.variants.first?.id else { return }
            let sessionBase = settings.preferredZoneUrl ?? base
            let createRequest = SessionCreateRequest(
                appId: appId,
                internalTitle: game.title,
                token: token,
                zone: "",
                streamingBaseUrl: sessionBase,
                settings: settings,
                accountLinked: true
            )

            var sessionInfo: SessionInfo?
            var createdNewSession = false
            var resumedExistingSession = false

            if let localSession = createdSession, localSession.hasValidResumeEndpoint {
                // Retry path: prefer reclaiming the last server session we created.
                loadingPhase = .resuming
                streamLogger.info("Attempting local session resume sessionId=\(localSession.sessionId, privacy: .public) serverIp=\(localSession.serverIp, privacy: .public)")
                do {
                    let claimedSession = try await cloudMatchClient.claimSession(
                        sessionId: localSession.sessionId,
                        serverIp: SessionInfo.isValidHost(localSession.serverIp) ? localSession.serverIp : nil,
                        token: token,
                        base: base,
                        appId: appId,
                        settings: settings
                    )
                    if isEmptySessionPlaceholder(claimedSession) {
                        streamLogger.error("Local session resume returned an empty placeholder; discarding sessionId=\(claimedSession.sessionId, privacy: .public)")
                        try? await cloudMatchClient.stopSession(
                            sessionId: claimedSession.sessionId,
                            token: token,
                            base: claimedSession.streamingBaseUrl
                        )
                        createdSession = nil
                    } else {
                        sessionInfo = claimedSession
                        resumedExistingSession = true
                    }
                } catch {
                    streamLogger.error("Local session resume failed: \(error.localizedDescription, privacy: .public)")
                    createdSession = nil
                }
            } else if createdSession != nil {
                streamLogger.error("Ignoring cached session with invalid resume endpoint")
                createdSession = nil
            }

            loadingPhase = .checkingActive
            let activeSession = try await sessionToClaimIfAvailable(token: token, base: base)
            if sessionInfo == nil, let existing = activeSession {
                // Resume path: attach to the existing session without creating a new one.
                loadingPhase = .resuming
                streamLogger.info("Attempting active session resume sessionId=\(existing.sessionId, privacy: .public) status=\(existing.status) appId=\(existing.appId ?? "nil", privacy: .public) serverIp=\(existing.serverIp ?? "nil", privacy: .public)")
                sessionInfo = try await cloudMatchClient.claimSession(
                    sessionId: existing.sessionId,
                    serverIp: existing.serverIp,
                    token: token,
                    base: base,
                    appId: existing.appId ?? appId,
                    settings: settings
                )
                resumedExistingSession = true
            }

            if sessionInfo == nil {
                // New session path
                loadingPhase = .creating

                do {
                    sessionInfo = try await cloudMatchClient.createSession(createRequest)
                    createdNewSession = true
                } catch CloudMatchError.sessionCreateFailed(let msg) where isSessionLimitError(msg) {
                    streamLogger.error("Create failed with a session limit response; checking for resumable sessions")
                    var sessionLimitResumeCandidate = activeSession
                    if sessionLimitResumeCandidate == nil {
                        sessionLimitResumeCandidate = try? await sessionToClaim(token: token, base: base)
                    }
                    if let existing = sessionLimitResumeCandidate {
                        loadingPhase = .resuming
                        streamLogger.info("Resuming after session limit sessionId=\(existing.sessionId, privacy: .public) status=\(existing.status) appId=\(existing.appId ?? "nil", privacy: .public) serverIp=\(existing.serverIp ?? "nil", privacy: .public)")
                        sessionInfo = try await cloudMatchClient.claimSession(
                            sessionId: existing.sessionId,
                            serverIp: existing.serverIp,
                            token: token,
                            base: base,
                            appId: existing.appId ?? appId,
                            settings: settings
                        )
                        resumedExistingSession = true
                    } else {
                        // Stale server sessions are blocking creation — stop them and retry once.
                        loadingPhase = .creating
                        let staleSessions = (try? await cloudMatchClient.getActiveSessions(token: token, base: base)) ?? []
                        streamLogger.error("No matching active session found; stopping \(staleSessions.count) stale sessions before retry")
                        for stale in staleSessions {
                            try? await cloudMatchClient.stopSession(sessionId: stale.sessionId, token: token, base: base)
                        }
                        sessionInfo = try await cloudMatchClient.createSession(createRequest)
                        createdNewSession = true
                    }
                }
            }
            guard var sessionInfo else { return }
            createdSession = sessionInfo

            // Poll with readyPollStreak confirmation (requires 2 consecutive ready polls).
            // While in queue: no timeout — user waits indefinitely with position updates.
            // After queue clears: 180-second setup timeout applies.
            var readyPollStreak = 0
            var setupStartTime: Date? = nil
            var emptyPlaceholderPolls = 0
            var recreatedEmptyPlaceholder = false
            var unhealthyStatusPolls = 0
            var rebuildAttempts = 0
            let maxRebuildAttempts = 2

            while readyPollStreak < 2 {
                streamLogger.info("Session poll state sessionId=\(sessionInfo.sessionId, privacy: .public) status=\(sessionInfo.status) queue=\(sessionInfo.queuePosition ?? -1) setupStep=\(sessionInfo.seatSetupStep ?? -1) serverIp=\(sessionInfo.serverIp, privacy: .public) media=\(sessionInfo.mediaConnectionInfo.map { "\($0.ip):\($0.port)" } ?? "nil", privacy: .public)")
                let emptyPlaceholder = sessionInfo.status == 0
                    && !SessionInfo.isValidHost(sessionInfo.serverIp)
                    && sessionInfo.mediaConnectionInfo == nil
                    && !sessionInfo.isInQueue
                if createdNewSession, emptyPlaceholder {
                    emptyPlaceholderPolls += 1
                    if emptyPlaceholderPolls >= 6 {
                        guard !recreatedEmptyPlaceholder else {
                            createdSession = nil
                            throw CloudMatchError.sessionCreateFailed("GeForce NOW returned an empty session placeholder. Please try again in a moment.")
                        }
                        streamLogger.error("Session stayed empty without endpoint; stopping and recreating once sessionId=\(sessionInfo.sessionId, privacy: .public)")
                        try? await cloudMatchClient.stopSession(
                            sessionId: sessionInfo.sessionId,
                            token: token,
                            base: sessionInfo.streamingBaseUrl
                        )
                        sessionInfo = try await cloudMatchClient.createSession(createRequest)
                        createdSession = sessionInfo
                        readyPollStreak = 0
                        setupStartTime = nil
                        emptyPlaceholderPolls = 0
                        recreatedEmptyPlaceholder = true
                        continue
                    }
                } else {
                    emptyPlaceholderPolls = 0
                }

                if isUnhealthyStartupStatus(sessionInfo.status), !sessionInfo.isInQueue {
                    unhealthyStatusPolls += 1
                    if unhealthyStatusPolls >= 6 {
                        guard rebuildAttempts < maxRebuildAttempts else {
                            loadingPhase = .timedOut
                            throw CloudMatchError.sessionCreateFailed("GeForce NOW session stalled during startup.")
                        }
                        rebuildAttempts += 1
                        sessionInfo = try await rebuildSession(
                            previous: sessionInfo,
                            request: createRequest,
                            token: token,
                            attempt: rebuildAttempts
                        )
                        createdSession = sessionInfo
                        createdNewSession = true
                        resumedExistingSession = false
                        readyPollStreak = 0
                        setupStartTime = nil
                        emptyPlaceholderPolls = 0
                        unhealthyStatusPolls = 0
                        continue
                    }
                } else {
                    unhealthyStatusPolls = 0
                }

                // Update loading phase and apply timeout only outside the queue
                if sessionInfo.isInQueue {
                    loadingPhase = .inQueue(sessionInfo.queuePosition)
                    setupStartTime = nil
                } else {
                    if setupStartTime == nil { setupStartTime = Date() }
                    if let t = setupStartTime, Date().timeIntervalSince(t) > 180 {
                        guard rebuildAttempts < maxRebuildAttempts else {
                            loadingPhase = .timedOut
                            throw CloudMatchError.sessionCreateFailed("GeForce NOW session timed out during startup.")
                        }
                        rebuildAttempts += 1
                        sessionInfo = try await rebuildSession(
                            previous: sessionInfo,
                            request: createRequest,
                            token: token,
                            attempt: rebuildAttempts
                        )
                        createdSession = sessionInfo
                        createdNewSession = true
                        resumedExistingSession = false
                        readyPollStreak = 0
                        setupStartTime = nil
                        emptyPlaceholderPolls = 0
                        unhealthyStatusPolls = 0
                        continue
                    }
                    loadingPhase = .preparing
                }

                if sessionInfo.status == 2 || sessionInfo.status == 3 {
                    readyPollStreak += 1
                } else {
                    readyPollStreak = 0
                }

                if readyPollStreak >= 2 { break }

                try await Task.sleep(for: .seconds(2))
                sessionInfo = try await cloudMatchClient.pollSession(
                    sessionId: sessionInfo.sessionId,
                    token: token,
                    base: sessionInfo.streamingBaseUrl,
                    serverIp: SessionInfo.isValidHost(sessionInfo.serverIp) ? sessionInfo.serverIp : nil,
                    clientId: sessionInfo.clientId,
                    deviceId: sessionInfo.deviceId
                )
                createdSession = sessionInfo
            }

            viewModel.recordPlayed(game)
            loadingPhase = .startingWebRTC
            if resumedExistingSession {
                let connected = try await connectWithIceRetries(
                    sessionInfo,
                    token: token,
                    base: base,
                    appId: appId,
                    maxRetries: 2
                )
                if !connected, rebuildAttempts < maxRebuildAttempts {
                    rebuildAttempts += 1
                    let rebuilt = try await rebuildSession(
                        previous: sessionInfo,
                        request: createRequest,
                        token: token,
                        attempt: rebuildAttempts
                    )
                    createdSession = rebuilt
                    viewModel.recordPlayed(game)
                    let rebuiltConnected = try await connectWithIceRetries(
                        rebuilt,
                        token: token,
                        base: base,
                        appId: appId,
                        maxRetries: 2
                    )
                    if !rebuiltConnected {
                        streamController.fail(with: "The stream could not finish connecting.")
                    }
                } else if !connected {
                    streamController.fail(with: "The stream could not finish connecting.")
                }
            } else {
                let connected = try await connectWithIceRetries(
                    sessionInfo,
                    token: token,
                    base: base,
                    appId: appId,
                    maxRetries: 2
                )
                if !connected, rebuildAttempts < maxRebuildAttempts {
                    rebuildAttempts += 1
                    let rebuilt = try await rebuildSession(
                        previous: sessionInfo,
                        request: createRequest,
                        token: token,
                        attempt: rebuildAttempts
                    )
                    createdSession = rebuilt
                    viewModel.recordPlayed(game)
                    let rebuiltConnected = try await connectWithIceRetries(
                        rebuilt,
                        token: token,
                        base: base,
                        appId: appId,
                        maxRetries: 2
                    )
                    if !rebuiltConnected {
                        streamController.fail(with: "The stream could not finish connecting.")
                    }
                } else if !connected {
                    streamController.fail(with: "The stream could not finish connecting.")
                }
            }
        } catch {
            streamController.fail(with: error.localizedDescription)
        }
    }

    private func resumeAndConnect(
        seed: SessionInfo,
        token: String,
        base: String,
        appId: String?,
        maxIceRetries: Int
    ) async throws -> Bool {
        var sessionInfo = seed
        for attempt in 0...maxIceRetries {
            loadingPhase = .resuming
            let resumeServer = SessionInfo.isValidHost(sessionInfo.serverIp) ? sessionInfo.serverIp : nil
            streamLogger.info("Attempting direct session resume sessionId=\(sessionInfo.sessionId, privacy: .public) attempt=\(attempt + 1) serverIp=\(resumeServer ?? "nil", privacy: .public) media=\(sessionInfo.mediaConnectionInfo.map { "\($0.ip):\($0.port)" } ?? "nil", privacy: .public) base=\(base, privacy: .public)")
            sessionInfo = try await cloudMatchClient.claimSession(
                sessionId: sessionInfo.sessionId,
                serverIp: resumeServer,
                token: token,
                base: base,
                appId: appId,
                settings: settings
            )
            createdSession = sessionInfo
            streamLogger.info("Resume claim returned sessionId=\(sessionInfo.sessionId, privacy: .public) status=\(sessionInfo.status) queue=\(sessionInfo.queuePosition ?? -1) setupStep=\(sessionInfo.seatSetupStep ?? -1) serverIp=\(sessionInfo.serverIp, privacy: .public) media=\(sessionInfo.mediaConnectionInfo.map { "\($0.ip):\($0.port)" } ?? "nil", privacy: .public)")
            if sessionInfo.isEmptyPlaceholder {
                clearDeadResume(sessionInfo, token: token, base: base)
                return false
            }

            sessionInfo = try await waitForResumedSessionReady(sessionInfo, token: token, base: base)
            guard !sessionInfo.isEmptyPlaceholder else { return false }
            if isUnhealthyStartupStatus(sessionInfo.status), !sessionInfo.isInQueue {
                return false
            }

            viewModel.recordPlayed(game)
            let connected = try await connectWithIceRetries(
                sessionInfo,
                token: token,
                base: base,
                appId: appId,
                maxRetries: 0
            )
            if connected { return true }
            if attempt < maxIceRetries {
                loadingPhase = .resuming
                streamLogger.error("Resume ICE failed; reclaiming session before retry attempt=\(attempt + 2)")
                try await Task.sleep(for: .seconds(1))
            }
        }
        return false
    }

    private func waitForResumedSessionReady(_ initial: SessionInfo, token: String, base: String) async throws -> SessionInfo {
        var sessionInfo = initial

        // The RESUME PUT can return a ready-looking session before media is actually
        // settled. Poll once before WebRTC so ICE gets the current endpoint.
        loadingPhase = .preparing
        try await Task.sleep(for: .seconds(1))
        sessionInfo = try await poll(sessionInfo, token: token)
        createdSession = sessionInfo
        streamLogger.info("Resume post-claim poll returned sessionId=\(sessionInfo.sessionId, privacy: .public) status=\(sessionInfo.status) queue=\(sessionInfo.queuePosition ?? -1) setupStep=\(sessionInfo.seatSetupStep ?? -1) serverIp=\(sessionInfo.serverIp, privacy: .public) media=\(sessionInfo.mediaConnectionInfo.map { "\($0.ip):\($0.port)" } ?? "nil", privacy: .public)")

        let timeout: TimeInterval = 60
        let start = Date()
        var unhealthyPolls = 0
        while sessionInfo.status != 2 && sessionInfo.status != 3 {
            if sessionInfo.isEmptyPlaceholder {
                clearDeadResume(sessionInfo, token: token, base: base)
                return sessionInfo
            }
            if isUnhealthyStartupStatus(sessionInfo.status), !sessionInfo.isInQueue {
                unhealthyPolls += 1
                if unhealthyPolls >= 3 {
                    streamLogger.error("Resume session stalled in unhealthy status=\(sessionInfo.status); returning to rebuild path")
                    return sessionInfo
                }
            } else {
                unhealthyPolls = 0
            }
            if Date().timeIntervalSince(start) > timeout {
                loadingPhase = .timedOut
                throw CloudMatchError.sessionCreateFailed("Timed out waiting for resumed session.")
            }
            loadingPhase = .preparing
            try await Task.sleep(for: .seconds(2))
            sessionInfo = try await poll(sessionInfo, token: token)
            createdSession = sessionInfo
            streamLogger.info("Resume wait poll returned sessionId=\(sessionInfo.sessionId, privacy: .public) status=\(sessionInfo.status) queue=\(sessionInfo.queuePosition ?? -1) setupStep=\(sessionInfo.seatSetupStep ?? -1) serverIp=\(sessionInfo.serverIp, privacy: .public) media=\(sessionInfo.mediaConnectionInfo.map { "\($0.ip):\($0.port)" } ?? "nil", privacy: .public)")
        }
        return sessionInfo
    }

    private func connectWithIceRetries(
        _ initial: SessionInfo,
        token: String,
        base: String,
        appId: String?,
        maxRetries: Int
    ) async throws -> Bool {
        var sessionInfo = initial
        for attempt in 0...maxRetries {
            loadingPhase = .startingWebRTC
            streamLogger.info("Starting WebRTC for resumed session sessionId=\(sessionInfo.sessionId, privacy: .public) attempt=\(attempt + 1) status=\(sessionInfo.status) serverIp=\(sessionInfo.serverIp, privacy: .public) signaling=\(sessionInfo.signalingServer, privacy: .public) media=\(sessionInfo.mediaConnectionInfo.map { "\($0.ip):\($0.port)" } ?? "nil", privacy: .public)")
            await streamController.connect(session: sessionInfo, settings: settings)
            let result = await waitForStreamStartupResult()
            switch result {
            case .connected:
                return true
            case .iceFailed:
                guard attempt < maxRetries else { return false }
                loadingPhase = .resuming
                streamLogger.error("ICE failed after WebRTC start; reclaiming session and retrying attempt=\(attempt + 2)")
                streamController.disconnect()
                try await Task.sleep(for: .seconds(1))
                sessionInfo = try await claimSessionAfterIceFailure(
                    sessionInfo,
                    token: token,
                    base: base,
                    appId: appId
                )
                sessionInfo = try await waitForResumedSessionReady(sessionInfo, token: token, base: base)
                if isUnhealthyStartupStatus(sessionInfo.status), !sessionInfo.isInQueue {
                    return false
                }
            case .failed(let message):
                streamLogger.error("WebRTC startup failed before stream became ready: \(message, privacy: .public)")
                streamController.disconnect()
                return false
            case .timedOut:
                streamLogger.error("WebRTC startup timed out")
                streamController.disconnect()
                return false
            }
        }
        return false
    }

    private enum StreamStartupResult {
        case connected
        case iceFailed
        case failed(String)
        case timedOut
    }

    private func waitForStreamStartupResult(timeout: TimeInterval = 25) async -> StreamStartupResult {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            switch streamController.state {
            case .streaming:
                return .connected
            case .failed(let message):
                if message.localizedCaseInsensitiveContains("ICE connection failed") {
                    return .iceFailed
                }
                return .failed(message)
            case .disconnected(let reason):
                return .failed(reason)
            case .idle, .connecting:
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        return .timedOut
    }

    private func claimSessionAfterIceFailure(
        _ session: SessionInfo,
        token: String,
        base: String,
        appId: String?
    ) async throws -> SessionInfo {
        do {
            return try await cloudMatchClient.claimSession(
                sessionId: session.sessionId,
                serverIp: SessionInfo.isValidHost(session.serverIp) ? session.serverIp : nil,
                token: token,
                base: base,
                appId: appId,
                settings: settings
            )
        } catch {
            streamLogger.error("Resume retry claim failed on last endpoint; trying active session lookup: \(error.localizedDescription, privacy: .public)")
            if let active = try await sessionToClaim(token: token, base: base) {
                return try await cloudMatchClient.claimSession(
                    sessionId: active.sessionId,
                    serverIp: active.serverIp,
                    token: token,
                    base: base,
                    appId: active.appId ?? appId,
                    settings: settings
                )
            }
            throw error
        }
    }

    private func poll(_ session: SessionInfo, token: String) async throws -> SessionInfo {
        try await cloudMatchClient.pollSession(
            sessionId: session.sessionId,
            token: token,
            base: session.streamingBaseUrl,
            serverIp: SessionInfo.isValidHost(session.serverIp) ? session.serverIp : nil,
            clientId: session.clientId,
            deviceId: session.deviceId
        )
    }

    private func isUnhealthyStartupStatus(_ status: Int) -> Bool {
        // Status 7 has shown up as a terminal/stuck CloudMatch state: it keeps an
        // endpoint but never becomes stream-ready. Treat repeated polls as a bad
        // allocation and rebuild the session.
        status == 7
    }

    private func rebuildSession(
        previous: SessionInfo,
        request: SessionCreateRequest,
        token: String,
        attempt: Int
    ) async throws -> SessionInfo {
        loadingPhase = .rebuilding(attempt)
        streamLogger.error("Rebuilding stalled session attempt=\(attempt) sessionId=\(previous.sessionId, privacy: .public) status=\(previous.status) serverIp=\(previous.serverIp, privacy: .public)")
        try? await cloudMatchClient.stopSession(
            sessionId: previous.sessionId,
            token: token,
            base: previous.streamingBaseUrl.isEmpty ? (request.streamingBaseUrl ?? NVIDIAAuth.defaultStreamingUrl) : previous.streamingBaseUrl
        )
        viewModel.resumableSession = nil
        streamController.disconnect()
        try await Task.sleep(for: .seconds(1))
        loadingPhase = .creating
        return try await cloudMatchClient.createSession(request)
    }

    // Leaves the stream locally without stopping the server session.
    // GFN keeps the session alive for ~1–2 minutes so it can be resumed from home.
    private func leave() {
        recordLeaveIfNeeded()
        streamController.disconnect()
        onDismiss()
    }

    private func recordLeaveIfNeeded() {
        guard !didEndSession, !didRecordLeave, let session = createdSession else { return }
        guard !isEmptySessionPlaceholder(session) else { return }
        didRecordLeave = true
        streamLogger.info("Recording resumable session sessionId=\(session.sessionId, privacy: .public) serverIp=\(session.serverIp, privacy: .public) media=\(session.mediaConnectionInfo.map { "\($0.ip):\($0.port)" } ?? "nil", privacy: .public)")
        onLeave?(game, session)
    }

    private func disconnect() {
        didEndSession = true
        didRecordLeave = false
        // Intentional end — clear any pending resumable session
        viewModel.resumableSession = nil
        if let session = createdSession {
            streamLogger.info("Ending server session sessionId=\(session.sessionId, privacy: .public)")
        }
        // Tell the server to stop the session so it doesn't linger
        if let session = createdSession, let token = sessionToken {
            Task {
                try? await cloudMatchClient.stopSession(
                    sessionId: session.sessionId,
                    token: token,
                    base: session.streamingBaseUrl
                )
            }
        }
        streamController.disconnect()
        onDismiss()
    }

    private func isEmptySessionPlaceholder(_ sessionInfo: SessionInfo) -> Bool {
        sessionInfo.isEmptyPlaceholder
    }

    private func clearDeadResume(_ session: SessionInfo, token: String, base: String) {
        streamLogger.error("Discarding empty placeholder sessionId=\(session.sessionId, privacy: .public); falling back to fresh session")
        if viewModel.resumableSession?.session.sessionId == session.sessionId {
            viewModel.resumableSession = nil
        }
        createdSession = nil
        Task {
            try? await cloudMatchClient.stopSession(
                sessionId: session.sessionId,
                token: token,
                base: session.streamingBaseUrl.isEmpty ? base : session.streamingBaseUrl
            )
        }
    }

    private func sessionToClaimIfAvailable(token: String, base: String) async throws -> ActiveSessionInfo? {
        do {
            return try await sessionToClaim(token: token, base: base)
        } catch {
            streamLogger.error("Active session lookup failed; continuing with fresh create path: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func sessionToClaim(token: String, base: String) async throws -> ActiveSessionInfo? {
        if let existingSession {
            return existingSession
        }

        let activeSessions = try await cloudMatchClient.getActiveSessions(token: token, base: base)
        viewModel.activeSessions = activeSessions
        return activeSessions.first { session in
            game.variants.contains { variant in
                guard let appId = variant.appId ?? Optional(variant.id),
                      let sessionAppId = session.appId else { return false }
                return appId == sessionAppId
            }
        }
    }

    private func reportAd(id: String, action: AdAction, watchedMs: Int? = nil) {
        // Prevent duplicate reports for the same action on the same ad
        guard adReportedAction[id] != action else { return }
        adReportedAction[id] = action
        guard let session = createdSession, let token = sessionToken else { return }
        Task {
            await cloudMatchClient.reportAdEvent(
                sessionId: session.sessionId,
                token: token,
                base: session.streamingBaseUrl,
                serverIp: SessionInfo.isValidHost(session.serverIp) ? session.serverIp : nil,
                clientId: session.clientId,
                deviceId: session.deviceId,
                adId: id,
                action: action,
                watchedTimeMs: watchedMs
            )
        }
    }

    private func toggleOverlay() {
        showOverlay.toggle()
        // Pause input forwarding while the overlay is visible so swipes don't move
        // the game cursor and keyboard shortcuts don't reach the game accidentally.
        streamController.setInputPaused(showOverlay)
    }
}

struct StreamStartupBackground: View {
    let game: GameInfo

    var body: some View {
        SteamLaunchBackground()
    }
}

struct SteamLaunchBackground: View {
    var body: some View {
        Image("SteamStartupBackground")
            .resizable()
            .scaledToFill()
            .ignoresSafeArea()
    }
}

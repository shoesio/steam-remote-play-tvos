import SwiftUI
import OSLog

private enum MainSection: String, Identifiable {
    case home
    case geforceNow
    case xbox
    case sunshine
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .home: return "Home"
        case .geforceNow: return "GFN"
        case .xbox: return "X-box"
        case .sunshine: return "Sunshine"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .geforceNow: return "bolt.fill"
        case .xbox: return "xbox.logo"
        case .sunshine: return "sun.max.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

private enum SunshinePowerError: LocalizedError {
    case missingHost
    case missingMACAddress
    case missingUtilityApp(String)
    case wakePacketFailed
    case wakeTimedOut
    case shutdownNotConfirmed

    var errorDescription: String? {
        switch self {
        case .missingHost:
            return "The Sunshine host is not configured."
        case .missingMACAddress:
            return "Wake-on-LAN is waiting for Sunshine to report the host MAC address."
        case .missingUtilityApp(let name):
            return "The Sunshine \(name) utility app is not available."
        case .wakePacketFailed:
            return "The Wake-on-LAN packet could not be sent."
        case .wakeTimedOut:
            return "The BC-250 did not respond after repeated Wake-on-LAN packets."
        case .shutdownNotConfirmed:
            return "The BC-250 did not go offline, so its Apple Home power outlet was left on."
        }
    }
}

struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AuthManager.self) var authManager
    @Environment(XCloudAuthManager.self) var xcloudAuth
    @Environment(XCloudLibraryStore.self) var xcloudLibrary
    @Environment(SunshineHostStore.self) var sunshineHostStore
    @Environment(HomeKitPowerOutletStore.self) var homeKitPowerOutletStore
    @AppStorage("app.localProviderSetup") private var localProviderSetup = false
    @State private var viewModel = GamesViewModel()
    @State private var gameToPlay: GameInfo?
    @State private var sunshineGameToLaunch: GameInfo?
    @State private var xcloudGameToLaunch: XCloudGame?
    @State private var sessionToResume: ActiveSessionInfo? = nil
    @State private var directSessionToResume: SessionInfo? = nil
    @State private var selectedSection: MainSection = .home
    @State private var hasAppliedInitialSelection = false
    @State private var pendingTopShelfLaunchID: String?
    @State private var powerStatusMessage: String?
    @State private var powerErrorMessage: String?
    @State private var isPowerActionInProgress = false
    @State private var isShowingShutdownConfirmation = false
    private let logger = Logger(subsystem: "CloudNow", category: "Launch")
    private let sunshinePowerClient = SunshineClient()
    private static let navLogger = Logger(subsystem: "CloudNow", category: "NavPerf")

    private var navigationSections: [MainSection] {
        var result: [MainSection] = [.home]
        if sunshineHostStore.isConfigured && sunshineHostStore.isPaired { result.append(.sunshine) }
        if authManager.isAuthenticated { result.append(.geforceNow) }
        if xcloudAuth.isSignedIn { result.append(.xbox) }
        result.append(.settings)
        return result
    }

    var body: some View {
        let _ = Self.logBodyRender(selectedSection: selectedSection)

        TabView(selection: $selectedSection) {
            ForEach(navigationSections) { section in
                content(for: section)
                    .tag(section)
                    .tabItem {
                        Label(section.title, systemImage: section.systemImage)
                    }
            }
        }
        .background(Color.appBackground.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            powerNavigationControl
                .padding(.top, 8)
                .padding(.trailing, 52)
                .offset(y: -22)
                .zIndex(10)
        }
        .environment(viewModel)
        .environment(sunshineHostStore)
        .environment(xcloudAuth)
        .environment(xcloudLibrary)
        .task {
            applyInitialSelectionIfNeeded()
            viewModel.setXCloudGames(
                xcloudLibrary.gameInfos,
                newOnXCloud: xcloudLibrary.newOnXCloudGameInfos,
                mostPopular: xcloudLibrary.mostPopularGameInfos
            )
            if xcloudAuth.isSignedIn {
                await xcloudLibrary.load(auth: xcloudAuth, force: true)
                viewModel.setXCloudGames(
                    xcloudLibrary.gameInfos,
                    newOnXCloud: xcloudLibrary.newOnXCloudGameInfos,
                    mostPopular: xcloudLibrary.mostPopularGameInfos
                )
            }
            await viewModel.load(authManager: authManager, sunshineHostStore: sunshineHostStore)
            await refreshSunshineWakeDetails()
            launchPendingTopShelfGameIfPossible()
        }
        .onOpenURL { url in
            handleTopShelfURL(url)
        }
        .task(id: sunshineHostStore.isPaired) {
            guard sunshineHostStore.isPaired else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(120))
                } catch {
                    return
                }
                guard scenePhase == .active,
                      gameToPlay == nil,
                      sunshineGameToLaunch == nil,
                      xcloudGameToLaunch == nil else { continue }
                await viewModel.syncSunshine(hostStore: sunshineHostStore)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await viewModel.syncSunshine(hostStore: sunshineHostStore) }
        }
        .onChange(of: navigationSections) { _, sections in
            if !sections.contains(selectedSection) {
                selectedSection = sections.first ?? .settings
            }
        }
        .onChange(of: xcloudAuth.isSignedIn) { _, signedIn in
            Task {
                if signedIn {
                    await xcloudLibrary.load(auth: xcloudAuth, force: true)
                    viewModel.setXCloudGames(
                        xcloudLibrary.gameInfos,
                        newOnXCloud: xcloudLibrary.newOnXCloudGameInfos,
                        mostPopular: xcloudLibrary.mostPopularGameInfos
                    )
                } else {
                    xcloudLibrary.clear()
                    viewModel.setXCloudGames([])
                }
                launchPendingTopShelfGameIfPossible()
            }
        }
        .onChange(of: authManager.isAuthenticated) { _, signedIn in
            if signedIn {
                Task {
                    await viewModel.load(authManager: authManager, sunshineHostStore: sunshineHostStore, force: true)
                    launchPendingTopShelfGameIfPossible()
                }
            }
        }
        .onChange(of: sunshineHostStore.isPaired) { _, _ in
            Task {
                await viewModel.load(authManager: authManager, sunshineHostStore: sunshineHostStore, force: true)
                launchPendingTopShelfGameIfPossible()
            }
        }
        .onChange(of: selectedSection) { _, section in
            Self.navLogger.info("Native tab selected=\(section.rawValue, privacy: .public)")
            guard section == .sunshine else { return }
            Task { await viewModel.syncSunshine(hostStore: sunshineHostStore) }
        }
        .onChange(of: viewModel.streamSettings) { _, _ in viewModel.saveSettings() }
        .onChange(of: gameToPlay) { _, new in
            if new == nil {
                directSessionToResume = nil
                Task { await viewModel.refreshActiveSessions(authManager: authManager, force: true) }
            }
        }
        .onChange(of: sunshineGameToLaunch) { oldValue, newValue in
            logger.info("Sunshine launch selection changed: old=\(oldValue?.title ?? "nil", privacy: .public) new=\(newValue?.title ?? "nil", privacy: .public)")
        }
        .confirmationDialog(
            "Shut down \(sunshineHostStore.name)?",
            isPresented: $isShowingShutdownConfirmation,
            titleVisibility: .visible
        ) {
            Button("Shut Down", role: .destructive) {
                Task { await performPowerAction(.shutdown) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The remote Sunshine host will power off completely.")
        }
        .alert(
            "Power Action Failed",
            isPresented: Binding(
                get: { powerErrorMessage != nil },
                set: { if !$0 { powerErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                powerErrorMessage = nil
            }
        } message: {
            Text(powerErrorMessage ?? "The power action could not be completed.")
        }
        .fullScreenCover(item: $gameToPlay) { game in
            StreamView(
                game: game,
                settings: viewModel.streamSettings,
                existingSession: sessionToResume,
                directSession: directSessionToResume,
                onDismiss: {
                    gameToPlay = nil
                    sessionToResume = nil
                },
                onLeave: { leftGame, session in
                    viewModel.resumableSession = ResumableSession(
                        game: leftGame,
                        session: session,
                        leftAt: Date()
                    )
                }
            )
            .environment(authManager)
            .environment(viewModel)
        }
        .fullScreenCover(item: $sunshineGameToLaunch) { game in
            SunshineLaunchView(
                game: game,
                host: sunshineHostStore.host ?? SunshineHost(
                    name: "Sunshine",
                    address: "",
                    httpPort: SunshineHost.defaultHTTPPort,
                    httpsPort: SunshineHost.defaultHTTPSPort,
                    macAddress: "",
                    webUsername: "sunshine",
                    webPassword: "",
                    uniqueId: nil,
                    serverCertificateDER: nil,
                    isPaired: false
                ),
                settings: viewModel.sunshineStreamSettings,
                wakeHostIfNeeded: { updateStatus in
                    guard let host = sunshineHostStore.host else {
                        throw SunshinePowerError.missingHost
                    }
                    try await wakeSunshineHost(
                        host,
                        reportStatus: updateStatus,
                        syncAfterWake: false
                    )
                },
                onDismiss: {
                    logger.info("SunshineLaunchView requested dismiss for \(game.title, privacy: .public)")
                    sunshineGameToLaunch = nil
                }
            )
            .environment(viewModel)
            .interactiveDismissDisabled(true)
        }
        .fullScreenCover(item: $xcloudGameToLaunch) { game in
            XCloudStreamView(
                game: game,
                controllerDeadzone: viewModel.streamSettings.controllerDeadzone,
                onDismiss: { xcloudGameToLaunch = nil }
            )
                .environment(xcloudAuth)
        }
    }

    @ViewBuilder
    private func content(for section: MainSection) -> some View {
        switch section {
        case .home:
            HomeView(
                onPlay: { game in
                    Task { await play(game) }
                },
                onResume: { rs in
                    directSessionToResume = rs.session
                    sessionToResume = nil
                    gameToPlay = rs.game
                }
            )
        case .geforceNow:
            ProviderLibraryView(
                title: "GeForce NOW",
                subtitle: "Your NVIDIA library",
                systemImage: "bolt.fill",
                accent: .green,
                games: viewModel.libraryGames,
                isLoading: viewModel.isLoading,
                errorMessage: viewModel.libraryError,
                emptyMessage: "No playable games are currently in your GeForce NOW library.",
                onReload: { Task { await viewModel.load(authManager: authManager, sunshineHostStore: sunshineHostStore, force: true) } },
                onPlay: { game in
                    Task { await play(game) }
                }
            )
        case .sunshine:
            ProviderLibraryView(
                title: "Sunshine",
                subtitle: sunshineHostStore.name,
                systemImage: "sun.max.fill",
                accent: .orange,
                games: viewModel.localSunshineGames,
                isLoading: viewModel.isLoading || viewModel.isSunshineSyncing,
                errorMessage: viewModel.sunshineError,
                emptyMessage: "No applications were returned by this Sunshine host.",
                onReload: { Task { await viewModel.syncSunshine(hostStore: sunshineHostStore, force: true) } },
                onPlay: { game in
                    Task { await play(game) }
                }
            )
        case .xbox:
            XCloudLibraryView(
                onPlay: { game in Task { await play(game) } }
            )
        case .settings:
            UnifiedSettingsView()
        }
    }

    private static func logBodyRender(
        selectedSection: MainSection
    ) {
        navLogger.debug("MainTabView body selected=\(selectedSection.rawValue, privacy: .public)")
    }

    @ViewBuilder
    private var powerNavigationControl: some View {
        if sunshineHostStore.isConfigured && sunshineHostStore.isPaired {
            Menu {
                Button {
                    Task { await performPowerAction(.wake) }
                } label: {
                    Label("Wake", systemImage: "sunrise.fill")
                }
                .disabled(isPowerActionInProgress || sunshineHostStore.host?.macAddress.isEmpty != false)

                Button {
                    Task { await performPowerAction(.sleep) }
                } label: {
                    Label("Sleep", systemImage: "moon.zzz.fill")
                }
                .disabled(isPowerActionInProgress || viewModel.sunshinePowerApp(for: .sleep) == nil)

                Divider()

                Button(role: .destructive) {
                    isShowingShutdownConfirmation = true
                } label: {
                    Label("Shut Down", systemImage: "power")
                }
                .disabled(isPowerActionInProgress || viewModel.sunshinePowerApp(for: .shutdown) == nil)
            } label: {
                Group {
                    if isPowerActionInProgress {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "power.circle.fill")
                    }
                }
                .font(.body)
                .frame(width: 36, height: 36)
            }
            .accessibilityLabel(powerStatusMessage ?? "BC-250 power options")
            .disabled(isPowerActionInProgress)
        }
    }

    private func applyInitialSelectionIfNeeded() {
        guard !hasAppliedInitialSelection else { return }
        hasAppliedInitialSelection = true

        if !authManager.isAuthenticated, xcloudAuth.isSignedIn {
            selectedSection = .xbox
        } else if !authManager.isAuthenticated, sunshineHostStore.isConfigured && sunshineHostStore.isPaired {
            selectedSection = .sunshine
        } else if !authManager.isAuthenticated {
            selectedSection = localProviderSetup ? .settings : .home
        }
    }

    private func play(_ game: GameInfo) async {
        directSessionToResume = nil
        let launchGame = viewModel.gameWithPreferredStore(game)
        if launchGame.isXCloudGame, let titleID = launchGame.xcloudTitleID,
           let xcloudGame = xcloudLibrary.game(titleID: titleID) {
            logger.info("Routing Xbox Cloud launch title=\(launchGame.title, privacy: .public) id=\(titleID, privacy: .public)")
            viewModel.recordPlayed(launchGame)
            xcloudGameToLaunch = xcloudGame
            return
        }
        guard !launchGame.isSunshineGame else {
            logger.info("Routing Sunshine launch title=\(launchGame.title, privacy: .public) id=\(launchGame.id, privacy: .public)")
            sunshineGameToLaunch = launchGame
            return
        }
        logger.info("Routing GFN launch title=\(launchGame.title, privacy: .public) id=\(launchGame.id, privacy: .public)")
        sessionToResume = await viewModel.prepareForGFNLaunch(launchGame, authManager: authManager)
        gameToPlay = launchGame
    }

    private func refreshSunshineWakeDetails() async {
        guard let host = sunshineHostStore.host else { return }
        guard let info = try? await sunshinePowerClient.fetchServerInfo(host: host, fastFail: true) else {
            viewModel.clearActiveSunshineStream()
            return
        }
        sunshineHostStore.updateWakeMACAddress(info.macAddress)
        let currentGame = info.currentGame?.trimmingCharacters(in: .whitespacesAndNewlines)
        if currentGame == nil || currentGame?.isEmpty == true || currentGame == "0" {
            viewModel.clearActiveSunshineStream()
        }
    }

    private func performPowerAction(_ action: SunshinePowerAction) async {
        guard !isPowerActionInProgress else { return }
        isPowerActionInProgress = true
        defer { isPowerActionInProgress = false }

        do {
            guard let host = sunshineHostStore.host else {
                throw SunshinePowerError.missingHost
            }

            switch action {
            case .wake:
                try await wakeSunshineHost(host)
            case .sleep, .shutdown:
                try await runSunshinePowerApp(action, host: host)
            }
        } catch is CancellationError {
            powerStatusMessage = nil
        } catch {
            powerStatusMessage = nil
            powerErrorMessage = error.localizedDescription
        }
    }

    private func wakeSunshineHost(
        _ host: SunshineHost,
        reportStatus: ((String) -> Void)? = nil,
        syncAfterWake: Bool = true
    ) async throws {
        if let info = try? await sunshinePowerClient.fetchServerInfo(host: host, fastFail: true) {
            sunshineHostStore.updateWakeMACAddress(info.macAddress)
            return
        }

        func updateStatus(_ message: String) {
            powerStatusMessage = message
            reportStatus?(message)
        }

        await homeKitPowerOutletStore.refresh()
        let hasPowerOutlet = homeKitPowerOutletStore.hasSelectedOutlet
        let outletWasOff = homeKitPowerOutletStore.selectedOutlet?.isOn == false
        if hasPowerOutlet {
            updateStatus("Turning on the BC-250 power outlet…")
            try await homeKitPowerOutletStore.setSelectedOutletPower(true)
            if outletWasOff {
                try await Task.sleep(for: .seconds(2))
            }
        }

        guard !host.macAddress.isEmpty || hasPowerOutlet else {
            throw SunshinePowerError.missingMACAddress
        }

        updateStatus("Sending a Wake-on-LAN packet to \(host.name)…")
        var wakePacketSent = false
        if !host.macAddress.isEmpty {
            wakePacketSent = CNWakeOnLAN.send(
                macAddress: host.macAddress,
                host: host.address,
                basePort: host.httpPort
            )
        }
        guard wakePacketSent || hasPowerOutlet else {
            throw SunshinePowerError.wakePacketFailed
        }

        for attempt in 0..<30 {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(2))
            if let info = try? await sunshinePowerClient.fetchServerInfo(host: host, fastFail: true) {
                sunshineHostStore.updateWakeMACAddress(info.macAddress)
                if syncAfterWake {
                    await viewModel.syncSunshine(hostStore: sunshineHostStore, force: true)
                }
                updateStatus("\(host.name) is awake. Starting Steam…")
                return
            }
            if attempt > 0, attempt.isMultiple(of: 3), !host.macAddress.isEmpty {
                updateStatus("Waiting for \(host.name) to wake…")
                _ = CNWakeOnLAN.send(
                    macAddress: host.macAddress,
                    host: host.address,
                    basePort: host.httpPort
                )
            }
        }
        throw SunshinePowerError.wakeTimedOut
    }

    private func runSunshinePowerApp(_ action: SunshinePowerAction, host: SunshineHost) async throws {
        let displayName = action == .sleep ? "Sleep" : "Shut Down"
        guard let app = viewModel.sunshinePowerApp(for: action) else {
            throw SunshinePowerError.missingUtilityApp(displayName)
        }

        if action == .shutdown,
           (try? await sunshinePowerClient.fetchServerInfo(host: host, fastFail: true)) == nil {
            powerStatusMessage = "Waking \(host.name) so it can shut down…"
            try await wakeSunshineHost(host, syncAfterWake: false)
            powerStatusMessage = "\(host.name) is awake. Preparing to shut down…"
        }

        powerStatusMessage = action == .sleep
            ? "Putting \(host.name) to sleep…"
            : "Shutting down \(host.name)…"

        try await stopRunningSunshineAppIfNeeded(host)

        do {
            _ = try await sunshinePowerClient.launchApp(
                host: host,
                appId: app.appId,
                settings: viewModel.sunshineStreamSettings
            )
        } catch {
            if error.localizedDescription.localizedCaseInsensitiveContains("already running") {
                try await stopRunningSunshineAppIfNeeded(host, force: true)
                do {
                    _ = try await sunshinePowerClient.launchApp(
                        host: host,
                        appId: app.appId,
                        settings: viewModel.sunshineStreamSettings
                    )
                } catch {
                    if (try? await sunshinePowerClient.fetchServerInfo(host: host, fastFail: true)) != nil {
                        throw error
                    }
                }
            } else {
                // A power command can close the network connection before Sunshine
                // finishes its launch response. Treat an unreachable host as success.
                if (try? await sunshinePowerClient.fetchServerInfo(host: host, fastFail: true)) != nil {
                    throw error
                }
            }
        }

        var wentOffline = false
        let offlineCheckCount = action == .shutdown ? 60 : 20
        for _ in 0..<offlineCheckCount {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(1))
            if (try? await sunshinePowerClient.fetchServerInfo(host: host, fastFail: true)) == nil {
                wentOffline = true
                break
            }
        }

        if wentOffline {
            viewModel.clearActiveSunshineStream()
        }

        if action == .shutdown, homeKitPowerOutletStore.hasSelectedOutlet {
            guard wentOffline else {
                throw SunshinePowerError.shutdownNotConfirmed
            }
            powerStatusMessage = "Waiting for the BC-250 to finish shutting down…"
            try await Task.sleep(for: .seconds(8))
            powerStatusMessage = "Turning off the BC-250 power outlet…"
            try await homeKitPowerOutletStore.setSelectedOutletPower(false)
        }

        let completedMessage: String
        if wentOffline {
            completedMessage = action == .sleep
                ? "\(host.name) is asleep"
                : "\(host.name) is shut down"
        } else {
            completedMessage = "\(displayName) command sent to \(host.name)"
        }
        showPowerResult(completedMessage)
    }

    private func stopRunningSunshineAppIfNeeded(_ host: SunshineHost, force: Bool = false) async throws {
        var shouldCancel = force
        if !force,
           let info = try? await sunshinePowerClient.fetchServerInfo(host: host, fastFail: true),
           let currentGame = info.currentGame?.trimmingCharacters(in: .whitespacesAndNewlines) {
            shouldCancel = !currentGame.isEmpty && currentGame != "0"
        }
        guard shouldCancel else { return }

        powerStatusMessage = "Stopping the current Sunshine app…"
        try await sunshinePowerClient.cancelRunningApp(host: host)

        for _ in 0..<10 {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(500))
            guard let info = try? await sunshinePowerClient.fetchServerInfo(host: host, fastFail: true) else {
                return
            }
            let currentGame = info.currentGame?.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentGame == nil || currentGame?.isEmpty == true || currentGame == "0" {
                return
            }
        }
    }

    private func showPowerResult(_ message: String) {
        powerStatusMessage = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard powerStatusMessage == message, !isPowerActionInProgress else { return }
            powerStatusMessage = nil
        }
    }

    private func handleTopShelfURL(_ url: URL) {
        guard url.scheme == "cloudnow" else { return }
        selectedSection = .home

        guard url.host == "play" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard let gameID = components?.queryItems?.first(where: { $0.name == "id" })?.value else { return }
        pendingTopShelfLaunchID = gameID
        launchPendingTopShelfGameIfPossible()
    }

    private func launchPendingTopShelfGameIfPossible() {
        guard let gameID = pendingTopShelfLaunchID else { return }
        guard let game = topShelfGame(withID: gameID) else { return }

        pendingTopShelfLaunchID = nil
        Task { await play(game) }
    }

    private func topShelfGame(withID gameID: String) -> GameInfo? {
        viewModel.allKnownGames.first { $0.id == gameID }
            ?? viewModel.homeSnapshot.heroGames.first { $0.id == gameID }
    }
}

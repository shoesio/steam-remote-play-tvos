import Foundation
import Observation
import os
import UIKit

struct ResumableSession: Codable {
    let game: GameInfo
    let session: SessionInfo
    let leftAt: Date
    /// Grace window before we stop offering to resume (GFN keeps the session ~2 min).
    static let gracePeriod: TimeInterval = 110

    var secondsRemaining: Int {
        max(0, Int(Self.gracePeriod - Date().timeIntervalSince(leftAt)))
    }
    var isExpired: Bool { secondsRemaining == 0 }
}

struct ActiveSunshineStream: Codable, Equatable {
    let game: GameInfo
    let host: SunshineHost
    let startedAt: Date

    static let gracePeriod: TimeInterval = 6 * 60 * 60

    var isExpired: Bool {
        Date().timeIntervalSince(startedAt) >= Self.gracePeriod
    }
}

private struct GamesCacheSnapshot: Codable {
    let savedAt: Date
    let mainGames: [GameInfo]
    let libraryGames: [GameInfo]
    let publicCatalogGames: [GameInfo]
    let sunshineGames: [GameInfo]?
    let xcloudGames: [GameInfo]?
    let xcloudNewGames: [GameInfo]?
    let xcloudPopularGames: [GameInfo]?
    let canonicalGames: [CanonicalGame]?
}

private struct UserGameCustomization: Codable {
    var gameIds: Set<String>
    var canonicalId: String?
    var variantIds: Set<String>
    var normalizedTitle: String
    var displayTitle: String?
    var heroURL: String
    var coverURL: String?
    var metadata: GameMetadataLookupResult
    var isUserSelected: Bool

    enum CodingKeys: String, CodingKey {
        case gameIds, canonicalId, variantIds, normalizedTitle, displayTitle, heroURL, coverURL, metadata, isUserSelected
    }

    init(
        gameIds: Set<String>,
        canonicalId: String?,
        variantIds: Set<String>,
        normalizedTitle: String,
        displayTitle: String? = nil,
        heroURL: String,
        coverURL: String? = nil,
        metadata: GameMetadataLookupResult,
        isUserSelected: Bool = true
    ) {
        self.gameIds = gameIds
        self.canonicalId = canonicalId
        self.variantIds = variantIds
        self.normalizedTitle = normalizedTitle
        self.displayTitle = displayTitle
        self.heroURL = heroURL
        self.coverURL = coverURL
        self.metadata = metadata
        self.isUserSelected = isUserSelected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gameIds = try container.decode(Set<String>.self, forKey: .gameIds)
        canonicalId = try container.decodeIfPresent(String.self, forKey: .canonicalId)
        variantIds = try container.decode(Set<String>.self, forKey: .variantIds)
        normalizedTitle = try container.decode(String.self, forKey: .normalizedTitle)
        displayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle)
        heroURL = try container.decode(String.self, forKey: .heroURL)
        coverURL = try container.decodeIfPresent(String.self, forKey: .coverURL)
        metadata = try container.decode(GameMetadataLookupResult.self, forKey: .metadata)
        isUserSelected = try container.decodeIfPresent(Bool.self, forKey: .isUserSelected) ?? true
    }
}

struct HomeSnapshot {
    static let empty = HomeSnapshot(
        continuePlaying: [],
        recentlyPlayedGames: [],
        favoriteGames: [],
        homeLibraryGames: [],
        localSunshineGames: [],
        xcloudGames: [],
        xcloudNewGames: [],
        xcloudPopularGames: [],
        xboxGames: [],
        popularGames: [],
        heroGames: [],
        hasHomeContent: false
    )

    let continuePlaying: [GameInfo]
    let recentlyPlayedGames: [GameInfo]
    let favoriteGames: [GameInfo]
    let homeLibraryGames: [GameInfo]
    let localSunshineGames: [GameInfo]
    let xcloudGames: [GameInfo]
    let xcloudNewGames: [GameInfo]
    let xcloudPopularGames: [GameInfo]
    let xboxGames: [GameInfo]
    let popularGames: [GameInfo]
    let heroGames: [GameInfo]
    let hasHomeContent: Bool
}

@MainActor
@Observable
class GamesViewModel {
    var mainGames: [GameInfo] = [] {
        didSet { rebuildHomeSnapshot() }
    }
    var libraryGames: [GameInfo] = [] {
        didSet { rebuildHomeSnapshot() }
    }
    var publicCatalogGames: [GameInfo] = []
    var sunshineGames: [GameInfo] = [] {
        didSet { rebuildHomeSnapshot() }
    }
    private(set) var sunshinePowerApps: [SunshinePowerAction: SunshineGame] = [:]
    var xcloudGames: [GameInfo] = [] {
        didSet { rebuildHomeSnapshot() }
    }
    var xcloudNewGames: [GameInfo] = [] {
        didSet { rebuildHomeSnapshot() }
    }
    var xcloudPopularGames: [GameInfo] = [] {
        didSet { rebuildHomeSnapshot() }
    }
    var canonicalGames: [CanonicalGame] = []
    var activeSessions: [ActiveSessionInfo] = [] {
        didSet { rebuildHomeSnapshot() }
    }
    var isLoading = false
    var isSunshineSyncing = false
    private(set) var lastSunshineSync: Date?
    var isMatchingMetadata = false
    var error: String?
    var libraryError: String?
    var sunshineError: String?
    var metadataMatchStatus: String?
    var isScrapingHeroArtwork = false
    var heroArtworkScrapeStatus: String?
    var heroArtworkCandidates: [GameMetadataArtworkCandidate] = []
    var isScrapingCoverArtwork = false
    var coverArtworkScrapeStatus: String?
    var coverArtworkCandidates: [GameMetadataArtworkCandidate] = []
    var isSearchingMetadata = false
    var metadataSearchStatus: String?
    var metadataSearchCandidates: [GameMetadataLookupResult] = []
    private var isRestoringPersistentState = true
    var hiddenHeroIds: Set<String> = [] {
        didSet {
            guard !isRestoringPersistentState else { return }
            saveHiddenHeroIds()
            rebuildHomeSnapshot()
        }
    }
    var pinnedHeroIds: Set<String> = [] {
        didSet {
            guard !isRestoringPersistentState else { return }
            savePinnedHeroIds()
            rebuildHomeSnapshot()
        }
    }

    var favoriteIds: Set<String> = [] {
        didSet { rebuildHomeSnapshot() }
    }
    var preferredStoreIds: [String: String] = [:]
    var recentlyPlayedIds: [String] = [] {
        didSet { rebuildHomeSnapshot() }
    }
    var streamSettings: StreamSettings = StreamSettings()
    var subscription: SubscriptionInfo? = nil
    private(set) var steamGridDBAPIKey: String? = SteamGridDBKeychain.load()
    var isSteamGridDBConnected: Bool { !(steamGridDBAPIKey ?? "").isEmpty }
    /// Session the user left without ending — available to resume for ~2 minutes.
    var resumableSession: ResumableSession? = nil {
        didSet {
            saveResumableSession()
            rebuildHomeSnapshot()
        }
    }
    var activeSunshineStream: ActiveSunshineStream? = nil {
        didSet {
            saveActiveSunshineStream()
            rebuildHomeSnapshot()
        }
    }
    var homeSnapshot: HomeSnapshot = .empty

    private let gamesClient = GamesClient()
    private let cloudMatchClient = CloudMatchClient()
    private let sunshineClient = SunshineClient()
    private let metadataLookupClient = GameMetadataLookupClient()
    private let steamGridDBService = SteamGridDBService()
    private let catalogLogger = Logger(subsystem: "CloudNow", category: "Catalog")
    private let homePerfLogger = Logger(subsystem: "CloudNow", category: "HomePerf")
    private var hasLoaded = false
    private var isRefreshingActiveSessions = false
    private var lastActiveSessionsRefresh: Date?
    private var userGameCustomizations: [UserGameCustomization] = []
    private var isResolvingAutomaticHeroArtwork = false
    private var isAutomaticHeroArtworkPassScheduled = false
    private var automaticHeroArtworkQueuedSeed: GameInfo?
    private var defersHomeSnapshotRebuild = false
    private var needsDeferredHomeSnapshotRebuild = false
    private var automaticHeroArtworkFailedIds: Set<String> = []
    private static let sunshineRefreshInterval: TimeInterval = 120
    private static let automaticHeroArtworkBatchLimit = 1
    private static let automaticHeroArtworkInitialDelay: Duration = .seconds(5)
    private static let automaticHeroArtworkFollowUpDelay: Duration = .seconds(20)

    init() {
        if let data = UserDefaults.standard.data(forKey: "gfn.favoriteIds"),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            self.favoriteIds = Set(ids)
        }
        if let data = UserDefaults.standard.data(forKey: "gfn.preferredStores"),
           let stores = try? JSONDecoder().decode([String: String].self, from: data) {
            self.preferredStoreIds = stores
        }
        if let data = UserDefaults.standard.data(forKey: "gfn.recentlyPlayed"),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            self.recentlyPlayedIds = ids
        }
        if let data = UserDefaults.standard.data(forKey: "home.hiddenHeroIds"),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            self.hiddenHeroIds = Set(ids)
        }
        if let data = UserDefaults.standard.data(forKey: "home.pinnedHeroIds"),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            self.pinnedHeroIds = Set(ids)
        }
        if let data = UserDefaults.standard.data(forKey: "gfn.streamSettings"),
           let settings = try? JSONDecoder().decode(StreamSettings.self, from: data) {
            self.streamSettings = settings
        }
        // IGDB credentials were used by a retired artwork source and should not linger locally.
        UserDefaults.standard.removeObject(forKey: "metadata.lookupSettings")
        if let data = UserDefaults.standard.data(forKey: "gfn.resumableSession"),
           let session = try? JSONDecoder().decode(ResumableSession.self, from: data),
           !session.isExpired,
           !session.session.isEmptyPlaceholder,
           session.session.hasValidResumeEndpoint {
            self.resumableSession = session
        } else {
            UserDefaults.standard.removeObject(forKey: "gfn.resumableSession")
        }
        if let data = UserDefaults.standard.data(forKey: "sunshine.activeStream"),
           let stream = try? JSONDecoder().decode(ActiveSunshineStream.self, from: data),
           !stream.isExpired {
            self.activeSunshineStream = stream
        } else {
            UserDefaults.standard.removeObject(forKey: "sunshine.activeStream")
        }
        loadCachedGamesSnapshot()
        loadUserGameCustomizations()
        applyUserGameCustomizations()
        // tvOS currently caps at 60 Hz; clamp any saved value to the screen maximum.
        // If Apple raises the cap in a future tvOS release this will automatically unlock.
        let screenMax = UIScreen.main.maximumFramesPerSecond
        if streamSettings.fps > screenMax {
            streamSettings.fps = screenMax
        }
        if streamSettings.isBitrateAuto {
            streamSettings.applyRecommendedBitrate()
        }
        isRestoringPersistentState = false
        rebuildHomeSnapshot()
    }

    // MARK: Computed — Entitled Resolutions & FPS

    /// Resolution strings available to the current account tier.
    /// Falls back to a standard preset if no subscription data is available.
    var availableResolutions: [String] {
        guard let resos = subscription?.entitledResolutions, !resos.isEmpty else {
            return ["1280x720", "1920x1080"]
        }
        let unique = Array(Set(resos.map(\.resolutionLabel)))
        return unique.sorted {
            let lw = Int($0.split(separator: "x").first ?? "") ?? 0
            let rw = Int($1.split(separator: "x").first ?? "") ?? 0
            return lw < rw
        }
    }

    /// FPS values available for the currently selected resolution, capped to the
    /// screen's maximum refresh rate. Today tvOS caps at 60 Hz; if Apple raises it
    /// in a future update this will automatically expose the higher option.
    var availableFps: [Int] {
        let maxFps = UIScreen.main.maximumFramesPerSecond
        guard let resos = subscription?.entitledResolutions, !resos.isEmpty else {
            return [30, 60].filter { $0 <= maxFps }
        }
        let parts = streamSettings.resolution.split(separator: "x").compactMap { Int($0) }
        let w = parts.first ?? 1920
        let h = parts.last  ?? 1080
        let matching = resos.filter { $0.widthInPixels == w && $0.heightInPixels == h }
        let source = matching.isEmpty ? resos : matching
        return Array(Set(source.map(\.framesPerSecond))).filter { $0 <= maxFps }.sorted()
    }

    /// Moonlight settings with Sunshine's independent resolution applied.
    var sunshineStreamSettings: StreamSettings {
        var settings = streamSettings
        settings.resolution = settings.sunshineResolution
        settings.fps = settings.sunshineFPS
        settings.codec = settings.sunshineCodec.fallbackVideoCodec
        settings.isBitrateAuto = settings.sunshineIsBitrateAuto
        settings.maxBitrateKbps = settings.sunshineIsBitrateAuto
            ? StreamSettings.recommendedSunshineBitrateKbps(
                resolution: settings.sunshineResolution,
                fps: settings.sunshineFPS,
                codec: settings.sunshineCodec
            )
            : settings.sunshineMaxBitrateKbps
        return settings
    }

    // MARK: Computed — Games

    var allKnownGames: [GameInfo] {
        mergeGames(primary: libraryGames + sunshineGames + xcloudGames + xcloudNewGames + xcloudPopularGames, secondary: mainGames)
    }

    var continuePlaying: [GameInfo] {
        let sessionAppIds = Set(activeSessions.compactMap { $0.appId })
        var games = allKnownGames.filter { game in
            game.variants.contains { v in
                guard let appId = v.appId else { return false }
                return sessionAppIds.contains(appId)
            }
        }
        if let activeSunshineStream,
           !games.contains(where: { $0.id == activeSunshineStream.game.id }),
           let game = allKnownGames.first(where: { $0.id == activeSunshineStream.game.id }) ?? Optional(activeSunshineStream.game) {
            games.insert(game, at: 0)
        }
        return games
    }

    func activeSession(for game: GameInfo) -> ActiveSessionInfo? {
        activeSessions.first { session in
            sessionMatchesGame(session, game: game)
        }
    }

    var favoriteGames: [GameInfo] {
        var seen = Set<String>()
        return allKnownGames.filter { favoriteIds.contains($0.id) && seen.insert($0.id).inserted }
    }

    var recentlyPlayedGames: [GameInfo] {
        return recentlyPlayedIds.compactMap { id in
            allKnownGames.first { $0.id == id }
        }
    }

    func isSessionActive(for game: GameInfo) -> Bool {
        if activeSunshineStream?.game.id == game.id {
            return true
        }
        if let resumableSession, !resumableSession.isExpired, resumableSession.game.id == game.id {
            return true
        }
        return activeSession(for: game) != nil
    }

    var homeLibraryGames: [GameInfo] {
        let hiddenIds = Set((continuePlaying + recentlyPlayedGames + favoriteGames).map(\.id))
        return libraryGames.filter { !hiddenIds.contains($0.id) }
    }

    var popularGames: [GameInfo] {
        let hiddenIds = homePrimaryHiddenIds
        return mainGames.filter { !hiddenIds.contains($0.id) }
    }

    var xboxGames: [GameInfo] {
        let hiddenIds = homePrimaryHiddenIds
        return mainGames.filter { game in
            !hiddenIds.contains(game.id) && game.variants.contains { $0.appStore == "XBOX" || $0.appStore == "MICROSOFT" }
        }
    }

    var localSunshineGames: [GameInfo] {
        sunshineGames.filter { !$0.isReservedSunshinePowerApp }
    }

    func sunshinePowerApp(for action: SunshinePowerAction) -> SunshineGame? {
        sunshinePowerApps[action]
    }

    func setXCloudGames(_ games: [GameInfo], newOnXCloud: [GameInfo] = [], mostPopular: [GameInfo] = []) {
        xcloudGames = games
        xcloudNewGames = newOnXCloud
        xcloudPopularGames = mostPopular
        applyUserGameCustomizations()
        saveCachedGamesSnapshot()
        scheduleAutomaticHeroArtworkLookup(reason: "xcloud", delay: Self.automaticHeroArtworkInitialDelay)
    }

    var catalogStoreCounts: [(store: String, count: Int)] {
        let pairs = allKnownGames.flatMap { game in
            Set(game.variants.map(\.appStore)).map { store in (store, game.id) }
        }
        let grouped = Dictionary(grouping: pairs, by: \.0)
        return grouped
            .map { (store: $0.key, count: Set($0.value.map(\.1)).count) }
            .sorted { $0.count > $1.count }
    }

    var hasHomeContent: Bool {
        homeSnapshot.hasHomeContent
    }

    var doomCatalogMatches: [GameInfo] {
        allKnownGames
            .filter { $0.title.localizedCaseInsensitiveContains("doom") }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var gamesMissingHeroCount: Int {
        allKnownGames.filter { ($0.heroBannerUrl ?? "").isEmpty }.count
    }

    var gamesWithCoverHeroFallbackCount: Int {
        allKnownGames.filter {
            ($0.heroBannerUrl ?? "").isEmpty && ($0.boxArtUrl ?? "").isEmpty == false
        }.count
    }

    var sunshineReviewNeededCount: Int {
        sunshineGames.filter(\.needsReview).count
    }

    private var homePrimaryHiddenIds: Set<String> {
        Set((continuePlaying + recentlyPlayedGames + favoriteGames + homeLibraryGames + localSunshineGames + xcloudGames + xcloudNewGames + xcloudPopularGames).map(\.id))
    }

    private var activeResumableExists: Bool {
        guard let resumableSession else { return false }
        return !resumableSession.isExpired
    }

    private func rebuildHomeSnapshot() {
        guard !defersHomeSnapshotRebuild else {
            needsDeferredHomeSnapshotRebuild = true
            return
        }
        let start = CFAbsoluteTimeGetCurrent()
        let allKnown = mergeGames(primary: libraryGames + sunshineGames + xcloudGames + xcloudNewGames + xcloudPopularGames, secondary: mainGames)
        var byId: [String: GameInfo] = [:]
        byId.reserveCapacity(allKnown.count)
        for game in allKnown where byId[game.id] == nil {
            byId[game.id] = game
        }

        let sessionAppIds = Set(activeSessions.compactMap(\.appId))
        var continuePlaying = allKnown.filter { game in
            game.variants.contains { variant in
                guard let appId = variant.appId else { return false }
                return sessionAppIds.contains(appId)
            }
        }
        if let activeSunshineStream,
           !continuePlaying.contains(where: { $0.id == activeSunshineStream.game.id }) {
            continuePlaying.insert(byId[activeSunshineStream.game.id] ?? activeSunshineStream.game, at: 0)
        }

        var favoriteSeen = Set<String>()
        let favorites = allKnown.filter { game in
            favoriteIds.contains(game.id) && favoriteSeen.insert(game.id).inserted
        }
        let recentlyPlayed = recentlyPlayedIds.compactMap { byId[$0] }

        let hiddenBeforeLibrary = Set((continuePlaying + recentlyPlayed + favorites).map(\.id))
        let homeLibrary = libraryGames.filter { !hiddenBeforeLibrary.contains($0.id) }
        let localSunshine = sunshineGames
        let xcloudNew = uniqueById(xcloudNewGames).filter { !hiddenBeforeLibrary.contains($0.id) }
        let xcloudNewIds = Set(xcloudNew.map(\.id))
        let xcloudPopular = uniqueById(xcloudPopularGames).filter {
            !hiddenBeforeLibrary.contains($0.id) && !xcloudNewIds.contains($0.id)
        }
        let xcloudPlaylistIds = xcloudNewIds.union(xcloudPopular.map(\.id))
        let xcloudLibrary = xcloudGames.filter { !hiddenBeforeLibrary.contains($0.id) && !xcloudPlaylistIds.contains($0.id) }

        let primaryHiddenIds = Set((continuePlaying + recentlyPlayed + favorites + homeLibrary + localSunshine + xcloudNew + xcloudPopular + xcloudLibrary).map(\.id))
        let xbox = mainGames.filter { game in
            !primaryHiddenIds.contains(game.id)
                && game.variants.contains { $0.appStore == "XBOX" || $0.appStore == "MICROSOFT" }
        }
        let xboxIds = Set(xbox.map(\.id))
        let popular = mainGames.filter { game in
            !primaryHiddenIds.contains(game.id) && !xboxIds.contains(game.id)
        }

        var heroGames: [GameInfo] = []
        var heroSeen = Set<String>()
        func appendHeroes(_ games: [GameInfo]) {
            guard heroGames.count < 8 else { return }
            for game in games where !hiddenHeroIds.contains(game.id) && heroSeen.insert(game.id).inserted {
                heroGames.append(game)
                if heroGames.count >= 8 { return }
            }
        }

        appendHeroes(allKnown.filter { pinnedHeroIds.contains($0.id) })
        appendHeroes(resumableSession.map { [$0.game] } ?? [])
        appendHeroes(continuePlaying)
        appendHeroes(recentlyPlayed)
        appendHeroes(favorites)
        appendHeroes(homeLibrary)
        appendHeroes(localSunshine)
        appendHeroes(xcloudNew)
        appendHeroes(xcloudPopular)
        appendHeroes(xcloudLibrary)
        appendHeroes(xbox)
        appendHeroes(popular)

        homeSnapshot = HomeSnapshot(
            continuePlaying: continuePlaying,
            recentlyPlayedGames: recentlyPlayed,
            favoriteGames: favorites,
            homeLibraryGames: homeLibrary,
            localSunshineGames: localSunshine,
            xcloudGames: xcloudLibrary,
            xcloudNewGames: xcloudNew,
            xcloudPopularGames: xcloudPopular,
            xboxGames: xbox,
            popularGames: popular,
            heroGames: heroGames,
            hasHomeContent: activeResumableExists
                || !continuePlaying.isEmpty
                || !recentlyPlayed.isEmpty
                || !favorites.isEmpty
                || !homeLibrary.isEmpty
                || !localSunshine.isEmpty
                || !xcloudNew.isEmpty
                || !xcloudPopular.isEmpty
                || !xcloudLibrary.isEmpty
                || !xbox.isEmpty
                || !popular.isEmpty
        )
        TopShelfHeroStore.saveHeroes(heroGames)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        homePerfLogger.info("HomeSnapshot rebuilt elapsedMs=\(elapsedMs) allKnown=\(allKnown.count) hero=\(heroGames.count) favorites=\(favorites.count) library=\(homeLibrary.count) local=\(localSunshine.count) xcloudNew=\(xcloudNew.count) xcloudPopular=\(xcloudPopular.count) xcloud=\(xcloudLibrary.count) xbox=\(xbox.count) popular=\(popular.count)")
    }

    func setSunshineStreamPresentationActive(_ active: Bool) {
        guard defersHomeSnapshotRebuild != active else { return }
        defersHomeSnapshotRebuild = active
        guard !active, needsDeferredHomeSnapshotRebuild else { return }
        needsDeferredHomeSnapshotRebuild = false
        rebuildHomeSnapshot()
    }

    // MARK: Load

    func load(authManager: AuthManager, sunshineHostStore: SunshineHostStore? = nil, force: Bool = false) async {
        guard force || !hasLoaded else { return }
        guard !isLoading else { return }
        isLoading = true
        error = nil
        libraryError = nil
        sunshineError = nil
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            var shouldSaveSnapshot = true
            var fetchedSunshineApps: [SunshineGame]?
            let previousPublicCatalogGames = publicCatalogGames
            let previousMainGames = mainGames
            let previousLibraryGames = libraryGames
            let previousSunshineGames = sunshineGames
            let previousCanonicalGames = canonicalGames

            if let host = sunshineHostStore?.host, host.isPaired {
                do {
                    let sunshineApps = try await sunshineClient.fetchAppList(host: host)
                    fetchedSunshineApps = sunshineApps
                    applySunshineImport(
                        sunshineApps,
                        canonicalCandidates: publicCatalogGames + mainGames + libraryGames
                    )
                    lastSunshineSync = Date()
                    catalogLogger.info("[Sunshine] loaded local apps count=\(sunshineApps.count)")
                } catch {
                    if isCancellation(error) {
                        catalogLogger.info("[Sunshine] app list fetch cancelled; keeping previous Sunshine snapshot")
                        shouldSaveSnapshot = false
                    } else {
                        sunshineError = error.localizedDescription
                        sunshineGames = previousSunshineGames
                        canonicalGames = previousCanonicalGames
                        shouldSaveSnapshot = false
                        catalogLogger.error("[Sunshine] app list fetch failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            } else {
                sunshineGames = []
                canonicalGames.removeAll { game in
                    game.launchOptions.contains { $0.providerID == .sunshine }
                }
                sunshineError = nil
            }

            guard authManager.isAuthenticated else {
                if let fetchedSunshineApps {
                    applySunshineImport(
                        fetchedSunshineApps,
                        canonicalCandidates: publicCatalogGames + mainGames + libraryGames
                    )
                }
                applyUserGameCustomizations()
                activeSessions = []
                subscription = nil
                if shouldSaveSnapshot {
                    saveCachedGamesSnapshot()
                }
                scheduleAutomaticHeroArtworkLookup(reason: "load-local", delay: Self.automaticHeroArtworkInitialDelay)
                return
            }

            let token = try await authManager.resolveToken()
            let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl

            let panelMainGames = try await gamesClient.fetchMainGames(token: token, streamingBaseUrl: base)
            do {
                publicCatalogGames = try await gamesClient.fetchPublicCatalog(streamingBaseUrl: base)
            } catch {
                if isCancellation(error) {
                    catalogLogger.info("Public catalog fetch cancelled; keeping previous catalog snapshot")
                    shouldSaveSnapshot = false
                } else {
                    publicCatalogGames = previousPublicCatalogGames
                    shouldSaveSnapshot = false
                    catalogLogger.error("Public catalog fetch failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            mainGames = mergeGames(primary: panelMainGames, secondary: publicCatalogGames)
            if mainGames.isEmpty {
                mainGames = previousMainGames
            }

            // Non-fatal — may be empty if no games are linked to account
            var panelLibrary: [GameInfo] = []
            do {
                panelLibrary = try await gamesClient.fetchLibrary(token: token, streamingBaseUrl: base)
            } catch {
                if isCancellation(error) {
                    catalogLogger.info("Library fetch cancelled; keeping previous library snapshot")
                    panelLibrary = previousLibraryGames
                    shouldSaveSnapshot = false
                } else {
                    libraryError = error.localizedDescription
                    panelLibrary = previousLibraryGames
                    shouldSaveSnapshot = false
                }
            }

            // The LIBRARY panel under-reports owned games. The MAIN catalog carries a per-variant
            // `gfn.library.selected` flag, so union it with catalog games flagged as owned
            // (dedup by id, panel order first) for a complete list.
            let catalogOwned = mainGames.filter { $0.isInLibrary }
            libraryGames = mergeGames(primary: panelLibrary, secondary: catalogOwned)

            if let fetchedSunshineApps {
                applySunshineImport(
                    fetchedSunshineApps,
                    canonicalCandidates: mainGames + libraryGames + publicCatalogGames
                )
            }

            applyUserGameCustomizations()

            if shouldSaveSnapshot {
                saveCachedGamesSnapshot()
            }
            logCatalogDiagnostics(panelMainGames: panelMainGames)
            scheduleAutomaticHeroArtworkLookup(reason: "load", delay: Self.automaticHeroArtworkInitialDelay)

            // Non-fatal — may fail if no active sessions or server returns 404
            activeSessions = (try? await cloudMatchClient.getActiveSessions(token: token, base: base)) ?? []

            // Non-fatal — fetch subscription tier and entitled resolutions
            if let userId = authManager.session?.user.userId {
                let vpcId = (try? await MESClient.shared.fetchVpcId(token: token, base: base)) ?? ""
                let sub = try? await MESClient.shared.fetchSubscription(token: token, vpcId: vpcId, userId: userId)
                subscription = sub
            }
        } catch {
            if !isCancellation(error) {
                self.error = error.localizedDescription
            }
        }
    }

    /// Refreshes only Sunshine's app list, avoiding an expensive reload of the
    /// other providers. Automatic callers are throttled; user-initiated syncs
    /// can bypass the freshness window with `force`.
    func syncSunshine(hostStore: SunshineHostStore, force: Bool = false) async {
        guard let host = hostStore.host, host.isPaired else { return }
        guard !isLoading else { return }
        if !force,
           let lastSunshineSync,
           Date().timeIntervalSince(lastSunshineSync) < Self.sunshineRefreshInterval {
            return
        }
        guard !isSunshineSyncing else { return }

        isSunshineSyncing = true
        sunshineError = nil
        defer { isSunshineSyncing = false }

        do {
            let apps = try await sunshineClient.fetchAppList(host: host)
            applySunshineImport(
                apps,
                canonicalCandidates: mainGames + libraryGames + publicCatalogGames
            )
            applyUserGameCustomizations()
            lastSunshineSync = Date()
            saveCachedGamesSnapshot()
            scheduleAutomaticHeroArtworkLookup(reason: "sunshine-sync", delay: Self.automaticHeroArtworkInitialDelay)
            catalogLogger.info("[Sunshine] synced local apps count=\(apps.count)")
        } catch {
            guard !isCancellation(error) else { return }
            sunshineError = error.localizedDescription
            catalogLogger.error("[Sunshine] sync failed; keeping previous snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    func matchMissingMetadata(authManager: AuthManager, sunshineHostStore: SunshineHostStore) async {
        guard !isMatchingMetadata else { return }
        isMatchingMetadata = true
        metadataMatchStatus = "Matching metadata..."
        defer { isMatchingMetadata = false }

        await load(authManager: authManager, sunshineHostStore: sunshineHostStore, force: true)

        let remoteHeroMatches = await lookupMissingGameMetadata()

        let matchedSunshine = sunshineGames.filter { ($0.matchConfidence ?? 0) >= 0.82 }.count
        let coverFallbacks = gamesWithCoverHeroFallbackCount
        let missingHeroes = gamesMissingHeroCount
        let reviewCount = sunshineReviewNeededCount
        metadataMatchStatus = "Matched \(matchedSunshine) Sunshine apps. Added \(remoteHeroMatches) metadata heroes. \(coverFallbacks) cover hero fallbacks available. \(missingHeroes) games still have no provider hero. \(reviewCount) need review."
    }

    func scrapeHeroArtworkCandidates(for game: GameInfo) async {
        guard !isScrapingHeroArtwork else { return }
        isScrapingHeroArtwork = true
        heroArtworkScrapeStatus = "Searching artwork..."
        heroArtworkCandidates = []
        defer { isScrapingHeroArtwork = false }

        let canonical = canonicalGame(for: game)
        do {
            let remoteCandidates = try await metadataLookupClient.artworkCandidates(
                title: game.title,
                igdbId: canonical?.externalIds.igdbId,
                gameDBId: canonical?.externalIds.gameDBId,
                steamAppId: canonical?.externalIds.steamAppId,
                steamGridDBAPIKey: steamGridDBAPIKey
            )
            let candidates = uniqueArtworkCandidates(currentArtworkCandidates(for: game, canonical: canonical) + remoteCandidates)
            heroArtworkCandidates = candidates
            let steamGridDBCount = candidates.filter { $0.source == .steamGridDB }.count
            heroArtworkScrapeStatus = candidates.isEmpty
                ? "No artwork options found."
                : "Found \(candidates.count) artwork option\(candidates.count == 1 ? "" : "s")\(steamGridDBCount > 0 ? " · \(steamGridDBCount) from SteamGridDB" : "")."
            catalogLogger.info("[Metadata] hero scrape game=\(game.title, privacy: .public) candidates=\(candidates.count)")
        } catch {
            heroArtworkCandidates = []
            heroArtworkScrapeStatus = "Artwork search failed: \(error.localizedDescription)"
            catalogLogger.info("[Metadata] hero scrape failed game=\(game.title, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func applyHeroArtworkCandidate(_ candidate: GameMetadataArtworkCandidate, to game: GameInfo) {
        applyHeroArtworkCandidate(candidate, to: game, userSelected: true)
        heroArtworkScrapeStatus = "Hero artwork updated."
        catalogLogger.info("[Metadata] hero selected game=\(game.title, privacy: .public) source=\(candidate.source.rawValue, privacy: .public) url=\(candidate.url, privacy: .public)")
    }

    func scrapeCoverArtworkCandidates(for game: GameInfo) async {
        guard !isScrapingCoverArtwork else { return }
        isScrapingCoverArtwork = true
        coverArtworkScrapeStatus = "Searching covers..."
        coverArtworkCandidates = []
        defer { isScrapingCoverArtwork = false }

        let canonical = canonicalGame(for: game)
        do {
            let remoteCandidates = try await metadataLookupClient.coverArtworkCandidates(
                title: game.title,
                igdbId: canonical?.externalIds.igdbId,
                gameDBId: canonical?.externalIds.gameDBId,
                steamAppId: canonical?.externalIds.steamAppId,
                steamGridDBAPIKey: steamGridDBAPIKey
            )
            let currentCandidate = currentCoverArtworkCandidate(for: game, canonical: canonical)
            let candidates = uniqueArtworkCandidates([currentCandidate].compactMap { $0 } + remoteCandidates)
            coverArtworkCandidates = candidates
            let steamGridDBCount = candidates.filter { $0.source == .steamGridDB }.count
            coverArtworkScrapeStatus = candidates.isEmpty
                ? "No cover options found."
                : "Found \(candidates.count) cover option\(candidates.count == 1 ? "" : "s")\(steamGridDBCount > 0 ? " · \(steamGridDBCount) from SteamGridDB" : "")."
            catalogLogger.info("[Metadata] cover scrape game=\(game.title, privacy: .public) candidates=\(candidates.count)")
        } catch {
            coverArtworkCandidates = []
            coverArtworkScrapeStatus = "Cover search failed: \(error.localizedDescription)"
            catalogLogger.info("[Metadata] cover scrape failed game=\(game.title, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    func applyCoverArtworkCandidate(_ candidate: GameMetadataArtworkCandidate, to game: GameInfo) {
        let metadata = candidate.metadata
        let updatedGame = gameWithCover(game, coverURL: candidate.url, metadata: metadata)
        mainGames = mainGames.map { gameMatches($0, game) ? gameWithCover($0, coverURL: candidate.url, metadata: metadata) : $0 }
        libraryGames = libraryGames.map { gameMatches($0, game) ? gameWithCover($0, coverURL: candidate.url, metadata: metadata) : $0 }
        publicCatalogGames = publicCatalogGames.map { gameMatches($0, game) ? gameWithCover($0, coverURL: candidate.url, metadata: metadata) : $0 }
        sunshineGames = sunshineGames.map { gameMatches($0, game) ? gameWithCover($0, coverURL: candidate.url, metadata: metadata) : $0 }
        xcloudGames = xcloudGames.map { gameMatches($0, game) ? gameWithCover($0, coverURL: candidate.url, metadata: metadata) : $0 }
        xcloudNewGames = xcloudNewGames.map { gameMatches($0, game) ? gameWithCover($0, coverURL: candidate.url, metadata: metadata) : $0 }
        xcloudPopularGames = xcloudPopularGames.map { gameMatches($0, game) ? gameWithCover($0, coverURL: candidate.url, metadata: metadata) : $0 }

        if activeSunshineStream?.game.id == game.id, let activeSunshineStream {
            self.activeSunshineStream = ActiveSunshineStream(game: updatedGame, host: activeSunshineStream.host, startedAt: activeSunshineStream.startedAt)
        }
        if resumableSession?.game.id == game.id, let resumableSession {
            self.resumableSession = ResumableSession(game: updatedGame, session: resumableSession.session, leftAt: resumableSession.leftAt)
        }

        canonicalGames = canonicalGames.map { canonical in
            guard canonicalMatches(canonical, game: game) else { return canonical }
            var updated = canonical
            updated.externalIds.mergeMissing(from: metadata.externalIds)
            updated.artwork = updated.artwork.map { asset in
                var copy = asset
                if copy.role == .tileCover { copy.isPreferred = false }
                return copy
            }
            if !updated.artwork.contains(where: { $0.role == .tileCover && $0.url == candidate.url }) {
                updated.artwork.append(ArtworkAsset(
                    id: "\(updated.id):user-cover:\(candidate.id)",
                    role: .tileCover,
                    source: candidate.source,
                    url: candidate.url,
                    isUserSelected: true,
                    isPreferred: true
                ))
            }
            return updated
        }

        saveUserCoverCustomization(for: game, coverURL: candidate.url, metadata: metadata)
        coverArtworkScrapeStatus = "Cover artwork updated."
        saveCachedGamesSnapshot()
        catalogLogger.info("[Metadata] cover selected game=\(game.title, privacy: .public) source=\(candidate.source.rawValue, privacy: .public) url=\(candidate.url, privacy: .public)")
    }

    func searchMetadata(correctedTitle: String) async {
        let title = correctedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2, !isSearchingMetadata else { return }
        isSearchingMetadata = true
        metadataSearchStatus = "Searching GameDB..."
        metadataSearchCandidates = []
        defer { isSearchingMetadata = false }

        let candidates = await metadataLookupClient.metadataCandidates(title: title)
        metadataSearchCandidates = candidates
        metadataSearchStatus = candidates.isEmpty
            ? "No metadata matches found. You can still apply the corrected name."
            : "Choose the matching game to apply its name and metadata."
    }

    func resetMetadataSearch() {
        metadataSearchCandidates = []
        metadataSearchStatus = nil
    }

    func applyCorrectedName(_ correctedTitle: String, metadata: GameMetadataLookupResult?, to game: GameInfo) async {
        let title = correctedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var selectedMetadata = metadata ?? GameMetadataLookupResult(
            source: .providerMetadata,
            title: title,
            releaseDate: nil,
            releaseYear: nil,
            developer: nil,
            publisher: nil,
            genres: [],
            summary: nil,
            externalIds: ExternalGameIds(),
            heroArtworkUrl: nil,
            screenshotUrl: nil
        )
        selectedMetadata = await metadataByFillingMissingArtwork(
            selectedMetadata,
            title: selectedMetadata.title ?? title,
            game: game
        )
        let confirmedTitle = selectedMetadata.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? selectedMetadata.title!
            : title
        let updatedGame = gameWithMetadata(game, title: confirmedTitle, metadata: selectedMetadata)

        mainGames = mainGames.map { gameMatches($0, game) ? gameWithMetadata($0, title: confirmedTitle, metadata: selectedMetadata) : $0 }
        libraryGames = libraryGames.map { gameMatches($0, game) ? gameWithMetadata($0, title: confirmedTitle, metadata: selectedMetadata) : $0 }
        publicCatalogGames = publicCatalogGames.map { gameMatches($0, game) ? gameWithMetadata($0, title: confirmedTitle, metadata: selectedMetadata) : $0 }
        sunshineGames = sunshineGames.map { gameMatches($0, game) ? gameWithMetadata($0, title: confirmedTitle, metadata: selectedMetadata) : $0 }
        xcloudGames = xcloudGames.map { gameMatches($0, game) ? gameWithMetadata($0, title: confirmedTitle, metadata: selectedMetadata) : $0 }
        xcloudNewGames = xcloudNewGames.map { gameMatches($0, game) ? gameWithMetadata($0, title: confirmedTitle, metadata: selectedMetadata) : $0 }
        xcloudPopularGames = xcloudPopularGames.map { gameMatches($0, game) ? gameWithMetadata($0, title: confirmedTitle, metadata: selectedMetadata) : $0 }

        if activeSunshineStream?.game.id == game.id, let activeSunshineStream {
            self.activeSunshineStream = ActiveSunshineStream(game: updatedGame, host: activeSunshineStream.host, startedAt: activeSunshineStream.startedAt)
        }
        if resumableSession?.game.id == game.id, let resumableSession {
            self.resumableSession = ResumableSession(game: updatedGame, session: resumableSession.session, leftAt: resumableSession.leftAt)
        }

        canonicalGames = canonicalGames.map { canonical in
            guard canonicalMatches(canonical, game: game) else { return canonical }
            var updated = canonical
            updated.title = confirmedTitle
            updated.platform = resolvedGamePlatformName(selectedMetadata.platform)
                ?? resolvedGamePlatformName(updated.platform)
            updated.releaseDate = selectedMetadata.releaseDate ?? updated.releaseDate
            updated.releaseYear = selectedMetadata.releaseYear ?? updated.releaseYear
            updated.developer = selectedMetadata.developer ?? updated.developer
            updated.publisher = selectedMetadata.publisher ?? updated.publisher
            updated.summary = selectedMetadata.summary ?? updated.summary
            updated.genres = unique(selectedMetadata.genres + updated.genres)
            updated.externalIds.mergeMissing(from: selectedMetadata.externalIds)
            updated.matchSources = Array(Set(updated.matchSources + [.userConfirmed])).sorted { $0.rawValue < $1.rawValue }
            updated.needsReview = false
            if let heroURL = selectedMetadata.heroArtworkUrl,
               (game.heroBannerUrl ?? "").isEmpty,
               !updated.artwork.contains(where: { $0.role == .heroBackground && $0.url == heroURL }) {
                updated.artwork.append(ArtworkAsset(
                    id: "\(updated.id):manual-metadata-hero",
                    role: .heroBackground,
                    source: selectedMetadata.source,
                    url: heroURL,
                    isUserSelected: true,
                    isPreferred: true
                ))
            }
            if let coverURL = selectedMetadata.coverArtworkUrl,
               (game.boxArtUrl ?? "").isEmpty,
               !updated.artwork.contains(where: { $0.role == .tileCover && $0.url == coverURL }) {
                updated.artwork.append(ArtworkAsset(
                    id: "\(updated.id):manual-metadata-cover",
                    role: .tileCover,
                    source: selectedMetadata.source,
                    url: coverURL,
                    isUserSelected: true,
                    isPreferred: true
                ))
            }
            return updated
        }

        saveUserMetadataCustomization(for: game, displayTitle: confirmedTitle, metadata: selectedMetadata)
        metadataSearchStatus = "Name and metadata updated."
        saveCachedGamesSnapshot()
        catalogLogger.info("[Metadata] manual match game=\(game.title, privacy: .public) corrected=\(confirmedTitle, privacy: .public) source=\(selectedMetadata.source.rawValue, privacy: .public)")
    }

    private func metadataByFillingMissingArtwork(
        _ metadata: GameMetadataLookupResult,
        title: String,
        game: GameInfo
    ) async -> GameMetadataLookupResult {
        var updated = metadata
        let heroOnlyRepeatsCover = updated.heroArtworkUrl != nil
            && updated.heroArtworkUrl == updated.coverArtworkUrl
        let needsHero = (game.heroBannerUrl ?? "").isEmpty
            && ((updated.heroArtworkUrl ?? "").isEmpty || heroOnlyRepeatsCover)
        let needsCover = (game.boxArtUrl ?? "").isEmpty && (updated.coverArtworkUrl ?? "").isEmpty
        guard needsHero || needsCover else { return updated }

        if needsHero {
            let candidates = (try? await metadataLookupClient.artworkCandidates(
                title: title,
                igdbId: metadata.externalIds.igdbId,
                gameDBId: metadata.externalIds.gameDBId,
                steamAppId: metadata.externalIds.steamAppId,
                steamGridDBAPIKey: steamGridDBAPIKey
            )) ?? []
            if let bestHero = candidates.first(where: { $0.role == .heroBackground })?.url
                ?? candidates.first(where: { $0.role == .screenshot })?.url {
                updated.heroArtworkUrl = bestHero
            }
        }
        if needsCover {
            let candidates = (try? await metadataLookupClient.coverArtworkCandidates(
                title: title,
                igdbId: metadata.externalIds.igdbId,
                gameDBId: metadata.externalIds.gameDBId,
                steamAppId: metadata.externalIds.steamAppId,
                steamGridDBAPIKey: steamGridDBAPIKey
            )) ?? []
            updated.coverArtworkUrl = candidates.first?.url
        }
        return updated
    }

    func displayMetadata(for game: GameInfo) -> CanonicalGame? {
        let provider = game.providerMetadata
        guard var metadata = canonicalGame(for: game) ?? provider.map({ provider in
            CanonicalGame(
                id: game.canonicalId ?? game.id,
                title: game.title,
                platform: provider.platform,
                releaseDate: provider.releaseDate,
                releaseYear: provider.releaseYear,
                developer: provider.developer,
                publisher: provider.publisher,
                genres: provider.genres,
                summary: provider.summary,
                externalIds: ExternalGameIds(),
                providerEntries: [],
                launchOptions: [],
                artwork: [],
                matchConfidence: game.matchConfidence ?? 1,
                matchSources: [],
                needsReview: false
            )
        }) else { return nil }
        // Canonical/user-confirmed values win; provider data fills only gaps.
        metadata.platform = metadata.platform ?? provider?.platform
        metadata.releaseDate = metadata.releaseDate ?? provider?.releaseDate
        metadata.releaseYear = metadata.releaseYear ?? provider?.releaseYear
        metadata.developer = metadata.developer ?? provider?.developer
        metadata.publisher = metadata.publisher ?? provider?.publisher
        metadata.genres = unique(metadata.genres + (provider?.genres ?? []))
        metadata.summary = metadata.summary ?? provider?.summary
        metadata.platform = resolvedGamePlatformName(metadata.platform)
        return metadata
    }

    func connectSteamGridDB(apiKey: String) async throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SteamGridDBError.invalidKey }
        try await steamGridDBService.validate(apiKey: trimmed)
        try SteamGridDBKeychain.save(trimmed)
        steamGridDBAPIKey = trimmed
        automaticHeroArtworkFailedIds.removeAll()
        scheduleAutomaticHeroArtworkLookup(reason: "steamgriddb-connected", delay: .seconds(1))
    }

    func disconnectSteamGridDB() {
        SteamGridDBKeychain.delete()
        steamGridDBAPIKey = nil
        automaticHeroArtworkFailedIds.removeAll()
    }

    func refreshActiveSessions(authManager: AuthManager, force: Bool = false) async {
        guard !isRefreshingActiveSessions else { return }
        if !force, let lastActiveSessionsRefresh, Date().timeIntervalSince(lastActiveSessionsRefresh) < 10 {
            return
        }
        isRefreshingActiveSessions = true
        defer {
            isRefreshingActiveSessions = false
            lastActiveSessionsRefresh = Date()
        }
        guard let token = try? await authManager.resolveToken() else { return }
        let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
        let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl
        activeSessions = (try? await cloudMatchClient.getActiveSessions(token: token, base: base)) ?? []
    }

    func activeSessionForLaunch(_ game: GameInfo, authManager: AuthManager) async -> ActiveSessionInfo? {
        guard let token = try? await authManager.resolveToken() else {
            return activeSession(for: game)
        }

        let launchGame = gameWithPreferredStore(game)
        let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
        let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl
        let currentSessions = (try? await cloudMatchClient.getActiveSessions(token: token, base: base)) ?? activeSessions
        activeSessions = currentSessions

        if let matchingSession = currentSessions.first(where: { sessionMatchesGame($0, game: launchGame) }) {
            return matchingSession
        }

        var stoppedSessionIds = Set<String>()
        if !currentSessions.isEmpty {
            catalogLogger.info("[Session] stopping \(currentSessions.count) active provider sessions before launching \(launchGame.title, privacy: .public)")
        }
        for session in currentSessions {
            stoppedSessionIds.insert(session.sessionId)
            try? await cloudMatchClient.stopSession(sessionId: session.sessionId, token: token, base: base)
        }

        if let resumableSession, resumableSession.game.id != launchGame.id {
            stoppedSessionIds.insert(resumableSession.session.sessionId)
            let resumeBase = resumableSession.session.streamingBaseUrl.isEmpty ? base : resumableSession.session.streamingBaseUrl
            try? await cloudMatchClient.stopSession(
                sessionId: resumableSession.session.sessionId,
                token: token,
                base: resumeBase
            )
            self.resumableSession = nil
        }

        if !stoppedSessionIds.isEmpty {
            try? await Task.sleep(for: .milliseconds(700))
            let refreshed = (try? await cloudMatchClient.getActiveSessions(token: token, base: base)) ?? []
            activeSessions = refreshed.filter { !stoppedSessionIds.contains($0.sessionId) }
        }

        return nil
    }

    func prepareForSunshineLaunch(_ game: GameInfo, host: SunshineHost) async {
        let launchGame = gameWithPreferredStore(game)
        catalogLogger.info("[Sunshine] preparing launch for \(launchGame.title, privacy: .public)")
        catalogLogger.info("[Sunshine] deferring Sunshine host cleanup to launch preflight")
    }

    func prepareForGFNLaunch(_ game: GameInfo, authManager: AuthManager) async -> ActiveSessionInfo? {
        await stopActiveSunshineIfNeeded(keeping: nil, host: nil)
        return await activeSessionForLaunch(game, authManager: authManager)
    }

    func markSunshineStreamActive(game: GameInfo, host: SunshineHost) {
        activeSunshineStream = ActiveSunshineStream(game: game, host: host, startedAt: Date())
        recordPlayed(game)
    }

    func clearActiveSunshineStream(for game: GameInfo? = nil) {
        guard let game else {
            activeSunshineStream = nil
            return
        }
        if activeSunshineStream?.game.id == game.id {
            activeSunshineStream = nil
        }
    }

    func stopStream(for game: GameInfo, authManager: AuthManager) async {
        if let active = activeSunshineStream, active.game.id == game.id {
            try? await sunshineClient.cancelRunningApp(host: active.host)
            activeSunshineStream = nil
        }

        guard let token = try? await authManager.resolveToken() else { return }
        let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
        let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl
        let matchingSessions = activeSessions.filter { sessionMatchesGame($0, game: game) }

        for session in matchingSessions {
            try? await cloudMatchClient.stopSession(sessionId: session.sessionId, token: token, base: base)
        }
        let stoppedIds = Set(matchingSessions.map(\.sessionId))
        activeSessions.removeAll { stoppedIds.contains($0.sessionId) }

        if let resumableSession, resumableSession.game.id == game.id {
            let resumeBase = resumableSession.session.streamingBaseUrl.isEmpty
                ? base
                : resumableSession.session.streamingBaseUrl
            try? await cloudMatchClient.stopSession(
                sessionId: resumableSession.session.sessionId,
                token: token,
                base: resumeBase
            )
            self.resumableSession = nil
        }
    }

    private func stopActiveSunshineIfNeeded(keeping game: GameInfo?, host: SunshineHost?) async {
        guard let active = activeSunshineStream else { return }
        if active.isExpired {
            activeSunshineStream = nil
            return
        }
        if let game, let host, active.game.id == game.id, active.host == host {
            return
        }
        try? await sunshineClient.cancelRunningApp(host: active.host)
        activeSunshineStream = nil
    }

    private func stopGFNSessions(except keptSessionId: String?, authManager: AuthManager) async {
        guard let token = try? await authManager.resolveToken() else { return }
        let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
        let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl
        let currentSessions = (try? await cloudMatchClient.getActiveSessions(token: token, base: base)) ?? activeSessions
        if !currentSessions.isEmpty {
            catalogLogger.info("[Session] stopping \(currentSessions.count) GFN sessions before Sunshine launch")
        }
        var stoppedSessionIds = Set<String>()
        for session in currentSessions where session.sessionId != keptSessionId {
            stoppedSessionIds.insert(session.sessionId)
            try? await cloudMatchClient.stopSession(sessionId: session.sessionId, token: token, base: base)
        }
        if let resumableSession, resumableSession.session.sessionId != keptSessionId {
            stoppedSessionIds.insert(resumableSession.session.sessionId)
            let resumeBase = resumableSession.session.streamingBaseUrl.isEmpty ? base : resumableSession.session.streamingBaseUrl
            try? await cloudMatchClient.stopSession(
                sessionId: resumableSession.session.sessionId,
                token: token,
                base: resumeBase
            )
            self.resumableSession = nil
        }
        if !stoppedSessionIds.isEmpty {
            try? await Task.sleep(for: .milliseconds(700))
            let refreshed = (try? await cloudMatchClient.getActiveSessions(token: token, base: base)) ?? []
            activeSessions = refreshed.filter { !stoppedSessionIds.contains($0.sessionId) }
        }
    }

    // MARK: Recently Played

    func recordPlayed(_ game: GameInfo) {
        recentlyPlayedIds.removeAll { $0 == game.id }
        recentlyPlayedIds.insert(game.id, at: 0)
        if recentlyPlayedIds.count > 10 { recentlyPlayedIds = Array(recentlyPlayedIds.prefix(10)) }
        let data = try? JSONEncoder().encode(recentlyPlayedIds)
        UserDefaults.standard.set(data, forKey: "gfn.recentlyPlayed")
        scheduleAutomaticHeroArtworkLookup(seed: game, reason: "played")
    }

    // MARK: Preferred Store

    func setPreferredStore(gameId: String, variantId: String) {
        preferredStoreIds[gameId] = variantId
        let data = try? JSONEncoder().encode(preferredStoreIds)
        UserDefaults.standard.set(data, forKey: "gfn.preferredStores")
    }

    func preferredVariantId(for game: GameInfo) -> String? {
        preferredStoreIds[game.id] ?? game.variants.first?.id
    }

    func gameWithPreferredStore(_ game: GameInfo) -> GameInfo {
        guard let preferredId = preferredStoreIds[game.id],
              let idx = game.variants.firstIndex(where: { $0.id == preferredId }),
              idx != 0 else { return game }
        var g = game
        let preferred = g.variants.remove(at: idx)
        g.variants.insert(preferred, at: 0)
        return g
    }

    private func sessionMatchesGame(_ session: ActiveSessionInfo, game: GameInfo) -> Bool {
        game.variants.contains { variant in
            guard let sessionAppId = session.appId else { return false }
            let variantIds = [variant.appId, variant.id]
            return variantIds.contains(sessionAppId)
        }
    }

    // MARK: Favorites

    func toggleFavorite(_ id: String) {
        if favoriteIds.contains(id) {
            favoriteIds.remove(id)
        } else {
            favoriteIds.insert(id)
        }
        saveFavorites()
    }

    func isFavorite(_ id: String) -> Bool {
        favoriteIds.contains(id)
    }

    // MARK: Hidden Heroes

    var hiddenHeroCount: Int {
        hiddenHeroIds.count
    }

    func hideFromHeroes(_ game: GameInfo) {
        pinnedHeroIds.remove(game.id)
        hiddenHeroIds.insert(game.id)
    }

    func showInHeroes(_ game: GameInfo) {
        hiddenHeroIds.remove(game.id)
        pinnedHeroIds.insert(game.id)
    }

    func isInHeroes(_ game: GameInfo) -> Bool {
        homeSnapshot.heroGames.contains { $0.id == game.id }
    }

    func resetHiddenHeroes() {
        hiddenHeroIds.removeAll()
    }

    // MARK: Sunshine Import

    private func applySunshineImport(_ apps: [SunshineGame], canonicalCandidates: [GameInfo]) {
        sunshinePowerApps = apps.reduce(into: [:]) { result, app in
            guard let action = app.reservedPowerAction, result[action] == nil else { return }
            result[action] = app
        }
        let visibleApps = apps.filter { $0.reservedPowerAction == nil }
        let results = SunshineGameEnricher().importGames(visibleApps, canonicalDatabase: canonicalCandidates)
        sunshineGames = results.map(\.gameInfo)

        let importedCanonicalGames = mergeCanonicalGames(results.map(\.canonicalGame))
        let importedIds = Set(importedCanonicalGames.map(\.id))
        let retainedCanonicalGames = canonicalGames.filter { existing in
            guard existing.launchOptions.contains(where: { $0.providerID == .sunshine }) else {
                return true
            }
            return !importedIds.contains(existing.id)
        }
        canonicalGames = retainedCanonicalGames + importedCanonicalGames

        let reviewCount = importedCanonicalGames.filter(\.needsReview).count
        let selectedCoverMatches = importedCanonicalGames.filter {
            $0.matchSources.contains(.sunshineSelectedCover)
        }.count
        let coverFilenameMatches = importedCanonicalGames.filter {
            $0.matchSources.contains(.sunshineCoverFilename)
        }.count
        let cachedOnlyCovers = visibleApps.filter {
            ($0.imagePath ?? "").isEmpty && ($0.boxArtUrl ?? "").contains("/CloudNow/SunshineAssets/")
        }.count
        let imagePathCount = visibleApps.filter { ($0.imagePath ?? "").isEmpty == false }.count
        let rawArtworkFieldCount = visibleApps.filter { app in
            app.rawFields.keys.contains { key in
                let lower = key.lowercased()
                return lower.contains("image") || lower.contains("cover") || lower.contains("box") || lower.contains("poster") || lower.contains("art")
            }
        }.count
        let sampleRawKeys = visibleApps.first?.rawFields.keys.sorted().joined(separator: ",") ?? "none"
        catalogLogger.info("[Sunshine] enriched apps=\(visibleApps.count) reservedPowerApps=\(self.sunshinePowerApps.count) selectedCoverMatches=\(selectedCoverMatches) coverFilenameMatches=\(coverFilenameMatches) needsReview=\(reviewCount) imagePaths=\(imagePathCount) rawArtworkFields=\(rawArtworkFieldCount) cachedOnlyCovers=\(cachedOnlyCovers)")
        catalogLogger.info("[Sunshine] sample raw app fields: \(sampleRawKeys, privacy: .public)")
    }

    private func mergeCanonicalGames(_ games: [CanonicalGame]) -> [CanonicalGame] {
        var byId: [String: CanonicalGame] = [:]
        var orderedIds: [String] = []
        for game in games {
            if var existing = byId[game.id] {
                existing = mergedCanonicalGame(existing, with: game)
                byId[game.id] = existing
            } else {
                byId[game.id] = game
                orderedIds.append(game.id)
            }
        }
        return orderedIds.compactMap { byId[$0] }
    }

    private func mergedCanonicalGame(_ lhs: CanonicalGame, with rhs: CanonicalGame) -> CanonicalGame {
        var merged = lhs
        merged.title = lhs.title.isEmpty ? rhs.title : lhs.title
        merged.platform = lhs.platform ?? rhs.platform
        merged.releaseDate = lhs.releaseDate ?? rhs.releaseDate
        merged.releaseYear = lhs.releaseYear ?? rhs.releaseYear
        merged.developer = lhs.developer ?? rhs.developer
        merged.publisher = lhs.publisher ?? rhs.publisher
        merged.summary = lhs.summary ?? rhs.summary
        merged.genres = unique(lhs.genres + rhs.genres)
        merged.externalIds.mergeMissing(from: rhs.externalIds)
        merged.providerEntries = uniqueById(lhs.providerEntries + rhs.providerEntries)
        merged.launchOptions = uniqueById(lhs.launchOptions + rhs.launchOptions)
        merged.artwork = uniqueById(lhs.artwork + rhs.artwork)
        merged.matchConfidence = max(lhs.matchConfidence, rhs.matchConfidence)
        merged.matchSources = Array(Set(lhs.matchSources + rhs.matchSources)).sorted { $0.rawValue < $1.rawValue }
        merged.needsReview = lhs.needsReview || rhs.needsReview
        return merged
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func uniqueById<T: Identifiable>(_ values: [T]) -> [T] where T.ID == String {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }

    // MARK: Metadata Lookup

    private func scheduleAutomaticHeroArtworkLookup(
        seed: GameInfo? = nil,
        reason: String,
        delay: Duration = .zero
    ) {
        if let seed {
            automaticHeroArtworkQueuedSeed = seed
            automaticHeroArtworkFailedIds.remove(seed.id)
        } else {
            guard !isAutomaticHeroArtworkPassScheduled else { return }
            isAutomaticHeroArtworkPassScheduled = true
        }
        Task(priority: seed == nil ? .background : .utility) {
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            await resolveAutomaticHeroArtwork(reason: reason, seedOnly: seed != nil)
        }
    }

    private func resolveAutomaticHeroArtwork(reason: String, seedOnly: Bool) async {
        if !seedOnly {
            isAutomaticHeroArtworkPassScheduled = false
        }
        guard !isResolvingAutomaticHeroArtwork else { return }
        isResolvingAutomaticHeroArtwork = true
        let seed = automaticHeroArtworkQueuedSeed
        automaticHeroArtworkQueuedSeed = nil
        defer {
            isResolvingAutomaticHeroArtwork = false
            if let queuedSeed = automaticHeroArtworkQueuedSeed {
                scheduleAutomaticHeroArtworkLookup(seed: queuedSeed, reason: "queued")
            }
        }

        let candidates = automaticHeroArtworkCandidates(seed: seed, seedOnly: seedOnly)
        guard !candidates.isEmpty else { return }

        var resolvedCount = 0
        for game in candidates.prefix(Self.automaticHeroArtworkBatchLimit) {
            let currentGame = game

            if let hero = currentGame.heroBannerUrl, !hero.isEmpty {
                prefetchHeroImage(for: currentGame)
                continue
            }

            guard !automaticHeroArtworkFailedIds.contains(currentGame.id) else { continue }
            if await applyBestAutomaticHeroArtwork(to: currentGame) {
                resolvedCount += 1
            } else {
                automaticHeroArtworkFailedIds.insert(currentGame.id)
            }
        }

        if resolvedCount > 0 {
            catalogLogger.info("[Metadata] automatic hero artwork reason=\(reason, privacy: .public) resolved=\(resolvedCount)")
        }

        if !seedOnly, firstMissingAutomaticHeroCandidate() != nil {
            scheduleAutomaticHeroArtworkLookup(reason: "follow-up", delay: Self.automaticHeroArtworkFollowUpDelay)
        }
    }

    private func automaticHeroArtworkCandidates(seed: GameInfo?, seedOnly: Bool) -> [GameInfo] {
        if let seed {
            let game = allKnownGames.first(where: { gameMatches($0, seed) }) ?? seed
            guard !automaticHeroArtworkFailedIds.contains(game.id) else { return [] }
            return [game]
        }
        guard !seedOnly, let game = firstMissingAutomaticHeroCandidate() else { return [] }
        return [game]
    }

    private func firstMissingAutomaticHeroCandidate() -> GameInfo? {
        let candidates = homeSnapshot.heroGames
            + recentlyPlayedGames
            + continuePlaying
            + favoriteGames
            + Array(localSunshineGames.prefix(6))
            + Array(xcloudNewGames.prefix(6))
            + Array(xcloudPopularGames.prefix(6))
            + Array(homeLibraryGames.prefix(6))
        var seen = Set<String>()
        for game in candidates {
            guard seen.insert(game.id).inserted else { continue }
            guard (game.heroBannerUrl ?? "").isEmpty,
                  !automaticHeroArtworkFailedIds.contains(game.id) else {
                continue
            }
            return game
        }
        return nil
    }

    private func applyBestAutomaticHeroArtwork(to game: GameInfo) async -> Bool {
        let canonical = canonicalGame(for: game)
        do {
            guard let metadata = try await metadataLookupClient.lookup(
                title: game.title,
                igdbId: canonical?.externalIds.igdbId,
                gameDBId: canonical?.externalIds.gameDBId,
                steamAppId: canonical?.externalIds.steamAppId,
                steamGridDBAPIKey: steamGridDBAPIKey
            ),
            let heroURL = metadata.heroArtworkUrl,
            !heroURL.isEmpty else {
                catalogLogger.info("[Metadata] automatic hero not found title=\(game.title, privacy: .public)")
                return false
            }

            let candidate = GameMetadataArtworkCandidate(
                id: "\(game.id):auto-\(metadata.source.rawValue)",
                title: metadata.title ?? game.title,
                subtitle: "\(metadata.source.rawValue) hero",
                source: metadata.source,
                role: .heroBackground,
                url: heroURL,
                metadata: metadata
            )
            applyHeroArtworkCandidate(candidate, to: game, userSelected: false)
            catalogLogger.info("[Metadata] automatic hero applied title=\(game.title, privacy: .public) source=\(metadata.source.rawValue, privacy: .public)")
            return true
        } catch {
            catalogLogger.info("[Metadata] automatic hero failed title=\(game.title, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func applyHeroArtworkCandidate(
        _ candidate: GameMetadataArtworkCandidate,
        to game: GameInfo,
        userSelected: Bool
    ) {
        let metadata = candidate.metadata
        let matchSource = userSelected ? "userConfirmed" : candidate.source.rawValue
        let clearsReview = userSelected || metadata.externalIds.hasProviderIdentity
        let updatedGame = gameWithHero(
            game,
            heroURL: candidate.url,
            metadata: metadata,
            matchSource: matchSource,
            clearsReview: clearsReview
        )
        mainGames = mainGames.map {
            gameMatches($0, game)
                ? gameWithHero($0, heroURL: candidate.url, metadata: metadata, matchSource: matchSource, clearsReview: clearsReview)
                : $0
        }
        libraryGames = libraryGames.map {
            gameMatches($0, game)
                ? gameWithHero($0, heroURL: candidate.url, metadata: metadata, matchSource: matchSource, clearsReview: clearsReview)
                : $0
        }
        publicCatalogGames = publicCatalogGames.map {
            gameMatches($0, game)
                ? gameWithHero($0, heroURL: candidate.url, metadata: metadata, matchSource: matchSource, clearsReview: clearsReview)
                : $0
        }
        sunshineGames = sunshineGames.map {
            gameMatches($0, game)
                ? gameWithHero($0, heroURL: candidate.url, metadata: metadata, matchSource: matchSource, clearsReview: clearsReview)
                : $0
        }
        xcloudGames = xcloudGames.map {
            gameMatches($0, game)
                ? gameWithHero($0, heroURL: candidate.url, metadata: metadata, matchSource: matchSource, clearsReview: clearsReview)
                : $0
        }
        xcloudNewGames = xcloudNewGames.map {
            gameMatches($0, game)
                ? gameWithHero($0, heroURL: candidate.url, metadata: metadata, matchSource: matchSource, clearsReview: clearsReview)
                : $0
        }
        xcloudPopularGames = xcloudPopularGames.map {
            gameMatches($0, game)
                ? gameWithHero($0, heroURL: candidate.url, metadata: metadata, matchSource: matchSource, clearsReview: clearsReview)
                : $0
        }

        if activeSunshineStream?.game.id == game.id, let activeSunshineStream {
            self.activeSunshineStream = ActiveSunshineStream(
                game: updatedGame,
                host: activeSunshineStream.host,
                startedAt: activeSunshineStream.startedAt
            )
        }
        if resumableSession?.game.id == game.id, let resumableSession {
            self.resumableSession = ResumableSession(
                game: updatedGame,
                session: resumableSession.session,
                leftAt: resumableSession.leftAt
            )
        }

        canonicalGames = canonicalGames.map { canonical in
            guard canonicalMatches(canonical, game: game) else { return canonical }
            var updated = canonical
            updated.title = updated.title.isEmpty ? (metadata.title ?? updated.title) : updated.title
            updated.releaseDate = updated.releaseDate ?? metadata.releaseDate
            updated.releaseYear = updated.releaseYear ?? metadata.releaseYear
            updated.developer = updated.developer ?? metadata.developer
            updated.publisher = updated.publisher ?? metadata.publisher
            updated.summary = updated.summary ?? metadata.summary
            updated.genres = unique(updated.genres + metadata.genres)
            updated.externalIds.mergeMissing(from: metadata.externalIds)
            if userSelected {
                updated.matchSources = Array(Set(updated.matchSources + [.userConfirmed])).sorted { $0.rawValue < $1.rawValue }
            }
            updated.needsReview = clearsReview ? false : updated.needsReview
            updated.artwork = updated.artwork.map { asset in
                var copy = asset
                if copy.role == .heroBackground {
                    copy.isPreferred = false
                }
                return copy
            }
            if !updated.artwork.contains(where: { $0.role == .heroBackground && $0.url == candidate.url }) {
                updated.artwork.append(
                    ArtworkAsset(
                        id: "\(updated.id):\(userSelected ? "user" : "auto")-hero:\(candidate.id)",
                        role: .heroBackground,
                        source: candidate.source,
                        url: candidate.url,
                        isUserSelected: userSelected,
                        isPreferred: true
                    )
                )
            }
            return updated
        }

        saveUserGameCustomization(
            for: game,
            heroURL: candidate.url,
            metadata: metadata,
            userSelected: userSelected
        )

        automaticHeroArtworkFailedIds.remove(updatedGame.id)
        prefetchHeroImage(for: updatedGame)
        saveCachedGamesSnapshot()
    }

    private func prefetchHeroImage(for game: GameInfo) {
        guard let url = displayHeroURL(for: game) else { return }
        RemoteImagePrefetcher.prefetch([url])
    }

    private func prefetchHeroImages(_ urls: [String?]) {
        RemoteImagePrefetcher.prefetch(urls.compactMap { raw in
            guard let raw, !raw.isEmpty else { return nil }
            return displayHeroURL(raw)
        })
    }

    private func displayHeroURL(for game: GameInfo) -> URL? {
        guard let raw = game.heroBannerUrl, !raw.isEmpty else { return nil }
        return displayHeroURL(raw)
    }

    private func displayHeroURL(_ value: String) -> URL? {
        var raw = value
        guard raw.contains("img.nvidiagrid.net") else { return URL(string: raw) }
        if let range = raw.range(of: ";w=") {
            raw = String(raw[..<range.lowerBound])
        }
        return URL(string: "\(raw);w=1600")
    }

    private func lookupMissingGameMetadata() async -> Int {
        let candidates = metadataLookupCandidates()
        var metadataByGameId: [String: GameMetadataLookupResult] = [:]

        for candidate in candidates.prefix(50) {
            let igdbId = candidate.canonicalGame?.externalIds.igdbId
            let gameDBId = candidate.canonicalGame?.externalIds.gameDBId
            let steamAppId = candidate.canonicalGame?.externalIds.steamAppId
            do {
                guard let metadata = try await metadataLookupClient.lookup(
                    title: candidate.game.title,
                    igdbId: igdbId,
                    gameDBId: gameDBId,
                    steamAppId: steamAppId,
                    steamGridDBAPIKey: steamGridDBAPIKey
                ) else {
                    continue
                }
                metadataByGameId[candidate.game.id] = metadata
                applyMetadataResults([candidate.game.id: metadata])
                if let heroURL = metadata.heroArtworkUrl, !heroURL.isEmpty {
                    saveUserGameCustomization(
                        for: candidate.game,
                        heroURL: heroURL,
                        metadata: metadata,
                        userSelected: false
                    )
                    prefetchHeroImages([heroURL])
                }
                saveCachedGamesSnapshot()
                catalogLogger.info("[Metadata] matched title=\(candidate.game.title, privacy: .public) source=\(metadata.source.rawValue, privacy: .public) igdb=\(metadata.externalIds.igdbId ?? "nil", privacy: .public) gameDB=\(metadata.externalIds.gameDBId ?? "nil", privacy: .public) hero=\((metadata.heroArtworkUrl ?? "").isEmpty ? "no" : "yes", privacy: .public)")
            } catch {
                catalogLogger.info("[Metadata] lookup failed title=\(candidate.game.title, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }

        guard !metadataByGameId.isEmpty else { return 0 }
        let heroCount = metadataByGameId.values.filter { ($0.heroArtworkUrl ?? "").isEmpty == false }.count
        let gameDBCount = metadataByGameId.values.filter { $0.source == .gameDB }.count
        let steamGridDBCount = metadataByGameId.values.filter { $0.source == .steamGridDB }.count
        catalogLogger.info("[Metadata] lookup complete candidates=\(candidates.count) matches=\(metadataByGameId.count) gameDB=\(gameDBCount) steamGridDB=\(steamGridDBCount) heroes=\(heroCount)")
        return heroCount
    }

    private func metadataLookupCandidates() -> [(game: GameInfo, canonicalGame: CanonicalGame?)] {
        var seen = Set<String>()
        return allKnownGames.compactMap { game in
            guard seen.insert(game.id).inserted else { return nil }
            let canonical = canonicalGame(for: game)
            let missingHero = (game.heroBannerUrl ?? "").isEmpty
            let hasIGDBIdentity = canonical?.externalIds.igdbId != nil
            let hasGameDBIdentity = canonical?.externalIds.gameDBId != nil
            guard missingHero || game.needsReview || hasIGDBIdentity || hasGameDBIdentity else { return nil }
            return (game, canonical)
        }
    }

    private func canonicalGame(for game: GameInfo) -> CanonicalGame? {
        if let canonicalId = game.canonicalId,
           let canonical = canonicalGames.first(where: { $0.id == canonicalId }) {
            return canonical
        }
        return canonicalGames.first { canonical in
            canonical.providerEntries.contains { entry in
                game.variants.contains { variant in
                    entry.providerID == .sunshine && entry.providerGameID == variant.appId
                }
            }
        }
    }

    private func applyMetadataResults(_ metadataByGameId: [String: GameMetadataLookupResult]) {
        mainGames = mainGames.map { applyingMetadata(to: $0, metadataByGameId: metadataByGameId) }
        libraryGames = libraryGames.map { applyingMetadata(to: $0, metadataByGameId: metadataByGameId) }
        publicCatalogGames = publicCatalogGames.map { applyingMetadata(to: $0, metadataByGameId: metadataByGameId) }
        sunshineGames = sunshineGames.map { applyingMetadata(to: $0, metadataByGameId: metadataByGameId) }
        xcloudGames = xcloudGames.map { applyingMetadata(to: $0, metadataByGameId: metadataByGameId) }
        xcloudNewGames = xcloudNewGames.map { applyingMetadata(to: $0, metadataByGameId: metadataByGameId) }
        xcloudPopularGames = xcloudPopularGames.map { applyingMetadata(to: $0, metadataByGameId: metadataByGameId) }
        canonicalGames = canonicalGames.map { canonical in
            var updated = canonical
            let matchingMetadata = metadataByGameId.first { gameId, _ in
                allKnownGames.first { $0.id == gameId }.flatMap { canonicalGame(for: $0)?.id } == canonical.id
            }?.value
            guard let metadata = matchingMetadata else { return canonical }
            updated.title = updated.title.isEmpty ? (metadata.title ?? updated.title) : updated.title
            updated.releaseDate = updated.releaseDate ?? metadata.releaseDate
            updated.releaseYear = updated.releaseYear ?? metadata.releaseYear
            updated.developer = updated.developer ?? metadata.developer
            updated.publisher = updated.publisher ?? metadata.publisher
            updated.summary = updated.summary ?? metadata.summary
            updated.genres = unique(updated.genres + metadata.genres)
            updated.externalIds.mergeMissing(from: metadata.externalIds)
            if metadata.externalIds.gameDBId != nil, !updated.matchSources.contains(.gameDBId) {
                updated.matchSources.append(.gameDBId)
            }
            if metadata.externalIds.igdbId != nil, !updated.matchSources.contains(.igdbId) {
                updated.matchSources.append(.igdbId)
            }
            updated.needsReview = updated.needsReview && !metadata.externalIds.hasProviderIdentity
            if let hero = metadata.heroArtworkUrl,
               !updated.artwork.contains(where: { $0.role == .heroBackground && $0.url == hero }) {
                updated.artwork.append(
                    ArtworkAsset(
                        id: "\(updated.id):\(metadata.source.rawValue)-hero",
                        role: .heroBackground,
                        source: metadata.source,
                        url: hero,
                        isUserSelected: false,
                        isPreferred: true
                    )
                )
            }
            return updated
        }
    }

    private func applyingMetadata(
        to game: GameInfo,
        metadataByGameId: [String: GameMetadataLookupResult]
    ) -> GameInfo {
        guard let metadata = metadataByGameId[game.id] else { return game }
        return GameInfo(
            id: game.id,
            title: game.title,
            boxArtUrl: game.boxArtUrl,
            heroBannerUrl: game.heroBannerUrl ?? metadata.heroArtworkUrl,
            isInLibrary: game.isInLibrary,
            variants: game.variants,
            canonicalId: game.canonicalId,
            matchConfidence: max(game.matchConfidence ?? 0, metadata.externalIds.hasProviderIdentity ? 0.96 : 0),
            matchSource: [game.matchSource, metadataMatchSource(metadata)]
                .compactMap { $0 }
                .joined(separator: ","),
            needsReview: game.needsReview && !metadata.externalIds.hasProviderIdentity,
            providerMetadata: game.providerMetadata
        )
    }

    private func metadataMatchSource(_ metadata: GameMetadataLookupResult) -> String {
        switch metadata.source {
        case .gameDB:
            return metadata.externalIds.gameDBId == nil ? "igdbId" : "gameDBId"
        case .steamGridDB, .providerMetadata, .sunshineSelectedCover, .geforceNow, .igdb, .fallback:
            return metadata.source.rawValue
        }
    }

    private func currentArtworkCandidates(for game: GameInfo, canonical: CanonicalGame?) -> [GameMetadataArtworkCandidate] {
        let metadata = GameMetadataLookupResult(
            source: .providerMetadata,
            title: game.title,
            releaseDate: canonical?.releaseDate,
            releaseYear: canonical?.releaseYear,
            developer: canonical?.developer,
            publisher: canonical?.publisher,
            genres: canonical?.genres ?? [],
            summary: canonical?.summary,
            externalIds: canonical?.externalIds ?? ExternalGameIds(),
            heroArtworkUrl: game.heroBannerUrl,
            screenshotUrl: nil
        )

        var candidates: [GameMetadataArtworkCandidate] = []
        if let hero = game.heroBannerUrl, !hero.isEmpty {
            candidates.append(
                GameMetadataArtworkCandidate(
                    id: "\(game.id):current-hero",
                    title: game.title,
                    subtitle: "Current hero",
                    source: .providerMetadata,
                    role: .heroBackground,
                    url: hero,
                    metadata: metadata
                )
            )
        }
        if let cover = game.boxArtUrl, !cover.isEmpty {
            candidates.append(
                GameMetadataArtworkCandidate(
                    id: "\(game.id):cover-fallback",
                    title: game.title,
                    subtitle: game.isSunshineGame ? "Sunshine cover fallback" : "Cover fallback",
                    source: game.isSunshineGame ? .sunshineSelectedCover : .fallback,
                    role: .tileCover,
                    url: cover,
                    metadata: metadata
                )
            )
        }
        return candidates
    }

    private func currentCoverArtworkCandidate(for game: GameInfo, canonical: CanonicalGame?) -> GameMetadataArtworkCandidate? {
        guard let cover = game.boxArtUrl, !cover.isEmpty else { return nil }
        let metadata = GameMetadataLookupResult(
            source: .providerMetadata,
            title: game.title,
            releaseDate: canonical?.releaseDate,
            releaseYear: canonical?.releaseYear,
            developer: canonical?.developer,
            publisher: canonical?.publisher,
            genres: canonical?.genres ?? [],
            summary: canonical?.summary,
            externalIds: canonical?.externalIds ?? ExternalGameIds(),
            heroArtworkUrl: game.heroBannerUrl,
            screenshotUrl: nil
        )
        return GameMetadataArtworkCandidate(
            id: "\(game.id):current-cover",
            title: game.title,
            subtitle: "Current cover",
            source: game.isSunshineGame ? .sunshineSelectedCover : .providerMetadata,
            role: .tileCover,
            url: cover,
            metadata: metadata
        )
    }

    private func uniqueArtworkCandidates(_ candidates: [GameMetadataArtworkCandidate]) -> [GameMetadataArtworkCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.url).inserted }
    }

    private func gameWithHero(
        _ game: GameInfo,
        heroURL: String,
        metadata: GameMetadataLookupResult,
        matchSource: String = "userConfirmed",
        clearsReview: Bool = true
    ) -> GameInfo {
        GameInfo(
            id: game.id,
            title: game.title.isEmpty ? (metadata.title ?? game.title) : game.title,
            boxArtUrl: game.boxArtUrl,
            heroBannerUrl: heroURL,
            isInLibrary: game.isInLibrary,
            variants: game.variants,
            canonicalId: game.canonicalId,
            matchConfidence: max(game.matchConfidence ?? 0, metadata.externalIds.hasProviderIdentity ? 0.96 : 0),
            matchSource: combinedMatchSource(game.matchSource, matchSource),
            needsReview: clearsReview ? false : game.needsReview,
            providerMetadata: game.providerMetadata
        )
    }

    private func gameWithCover(
        _ game: GameInfo,
        coverURL: String,
        metadata: GameMetadataLookupResult
    ) -> GameInfo {
        GameInfo(
            id: game.id,
            title: game.title.isEmpty ? (metadata.title ?? game.title) : game.title,
            boxArtUrl: coverURL,
            heroBannerUrl: game.heroBannerUrl,
            isInLibrary: game.isInLibrary,
            variants: game.variants,
            canonicalId: game.canonicalId,
            matchConfidence: max(game.matchConfidence ?? 0, metadata.externalIds.hasProviderIdentity ? 0.96 : 0),
            matchSource: combinedMatchSource(game.matchSource, "userConfirmed"),
            needsReview: false,
            providerMetadata: game.providerMetadata
        )
    }

    private func gameWithMetadata(
        _ game: GameInfo,
        title: String,
        metadata: GameMetadataLookupResult
    ) -> GameInfo {
        GameInfo(
            id: game.id,
            title: title,
            boxArtUrl: game.boxArtUrl ?? metadata.coverArtworkUrl,
            heroBannerUrl: game.heroBannerUrl ?? metadata.heroArtworkUrl,
            isInLibrary: game.isInLibrary,
            variants: game.variants,
            canonicalId: game.canonicalId,
            matchConfidence: max(game.matchConfidence ?? 0, metadata.externalIds.hasProviderIdentity ? 0.96 : 0),
            matchSource: combinedMatchSource(game.matchSource, "userConfirmed"),
            needsReview: false,
            providerMetadata: game.providerMetadata
        )
    }

    private func gameMatches(_ lhs: GameInfo, _ rhs: GameInfo) -> Bool {
        if lhs.id == rhs.id { return true }
        if let lhsCanonical = lhs.canonicalId,
           let rhsCanonical = rhs.canonicalId,
           lhsCanonical == rhsCanonical {
            return true
        }
        let lhsVariantIds = Set(lhs.variants.compactMap(\.appId) + lhs.variants.map(\.id))
        let rhsVariantIds = Set(rhs.variants.compactMap(\.appId) + rhs.variants.map(\.id))
        return lhsVariantIds.isDisjoint(with: rhsVariantIds) == false
    }

    private func canonicalMatches(_ canonical: CanonicalGame, game: GameInfo) -> Bool {
        if canonical.id == game.canonicalId {
            return true
        }
        return canonical.providerEntries.contains { entry in
            game.variants.contains { variant in
                entry.providerGameID == variant.appId || entry.providerGameID == variant.id
            }
        }
    }

    // MARK: Persistence

    func saveFavorites() {
        let data = try? JSONEncoder().encode(Array(favoriteIds))
        UserDefaults.standard.set(data, forKey: "gfn.favoriteIds")
    }

    func saveSettings() {
        let data = try? JSONEncoder().encode(streamSettings)
        UserDefaults.standard.set(data, forKey: "gfn.streamSettings")
    }

    private func saveHiddenHeroIds() {
        let data = try? JSONEncoder().encode(Array(hiddenHeroIds))
        UserDefaults.standard.set(data, forKey: "home.hiddenHeroIds")
    }

    private func savePinnedHeroIds() {
        let data = try? JSONEncoder().encode(Array(pinnedHeroIds))
        UserDefaults.standard.set(data, forKey: "home.pinnedHeroIds")
    }

    private func loadCachedGamesSnapshot() {
        for url in Self.gamesCacheURLs {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(GamesCacheSnapshot.self, from: data) else {
                continue
            }
            mainGames = snapshot.mainGames
            libraryGames = snapshot.libraryGames
            publicCatalogGames = snapshot.publicCatalogGames
            sunshineGames = (snapshot.sunshineGames ?? []).filter { !$0.isReservedSunshinePowerApp }
            xcloudGames = snapshot.xcloudGames ?? []
            xcloudNewGames = snapshot.xcloudNewGames ?? []
            xcloudPopularGames = snapshot.xcloudPopularGames ?? []
            canonicalGames = snapshot.canonicalGames ?? []
            catalogLogger.info("[Catalog] loaded cached snapshot main=\(snapshot.mainGames.count) library=\(snapshot.libraryGames.count) age=\(Int(Date().timeIntervalSince(snapshot.savedAt)))s path=\(url.path, privacy: .public)")
            if url != Self.gamesCacheURL {
                saveCachedGamesSnapshot()
            }
            return
        }
    }

    private func saveCachedGamesSnapshot() {
        let snapshot = GamesCacheSnapshot(
            savedAt: Date(),
            mainGames: mainGames,
            libraryGames: libraryGames,
            publicCatalogGames: publicCatalogGames,
            sunshineGames: sunshineGames,
            xcloudGames: xcloudGames,
            xcloudNewGames: xcloudNewGames,
            xcloudPopularGames: xcloudPopularGames,
            canonicalGames: canonicalGames
        )
        do {
            let data = try JSONEncoder().encode(snapshot)
            let url = try Self.writableGamesCacheURL()
            try data.write(to: url, options: [.atomic])
            catalogLogger.info("[Catalog] saved cached snapshot path=\(url.path, privacy: .public)")
        } catch {
            catalogLogger.error("[Catalog] failed to save cached snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func ensureDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static var gamesCacheURL: URL {
        persistentCloudNowDirectory
            .appendingPathComponent("games-cache-v2.json", isDirectory: false)
    }

    private static var gamesCacheURLs: [URL] {
        var urls = cloudNowStorageDirectories.map {
            $0.appendingPathComponent("games-cache-v2.json", isDirectory: false)
        }
        urls.append(gamesCacheURL)
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    private static var persistentCloudNowDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CloudNow", isDirectory: true)
    }

    private static var cloudNowStorageDirectories: [URL] {
        let bases = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            FileManager.default.temporaryDirectory
        ].compactMap { $0 }

        var seen = Set<String>()
        return bases.compactMap { base in
            let url = base.appendingPathComponent("CloudNow", isDirectory: true)
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    private static func writableGamesCacheURL() throws -> URL {
        var lastError: Error?
        for directory in cloudNowStorageDirectories {
            do {
                try ensureDirectory(directory)
                return directory.appendingPathComponent("games-cache-v2.json", isDirectory: false)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CocoaError(.fileWriteNoPermission)
    }

    private static var userGameCustomizationsURLs: [URL] {
        cloudNowStorageDirectories.map {
            $0
                .appendingPathComponent("user-game-customizations-v1.json", isDirectory: false)
        }
    }

    private static func writableUserGameCustomizationsURL() throws -> URL {
        var lastError: Error?
        for url in userGameCustomizationsURLs {
            do {
                try ensureDirectory(url.deletingLastPathComponent())
                return url
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CocoaError(.fileWriteNoPermission)
    }

    private func loadUserGameCustomizations() {
        for url in Self.userGameCustomizationsURLs {
            if let data = try? Data(contentsOf: url),
               let customizations = try? JSONDecoder().decode([UserGameCustomization].self, from: data) {
                userGameCustomizations = customizations
                return
            }
        }
        migrateUserGameCustomizationsFromCache()
    }

    private func saveUserGameCustomization(
        for game: GameInfo,
        heroURL: String,
        metadata: GameMetadataLookupResult,
        userSelected: Bool = true
    ) {
        let customization = UserGameCustomization(
            gameIds: [game.id],
            canonicalId: game.canonicalId,
            variantIds: Set(game.variants.flatMap { [$0.id, $0.appId].compactMap { $0 } }),
            normalizedTitle: normalizedCatalogTitle(game.title),
            heroURL: heroURL,
            metadata: mergedCustomizationMetadata(metadata, preserving: userGameCustomizations.first(where: { customizationMatches($0, game: game) })?.metadata),
            isUserSelected: userSelected
        )
        if let index = userGameCustomizations.firstIndex(where: { customizationMatches($0, game: game) }) {
            var merged = customization
            merged.gameIds.formUnion(userGameCustomizations[index].gameIds)
            merged.variantIds.formUnion(userGameCustomizations[index].variantIds)
            merged.canonicalId = merged.canonicalId ?? userGameCustomizations[index].canonicalId
            merged.displayTitle = userGameCustomizations[index].displayTitle
            merged.coverURL = userGameCustomizations[index].coverURL
            userGameCustomizations[index] = merged
        } else {
            userGameCustomizations.append(customization)
        }
        persistUserGameCustomizations()
    }

    private func saveUserCoverCustomization(
        for game: GameInfo,
        coverURL: String,
        metadata: GameMetadataLookupResult
    ) {
        let existingIndex = userGameCustomizations.firstIndex(where: { customizationMatches($0, game: game) })
        let existing = existingIndex.map { userGameCustomizations[$0] }
        let customization = UserGameCustomization(
            gameIds: (existing?.gameIds ?? []).union([game.id]),
            canonicalId: game.canonicalId ?? existing?.canonicalId,
            variantIds: (existing?.variantIds ?? []).union(game.variants.flatMap { [$0.id, $0.appId].compactMap { $0 } }),
            normalizedTitle: normalizedCatalogTitle(game.title),
            displayTitle: existing?.displayTitle,
            heroURL: existing?.heroURL ?? game.heroBannerUrl ?? "",
            coverURL: coverURL,
            metadata: mergedCustomizationMetadata(metadata, preserving: existing?.metadata),
            isUserSelected: true
        )
        if let existingIndex {
            userGameCustomizations[existingIndex] = customization
        } else {
            userGameCustomizations.append(customization)
        }
        persistUserGameCustomizations()
    }

    private func saveUserMetadataCustomization(
        for game: GameInfo,
        displayTitle: String,
        metadata: GameMetadataLookupResult
    ) {
        let existingIndex = userGameCustomizations.firstIndex(where: { customizationMatches($0, game: game) })
        let existing = existingIndex.map { userGameCustomizations[$0] }
        let customization = UserGameCustomization(
            gameIds: (existing?.gameIds ?? []).union([game.id]),
            canonicalId: game.canonicalId ?? existing?.canonicalId,
            variantIds: (existing?.variantIds ?? []).union(game.variants.flatMap { [$0.id, $0.appId].compactMap { $0 } }),
            normalizedTitle: normalizedCatalogTitle(game.title),
            displayTitle: displayTitle,
            heroURL: existing?.heroURL ?? game.heroBannerUrl ?? metadata.heroArtworkUrl ?? "",
            coverURL: existing?.coverURL ?? game.boxArtUrl ?? metadata.coverArtworkUrl,
            metadata: mergedCustomizationMetadata(metadata, preserving: existing?.metadata),
            isUserSelected: true
        )
        if let existingIndex {
            userGameCustomizations[existingIndex] = customization
        } else {
            userGameCustomizations.append(customization)
        }
        persistUserGameCustomizations()
    }

    private func mergedCustomizationMetadata(
        _ preferred: GameMetadataLookupResult,
        preserving existing: GameMetadataLookupResult?
    ) -> GameMetadataLookupResult {
        guard let existing else { return preferred }
        var merged = preferred
        merged.title = merged.title ?? existing.title
        merged.platform = resolvedGamePlatformName(merged.platform)
            ?? resolvedGamePlatformName(existing.platform)
        merged.releaseDate = merged.releaseDate ?? existing.releaseDate
        merged.releaseYear = merged.releaseYear ?? existing.releaseYear
        merged.developer = merged.developer ?? existing.developer
        merged.publisher = merged.publisher ?? existing.publisher
        if merged.genres.isEmpty { merged.genres = existing.genres }
        merged.summary = merged.summary ?? existing.summary
        merged.externalIds.mergeMissing(from: existing.externalIds)
        merged.heroArtworkUrl = merged.heroArtworkUrl ?? existing.heroArtworkUrl
        merged.coverArtworkUrl = merged.coverArtworkUrl ?? existing.coverArtworkUrl
        merged.screenshotUrl = merged.screenshotUrl ?? existing.screenshotUrl
        return merged
    }

    private func persistUserGameCustomizations() {
        do {
            let data = try JSONEncoder().encode(userGameCustomizations)
            let url = try Self.writableUserGameCustomizationsURL()
            try data.write(to: url, options: [.atomic])
        } catch {
            catalogLogger.error("[Metadata] failed to save user customizations: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyUserGameCustomizations() {
        guard !userGameCustomizations.isEmpty else { return }
        func customized(_ game: GameInfo) -> GameInfo {
            guard let customization = userGameCustomizations.last(where: { customizationMatches($0, game: game) }) else {
                return game
            }
            var updated = game
            if let displayTitle = customization.displayTitle, !displayTitle.isEmpty {
                updated = gameWithMetadata(updated, title: displayTitle, metadata: customization.metadata)
            }
            if !customization.heroURL.isEmpty {
                updated = gameWithHero(
                    updated,
                    heroURL: customization.heroURL,
                    metadata: customization.metadata,
                    matchSource: customization.isUserSelected ? "userConfirmed" : customization.metadata.source.rawValue,
                    clearsReview: customization.isUserSelected || customization.metadata.externalIds.hasProviderIdentity
                )
            }
            if let coverURL = customization.coverURL, !coverURL.isEmpty {
                updated = gameWithCover(updated, coverURL: coverURL, metadata: customization.metadata)
            }
            return updated
        }
        mainGames = mainGames.map(customized)
        libraryGames = libraryGames.map(customized)
        publicCatalogGames = publicCatalogGames.map(customized)
        sunshineGames = sunshineGames.map(customized)
        xcloudGames = xcloudGames.map(customized)
        xcloudNewGames = xcloudNewGames.map(customized)
        xcloudPopularGames = xcloudPopularGames.map(customized)

        canonicalGames = canonicalGames.map { canonical in
            guard let customization = userGameCustomizations.last(where: { customizationMatches($0, canonical: canonical) }) else {
                return canonical
            }
            return applyingUserCustomization(customization, to: canonical)
        }
    }

    private func customizationMatches(_ customization: UserGameCustomization, game: GameInfo) -> Bool {
        if customization.gameIds.contains(game.id) { return true }
        if let canonicalId = game.canonicalId,
           customization.canonicalId == canonicalId { return true }
        let variantIds = Set(game.variants.flatMap { [$0.id, $0.appId].compactMap { $0 } })
        if !customization.variantIds.isDisjoint(with: variantIds) { return true }
        return customization.normalizedTitle == normalizedCatalogTitle(game.title)
    }

    private func customizationMatches(_ customization: UserGameCustomization, canonical: CanonicalGame) -> Bool {
        if customization.canonicalId == canonical.id { return true }
        let providerIds = Set(canonical.providerEntries.map(\.providerGameID))
        if !customization.variantIds.isDisjoint(with: providerIds) { return true }
        return customization.normalizedTitle == normalizedCatalogTitle(canonical.title)
    }

    private func applyingUserCustomization(
        _ customization: UserGameCustomization,
        to canonical: CanonicalGame
    ) -> CanonicalGame {
        var updated = canonical
        let metadata = customization.metadata
        updated.title = customization.displayTitle ?? (updated.title.isEmpty ? (metadata.title ?? updated.title) : updated.title)
        updated.platform = resolvedGamePlatformName(metadata.platform)
            ?? resolvedGamePlatformName(updated.platform)
        updated.releaseDate = updated.releaseDate ?? metadata.releaseDate
        updated.releaseYear = updated.releaseYear ?? metadata.releaseYear
        updated.developer = updated.developer ?? metadata.developer
        updated.publisher = updated.publisher ?? metadata.publisher
        updated.summary = updated.summary ?? metadata.summary
        updated.genres = unique(updated.genres + metadata.genres)
        updated.externalIds.mergeMissing(from: metadata.externalIds)
        if customization.isUserSelected {
            updated.matchSources = Array(Set(updated.matchSources + [.userConfirmed])).sorted { $0.rawValue < $1.rawValue }
        }
        if customization.isUserSelected || metadata.externalIds.hasProviderIdentity {
            updated.needsReview = false
        }
        if !customization.heroURL.isEmpty {
            updated.artwork = updated.artwork.map { asset in
                var copy = asset
                if copy.role == .heroBackground { copy.isPreferred = false }
                return copy
            }
        }
        if !customization.heroURL.isEmpty,
           !updated.artwork.contains(where: { $0.role == .heroBackground && $0.url == customization.heroURL }) {
            updated.artwork.append(ArtworkAsset(
                id: "\(updated.id):\(customization.isUserSelected ? "user" : "auto")-hero:\(customization.heroURL.hashValue)",
                role: .heroBackground,
                source: metadata.source,
                url: customization.heroURL,
                isUserSelected: customization.isUserSelected,
                isPreferred: true
            ))
        }
        if let coverURL = customization.coverURL, !coverURL.isEmpty {
            updated.artwork = updated.artwork.map { asset in
                var copy = asset
                if copy.role == .tileCover { copy.isPreferred = false }
                return copy
            }
            if !updated.artwork.contains(where: { $0.role == .tileCover && $0.url == coverURL }) {
                updated.artwork.append(ArtworkAsset(
                    id: "\(updated.id):user-cover:\(coverURL.hashValue)",
                    role: .tileCover,
                    source: metadata.source,
                    url: coverURL,
                    isUserSelected: true,
                    isPreferred: true
                ))
            }
        }
        return updated
    }

    private func migrateUserGameCustomizationsFromCache() {
        for canonical in canonicalGames {
            guard let artwork = canonical.artwork.first(where: { $0.role == .heroBackground && $0.isUserSelected }) else {
                continue
            }
            let matchingGame = (mainGames + libraryGames + publicCatalogGames + sunshineGames).first {
                $0.canonicalId == canonical.id || normalizedCatalogTitle($0.title) == normalizedCatalogTitle(canonical.title)
            }
            let metadata = GameMetadataLookupResult(
                source: artwork.source,
                title: canonical.title,
                releaseDate: canonical.releaseDate,
                releaseYear: canonical.releaseYear,
                developer: canonical.developer,
                publisher: canonical.publisher,
                genres: canonical.genres,
                summary: canonical.summary,
                externalIds: canonical.externalIds,
                heroArtworkUrl: artwork.url,
                screenshotUrl: nil
            )
            let gameIds = Set([matchingGame?.id].compactMap { $0 })
            let variantIds = Set(matchingGame?.variants.flatMap { [$0.id, $0.appId].compactMap { $0 } } ?? [])
            userGameCustomizations.append(UserGameCustomization(
                gameIds: gameIds,
                canonicalId: canonical.id,
                variantIds: variantIds,
                normalizedTitle: normalizedCatalogTitle(canonical.title),
                heroURL: artwork.url,
                metadata: metadata,
                isUserSelected: true
            ))
        }
        if !userGameCustomizations.isEmpty { persistUserGameCustomizations() }
    }

    private func saveResumableSession() {
        guard let resumableSession,
              !resumableSession.isExpired,
              !resumableSession.session.isEmptyPlaceholder,
              resumableSession.session.hasValidResumeEndpoint else {
            UserDefaults.standard.removeObject(forKey: "gfn.resumableSession")
            return
        }
        let data = try? JSONEncoder().encode(resumableSession)
        UserDefaults.standard.set(data, forKey: "gfn.resumableSession")
    }

    private func saveActiveSunshineStream() {
        guard let activeSunshineStream else {
            UserDefaults.standard.removeObject(forKey: "sunshine.activeStream")
            return
        }
        let data = try? JSONEncoder().encode(activeSunshineStream)
        UserDefaults.standard.set(data, forKey: "sunshine.activeStream")
    }

    private func mergeGames(primary: [GameInfo], secondary: [GameInfo]) -> [GameInfo] {
        var gamesById: [String: GameInfo] = [:]
        var idByNormalizedTitle: [String: String] = [:]
        var orderedIds: [String] = []

        for game in primary + secondary {
            let normalizedTitle = normalizedCatalogTitle(game.title)
            let mergeId = gamesById[game.id] != nil ? game.id : (idByNormalizedTitle[normalizedTitle] ?? game.id)
            if let existing = gamesById[mergeId] {
                gamesById[mergeId] = mergedGame(existing, with: game)
            } else {
                gamesById[game.id] = game
                idByNormalizedTitle[normalizedTitle] = game.id
                orderedIds.append(game.id)
            }
        }

        return orderedIds.compactMap { gamesById[$0] }
    }

    private func mergedGame(_ lhs: GameInfo, with rhs: GameInfo) -> GameInfo {
        var variants = lhs.variants
        let existingVariantIds = Set(variants.map(\.id))
        variants.append(contentsOf: rhs.variants.filter { !existingVariantIds.contains($0.id) })

        return GameInfo(
            id: lhs.id,
            title: lhs.title.isEmpty || lhs.title == lhs.id ? rhs.title : lhs.title,
            boxArtUrl: lhs.boxArtUrl ?? rhs.boxArtUrl,
            heroBannerUrl: lhs.heroBannerUrl ?? rhs.heroBannerUrl,
            isInLibrary: lhs.isInLibrary || rhs.isInLibrary,
            variants: variants,
            canonicalId: lhs.canonicalId ?? rhs.canonicalId,
            matchConfidence: max(lhs.matchConfidence ?? 0, rhs.matchConfidence ?? 0),
            matchSource: combinedMatchSource(lhs.matchSource, rhs.matchSource),
            needsReview: lhs.needsReview || rhs.needsReview,
            providerMetadata: mergedProviderMetadata(lhs.providerMetadata, rhs.providerMetadata)
        )
    }

    private func mergedProviderMetadata(
        _ lhs: GameProviderMetadata?,
        _ rhs: GameProviderMetadata?
    ) -> GameProviderMetadata? {
        guard var merged = lhs else { return rhs }
        guard let rhs else { return merged }
        merged.platform = merged.platform ?? rhs.platform
        merged.releaseDate = merged.releaseDate ?? rhs.releaseDate
        merged.releaseYear = merged.releaseYear ?? rhs.releaseYear
        merged.developer = merged.developer ?? rhs.developer
        merged.publisher = merged.publisher ?? rhs.publisher
        merged.genres = unique(merged.genres + rhs.genres)
        merged.summary = merged.summary ?? rhs.summary
        return merged
    }

    private func combinedMatchSource(_ lhs: String?, _ rhs: String?) -> String? {
        let values = [lhs, rhs]
            .compactMap { $0?.split(separator: ",").map(String.init) }
            .flatMap { $0 }
            .filter { !$0.isEmpty }
        guard !values.isEmpty else { return nil }
        return unique(values).joined(separator: ",")
    }

    private func logCatalogDiagnostics(panelMainGames: [GameInfo]) {
        let doomTitles = doomCatalogMatches.map(\.title).joined(separator: " | ")
        let xboxCount = catalogStoreCounts.first { $0.store == "XBOX" }?.count ?? 0
        let microsoftCount = catalogStoreCounts.first { $0.store == "MICROSOFT" }?.count ?? 0
        catalogLogger.info("[Catalog] panelMain=\(panelMainGames.count) public=\(self.publicCatalogGames.count) merged=\(self.mainGames.count) library=\(self.libraryGames.count) xbox=\(xboxCount) microsoft=\(microsoftCount)")
        catalogLogger.info("[Catalog] Doom matches: \(doomTitles.isEmpty ? "none" : doomTitles, privacy: .public)")
    }

    private func normalizedCatalogTitle(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}
